# KOReader 开源阅读插件 (reading.koplugin)

这是一个专为 KOReader 开发的“开源阅读 (Legado)” 同步插件。通过 WebDAV，它可以将 KOReader 墨水屏设备与手机端的“开源阅读”App 完美打通，实现书架同步、云端书籍下载、以及多端无缝的阅读进度双向同步。

---

## 🚀 核心功能

1. **书架同步 (快捷同步)**
   - 自动拉取云端（WebDAV）的 `bookshelf.json`。
   - 智能比对本地书架，自动去重（支持书名+作者双重校验）。
   - 保留本地已下载但云端已删除的书籍（防误删机制）。
2. **云端书库与书籍下载**
   - 浏览 WebDAV `books/` 目录下的所有书籍。
   - 一键下载 `.epub` / `.txt` 到本地设备，支持实时进度条显示。
   - **多版本选择**：智能识别 Legado 导出的多版本后缀（如 `(1)`、`(2)`），强制覆盖本地旧版。
   - **断点续传**：下载中断（断网 / 取消 / 杀进程）后再次下载，从已下载的字节继续，不必整包重来。
   - **原子落盘**：先写 `*.epub.tmp`，校验完整后才改名为正式文件，因此书架上**永远不会出现半截坏书**。
3. **阅读进度双向同步**
   - **拉取进度**：自动计算 EPUB 复杂目录（封面、简介等）的偏移量，精准跳转到手机端对应的正文章节。
   - **覆盖进度**：将墨水屏的当前进度反推计算后，精准推送到云端。
4. **手势与快捷操作**
   - 支持集成到 KOReader 的手势管理器（Dispatcher）。
   - 可通过手势一键呼出：打开书架、拉取云端进度、覆盖云端进度。
5. **书架秒开与后台静默刷新**
   - 打开书架**先用本地缓存零等待渲染**，不必等 WebDAV 往返。
   - 缓存超过设定时长（默认 6 小时）才在后台静默同步；同步回来若书架仍停留在最上层且内容有变化，
     才原地刷新，避免墨水屏无谓重画（也会把浏览页码打回第一页）。
   - 可在菜单中关闭「打开书架时自动刷新」。
6. **本地存储管理**
   - 支持“仅显示已下载”书籍过滤。
   - 支持“删除缓存”（仅删文件保留书架记录）和“彻底删除”双重清理机制。
   - **缓存自动清理**：章节正文 / 目录 / 目录偏移三类缓存按总量与存活时长自动淘汰（LRU），
     下载不完整留下的 `*.tmp` 也会被回收；**用户下载的完整书籍永不参与清理**。

---

## 📖 使用教程

### 1. 准备工作
- 在手机端的“开源阅读”App 中，配置好 WebDAV。
- 将您需要阅读的书籍导出为 `.epub` 格式，并确保上传到 WebDAV 的 `legado/books/` 目录下。
- 在“开源阅读”中执行一次“WebDAV 备份”，确保 `bookshelf.json` 和 `bookProgress/` 目录已同步到云端。

### 2. 插件配置
- 将本插件放到 KOReader 的 `plugins/reading.koplugin` 目录下。
- 打开 KOReader，进入顶部菜单，找到“开源阅读”设置项。
- 填入您的 WebDAV 账号信息（地址、账号、密码）。

配置文件的完整字段见 `config.example.lua`。与体验相关的可调项（在 `config.lua` 中直接修改；
「打开书架时自动刷新」另在插件菜单里有开关）：

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `sync.shelf_ttl_hours` | `6` | 书架缓存新鲜度（小时）。超过才触发后台静默同步；设 `0` 表示每次都刷新 |
| `sync.auto_refresh` | `true` | 打开书架时是否后台自动刷新 |
| `cache.max_size_mb` | `512` | 章节 / 目录 / 锚点缓存总量上限（MB），超出按 LRU 淘汰到 80% |
| `cache.max_age_hours` | `48` | 缓存最长存活时长（小时），超时即淘汰 |

### 3. 日常使用
- **同步书架**：点击菜单中的“快捷同步”，即可将手机书架拉取到设备上。
- **下载书籍**：在书架左上角点击“菜单” -> “云端书库”，找到书籍并点击下载。
- **同步进度**：在阅读界面，唤出顶栏菜单，点击“开源阅读”图标，选择“拉取云端进度”或“覆盖云端进度”即可。

---

## 🔄 检查更新

菜单：**开源阅读 → 检查更新**

| 菜单项 | 说明 |
|--------|------|
| **立即检查更新** | 手动检查。有新版会弹出更新说明与「下载并安装」确认框 |
| **自动检查更新** | 开关。开启时每次启动 KOReader 后延迟 5 秒静默检查一次 |
| **检查频率** | 每天 / 每 3 天 / 每 7 天。限流用，避免每次启动都打网络 |
| **安装完成后** | 询问是否重启（默认）/ 自动重启 / 稍后手动重启 |
| **当前版本** | 只读展示 |
| **回滚上次更新** | 仅在「装了但重启后没生效」时出现 |

**关于安装**：升级会替换 `plugins/reading.koplugin/` 下的全部文件，但 **`config.lua` 会被保留**
（WebDAV 地址与口令不用重填）。整个过程分四步，每一步失败都能安全收场：

1. 下载后**强制校验 SHA-256**（清单里带摘要，对不上直接拒绝安装）；
2. 解压到暂存目录，校验包结构（必须只含一个 `reading.koplugin` 根目录）与**包内版本号**
   （必须与清单一致）；
3. 备份当前插件目录 → 替换文件 → 恢复 `config.lua`；中途任何一步失败都会自动回滚；
4. 重启 KOReader 后，插件启动时比对「期望版本 vs 实际运行版本」——一致才算更新成功并清掉
   回滚点；不一致则保留备份，菜单里出现回滚入口。

**关于网络**：更新源是 GitHub Release。国内直连 `github.com` / `raw.githubusercontent.com`
通常不通，插件会自动改用镜像（ghfast.top / gh-proxy.com / ghproxy.net）。镜像只影响下载速度，
**不会影响安装内容** —— 下载完仍然强制校验 SHA-256。自动检查只在**已经联网**时进行，绝不主动开 WiFi。

**关于兼容性**：这里刻意**没有**复用 `webdav.lua` 的请求链路 —— 更新请求必须一个凭证都不带
（把 WebDAV 口令发给镜像站是不可接受的），所以 `updater_http.lua` 是一个只做「取 JSON + 下文件」
的最小客户端。解压复用 `helper.lua` 的 `unzip_file`（KOReader 自带 `ffi/archiver`，纯 Lua），
SHA-256 也是纯 Lua 实现，因此**不依赖设备上有 `unzip` / `sha256sum` 命令**。

## 🖐 与第三方桌面插件共存（首页手势）

**现象**：首页（文件管理器）里用手势打开书架没反应，但从菜单点「书架」一切正常。

**原因**（KOReader 上游机制，已逐行核对）：`UIManager:sendEvent` 只把派发事件交给窗口栈
最上面那个控件；它不消费时，才继续交给「该控件的 `active_widgets`」与「标了
`is_always_active` 的控件」。而 `FileManager` 自身既不是 `is_always_active`，插件也没被登记
进它的 `active_widgets` —— 于是**只要有控件盖在首页之上**（例如第三方桌面类插件），
`Dispatcher` 派发到本插件的动作就永远送不到。

菜单项不受影响：它是回调**直接调方法**，不走事件派发 —— 这个不对称就是判别式。

**处理**：插件启动时把自身挂进 `ui.active_widgets`（上游留的正是这个口子 ——
`registerModule(name, module, always_active)` 的第三个参数，注释写着
"to get events even when hidden"）。挂进去的是一个只放行本插件自有事件的**桥**
（`ReadingShowBookshelf` / `ReadingPullProgress` / `ReadingPushProgress`）：
触摸 / 按键等输入事件一概不转发，因此不改变任何既有行为。

**边界**（这两条绕不过去，属上游 `sendEvent` 本身的设计）：

1. 遮挡控件**主动消费**了事件（返回 `true`）—— 那是它的正当行为，不该绕过；
2. 遮挡控件在事件链上**抛错** —— `sendEvent` 里 `if top_widget:handleEvent(event) then`
   没有 `pcall` 保护，异常会让整条派发链中断（表现为 KOReader 崩溃/重启），
   此时任何插件都收不到。这种情况要修的是那个控件本身（或先禁用它）。

排查提示：先看 `crash.log` 有没有 `Failed to initialize` 或指向别的插件的崩溃栈；
另外 KOReader 的手势设置分**两套**（`gesture_fm` 首页 / `gesture_reader` 阅读界面），互不通用。

## 📂 代码结构

插件按职责分层。`main.lua` 只负责**插件生命周期与书架入口**（约 450 行），
其余方法拆到 `reading/` 下的模块，启动时以「同名 mixin」合并回插件类
（方法名与调用约定不变，所以 `self:xxx()` 调用点无需关心方法实际定义在哪）：

```text
reading.koplugin/
├── _meta.lua                    # 插件元数据（名称、描述、版本）—— 版本号的唯一来源
├── main.lua                     # 插件入口：生命周期钩子、初始化、书架入口 show()
├── config.lua                   # 可选：以文件形式配置 WebDAV（首次运行播种进 settings）
├── config.example.lua           # 配置模板
├── reading/
│   ├── store.lua                # 【进程级单例】settings/bookshelf/read_record/sync 的唯一持有者
│   ├── toc_align.lua            # TOC 锚点校准（Legado 索引 ↔ EPUB TOC 索引，两点锚定）
│   ├── progress.lua             # 进度链路：章节加载、阅读记录、云端进度拉取/推送/跳转
│   ├── book_detail.lua          # 书籍详情页、EPUB 的获取/打开/删除
│   ├── downloader.lua           # 异步执行框架（_async_run/_cancel_async）与云端书库下载
│   ├── menus.lua                # 主菜单/WebDAV 菜单项注册与设置对话框
│   ├── lifecycle.lua            # onClose / onCloseDocument / onPageUpdate / 日志查看
│   ├── settings.lua             # 配置读写（UI 设置项 + config.lua 播种/迁移）
│   ├── bookshelf.lua            # 书架数据模型：合并去重、本地 EPUB 扫描、锚点持久化
│   ├── read_record.lua          # 阅读时长记录（原子写盘）
│   ├── sync.lua                 # 同步编排：WebDAV 备份 / 阅读进度 / 书籍的读写
│   ├── webdav.lua               # 底层 WebDAV 驱动：PROPFIND/GET/PUT、XML 目录解析、Range 断点续传
│   ├── shelf_view.lua           # 书架 UI 渲染：列表视图、云端书库/文件列表弹出
│   ├── download_progress.lua    # 下载进度对话框
│   ├── async.lua                # 异步子进程执行（管道 IPC，UI 线程不阻塞）
│   ├── reading_context.lua      # 阅读会话上下文（当前书籍、EPUB TOC）
│   ├── ui_handles.lua           # UI 句柄注册表（跨模块关闭对话框）
│   ├── helper.lua               # 通用工具：路径、JSON、原子写、文件名净化、LRU 缓存清理
│   ├── log.lua                  # 日志（内存缓冲 + 大小轮转）
│   ├── updater.lua              # 自更新：清单校验 / 下载 / 备份替换 / 回滚 / 启动确认
│   ├── updater_http.lua         # 自更新专用 HTTP（取清单、下包；刻意不带任何业务凭证）
│   ├── updater_ui.lua           # 自更新菜单与流程编排（异步、防重入、重启询问）
│   ├── digests.lua              # 纯 Lua SHA-256（校验更新包完整性）
│   └── result.lua               # 统一错误结果封装
```

> **为什么要有 `store.lua`**：KOReader 会为 `FileManager` 和每个 `ReaderUI` 各创建一个插件实例。
> 若各实例自行 `Settings:new()` / `Bookshelf:new()`，同一批磁盘文件就会被两套内存模型并发读写
> （「状态归属分裂」，症状是书架偶发空白、进度偶发错一章）。现在这 4 个有状态模块收敛到单例。
> 而 `_async_handles` 等**实例级**状态刻意不共享 —— `onClose` 会无条件取消「本实例」的异步任务。

### 💡 核心技术亮点
- **高性能去重**：使用 `name|author` 复合哈希键，将书架合并复杂度从 $O(N^2)$ 降为 $O(N)$。
- **偏移量自适应校准 (toc_anchors)**：用「当前章节标题」与「末章标题」两个来自 Legado 的真实端点做两点锚定，
  把本地 EPUB 目录映射到手机端目录，解决因「封面」「序章」导致的进度同步错位。
  校准不可靠时**不会**写入猜测锚点（宁可不校准，也不静默跳错章节）。
- **Schwartzian Transform 排序优化**：将书架的渲染及排序性能提升数倍，杜绝大书架卡顿。
- **IPC 异步下载**：通过临时文件通信实现子进程静默下载与父进程进度条实时刷新的完美结合；
  取消下载会真正终止子进程并清理半截文件。
- **断点续传 + 原子落盘**：下载写入 `*.epub.tmp`（该后缀不匹配书架扫描，因此半截数据对用户不可见），
  失败重试 / 重新下载时带上 `Range` 头从已有字节续传，完整校验通过后才 `rename` 成正式文件。
  服务器不支持 `Range`（返回 `200`）时会识别出「新整包被追加到半截文件后」的污染并自愈重下一次。
  更新书籍（强制覆盖）时**不复用**旧断点 —— 否则旧前段 + 新后段会拼出「长度正确、内容错乱」的坏文件。

---

## 🚀 发布流程

插件的「检查更新」读的是仓库 `main` 分支根目录的 `update.json`，包则在 GitHub Release 上。
两者都由打包脚本一次生成：

```bash
# 1. 改代码，并把 _meta.lua 的 version 改好（版本号只有这一个来源）
# 2. 打包 + 生成清单（版本号、包大小、SHA-256 全部自动计算）
python .workbuddy/tools/pack_plugin.py D:/webProgram/project/reading.koplugin
# 3. 提交（update.json 要和代码一起进 main 分支，否则客户端读不到）
git add -A && git commit -m "v0.3.0"
git tag v0.3.0
git push origin main --tags
# 4. 在 GitHub 上按 v0.3.0 建 Release，上传 reading.koplugin.zip
```

脚本会自动把用户的 `config.lua` 排除在包外（含 WebDAV 口令，绝不发布），zip 内保留一层
`reading.koplugin/` 根目录，并且**按字节写入、完整保留源文件行尾**。

> ⚠️ 打包前确认没有未提交的源文件 —— `pack_plugin.py` 是从**工作目录**读取的，
> 而别人 `git clone` 拿到的是**已提交内容**。两者不一致时，更新包会比仓库多/少文件
> （本项目历史上就曾有过若干核心模块长期未提交）。

---

## 📝 更新日志

### v0.3.1

**修复在线更新 403 误报 + 下载镜像可手选**（设计参考 appstore.koplugin）

- **检查更新失败不再只报最后一个错误**：所有清单地址（直连 + 镜像）逐个尝试，失败时
  按**主机名**聚合报出 —— 直连被墙（连接重置）与镜像限流（HTTP 403）从此一眼可分。
- **新增「下载镜像」菜单**：自动（默认）/ 仅直连 GitHub / 四个预设镜像 / 自定义前缀。
  镜像站按 IP 限流，哪个能用完全取决于当时网络 —— 换一个常能解决「检查更新失败」。
- **镜像偏好同时作用于清单检查与安装包下载**，下载内容仍强制校验 SHA-256，安装内容不受影响。
- **修复：SHA-256 校验永远不通过的隐藏 bug** —— Lua 模式不支持 `{64}` 量词，
  `^%x{64}$` 会把合法哈希全部拒掉（此前一直被网络层错误掩盖）；现改为长度 + `^%x+$` 校验。

---

以下为详细说明：

- **为什么 403**：镜像站（ghfast.top 等）普遍按 IP 限流，返回干净的 HTTP 403；
  而 DNS 污染的表现是连接重置 / 超时 / 错站内容，不会是 403。旧代码轮询 4 个清单地址
  却**只报最后一个错误**，用户看到的 403 大概率只是某一个镜像的限流应答。
- **镜像策略**（菜单「检查更新 → 下载镜像」）：
  - `自动`：直连优先，失败依次换镜像（原有行为）
  - `仅直连`：完全不碰第三方镜像（适合自建了代理的环境）
  - 固定镜像：所选镜像的地址排最前，其余镜像与直连兜底
  - `自定义前缀`：填 `https://your-mirror/` 这类前缀（仅接受 https，结尾自动补 `/`，
    带空格 / 无主机名的输入会被拒绝）
- **顺带修复 SHA-256 校验 bug**：`validate_manifest` 里用 `sha:match("^%x{64}$")` 判断哈希
  合法性，但 Lua 模式没有 `{64}` 量词 —— `%x{64}` 实际匹配「1 个 hex 字符 + 字面量 `{64}`」，
  合法 SHA-256 永远被拒、`a{64}` 反而放行。一旦网络层先报 403 就一直没暴露。
  现改为 `#sha == 64 and sha:match("^%x+$")`。

### v0.3.0

**新增：插件内「检查更新」与一键升级**（设计参考觅阅 miuread）

- **检查更新**：菜单「开源阅读 → 检查更新 → 立即检查更新」。从 GitHub Release 的
  `update.json` 读最新版本号做语义化比对。清单里同时带 4 个下载地址（GitHub 原址 + 3 个国内
  镜像），直连不通时自动换下一个。
- **自动检查**：启动 5 秒后静默检查一次，默认 24 小时最多一次（可关、可改频率），同一个新版本
  只提醒一次。**只在已联网时检查**，绝不主动开 WiFi。
- **下载与安装**：下载后强制校验 SHA-256 → 解压到暂存目录并校验包结构与包内版本号 →
  备份当前插件 → 替换 → 恢复用户配置。任何一步失败都自动回滚到旧版本。
- **安装后重启**：可选「询问（默认）/ 自动重启 / 稍后手动」。重启后插件启动时比对
  「期望版本 vs 实际运行版本」，一致才算更新成功并清掉回滚点；不一致则保留备份并给出回滚入口。
- **保留用户配置**：`config.lua`（含 WebDAV 地址与口令）在升级时被完整保留。更新包本身也
  禁止含 `config.lua` —— 发布包不该带凭证，真带上了直接拒绝安装。
- **不复用 WebDAV 请求链路**：更新请求必须不带任何凭证，而 `webdav.lua` 的
  `_request_with_fallback` 绑死了 verify_cert / http_fallback 配置并会带 Basic 认证头，
  因此新写了 `updater_http.lua` 这个只做「取 JSON + 下文件」的最小客户端。
- **零外部命令依赖**：解压复用 `helper.lua` 的 `unzip_file`（KOReader 自带 `ffi/archiver`），
  SHA-256 是纯 Lua 实现，不依赖设备上的 `unzip` / `sha256sum`。

新增模块：`reading/digests.lua`、`reading/updater_http.lua`、`reading/updater.lua`、
`reading/updater_ui.lua`。

**同时修掉三个会让功能「静默失效」的问题**

- **`redirect` 参数让所有 HTTPS 更新请求在发出前就失败**：更新器给请求传了
  `redirect = true`，而 LuaSec 的 `ssl/https.lua` **不支持自动重定向** ——
  `elseif url.redirect then return nil, "redirect not supported"`，请求根本发不出去。
  改为手动跟随跳转（上限 5 次）。
- **`init()` 里任何一处抛错会弄哑整个插件**：上游 `PluginLoader:createPluginInstance`
  用 `pcall(plugin.new, plugin, attr)` 包住构造，而 `Widget:new` 内部就会调 `init()` ——
  也就是说 `init()` 抛错时**插件实例根本不会被创建**，现场只留一行
  `logger.err("Failed to initialize", ...)` 日志。后果是主菜单与手势动作一起消失，而
  `Dispatcher:execute` 查不到动作名时**静默跳过**，用户看到的就是「首页手势点了没反应」。
  本插件原先 `Store.get()`（构造 Settings/Sync/Bookshelf/ReadRecord 并读盘）排在动作注册
  之前，同样会连带弄哑注册。现拆成 `init + _init_modules`：动作注册最先跑且不依赖任何模块，
  模块构造整段 `pcall`，失败只降级为「插件不可用但实例仍在」。
- **首页被第三方桌面插件遮挡时手势也能生效**：把手势动作事件挂进 `ui.active_widgets`
  （详见「与第三方桌面插件共存」一节）。

### v0.2.3

**第四轮复查 · 清理 / 重复 / 性能**（纯内部整理，无用户可见功能变更）

- **删除死代码**：`webdav.lua` 的 `WebDAV:delete_file` + `_delete_file_impl`（≈48 行，全仓零调用 ——
  同组的 list/get/put impl 仍在用，只有 delete 这组是死的）；`log.lua` 顶部那段
  `pcall(require, "logger")`（`ko_logger` 从未被使用）；`downloader._cancel_async` 的
  「按字符串 ID 取消」分支（调用方只传 nil 或句柄 table）；`book_detail.lua` 里重复的
  `require("reading.ui_handles")`（第二次遮蔽第一次）。
- **合并重复实现**：`book_detail` 的 `delete_book_cache` 与 `delete_book_completely` 原本是两份
  逐行重复的确认框实现（只差「是否从书架移除」与文案），合并为共用的 `confirm_delete_book`
  + 两个薄封装；`main.lua:show()` 里「去重 + 仅显示已下载 + 搜索过滤」的循环原本被复制两份
  （第二份用于搜索无结果的回退重跑），抽成 `collect_valid_books(filter)`。
- **清理未消费配置**：`sync.sync_url` 与 `progress_sync.auto_sync_interval` 全仓无读取方，
  已从 `settings.lua` 默认值、`config.example.lua`、`config.lua` 一并移除。
- **性能**：下载子进程的进度回调节流 —— 此前**每收一个 HTTP chunk（约 8KB）就 json_encode +
  开/写/关一个进度文件**（一本 20MB 的书约 2500 次落盘），现改为「距上次落盘 ≥1s 或新增 ≥64KB」，
  但最后一次（`downloaded >= total`）必定落盘，保证父进程能读到 100%；`download_progress.lua`
  的 stage→文案映射表从每次 `setState` 重建改为模块级常量。

> 有意保留：`toc_align.lua` 的「用完整 Legado 章节表对齐」分支（`load_toc_cache` 目前无数据源写入，
> 是**预留链路**，见 `Bookshelf:save_toc_cache` 注释）；`Bookshelf:save_toc_cache` / `Store.reset`。

### v0.2.2

**WebDAV 传输可用性：HTTPS 降级链**

- **传输选择从「单点判断」改为「策略链」**（`reading/webdav.lua`）。此前 `get_transport(url)` 只在
  `https://` 且 SSL 模块可用时返回 https，否则直接报「SSL 模块不可用」——**自签 / 过期 / 证书链不完整的
  服务器会让整个 WebDAV 彻底不可用，没有任何退路**。现由
  `build_transport_chain(url, verify_cert, allow_http_fallback)` 产出
  `{name, transport, url, ssl_opts}` 策略数组，`_request_with_fallback` 对每个策略各跑一遍
  `_request_with_retry`：**收到数值状态码即停**（业务错误不再换传输方式重试），
  只有传输层全部失败才前进到下一策略。
- **默认行为与旧版完全一致**：`verify_cert = false` —— 电子墨水设备普遍**没有 CA 证书库**，
  显式 `verify="peer"` 会让**所有**服务器握手失败；KOReader 自带 `webdavapi.lua` 与 koobone 同样从不校验。
  `allow_http_fallback = false` —— 明文传输会暴露 WebDAV 口令，属安全降级，不默认开启。
- **新增两个设置项**（`settings.lua` + `menus.lua`）：「校验证书（需 CA 证书库）」与
  「允许降级 HTTP（明文，有风险）」，菜单中就地点出风险。开启前者 → HTTPS 走
  `verify="peer"` + `tlsv1_2`；开启后者 → HTTPS 失败后自动以 `http://` 重试同一请求。
- 所有传输层都失败、原 URL 为 https 且未开明文回退时，日志留一条 WARN 明确提示「可开启任一选项」。

**书架缓存改 Lua 持久化（去掉每次全量 JSON 解析）**

- **`bookshelf.lua` 的缓存由 JSON 改为 `loadfile` 可直接执行的 Lua 源**（`serpent.block({comment=false})`，
  失败退回 `H.json_encode`）。加载路径从「读文件 → 全量 `json_decode`」变为 `loadfile` + `pcall(chunk)`，
  **大书架不必每次启动都付一次全量反序列化开销**。
- **向后兼容**：旧 `bookshelf_cache.json` 仍可读（`json_decode` 前先剥掉 `"return "` 前缀）；
  首次成功写出 `.lua` 后自动删除旧文件，完成一次性迁移。原有 mtime 短路逻辑保留。
- 缓存**瘦身**：不再写 `sources` / `replace_rules`（`bookshelf.lua`、`sync.lua`）。二者经全仓核查
  **零消费方** —— 只在 sync ↔ bookshelf 之间来回搬运，是纯粹的无效载荷。同时把 `readRecord.json`
  加进 `load_from_extracted_dir` 的 `target_files`，让此前**永不成立**的 `readRecord.json`
  死分支真正生效（阅读记录合并链路由此打通）。
- **顺带修掉 `read_record.lua` 的 serpent 模块名 bug**：`pcall(require, "serpent")` 在 KOReader 里
  **永远失败**（正确模块名是 `ffi/serpent`，见 `frontend/logger.lua` / `frontend/persist.lua`），
  即「用 serpent 落盘」的设计意图**从未生效**、一直在走 JSON 兜底。现改为 `ffi/serpent` → `serpent` 双探测。

**书架渲染节流**

- **`main.lua:show()` 增加内容键去重**：`_shelf_content_key` 由「书籍数据指纹 + 搜索关键字 +
  排序键/方向 + 仅显示已下载」拼成；键相同**且书架菜单仍在最上层**时直接返回，不再整屏重画。
  墨水屏上反复进出书架时的重绘闪烁、页码被打回第一页的情况由此明显减少。
- 为跨文件复用，`downloader.lua` 的 `is_widget_on_top` / `shelf_signature` 从 `local function`
  提升为 mixin 方法（`self:is_widget_on_top(...)` / `self:shelf_signature(...)`）。

**死代码清理**

- 删除确定死亡的代码：`ui_handles.close_all_except_busy`、`read_record.get_sync_data`，
  以及 `sync.load_from_extracted_dir` 中永不成立的 `bookSource.json` / `replaceRule.json` 两个分支。
- 剩余 2 个不可达函数（`bookshelf.save_toc_cache` ~42 行、`store.Store.reset` ~2 行）为**有意保留**
  （见 `bookshelf.lua` 注释：WebDAV 备份没有章节表，`save_toc_cache` 是预留链路）。

### v0.2.1

**写盘健壮性**（3 处 `write`/`close` 未查返回值的地方；正确写法同仓库早有先例，见 `read_record.lua` 的原子写）

- **`reading/helper.lua` 的 `unzip_file`** — 此前只看 `io.open` 是否成功。Lua 的 stdio 是带缓冲的，
  磁盘写满 / 配额耗尽时 `write` 往往不报错、`close` 才暴露 → 会静默留下一个**截断**的条目文件，
  后续被当完整文件使用。现检查 `write`/`close` 返回值，失败即删除半截文件并告警。
- **`reading/bookshelf.lua` 的 `save_toc_anchors` / `save_bookshelf_cache`** — 两处原子写此前无条件
  `rename`。`write` 失败但 `rename` 成功 = 把一个**截断的 JSON** 换上去：前者损坏两点校准锚点表
  （进度同步会跳到错误章节），后者损坏**整个书架缓存**。现写入失败即 `os.remove(tmp)` 并返回 false。

**正确性**

- **`reading/async.lua` 的子进程回写** — `pcall(ffiutil.writeToFD, ...)` 的返回值此前被丢弃。
  写管道失败（对端已关闭 / 管道满）时，父进程侧走「子进程已结束但读不到数据 → 视为成功、
  `result=nil`」，于是**「子进程写不出去」被当成「子进程成功且无返回值」**。现失败至少留一条 warn。
  注意这是语义漏洞而非现发 bug —— 多数调用方对 `result=nil` 本就判空。

**重构（零行为变更）**

- 抽出 `reading/toc_align.lua::_scan_toc_for_page(toc, pageno, total_pages)`：
  `lifecycle.lua` 的 `onPageUpdate` 慢路径与 `progress.lua` 的 `_refresh_current_progress`
  此前**逐行复制了同一段 TOC 扫描**（各约 55 行：单调性检查 + 二分/线性查找 + 章内位置换算），
  历史上已因两处漂移出过一次 bug（`progress.lua` 注释有记录）。现两边共用一份实现，
  统一返回 `(chapter_index, chapter_pos, current_start, next_start, chapter_title)`。

### v0.2.0

**下载健壮性**

- **断点续传**（`reading/webdav.lua`、`reading/sync.lua`）：GET 请求支持 `Range: bytes=N-`，
  并区分 `206`（续传成功）/ `416`（本地已完整）/ `200`（服务器忽略 Range → 删除被污染的半截文件后从零重下）三种响应。
  下载中断后重新发起会从已下载字节继续，弱网环境下不再每次重试都从头下载。
- **原子落盘**（`reading/sync.lua`）：EPUB 先写 `save_path.tmp`，长度校验通过后 `os.rename` 原子替换。
  下载中途取消或进程被杀，书架上也不会出现扩展名合法的半截文件。
- `404` 由「视为业务成功」改为失败上报（原实现会让调用方拿到空文件却认为下载成功）。
- 云书库下载路径不再强制覆盖，从而启用续传；「文件已存在」的短路判断单独保留。
- **覆盖本地文件前二次确认**（`reading/downloader.lua`）：云端书库 / 云端多版本两个入口，
  在「本地已有同名文件且与云端大小不同」时先弹确认框（并列显示两边大小），
  确认后才下载。此前 `os.rename` 会**静默替换**掉本地文件 —— 用户自己换过或手工
  拷进来的同名书就是不可逆丢失。大小相同不弹框（那是同一份，走「文件已存在」短路，
  根本不会下载）。

**性能与存储**

- **缓存 LRU 淘汰**（`reading/helper.lua`、`reading/downloader.lua`）：新增 `H.lru_cleanup`，
  按「存活时长」与「总量上限」两个维度淘汰 `chapters/`、`toc/`、`toc_offset/` 缓存。
  清理在启动后延迟 5 秒异步执行，并有进程级 + 12 小时双重短路，不会拖慢启动。
  清理仅作用于可重建的数据缓存，**用户下载的完整书籍永不参与**；`books/` 只回收 `*.tmp` 残留。
- **书架秒开 + 后台静默刷新**（`main.lua`、`reading/downloader.lua`）：打开书架先用本地缓存零等待渲染，
  缓存超过 `shelf_ttl_hours`（默认 6 小时）才后台静默同步。
  同步结果落地前经过四重判定（身份令牌 / 菜单句柄存活 / 书架仍在最上层 / 内容指纹有变化）才重绘，
  用户已进入书籍详情页时不会被打断。
- 后台静默刷新同样会合并云端阅读记录，与手动同步语义一致。

**新增配置项**：`sync.shelf_ttl_hours`、`sync.auto_refresh`、`cache.max_size_mb`、`cache.max_age_hours`。
**新增菜单项**：「设置 → 打开书架时自动刷新」。

**修正**

- `reading/webdav.lua` 补上缺失的 `require("libs/libkoreader-lfs")`（KOReader 无全局 `lfs`），
  修复断点检测在真机上可能报错的问题。
- **两条下载入口合并为单槽位会话**（`reading/downloader.lua`、`reading/book_detail.lua`）：
  详情页「下载/更新书籍」与云端书库「下载」此前各存各的句柄（`_download_epub_handle`
  与 `_download_handle`），互相取消不到 —— 同一本书会同时跑两个子进程写同一个
  `save_path`（及其 `.tmp`），落盘结果互相覆盖，屏幕上还会挂两个进度窗。
  现在统一为 `self._book_download` 单槽位（后来的下载会先收掉前一个，含它的进度窗与 busy 提示）。
- 关闭插件（从文件管理器打开一本书 / 退出 KOReader 触发 `onCloseWidget`）不再把
  「下载中」进度窗永久留在屏幕上：此前只取消了子进程，而被取消的异步任务不会再回调，
  窗口就无人关闭。
- 删除两个「声明了但没有任何消费方」的死配置项：`cache.pre_download_chapters` 与
  `cache.download_cover_images`。前者需要「按章从远端取正文」的接口，而本插件只会整本
  下载 WebDAV 上的 EPUB/TXT（全仓库零个 Legado API 客户端）；后者对应的封面链路
  （下载 → 缓存 → 渲染）早已整体移除。两个键此前**从未被读取**，改它们不产生任何效果。
  用户 `config.lua` 里若仍保留这两个键，只是被合并进配置表，无副作用。

### v0.1.0

- 首个版本：书架快捷同步、云端书库下载、阅读进度双向同步、手势集成、本地存储管理。
