# docker-desktop-zh-mac

把 **Docker Desktop（macOS）的界面汉化成中文** —— 带完整备份、状态判定与一键回滚的安全包装。

> 这是一个「胶水 + 安全网」项目：翻译数据来自开源项目 [asxez/DDCS](https://github.com/asxez/DDCS)，
> 本仓库在它外面加上了**备份、原版判定、权限预检、完整性校验、回滚**这一整圈保障。

---

## 它解决什么问题

网上的 Docker Desktop 汉化教程大多只讲「怎么改」，不讲「改坏了怎么办」。
而 macOS 上的 Docker Desktop 有两个很容易踩的坑：

1. **改完直接起不来。**
   Docker Desktop 4.76.0 起，Electron 会校验 `app.asar` 的哈希
   （记录在内层 `Info.plist` 的 `ElectronAsarIntegrity` 字段里）。
   改了界面文件却不同步这个哈希，Docker 会以 `Integrity check failed for asar archive` 拒绝启动。
   注意这是 **Electron 自己的校验，跟 macOS 代码签名/公证无关** ——
   所以网上那些「ad-hoc 重新签名」的做法在这里既不必要、还会帮倒忙。

2. **手一抖就把唯一的原版备份覆盖了。**
   第二次运行汉化脚本时，如果脚本无脑「先备份再改」，备份下来的就是**已经汉化过的那份**，
   英文原版就此永久丢失，之后再想回滚也回不去了。

本项目针对性地处理了这两点，并额外送上一圈排障工具。

## 特性

- ✅ **一键汉化 / 一键回滚**：双击 `.command` 文件即可，不需要记命令
- ✅ **双重状态判定**：分别回答「能不能启动」和「是不是官方原版」两个不同的问题
  - *完整性*：`Info.plist` 记录哈希 vs `app.asar` 实际哈希 —— 决定 Electron 会不会拒绝启动
  - *原版性*：`app.asar` 文件指纹 vs 官方指纹表 —— 决定备份能否用于回滚到英文原版
- ✅ **原版保护**：确认是官方原版才生成新备份；已汉化时**复用**旧备份，绝不覆盖
- ✅ **权限预检**：动手前先真实试写，提前发现 macOS「应用管理」授权缺失，
  避免跑到一半失败、留下半改状态
- ✅ **完整性自检**：汉化后立即核对两个哈希，不一致就明确提示回滚
- ✅ **备份可校验**：每份备份带 `SHA256SUMS.txt`，回滚前自动校验
- ✅ **环境诊断**：`diagnose.command` 输出一份完整报告，提 issue 直接贴它
- ✅ **依赖隔离**：Python 用项目内 `.venv`，`asar` 局部安装，不碰系统环境，不执行 `npm install -g`

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | macOS（本项目只支持 macOS） |
| CPU | Apple Silicon (arm64) **已在 4.91.0 上完整验证**；Intel 未验证 |
| Docker Desktop | 4.76.0 或更高（更早的版本没有 asar 完整性校验，本包装仍可用但没必要） |
| Python | 3.8+（`python3 --version`） |
| Node.js | 任意 LTS（需要能装 npm 包） |
| 磁盘 | 约 100 MB（源码 + 依赖 + 一份备份） |

## 快速开始

```bash
git clone https://github.com/jkooe/docker-desktop-zh-mac.git
cd docker-desktop-zh-mac
```

然后 **在 Finder 里双击 `install.command`**。

首次运行会自动下载上游脚本、创建虚拟环境、安装 `asar`（约 1 分钟），
之后每次运行都很快。脚本会提示你确认，输入 `y` 回车即可。

> **首次运行前建议先跑一次 `diagnose.command`**，确认环境与权限都没问题。

## 用法

### 汉化

```bash
./install.command              # 交互式，会先确认
./install.command --yes        # 无人值守（适合脚本化）
./install.command --force      # 强制用当前文件生成备份（见下方风险说明）
```

### 回滚到英文原版

```bash
./restore.command              # 交互式
./restore.command --list       # 只列出所有备份，不改动任何文件
./restore.command --from backups/4.91.0-20260917-181437
./restore.command --yes
```

### 诊断

```bash
./diagnose.command
```

只读检查：系统信息、Docker 定位与版本、工具链、写入权限、安装状态、备份清单。
遇到问题请先跑它，并把完整输出贴到 issue 里。

### 自定义安装位置

若 Docker Desktop 不在 `/Applications`：

```bash
DDZ_DOCKER_APP="$HOME/Applications/Docker.app" ./install.command
```

### 网络受限时

脚本用 `curl` 下载上游源码，`npm` 安装 `asar`。
两者都会自动读取 `https_proxy` / `HTTPS_PROXY` 环境变量，也可以显式指定：

```bash
export DDZ_PROXY=http://127.0.0.1:7890
./install.command
```

## 它是怎么工作的

```
install.command
  ├─ [1/7] 环境检查   定位 Docker、探测 python3/node、真实试写测权限
  ├─ [2/7] 工具链     下载 DDCS 源码 → 建 .venv → 局部装 asar
  ├─ [3/7] 状态判定   完整性 + 原版性 → 决定备份方案（不满足条件就早退）
  ├─ [4/7] 关闭 Docker
  ├─ [5/7] 备份官方原版（或复用已有备份）
  ├─ [6/7] 调用上游脚本：解包 asar → 文本替换 → 重打包 → 同步校验哈希
  └─ [7/7] 核对两个哈希 → 启动 Docker
```

核心的替换与打包由上游 DDCS 完成；本项目的价值在**第 1、3、5、7 步**。

细节见 [`docs/how-it-works.md`](docs/how-it-works.md)。

## 风险与注意事项

- **务必先确认能回滚。** 汉化会改写 `/Applications/Docker.app` 内的文件。
  脚本会在动手前备份，并用 `restore.command` 一键还原，但**请先跑一次 `--list` 确认备份确实存在**。
- **不要给 Docker.app 重新签名。** 完整性校验在 Electron 层，重签名解决不了问题，反而可能破坏公证。
- **Docker Desktop 自动更新后汉化会失效**（更新会覆盖 `app.asar`）。
  重新运行 `install.command` 即可。注意此时 `app.asar` 已回到官方版本，
  脚本会识别为「原版」并**新建**一份备份，旧的备份目录不会被删除。
- **`--force` 的危险性**：它会用「当前」的文件生成备份。
  如果当前已经是汉化版，这份备份就**不能**用于回滚到英文原版。
  只有在「你确定不需要回滚」或「已经另行保存了原版」时才用。
- **翻译表按 4.91.0 生成。** 版本不一致时会给出警告但允许继续；
  若界面出现异常，先回滚，再等上游更新对应版本的翻译表。
- **`app.asar.unpacked/` 的已知副作用**：DDCS 重打包时会把 `app/package.json`
  一并放进 unpacked 目录，替换掉官方原有的一个仅含 `{ "type": "commonjs" }` 的标记文件。
  两边文件清单一致（均 13 个），但理论上存在模块解析模式差异的风险。
  实测 4.91.0 正常。介意的话请用上游发布的标准成品包。
- **本项目只改界面文本**，不触碰 Docker 的镜像、容器、数据卷等任何运行数据。

## 常见问题

**Q：汉化后 Docker Desktop 打不开了，报 `Integrity check failed for asar archive`？**
A：`Info.plist` 里的哈希没同步上。立即回滚：`./restore.command`。
如果是自动更新导致的，重跑 `./install.command`。

**Q：脚本报「没有权限更新 macOS asar 完整性校验」？**
A：终端缺少 macOS 的**「应用管理」**授权。这不是文件权限问题 ——
文件属主、标志位、ACL 都是正常的，是系统隐私保护（TCC）在拦。
按脚本提示去「系统设置 → 隐私与安全性 → 应用管理」给你的终端打开开关，
然后 **⌘Q 完全退出终端再重开**（只关窗口不生效），再重试。
详见 [`docs/troubleshooting.md`](docs/troubleshooting.md)。

**Q：怎么确认当前是官方原版还是汉化版？**
A：跑 `./diagnose.command`。它会分别报告「完整性」和「原版性」两项判定。

**Q：回滚后还是中文？**
A：说明那份备份本身就是汉化版（`STATE` 不是 `original`）。
检查 `backups/*/STATE`，或用 Docker 官方安装包重装。

**Q：能汉化 Windows 版吗？**
A：本仓库只做 macOS。上游 DDCS 支持 Windows，请直接用上游。

## 目录结构

```
docker-desktop-zh-mac/
├── install.command          # 汉化（双击运行）
├── restore.command          # 回滚（双击运行）
├── diagnose.command         # 诊断（双击运行）
├── lib/common.sh            # 公共函数库
├── data/
│   └── official-asar-sha256.txt   # 官方 app.asar 指纹表
├── docs/
│   ├── how-it-works.md      # 原理详解
│   └── troubleshooting.md   # 故障排查
├── LICENSE                  # MIT
├── NOTICE                   # 第三方组件声明
├── backups/                 # 备份（运行时生成，已 gitignore）
└── .ddcs/  .venv/           # 工具链（运行时生成，已 gitignore）
```

## 关于翻译数据（上游 DDCS）

界面文本的翻译表、以及解包/替换/重打包的逻辑，全部来自
**[asxez/DDCS](https://github.com/asxez/DDCS)**（作者 ASXE，**GPL-3.0**）。

本仓库**不包含**其任何代码或数据，只在运行时下载并作为独立程序调用。
因此本仓库以 **MIT** 发布；DDCS 本身仍受 GPL-3.0 约束。
详见 [`NOTICE`](NOTICE)。

上游会按 Docker Desktop 版本发布成品汉化包：
<https://github.com/asxez/DDCS/releases> —— 如果你只想赶快用上，
也可以直接去那里下载对应版本，按上游说明操作。

## 贡献

**特别欢迎：提交官方 app.asar 指纹。**

`data/official-asar-sha256.txt` 记录各版本官方 `app.asar` 的 SHA256。
记录越全，「原版性」判定就越准 —— 如果你的 Docker 版本不在表里，
判定结果会是「无法确认」，虽然仍可继续，但不如有指纹来得踏实。

提交方式：在你**未改动过**的 Docker Desktop 上执行

```bash
shasum -a 256 "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/Resources/app.asar"
stat -f %z "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/Resources/app.asar"
defaults read "/Applications/Docker.app/Contents/Info.plist" CFBundleShortVersionString
uname -m
```

然后把四行结果按表格格式加进 `data/official-asar-sha256.txt`，提 PR。

## 免责声明

本项目按「原样」提供，不附带任何明示或暗示的担保。
它**会改写你本机 `/Applications/Docker.app` 内的文件**，请在使用前确认你已理解风险、
并已确认存在可用的官方原版备份。

因使用本项目造成的任何直接或间接损失（包括但不限于 Docker Desktop 无法启动、
需要重装、容器或数据受影响等），作者不承担责任。

本项目与 Docker, Inc. 无任何关联，Docker 及 Docker Desktop 是其各自权利人的商标。
