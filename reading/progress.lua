--[[
    阅读进度链路：章节加载、阅读记录、云端进度拉取/推送/跳转。

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
local InputDialog = safe_require("ui/widget/inputdialog")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or function(str, ...) return str end
local Device = safe_require("device")
local ShelfView = safe_require("reading.shelf_view")
local Log = safe_require("reading.log")
local Context = require("reading.reading_context")
-- UI 句柄管理（替代原 _state 中的 UI 字段，修复 chapter_list_menu 泄漏）
local UIHandles = require("reading.ui_handles")

local M = {}

--- 「进度同步」选择框在 UIHandles 里的句柄名。
--
-- 用它而不是用 local 变量持有对话框，是为了拿到两件现成的东西：
--   ① 「同名句柄只留一个」—— `UIHandles.set` 注册同名句柄时会先关掉旧的；
--   ② 插件关闭时 `UIHandles.close_all()` 会一并收掉它（local 变量做不到）。
-- 附带好处：三个按钮不再需要引用正在构造的那个 `dialog`，
-- 于是彻底绕开了 `local dialog = ButtonDialog:new{ ... dialog ... }` 那个陷阱
-- （Lua 的 local 作用域从声明行**之后**才开始，闭包捕获到的是全局 nil）。
local PROGRESS_DIALOG_HANDLE = "progress_dialog"

--- 自动对比的首次延迟（秒）。与原「打开书」路径保持一致：等界面稳定下来再发网络请求。
local AUTO_COMPARE_DELAY_SEC = 0.5

--- 屏保还盖在最上层时的轮询间隔与最大次数（0.5 × 20 = 最多等 10 秒）。
-- 见 `_auto_pull_and_compare` 里「屏保还盖着就先不弹」那段说明。
local AUTO_COMPARE_SCREENSAVER_POLL_SEC = 0.5
local AUTO_COMPARE_SCREENSAVER_MAX_TRIES = 20

function M._load_chapters_from_document(self, retry_count)
    retry_count = retry_count or 0
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance

    if not reader or not reader.document then
        -- ReaderUI 尚未就绪，重试而不是直接返回（避免丢失 pending_jump）
        if retry_count < 6 and Context.get_current_epub_path() then
            Log.warn("_load_chapters_from_document: ReaderUI未就绪，0.5秒后重试 (" .. (retry_count + 1) .. "/6)")
            UIManager:scheduleIn(0.5, self:_guard(_("加载章节"), function()
                self:_load_chapters_from_document(retry_count + 1)
            end))
        else
            Log.error("_load_chapters_from_document: ReaderUI实例或文档为空，放弃重试")
            self:closeBusy()
        end
        return
    end

    -- 本函数语义就是「从文档重新加载目录」，所以先让 doc 上的 TOC 缓存失效再取，
    -- 并统一走 _get_doc_toc —— 否则会出现**两份目录不一致**：
    -- Context.get_current_chapters() 是刚重建的，而 doc._reading_toc 还是旧的，
    -- 于是 onPageUpdate 按新目录算出的索引，被 _refresh_current_progress 用旧目录解释。
    reader.document._reading_toc = nil
    local toc = self:_get_doc_toc(reader.document, Context.get_current_book())
    if toc and #toc > 0 then
        -- 先在局部表里攒好再一次性交出去。
        -- 原实现在循环里反复调 `table.insert(Context.get_current_chapters(), ...)`：
        -- 2000 章的书 = 2000 次多余的 getter 调用 + 2000 次无预分配、可能重复 rehash
        -- 的 insert。本函数只由「打开书 / 手动刷新目录」触发（中低频），
        -- 但改法零风险，且与 ShelfView 里的写法一致。
        local chapters = {}
        for ___, entry in ipairs(toc) do
            local title = entry.title or ""
            chapters[#chapters + 1] = {
                name = title,
                -- 预处理并缓存 normalize 后的标题，优化查找效率
                norm_name = title:gsub("%s+", ""),
                xpointer = entry.xpointer or "",
                page = entry.page or 1,
            }
        end
        Context.set_current_chapters(chapters)
        Log.info("加载目录完成，共 " .. #chapters .. " 章")
    else
        Log.warn("_load_chapters_from_document: 目录为空")
        Context.set_current_chapters({})
    end

    if Context.get_pending_jump() then
        Log.info("执行待处理的跳转: 第" .. Context.get_pending_jump().chapter_index .. "章, 位置: " .. Context.get_pending_jump().chapter_pos)
        local legado_index = Context.get_pending_jump().chapter_index
        local chapter_pos = Context.get_pending_jump().chapter_pos
        local chapter_title = Context.get_pending_jump().chapter_title or ""
        Context.set_pending_jump(nil)

        if Context.get_current_chapters() and #Context.get_current_chapters() > 0 then
            -- 跳转逻辑与 _jump_to_cloud_progress 共用（原先两处逐行重复约 40 行，已漂移过一次）
            self:_jump_to_legado_chapter(Context.get_current_book(), legado_index, chapter_pos,
                chapter_title, "pending_jump ")
        else
            Log.warn("_load_chapters_from_document: 目录为空，无法跳转")
            self:showInfo(_("目录为空，无法跳转"))
        end
    end

    self:closeBusy()
end

function M.show_chapter_list(self)
    local book = Context.get_current_book()
    local chapters = Context.get_current_chapters()

    if not book then
        self:showInfo(_("请先选择书籍"))
        return
    end
    if not chapters or #chapters == 0 then
        self:showInfo(_("目录未加载"))
        return
    end

    -- chapters 是 **EPUB TOC**（_load_chapters_from_document 从 doc:getToc() 构建），
    -- 而 book.durChapterIndex 是 **Legado 0-based** —— 两者之间存在由 toc_anchors
    -- 校准出的偏移，不能靠 ±1 硬转，否则章节列表的高亮与跳转都会差 offset 个章节。
    -- 统一走 _get_epub_index / _get_legado_index（无锚点时它们自然退化为 ±1 的恒等映射）。
    local current_chapter_index = self:_get_epub_index(book, book.durChapterIndex or 0, chapters)

    if current_chapter_index < 1 then
        current_chapter_index = 1
    end
    if current_chapter_index > #chapters then
        current_chapter_index = #chapters
    end

    UIHandles.set("chapter_list_menu", ShelfView.show_chapter_list(
        chapters,
        current_chapter_index,
        function(index)
            -- 回调拿到的 index 是 chapters 的 1-based 行号（= EPUB TOC 索引），
            -- 而 read_chapter 期望 Legado 0-based，必须经锚点换算。
            self:read_chapter(self:_get_legado_index(book, index, chapters))
        end,
        function()
            self:refresh_toc()
        end,
        book.name or book.title or "目录"
    ))
end

--- 「按章号直达」输入框。
--
-- 章号以**章节列表里看到的行号**为准（1 ~ 总章数，即 EPUB TOC 的 1-based 行号），
-- 因为那才是用户在「显示目录」里逐条数出来的东西。上游 Menu 自带的
-- 「长按页码 → Go to page」只能输入**页码**，2000 章的书得先自己心算
-- 「2000 / 每页条数」才能用 —— 这就是 1.5 里说的「发现性为零」。
--
-- 跳转本身与「在章节列表里点第 N 行」**完全一致**（同样经 _get_legado_index 换算 →
-- read_chapter），刻意不走 _jump_to_legado_chapter 的标题匹配：用户已经明确指定了行号，
-- 再按标题把目标反推回去，反而可能落到别处。
--
-- 跳转成功**不额外弹提示**：read_chapter 已经是「点列表行」那条路径的反馈方式
-- （画面跳到目标章、页眉/进度条跟着变），而且它在失败时自己会弹
-- 「无法跳转到第 N 章」—— 这里再补一条成功提示就会在失败时叠出两个弹窗。
function M.show_chapter_jump_dialog(self)
    local book = Context.get_current_book()
    local chapters = Context.get_current_chapters()

    if not book then
        self:showInfo(_("请先选择书籍"))
        return
    end
    if not chapters or #chapters == 0 then
        self:showInfo(_("目录未加载"))
        return
    end
    if not InputDialog then
        self:showInfo(_("输入框组件不可用"), false)
        return
    end

    local total = #chapters

    -- 注意 `local dialog` 必须先声明再由回调引用：`local dialog = InputDialog:new{ ... dialog ... }`
    -- 里的闭包捕获的是全局 dialog（Lua 的 local 作用域从声明行之后才开始），运行期为 nil。
    local dialog
    dialog = InputDialog:new{
        title = T(_("跳转到章节（1 - %1）"), tostring(total)),
        input = "",
        input_type = "number",   -- 唤出数字键盘
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("跳转"),
                    is_enter_default = true,
                    callback = function()
                        local n = tonumber(dialog:getInputText())
                        UIManager:close(dialog)
                        if not n then
                            self:showInfo(_("请输入有效的章号"))
                            return
                        end
                        n = math.floor(n)
                        if n < 1 then n = 1 end
                        if n > total then n = total end
                        self:read_chapter(self:_get_legado_index(book, n, chapters))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M.refresh_toc(self)
    if UIHandles.get("chapter_list_menu") then
        UIManager:close(UIHandles.get("chapter_list_menu"))
    end

    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    if not reader or not reader.document then
        self:showInfo(_("请先打开书籍"))
        return
    end

    -- 直接从当前文档重新加载目录，无需重开书籍。
    -- 重开（open_epub_book）会触发 onCloseDocument，对同一本书会清理 current_book，导致进度同步失效。
    self:_load_chapters_from_document()
    self:show_chapter_list()
end

function M.read_chapter(self, chapter_index, chapter_pos)
    -- chapter_index: Legado 0-based 章节索引
    chapter_pos = chapter_pos or 0

    if UIHandles.get("chapter_list_menu") then
        UIManager:close(UIHandles.get("chapter_list_menu"))
    end

    local book = Context.get_current_book()
    local chapters = Context.get_current_chapters()

    if not book then
        self:showInfo(_("请先选择书籍"))
        return
    end
    if not chapters or #chapters == 0 then
        self:showInfo(_("目录未加载"))
        return
    end

    -- 获取 TOC 偏移量：epub_1based = legado_0based + toc_offset (已废弃，改用锚点表)
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    -- 与进度计算共用同一份缓存，避免"两处各取一份目录"带来的索引口径不一致
    local toc = reader and reader.document and self:_get_doc_toc(reader.document, book) or nil

    -- 转换为 EPUB TOC 1-based 索引（用于查 chapters 表和 toc 表）
    local epub_index = self:_get_epub_index(book, chapter_index, chapters)

    -- 标题验证（反向）：从 Legado 章节列表获取标题，在 EPUB TOC 中查找
    -- 处理"作者有话说""紧急求助"等动态插入导致偏移量失效的情况
    -- 注意：这里固定传 chapters，因为最终查表用的是 chapters，toc 只在算页码时用
    local verified_epub = self:_verify_epub_index_by_title(book, chapter_index, chapters)
    if verified_epub then
        epub_index = verified_epub
        -- 修复：标题命中后，动态更新锚点
        local anchor_title = chapters[verified_epub] and (chapters[verified_epub].name or chapters[verified_epub].title) or ""
        self:_add_toc_anchor(book, chapter_index, verified_epub, anchor_title)
    end

    -- 边界保护（epub_index 是 1-based）
    if epub_index < 1 then epub_index = 1 end
    if epub_index > #chapters then epub_index = #chapters end

    -- 反算合法的 Legado 索引（防止越界后数据不一致）
    local legado_index = self:_get_legado_index(book, epub_index, chapters)
    if legado_index < 0 then legado_index = 0 end

    Log.debug("read_chapter: Legado " .. chapter_index .. " -> EPUB " .. epub_index)

    -- 用 EPUB 1-based 索引查 chapters 表
    Context.set_current_chapter_index(epub_index)
    local chapter = chapters[epub_index]

    -- 存入 book 的是 Legado 0-based 索引（与 Legado App 一致）
    book.durChapterIndex = legado_index
    book.durChapterTitle = chapter.name
    book.durChapterPos = chapter_pos
    -- 【单位必须毫秒】本仓库约定：所有 `*Time` / `*CheckTime` 字段一律毫秒
    -- （见 ReadRecord:update_record 的注释）。这里原先是 os.time()（秒，约 1.7e9），
    -- 而紧随其后的 read_record:update_record 用的是 os.time()*1000 —— 同一个函数里
    -- 两种单位并存。读取侧是 `tonumber(durChapterTime) or tonumber(lastCheckTime)`
    -- （bookshelf.lua:150 / :67-68），只有当一本书**没有 durChapterTime** 时才会取到这个值，
    -- 一旦命中就会小三个数量级：该书在「按最后阅读」排序里被甩到最后，
    -- apply_sync_data 还会误判「云端更新」而用云端覆盖本地进度。
    book.lastCheckTime = os.time() * 1000

    -- 【跳转 ≠ 阅读】目录跳转是**导航**行为，不应立刻把云端进度改写成跳转目标：
    -- 否则用户跳到第 500 章后再点「拉取云端进度」，云端已经被这次跳转覆盖，
    -- 永远显示「进度一致」，「跳回云端那一章」的选择也就无从谈起。
    --
    -- 这条保障现在由**去抖窗口本身**提供（见 lifecycle.lua 的
    -- PROGRESS_UPLOAD_DEBOUNCE_SEC）：跳转之后紧跟的 onPageUpdate/onPosUpdate 会安排
    -- 一次上传，但它至少要等窗口期满才会执行；用户在这段时间内点「拉取云端进度」，
    -- 拿到的仍是云端旧值，对比与「跳回云端那一章」的选择权完好。
    --
    -- 这里取消跳转**之前**安排的在途任务：它是按旧位置排的队，万一本次跳转没有触发
    -- 位置回调（例如目标页取不到、doc 不可用），留着它就会按旧位置上传。
    self:_cancel_pending_progress_upload()

    -- 【章节范围缓存此刻必然过期】它描述的是跳转**之前**所在章节的页区间
    -- （start_page/end_page/chapter_index）。若不失效，紧随 GotoPage 触发的
    -- onPageUpdate 一旦命中快速路径，就会用旧章节把刚设好的 durChapterIndex 覆盖回去。
    Context.set_chapter_range_cache(nil)

    self.read_record:update_record(
        book.bookUrl,
        book.name or book.title or "",
        0,
        os.time() * 1000
    )

    if reader and reader.document then
        local doc = reader.document
        if toc and toc[epub_index] then
            local chapter_start_page = doc:getPageFromXPointer(toc[epub_index].xpointer)
            if not chapter_start_page then
                -- 回退：xpointer 无效时使用 TOC 中记录的页码
                chapter_start_page = toc[epub_index].page
                Log.warn("无法从 xpointer 获取页码，回退使用 TOC 页码: " .. tostring(chapter_start_page))
            end
            if chapter_start_page then
                local target_page = chapter_start_page

                if chapter_pos > 0 then
                    local total_pages = doc:getPageCount()
                    if total_pages and total_pages > 0 then
                        local current_start = toc[epub_index].page or chapter_start_page
                        local next_start = (epub_index < #toc) and (toc[epub_index + 1].page or total_pages + 1) or (total_pages + 1)
                        local chapter_pages = next_start - current_start
                        if chapter_pages > 0 then
                            local offset_pages = math.floor((chapter_pos / 1000) * chapter_pages)
                            target_page = chapter_start_page + offset_pages
                        end
                    end
                end

                Log.info("跳转到页面: " .. target_page)
                -- 必须通过 GotoPage 事件走 ReaderRolling/ReaderPaging 的导航逻辑，
                -- 其内部会更新 view.state 并广播 PageUpdate/PosUpdate 刷新视图；
                -- 直接调 doc:gotoPage 只改文档内部页码，画面不会刷新。
                local Event = require("ui/event")
                reader:handleEvent(Event:new("GotoPage", target_page))
            else
                Log.warn("无法获取章节起始页面: EPUB TOC=" .. epub_index)
                self:showInfo(T(_("无法跳转到第 %1 章"), tostring(legado_index + 1)), false)
            end
        else
            Log.warn("目录为空或章节索引无效: EPUB TOC=" .. epub_index)
            self:showInfo(T(_("无法跳转到第 %1 章"), tostring(legado_index + 1)), false)
        end
    else
        Log.warn("ReaderUI实例或文档为空")
        self:showInfo(_("请先打开书籍"))
    end
end

--- 自动拉取云端进度并与本地对比（不算「用户主动」的那两次触发）。
--
-- 触发点有两个，都在本文件之外：
--   · `onReaderReady`（打开一本书）—— main.lua
--   · `onResume`（设备从休眠/后台回到前台）—— reading/lifecycle.lua
-- 因此本函数必须自己去重：某些平台（尤其 Android 的 `APP_CMD_RESUME`）一次唤醒
-- 会连发多次 Resume，不去重就会连发多次网络请求，返回顺序不定时还可能叠出
-- 两个一模一样的「进度同步」框。
--
-- 去重办法与去抖上传完全一致：**自己存闭包当句柄**。
-- `UIManager:scheduleIn` 没有返回值，而 `UIManager:unschedule` 是按**函数引用**匹配的
-- （koreader-master/frontend/ui/uimanager.lua），所以只能自己留一份引用。
function M._auto_pull_and_compare(self)
    if not self.settings:is_progress_auto_sync_enabled() then return end
    local book = Context.get_current_book()
    if not book then return end

    local book_name = book.name or book.title or ""
    local book_author = book.author or ""
    if book_name == "" then return end

    -- 捕获 generation 令牌，异步回调执行时校验，防止切书后旧回调上传旧书进度
    local gen = Context.get_generation()
    local self_ref = self

    Log.info("自动拉取云端进度进行对比: " .. book_name)

    -- 先撤掉上一次还没执行的那次，再排新的（重新计时，语义等同「只保留最后一次」）
    self:_cancel_pending_auto_compare()

    -- ⚠️ `attempt` 必须先**单独声明**，上面的 guarded 才能捕获到它。
    -- 写成 `local attempt = function ... end` 的话，guarded 里的闭包看到的是
    -- 一个全局 attempt（运行期为 nil）—— 与项目记忆里那条 local 作用域陷阱同源。
    local attempt
    local guarded = self:_guard(_("自动拉取云端进度"), function(tries_left)
        attempt(tries_left)
    end)

    attempt = function(tries_left)
        self_ref._pending_auto_compare = nil

        -- 令牌校验：若期间切换了书籍，放弃本次回调
        if Context.get_generation() ~= gen then
            Log.debug("自动拉取: 阅读会话已变更，放弃")
            return
        end

        -- 【屏保还盖着就先不弹，等它退场】
        --
        -- `Device:onPowerEvent("Resume")` 的顺序是「先 `self:resume()`（内部 `_afterResume()`
        -- 广播 Resume）、再 `Screensaver:close()`」（device/generic/device.lua:399-415），
        -- 而默认设置是「点一下退出屏保」——`Screensaver:close` 只是记一条日志，
        -- **屏保 widget 一直留在窗口栈最上层，直到用户点一下**
        -- （ui/screensaver.lua:712-713；退出路径是
        -- ui/widget/screensaverwidget.lua:59 `onTap = onClose`）。
        --
        -- 而 `ButtonDialog` 默认 `dismissable = true`，会注册一张**全屏**的 TapClose 手势
        -- （ui/widget/buttondialog.lua:84 / 98-108）：此时弹框，用户那一记
        -- 「点一下关屏保」会被对话框当作「点框外」吃掉 —— 对话框闪一下关掉，
        -- 屏保却还在，用户只会觉得「点了没反应」。
        --
        -- 所以屏保未退场时每隔 0.5 秒回来看一次，最多等 10 秒；超时就放弃本次对比
        -- （打开书路径不受影响，那时屏保早就不在了）。
        if tries_left > 0 and Device and Device.screen_saver_mode then
            Log.debug("自动拉取: 屏保仍在显示，稍后再试 (" .. tostring(tries_left) .. ")")
            local wait = function() guarded(tries_left - 1) end
            self_ref._pending_auto_compare = wait
            UIManager:scheduleIn(AUTO_COMPARE_SCREENSAVER_POLL_SEC, wait)
            return
        end

        local sync_ref = self_ref.sync

        -- get_book_progress 在子进程中执行，不阻塞 UI
        self_ref:_async_run(
            function()
                local ok, progress_data, err = sync_ref:get_book_progress(book_name, book_author)
                return { ok = ok, data = progress_data, err = err }
            end,
            function(ok, result, err)
                if not ok then
                    Log.warn("自动拉取云端进度异步失败: " .. tostring(err))
                    return
                end
                if not result or not result.ok then
                    Log.warn("自动拉取云端进度失败: " .. tostring(result and result.err or err))
                    return
                end
                if not result.data then
                    Log.debug("自动拉取: 云端无进度数据")
                    return
                end
                -- silent=true: 自动对比时非"云端超前"不显示提示
                self_ref:_handle_pulled_progress(book, result.data, gen, true)
            end,
            { timeout = 30 }
        )
    end

    -- 句柄必须就是**传给 scheduleIn 的那个函数本身**：`UIManager:unschedule` 按函数引用匹配。
    local first = function() guarded(AUTO_COMPARE_SCREENSAVER_MAX_TRIES) end
    self._pending_auto_compare = first
    UIManager:scheduleIn(AUTO_COMPARE_DELAY_SEC, first)
end

--- 取消尚未执行的自动对比任务（关闭文档 / 重新安排时调用）。
function M._cancel_pending_auto_compare(self)
    if self._pending_auto_compare then
        UIManager:unschedule(self._pending_auto_compare)
        self._pending_auto_compare = nil
    end
end

--- 把当前进度上传到云端（去抖窗口期满后由 lifecycle.lua 调用）。
--
-- 进度取自 `book` 的 durChapterIndex / durChapterPos / durChapterTitle —— 这三个字段
-- 在 onPageUpdate 里已经实时维护，所以本函数**不接受章节号参数**：早先那个从未被
-- 读取过的 `chapter_index` 形参只会让调用方误以为「上传的是我指定的那一章」。
function M.save_read_progress(self)
    local book = Context.get_current_book()
    if not book or not Context.get_current_epub_path() then return end

    local refresh_ok = self:_refresh_current_progress()
    if not refresh_ok then
        Log.warn("save_read_progress: 无法刷新当前进度（document 不可用），使用上次记录的进度")
    end
    local book_name = book.name or book.title or ""
    local book_author = book.author or ""
    local chapter_index_val = book.durChapterIndex or 0
    local chapter_pos_val = book.durChapterPos or 0
    local chapter_title_val = book.durChapterTitle or ""
    
    Log.debug("自动保存进度: " .. book_name .. " 章节 " .. chapter_index_val .. " 位置 " .. chapter_pos_val)

    local gen = Context.get_generation()
    local sync_ref = self.sync
    self:_async_run(
        function()
            local ok, __, err = sync_ref:upload_book_progress(
                book_name, book_author, chapter_index_val, chapter_pos_val, chapter_title_val
            )
            return { ok = ok, err = err }
        end,
        function(ok, result, err)
            if Context.get_generation() ~= gen then
                Log.debug("save_read_progress: 阅读会话已变更，放弃回调")
                return
            end
            if ok and result and result.ok then
                Log.debug("自动上传进度成功: " .. book_name)
            else
                Log.warn("自动上传进度失败: " .. book_name .. ", " .. tostring(err or (result and result.err)))
            end
        end,
        { timeout = 30 }
    )
end

function M.pull_cloud_progress(self)
    if not Context.get_current_book() then return end

    -- 捕获 generation 令牌，异步回调执行时校验（真正的校验在 _handle_pulled_progress 里）
    local gen = Context.get_generation()

    local busy = self:showBusy(_("正在拉取云端进度..."))

    local book = Context.get_current_book()
    if not book then
        self:closeBusy(busy)
        return
    end
    local book_name = book.name or book.title or ""
    local book_author = book.author or ""

    Log.info("手动拉取云端进度: " .. book_name)

    local sync_ref = self.sync
    local self_ref = self

    -- get_book_progress 在子进程中执行，不阻塞 UI
    self:_async_run(
        function()
            local ok, progress_data, err = sync_ref:get_book_progress(book_name, book_author)
            return { ok = ok, data = progress_data, err = err }
        end,
        function(ok, result, err)
            self_ref:closeBusy(busy)
            if not ok then
                Log.warn("拉取进度异步失败: " .. tostring(err))
                self_ref:showInfo(T(_("拉取进度失败:\n%1"), tostring(err)), false)
                return
            end
            if not result or not result.ok then
                self_ref:showInfo(T(_("拉取进度失败:\n%1"), tostring(result and result.err or err)), false)
                return
            end
            if not result.data then
                self_ref:showInfo(_("云端没有该书的进度"))
                return
            end
            
            Log.info("开始处理拉取到的进度，准备调用 _handle_pulled_progress")
            
                    local success, err_msg = pcall(function()
                self_ref:_handle_pulled_progress(book, result.data, gen)
            end)
            if not success then
                Log.error("_handle_pulled_progress 崩溃: " .. tostring(err_msg))
                self_ref:showInfo(T(_("处理云端进度时出错:\n%1"), tostring(err_msg)), false)
            end
        end,
        { timeout = 30 }
    )
end

--- 处理拉取到的云端进度：对比本地进度并提示用户（从 pull_cloud_progress 提取，便于复用）
--- @param silent boolean|nil  true 时非"云端超前"情况不显示提示（自动对比用）
function M._handle_pulled_progress(self, book, progress_data, gen, silent)
    if not book or not progress_data then return end
    if gen and Context.get_generation() ~= gen then
        -- 【自动对比必须放弃，手动拉取才继续】
        --
        -- 手动路径：结果**是用户刚点出来的**，哪怕这期间切了书也得给他看，
        -- 所以原实现选择「不 return，强制显示结果」。
        --
        -- 自动路径（silent=true）不同：它是后台行为，触发点有「打开书」与「回到前台」，
        -- 而这两件事都可能刚好赶上切书/关书。此时再弹一个「进度同步」框，
        -- 就是拿**上一本书**的进度在**新书**上打断用户 —— 必须放弃。
        if silent then
            Log.debug("_handle_pulled_progress: 自动对比的阅读会话已变更，放弃")
            return
        end
        Log.debug("_handle_pulled_progress: 阅读会话已变更 (gen=" .. tostring(gen) .. ", curr=" .. tostring(Context.get_generation()) .. ")，但由于是手动拉取，我们继续显示结果")
    end

    local remote_record = {
        durChapterIndex = tonumber(progress_data.durChapterIndex) or 0,
        durChapterPos = tonumber(progress_data.durChapterPos) or 0,
        durChapterTitle = progress_data.durChapterTitle or "",
        durChapterTime = tonumber(progress_data.durChapterTime) or 0,
    }

    -- 刷新本地进度，同时取出 EPUB TOC 1-based 索引用于标题对齐对比
    local __, local_epub_idx = self:_refresh_current_progress()
    local local_chapter_index = tonumber(book.durChapterIndex) or 0   -- Legado 0-based，用于展示
    local local_chapter_pos = tonumber(book.durChapterPos) or 0

    Log.debug("本地进度: 第" .. (local_chapter_index + 1) .. "章(0based=" .. local_chapter_index ..
             ", EPUB=" .. tostring(local_epub_idx) .. "), 位置: " .. local_chapter_pos)
    Log.debug("云端进度: 第" .. ((remote_record.durChapterIndex or 0) + 1) ..
             "章(0based=" .. (remote_record.durChapterIndex or 0) .. "), 位置: " .. remote_record.durChapterPos ..
             ", 标题: " .. (remote_record.durChapterTitle or ""))

    -- 对比走标题对齐：优先用云端 durChapterTitle 在本地 EPUB TOC 匹配，
    -- 反推偏移量并持久化，供后续上传/跳转链路复用
    local compare_result, matched_epub_idx = self:_compare_progress_by_title(book, local_epub_idx, remote_record)

    -- 持久化校准出的偏移量，并同步更新内存缓存
    if matched_epub_idx then
        self:_add_toc_anchor(book, remote_record.durChapterIndex or 0, matched_epub_idx, remote_record.durChapterTitle or "")
        -- 立即落盘：_add_toc_anchor 内部只有 5 秒 debounce，而「拉取云端进度」是用户
        -- 主动触发的校准动作，结果很宝贵，这里直接写一次，避免 debounce 期间进程被杀死而丢失。
        self:_save_toc_anchors(book)
    end

    if compare_result == "same" then
        if not silent then
            self:showInfo(_("进度一致，无需跳转"))
        end
    elseif compare_result == "remote_ahead" then
        -- 云端更靠前（通常意味着「你在别的设备上读得更多」）→ 值得打断，自动对比时也弹
        self:_show_progress_choice_dialog(book, remote_record, local_chapter_index, true)
    else
        -- 本地更靠前。
        --
        -- 【为什么这里也必须给选择权】此前这个分支只弹一条 showInfo
        -- （「本地进度超前，云端进度: 第X章 Y」），用户除了点掉它没有任何操作空间。
        -- 但「本地超前」**未必是用户想要的**：误翻页、跳章后没读、在书架里随手点了一章，
        -- 都会让本地进度虚高，此时用户恰恰需要「回到云端那一章」这条路。
        -- 只告知不给出路，等于把用户锁在一个他自己无法纠正的状态里。
        -- 所以这里弹出于「云端更靠前」完全相同的选择框，只是文案反过来。
        --
        -- silent=true（进书时的自动对比）保持安静：本地超前是常态，不该每次打断。
        if not silent then
            self:_show_progress_choice_dialog(book, remote_record, local_chapter_index, false)
        end
    end
end

--- 弹出「进度同步」选择框：本地与云端进度不一致时，让用户自己决定用哪一份。
--
-- 三个按钮在「云端更靠前」与「本地更靠前」两种情况下语义完全相同
-- （跳到云端那一章 / 维持本地不动 / 用本地覆盖云端），所以两条分支共用本函数，
-- 只由 `remote_ahead` 决定文案说谁在前。
--
-- 【为什么第三个按钮两种情况下都要有】「跳到云端」只解决「我想去云端那一章」；
-- 但还有相反的需求 —— 用户认为**本地这份才是对的**（云端是误操作、是另一台设备
-- 上的随手翻动），此时他想把本地写死到云端。少了这个按钮，用户只能先退出去点
-- 「覆盖云端」菜单，多绕一步且容易以为插件不支持。
--
-- 「用本地覆盖云端」会丢云端那份进度，所以不在这里直接上传：转交
-- `push_cloud_progress`，它自带一个「确认覆盖云端进度？」的 ConfirmBox。
--
-- @param book table                     当前书籍（取 durChapterTitle 用于展示）
-- @param remote_record table            云端进度 { durChapterIndex, durChapterPos, durChapterTitle }
-- @param local_chapter_index number|nil 本地 Legado 0-based 章节索引（仅用于展示）
-- @param remote_ahead boolean           true=云端更靠前，false=本地更靠前（仅影响文案）
function M._show_progress_choice_dialog(self, book, remote_record, local_chapter_index, remote_ahead)
    remote_record = remote_record or {}

    -- 【同一个框只留一个】触发点现在有三个（打开书 / 回到前台 / 手动拉取），
    -- 用户完全可能「框还开着就息屏、醒来 onResume 又给弹一个」。
    -- 这里在已有框时直接跳过 —— 不叠框，也不会把用户正在看的那个顶掉。
    if UIHandles.get(PROGRESS_DIALOG_HANDLE) then
        Log.debug("进度选择框已存在，跳过重复弹出")
        return
    end

    local ButtonDialog = require("ui/widget/buttondialog")

    local lead_text = _("本地进度更靠前")
    if remote_ahead then
        lead_text = _("云端进度更靠前")
    end

    local info_text = lead_text .. "\n\n" ..
        string.format(_("本地进度: 第%s章 %s"),
            tostring((tonumber(local_chapter_index) or 0) + 1),
            tostring((book and book.durChapterTitle) or "")) .. "\n" ..
        string.format(_("云端进度: 第%s章 %s"),
            tostring((tonumber(remote_record.durChapterIndex) or 0) + 1),
            tostring(remote_record.durChapterTitle or ""))

    local self_ref = self

    -- 注意：三个 callback **不再**引用正在构造的这个 dialog，而是走 UIHandles 常量名。
    -- 早先的写法是 `local dialog = ButtonDialog:new{ callback = function() UIManager:close(dialog) end }`，
    -- 那是坏的 —— Lua 的 local 作用域从声明行**之后**才开始，构造器内部的闭包看到的是
    -- 一个全局 `dialog`（运行期为 nil），`UIManager:close(nil)` 只打一条 debug 日志就返回，
    -- 于是两个按钮都关不掉弹窗。改用句柄名后这个陷阱在结构上就不存在了。
    local dialog = ButtonDialog:new{
        -- 【对比信息必须并进 title】ButtonDialog **没有** info_text 字段 —— 上游
        -- ui/widget/buttondialog.lua 的字段表只有 title / title_align / title_face /
        -- use_info_style / info_face / info_padding / info_margin（info_* 是**字号与留白**，
        -- 不是内容），init() 只渲染 self.title 与 self._added_widgets。
        -- 原来写 `info_text = info_text` 会被**静默忽略**：用户只看到标题「进度同步」和
        -- 三个按钮，而这三个按钮的全部意义都建立在「本地第几章 / 云端第几章」的对比上。
        -- title 是 TextBoxWidget，本身就支持多行，show_book_detail 用的就是这个办法。
        title = _("进度同步") .. "\n\n" .. info_text,
        title_align = "center",
        -- 点框外关闭（ButtonDialog:onTapClose）时它自己会 close，这里只需清掉句柄，
        -- 否则下一次要弹框时会被上面的「已存在」判断挡掉 —— 弹窗会永久失效。
        tap_close_callback = function()
            UIHandles.clear(PROGRESS_DIALOG_HANDLE)
        end,
        buttons = {
            {
                {
                    text = _("跳转到云端进度"),
                    callback = function()
                        UIHandles.close(PROGRESS_DIALOG_HANDLE)
                        self_ref:_jump_to_cloud_progress(remote_record)
                    end,
                },
                {
                    text = _("保持本地进度"),
                    callback = function()
                        UIHandles.close(PROGRESS_DIALOG_HANDLE)
                        self_ref:showInfo(_("保持本地进度"))
                    end,
                },
            },
            {
                {
                    text = _("用本地覆盖云端"),
                    callback = function()
                        UIHandles.close(PROGRESS_DIALOG_HANDLE)
                        -- push_cloud_progress 内部自带「确认覆盖云端进度？」二次确认，
                        -- 所以这里不重复询问（覆盖会丢云端那份进度，必须问一次）。
                        self_ref:push_cloud_progress()
                    end,
                },
            },
        },
    }
    UIHandles.set(PROGRESS_DIALOG_HANDLE, dialog)
    UIManager:show(dialog)
end

--- 通过标题对齐对比本地与云端进度，并反推校准偏移量
-- 优先用云端 durChapterTitle 在本地 EPUB TOC 中匹配章节索引，
-- 跟本地当前 EPUB TOC 索引比较；同时通过 (matched_epub_idx - cloud_legado_idx)
-- 反推出偏移量，返回给调用方持久化，供后续上传/跳转链路复用。
--
-- 核心映射公式（统一完整导出和部分导出场景）：
--   offset = remote_epub_idx - remote_legado_idx   （允许负数）
--   上传：local_legado = local_epub - offset
--   跳转：local_epub  = legado + offset
--
-- 完整导出：offset 为前置条目数（正数，如 3）
-- 部分导出（多卷只导后几卷）：offset 为负数（如 6 - 865 = -859），
--   此时 local_epub - offset = local_epub + 859，正确反推出全书索引。
-- 只要本地 EPUB 章节是连续的（按卷导出即满足），线性映射就成立。
--
-- @param book table              当前书籍对象
-- @param local_epub_idx number   本地当前 EPUB TOC 1-based 索引（由 _refresh_current_progress 返回）
-- @param remote_record table     { durChapterIndex, durChapterPos, durChapterTitle }
-- @return result string          "local_ahead" | "remote_ahead" | "same"
-- @return matched_epub_idx|nil   标题匹配命中时的 EPUB 索引；nil 表示未命中
function M._compare_progress_by_title(self, book, local_epub_idx, remote_record)
    if not book or not remote_record then return "same", nil end

    local doc_toc = Context.get_current_chapters() or {}
    local remote_title = remote_record.durChapterTitle or ""
    local remote_legado_idx = tonumber(remote_record.durChapterIndex) or 0
    local local_epub = tonumber(local_epub_idx) or 0

    Log.info("标题对齐前置状态: remote_title='" .. tostring(remote_title) .. "', remote_legado_idx=" .. tostring(remote_legado_idx) .. ", local_epub=" .. tostring(local_epub))

    -- 1. 优先：云端标题在本地 EPUB TOC 匹配
    if remote_title ~= "" and #doc_toc > 0 then
        local remote_epub_idx = self:_find_chapter_by_title(doc_toc, remote_title)
        if remote_epub_idx then
            -- 对比结论：local_epub_idx 与 remote_epub_idx 都是本地 EPUB TOC 索引基准，可直接比较
            local result
            if local_epub > remote_epub_idx then
                result = "local_ahead"
            elseif local_epub < remote_epub_idx then
                result = "remote_ahead"
            else
                result = "same"
            end

            Log.info("标题对齐对比: 本地EPUB=" .. local_epub ..
                     ", 云端EPUB=" .. remote_epub_idx ..
                     " (云端第" .. remote_legado_idx .. "章 '" .. remote_title ..
                     "') → " .. result)
            return result, remote_epub_idx
        else
            Log.warn("标题对齐: 云端标题 '" .. remote_title .. "' 在本地 EPUB TOC 未匹配，回退数值对比")
        end
    end

    -- 2. 回退：用锚点表把本地 EPUB 索引转 Legado，再数值对比
    local local_legado = self:_get_legado_index(book, local_epub, doc_toc)
    if local_legado < 0 then local_legado = 0 end

    local result
    if local_legado > remote_legado_idx then
        result = "local_ahead"
    elseif local_legado < remote_legado_idx then
        result = "remote_ahead"
    else
        result = "same"
    end

    Log.info("数值对比回退: 本地EPUB=" .. local_epub .. " -> Legado=" .. local_legado ..
             ", 云端Legado=" .. remote_legado_idx .. " → " .. result)
    return result, nil
end

function M._refresh_current_progress(self)
    local book = Context.get_current_book()
    if not book then return false, nil, nil, nil end
    if not self.ui or not self.ui.document then return false, nil, nil, nil end

    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return false, nil, nil, nil end

    local toc = self:_get_doc_toc(doc, book)
    if not toc or #toc == 0 then
        local current_page = doc:getCurrentPage() or 1
        local progress_percent = current_page / total_pages
        book.durChapterPos = math.floor(progress_percent * 1000)
        return true, nil, nil, nil  -- 无 TOC，无法返回章节索引
    end

    local current_page = doc:getCurrentPage() or 1

    -- 扫描逻辑与 lifecycle.onPageUpdate 的慢路径共用一份实现（抽到 toc_align）。
    local chapter_index, chapter_pos, current_start, next_start, chapter_title =
        self:_scan_toc_for_page(toc, current_page, total_pages)

    Context.set_chapter_range_cache({
        start_page = current_start,
        end_page = next_start,
        chapter_index = chapter_index,
        chapter_title = chapter_title,
    })

    -- 从 EPUB TOC 索引转换为 Legado 章节索引
    -- 注意：Legado durChapterIndex 是 0-based（Book.kt L97 默认 0，L166 lastChapterIndex=totalChapterNum-1）
    local legado_index = self:_get_legado_index(book, chapter_index, toc)
    local legado_title = chapter_title

    -- 标题验证：用 EPUB TOC 当前章节标题在 Legado 章节列表中查找，
    -- 处理"作者有话说""紧急求助"等动态插入导致偏移量失效的情况
    local verified_index = self:_verify_legado_index_by_title(book, legado_title, legado_index)
    if verified_index then
        legado_index = verified_index
        -- 动态更新锚点，让后续的快速路径也能用上正确的锚点
        self:_add_toc_anchor(book, verified_index, chapter_index, legado_title)
    elseif legado_index < 0 then
        -- 落在 TOC 前置条目（封面/内容简介），用 Legado 第1章（索引0）兜底
        legado_index = 0
    end

    -- 将验证后的 Legado 索引存入缓存，供快速路径使用
    local cache = Context.get_chapter_range_cache()
    if cache then
        cache.legado_index = legado_index
    end

    -- 上界保护：负 offset（部分导出场景）下 legado_index 会较大，
    -- 避免异常 offset 导致上传超出全书范围的索引
    local total = tonumber(book.totalChapterNum) or 0
    if total > 0 and legado_index >= total then
        Log.warn("legado_index " .. legado_index .. " 超出 totalChapterNum " .. total .. "，钳制为 " .. (total - 1))
        legado_index = total - 1
    end

    book.durChapterIndex = legado_index
    book.durChapterPos = chapter_pos
    book.durChapterTitle = legado_title

    Log.debug("强制刷新进度: TOC=" .. chapter_index .. " -> Legado=" .. legado_index .. "章, 位置=" .. chapter_pos)
    -- 多返回值：ok, epub_idx(1-based), legado_idx(0-based), chapter_title
    -- 旧调用点 `local ok = ...` 只取第一个返回值，兼容不变
    return true, chapter_index, legado_index, legado_title
end

--- 按 Legado 索引跳转（「待处理跳转」与「跳转云端进度」两条来路的公共实现）
--
-- 调用前提：Context.get_current_chapters() 非空 —— 「目录为空 / 尚未加载」的分支由调用方处理。
-- 流程：先在 EPUB TOC 里按标题匹配（命中则落一个锚点，校准 Legado↔EPUB 偏移），
-- 再做 Legado 0-based 的边界保护，然后 read_chapter，最后提示「已跳转到第 N 章」。
--
-- ⚠️ 这里**不再**出现 `jump_index = legado_index` 这种赋值：jump_index 的初值就是它。
-- 真正的索引换算发生在 read_chapter 内部（_get_epub_index），以及上面 _add_toc_anchor
-- 落好的锚点上。旧注释「直接使用云端传来的 Legado 索引作为跳转目标」描述的正是这个初值，
-- 写成赋值属于历史误留（恒等 no-op）。
--
-- 抽出来的动机：这两段原本逐行重复约 40 行，已经漂移过一次 ——
-- 「改一处忘一处」是这类重复的必然结局。
--
-- @param book table|nil        当前书籍（可为 nil，锚点与边界换算各自降级）
-- @param legado_index number   Legado 0-based 章节索引
-- @param chapter_pos number    章内位置
-- @param chapter_title string  章节标题（用于标题匹配校准，可为空串）
-- @param log_prefix string|nil 日志前缀，用于区分来路（如 "pending_jump "）
function M._jump_to_legado_chapter(self, book, legado_index, chapter_pos, chapter_title, log_prefix)
    local chapters = Context.get_current_chapters()
    local prefix = log_prefix or ""
    local jump_index = legado_index

    -- 优先用章节标题匹配，解决 Legado 与 EPUB TOC 索引偏移（目录/简介等前置条目）
    if chapter_title and chapter_title ~= "" then
        local matched_epub_idx = self:_find_chapter_by_title(chapters, chapter_title)
        if matched_epub_idx then
            if book then
                self:_add_toc_anchor(book, legado_index, matched_epub_idx, chapter_title)
            end
            Log.info(prefix .. "标题匹配: 第" .. legado_index .. "章 '" .. chapter_title ..
                     "' -> EPUB TOC " .. matched_epub_idx .. " -> 动态更新锚点")
        else
            Log.warn(prefix .. "标题匹配失败，回退使用索引: 第" .. legado_index .. "章")
        end
    end

    -- 边界保护（Legado 0-based：0 ~ totalChapters-1）
    if jump_index < 0 then jump_index = 0 end
    local max_legado = self:_get_legado_index(book, #chapters, chapters)
    if jump_index > max_legado then jump_index = max_legado end

    self:read_chapter(jump_index, chapter_pos)

    -- 跳转完成后才显示成功消息
    local jumped_epub_idx = self:_get_epub_index(book, jump_index, chapters)
    if jumped_epub_idx < 1 then jumped_epub_idx = 1 end
    if jumped_epub_idx > #chapters then jumped_epub_idx = #chapters end
    local jumped_title = chapters[jumped_epub_idx].name or ""
    self:showInfo(string.format(_("已跳转到第 %s 章 %s"), tostring(jump_index + 1), tostring(jumped_title)))
end

function M._jump_to_cloud_progress(self, remote_record)
    local legado_index = remote_record.durChapterIndex or 1
    local chapter_pos = remote_record.durChapterPos or 0
    local chapter_title = remote_record.durChapterTitle or ""

    if not Context.get_current_book() then
        Log.error("_jump_to_cloud_progress: 当前没有选中的书籍")
        self:showInfo(_("请先选择书籍"))
        return
    end

    local epub_path = self.bookshelf:get_epub_for_book(Context.get_current_book())
    if not epub_path then
        Log.error("_jump_to_cloud_progress: 未找到本地书籍文件")
        self:showInfo(_("未找到本地书籍文件"))
        return
    end

    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance

    if not reader or not reader.document then
        -- 书籍未打开：设置 pending_jump（含标题），打开书籍后由 _load_chapters_from_document 执行跳转
        Log.info("_jump_to_cloud_progress: 书籍未打开，先打开书籍，跳转将延后执行")
        Context.set_pending_jump({
            chapter_index = legado_index,
            chapter_pos = chapter_pos,
            chapter_title = chapter_title,
        })
        -- 成功消息由 _load_chapters_from_document 在跳转完成后显示
        self:open_epub_book(epub_path, Context.get_current_book())
    else
        if Context.get_current_chapters() and #Context.get_current_chapters() > 0 then
            -- 日志记「请求要跳到的章」，而不是钳制后的值 —— 越界被夹紧本身就是异常信号，
            -- 打印原始值更利于排查。
            Log.info("跳转到云端进度: 第" .. legado_index .. "章, 位置: " .. chapter_pos)
            -- 跳转逻辑与 _load_chapters_from_document 的 pending_jump 分支共用
            self:_jump_to_legado_chapter(Context.get_current_book(), legado_index, chapter_pos, chapter_title)
        else
            -- 目录未加载：设置 pending_jump（含标题），加载完成后执行跳转
            Log.info("_jump_to_cloud_progress: 目录未加载完成，等待加载")
            Context.set_pending_jump({
                chapter_index = legado_index,
                chapter_pos = chapter_pos,
                chapter_title = chapter_title,
            })
            self:showBusy(_("正在加载目录..."))
            self:_load_chapters_from_document()
        end
    end
end

function M.push_cloud_progress(self)
    if not Context.get_current_book() then
        self:showInfo(_("请先选择书籍"))
        return
    end

    self:_refresh_current_progress()

    local book = Context.get_current_book()
    
    -- 当准备上传本地进度到云端时，优先使用我们在 `onPageUpdate` 中计算的 book.durChapterIndex（Legado 0-based 索引）
    -- 但考虑到有的章节本地计算出的 Legado index 可能不准，我们在这里加一步“反推校验”
    local chapter_index = tonumber(book.durChapterIndex) or tonumber(Context.get_current_chapter_index()) or 0
    local chapter_pos = tonumber(book.durChapterPos) or 0
    local chapter_title = book.durChapterTitle or ""

    -- 优化：覆盖云端进度时，由于本地有封面等干扰，我们如果能加载到云端的完整目录（或者使用已知的 toc_anchors）
    -- 我们可以在这里尝试校准 chapter_index，确保传给手机的 index 是纯净的。
    -- 由于这里不方便去请求云端目录，我们依赖在 _refresh_current_progress / onPageUpdate 中
    -- 用到的 `self:_verify_legado_index_by_title` 及 `toc_anchors`，它们已经把本地 EPUB 的 1-based 转回了 Legado 0-based。
    
    Log.info(string.format("准备覆盖云端进度: 本地标题 [%s], 转换后的 Legado Index: %d, Pos: %d", chapter_title, chapter_index, chapter_pos))

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = string.format(_("确认覆盖云端进度？\n\n本地进度: 第%s章 %s"), tostring(chapter_index + 1), tostring(chapter_title)),
        ok_text = _("确认覆盖"),
        cancel_text = _("取消"),
        ok_callback = function()
            local busy = self:showBusy(_("正在上传进度..."))

            local gen = Context.get_generation()
            local sync_ref = self.sync
            local self_ref = self
            
            -- FIX: 移除 UI 线程阻塞的风险，确保异步上传稳定执行
            self:_async_run(
                function()
                    local ok, __, err = sync_ref:upload_book_progress(
                        book.name or book.title or "",
                        book.author or "",
                        chapter_index, chapter_pos, chapter_title
                    )
                    return { ok = ok, err = err }
                end,
                function(ok, result, err)
                    local success, err_msg = pcall(function()
                        if Context.get_generation() ~= gen then
                            Log.debug("push_cloud_progress: 阅读会话已变更 (gen=" .. tostring(gen) .. ", curr=" .. tostring(Context.get_generation()) .. ")，但作为手动操作，我们继续执行 UI 反馈")
                            -- return -- 取消阻止，确保给出反馈
                        end
                        self_ref:closeBusy(busy)
                        if ok and result and result.ok then
                            self_ref:showInfo(_("进度已上传到云端"))
                        else
                            self_ref:showInfo(string.format(_("上传失败: %s"), tostring(err or (result and result.err))), false)
                        end
                    end)
                    if not success then
                        Log.error("push_cloud_progress 崩溃: " .. tostring(err_msg))
                        self_ref:showInfo(T(_("上传进度时出错:\n%1"), tostring(err_msg)), false)
                    end
                end,
                { timeout = 30 }
            )
        end,
    })
end

return M
