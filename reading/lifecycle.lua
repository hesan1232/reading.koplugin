--[[
    插件生命周期钩子（关闭、翻页、休眠前落盘）与日志查看。

    本文件由 `main.lua` 按职责拆出（架构报告 §9-2 / P0-6）。
    函数以「同名 mixin」方式合并回 `ReadingPlugin`：方法名与调用约定与拆分前完全一致，
    因此 `main.lua` 中的调用点（`self:xxx()`）无需任何改动。

    文件顶部的 require 前导是**自动推导**的：只列出本文件函数真正引用的自由变量，
    由 `lua_upvalue_lint.py`（作用域感知，非 grep）校验过，不存在漏引用的 upvalue。
]]

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
local UIManager = safe_require("ui/uimanager")
local InfoMessage = safe_require("ui/widget/infomessage")
local H = require("reading.helper")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or function(str, ...) return str end
local Log = safe_require("reading.log")
local Context = require("reading.reading_context")
-- UI 句柄管理（替代原 _state 中的 UI 字段，修复 chapter_list_menu 泄漏）
local UIHandles = require("reading.ui_handles")

local M = {}

--- 位置变化后、真正上传进度前的等待时长（秒）—— **尾部去抖**。
--
-- 对齐 Legado 的语义（legado-E-main ……/ReadBookActivity.kt:1667 `delay(300000)`）：
-- 窗口由「页面变化」触发、**每一次变化都把窗口整体推后**，只有「停下不动满整个窗口」
-- 才认为这段阅读已经稳定，可以上传。所以它是「停止阅读后多久同步」，
-- 而不是「最多攒多久同步一次」。
--
-- 【为什么不能「一变就上传】「从目录跳到第 500 章」是**导航**行为，
-- 不等于「我读到第 500 章了」。若一变就立刻推上云端，用户紧接着点「拉取云端进度」
-- 拿到的云端值已等于本地 → 永远显示「进度一致」，「跳回云端那一章」的选择权
-- 就被自己的上传抹掉了。窗口内再有任何位置变化都会重新计时。
--
-- 【为什么是 60 秒而不是 Legado 的 300 秒】读者**单页停留**通常远短于 60 秒，
-- 连续阅读期间窗口被不断推后，真正的上传只发生在放下设备之后；而退出阅读界面时
-- onCloseDocument 还会无条件上传一次兜底，所以窗口不必长到 5 分钟也不会丢进度。
local PROGRESS_UPLOAD_DEBOUNCE_SEC = 60

function M.view_log(self)
    local content, err = Log.read_log_content(5000)
    if content then
        UIManager:show(InfoMessage:new{
            text = content,
            timeout = 0,
        })
    else
        self:showInfo(T(_("查看日志失败: %1"), tostring(err)), false)
    end
end

function M.onClose(self)
    -- 先收掉「书籍下载」会话：它自带进度窗（DownloadProgress）与 busy 提示，
    -- 而下面的 _cancel_async() 只会杀掉子进程 —— 被取消的异步任务不会再回调 on_done，
    -- 于是进度窗会永久留在屏幕上。这条路径真实存在：从文件管理器打开一本书 /
    -- 退出 KOReader 都会触发本实例的 onCloseWidget → onClose。
    self:_cancel_book_download()

    -- 清理所有未完成的异步任务，防止插件关闭后回调仍被触发
    self:_cancel_async()

    -- 取消待执行的去抖上传定时器：否则插件销毁后回调仍会跑一次上传
    self:_cancel_pending_progress_upload()

    -- 取消待执行的自动对比：否则销毁后回调仍会弹一个「进度同步」框
    self:_cancel_pending_auto_compare()

    -- 一次性关闭所有 UI 句柄（close_all 遍历 _handles 全表，新增句柄自动覆盖）
    -- 修复原 _state 中 current_chapter_list_menu 在 onClose 未被清理的泄漏 bug
    UIHandles.close_all()
end

function M.onCloseWidget(self)
    self:onClose()
end

--- 把「本地进度」相关的内存改动落盘 —— **纯本地，不发任何网络请求**。
--
-- 由两条路径共用：
--   · `onCloseDocument`（关闭阅读界面）
--   · `onFlushSettings`（设备准备休眠 / 系统要求保存状态前发来的第一个事件）
--
-- 【为什么必须抽出来共用】阅读过程中这些字段刻意**只留在内存里**累积 ——
-- 见 onPageUpdate 的跨章分支：`book.durChapterTime / lastCheckTime` 只在内存更新，
-- 那里写明「书架缓存写盘推迟到 onCloseDocument，避免翻页阻塞 UI」。
-- 若只有 onCloseDocument 一条落盘路径，那么「息屏之后直接关机 / 断电 / 被系统杀进程」
-- 就永远走不到它 —— 用户看到的是书架上这本书的「最近阅读时间」倒退，排序也跟着乱。
--
-- 【为什么不顺手在这里上传】准备休眠的那一刻 Wi-Fi 正在被关闭
-- （`NetworkListener:onSuspend` → `NetworkMgr:disableWifi()`），且 `Device:_beforeSuspend`
-- 是**同步**调用链，在里面等一个 HTTP 往返会拖住休眠（按下电源键后屏幕迟迟不灭）。
-- 上传始终交给 onCloseDocument 与去抖窗口两条路径。
--
-- 【阅读进度本身不会丢】`book.durChapterIndex` 每次都是由**当前页码反推**的
-- （onPageUpdate / _refresh_current_progress），不是累积状态；即便书架缓存落后，
-- 翻开书后立刻重算正确。真正会丢的只有 `durChapterTime` / `lastCheckTime`
-- 这类「展示 / 排序」字段，以及只活在内存里的阅读记录。
function M._persist_local_progress(self)
    local book = Context.get_current_book()
    if not book then return end

    -- TOC 对齐锚点表也在内存里攒着，脏了就一起落盘。
    -- 注：onCloseDocument 在本函数之前还有一次同样调用，那一次是为了兜住
    -- 「关闭的不是插件目录下的书、Context 已无当前书」的场景；走到这里说明有当前书，
    -- 那一处若已落盘则 _toc_anchors_dirty 已被清掉，这里是空操作。
    if book._toc_anchors_dirty then
        self:_save_toc_anchors(book)
    end

    local now_ms = os.time() * 1000
    book.durChapterTime = now_ms
    book.lastCheckTime = now_ms
    self.read_record:update_record(
        book.bookUrl,
        book.name or book.title or "",
        0,
        now_ms
    )
    -- 统一持久化阅读记录（update_record 仅更新内存，写盘推迟到此处避免切章阻塞）
    if self.read_record._dirty then
        self.read_record:save_records()
        self.read_record._dirty = false
    end
    self:_refresh_current_progress()
    -- 持久化 lastCheckTime 到书架缓存，确保书架排序能反映最近阅读时间
    self.bookshelf:save_bookshelf_cache(self.bookshelf:get_books())
end

function M.onCloseDocument(self)
    if not self.ui or not self.ui.document then return end

    -- 以“正在关闭的文档”自身路径为准判断，不依赖可能已被切书覆盖的 Context
    local closing_doc_path = self.ui.document.file or self.ui.document.path or ""
    if closing_doc_path == "" then return end

    -- 位置回调的「上次观察值」跟随文档生命周期失效 —— 放在最前面，**包括**那些
    -- 不属于本插件目录的书：页码是每本书各自编号的，若关闭别的书时不清，
    -- 「打开插件书 → 打开别的书 → 再打开插件书」会让上一本的页码残留下来，
    -- 把新书的首帧误判成「翻页」，凭空安排一次上传（进而静默覆盖云端进度）。
    self._last_seen_chapter = nil
    self._last_seen_page = nil
    
    -- 兜底刷盘：如果当前书籍的锚点表有未保存的修改，立即保存
    local book = Context.get_current_book()
    if book and book._toc_anchors_dirty then
        self:_save_toc_anchors(book)
    end

    local books_dir = H.get_books_dir()
    -- 只处理 reading 插件目录下的书籍
    if closing_doc_path:lower():sub(1, books_dir:lower():len()) ~= books_dir:lower() then
        return
    end

    -- 取消待执行的去抖上传：本函数稍后会用快照自己上传一次，留着定时器会重复上传
    -- （位置观察值已在函数开头清掉了，那里还覆盖了「关闭的不是插件目录下的书」的情况）
    self:_cancel_pending_progress_upload()

    -- 取消待执行的自动对比：onResume 排的那次可能还没到点（0.5 秒延迟 + 网络往返），
    -- 留着就会在文档已经关掉之后弹「进度同步」框。
    self:_cancel_pending_auto_compare()

    -- 切书场景：open_epub_book 已把 Context 指向新书，此时旧文档关闭，
    -- 不应上传新书进度、更不能 clear_reading_context（否则丢失新书的 current_book 与 pending_jump）。
    local ctx_path = Context.get_current_epub_path()
    local is_switching = ctx_path ~= nil
        and ctx_path:lower() ~= closing_doc_path:lower()

    if is_switching then
        Log.info("onCloseDocument: 检测到切书（上下文已指向新书 " .. tostring(ctx_path) .. "），跳过上传与清理")
        return
    end

    if not ctx_path then return end

    Log.info("阅读界面关闭，保存进度: " .. closing_doc_path)

    -- 更新阅读记录并刷新进度（与 onFlushSettings 共用同一套本地落盘动作），
    -- 随后通过 Context.snapshot_progress() 捕获快照（含 generation 令牌）再上传
    self:_persist_local_progress()

    -- 使用快照数据上传，不依赖 Context 全局状态（清理后仍可安全上传）
    local snapshot = Context.snapshot_progress()
    if snapshot then
        local gen = snapshot.generation
        local sync_ref = self.sync
        self:_async_run(
            function()
                local ok, __, err = sync_ref:upload_book_progress(
                    snapshot.name,
                    snapshot.author,
                    snapshot.durChapterIndex,
                    snapshot.durChapterPos,
                    snapshot.durChapterTitle
                )
                return { ok = ok, err = err }
            end,
            function(ok, result, err)
                -- 令牌校验：若关闭后又打开了新书籍，放弃旧快照上传结果
                if Context.get_generation() ~= gen then
                    Log.debug("关闭文档上传: 阅读会话已变更，放弃旧快照")
                    return
                end
                if ok and result and result.ok then
                    Log.info("关闭文档时自动上传进度成功: " .. snapshot.name)
                else
                    Log.warn("关闭文档时自动上传进度失败: " .. snapshot.name .. ", " .. tostring(err or (result and result.err)))
                end
            end,
            { timeout = 30 }
        )
    end

    -- 统一清理阅读上下文（generation 不重置，旧异步回调仍能识别过期）
    Context.clear_reading_context()
end

--- 系统要求「保存状态」时的钩子 —— 设备准备休眠 / 息屏前的**第一个**事件，比 `Suspend` 更早。
--
-- 【为什么要它】阅读进度相关的内存改动只在 onCloseDocument 落盘（见
-- `_persist_local_progress`）。而 `onCloseDocument` 只有「正常退出阅读界面」才会走到；
-- 「正在读书 → 息屏 → 直接关机 / 断电 / 被系统杀掉进程」这条路走不到它，
-- 于是书架上的「最近阅读时间」会退回上一次落盘的值（排序也跟着倒退）。
--
-- 【事件是怎么到这里的】`Device:_beforeSuspend` 的第一步就是 `UIManager:flushSettings()`
-- （koreader-master/frontend/device/generic/device.lua:1071-1073），
-- 而 `UIManager:flushSettings()` 就是 `broadcastEvent(Event:new("FlushSettings"))`
-- （ui/uimanager.lua:1683-1685）—— 广播给窗口栈上每个 widget，于是作为 ReaderUI
-- 注册模块的本插件会经 `WidgetContainer:propagateEvent` → `EventListener:handleEvent`
-- （按 `"on"..事件名` 取方法名）收到它。同为触发点的还有 `SaveState` 输入事件
-- （uimanager.lua:55-57）与 Android 的 `APP_CMD_PAUSE`（device/android/device.lua:150）。
-- 上游先例：`ReaderUI:onFlushSettings`（saveSettings）、`FileManager:onFlushSettings`、
-- `SwitchPlugin:onFlushSettings`（`self.settings:flush()`）。
--
-- ⚠️ **不能返回 true**：本插件是 ReaderUI 的子模块之一，而
-- `WidgetContainer:propagateEvent` 一旦遇到返回 true 的子模块就**停止转发** ——
-- 排在插件后面的模块再也收不到 FlushSettings，它们的设置就不会被保存。
-- 上游那几个 onFlushSettings 实现同样都不返回值。
--
-- 【只落盘，绝不上传/弹窗】理由见 _persist_local_progress 的注释：此刻 Wi-Fi 正在被关，
-- 且这条调用链是同步的，等网络会拖住休眠。
function M.onFlushSettings(self)
    -- FlushSettings 是**广播**事件：文件管理器（主页面）上的那个插件实例同样会收到。
    -- 没有当前阅读会话时直接返回，既不去动 Context，也省掉一次无谓的书架缓存写盘。
    if not Context.get_current_epub_path() then return end
    if not self.ui or not self.ui.document then return end

    Log.debug("收到 FlushSettings，落盘本地进度（仅本地，不上传）")
    self:_persist_local_progress()
end

function M.onPageUpdate(self, pageno)
    if not Context.get_current_epub_path() then return end

    if not self.ui or not self.ui.document then return end

    local book = Context.get_current_book()
    if not book then return end

    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return end

    local toc = self:_get_doc_toc(doc, book)
    if toc and #toc > 0 then
        local cache = Context.get_chapter_range_cache()

        -- 快速路径：页码在缓存的章节范围内，O(1) 计算位置
        if cache and pageno >= cache.start_page and pageno < cache.end_page then
            local chapter_pages = cache.end_page - cache.start_page
            local chapter_pos = 0
            if chapter_pages > 0 then
                chapter_pos = math.floor((pageno - cache.start_page) / chapter_pages * 1000)
            end
            -- EPUB TOC 索引转换为 Legado 章节索引（0-based）
            local legado_index = self:_get_legado_index(book, cache.chapter_index, toc)
            if legado_index < 0 then legado_index = 0 end
            book.durChapterIndex = legado_index
            book.durChapterPos = chapter_pos
            book.durChapterTitle = cache.chapter_title
        else
            -- 慢路径：跨章了，扫描 TOC 找到新章节
            -- 扫描逻辑与 progress._refresh_current_progress 共用一份实现
            -- （抽到 toc_align._scan_toc_for_page；此前两处逐行复制，已因漂移出过 bug）。
            local chapter_index, chapter_pos, current_start, next_start, chapter_title =
                self:_scan_toc_for_page(toc, pageno, total_pages)

            -- 更新缓存（存 EPUB 原生索引 + 原生标题）
            Context.set_chapter_range_cache({
                start_page = current_start,
                end_page = next_start,
                chapter_index = chapter_index,
                chapter_title = chapter_title,
            })

            -- EPUB TOC 索引转换为 Legado 章节索引（0-based）
            local legado_index = self:_get_legado_index(book, chapter_index, toc)
            -- 标题验证：处理"作者有话说"等动态插入导致偏移量失效
            local verified_index = self:_verify_legado_index_by_title(book, chapter_title, legado_index)
            if verified_index then
                legado_index = verified_index
                self:_add_toc_anchor(book, verified_index, chapter_index, chapter_title)
            elseif legado_index < 0 then
                legado_index = 0
            end
            book.durChapterIndex = legado_index
            book.durChapterPos = chapter_pos
            book.durChapterTitle = chapter_title
            -- 跨章时更新阅读时间（仅内存），书架缓存写盘推迟到 onCloseDocument，避免翻页阻塞 UI
            local now_ms = os.time() * 1000
            book.durChapterTime = now_ms
            book.lastCheckTime = now_ms
        end
    else
        local progress_percent = pageno / total_pages
        book.durChapterPos = math.floor(progress_percent * 1000)
    end

    -- 【去抖锚点 = 页码变化，而不是「章节变化」】
    --
    -- Legado 的窗口由 pageChanged() 触发，也就是**每一页**都会把窗口推后；
    -- 本插件此前只在 durChapterIndex 变化时才重置窗口，同章内的连续翻页**不重置** ——
    -- 于是「跳到某章 → 快速翻 60 秒 → 窗口到点上传」会把进度记在一个其实还没读到的
    -- 位置上（用户以为只是快速扫过，云端却已经认定他读到这里）。
    -- 现在每次页码变化都重新计时，语义与 Legado 一致：「停下不动满
    -- PROGRESS_UPLOAD_DEBOUNCE_SEC 秒」才算读稳了，才值得写回云端。
    --
    -- 判据为什么是「页码」而不是「位置/滚动量」：本函数算出的 durChapterIndex /
    -- durChapterPos / durChapterTitle **全部由 pageno 推导**，所以「页码没变」严格等价于
    -- 「要上传的内容没变」，此时不重置窗口不会有任何后果；而滚动模式下跨页滚动
    -- 同样会改变 pageno，因此不会漏掉「真的读下去了」的场景。
    --
    -- 另一个必须用 `prev_page ~= nil` 兜住的情形：进入阅读界面、切书、从内存恢复位置
    -- 都会先上报一次**当前位置**，那不是用户操作。若把它当成一次翻页，就会出现
    -- 「打开书什么都不做，60 秒后本地进度静默覆盖云端」—— 那会连带废掉弹窗里
    -- 「保持本地进度」这个选项的区分度（它和「用本地覆盖云端」就变成一回事了）。
    local current_chapter = book.durChapterIndex
    if current_chapter ~= self._last_seen_chapter then
        -- 仅用于日志：区分「跨章」与「同章内翻页」；两者都会同样重置窗口。
        self._last_seen_chapter = current_chapter
        Log.debug("位置更新跨章: " .. tostring(current_chapter))
    end

    local prev_page = self._last_seen_page
    self._last_seen_page = pageno
    if prev_page and prev_page ~= pageno
        and self.settings:is_progress_auto_sync_enabled() then
        self:_schedule_progress_upload()
    end
end

--- 滚动模式（view_mode = "scroll"）下的位置更新钩子。
--
-- 【为什么必须有它】KOReader 只在**分页模式**下发 PageUpdate；滚动模式发的是
-- PosUpdate —— 见 koreader-master/frontend/apps/reader/modules/readerrolling.lua
-- 的四处分发（1087-1093 / 1161-1164 / 1195-1200 / 1683-1689），**全部**位于
-- `view_mode ~= "page"` 分支内（1195-1200 是最典型的：page 分支发 PageUpdate，
-- else 分支发 PosUpdate）。上游每一个关心「当前页」的模块都两个都实现，
-- 或直接设别名（`ReaderLink.onPosUpdate = ReaderLink.onPageUpdate`），
-- 或用 (pos, pageno) 签名（ReaderFooter / ReaderToc）。
--
-- 本插件此前**只实现了 onPageUpdate** —— 于是滚动模式下所有位置变化（翻页、
-- 滚动、**从目录跳章**）都收不到通知：book.durChapterIndex 停在旧值，
-- 再点「拉取云端进度」就是拿旧值去和云端比，结论自然是「进度一致」。
--
-- @param pos number     文档位置（滚动像素偏移，本插件不用）
-- @param pageno number  当前页号（与 doc:getPageCount() 同一坐标系）
function M.onPosUpdate(self, pos, pageno)
    if not pageno then return end
    self:onPageUpdate(pageno)
end

--- 设备从休眠/后台「回到前台」时，自动拉取一次云端进度做对比。
--
-- 【为什么需要它】插件此前只在**打开书**（`onReaderReady`）时对比一次。若用户让一本书
-- 一直开着、只是反复息屏，那他永远发现不了「另一端已经读得更靠前」——
-- 而这恰恰是进度同步插件最该提醒的场景。Legado 的做法就是把自动拉取挂在页面生命周期上
-- （`onResume` / 网络恢复），本函数与之对齐。
--
-- 【事件是怎么到这里的】Suspend/Resume 是**广播事件**：`Device:_beforeSuspend` 与
-- `Device:_afterResume` 分别 `UIManager:broadcastEvent(Event:new("Suspend"/"Resume"))`
-- （koreader-master/frontend/device/generic/device.lua:1071-1097；Android 上对应
-- `APP_CMD_RESUME` → device/android/device.lua:177-180）。
-- `broadcastEvent` 把事件交给窗口栈上每个 widget 的 `handleEvent`，而插件实例是
-- ReaderUI 的注册模块（readerui.lua:464-478 → `registerModule`），
-- 于是基类 `EventListener:handleEvent` 会按 `"on"..事件名` 的约定调到本函数。
--
-- 【为什么不顺手在 onSuspend 里补上传】两条硬理由：
--   ① 息屏前 WiFi 正在被关（`NetworkListener:onSuspend` → `NetworkMgr:disableWifi()`），
--      此刻的 HTTP 上传本就不可靠；
--   ② `Device:_beforeSuspend` 是**同步**调用链，在里面等网络会拖住休眠，
--      用户按下电源键后屏幕迟迟不灭。
-- 兜底本来就有：醒来后退出阅读界面会由 `onCloseDocument` 无条件上传一次。
function M.onResume(self)
    -- Resume 是广播事件，**文件管理器（主页面）上的插件实例同样会收到**，
    -- 所以必须先确认「当前确实在读插件目录下的一本书」，否则会在书架界面白发网络请求。
    if not Context.get_current_epub_path() then return end
    if not self.ui or not self.ui.document then return end

    -- 复用「打开书」那条链路：同样的 silent 语义（只有云端更靠前才打断）、
    -- 同样的 generation 令牌校验，以及自动去重（见 _auto_pull_and_compare）。
    --
    -- 唤醒时屏保还盖在最上层，那边会先等屏保退场再弹框（ButtonDialog 默认会吃掉
    -- 全屏点击，否则用户「点一下关屏保」的那一记会被弹框抢走）—— 细节见那边注释。
    self:_auto_pull_and_compare()
end

--- 安排一次去抖的进度上传（同一时刻只保留一个待执行任务）。
--
-- ⚠️ `UIManager:scheduleIn` **没有返回值**（koreader-master/frontend/ui/uimanager.lua:13502
-- 内部只调 `self:schedule(when, action)`），所以必须自己把闭包存下来当句柄 ——
-- `UIManager:unschedule(action)` 是按**函数引用**匹配的。
--
-- 句柄**只创建一次并复用**：本函数在每次位置更新（翻页 / 滚动）时都会被调用，
-- 若每次都新建闭包，等于在翻页热路径上给 GC 添堵。上传内容由 `save_read_progress`
-- 从 `book` 现取，所以复用同一个闭包不需要携带任何参数。
function M._schedule_progress_upload(self)
    if not self._pending_progress_upload then
        local self_ref = self
        self._pending_progress_upload = function()
            self_ref._pending_progress_upload = nil
            self_ref:save_read_progress()
        end
    end

    -- 重新计时：先撤销队列里的旧项，再排新的。
    -- `unschedule` 找不到匹配项时是空操作；而**不撤销**直接 scheduleIn 会在
    -- 任务队列里堆出多份同一个 action（schedule 不去重），窗口就形同虚设。
    UIManager:unschedule(self._pending_progress_upload)
    UIManager:scheduleIn(PROGRESS_UPLOAD_DEBOUNCE_SEC, self._pending_progress_upload)
end

--- 取消待执行的去抖上传（关闭文档 / 手动跳章时调用）。
function M._cancel_pending_progress_upload(self)
    if self._pending_progress_upload then
        UIManager:unschedule(self._pending_progress_upload)
        self._pending_progress_upload = nil
    end
end

return M
