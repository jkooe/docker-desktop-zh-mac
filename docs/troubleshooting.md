# 故障排查

按症状查找。**遇到任何问题，第一步都是**：

```bash
./diagnose.command
```

它会一次性输出系统信息、Docker 定位与版本、工具链、写入权限、安装状态、备份清单。
提 issue 时请把完整输出贴上去。

---

## A. 脚本阶段报错

### A1. `没有权限更新 macOS asar 完整性校验`

**完整报错**（来自上游 DDCS）：

```
ERROR : 文件复制时出错: 没有权限更新 macOS asar 完整性校验，请使用管理员权限运行脚本: 
/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/Info.plist
```

**这不是文件权限问题。** 你去查会发现属主、标志位、ACL 全都正常：

```bash
$ ls -l  ".../Info.plist"
-rw-r--r--@ 1 you staff 3444 ... Info.plist      # 属主可写
$ ls -lO ".../Info.plist"                        # 无 uchg/schg
$ ls -le ".../Info.plist"                        # 无 ACL
$ [ -w ".../Info.plist" ] && echo writable
writable                                          # ← 假的！test -w 不查 TCC
```

真相是 macOS 的 **TCC「应用管理」权限**（`kTCCServiceAppManagement`）在拦：
**非授权进程不得改写其他 App 包内的文件。**

#### 解决办法

1. 打开「系统设置」
2. 进入「隐私与安全性」→「应用管理」
3. 找到你正在用的终端程序，打开右侧开关
   - 用的是「终端」→ 找 **终端 / Terminal**
   - 用的是 iTerm2 → 找 **iTerm**
   - 用的是 VS Code 集成终端 → 找 **Visual Studio Code**
4. **按 ⌘Q 完全退出该程序**（只关窗口不生效 —— TCC 权限在进程启动时读取）
5. 重新打开，重新运行 `./install.command`

#### 如果「应用管理」列表里找不到你的终端

先执行下面这行来触发系统弹窗：

```bash
touch "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/Info.plist"
```

弹窗点「好」，这个 App 就会出现在列表里，再去打开开关。

> 也可以换个思路：直接用「终端」App 跑脚本（它通常已经在列表里），
> 或把 `.command` 文件在 Finder 里**双击**运行 —— 双击默认走「终端」。

#### 为什么脚本不能自己弹窗要权限

TCC 弹窗只能由**触发操作的那个进程**引发，且授权后**必须重启进程**才能生效。
脚本自己无法完成「弹窗 → 授权 → 重启自身」这个循环，所以只能提示用户手动做。

---

### A2. `警告：翻译表是按 4.91.0 生成的，本机为 X.Y.Z`

翻译表是**按版本**维护的（Docker 前端把界面文字硬编码在 JS bundle 里，版本一变字符串就变）。

**通常仍能汉化**，只是新增或改动过的界面可能显示异常。两个选择：

- 先跑，跑完看界面是否正常；不正常就 `./restore.command` 回滚
- 去上游 <https://github.com/asxez/DDCS/releases> 看有没有对应版本的成品包

---

### A3. `缺少必需工具：python3 (>= 3.8)` / `node`

```bash
# 有 Homebrew 的话
brew install python node

# 或者去官网下载
# Python:  https://www.python.org/downloads/macos/
# Node.js: https://nodejs.org/zh-cn/download
```

装完开个新终端再试（PATH 需要刷新）。

---

### A4. 下载上游源码失败

脚本用 `curl` 拉取 `github.com/asxez/DDCS`。网络受限时：

```bash
export DDZ_PROXY=http://127.0.0.1:7890    # 换成你自己的代理
./install.command
```

`curl` 和 `npm` 都会自动读取 `https_proxy` / `HTTPS_PROXY` 环境变量，
所以如果你已经在 shell 配置里导出过代理，通常不用管。

---

### A5. `asar 安装失败`

`npm install` 失败通常是 registry 网络问题。可以临时换源：

```bash
npm config set registry https://registry.npmmirror.com
./install.command
```

装完后 `asar` 会落在项目内 `.ddcs/node_modules/.bin/asar`，**不污染全局环境**。

---

### A6. `Docker Desktop 未能完全退出`

脚本会先 `osascript quit`，再轮询 40 秒，最后 `pkill`。
若仍失败，通常是有 Docker 相关的弹窗对话框卡住了。手动处理：

```bash
# 看一眼还有哪些相关进程
pgrep -lf "Docker"

# 手动退出
osascript -e 'quit app "Docker"'
# 或直接在菜单栏 🐳 → Quit Docker Desktop
```

确认托盘图标消失后再跑脚本。

---

## B. 汉化后 Docker Desktop 起不来

### B1. `Integrity check failed for asar archive`

`Info.plist` 里的哈希与实际 `app.asar` 不匹配。**立即回滚**：

```bash
./restore.command
```

然后跑一次 `./diagnose.command` 确认「完整性」一项显示「两者一致」。

### B2. 界面白屏 / 部分错乱

多半是翻译表版本不匹配（见 A2）。
先回滚确认原版能正常工作：

```bash
./restore.command
```

### B3. 完全没反应 / Dock 图标跳一下就消失

```bash
# 看 Docker 自己的日志
tail -100 ~/Library/Containers/com.docker.docker/Data/log/host/com.docker.backend.log
# 或者
~/Library/Group\ Containers/group.com.docker/log/
```

同时回滚到原版对照验证。

---

## C. 回滚相关

### C1. `找不到可用的官方原版备份`

说明 `backups/` 里没有 `STATE=original` 的目录。检查：

```bash
./restore.command --list
cat backups/*/STATE
```

- 有备份但 `STATE` 是 `unknown` / `forced` → 那份备份本身就不是英文原版，
  恢复后仍是中文。**需要重装 Docker Desktop** 才能拿到英文原版。
- 完全没有备份 → 同上，重装。

### C2. 回滚后还是中文

同上 —— 备份的内容本身就是汉化版。重装 Docker Desktop。

### C3. 备份自检未通过

`SHA256SUMS.txt` 与文件不匹配，说明备份在磁盘上损坏了或被改动过。
脚本会提示你确认后继续。更稳妥的做法是：

```bash
# 看看另一份备份是否可用
./restore.command --list
./restore.command --from backups/<另一份>
```

---

## D. 汉化「消失」了

### D1. Docker Desktop 更新后界面变回英文

**这是预期行为** —— 更新会覆盖 `app.asar`。重新跑：

```bash
./install.command
```

此时 `app.asar` 已回到官方版本，脚本会判定为 `original` 并**新建**一份备份，
**旧的备份目录不会被删除**（`backups/` 里会有多份，可以手动清理旧的）。

### D2. 想彻底卸载本工具

```bash
./restore.command     # 先恢复英文原版
cd ..
rm -rf docker-desktop-zh-mac
```

`backups/` 会随目录一起删掉。如果想留一手，先把 `backups/` 挪到别处。

---

## E. 其他

### E1. 双击 `.command` 一闪而过，看不到报错

macOS 的 `com.apple.quarantine` 属性导致的。任一方案：

```bash
# 方案一：去掉隔离属性
xattr -d com.apple.quarantine ./install.command

# 方案二：右键 → 打开 → 在弹窗里点「打开」

# 方案三：直接从终端跑，能看到完整输出
./install.command
```

### E2. `Operation not permitted`，且终端已在「应用管理」里

检查是否有安全软件在拦截（某些企业的 EDR / 终端管控会阻止对 `/Applications` 的写入）。
尝试：

```bash
# 确认 SIP 状态（正常应为 enabled）
csrutil status
```

### E3. 想确认自己用的是官方原版还是汉化版

```bash
./diagnose.command
```

看「原版性」一项：

- `指纹与官方一致` → 是官方原版
- `指纹与官方不符` → 已被改写（汉化过）
- `无法判定` → 指纹表里没有你这个版本，欢迎按 README 里的方法提交指纹

### E4. `app.asar.unpacked` 里的 `package.json` 为什么和官方不一样

上游重打包的副作用，详见 [`how-it-works.md` 第 5 节](how-it-works.md#5-汉化流程上游-ddcs-做什么)。
本工具在汉化后会自动把它改回官方版本，输出里会有一行：

```
修正 app.asar.unpacked（对齐官方原版）……
  ✓ 已修正 1 个文件
```

如果看到 `✓ 无需修正`，说明本来就是一致的。
