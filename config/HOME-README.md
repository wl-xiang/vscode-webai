# 容器 HOME 目录说明（`~` = `/home/coder`）

> 这份文件由镜像烧录，用来告诉你容器 HOME 下**每个目录是干什么的**、
> **哪些是持久化的**、以及**要改配置该动哪个文件**。
> 想改这份说明本身 → 编辑仓库里的 `config/HOME-README.md` 后重建镜像。

- 镜像：`vscode-webai`（code-server + opencode + Node/Python/Go + Oracle Instant Client）
- 容器内用户：`coder`（uid 1000），HOME = `/home/coder`，`~` 即此目录
- 启动时由官方 `fixuid` 自动把挂载目录属主修正为 `coder`，**不要手动 chown**

---

## 一、目录结构总览

```
/home/coder
├── README.md                 ← 本文件（镜像烧录）
├── .bashrc                   ← shell 配置      [持久化 → 宿主机 ./config/bashrc]
├── project/                  ← 你的代码工作区   [持久化 → ./volumes/workspace]
├── wheels/                   ← 离线 pip wheel 投放目录 [→ ./volumes/python-wheels]
├── go/                       ← GOPATH (含 pkg/mod 模块缓存) [→ ./volumes/go-workspace]
│
├── .config/
│   ├── code-server/          ← code-server 配置 [→ ./volumes/code-server-config]
│   └── opencode/             ← ★ opencode 全局配置 (无前导点!)
│       ├── opencode.json     ←   全局配置文件（需自行创建）
│       ├── skills/           ←   全局 skills  <名字>/SKILL.md
│       ├── agent/            ←   全局 agents  <名字>.md
│       └── command/          ←   全局 commands <名字>.md
│
├── .local/                   ← npm 全局安装点 (prefix) [→ ./volumes/local-bin]
│   ├── bin/                  ←   `npm i -g` 的可执行文件落这里 (已在 PATH)
│   └── share/
│       ├── code-server/      ←   VSIX 扩展、用户数据 [→ ./volumes/code-server-data]
│       └── opencode/         ←   opencode 状态/会话/登录态 [→ ./volumes/opencode-share]
│
├── .cache/
│   ├── opencode/             ← opencode 缓存 [→ ./volumes/opencode-cache]
│   └── pip/                  ← pip 下载缓存 [→ ./volumes/pip-cache]
│
└── .npm/                     ← npm 下载缓存 [→ ./volumes/npm-cache]

# 不在 HOME 下、但常用的两个位置：
/opt/opencode/bin/opencode    ← opencode 二进制(热升级挂载点) [→ ./volumes/opencode-binary]
/opt/oracle/instantclient     ← Oracle Instant Client 21c，见 /opt/oracle/VERSION
```

---

## 二、目录一览表

| 路径 | 用途 | 持久化来源（宿主机） |
|---|---|---|
| `~/.bashrc` | shell 配置（别名、环境变量、PATH） | `./config/bashrc` |
| `~/project` | **你的项目代码**，建议 venv / node_modules 都放这里 | `./volumes/workspace` |
| `~/.config/code-server` | code-server 自身配置 | `./volumes/code-server-config` |
| `~/.config/opencode` | **opencode 全局配置 + skills/agent/command** | `./volumes/opencode-config` |
| `~/.local` | npm 全局前缀（`npm i -g` 落 `~/.local/bin`） | `./volumes/local-bin` |
| `~/.local/share/code-server` | VSIX 扩展、用户数据 | `./volumes/code-server-data` |
| `~/.local/share/opencode` | opencode 会话/状态、`auth.json` 登录态 | `./volumes/opencode-share` |
| `~/.cache/opencode` | opencode 缓存 | `./volumes/opencode-cache` |
| `~/.cache/pip` | pip 下载缓存 | `./volumes/pip-cache` |
| `~/.npm` | npm 下载缓存 | `./volumes/npm-cache` |
| `~/wheels` | 离线 pip wheel 投放目录 | `./volumes/python-wheels` |
| `~/go` | GOPATH（`pkg/mod` 模块缓存） | `./volumes/go-workspace` |
| `/opt/opencode/bin` | **opencode 二进制热升级挂载点** | `./volumes/opencode-binary` |

> 以上全部是宿主机 bind mount。`docker compose down`、重建容器、换镜像都**不会丢数据**；
> 但**未列出的路径都是临时的**（例如 `/tmp`、`/usr/local/*`），重建即丢失。

---

## 三、opencode 目录约定（最容易搞错的一点）

opencode 分**全局**和**项目级**两个作用域，目录名不一样：

| 作用域 | 配置目录 | 说明 |
|---|---|---|
| **全局** | `~/.config/opencode/` | **没有前导点**。官方文档标注 "NOT `~/.opencode/`" |
| 项目级 | `<项目根>/.opencode/` | **带点**。随项目走，可提交 Git |

子目录推荐用**复数**形式（单数向后兼容）：

| 内容 | 全局路径 | 项目级路径 |
|---|---|---|
| 配置 | `~/.config/opencode/opencode.json`（或 `.jsonc`） | `<项目>/opencode.json` 或 `.opencode/opencode.json` |
| Skills | `~/.config/opencode/skills/<名字>/SKILL.md` | `.opencode/skills/<名字>/SKILL.md` |
| Agents | `~/.config/opencode/agent/<名字>.md` | `.opencode/agent/<名字>.md` |
| Commands | `~/.config/opencode/command/<名字>.md` | `.opencode/command/<名字>.md` |
| 登录态 | `~/.local/share/opencode/auth.json` | —（全局，含 token，别外传） |

要点：

- 全局配置文件和项目配置是**深度合并**的，项目配置优先级更高
- 配置**只在启动时加载一次**，改完要重启 opencode 才生效
- `opencode.json` 里有无法识别的顶层 key 会**直接启动失败**，写配置前建议先声明
  `"$schema": "https://opencode.ai/config.json"` 让编辑器校验

---

## 四、各语言的配置与环境变量

| 项 | 位置 / 值 |
|---|---|
| Node | `/usr/local`，`node -v`；npm registry = `https://registry.npmmirror.com` |
| npm 全局前缀 | `~/.local`（免 sudo，落在宿主机 `./volumes/local-bin`） |
| Python | `/usr/local/bin/python3`（3.13.x），pip 源 = 清华镜像 |
| pip 离线 | `pip install --no-index --find-links=~/wheels -r requirements.txt` |
| Go | `/usr/local/go/bin/go`，`GOPROXY=https://goproxy.cn,direct` |
| Oracle | `LD_LIBRARY_PATH=/opt/oracle/instantclient`，`libclntsh.so` 21c |
| PATH 顺序 | `/opt/opencode/bin` → `/usr/local/go/bin` → `~/.local/bin` → 系统 |
| 时区 | `TZ=Asia/Shanghai` |

---

## 五、常见操作

```bash
# —— shell 配置：改了立刻持久化到宿主机 ./config/bashrc
vim ~/.bashrc && source ~/.bashrc

# —— opencode 全局配置（首次自己建）
mkdir -p ~/.config/opencode
cat > ~/.config/opencode/opencode.json <<'EOF'
{ "$schema": "https://opencode.ai/config.json" }
EOF

# —— 加一个全局 skill
mkdir -p ~/.config/opencode/skills/my-skill
vim ~/.config/opencode/skills/my-skill/SKILL.md

# —— 装全局 CLI（免 sudo，落到 ./volumes/local-bin）
npm i -g <某个-cli>

# —— 升级 opencode：宿主机把新二进制放到 ./volumes/opencode-binary/opencode
#    然后 docker compose up -d 即可，不用重建镜像（卷是目录挂载，甚至无需重启）
opencode --version

# —— Oracle 依赖自检（含 python-oracledb thick 模式）
test-oracle-instantclient            # 装 oracledb 完整测（需联网）
test-oracle-instantclient --skip-pip # 离线只测底层依赖
cat /opt/oracle/VERSION              # 查看当前 Oracle 客户端版本
```

---

## 六、注意事项

1. **别把大文件放 HOME 的非挂载路径**——重建容器就没了。要留存就放 `~/project` 或上面表格里列出的目录。
2. `~/project` 是挂载覆盖的目录，镜像里的同名目录只是占位。
3. `~/.config/opencode` 是**单独挂载**的。不要试图整体替换 `~/.config`，
   它下面还挂着 code-server 的配置，会互相遮蔽。
4. `~/.local` 整体来自宿主机 `./volumes/local-bin`（首次可能为空），
   `npm i -g` 会自行创建 `~/.local/bin`，属正常现象。
5. `~/.config/opencode` 也来自宿主机 `./volumes/opencode-config`。
   **它是空目录时会遮住镜像里预建的 `skills/agent/command`** —— 想立刻看到标准结构，
   可在宿主机执行一次：
   ```bash
   mkdir -p volumes/opencode-config/{skills,agent,command}
   ```
   不执行也没关系，按第五节示例用 `mkdir -p` 创建即可，opencode 会自动识别。
6. 镜像里默认**不预装 opencode 二进制**（除非构建时勾选了 `install-opencode`），
   靠 `./volumes/opencode-binary` 卷在运行时提供，这样升级不用重建 3GB+ 镜像。
7. 离线装依赖请走「投放到挂载目录」的思路：Python → `~/wheels`、Node → `node_modules` 随项目、
   Go → `go mod vendor` 或 `~/go/pkg/mod`。详见仓库 README。
