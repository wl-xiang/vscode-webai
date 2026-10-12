# ============================================================
# code-server AI 开发环境镜像 (multi-arch: linux/amd64 | linux/arm64)
# Base: codercom/code-server (官方发布镜像, Ubuntu)
# Source repo: https://github.com/coder/code-server
#
# 架构由 --platform 控制 (buildx 自动注入 TARGETARCH):
#   x86_64: docker build --platform linux/amd64 (默认)
#   arm64 : docker build --platform linux/arm64
# Node/Python/Go/yq/opencode/Oracle 下载资源均按 TARGETARCH 自动切换
# ============================================================
FROM codercom/code-server:latest

USER root

# 目标架构: buildx 按 --platform 自动注入 (不指定 = 宿主架构)。
# 注意: 不能写默认值! 写了默认值 (如 =amd64) 会覆盖自动注入的值,
# 导致跨架构构建 arm64 时所有下载仍用 x86_64 资源 (即此前 arm64 构建失败的原因)。
# CI action 里为保险起见还会显式传 --build-arg TARGETARCH=amd64|arm64
ARG TARGETARCH

# ---------- 构建参数 ----------
# apt 镜像源 (留空 = 官方源 deb.debian.org; 网络不通时再改如 mirrors.aliyun.com)
ARG APT_MIRROR=
# Node 版本: 留空 = 构建时自动获取 v24 LTS 最新版 (如需固定: 24.13.1)
ARG NODE_VERSION=
# Python 3.13 预编译包完整下载地址: 留空 = 从 GitHub 自动获取最新 3.13.x
# (python-build-standalone 项目; 离线构建可把 URL 指向内网 HTTP 服务)
ARG PYTHON_URL=
# Go 版本: 留空 = 构建时自动获取最新稳定版
ARG GO_VERSION=
# 是否把 opencode 二进制烧录进镜像 (默认 false)。
#   false: 镜像不含 opencode —— 运行时用 compose 的 opencode-binary 卷把二进制
#          挂到 /opt/opencode/bin (PATH 优先), 升级只需换文件, 免重建镜像
#   true : 把 opencode-bin-cli/ 下的二进制装到 /usr/local/bin/opencode
ARG INSTALL_OPENCODE=false
# Oracle Instant Client Basic 包完整下载地址。
#   留空 = 按 TARGETARCH 取公开直链版本 (x64: 21.23 / arm64: 19.32)。
#
# 【关于 Oracle 11g (11.2.0.4) 客户端】
#   11.2 的 zip 已**不在**公开直链 (download.oracle.com/otn_software/...) 上,
#   访问 otn/linux/instantclient/112040/... 会 302 跳转到 Oracle 账号登录页,
#   CI 中无法匿名拉取。需要 11g 客户端时二选一:
#     a) 登录 OTN 手动下载 zip → 放到内网 HTTP → --build-arg OIC_URL=<内网地址>
#     b) docker build 前把 zip 下载到本机 HTTP 服务, 同上
#   依赖侧无需改动: libaio 修复对 11g / 19c / 21c 完全一致 (§7 附构建期校验)。
ARG OIC_URL=

# ---------- 1. 系统依赖 ----------
# jq / ripgrep(rg) / yq(下面单独装) / fzf 等常用工具
RUN if [ -n "$APT_MIRROR" ]; then \
        grep -rl "archive.ubuntu.com\|security.ubuntu.com\|deb.debian.org" /etc/apt 2>/dev/null | \
            xargs -r sed -i "s|archive.ubuntu.com|$APT_MIRROR|g; s|security.ubuntu.com|$APT_MIRROR|g; s|deb.debian.org|$APT_MIRROR|g"; \
    fi \
    && echo 'Acquire::Retries "6";' > /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl wget \
        unzip zip tar xz-utils \
        jq ripgrep fzf vim less \
        python3 python3-pip python3-venv \
        build-essential \
        sqlite3 \
        procps net-tools iputils-ping dnsutils

# ---------- 1b. Oracle 运行时依赖 (libaio / libnsl) ----------
# ============================================================
# ⚠ 这里是此前 "libaio 未正确安装" 的根因所在, 不要简化掉!
#
# Oracle Instant Client 的 libclntsh.so 硬依赖异步 I/O 库:
#     libclntsh.so => libaio.so.1 => (需要的 SONAME 就叫 libaio.so.1)
#
# 但 Debian 13 (trixie) / Ubuntu 24.04 的 time64 迁移把包 libaio1 改名成
# **libaio1t64**, 且共享库 SONAME 一起改成了 **libaio.so.1t64**。
# 于是 apt 装的库"在", 但 Oracle 二进制按 libaio.so.1 找不到它, 运行时报:
#     libaio.so.1: cannot open shared object file
# python-oracledb thick 模式则报 DPY-3010 / DPY-3012。
#
# 修复: 装包后统一补出 libaio.so.1 -> libaio.so.1t64 兼容软链接, 再 ldconfig。
# (磁盘上的文件名变了, 但 ABI 兼容, 软链接即可, 无需换发行版或降级)
# ============================================================
RUN set -eux; \
    (DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libaio1t64 \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libaio1); \
    (DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libnsl2 \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libnsl1 \
        || true); \
    rm -rf /var/lib/apt/lists/*; \
    AO=$(find /usr/lib /lib -name 'libaio.so.1t64' 2>/dev/null | head -1); \
    [ -n "$AO" ] || AO=$(ldconfig -p | awk '/libaio\.so\.1t64/{print $NF; exit}'); \
    if [ -n "$AO" ]; then \
        REAL=$(readlink -f "$AO"); \
        DIR=$(dirname "$REAL"); \
        if [ ! -e "$DIR/libaio.so.1" ]; then \
            ln -sf "$REAL" "$DIR/libaio.so.1"; \
            echo "created compat symlink: $DIR/libaio.so.1 -> $REAL"; \
        fi; \
        ldconfig; \
    fi; \
# 断言方式很重要: 不能用 `ldconfig -p | grep libaio.so.1` —— ldconfig 按 SONAME
# 去重, 软链接里的 SONAME 仍是 libaio.so.1t64, 所以修复成功后它也只显示 libaio.so.1t64,
# 拿它做断言会误判。唯一可信的是"让动态加载器按名字真正解析一次"。
    python3 -c "import ctypes; ctypes.CDLL('libaio.so.1')" \
        || { echo "ERROR: libaio.so.1 无法被动态加载器解析"; exit 1; }; \
    echo "OK: libaio.so.1 可被动态加载器解析"

# ---------- 2. yq (apt 源里没有, GitHub 最新版) ----------
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH}" \
        -o /usr/local/bin/yq \
    && chmod 755 /usr/local/bin/yq

# ---------- 3. Node v24 LTS (留空自动取最新 24.x; npmmirror 二进制镜像) ----------
RUN if [ -z "$NODE_VERSION" ]; then \
        NODE_VERSION=$(curl -fsSL 'https://nodejs.org/dist/index.json' \
            | grep -oP '"version":\s*"\Kv24\.[0-9.]+' | head -1); \
    fi \
    && case "$TARGETARCH" in arm64) NODE_ARCH=arm64 ;; *) NODE_ARCH=x64 ;; esac \
    && echo "Installing Node ${NODE_VERSION} (linux-${NODE_ARCH})" \
    && curl -fsSL "https://registry.npmmirror.com/-/binary/node/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        | tar -xJ --strip-components=1 -C /usr/local

# ---------- 4. Python 3.13 (python-build-standalone 预编译包, 自动取最新 3.13.x) ----------
# 预编译包解压到 /usr/local 后, /usr/local/bin/python3 优先于系统 /usr/bin/python3。
# install_only 包已自带 pip (site-packages/pip-*.dist-info + bin/pip3, 指向同目录 python3.13),
# 无需 ensurepip —— 且 arm64 走 QEMU 模拟时 ensurepip 的子进程执行又慢又易出问题, 直接验证版本即可
RUN case "$TARGETARCH" in arm64) PY_ARCH=aarch64 ;; *) PY_ARCH=x86_64 ;; esac \
    && if [ -z "$PYTHON_URL" ]; then \
        PYTHON_URL=$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
            | grep -oP '"browser_download_url":\s*"\K[^"]*cpython-3\.13\.[0-9.]+[^"]*'${PY_ARCH}'-unknown-linux-gnu-install_only\.tar\.gz' \
            | grep -v freethreaded | head -1); \
    fi \
    && echo "Installing Python: ${PYTHON_URL}" \
    && curl -fsSL "$PYTHON_URL" -o /tmp/py.tgz \
    && tar -xzf /tmp/py.tgz --strip-components=1 -C /usr/local \
    && rm -f /tmp/py.tgz \
    && python3 --version && pip3 --version | cut -d' ' -f1-2

# ---------- 5. Go (go.dev 自动取最新版, 失败回退阿里云镜像) ----------
RUN GO_VER=$(if [ -n "$GO_VERSION" ]; then echo "$GO_VERSION"; \
        else curl -fsSL 'https://go.dev/dl/?mode=json' \
            | grep -oP '"version":\s*"\Kgo[0-9.]+' | head -1 | sed 's/^go//'; fi) \
    && echo "Installing Go ${GO_VER}" \
    && (curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz \
        || curl -fsSL "https://mirrors.aliyun.com/golang/go${GO_VER}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz) \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz

# ---------- 6. opencode (可选预装) ----------
# 二进制位置约定 (上下一致, 见 compose 的 opencode-binary 卷):
#   • 镜像内烧录路径 : /usr/local/bin/opencode   ← 仅当 INSTALL_OPENCODE=true
#   • 热升级挂载路径 : /opt/opencode/bin/opencode ← compose 卷, PATH 优先命中
# INSTALL_OPENCODE=false (默认) 时镜像不含 opencode, 完全靠挂载卷提供,
# 这样升级 opencode 只需要换宿主机上的一个文件, 不必重建 3GB+ 镜像。
COPY opencode-bin-cli/ /tmp/opencode-bin-cli/
RUN set -eux; \
    if [ "$INSTALL_OPENCODE" = "true" ]; then \
        BIN=$(find /tmp/opencode-bin-cli -maxdepth 1 -type f -name 'opencode*' ! -name '.gitkeep' | head -1); \
        [ -n "$BIN" ] || { echo "ERROR: INSTALL_OPENCODE=true 但 opencode-bin-cli/ 里没有二进制"; exit 1; }; \
        install -m 755 "$BIN" /usr/local/bin/opencode; \
        echo "opencode 已烧录到镜像: /usr/local/bin/opencode ($("$BIN" --version 2>/dev/null || echo 'version n/a'))"; \
    else \
        echo "INSTALL_OPENCODE=false -> 跳过, 由 opencode-binary 卷在运行时提供"; \
    fi; \
    rm -rf /tmp/opencode-bin-cli

# ---------- 7. Oracle Instant Client (指定版本: 21c) ----------
# 提供 libclntsh.so (oracleclient) 等 OCI 库, 供 python-oracledb(thick 模式)/cx_Oracle 等使用。
#
# 【版本已按需求锁定为 21c (21.23.0.0.0)】, 不再"自动取最新":
#   x86-64 → instantclient-basic-linux.x64-21.23.0.0.0dbru.zip
#   arm64  → Oracle **从未发布 21c 的 arm64 包**, 只能降级 19c (19.32), 构建日志会告警
# 注意: 不要用无后缀的通配 URL (instantclient-basic-linux.zip / -arm64.zip),
# 它们提供的是 32 位构建 (x86 i686 / arm 32bit), 64 位系统上 python-oracledb
# 加载 libclntsh.so 会报 "wrong ELF class" 错误, 必须用带 .x64/.arm64 的官方固定版本。
# 需要 11g (11.2, 需 OTN 登录下载) 或其它版本 → --build-arg OIC_URL=<zip 地址> 覆盖。
RUN case "$TARGETARCH" in \
        arm64) \
            OIC_LABEL="19c (19.32.0.0.0) [arm64 无 21c 包, 自动降级]"; \
            OIC_DEFAULT="https://download.oracle.com/otn_software/linux/instantclient/1932000/instantclient-basic-linux.arm64-19.32.0.0.0dbru.zip" ;; \
        *) \
            OIC_LABEL="21c (21.23.0.0.0)"; \
            OIC_DEFAULT="https://download.oracle.com/otn_software/linux/instantclient/2123000/instantclient-basic-linux.x64-21.23.0.0.0dbru.zip" ;; \
    esac \
    && OIC_URL="${OIC_URL:-$OIC_DEFAULT}" \
    && echo "Oracle Instant Client: ${OIC_LABEL}" \
    && echo "  download: ${OIC_URL}" \
    && mkdir -p /opt/oracle \
    && curl -fsSL "$OIC_URL" -o /tmp/oic.zip \
    && unzip -q /tmp/oic.zip -d /opt/oracle \
    && rm -f /tmp/oic.zip \
    && mv /opt/oracle/instantclient_* /opt/oracle/instantclient \
    && printf '%s\n%s\n' "$OIC_LABEL" "$OIC_URL" > /opt/oracle/VERSION \
    && echo "/opt/oracle/instantclient" > /etc/ld.so.conf.d/oracle-instantclient.conf \
    && ldconfig \
# 构建期强校验: 任何 "not found" 直接让构建失败, 不让 libaio 类问题漏到运行时。
# (11g/12c/19c 的 libclntsh.so 会引用 libaio.so.1; 若某版本不直接引用则只提示不报错)
    && CLNT=$(ls /opt/oracle/instantclient/libclntsh.so* | head -1) \
    && { ldd "$CLNT" > /tmp/oc-ldd.txt || true; } \
    && if grep -q 'not found' /tmp/oc-ldd.txt; then \
           echo "ERROR: Oracle 客户端存在未解析依赖:"; grep 'not found' /tmp/oc-ldd.txt; exit 1; \
       fi \
    && if grep -q 'libaio\.so\.1 =>' /tmp/oc-ldd.txt; then \
           echo "OK: libaio.so.1 已解析 -> $(grep 'libaio\.so\.1 =>' /tmp/oc-ldd.txt)"; \
       else \
           echo "NOTE: 该版本 Oracle 客户端未直接引用 libaio.so.1 (无碍)"; \
       fi \
    && rm -f /tmp/oc-ldd.txt \
    && echo "Oracle Instant Client 依赖校验通过: ${OIC_LABEL} -> $CLNT"

# ---------- 8. 国内镜像源配置 ----------
# npm: registry + 全局安装前缀放全局配置 (注意: prefix 不能写在 ~/.npmrc,
#      coder 的 HOME 即工作区根目录, npm 会把它当项目级配置而报错)
RUN printf "registry=https://registry.npmmirror.com\nprefix=/home/coder/.local\n" > /usr/local/etc/npmrc
# npm: coder 用户级只配 registry
RUN printf "registry=https://registry.npmmirror.com\n" > /home/coder/.npmrc \
    && chown coder:coder /home/coder/.npmrc \
    && mkdir -p /home/coder/.local/bin \
    && chown -R coder:coder /home/coder/.local
# pip: 清华镜像
RUN printf "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\ntrusted-host = pypi.tuna.tsinghua.edu.cn\n" > /etc/pip.conf

# ---------- 9. 环境变量 ----------
ENV TZ=Asia/Shanghai
# /opt/opencode/bin 放最前: opencode 热升级卷挂载点, 有二进制时优先于镜像内 /usr/local/bin
ENV PATH=/opt/opencode/bin:/usr/local/go/bin:/home/coder/.local/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/oracle/instantclient
# Go 模块代理 (国内加速)
ENV GOPROXY=https://goproxy.cn,direct

# 登录 shell 修复: /etc/profile 会无条件重置 PATH, 冲掉上面的 ENV PATH,
# 导致 code-server 登录终端里 go / ~/.local/bin 下的命令 "Unknown command"
RUN printf 'export PATH=/opt/opencode/bin:/usr/local/go/bin:/home/coder/.local/bin:$PATH\n' \
        > /etc/profile.d/dev-path.sh \
    && chmod 644 /etc/profile.d/dev-path.sh

# ---------- 9b. 用户 shell 配置 (~/.bashrc) ----------
# 默认把仓库里的 config/bashrc 作为镜像基线 (无挂载时也能用);
# compose 会把同一份文件挂到 /home/coder/.bashrc 与 /root/.bashrc 实现持久化。
# 非登录交互 shell (code-server 网页终端) 只读 ~/.bashrc, 不读 /etc/profile,
# 所以 PATH 必须在这里也导出一次。
COPY config/bashrc /home/coder/.bashrc
RUN chown coder:coder /home/coder/.bashrc && chmod 644 /home/coder/.bashrc

# ---------- 10. 预置目录 (opencode skills 全局目录等, compose 里做持久化) ----------
# ⚠ opencode 的**全局**配置目录是 ~/.config/opencode (无前导点!),
#   官方文档明确写了 "NOT ~/.opencode/"。带点的 .opencode 只在**项目内**使用
#   (项目根目录的 .opencode/skills、.opencode/agent 等)。
#   子目录推荐用复数形式: skills/ agents/ commands/(单数向后兼容)。
RUN mkdir -p \
        /home/coder/project \
        /home/coder/.config/opencode/skills \
        /home/coder/.config/opencode/agent \
        /home/coder/.config/opencode/command \
        /home/coder/.local/share/opencode \
        /home/coder/.cache/opencode \
        /home/coder/go \
        /opt/opencode/bin \
    && chown -R coder:coder /home/coder

# ---------- 10b. 容器内工具脚本与说明文档 ----------
COPY test-oracle-instantclient.sh /usr/local/bin/test-oracle-instantclient
COPY config/HOME-README.md /home/coder/README.md
RUN chmod 755 /usr/local/bin/test-oracle-instantclient \
    && chown coder:coder /home/coder/README.md \
    && chmod 644 /home/coder/README.md

# ---------- 11. 运行身份 ----------
# 沿用官方设计: 以 coder(uid 1000) 运行, 官方 ENTRYPOINT 自带
# --bind-addr 0.0.0.0:8080 参数, 且 fixuid 会在启动时把挂载目录
# 属主修正为 coder (解决 Linux 宿主机 root 建目录 coder 无写权限的坑)
USER coder
WORKDIR /home/coder
