local LOG_MODULE = "[Reading]"

local function safe_require(module_name, required)
    local ok, result = pcall(require, module_name)
    if not ok then
        if required then
            print(LOG_MODULE, "fatal: failed to load required module:", module_name, "-", result)
            return nil, false
        else
            print(LOG_MODULE, "warning: failed to load optional module:", module_name, "-", result)
            return nil, true
        end
    end
    return result, true
end

local WidgetContainer, ok = safe_require("ui/widget/container/widgetcontainer", true)
if not ok then return end

local UIManager = safe_require("ui/uimanager")

local H = require("reading.helper")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- ⚠️ template 必须从 "ffi/util" 取：frontend/util.lua 的 util.template 是 nil
-- （它只在模块内部 local T = ffiUtil.template，没有导出）——曾因此掉进
-- fallback「原样返回」分支，提示里打出未替换的 %1（menus.lua 的写法是对的）。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(t, ...) return t end

local Dispatcher = safe_require("dispatcher")

-- Local libs
local ShelfView = safe_require("reading.shelf_view")
local Log = safe_require("reading.log")
local Store = safe_require("reading.store")
-- 说明：Settings / Sync / Bookshelf / ReadRecord 只在 reading/store.lua 里构造，
-- 本文件改为从 Store.get() 取单例，因此不再直接 require（P0-4）。

-- 阅读上下文状态（替代原 _state 中的阅读会话字段，含 generation 令牌防竞态）
local Context = require("reading.reading_context")
-- UI 句柄管理（替代原 _state 中的 UI 字段，修复 chapter_list_menu 泄漏）
local UIHandles = require("reading.ui_handles")

-- 自更新：updater_ui 负责菜单与流程编排，updater / digests / updater_http 由它按需 require。
-- 刻意**不**放进下面那份 mixin 合并列表 —— 那些函数的签名是 UI.xxx(plugin, ...)，
-- 不是插件方法，合并进去只会把 startup / check_update 之类的名字污染到 ReadingPlugin 上。
local ok_updater_ui, UpdaterUI = pcall(require, "reading.updater_ui")
if not ok_updater_ui then UpdaterUI = nil end

local ReadingPlugin = WidgetContainer:extend{
    -- fullname / description / version 不在此重复定义：KOReader 的 PluginLoader 会
    -- 把 _meta.lua 的全部键（name 除外）覆盖到插件实例上
    -- （见 koreader frontend/pluginloader.lua:253-262），写在这里的值永远不会生效。
    -- 因此 _meta.lua 是这些字段的单一来源，改版本号请只改 _meta.lua。
    name = "reading",
    is_doc_only = false,
}

-- ════════════════════════════════════════════════════════════════════════════
-- 「首页被别的控件遮住时，依然能收到 Dispatcher 派发的动作事件」
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【问题】UIManager:sendEvent（frontend/ui/uimanager.lua:884）先把事件送给窗口栈最上面
-- 那个非 toast 控件；它不消费时，才继续送给「该控件的 active_widgets」以及
-- 「is_always_active 的控件」。而 FileManager / ReaderUI 自身都不是 is_always_active
-- （全仓库只有前光 / 自然光 / 输入框 / 键盘等 6 处是），所以：
--
--   **只要有控件盖在首页之上**（例如第三方桌面类插件），Dispatcher 派发到本插件的
--   动作就永远送不到它。
--
-- 现象恰好是「菜单能打开书架、手势点了没反应」—— 菜单项是回调直接调方法，不走事件派发；
-- 手势要走 Dispatcher:execute → UIManager:sendEvent。（2026-10-11 在设备上实测确认：
-- 把覆盖首页的那个插件关掉，手势立刻恢复。）
--
-- 【上游留的口子】FileManager/ReaderUI:registerModule(name, module, always_active)
-- 第三个参数为 true 时会把 module 插进 self.active_widgets，注释写着
-- "to get events even when hidden"。但插件实例是由 PluginLoader 创建后交给
-- registerModule 的，第三个参数没传（= false）→ 插件默认收不到被遮挡时的事件。
-- 这里把自己补进去。（不能反过来去调 registerModule：它内部还会
-- table.insert(self, module)，会让插件在 FileManager 的数组部分出现两次，
-- propagateEvent 就会把它调两遍。）
--
-- 【为什么用一个「只放行自有事件」的桥，而不是把插件本身插进去】
--   ① 插件已经在 FileManager/ReaderUI 的**数组部分**（registerModule 里的
--      table.insert(self, ui_module)）。sendEvent 在「top_widget 自己」这条路径上
--      会经 WidgetContainer:propagateEvent 把事件送到插件一次；若插件同时也在
--      active_widgets 里，同一次 sendEvent 会在「top_widget 没消费」之后**再送一次**
--      （uimanager.lua:906-918）。桥只放行下面这几个自有事件，而这些事件的处理函数
--      都返回 true（= 已消费）→ 第一条路径就截断了，第二条根本轮不到桥，不会重复触发。
--   ② 桥把「因被遮挡而新增的接收面」严格限制在自有事件上 —— 插件永远不会因为被遮挡
--      而多收到 Touch / Gesture / KeyPress 等输入事件，行为零回归。
--
-- 幂等；ui 结构不符合预期时安全退出（退化为原有行为）。
--
-- 放行表用 Event.handler 名（frontend/ui/event.lua:31 是 `handler = "on"..name`）。
local DISPATCH_HANDLERS = {
    onReadingShowBookshelf = true,
    onReadingPullProgress  = true,
    onReadingPushProgress  = true,
}

local function ensure_dispatch_reachable(plugin)
    local ui = plugin and plugin.ui
    if not ui or type(ui.active_widgets) ~= "table" then
        return false
    end
    local bridge = plugin._dispatch_bridge
    if not bridge then
        -- 桥只认「我们自己的事件」，其余一律返回 nil（不消费、不干扰上游传播）。
        bridge = {
            handleEvent = function(_, event)
                local handler = event and event.handler
                if not handler or not DISPATCH_HANDLERS[handler] then
                    return nil
                end
                return plugin:handleEvent(event)
            end,
        }
        plugin._dispatch_bridge = bridge
    end
    for _, w in ipairs(ui.active_widgets) do
        if w == bridge then return true end
    end
    table.insert(ui.active_widgets, bridge)
    if Log then
        pcall(function() Log.info("dispatcher bridge attached to ui.active_widgets") end)
    end
    return true
end

-- ============================================================================
-- 把拆分到 reading/*.lua 的方法合并回插件类（同名 mixin）。
-- 方法名与调用约定与拆分前完全一致，因此本文件其余地方与其它模块里的
-- `self:xxx()` 调用点都无需改动。详见架构报告 §9-2 / P0-6。
-- ============================================================================
for ___, mod_name in ipairs({
    "reading.toc_align",
    "reading.progress",
    "reading.book_detail",
    "reading.downloader",
    "reading.menus",
    "reading.lifecycle",
}) do
    local mod = require(mod_name)
    for method_name, fn in pairs(mod) do
        ReadingPlugin[method_name] = fn
    end
end

function ReadingPlugin:isCurrentDocReading()
    if not (self.ui and self.ui.document) then return false end
    local doc_path = self.ui.document.file or self.ui.document.path or ""
    if doc_path == "" then return false end
    
    local H = require("reading.helper")
    local books_dir = H.get_books_dir()
    
    return doc_path:lower():sub(1, books_dir:lower():len()) == books_dir:lower()
end

function ReadingPlugin:onShow()
    if not self.ui then return end
    
    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    
    self:_detect_current_book()
end

function ReadingPlugin:_detect_current_book()
    if not self.ui or not self.ui.document then return end

    local doc_path = self.ui.document.file or self.ui.document.path or ""
    if doc_path == "" then return end

    local books_dir = H.get_books_dir()

    if doc_path:lower():sub(1, books_dir:lower():len()) == books_dir:lower() then
        Context.set_current_epub_path(doc_path)

        local book_name = H.get_filename(doc_path)
        book_name = book_name:gsub("%.epub$", ""):gsub("%.txt$", ""):lower()

        Log.debug("检测到打开的书籍文件: " .. doc_path .. ", 书名: " .. book_name)

        local books = self.bookshelf:get_books()
        -- 单例下书架缓存已在 Store.get() 内加载完毕，这里直接取权威内存副本。
        -- （P0-4：原先「ReaderUI 实例 books 为空则按需重新加载缓存」的补丁
        --   是双实例状态分裂的症状，已随单例化一并移除。）

        -- 优先用哈希索引 O(1) 精确匹配
        local matched = self.bookshelf:get_book_by_name(book_name)
        if matched then
            Context.set_current_book(matched)
            Log.info("检测到已打开阅读书籍(精确匹配): " .. (matched.name or matched.title or ""))
            return
        end

        -- 回退：线性扫描前缀匹配（处理 epub 名包含额外标识的情况）
        for ___, book in ipairs(books) do
            local bname = (book.name or book.title or ""):lower()
            if bname ~= "" and book_name:sub(1, #bname) == bname then
                Context.set_current_book(book)
                Log.info("检测到已打开阅读书籍(前缀匹配): " .. (book.name or book.title or ""))
                break
            end
        end
    end
end

function ReadingPlugin:onReaderReady()
    if not self.ui then return end

    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    self:_detect_current_book()

    if Context.get_current_epub_path() then
        Log.info("阅读界面就绪，位置变化停止满去抖窗口后将自动异步上传进度")

        -- 阅读器就绪后加载章节，并执行 pending_jump（如果有）
        self:_load_chapters_from_document()

        -- 进入阅读界面时自动拉取云端进度并对比
        self:_auto_pull_and_compare()
    end
end

function ReadingPlugin:onDispatcherRegisterActions()
    -- 「书架」注册到 KOReader 的手势/按键派发器中。
    -- 用 general：文件管理器（主页面）与阅读界面都用得上它 —— 阅读中想换书也说得通。
    -- （不要再加 filemanager = true：section 列表里 general 与 filemanager 各列一次，
    --   两个都为 true 会让同一动作在手势菜单里重复出现两项。）
    --
    -- ⚠️ 动作名 "reading_show_bookshelf" 自 4054c04（首个提交）以来从未变过。
    -- 用户在手势菜单里绑定的就是这个名字，**改名会让所有既有手势绑定失效**
    -- （Dispatcher:execute 查不到动作名只会静默跳过），属破坏性变更。
    Dispatcher:registerAction("reading_show_bookshelf", {
        category = "none",
        event = "ReadingShowBookshelf",
        title = _("开源阅读：书架"),
        general = true,
    })

    -- ⚠️ 「拉取进度」「覆盖云端」必须只在**阅读界面**注册（reader = true，而**不是** general）。
    --
    -- 这两个动作都以「当前正在阅读的那本书」为操作对象，在文件管理器里没有意义：
    -- pull_cloud_progress 第一行就是 `if not Context.get_current_book() then return end`，
    -- 在主页面上点它只会「毫无反应」。此前它们用的是 general = true，于是 FileManager 的
    -- 手势/按键菜单里也会列出这两项 —— 等于把「阅读中才成立的动作」注册到了主页面。
    --
    -- 上游的惯例也是按这个划分（frontend/dispatcher.lua:167-181）：
    -- 依赖 ReaderUI 的动作一律 reader = true（toggle_status_bar / prev_chapter / go_to …），
    -- 依赖 FileManager 的才用 filemanager = true（set_display_mode / folder_up …）。
    --
    -- 注：Dispatcher:registerAction 只在 settingsList[name] == nil 时写入，
    -- 所以本次改动需要**重启 KOReader** 才会在菜单里生效。
    Dispatcher:registerAction("reading_pull_progress", {
        category = "none",
        event = "ReadingPullProgress",
        title = _("开源阅读：拉取进度"),
        reader = true,
    })

    Dispatcher:registerAction("reading_push_progress", {
        category = "none",
        event = "ReadingPushProgress",
        title = _("开源阅读：覆盖云端"),
        reader = true,
    })
end

-- ⚠️ 这三个 onXxx 是**用户手势/按键直接触发的入口**，必须整体用 _guard 包住：
-- 插件里任何一处抛错，在派发器动作里都是「KOReader 整个进程崩掉」
-- （2026-09-30 实测：本动作绑成手势后一点就 ./luajit: ... attempt to call method
--  'showBookshelf' (a nil value)，正在读的书一起没了、要重新启动）。
-- _guard 会把异常降级成一条「xx 失败:<原因>」提示 + 一条 ERROR 日志。
function ReadingPlugin:onReadingShowBookshelf()
    -- 延迟执行以确保从阅读界面或其他状态安全切换。
    -- 入口是 self:show()（与主菜单「开源阅读 → 书架」同一入口，见 menus.lua 的
    -- getMainMenuItems）——**不是** showBookshelf。这段派发代码是照 koobone
    -- 抄的，那边的方法恰好叫 showBookshelf，而本插件的方法名是 show，改名时
    -- 漏了这一处，于是这个动作从来没能用过（备份里的 134KB 单体版同样如此）。
    -- 语法/自由变量/可达性/模块字段四项检查都看不见这种错：
    -- `self:foo()` 里的 foo 是「字段查找」，不是自由变量，也不是模块表的字段。
    UIManager:scheduleIn(0.1, self:_guard(_("打开书架"), function()
        self:show()
    end))
    return true
end

function ReadingPlugin:onReadingPullProgress()
    UIManager:scheduleIn(0.1, self:_guard(_("拉取进度"), function()
        -- 守卫：必须有「当前正在阅读的书」。
        -- 该动作现在只在阅读界面注册，但旧版本可能已经把 general 版绑到了手势上，
        -- 那种残留配置下会走到这里；没有守卫的话 pull_cloud_progress 第一行就
        -- 静默 return，用户看到的是「点了没反应」。
        if not Context.get_current_book() then
            self:showInfo(_("请先在开源阅读书架中打开一本书"), false)
            return
        end
        self:pull_cloud_progress()
    end))
    return true
end

function ReadingPlugin:onReadingPushProgress()
    UIManager:scheduleIn(0.1, self:_guard(_("覆盖云端"), function()
        if not Context.get_current_book() then
            self:showInfo(_("请先在开源阅读书架中打开一本书"), false)
            return
        end
        self:push_cloud_progress()
    end))
    return true
end

-- ⚠️ 【为什么拆成 init + _init_modules：一个会「静默弄哑整个插件」的 KOReader 语义】
--
-- 上游创建插件实例的链路（已逐行核对）：
--   frontend/pluginloader.lua:479  PluginLoader:createPluginInstance(plugin, attr)
--                                  → local ok, re = pcall(plugin.new, plugin, attr)
--   frontend/ui/widget/widget.lua:40  Widget:new(o) → if o.init then o:init() end
-- 合起来：**init() 里任何一处抛错，插件实例根本不会被创建**，只留下
--   logger.err("Failed to initialize", "<插件名>", "<错误>")
-- 一行日志，且不会弹给用户。
--
-- 用户侧的现象：插件主菜单消失 + 它注册的手势/按键动作消失；而 Dispatcher:execute 查到
-- 不存在的动作名时是**静默跳过**的（frontend/dispatcher.lua:1504 的
-- `if Dispatcher:isActionEnabled(settingsList[k])`，settingsList[k] == nil → 直接不执行、
-- 不报错）→ 表现为「首页手势点了没反应」。
--
-- 本插件原先 `Store.get()` 排在注册之前：store.lua 里要构造 Settings/Sync/Bookshelf/
-- ReadRecord 并读盘，任何一处因设备环境（配置损坏、目录不可写）抛错，都会顺手把
-- 「打开书架」这个动作一起弄哑。故拆开：
--   ① 动作注册最先，且不依赖任何模块（自身再包一层 pcall）；
--   ② 模块构造（含 Store.get()）整段 pcall，失败只降级为「插件不可用但仍在」；
--   ③ 主菜单注册单独 pcall。
function ReadingPlugin:init()
    pcall(function() self:onDispatcherRegisterActions() end)

    -- 让「首页被别的控件遮住」时也能收到 Dispatcher 派发的动作事件
    -- （原理见文件上方 ensure_dispatch_reachable 的注释）。
    -- 放在最前、且自身 pcall：它只做一次 table.insert，永远不会影响插件加载。
    pcall(function() ensure_dispatch_reachable(self) end)

    local ok_init, err_init = pcall(function() self:_init_modules() end)
    if not ok_init then
        self._init_error = tostring(err_init)
        pcall(function() Log.error("init 失败，插件降级为不可用：" .. tostring(err_init)) end)
    end

    if self.ui and self.ui.menu then
        pcall(function() self.ui.menu:registerToMainMenu(self) end)
    end

    Log.info("开源阅读插件初始化完成")
end

-- 真正做初始化（原 init 主体，逐字保留）。
function ReadingPlugin:_init_modules()
    -- 状态收敛到进程级单例（架构报告 §9-1 / P0-4）：
    -- FileManager 与每个 ReaderUI 实例共享同一份 settings / sync / bookshelf / read_record，
    -- 不再各自持有一套内存模型去并发读写同一批磁盘文件。
    local store = Store.get()
    self.settings = store.settings
    self.sync = store.sync
    self.bookshelf = store.bookshelf
    self.read_record = store.read_record

    -- 去抖上传的辅助状态（实例私有，见 reading/store.lua 顶部说明）：
    --   _last_seen_chapter / _last_seen_page：上一次位置回调观察到的章节与页码，
    --     用于判断「页码是否真的变了」，只有真的变了才重置去抖窗口；
    --   _pending_progress_upload：待执行的去抖上传定时器句柄（闭包引用，
    --     UIManager:unschedule 按函数引用匹配 —— scheduleIn 无返回值，只能自己存）。
    --   _pending_auto_compare：待执行的自动对比任务句柄（同上）。
    --     有两个触发点（打开书 / 回到前台），靠它在 onResume 连发时只保留最后一次。
    self._last_seen_chapter = nil
    self._last_seen_page = nil
    self._pending_progress_upload = nil
    self._pending_auto_compare = nil
    -- 详情页身份令牌：每次 show_book_detail 自增，异步回调据此判断
    -- 「这份云端检查结果还属不属于当前这本书的详情页」（见 book_detail.lua）。
    self._detail_token = 0

    -- 书架搜索关键字（会话级，不持久化）：书架左上角菜单「搜索」设置。
    -- 刻意放实例上而不是 settings —— 搜索是临时意图，重启 KOReader 后回到全量书架。
    self._shelf_filter_text = nil

    -- 书架渲染令牌（stale-while-revalidate 用）：每次 show() 自增。
    -- 后台静默刷新完成时用它判断「书架还是不是刚才那一次渲染」——不一致就说明用户
    -- 已经切走 / 又重新渲染过，此时重渲染会把用户当前看到的那一份冲掉。
    self._shelf_token = 0
    -- 上一次真正渲染出来的「内容键」（见 show() 的渲染去重）：键相同 + 菜单还在最上层
    -- 就不再重画。置 nil 表示「还不知道屏幕上是什么」，第一次 show() 必定渲染。
    self._shelf_last_content_key = nil
    -- 后台刷新「进行中」的时间戳（**不是**布尔，理由见 _maybe_bg_revalidate_shelf）。
    self._bg_refresh_started_at = nil

    -- 用于管理当前正在运行的异步任务的句柄集合。
    -- 刻意保持「实例级」：onClose 会无条件 _cancel_async() 取消本实例全部任务，
    -- 若共享则关闭阅读器会误杀书架实例正在跑的下载（见 reading/store.lua 顶部说明）。
    self._async_handles = {}

    -- 正在进行的「书籍下载」会话（**单槽位**）：{ handle=, progress=, on_dispose= }。
    -- 详情页「下载/更新书籍」与云端书库「下载」两条入口共用它 —— 此前各存各的字段
    -- （_download_epub_handle / _download_handle），互相取消不到，同一本书会起两个
    -- 子进程往同一个 save_path 写、并留下两个进度窗。见 downloader 文件顶部的
    -- 「书籍下载会话」一节。
    self._book_download = nil

    -- 缓存 LRU 清理（上限 + 过期）。**延迟到启动 5 秒之后**再跑：
    -- 插件 init 处在「插件加载 → UI 起来」这段最敏感的窗口里，而清理要遍历若干目录
    -- （几万次 lfs.attributes），放在这里会实打实地拖慢启动。内部还有进程级与
    -- 12 小时两道短路，不会反复扫盘。
    if UIManager then
        UIManager:scheduleIn(5, function()
            pcall(function() self:cleanup_caches() end)
        end)
    end

    -- 更新自检 + 启动后的自动检查。
    -- KOReader 会给 FileManager 与每个 ReaderUI 各 new 一个 Plugin，init 会被多次调用 ——
    -- 去重交给 updater_ui 内部的进程级标志（模块级 local 在同一 Lua VM 内共享）。
    -- 这里必须 pcall：本段跑在 init 内部，抛错会让整个插件不被加载（见 init 顶部注释）。
    if UpdaterUI then
        pcall(function() UpdaterUI.startup(self) end)
    end
end

--- 当前应当渲染的书架「内容键」。
--
-- 由「书籍数据指纹 + 所有会影响列表的输入」拼成：搜索关键字、排序键与方向、
-- 「仅显示已下载」。书籍数据部分复用 downloader.shelf_signature（已排序后再拼串，
-- 因此「顺序变化」不算内容变化 —— 顺序由排序键决定，已单独计入）。
--
-- 用途只有一个：show() 的**渲染去重**（见下）。键相同但显示不同是不可能的，
-- 因此它可以安全地用于「是否值得重画一屏」的判断。
function ReadingPlugin:_shelf_content_key()
    return table.concat({
        self:shelf_signature(self.bookshelf:get_books()),
        tostring(self._shelf_filter_text or ""),
        tostring(self.settings:get_shelf_sort()),
        tostring(self.settings:get_shelf_sort_asc()),
        tostring(self.settings:get_show_downloaded_only()),
    }, "|")
end

function ReadingPlugin:show()
    -- 标识当前实例类型（FileManager / ReaderUI），辅助定位书架空白问题
    local instance_type = (self.ui and self.ui.document) and "ReaderUI" or "FileManager"
    Log.info("show() 入口 [" .. instance_type .. "]")

    local cached_books = self.bookshelf:load_bookshelf_cache()
    Log.info("show() load_bookshelf_cache 返回: " .. (cached_books and #cached_books or "nil") .. " 本")

    -- 【渲染去重（墨水屏节流）】书架还没关、仍在最上层，且内容键与屏幕上那一份
    -- 完全相同时，直接返回 —— 再走一遍是「拆掉旧菜单 + 新建菜单 + 全屏重画」，
    -- 在墨水屏上有可见闪烁，而且会把用户翻到的页码打回第一页，纯亏。
    --
    -- 三条同时成立才跳过：句柄还在（菜单没被关掉）+ 内容键未变 + 就在最上层
    -- （被详情页/对话框盖住时不能跳过：那种情况下调用方要的是「把书架抬到前面」）。
    local content_key = self:_shelf_content_key()
    local current_menu = UIHandles.get("menu")
    if current_menu and content_key == self._shelf_last_content_key
        and self:is_widget_on_top(current_menu) then
        Log.info("show() 内容与当前渲染一致且书架在最上层，跳过重渲染")
        return
    end
    self._shelf_last_content_key = content_key

    -- 【书架渲染令牌】本次渲染的「身份」。后台静默刷新回来时比对它，
    -- 只有「还是这一次渲染」才允许原地换数据（见 _maybe_bg_revalidate_shelf）。
    self._shelf_token = (self._shelf_token or 0) + 1
    local shelf_token = self._shelf_token

    local books = self.bookshelf:get_books()
    Log.info("show() get_books 返回: " .. #books .. " 本")

    -- 构建阅读记录查找表（O(1) 替代原线性查找）
    local record_index = {}
    for __, rec in ipairs(self.read_record.records) do
        if rec.bookName then
            record_index[rec.bookName:lower()] = rec
        end
    end

    -- 先合并阅读记录到 books（self.bookshelf.books），排序依赖 lastCheckTime
    for ___, book in ipairs(books) do
        local title = book.name or book.title or ""
        if title ~= "" then
            local record = record_index[title:lower()]
            if record then
                book.lastCheckTime = record.lastRead or book.lastCheckTime or record.lastCheckTime
            end
        end
    end

    -- 排序 self.bookshelf.books（必须在构建 valid_books 之前，否则 valid_books 不受排序影响）
    self.bookshelf:sort_books()

    -- 从已排序的 books 构建 valid_books，保持排序顺序，同时进行 去重
    local show_downloaded_only = self.settings:get_show_downloaded_only()

    -- P1-7：原实现对每本书调 get_epub_for_book，每次都对本地文件列表跑一遍 O(M) 匹配，
    -- 整体 O(N×M)。这里预建一次索引，查询降到 O(1) 查表（详见 Bookshelf:build_downloaded_index）。
    local downloaded_index = nil
    if show_downloaded_only then
        downloaded_index = self.bookshelf:build_downloaded_index()
    end

    -- 书架搜索（会话级，见 init 里 _shelf_filter_text 的说明）：
    -- 匹配书名或作者，大小写不敏感、按字面匹配（find 第 4 参 true），
    -- 文件名/书名里的 . ( ) 等不会被当 pattern 元字符。
    local filter_kw = nil
    if self._shelf_filter_text and self._shelf_filter_text ~= "" then
        filter_kw = string.lower(self._shelf_filter_text)
    end

    -- 去重 + 「仅显示已下载」+ 搜索过滤 的统一实现。
    -- 这段循环原本被复制了两份（第二份用于「搜索把所有书都滤掉」时的回退重跑），
    -- 二者只差是否套用搜索关键字 —— 合并成一个函数，filter 传关键字或 nil。
    local function collect_valid_books(filter)
        local out = {}
        local seen = {}
        for ___, book in ipairs(books) do
            local title = book.name or book.title or ""
            local author = book.author or ""
            local unique_key = title .. "|" .. author
            local url = book.bookUrl or ""

            if title ~= "" and url ~= "" and not seen[unique_key] then
                local should_add = true
                if show_downloaded_only and not downloaded_index[title] then
                    should_add = false
                end
                if should_add and filter then
                    local hay = string.lower(title .. "\0" .. author)
                    if not string.find(hay, filter, 1, true) then
                        should_add = false
                    end
                end

                if should_add then
                    seen[unique_key] = true
                    out[#out + 1] = book
                end
            end
        end
        return out
    end

    local valid_books = collect_valid_books(filter_kw)

    if filter_kw and #valid_books == 0 then
        -- 搜索把所有书都滤掉了：提示并自动清除搜索（书架不比云端列表，
        -- 没有「保留旧列表」可言——show() 是全新渲染，困在空书架里连菜单都点不到几本书）。
        Log.info("show() 搜索 '" .. filter_kw .. "' 无匹配，清除搜索显示全部")
        self:showInfo(T(_("没有匹配「%1」的书籍，已显示全部"), self._shelf_filter_text))
        self._shelf_filter_text = nil
        filter_kw = nil
        -- 回退：重跑一遍不带筛选的收集
        valid_books = collect_valid_books(nil)
    end

    books = valid_books
    Log.info("show() valid_books 去重过滤后: " .. #books .. " 本，准备显示书架")

    -- 搜索生效时标题栏带 [关键字]（与云端书库筛选的显示约定一致）
    local shelf_title = _("书架")
    if filter_kw then
        shelf_title = shelf_title .. " [" .. self._shelf_filter_text .. "]"
    end

    UIHandles.set("menu", ShelfView.show{
        -- ⚠️ 这里只允许出现 ShelfView.show 真正消费的键（见 shelf_view.lua 顶部契约注释）。
        -- 历史上曾传入 bookshelf / settings / on_sync / on_sync_books / on_settings，
        -- 而 ShelfView 一个都没读 —— 于是 on_sync_books 指向的 sync_epub_files（129 行）
        -- 成了「传了但永远不会被调用」的死代码。传参式接口写错名字不会报错，
        -- 只会静默失效，所以新增键时必须同时改 shelf_view.lua。
        books = books,
        title = shelf_title,
        on_select = function(book)
            self:show_book_detail(book)
        end,
        on_left_button_tap = function(menu_instance)
            self:show_sort_dialog(menu_instance)
        end,
        on_close = function()
            UIHandles.clear("menu")
        end,
    })
    -- 不再另设 active_menu 句柄：它永远与 menu 同指同一个 widget，而 UIHandles.set
    -- 在注册同名句柄时会先关掉旧值 —— 于是「打开书架」这一步会对刚刚被
    -- set("menu", ...) 关掉的旧菜单**再 close 一次**（UIManager:close 在窗口栈里
    -- 找不到它，但照样发 FlushSettings + CloseWidget）。
    -- 需要「当前书架菜单」的地方一律用 UIHandles.get("menu")。

    -- 【stale-while-revalidate】上面已经用本地缓存把书架画出来了（打开书架零等待），
    -- 这里再判断缓存是否已陈旧，陈旧就在**后台**补一次同步，成功后原地换新数据。
    -- 放在渲染之后：先让用户看到东西，再补网络 —— 顺序反过来就是「打开书架要等网络」。
    self:_maybe_bg_revalidate_shelf(shelf_token)
end



return ReadingPlugin
