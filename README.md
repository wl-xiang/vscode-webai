# vscode-webai — 浏览器版 VS Code + Agent 运行环境镜像

> **完整设计思路、踩坑修复记录与构建/打包/部署流程见 [DESIGN.md](DESIGN.md)，改镜像前必读。**

基于官方 `codercom/code-server` (Debian 13 / code-server 4.141.0) 的增量定制镜像，
内置 opencode、Node/Python/Go 三套运行时、Oracle Instant Client 及其运行时依赖，
面向老服务器 (CentOS 7 / 内核 3.10+) 的浏览器远程开发场景。

**目录**

| 章节 | 讲什么 |
|---|---|
| [镜像内容](#镜像内容linuxamd64-实测2026-10-13) | 里装了哪些组件、什么版本 |
| [本机构建与快速启动](#本机构建与快速启动) | 一条命令构建并跑起来 |
| [GitHub Actions 构建](#github-actions-构建) | CI 构建、`install-opencode` 勾选项 |
| [服务器部署](#服务器部署-centos-7) | 导入镜像、`CODE_SERVER_PORT`、`down` 的边界 |
| [持久化目录一览](#持久化目录一览) | 哪些数据不丢；[opencode 目录约定](#opencode-目录约定易错点)（易错点） |
| [用户配置持久化](#用户配置持久化bashrc) | `~/.bashrc` 怎么改才不丢 |
| [Oracle Instant Client 依赖自检](#oracle-instant-client-依赖libaio自检) | libaio 修复说明 + 自检脚本用法 |
| [opencode 热升级](#opencode-热升级免重建镜像) | 换二进制即升级，免重建镜像 |
| [离线环境装依赖](#离线环境装依赖三种运行时) | Python / Node / Go 三套离线方案 |
| [FAQ](#faq) | 常见坑：`go` 找不到、opencode 配置不生效、端口冲突… |

> 容器内 HOME 下每个目录的用途见镜像里烧录的 `~/README.md`（源文件 `config/HOME-README.md`）。

## 镜像内容（linux/amd64 实测，2026-10-13）

| 组件 | 版本 | 说明 |
|---|---|---|
| code-server | 4.141.0 | 官方镜像自带（跟随 `latest`，会随上游漂移） |
| opencode | 可选 | **默认不预装**；由 `./volumes/opencode-binary` 卷在运行时提供（版本＝你放的二进制）。构建时勾选 `install-opencode` 可烧录到 `/usr/local/bin/opencode` |
| Node.js | v24.21.0 (LTS) | `/usr/local`，npm registry 已指向 npmmirror |
| Python | 3.13.16 | python-build-standalone 预编译，含 pip / venv，pip 已指向清华镜像 |
| Go | 1.27.2 | `/usr/local/go`，GOPROXY 已指向 goproxy.cn |
| Oracle Instant Client | **21c (21.23.0.0.0)** | `/opt/oracle/instantclient`，libclntsh.so 全套；**版本已锁定 21c**（arm64 无 21c 包，自动降级 19c）；可用 `OIC_URL` 覆盖为 11g |
| Oracle 运行时依赖 | libaio / libnsl | 见下方「Oracle Instant Client 依赖」，已修复 Debian 13 的 `libaio.so.1` 兼容问题 |
| 常用工具 | — | jq / rg (ripgrep) / yq / fzf / vim / sqlite3 / unzip / git |
| 编译链 | — | gcc/g++/make (node-gyp、pip 源码包编译用) |
| 网络调试 | — | ping / nslookup / netstat 等 |

> Node / Python / Go 是"构建时自动取最新"，上表为某次实测值；需要精确复现请用
> `--build-arg NODE_VERSION= / PYTHON_URL= / GO_VERSION=` 固定。

## 本机构建与快速启动

```bash
# 最省事：compose 直接构建 + 启动（镜像不存在时会自动 build）
docker compose up -d --build
# 日志 / 停止
docker compose logs -f
docker compose down
```

单独构建并导出离线包：

```bash
./build.sh          # 构建并导出 vscode-webai_amd64.tar（默认不预装 opencode）

# 需要把 opencode 烧进镜像时（二进制先放到 opencode-bin-cli/opencode）:
INSTALL_OPENCODE=true ./build.sh
```

或手动：

```bash
mkdir -p opencode-bin-cli          # Dockerfile 有 COPY, 目录必须存在
docker build --platform linux/amd64 -t vscode-webai:latest .
docker save -o vscode-webai_amd64.tar vscode-webai:latest
```

构建参数（可选覆盖）：

```bash
docker build \
    --build-arg NODE_VERSION=24.13.1 \
    --build-arg GO_VERSION=1.27.2 \
    --build-arg APT_MIRROR=mirrors.aliyun.com \
    --build-arg INSTALL_OPENCODE=true \
    --build-arg OIC_URL=https://内网/instantclient-basic-linux.x64-11.2.0.4.0.zip \
    -t vscode-webai:latest .
```

## GitHub Actions 构建

仓库自带 `action.yml`（composite action）与 `.github/workflows/build.yml`。
Actions 页 → "Build Docker Image" → Run workflow，可选：

| 选项 | 默认 | 说明 |
|---|---|---|
| `arch` | `x86_64` | 目标部署架构（`x86_64` / `arm64`） |
| `install-opencode` | **不勾选 (false)** | 勾选则自动拉**最新版** opencode 烧进镜像；不勾选则镜像不含 opencode，运行时用卷挂载 |
| `opencode-version` | 空 | 仅勾选预装时生效，空 = 取 npm 上的 latest |
| `oic-url` | 空 | 指定 Oracle Instant Client zip 地址（11g 必填） |

跑完在运行页 artifact 下载 `vscode-webai_docker-images_<arch>.<ext>` + sha256，
服务器 `docker load -i` 导入。

> **opencode 路径约定**（构建产物里也会记录）
> - 镜像内烧录位置：`/usr/local/bin/opencode`（仅 `install-opencode=true` 时存在）
> - 运行时热升级挂载点：`/opt/opencode/bin/opencode`（PATH 中优先级更高，见下方卷表）

## 服务器部署 (CentOS 7)

```bash
# 1. 导入镜像
docker load -i vscode-webai_amd64.tar

# 2. 上传 docker-compose.yaml + config/，与镜像同一目录，启动
docker compose up -d

# 3. 停止 (数据在挂载目录，不会丢)
docker compose down
```

浏览器访问 `http://<服务器IP>:8080`，密码在 compose 的 `PASSWORD` 环境变量中（默认 `root1234`）。
code-server 自带会话记忆：再次登录时会打开上一次浏览的目录。

### 端口与环境变量

宿主机端口默认 **8080**，可通过环境变量覆盖（例如宿主机 8080 已被别的服务占用时）：

```bash
# 方式一：临时覆盖
CODE_SERVER_PORT=8081 docker compose up -d

# 方式二：写在项目根目录的 .env 里（compose 自动读取，该文件已在 .gitignore）
echo 'CODE_SERVER_PORT=8081' > .env
docker compose up -d
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `CODE_SERVER_PORT` | `8080` | 宿主机映射端口（容器内始终是 8080） |
| `PASSWORD` | `root1234` | code-server 登录密码 |
| `TZ` | `Asia/Shanghai` | 容器时区 |

> **停止服务**：`docker compose down` 只移除本项目（`vscode-webai`）的容器与网络，
> 不会动宿主机上其它 compose 项目；加 `-v` 才会删卷——本项目全用 bind mount，
> 数据在 `./volumes/`，`down` 本身不会丢数据。

> ARM64 版本：`docker build --platform linux/arm64`（Dockerfile 已按 TARGETARCH 自动切换
> arm64 资源），或用 GitHub Actions 选 arm64 构建；找一台 ARM 机器原生构建更快（QEMU 模拟较慢）。

## 持久化目录一览

| 宿主机路径 | 容器路径 | 用途 |
|---|---|---|
| `./volumes/workspace` | `/home/coder/project` | 项目代码 |
| `./volumes/code-server-data` | `~/.local/share/code-server` | VSIX 扩展、用户数据 |
| `./volumes/code-server-config` | `~/.config/code-server` | code-server 配置 |
| **`./config/bashrc`** | **`~/.bashrc`（`/home/coder/.bashrc` 与 `/root/.bashrc`）** | **用户 shell 配置，跨重建持久化** |
| **`./volumes/opencode-binary`** | **`/opt/opencode/bin`** | **opencode 二进制热升级卷（放 `opencode` 即生效，免重建镜像）** |
| `./volumes/opencode-config` | `~/.config/opencode` | opencode **全局配置目录**（含 skills / agent / command；注意**无前导点**） |
| `./volumes/opencode-share` | `~/.local/share/opencode` | opencode 状态/会话数据 |
| `./volumes/opencode-cache` | `~/.cache/opencode` | opencode 缓存 |
| `./volumes/local-bin` | `~/.local` | **AI CLI / MCP CLI 安装点**（npm 全局前缀） |
| `./volumes/npm-cache` | `~/.npm` | npm 下载缓存（离线装依赖用） |
| `./volumes/pip-cache` | `~/.cache/pip` | pip 下载缓存（离线装依赖用） |
| `./volumes/python-wheels` | `~/wheels` | 离线 wheel 投放目录 |
| `./volumes/go-workspace` | `~/go` | GOPATH（含 pkg/mod 模块缓存，离线可用） |

> 目录属主问题已由官方镜像的 `fixuid` 在容器启动时自动修正，无需手动 chown
> （`config/bashrc` 若 coder 无写权限，服务器上执行一次 `sudo chown 1000:1000 config/bashrc`）。

另有 **`~/README.md`**（容器 HOME 目录说明）随镜像烧录，源文件为 `config/HOME-README.md`；
里面逐条讲清了 HOME 下每个目录的用途、持久化来源和配置位置 —— 用户进容器后可直接 `cat ~/README.md`。

### opencode 目录约定（易错点）

opencode 分**全局**和**项目级**两个作用域，目录名**不一样**，写错会导致"配置放了但不生效"：

| 作用域 | 目录 | 说明 |
|---|---|---|
| **全局** | `~/.config/opencode/` | **无前导点**。官方文档标注 "NOT `~/.opencode/`" |
| 项目级 | `<项目根>/.opencode/` | **带点**，随项目走，可提交 Git |

| 内容 | 全局路径 | 项目级路径 |
|---|---|---|
| 配置 | `~/.config/opencode/opencode.json`（或 `.jsonc`） | `<项目>/opencode.json` 或 `.opencode/opencode.json` |
| Skills | `~/.config/opencode/skills/<名字>/SKILL.md` | `.opencode/skills/<名字>/SKILL.md` |
| Agents | `~/.config/opencode/agent/<名字>.md` | `.opencode/agent/<名字>.md` |
| Commands | `~/.config/opencode/command/<名字>.md` | `.opencode/command/<名字>.md` |
| 登录态 | `~/.local/share/opencode/auth.json`（**不在配置目录里**，含 token） | — |

要点：配置是**深度合并**的，项目级优先；子目录推荐**复数**（`skills`/`agent` 与单数兼容）；
配置**只在启动时加载一次**，改完必须重启 opencode；`opencode.json` 里出现未知顶层 key
会**直接启动失败**，建议先声明 `"$schema": "https://opencode.ai/config.json"`。

首次部署时 `./volumes/opencode-config` 是空目录（空挂载会遮住镜像预建的子目录），
想让容器里立刻有标准结构，执行一次：

```bash
mkdir -p volumes/opencode-config/{skills,agent,command}
```

## 用户配置持久化（`~/.bashrc`）

容器以 `coder`(uid 1000) 运行，所以**日常生效的是 `/home/coder/.bashrc`**；
`/root/.bashrc` 只是 `docker exec -u root` 时生效的那份。

compose 把**同一份宿主机文件 `./config/bashrc`** 同时挂到这两个位置，因此：

```bash
# 容器内直接改（code-server 网页终端 / docker exec）
vim ~/.bashrc
source ~/.bashrc
```

改动即时落在宿主机 `./config/bashrc` 上，`docker compose down` / 重建容器 / 换镜像都不会丢。
自己的别名和环境变量写在文件末尾的「你自己的别名 / 环境变量」区块即可。

> 注意：非登录交互 shell（code-server 网页终端）只读 `~/.bashrc`、不读 `/etc/profile`，
> 所以 PATH 在 `config/bashrc` 里也导出了一次。

## Oracle Instant Client 依赖（libaio）自检

镜像内置自检脚本，容器内一条命令验证「依赖是否齐全 + python-oracledb 能否跑起来」：

```bash
# 完整检查（会临时建 venv 装 oracledb，需要能访问 pip 源）
docker compose exec code-server test-oracle-instantclient

# 离线环境：只校验底层依赖（ldd + ctypes 加载 OCI 库），不装任何 Python 包
docker compose exec code-server test-oracle-instantclient --skip-pip

# 顺带验证真实连接
docker compose exec code-server test-oracle-instantclient \
    --dsn 10.0.0.5:1521/ORCL --user scott --password tiger
```

脚本会依次检查：客户端目录与核心库 → `ldd` 全量动态依赖 → `libaio.so.1` 是否可解析
→ `ld.so.conf.d` / `LD_LIBRARY_PATH` → `ctypes` 直接加载 `libclntsh.so`
→ `python-oracledb` thick 模式 `init_oracle_client()` 与 `clientversion()`（可选真实连接）。

### 关于 libaio 的坑（已修复）

Oracle 的 `libclntsh.so` 硬依赖 **SONAME 叫 `libaio.so.1`** 的异步 I/O 库，但
Debian 13 (trixie) / Ubuntu 24.04 的 time64 迁移把包 `libaio1` 改名成 `libaio1t64`，
库文件名变成 `libaio.so.1t64`。于是 apt 装的库"在"，Oracle 却按 `libaio.so.1` 找不到，
运行时报：

```
libaio.so.1: cannot open shared object file: No such file or directory
```

python-oracledb thick 模式报 `DPY-3010` / `DPY-3012`。

镜像里的修复：装完 libaio 后补出兼容软链接并刷新缓存

```bash
ln -sf /usr/lib/<arch>/libaio.so.1t64 /usr/lib/<arch>/libaio.so.1
ldconfig
```

并在**构建期**强校验：`ldd libclntsh.so` 出现任何 `not found` 直接让构建失败，
不会把问题漏到运行时。

### 关于 Oracle 版本

镜像**已明确锁定 Oracle Instant Client 21c**（`21.23.0.0.0`），不再"自动取最新"：

| 目标架构 | 实际使用 | 说明 |
|---|---|---|
| x86_64 / amd64 | 21c (21.23.0.0.0) | 指定版本，固定 URL |
| arm64 | 19c (19.32.0.0.0) | Oracle **从未发布 21c 的 arm64 包**，构建时自动降级并告警 |

版本信息烧录在容器内 `/opt/oracle/VERSION`，`test-oracle-instantclient` 会一并打印。
需要换成别的版本（含 11g）时用 `--build-arg OIC_URL=<zip 地址>` 覆盖即可，依赖侧的
libaio 修复与版本无关。

### 关于 Oracle 11g (11.2) 客户端

Oracle 11.2 的 Instant Client zip **已不在公开直链上**（`otn_software` 只剩
19c / 21c / 23ai），访问 `otn/linux/instantclient/112040/...` 会 302 跳转到
Oracle 账号登录页，CI 无法匿名拉取。需要 11g 客户端时：

1. 登录 OTN 手动下载 `instantclient-basic-linux.x64-11.2.0.4.0.zip`；
2. 放到内网 HTTP 服务（或本机临时 HTTP 服务）；
3. 构建时指定：`--build-arg OIC_URL=<zip 地址>`（GitHub Actions 用 `oic-url` 输入）。

依赖侧无需任何额外处理 —— 上面的 libaio 修复对 11g / 19c / 21c 完全一致。

## opencode 热升级（免重建镜像）

opencode 二进制有两个位置，`/opt/opencode/bin` 在 PATH 里**优先于** `/usr/local/bin`：

| 位置 | 来源 |
|---|---|
| `/opt/opencode/bin/opencode` | compose 卷 `./volumes/opencode-binary` → **热升级用这个** |
| `/usr/local/bin/opencode` | 镜像烧录，仅构建时勾选 `install-opencode` 才有 |

升级步骤（**不需要重建镜像**）：

```bash
# 1. 下载新版（示例: linux x64；也可直接在宿主机下载后拷进 volumes/opencode-binary/）
curl -fsSL -o /tmp/oc.tgz https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-<版本>.tgz
tar -xzf /tmp/oc.tgz -C /tmp

# 2. 覆盖热升级卷里的二进制（文件名必须叫 opencode）
install -m 755 /tmp/package/bin/opencode ./volumes/opencode-binary/opencode

# 3. 验证 —— 该卷是「目录」bind mount，文件是实时可见的，通常无需重启容器
docker compose exec code-server opencode --version
```

> 若第 3 步仍是旧版本，说明当前会话的 shell 有命令哈希缓存，执行 `hash -r` 或重开终端即可；
> 只有在极少数需要重建挂载命名空间时才用 `docker compose up -d`。
>
> 卷为空时会自动回退到镜像内 `/usr/local/bin/opencode`（如果构建时预装过）；
> 两者都没有时 `opencode` 命令不可用 —— 这属于正常情况，放个二进制进去即可。

## AI CLI / MCP CLI 安装方式（免 sudo，且持久化）

npm 全局前缀已指向 `~/.local`（对应宿主机 `./volumes/local-bin`），容器内直接：

```bash
npm i -g <某个-ai-cli>
npm i -g <某个-mcp-cli>
```

二进制落在 `~/.local/bin`（已在 PATH），宿主机 `./volumes/local-bin/` 可见、重建容器不丢。
opencode 全局 skills / agents / commands 放宿主机 `./volumes/opencode-config/{skills,agent,command}/`
即可，容器内对应 `~/.config/opencode/{skills,agent,command}/`（**是 `opencode`，不是 `.opencode`**，
详见上文「opencode 目录约定」）。

## 离线环境装依赖（三种运行时）

原则：**运行时本身已烧进镜像**（tar 就是离线载体），需要处理的是项目依赖。
流程统一为"在线机上收集 → 拷进服务器挂载目录 → 容器内离线安装"。

### Python（pip）

```bash
# ① 在线机收集依赖 (在有网的容器里执行, 产物是纯 .whl 文件, 与运行环境同容器保证兼容)
docker run --rm -v ./volumes/python-wheels:/home/coder/wheels -w /home/coder/wheels \
    vscode-webai:latest \
    pip download -r requirements.txt -d /home/coder/wheels

# ② 把 ./volumes/python-wheels 目录拷到服务器 (目录已挂载到容器 /home/coder/wheels)

# ③ 容器内离线安装 (建议装进项目 venv, venv 位于 ./volumes/workspace → 天然持久化)
python3 -m venv /home/coder/project/myapp/.venv
/home/coder/project/myapp/.venv/bin/pip install \
    --no-index --find-links=/home/coder/wheels -r requirements.txt
```

- venv 建在项目目录里 → 随 `./volumes/workspace` 持久化，重建容器不丢
- `./volumes/pip-cache` 已挂载：在线装过一次的包，缓存自动留存，下次 `pip install` 秒装

### Node（npm）

```bash
# 方案 A (推荐): vendor 思路 —— 在线机在容器里装好, node_modules 随项目整体拷贝
docker run --rm -v ./volumes/workspace:/home/coder/project vscode-webai:latest \
    sh -c 'cd /home/coder/project/myapp && npm install'

# 方案 B: 缓存复用 —— 在线机装一次后, ./volumes/npm-cache 已填满, 打包传服务器
npm install --offline

# 全局 CLI 工具: npm i -g → 落在 ./volumes/local-bin, 天然持久化
npm i -g <cli>
```

### Go

```bash
# 方案 A (推荐): vendor —— 模块源码进项目目录, 随项目打包, go 命令自动优先使用
cd /home/coder/project/myapp
go mod vendor          # 在线执行一次; 之后 go build ./... 自动走 vendor/, 离线可用

# 方案 B: 模块缓存 —— GOPATH 挂载在 ./volumes/go-workspace
go mod download
GOPROXY=off go build ./...   # 离线构建 (强制只用本地缓存)
```

## 常用验证命令（容器内）

```bash
opencode --version && go version && node -v && python3 --version
jq --version && rg --version && yq --version && fzf --version
ls /opt/oracle/instantclient/libclntsh.so   # Oracle 库
cat /opt/oracle/VERSION                     # Oracle Instant Client 版本 (21c)
test-oracle-instantclient --skip-pip        # Oracle 依赖自检
cat ~/README.md                             # HOME 目录结构与配置说明
npm config get registry                     # 应为 npmmirror
go env GOPROXY                              # 应为 goproxy.cn
```

## FAQ

**Q: 命令行输入 `go` 提示 Unknown command？**

Go 只存在于**容器内部**：`/usr/local/go/bin/go`，宿主机（CentOS 7）上没有。
进入容器环境再用：code-server 网页终端、`docker exec -it vscode-webai bash`、
或 `docker compose exec code-server bash`。容器里登录/非登录 shell 的 PATH
均已包含（登录 shell 靠 `/etc/profile.d/dev-path.sh`，交互 shell 靠 `~/.bashrc`）。

**Q: `opencode: command not found`？**

默认构建不带 opencode。把二进制放到 `./volumes/opencode-binary/opencode`
然后 `docker compose up -d`；或构建时勾选 `install-opencode` 把它烧进镜像。

**Q: 把 opencode 配置放到 `~/.config/.opencode` 但完全没生效？**

全局配置目录是 **`~/.config/opencode`（无前导点）**，`~/.config/.opencode` 不是 opencode 的
读取路径。带点的 `.opencode` 只用于**项目级**（`<项目根>/.opencode/`）。详见
「持久化目录一览 → opencode 目录约定」。另外配置只在启动时加载一次，改完要重启 opencode。

**Q: 改了 `.env` 里的端口 / 环境变量，容器没变化？**

compose 的环境变量变更需要**重建容器**才生效：

```bash
docker compose up -d       # 会自动检测配置差异并重建
```

**Q: `docker compose down` 会不会把服务数据删掉？**

不会。`down` 只删除本项目（`vscode-webai`）的容器和网络，本项目的持久化数据全部是
宿主机 bind mount（`./volumes/`、`./config/`），与你机器上其它 compose 项目也互不影响。
只有 `docker compose down -v` 才会删卷——而本项目不使用命名卷，所以 `down` 是安全的。

**Q: 镜像里预装了哪些第三方依赖？**

没有。镜像只包含运行时本身（Node / Python / Go 解释器与工具链、code-server、
opencode（可选）、Oracle Client、jq/rg/yq/fzf 等系统工具），已实测确认：
pip 仅 pip/setuptools，npm -g 仅 npm 自身，Go 模块缓存为空。
所有项目依赖均按「离线环境装依赖」章节由用户自行安装、按需持久化。

## 注意事项

- CentOS 7 宿主机只需内核 3.10+ 和可用的 Docker，容器用户态自带，不受宿主 glibc 限制
- 端口默认 `8080:8080` 并暴露在局域网；可用 `CODE_SERVER_PORT` 改宿主端口，
  仅本机使用时把 compose 的 ports 改成 `"127.0.0.1:${CODE_SERVER_PORT:-8080}:8080"`
- 密码是明文写在 compose 里的（默认 `root1234`），建议改掉默认值，或后续换 `HASHED_PASSWORD`
- 镜像约 3.3GB，tar 包约 3.2GB，拷贝到服务器预留足够空间
