# 原理详解

本文记录这套工具背后的机制，以及两个最关键的判据是怎么来的。

---

## 1. Docker Desktop 在 macOS 上的目录结构

Docker Desktop for Mac 是一个**双层 `.app`**，很容易找错层级：

```
/Applications/Docker.app                                   ← 最外层（Finder 里看到的）
├── Contents/
│   ├── Info.plist                                         ← 外层版本号在这里
│   ├── MacOS/
│   │   └── Docker Desktop.app                             ← 内层，真正的 Electron 应用
│   │       └── Contents/
│   │           ├── Info.plist                             ← ★ ElectronAsarIntegrity 在这里
│   │           └── Resources/
│   │               ├── app.asar                           ← ★ 界面代码（要改的就是它）
│   │               └── app.asar.unpacked/                 ← 原生模块（.node）
```

所以本工具用到的三个关键路径是：

| 变量 | 路径 |
|---|---|
| `DDZ_APP` | `/Applications/Docker.app` |
| `DDZ_PLIST` | `<内层>/Contents/Info.plist` |
| `DDZ_RES` | `<内层>/Contents/Resources` |

版本号要从**外层** `Info.plist` 读（`defaults read .../Docker.app/Contents/Info.plist CFBundleShortVersionString`），
而 `ElectronAsarIntegrity` 在**内层**。搞混了会拿到空值。

---

## 2. 为什么改完会起不来：asar 完整性校验

从 Docker Desktop **4.76.0** 开始，内层 `Info.plist` 多了一个字段：

```xml
<key>ElectronAsarIntegrity</key>
<dict>
  <key>Resources/app.asar</key>
  <dict>
    <key>algorithm</key><string>SHA256</string>
    <key>hash</key><string>f9b58f58...</string>
  </dict>
</dict>
```

Electron 启动时会：

1. 读取 `app.asar` 的**头部 JSON**（归档索引结构，不是文件内容）
2. 对它做 SHA256
3. 与 `Info.plist` 里记录的 `hash` 比对

**不一致 → 直接拒绝启动**，通常报：

```
Integrity check failed for asar archive
```

### 三个容易踩错的地方

**① 校验的是「头部 JSON 的哈希」，不是「整个文件的 SHA256」。**

```js
// 正确算法
const disk = require('asar/lib/disk');
const crypto = require('crypto');
const header = disk.readArchiveHeaderSync('app.asar').header;
const hash = crypto.createHash('sha256')
  .update(JSON.stringify(header))
  .digest('hex');
```

注意 `JSON.stringify(header)` —— 依赖 `asar` 包对该对象的键序/序列化行为。
所以本项目在安装 `asar` 时**优先使用上游 `package.json` 里声明的版本**，
而不是随便装一个 latest，避免序列化结果漂移。

**② 这是 Electron 自己的校验，与 macOS 代码签名 / 公证无关。**

网上很多教程说「改完要 `codesign --force --deep --sign -` 重新签名」——
在这里**解决不了问题**，反而可能把官方公证签名破坏掉，引出 Gatekeeper 的麻烦。
本工具**不做任何重签名**。

**③ macOS 原生签名校验确实会失败，但 Docker Desktop 能容忍。**

实测汉化后：

```bash
$ codesign --verify --verbose=2 /Applications/Docker.app
/Applications/Docker.app: invalid Info.plist (plist or signature have been modified)
In subcomponent: /Applications/Docker.app/Contents/MacOS/Docker Desktop.app
```

但 Docker Desktop 照常启动 —— 因为它不是 App Store 安装，
Gatekeeper 不做严格校验（`spctl` 的评估在首次运行后就放行了）。

⚠️ **所以不要试图「修好」这个签名。** 重签名会改变签名字节，
而 Electron 的完整性校验与 macOS 签名是两套独立机制 ——
重签名解决不了 `Integrity check failed`，只会再引入一个 Gatekeeper 问题。
本工具**不做任何重签名**。

---

## 3. 「一致性」与「原版性」是两个不同的问题

这是本项目最容易搞混、也最关键的一点。

### 判据一：完整性（能不能启动）

```
Info.plist 里记录的 hash  ==  app.asar 头部实际 hash  ？
```

同步这个哈希之后，**答案总是「一致」** —— 无论改没改过。

所以它只能回答「**Docker 能不能启动**」，**不能**回答「**这是不是原版**」。

> 早期版本的本工具就栽在这里：汉化成功后返回 `pristine`（原版），
> 导致第二次运行时误判为「当前是原版」，差点把汉化版备份当成原版备份覆盖掉。
> 现在用两个独立函数，各自回答一个问题。

### 判据二：原版性（备份能不能用来回滚）

```
app.asar 的文件 SHA256  ==  官方指纹表里的值  ？
```

基准来自两处（按优先级）：

1. **`data/official-asar-sha256.txt`** —— 官方指纹表，按「版本 + 架构」索引
2. **已有的原版备份** —— 如果本地已经存着一份原版，直接拿它比对

三种结论：

| 结论 | 含义 | 后续动作 |
|---|---|---|
| `original` | 确认是官方原版 | 可以安全地新建备份 |
| `localized` | 与已知原版指纹不符，已被改写 | **绝不**新建备份；复用已有原版备份 |
| `unknown` | 指纹表里没有这个版本，且本地没有原版可比对 | 提示用户确认后，允许备份（`STATE=unknown`） |

---

## 4. 备份策略：为什么「先备份再改」是危险的

一个天真的实现是这样的：

```
1. 备份当前 app.asar  →  备份/20260917-1800/
2. 解包、替换、重打包
3. 写回
```

第二次运行时：

```
1. 备份当前 app.asar  →  备份/20260917-1815/   ← 这里备份的是【汉化版】！
```

于是英文原版不但没有第二份，唯一的那份如果被覆盖，就**永久丢失**了。

本项目的做法：

```
判定原版性
├─ original  → 新建备份，STATE=original（这份可以回滚到英文）
├─ localized → 查 backups/ 里有没有 STATE=original 的
│              ├─ 有 → 复用，绝不新建
│              └─ 无 → 中止，要求先重装 Docker 或用 --force 明确接受风险
└─ unknown   → 同上，但允许用户确认后备份（STATE=unknown，明确标注不可靠）
```

`STATE` 只有 `original` 才被当作「可用于回滚到英文原版」。
`restore.command` 也优先挑 `STATE=original` 的那份。

另外，备份时的顺序也是刻意的：
**先判定、再关 Docker、后备份**（`[3/7]` → `[4/7]` → `[5/7]`）。
判定不通过就地退出，不白关一次 Docker。

---

## 5. 汉化流程（上游 DDCS 做什么）

```
cp app.asar 到工作目录
   ↓
asar extract app.asar app         # 解包成普通目录树
   ↓
按翻译表做【纯文本 replace】
   · extract_config.py            # 主表，约 3000 条
   · extract_config_manually.py   # 手工补充，约 100 条
   ↓
asar pack app app.asar --unpack <模式>   # 重打包
   ↓
cp app.asar 回 Resources/
cp app.asar.unpacked 回 Resources/
   ↓
更新 Info.plist 的 ElectronAsarIntegrity（先做可写性检查，通过才动手）
```

### 为什么是「纯文本替换」而不是「改 i18n 资源」

Docker Desktop 的前端**没有做 i18n 抽取** —— 界面文字是硬编码在打包后的
JS bundle 里的字面量。所以没有 `zh-CN.json` 这类文件可以改，
只能对 JS 文本本身做字符串替换。这也是为什么：

- 替换表必须**按版本维护**（版本一变，bundle 里的字符串就变了）
- 极少数动态拼接的句子可能覆盖不到

### `app.asar.unpacked/` 的副作用

`asar pack --unpack` 会重新计算哪些文件需要解包到磁盘。
DDCS 的逻辑是从原始归档读 unpack 清单，但同时也把 `app/package.json` 一起
放进了 unpacked 目录，**覆盖掉官方放在那里的标记文件**：

```
官方：app.asar.unpacked/package.json  =  { "type": "commonjs" }
改后：app.asar.unpacked/package.json  =  完整的 @docker/desktop package.json
                                        （含 "type": "module"）
```

两边的**文件清单完全一致**（4.91.0 均为 13 个文件），只有这一个文件内容不同。
影响是：该目录下的 `.js` 会被 Node 按 ESM 而不是 CommonJS 解析。
该目录里主要是 `.node` 原生模块（通过 `process.dlopen` 加载，不受 `"type"` 影响），
所以实测 4.91.0 没有出现问题。

不过既然我们手上有官方原版备份，本项目会在汉化后**顺手把它改回官方版本**，
让 `app.asar.unpacked/` 与官方完全一致 —— 见 `ddz_sync_unpacked_from_backup()`。

---

## 6. macOS「应用管理」权限（TCC）

这是个很会误导人的错误。典型表现：

```
ERROR : 文件复制时出错: 没有权限更新 macOS asar 完整性校验
```

但你去查权限，会发现**一切正常**：

```bash
$ ls -l Info.plist
-rw-r--r--@ 1 you  staff 3444 ... Info.plist       # 属主可写
$ ls -lO Info.plist
... -                                    # 没有 uchg / schg 标志
$ ls -le Info.plist
...                                      # 没有 ACL
$ [ -w Info.plist ] && echo writable
writable                                 # ← 但这是假的！
```

真相是 macOS 的 **TCC（Transparency, Consent, and Control）** 在拦：
非授权进程不得改写**其他 App 包内**的文件。这是 `kTCCServiceAppManagement`，
属于「隐私与安全性 → 应用管理」这一项。

**关键点：`[ -w file ]` 和 `PermissionError` 的语义在这里会打架。**
`test -w` 只看 POSIX 权限位，压根不查 TCC，所以它会骗你。

### 本工具的做法：真实试写

```python
try:
    with open(path, "r+b"):
        pass
except PermissionError:
    → 没有授权
```

只有真去 `open(..., "r+b")` 才能问出准确答案。脚本在动手**之前**就跑这个探测，
不通过就打印授权指引并退出 —— 不会跑到一半失败、留下半改状态。

### 还有个坑：`touch "$PLIST"` 会「成功」

测试时发现：

```bash
$ touch "$PLIST" && echo ok
ok
```

看起来权限没问题？**不是。** `touch` 对已存在的文件只更新 mtime，
被 TCC 拦时也可能静默不报错。所以千万别用 `touch` 测写权限 ——
必须用 `r+b` 真实打开。

授权步骤见 [`troubleshooting.md`](troubleshooting.md)。

---

## 7. 为什么备份文件叫 `app-asar-backup.bin` 而不是 `app.asar`

一个现实原因：**某些沙箱化运行环境会拦截 `.asar` 扩展名的写入**
（实测某些 Agent 运行时的文件代理会拒绝，与文件大小、目标目录无关，
纯扩展名策略）。改名为 `.bin` 后一切正常。

顺带的好处：`.asar` 有时会被系统当成归档处理，`.bin` 更中性。

回滚时这个文件会被 `cp` 回 `app.asar`，所以对 Docker 而言没有区别。
