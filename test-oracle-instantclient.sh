#!/usr/bin/env bash
# ============================================================
# Oracle Instant Client 依赖完整性 + python-oracledb(thick) 冒烟测试
#
# 目的: 验证镜像内 Oracle Instant Client 的所有**动态依赖**是否齐备
#       —— 重点是 libaio.so.1 (Debian 13 的 libaio1t64 改名坑),
#       并用 Python SDK `oracledb` 以 thick 模式真正加载 OCI 客户端库。
#
# 用法 (容器内执行, 镜像已把它装到 PATH: `test-oracle-instantclient`):
#   test-oracle-instantclient
#   test-oracle-instantclient --lib-dir /opt/oracle/instantclient
#   test-oracle-instantclient --skip-pip                 # 离线: 不装 oracledb, 只测底层依赖
#   test-oracle-instantclient --dsn host:1521/ORCL --user scott --password tiger
#
# 退出码: 0 = 全部通过; 1 = 有检查项失败
# ============================================================
set -uo pipefail

LIB_DIR="${OIC_DIR:-/opt/oracle/instantclient}"
SKIP_PIP=0
DSN=""
DB_USER=""
DB_PASSWORD=""
PY="${PYTHON:-python3}"

while [ $# -gt 0 ]; do
    case "$1" in
        --lib-dir)  LIB_DIR="$2"; shift 2 ;;
        --dsn)      DSN="$2"; shift 2 ;;
        --user)     DB_USER="$2"; shift 2 ;;
        --password) DB_PASSWORD="$2"; shift 2 ;;
        --skip-pip) SKIP_PIP=1; shift ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "未知参数: $1 (--help 查看用法)"; exit 2 ;;
    esac
done

FAILED=0
pass() { printf '  [ OK ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILED=1; }
warn() { printf '  [WARN] %s\n' "$*"; }
info() { printf '\n== %s\n' "$*"; }

echo "Oracle Instant Client 自检 — $(date '+%F %T %Z')"
echo "库目录: ${LIB_DIR}     Python: ${PY}"

# ------------------------------------------------------------
info "1) 客户端目录与核心库"
if [ -d "$LIB_DIR" ]; then
    pass "目录存在: ${LIB_DIR}"
else
    fail "目录不存在: ${LIB_DIR} (可用 --lib-dir 指定)"
fi

CLNT=""
for cand in "$LIB_DIR"/libclntsh.so*; do
    [ -e "$cand" ] && CLNT="$cand" && break
done
if [ -n "$CLNT" ]; then
    pass "核心库: $(basename "$CLNT") -> $(readlink -f "$CLNT" | xargs basename)"
else
    fail "未找到 libclntsh.so* (Oracle 客户端基本库缺失)"
fi

if [ -f /opt/oracle/VERSION ]; then
    echo "        镜像声明版本: $(head -1 /opt/oracle/VERSION)"
fi

for extra in libclntshcore.so libnnz*.so libociei.so; do
    # shellcheck disable=SC2086
    found=$(ls $LIB_DIR/$extra 2>/dev/null | head -1)
    [ -n "$found" ] && pass "附加库: $(basename "$found")"
done

# ------------------------------------------------------------
info "2) 动态依赖解析 (ldd)"
if [ -n "$CLNT" ]; then
    LDD_OUT="$(ldd "$CLNT" 2>&1)"
    MISSING="$(printf '%s\n' "$LDD_OUT" | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')"
    if [ -n "$MISSING" ]; then
        fail "$(basename "$CLNT") 存在未解析依赖: ${MISSING}"
        printf '%s\n' "$LDD_OUT" | sed 's/^/        /'
    else
        pass "$(basename "$CLNT") 全部依赖已解析 ($(printf '%s\n' "$LDD_OUT" | grep -c '=>') 条)"
    fi
    # 逐个子库也查一遍
    for so in "$LIB_DIR"/libclntshcore.so*; do
        [ -e "$so" ] || continue
        m="$(ldd "$so" 2>&1 | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')"
        if [ -n "$m" ]; then fail "$(basename "$so") 缺失: ${m}"; else pass "$(basename "$so") 依赖完整"; fi
    done
fi

# ------------------------------------------------------------
info "3) libaio (Oracle 运行时硬依赖, 历史 bug 点)"
# 断言方式很重要: 不能用 `ldconfig -p | grep libaio.so.1` 判断 —— ldconfig 按
# SONAME 去重, 兼容软链接指向的库 SONAME 仍是 libaio.so.1t64, 所以**修复成功后**
# ldconfig -p 里也只会出现 libaio.so.1t64, 拿它做断言会误判(假绿/假红)。
# 唯一可信的方式: 让动态加载器按名字真正解析一次。
if "$PY" -c "import ctypes; ctypes.CDLL('libaio.so.1')" >/dev/null 2>&1; then
    pass "动态加载器可按名字解析 libaio.so.1"
else
    fail "libaio.so.1 不可解析 —— Oracle 会报 'libaio.so.1: cannot open shared object file'"
fi
LAIO_FILES="$(ls -1 /usr/lib/*/libaio.so.1* 2>/dev/null | sort -u)"
if [ -n "$LAIO_FILES" ]; then
    printf '        %s\n' $LAIO_FILES
fi
if ldconfig -p 2>/dev/null | grep -q 'libaio\.so\.1t64'; then
    warn "系统装的是新版 libaio1t64 (Debian 13+ 改名), 镜像已为其补出 libaio.so.1 兼容软链接"
fi

# ------------------------------------------------------------
info "4) 库搜索路径配置"
if grep -rqs "$LIB_DIR" /etc/ld.so.conf.d/ 2>/dev/null; then
    pass "已注册到 ld.so.conf.d: $(grep -rls "$LIB_DIR" /etc/ld.so.conf.d/ | tr '\n' ' ')"
else
    warn "未在 /etc/ld.so.conf.d/ 中注册 ${LIB_DIR}"
fi
echo "        LD_LIBRARY_PATH = ${LD_LIBRARY_PATH:-<未设置>}"

# ------------------------------------------------------------
info "5) ctypes 直接加载 OCI 客户端 (纯标准库, 不联网)"
if [ -n "$CLNT" ]; then
    "$PY" - "$CLNT" <<'PY'
import ctypes, sys
lib = sys.argv[1]
try:
    ctypes.CDLL(lib)
except OSError as e:
    print(f"  [FAIL] 加载失败: {e}")
    sys.exit(1)
print(f"  [ OK ] 成功加载 {lib} (动态依赖全部满足)")
PY
    [ $? -eq 0 ] || FAILED=1
fi

# ------------------------------------------------------------
info "6) python-oracledb (thick 模式, 真正调用 Oracle SDK)"
if [ "$SKIP_PIP" = "1" ]; then
    warn "已指定 --skip-pip, 跳过本项"
else
    ORAPY=""
    if "$PY" -c 'import oracledb' >/dev/null 2>&1; then
        ORAPY="$PY"
        pass "使用已安装的 oracledb"
    else
        VENV_DIR="$(mktemp -d)"
        if "$PY" -m venv "$VENV_DIR" >/dev/null 2>&1 \
           && "$VENV_DIR/bin/pip" install -q --disable-pip-version-check oracledb >/dev/null 2>&1; then
            ORAPY="$VENV_DIR/bin/python"
            pass "已在临时 venv 安装 oracledb (${VENV_DIR})"
        else
            fail "无法安装 oracledb (离线环境请用 --skip-pip 跳过本项)"
        fi
    fi

    if [ -n "$ORAPY" ]; then
        "$ORAPY" - "$LIB_DIR" "$DSN" "$DB_USER" "$DB_PASSWORD" <<'PY'
import sys
try:
    import oracledb
except ImportError as e:
    print(f"  [FAIL] import oracledb 失败: {e}"); sys.exit(1)

lib_dir, dsn, user, password = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(f"  [ OK ] python-oracledb {oracledb.__version__} 已导入")
try:
    oracledb.init_oracle_client(lib_dir=lib_dir)
except Exception as e:
    print(f"  [FAIL] init_oracle_client 失败 (thick 模式): {e}"); sys.exit(1)

try:
    cv = oracledb.clientversion()
    ver = ".".join(str(x) for x in cv) if isinstance(cv, tuple) else str(cv)
except Exception:
    ver = "unknown"
print(f"  [ OK ] thick 模式已激活, Oracle Client 版本 = {ver}")

if dsn and user:
    try:
        with oracledb.connect(user=user, password=password, dsn=dsn) as conn:
            with conn.cursor() as cur:
                cur.execute("select banner from v$version where rownum = 1")
                print(f"  [ OK ] 数据库连接成功: {cur.fetchone()[0]}")
    except Exception as e:
        print(f"  [FAIL] 数据库连接失败: {e}"); sys.exit(1)
else:
    print("  [ .. ] 未提供 --dsn/--user, 跳过真实连接 (客户端库加载已验证)")
PY
        [ $? -eq 0 ] || FAILED=1
    fi
fi

# ------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
    printf '\n\033[32m全部检查通过\033[0m — Oracle Instant Client 依赖完整, python-oracledb thick 模式可用\n'
    exit 0
else
    printf '\n\033[31m存在失败项\033[0m — 见上方 [FAIL] 行\n'
    exit 1
fi
