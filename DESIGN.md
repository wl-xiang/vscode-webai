# vscode-webai — 设计与流程文档

> 本文档记录镜像与编排的完整设计思路、需求映射、踩坑修复和构建/打包/部署流程。
> 上手一个新服务器或修改镜像前，请先读完本文。

## 1. 项目背景

- **办公 PC**：老机器，无法安装新版 AI/Coding 工具 → 一切工具必须以 **Web 服务** 形式部署在服务器上，老 PC 只用浏览器访问
- **服务器**：CentOS 7（内核 3.10，glibc 老），有 **x86_64 和 ARM64** 两种架构，不能在宿主机直接装新软件
- **核心思路**：Docker 容器自带完整用户态，宿主机只需内核 3.10+ 和可用的 Docker；把 code-server（浏览器版 VS Code）+ opencode（AI CLI）+ 多语言运行时 + Oracle Instant Client 全部打包进**一个镜像**，离线 tar 或 registry 分发

## 2. 需求 → 实现映射

| 需求 | 实现方式 | 位置 |
|---|---|---|
| code-server 基础镜像 | `FROM codercom/code-server:latest`（官方发布镜像，自带 4.141.0） | Dockerfile 顶部 |
| VSIX 插件持久化 | bind mount `~/.local/share/code-server` + `~/.config/code-server` | compose `volumes` |
| **用户配置 `~/.bashrc` 持久化** | 仓库内单一文件 `config/bashrc` 同时挂到 `/home/coder/.bashrc` 与 `/root/.bashrc` | compose `volumes` / Dockerfile §9b |
| **opencode 二进制可选预装** | 构建开关 `install-opencode`（默认 false）→ `INSTALL_OPENCODE` build-arg → Dockerfile §6 条件安装 | action.yml / build.yml / Dockerfile §6 |
| **opencode 热升级（免重建）** | 独立卷 `./volumes/opencode-binary` → `/opt/opencode/bin`，PATH 优先级高于镜像内 `/usr/local/bin` | compose `volumes` / Dockerfile §9 |
| opencode 配置/skills/node_modules 持久化 | `~/.config/opencode`（**无前导点**）、`~/.local/share/opencode`、`~/.cache/opencode` 分别独立挂载 | compose `volumes` |
| npm 镜像源/固定依赖一键安装 | registry 指向 npmmirror；缓存目录挂载 `~/.npm`，离线 `npm install --offline` | Dockerfile §8 |
| python + pip | Python 3.13（python-build-standalone 预编译）+ pip 清华源 | Dockerfile §4 |
| node + npm | Node v24 LTS（npmmirror 二进制自动取最新 24.x） | Dockerfile §3 |
| go + go 包 | Go 最新稳定版（go.dev JSON 自动取）+ GOPROXY=goproxy.cn | Dockerfile §5 |
| 常用工具 jq/rg/yq | apt 装 jq/ripgrep/fzf，yq 单独从 GitHub 下最新版 | Dockerfile §1/§2 |
| AI CLI / local MCP CLI | **不预装**（保持镜像纯净），npm prefix 已指向 `~/.local`，容器内 `npm i -g <cli>` 免 sudo 且落在挂载目录持久化 | compose `./volumes/local-bin` |
| **oracleclient.so + libaio 依赖** | Oracle Instant Client Basic 构建时下载到 `/opt/oracle` + `ldconfig`；libaio 补 `libaio.so.1` 兼容软链接（见 §4.10），构建期 `ldd` 强校验 | Dockerfile §1b / §7 |
| **Oracle 依赖自检** | `test-oracle-instantclient`（容器内 PATH 可执行）：ldd + ctypes + python-oracledb thick | `test-oracle-instantclient.sh` |
| 全局 skills 目录持久化 | `~/.config/opencode/skills` 随 `./volumes/opencode-config` 挂载 | compose `volumes` |
| 容器 HOME 说明文档 | `config/HOME-README.md` → 镜像内 `/home/coder/README.md` | Dockerfile §10b |
| 一键 up/down | docker compose 编排 + healthcheck | docker-compose.yaml |
| 离线分发 | `docker save \| gzip` 出带架构标识的 tgz + sha256 | build.sh / action.yml §5 |

## 3. 镜像分层设计（Dockerfile 段落结构）

```
codercom/code-server:latest        ← 官方镜像（Debian 13, code-server 4.141.0）
 ├ §1  apt 系统依赖               jq/rg/fzf/vim/python3/build-essential 等
 ├ §1b Oracle 运行时依赖          libaio(+libaio.so.1 兼容软链接) / libnsl
 ├ §2  yq                         GitHub 最新版（apt 源里没有）
 ├ §3  Node v24 LTS               npmmirror 二进制 tarball → /usr/local
 ├ §4  Python 3.13                python-build-standalone 预编译 → /usr/local
 ├ §5  Go 最新稳定版              go.dev 官方 tarball → /usr/local/go
 ├ §6  opencode (可选)            INSTALL_OPENCODE=true 时 → /usr/local/bin/opencode
 ├ §7  Oracle Instant Client      锁定 21c → /opt/oracle + /opt/oracle/VERSION
 │                                + ldconfig + ldd 强校验
 ├ §8  国内镜像源配置             npm(npmmirror) / pip(清华) / GOPROXY(goproxy.cn)
 ├ §9  环境变量 + 登录 shell PATH 修复（PATH 首位为 /opt/opencode/bin）
 ├ §9b 用户 shell 配置            config/bashrc → /home/coder/.bashrc
 ├ §10 预置目录                   project / .config/opencode/{skills,agent,command}
 │                                / go / /opt/opencode/bin
 ├ §10b 工具脚本与文档            test-oracle-instantclient / ~/README.md
 └ §11 运行身份                   USER coder + 官方 ENTRYPOINT 原样保留
```

**设计原则**：镜像只含**运行时**，不含任何项目依赖（已实测：pip 仅
pip/setuptools、npm -g 仅 npm 自身、Go 模块缓存为空）。所有第三方依赖由
用户按 §6 的离线方案自行安装，装出来的内容全部落在挂载目录，重建容器不丢。

## 4. 关键踩坑与决策记录（重要！改镜像前必读）

### 4.1 基础镜像已是 Debian 13 (trixie)，不是 Ubuntu
- `libaio1` 在 trixie 改名 `libaio1t64` → 见 **§4.10**（不只是改名，SONAME 也变了）
- apt 源是 `deb.debian.org`，换源 sed 要覆盖它

### 4.2 apt 镜像源不可靠
- 阿里云源出现 404/连接失败，官方源反而快 → **默认用官方源**（`ARG APT_MIRROR` 留空），
  并写入 `Acquire::Retries "6"` 抗网络抖动。网络真不通时再显式换源

### 4.3 npm prefix 绝不能写 `~/.npmrc`
- coder 的 HOME 就是工作区根目录，npm 会把 `~/.npmrc` 当**项目级配置**，
  prefix 出现在项目配置里直接报错 `config prefix cannot be changed`
- 正确做法：prefix + registry 写进 `/usr/local/etc/npmrc`（npm 全局配置），
  用户级 `~/.npmrc` 只留 registry

### 4.4 永远不要覆盖官方 ENTRYPOINT
- 官方镜像 `USER=1000` 直接运行，且 `--bind-addr 0.0.0.0:8080` 是官方
  ENTRYPOINT 参数的一部分。自定义 ENTRYPOINT 会**丢失默认参数**，导致
  以 root 身份运行且只监听 127.0.0.1（服务外面连不上）
- 正确做法：保留官方入口；Linux 宿主机上 compose 自动创建的 root 属主目录
  由官方 `fixuid`（setuid 二进制）在启动时自动 chown 给 coder，无需手写脚本

### 4.5 登录 shell 的 PATH 会被 /etc/profile 重置
- 现象：`docker exec sh -c 'go version'` 正常，但 code-server 网页终端里
  `go` 提示 Unknown command
- 根因：`/etc/profile` 无条件覆盖 PATH，冲掉 Dockerfile `ENV PATH` 里的
  `/usr/local/go/bin` 和 `~/.local/bin`
- 修复：镜像内写入 `/etc/profile.d/dev-path.sh`（export 两个路径）
- **补充（本次新增）**：code-server 网页终端是**非登录交互 shell**，根本不读
  `/etc/profile`，只读 `~/.bashrc` → PATH 在 `config/bashrc` 里再导出一次，双保险

### 4.6 code-server 自带会话记忆，不要动 WORKDIR
- 曾把 WORKDIR 改成 project 目录想让登录后默认打开项目区，实测发现
  code-server 本来就会打开**上次会话的目录**，该修改已撤回。WORKDIR 保持 `/home/coder`

### 4.7 预编译运行时的选择
- **Python**：Debian 仓库只有 3.13，用 astral 的 python-build-standalone
  预编译包（解压到 /usr/local，`/usr/local/bin/python3` 优先于系统 3.13，
  自带 pip，venv 可用）。注意 release 里还有 free-threaded 变体，grep 时要排除
- **Node**：npmmirror 同步全部官方版本，直接下 tarball（不用 NodeSource apt）
- **Go**：`https://go.dev/dl/?mode=json` 构建时取最新稳定版，失败回退阿里云镜像
- 三个运行时都可用 build-arg 固定版本（`NODE_VERSION` / `PYTHON_URL` / `GO_VERSION`）

### 4.8 shell 语法细节
- 子 shell 不能收参数：`(curl A || curl B) -o file` 是语法错误，
  `-o` 必须写进每个 curl

### 4.9 构建机环境差异
- Windows Docker Desktop 构建：build context 内文件全部变 755，属官方安全提示可忽略
- 本机 docker CLI 缺 compose/buildx 插件时：`docker compose images` 不可用，
  打包脚本 3-A 需手动等效执行（见 §7）

### 4.10 ⚠ libaio 坑：Debian 13 不只是"改名"，SONAME 也变了（本次修复）

**现象**：容器里 Oracle Instant Client 报
`libaio.so.1: cannot open shared object file`；python-oracledb thick 模式报
`DPY-3010` / `DPY-3012`。

**根因**：Oracle 的 `libclntsh.so` 链接的是 **SONAME `libaio.so.1`**，而 Debian 13
(trixie) / Ubuntu 24.04 的 **time64 迁移**把包 `libaio1` 改名 `libaio1t64`，并把
共享库文件名/SONAME 一起改成了 **`libaio.so.1t64`**。所以：
- `apt-get install libaio1t64` 会"成功"，`dpkg -l` 能看到包
- 但 Oracle 二进制按 `libaio.so.1` 查库 → 找不到 → 报错

**修复**（Dockerfile §1b）：装包后统一补出兼容软链接，再 `ldconfig`：

```bash
AO=$(find /usr/lib /lib -name 'libaio.so.1t64' -type f | head -1)
ln -sf "$AO" "$(dirname "$AO")/libaio.so.1"
ldconfig
```

libaio 的 ABI 未受 time64 影响，软链接即可，不需要换发行版/降级/装源码。

**防回归**：在 Dockerfile §7 末尾加**构建期强校验** —— `ldd libclntsh.so` 输出里
出现任何 `not found` 直接 `exit 1`，构建失败。这样同类问题不可能再漏到运行时。

**复验**：容器内 `test-oracle-instantclient --skip-pip`（离线可用，走 ldd + ctypes）。

### 4.11 Oracle Instant Client 版本策略：锁定 21c

- **已按需求把版本锁定为 21c (21.23.0.0.0)**，不再"自动取最新"：
  - x86_64 → `instantclient-basic-linux.x64-21.23.0.0.0dbru.zip`
  - arm64 → Oracle **从未发布 21c 的 arm64 包**，Dockerfile 自动降级 19c (19.32) 并在构建日志告警
- 版本标记烧录到 `/opt/oracle/VERSION`（两行：版本标签 + 下载 URL），
  `test-oracle-instantclient` 会打印，便于运维核对线上镜像到底是哪个版本

### 4.12 Oracle 11g (11.2) 无法匿名下载

- 公开直链 `download.oracle.com/otn_software/linux/instantclient/` 只剩
  **19c / 21c / 23ai**
- 11.2 的路径 `otn/linux/instantclient/112040/...` 会 **302 跳转到 Oracle 账号登录页**
- 因此 CI 里无法自动拉 11.2 包。需要时：登录 OTN 手动下载 → 放内网 HTTP →
  `--build-arg OIC_URL=<地址>`（Actions 里用 `oic-url` 输入）
- **依赖侧无需改动**：libaio 修复与客户端版本无关（11g/19c/21c 一样需要 `libaio.so.1`）

### 4.13 opencode 二进制位置与"可选预装"（本次新增）

- 两个位置，**`/opt/opencode/bin` 在 PATH 中优先于 `/usr/local/bin`**：

  | 容器路径 | 来源 | 用途 |
  |---|---|---|
  | `/opt/opencode/bin/opencode` | compose 卷 `./volumes/opencode-binary` | **热升级**：换文件即可生效（目录 bind mount 实时可见），不重建镜像 |
  | `/usr/local/bin/opencode` | 镜像烧录（仅 `INSTALL_OPENCODE=true`） | 兜底 |

- 已实测：往 `./volumes/opencode-binary/` 放一个可执行文件 `opencode`，容器内
  `command -v opencode` 立刻解析到 `/opt/opencode/bin/opencode`，**无需重启容器**

- `INSTALL_OPENCODE` 默认 **false**：镜像默认不含 opencode，避免每次升级都要重建 3GB+ 镜像
- Dockerfile 用 `COPY opencode-bin-cli/ /tmp/...` + `RUN` 条件安装，**不能用
  `COPY opencode-bin-cli/opencode-* /usr/local/bin/opencode`**：通配无匹配时构建直接失败
- 因此 `opencode-bin-cli/` 目录**必须始终存在**（保留 `.gitkeep`，见 `.gitignore`），
  源码包里也要保留这个占位文件，否则解包后重建会失败

### 4.14 ⚠ opencode 全局配置目录名：`~/.config/opencode`，不是 `.opencode`（本次修复）

**现象**：早期版本把全局配置目录写成 `~/.config/.opencode`，opencode 根本读不到里面的
`opencode.json` / skills —— 看起来"配置放了但没生效"。

**根因**：opencode 有两个作用域，目录名**不一样**：

| 作用域 | 配置目录 | 备注 |
|---|---|---|
| **全局** | `~/.config/opencode/` | 官方文档特别标注 "**NOT ~/.opencode/**"，也**没有**前导点的 `.opencode` |
| 项目级 | `<项目根>/.opencode/` | 带点，随项目走，可提交 Git |

容易混淆是因为 `.opencode` 这个名字**只属于项目级**（项目里的 `.opencode/skills` 等），
而全局必须是 `opencode`。

**修复点**（三处必须同时改，漏一处就会挂到空目录上）：

1. `Dockerfile §10` 预置目录：`~/.config/opencode/{skills,agent,command}`
2. `docker-compose.yaml` 卷目标：`./volumes/opencode-config:/home/coder/.config/opencode`
3. 文档（README / DESIGN）里的路径描述

**补充约定**：子目录推荐复数（`skills/` `agent/` 与 `agents/` 都支持，单数向后兼容）；
登录态不在配置目录里，而在 `~/.local/share/opencode/auth.json`（已由 opencode-share 卷持久化）。
配置**只在启动时加载一次**，改完必须重启 opencode。

## 5. 持久化设计（compose）

所有挂载统一放在宿主机 `./volumes/` 下；`config/bashrc` 与 `config/HOME-README.md`
是唯一的例外（随仓库走的配置文件，前者挂载进容器、后者烧录进镜像）：

| 宿主机路径 | 容器路径 | 内容 |
|---|---|---|
| `config/bashrc` | `/home/coder/.bashrc` **和** `/root/.bashrc` | 用户 shell 配置（同一份文件挂两处） |
| `volumes/workspace` | `/home/coder/project` | 项目代码（含 venv/node_modules/vendor） |
| `volumes/code-server-data` | `~/.local/share/code-server` | VSIX 扩展、用户数据 |
| `volumes/code-server-config` | `~/.config/code-server` | code-server 配置 |
| `volumes/opencode-binary` | `/opt/opencode/bin` | **opencode 二进制（热升级）** |
| `volumes/opencode-config` | `~/.config/opencode` | opencode 全局配置 + 全局 skills/agent/command |
| `volumes/opencode-share` | `~/.local/share/opencode` | opencode 状态/会话 |
| `volumes/opencode-cache` | `~/.cache/opencode` | opencode 缓存 |
| `volumes/local-bin` | `~/.local` | npm 全局安装点（AI CLI / MCP CLI） |
| `volumes/npm-cache` | `~/.npm` | npm 下载缓存（离线安装用） |
| `volumes/pip-cache` | `~/.cache/pip` | pip 下载缓存 |
| `volumes/python-wheels` | `~/wheels` | 离线 wheel 投放目录 |
| `volumes/go-workspace` | `~/go` | GOPATH（pkg/mod 模块缓存） |

要点：
- `~/.config/opencode` **单独挂载**，不能整体挂 `~/.config`（会互相吞掉）
- 全部 bind mount，`docker compose down` / 容器重建 / 换镜像均不丢数据
- 首次 `up` 自动建目录，属主由 fixuid 自动修正，**禁止手动 chown 脚本**
- `config/bashrc` 是**已入库的普通文件**（不是目录挂载），所以首启就有内容；
  若 coder 无写权限，服务器上 `sudo chown 1000:1000 config/bashrc` 一次即可

> **为什么 `~/.bashrc` 要同时挂 `/root/`？** 镜像以 `coder`(uid 1000) 运行，
> `~/.bashrc` 实际是 `/home/coder/.bashrc`。用户习惯里"容器的 ~"常被理解为
> `/root`，且 `docker exec -u root` 会读 `/root/.bashrc` —— 两个位置挂同一份文件，
> 两种用法都持久化，不会各自为政。

## 6. 离线装依赖（在线收集 → 传入挂载目录 → 容器内离线安装）

**原则：镜像不动，依赖随数据走。**

### Python (pip)
```bash
# 在线机（同一镜像容器内收集, 保证 .whl 与容器 glibc 匹配）
docker run --rm -v ./volumes/python-wheels:/home/coder/wheels -w /home/coder/wheels \
    vscode-webai:latest pip download -r requirements.txt -d /home/coder/wheels
# → ./volumes/python-wheels 整目录拷到服务器
# 容器内装进项目 venv（venv 在 ./volumes/workspace 下, 天然持久化）
python3 -m venv /home/coder/project/myapp/.venv
/home/coder/project/myapp/.venv/bin/pip install --no-index \
    --find-links=/home/coder/wheels -r requirements.txt
```

### Node (npm)
- 方案 A（推荐）：在线机同一容器里 `npm install`，`node_modules` 随项目整体打包
  （同镜像同平台，原生编译二进制完全兼容）
- 方案 B：在线装一次填满 `./volumes/npm-cache` → 拷服务器 → `npm install --offline`
- 全局 CLI：`npm i -g <cli>` 直接落 `./volumes/local-bin`，免 sudo 持久化

### Go
- 方案 A（推荐）：`go mod vendor`，vendor/ 进项目目录随项目打包，构建自动使用
- 方案 B：`go mod download` 后模块缓存就在 `./volumes/go-workspace/pkg/mod`，
  整目录拷贝，离线构建 `GOPROXY=off go build ./...`

## 7. 构建 / 打包 / 发布流程

### 7.1 构建（构建机在线）
```bash
./build.sh                        # = docker build + docker save 出未压缩 tar
# 固定版本 / 预装 opencode / 指定 Oracle 客户端:
docker build \
    --build-arg NODE_VERSION=24.13.1 --build-arg GO_VERSION=1.27.2 \
    --build-arg APT_MIRROR= --build-arg INSTALL_OPENCODE=true \
    --build-arg OIC_URL= \
    -t vscode-webai:latest .
```
- 默认构建 `linux/amd64`；ARM64 时 `--platform linux/arm64`（Dockerfile 已按
  TARGETARCH 自动切换资源），强烈建议找原生 ARM 机器构建，QEMU 模拟极慢
- `opencode-bin-cli/` 目录必须先 `mkdir -p`（Dockerfile 有 `COPY`）；
  预装时把二进制放成 `opencode-bin-cli/opencode`
- 构建结束前会自动校验 Oracle 客户端依赖（`ldd` 无 `not found`）

### 7.2 打包（repo-deploy-packager Skill 规范）
```
results/<项目名>/<项目名>_docker-images_<os>-<arch>.tgz   ← docker save | gzip
results/<项目名>/<项目名>_source-code_<os>-<arch>.tgz     ← 最小源码包
results/<项目名>/<项目名>_sha256_<os>-<arch>.txt          ← 校验和
logs/<项目名>_save.log / _tar.log / _pack.log              ← 全过程日志
```
- **文件名强制带 `<os>-<arch>` 后缀**（多架构产物同目录不混淆）
- 源码包含：Dockerfile、docker-compose.yaml、**config/bashrc**、
  **config/HOME-README.md**、**test-oracle-instantclient.sh**、README.md、DESIGN.md、
  build.sh、.dockerignore、**opencode-bin-cli/.gitkeep**（目录占位，缺了重建会失败）；
  大文件（opencode 二进制、中间 tar）一律不入包
  > 注意 action.yml 打包源码时的排除规则用的是**basename**（`--exclude='opencode'`、
  > `--exclude='opencode-linux-*'`），所以只剔除二进制本体，`.gitkeep` 会保留下来。
- 验收清单：tgz 可 `docker load` 回载且镜像 ID 与构建一致 / 源码可解包、无 .git /
  `config/` 与 `opencode-bin-cli/.gitkeep` 都在 / sha256 已记录

### 7.3 发布（三选一，可并存）
1. **离线 tar**：`results/*.tgz` 直接拷贝到服务器，`docker load -i`（兜底方案）
2. **内网 registry**：挑一台常开服务器跑 `registry:2` 容器，构建机
   `docker tag` 后 push，其他服务器 pull（完全离线内网；HTTP 需配
   insecure-registries，生产建议加 TLS）
3. **云 registry 备份**：腾讯云 TCR / 阿里云 ACR 个人版免费，推一份异地容灾；
   国内公共加速器只支持拉取转发，**不能推送**

### 7.4 服务器部署
```bash
docker load -i vscode-webai_docker-images_linux-amd64.tgz
# 把 source-code 包解到部署目录（compose + config/ 就在其中）
docker compose up -d          # 停止: docker compose down（数据不丢）
# 浏览器访问 http://<服务器IP>:8080，密码在 compose 的 PASSWORD（默认 root1234）
```

宿主端口用 `CODE_SERVER_PORT` 覆盖（容器内恒为 8080）；临时用环境变量，长期用项目根目录的
`.env`（compose 自动读取，该文件已在 `.gitignore`，服务器不需要它）：

```bash
CODE_SERVER_PORT=8081 docker compose up -d
# 或: echo 'CODE_SERVER_PORT=8081' > .env
```

**关于 `down` 的边界**：`docker compose down` 只作用于**本项目**（compose 项目名 =
目录名 `vscode-webai`）的容器与网络，不会影响宿主机上其它 compose 项目；本项目不使用
命名卷（全是 bind mount），所以 `down` 本身不会删数据，`down -v` 也无卷可删。
另注：宿主机上如果 8080 已被别的服务占用（例如同时跑着 Dify 的 nginx），
要用 `CODE_SERVER_PORT` 换端口，不要去停别人的容器。

## 8. 常用验证命令（容器内）

```bash
opencode --version && go version && node -v && python3 --version
jq --version && rg --version && yq --version && fzf --version
ls /opt/oracle/instantclient/libclntsh.so    # Oracle 库
test-oracle-instantclient                     # Oracle 依赖 + python-oracledb 自检
test-oracle-instantclient --skip-pip          # 离线版: 只查依赖
npm config get registry                      # npmmirror
go env GOPROXY                               # goproxy.cn
bash -lc 'go version'                        # 登录 shell PATH 修复生效
bash -ic 'go version'                        # 交互 shell (.bashrc) PATH 生效
```

## 9. 当前版本基线（linux/amd64 实测，2026-10-13）

| 组件 | 版本 | 备注 |
|---|---|---|
| code-server | 4.141.0 | 跟随官方 latest（会随上游漂移） |
| opencode | 可选（示例 1.18.29） | 默认**不预装**；由 `./volumes/opencode-binary` 卷在运行时提供，版本随你放的二进制 |
| Node.js | v24.21.0 (LTS) | 自动取 24.x 最新，ARG 可固定 |
| Python | 3.13.16 (pip 26.2.1) | 自动取 3.13.x 最新，ARG 可固定 |
| Go | 1.27.2 | 自动取最新稳定版，ARG 可固定 |
| Oracle Instant Client | **21c (21.23.0.0.0)** 已锁定 | 指定版本；arm64 无 21c 包自动降级 19c；`OIC_URL` 可覆盖（11g 需 OTN 登录下载） |
| oracle 运行时依赖 | libaio.so.1 + libnsl | §4.10 已修复 Debian 13 t64 改名问题 |

> Node / Python / Go 默认"构建时取最新"，上表是某次实测值；精确复现请用
> `NODE_VERSION` / `PYTHON_URL` / `GO_VERSION` 固定。

ARM64 版本尚未构建；构建方法见 §7.1。

## 10. FAQ

**Q: 宿主机命令行输入 `go` 提示 Unknown command？**
正常。Go 只在容器内（`/usr/local/go/bin/go`）。用 code-server 网页终端或
`docker exec -it vscode-webai bash`。

**Q: `opencode: command not found`？**
默认构建不含 opencode。把二进制放到宿主机 `./volumes/opencode-binary/opencode`
再 `docker compose up -d`；或构建时勾选 `install-opencode` 烧进镜像。

**Q: 为什么镜像里不预装 agent-browser / open-code-review 等工具？**
保持镜像纯净、避免随依赖膨胀。npm prefix 已指向挂载目录，`npm i -g` 装完
即持久化，重装容器不丢。

**Q: 密码写在哪？**
compose 的 `PASSWORD` 环境变量（明文，默认 `root1234`），生产建议改掉默认值或换 `HASHED_PASSWORD`。

**Q: 改了 `config/bashrc` 之后为什么容器里没生效？**
直接编辑宿主机文件是**即时生效**的（bind mount 同一 inode）。只有当你用
`git pull` / 覆盖写的方式换掉整个文件（换了 inode）时才需要 `docker compose up -d` 重建容器。

**Q: opencode 的全局配置/skills 放 `~/.config/.opencode` 里完全没生效？**
路径错了。全局配置目录是 **`~/.config/opencode`（无前导点）**；带点的 `.opencode` 只用于
**项目级**（`<项目根>/.opencode/`）。详见 §4.14。另外配置只在 opencode 启动时加载一次，
改完要重启 opencode 进程。

**Q: 首次部署后 `~/.config/opencode` / `~/.local/bin` 是空的？**
空挂载目录会遮住镜像里预建的子目录。想立刻有标准结构，在宿主机执行一次：
`mkdir -p volumes/opencode-config/{skills,agent,command}`；
`~/.local/bin` 不用管，`npm i -g` 会自动创建。

**Q: 宿主机 8080 被占用（比如同时跑 Dify），怎么换端口？**
`CODE_SERVER_PORT=8081 docker compose up -d`，或写进项目根目录的 `.env`。
**不要**去停宿主机上别的 compose 项目。详见 §7.4。

**Q: `docker compose down` 会不会影响宿主机上其它项目 / 丢数据？**
不会。`down` 只删除本项目（项目名 = 目录名 `vscode-webai`）的容器和网络；
本项目全是 bind mount、没有命名卷，数据在 `./volumes/` 与 `./config/`，`down` 之后依然完好。
