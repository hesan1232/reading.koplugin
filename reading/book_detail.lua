--[[
    书籍详情页与 EPUB 文件的获取/打开/删除。

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
local H = require("reading.helper")
-- UI 句柄管理（替代原 _state 中的 UI 字段，修复 chapter_list_menu 泄漏）
local UIHandles = require("reading.ui_handles")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or function(str, ...) return str end
local Log = safe_require("reading.log")
local Context = require("reading.reading_context")

local M = {}

function M._ensure_book_in_shelf(self, clean_filename, original_filename)
    local book_name = clean_filename:gsub("%.epub$", ""):gsub("%.txt$", "")
    
    self.bookshelf:invalidate_epub_cache()
    
    local existing = self.bookshelf:get_book_by_name(book_name)
    if existing then
        if original_filename and original_filename ~= clean_filename then
            existing.original_filename = original_filename
            self.bookshelf:save_bookshelf_cache()
        end
        return
    end
    
    local new_book = {
        name = book_name,
        author = "",
        bookUrl = "local://" .. H.url_encode(book_name),
        lastCheckTime = os.time() * 1000,
        is_local_only = true,
        original_filename = (original_filename ~= clean_filename) and original_filename or nil
    }
    
    table.insert(self.bookshelf.books, new_book)
    self.bookshelf:rebuild_index()
    self.bookshelf:save_bookshelf_cache()
    Log.info("手动添加云端书籍到书架: " .. book_name)
end

function M.show_book_detail(self, book)
    Context.set_current_book(book)

    -- 【详情页身份令牌】下面那次「列云端目录」是网络请求（Kindle 上常 1~3 秒），
    -- 而用户完全可能「点书 A → 不等结果 → 关掉 → 点书 B」。此时 A 的回调如果只判断
    -- 「detail_dialog 还在不在」，守卫会通过，于是 A 的详情页被替换到 B 的界面上 ——
    -- 数据不会串（闭包各自捕获自己的 book），但「点的是 B、看到的是 A」是明确的错误。
    -- 与 _auto_pull_and_compare 的 generation 校验同类；比比对 widget 引用更稳，
    -- 因为对话框本身会被 show_detail_dialog 重建。
    self._detail_token = (self._detail_token or 0) + 1
    local detail_token = self._detail_token

    local epub_path = self.bookshelf:get_epub_for_book(book)
    local has_local_epub = epub_path ~= nil

    local local_size = 0
    if has_local_epub then
        local lfs = require("libs/libkoreader-lfs")
        local attr = lfs.attributes(epub_path)
        if attr then
            local_size = attr.size or 0
        end
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local self_ref = self

    local book_name = book.name or book.title or _("未命名")
    local author_text = book.author or ""
    local chapter_text = book.durChapterIndex and T(_("当前章节: 第 %1 章"), tostring(book.durChapterIndex + 1)) or ""
    local original_file_text = book.original_filename and T(_("云端文件: %1"), book.original_filename) or ""

    local function build_info_text(status_text)
        local result = book_name
        if author_text ~= "" then
            result = result .. "\n" .. author_text
        end
        if chapter_text ~= "" then
            result = result .. "\n" .. chapter_text
        end
        if original_file_text ~= "" then
            result = result .. "\n" .. original_file_text
        end
        if status_text ~= "" then
            result = result .. "\n" .. status_text
        end
        return result
    end

    -- 提取按钮构建逻辑：每次调用都生成新的 callback 闭包，确保 reinit 后 callback 不丢失
    local function build_buttons(pull_enabled, pull_text)
        return {
            {
                {
                    text = _("开始阅读"),
                    enabled = true,
                    callback = self_ref:_guard(_("开始阅读"), function()
                        Log.info("点击开始阅读按钮, has_local_epub=" .. tostring(has_local_epub))
                        Log.info("书籍信息: " .. (book.name or book.title or ""))
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                        if UIHandles.get("menu") then
                            UIManager:close(UIHandles.get("menu"))
                            UIHandles.clear("menu")
                        end
                        self_ref:start_reading(book)
                    end),
                },
                {
                    text = pull_text or (has_local_epub and _("更新书籍") or _("拉取书籍")),
                    enabled = pull_enabled or false,
                    callback = self_ref:_guard(_("拉取书籍"), function()
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                        self_ref:download_epub_for_book(book, has_local_epub)
                    end),
                },
            },
            {
                {
                    text = _("拉取进度"),
                    callback = function()
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                        self_ref:pull_cloud_progress()
                    end,
                },
                {
                    text = _("覆盖云端"),
                    callback = function()
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                        self_ref:push_cloud_progress()
                    end,
                },
            },
            {
                {
                    text = _("云端多版本"),
                    callback = function()
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                        
                        local busy = self_ref:showBusy(_("正在查找云端版本..."))
                        local sync_ref = self_ref.sync
                        local bookshelf_ref = self_ref.bookshelf
                        local book_name = book.name or book.title or ""
                        local book_author = book.author or ""
                        
                        self_ref:_async_run(
                            function()
                                local ok, epub_files, err = sync_ref:list_books_directory()
                                if not ok then return { ok = false, err = err } end
                                
                                local matches = bookshelf_ref:match_all_epubs(book_name, epub_files, book_author)
                                return { ok = true, matches = matches }
                            end,
                            function(ok, result, err)
                                self_ref:closeBusy(busy)
                                if not ok or not result.ok then
                                    self_ref:showInfo(T(_("查找失败:\n%1"), tostring(err or result.err)), false)
                                    return
                                end
                                if #result.matches == 0 then
                                    self_ref:showInfo(_("云端未找到此书的任何版本"))
                                    return
                                end
                                
                                local ShelfView = require("reading.shelf_view")
                                ShelfView.show_cloud_library_list(result.matches, function(selected_file)
                                    self_ref:download_cloud_book(selected_file, UIHandles.get("menu"))
                                end, _("多版本选择: ") .. book_name)
                            end,
                            { timeout = 30 }
                        )
                    end,
                },
                {
                    text = _("删除缓存"),
                    callback = function()
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                        self_ref:delete_book_cache(book)
                    end,
                },
                {
                    text = _("彻底删除"),
                    callback = function()
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                        self_ref:delete_book_completely(book)
                    end,
                },
            },
            {
                {
                    text = _("关闭"),
                    callback = function()
                        UIManager:close(UIHandles.get("detail_dialog"))
                        UIHandles.clear("detail_dialog")
                    end,
                },
            },
        }
    end

    -- 关闭旧对话框并创建新对话框（替代 reinit，避免 callback 丢失）
    local function show_detail_dialog(status_text, pull_enabled, pull_text)
        local old_dlg = UIHandles.get("detail_dialog")
        if old_dlg then
            UIManager:close(old_dlg)
        end

        local new_dlg = ButtonDialog:new{
            title = build_info_text(status_text),
            title_align = "center",
            buttons = build_buttons(pull_enabled, pull_text),
        }
        UIHandles.set("detail_dialog", new_dlg)
        UIManager:show(new_dlg)
    end

    local function no_cloud_fallback()
        local status = has_local_epub and _("[本地已下载]") or _("[云端无书籍，请在Legado中导出到legado/books目录]")
        show_detail_dialog(status, false, nil)
    end

    -- 初始显示对话框（"开始阅读"按钮立即可用）
    local initial_status = has_local_epub and string.format(_("[本地已下载: %s]"), tostring(H.format_file_size(local_size))) or _("[检查云端中...]")
    show_detail_dialog(initial_status, false, nil)

    -- 异步检查云端书籍，完成后用新对话框替换旧对话框（callback 正确绑定）
    self_ref:_async_run(
        function()
            local ok, epub_files, err = self_ref.sync:list_books_directory()
            if not ok then
                return { ok = false, err = err }
            end

            local book_name_for_match = book.name or book.title or ""
            if book_name_for_match == "" then
                return { ok = true, matched_epub = nil }
            end

            local matched_epub = self_ref.bookshelf:match_epub(book_name_for_match, epub_files, book.author)
            return { ok = true, matched_epub = matched_epub }
        end,
        function(ok, result, err)
            -- 【身份校验】先确认这个回调仍属于「当前这本书的详情页」。
            -- 期间用户若已关掉并点了别的书，self._detail_token 会变，必须放弃，
            -- 否则 A 的结果会把 B 的详情页顶掉（见函数开头 _detail_token 的说明）。
            if self_ref._detail_token ~= detail_token then
                Log.debug("show_book_detail: 详情页已切换到其它书籍，放弃本次云端检查结果")
                return
            end

            -- 检查对话框是否还开着，如果用户已经点击了“开始阅读”或“关闭”，则不再更新
            local old_dlg = UIHandles.get("detail_dialog")
            if not old_dlg then
                return
            end

            if not ok or not result.ok then
                Log.warn("列出云端书籍失败: " .. tostring(err or result.err))
                no_cloud_fallback()
                return
            end

            local matched_epub = result.matched_epub
            local has_remote_epub = matched_epub ~= nil
            local remote_epub_name = has_remote_epub and matched_epub.name or ""
            local remote_size = has_remote_epub and (matched_epub.size or 0) or 0

            Log.debug("更新对话框: has_remote_epub=" .. tostring(has_remote_epub) .. ", has_local_epub=" .. tostring(has_local_epub))

            local status_text = ""
            local pull_button_enabled = false
            local pull_button_text = has_local_epub and _("更新书籍") or _("拉取书籍")

            if has_remote_epub then
                if has_local_epub then
                    if remote_size > local_size then
                        status_text = string.format(_("[本地: %s] [云端有更新: %s]"), tostring(H.format_file_size(local_size)), tostring(H.format_file_size(remote_size)))
                    elseif remote_size < local_size then
                        status_text = string.format(_("[本地: %s] [云端文件不同: %s]"), tostring(H.format_file_size(local_size)), tostring(H.format_file_size(remote_size)))
                    else
                        status_text = string.format(_("[本地: %s] [云端大小相同]"), tostring(H.format_file_size(local_size)))
                    end
                    pull_button_enabled = true
                    pull_button_text = _("更新书籍")
                else
                    status_text = string.format(_("[云端有书籍: %s (%s)]"), tostring(remote_epub_name), tostring(H.format_file_size(remote_size)))
                    pull_button_enabled = true
                    pull_button_text = _("拉取书籍")
                end
            else
                if has_local_epub then
                    status_text = string.format(_("[本地已下载: %s]"), tostring(H.format_file_size(local_size)))
                else
                    status_text = _("[云端无书籍，请在Legado中导出到legado/books目录]")
                end
                pull_button_enabled = false
            end

            Log.debug("按钮状态: enabled=" .. tostring(pull_button_enabled) .. ", text=" .. pull_button_text)
            show_detail_dialog(status_text, pull_button_enabled, pull_button_text)
        end,
        { timeout = 30 }
    )
end

-- 「删除本地文件 + 清理章节缓存 + 刷新书架」的公共实现。
--
-- delete_book_cache（保留在书架）与 delete_book_completely（从书架移除）此前是两份
-- 逐行重复的实现，只差「是否从书架移除」与文案 —— 合并到这一处，用 remove_from_shelf 区分。
--
-- ⚠️ 形参刻意不叫 `self`：`local function f(self)` 会让 lua_self_method_check 打印
-- 「self 参数重绑定，已跳过」并**静默跳过整个文件**（退出码仍 0，看着是绿的）。
local function confirm_delete_book(plugin, book, remove_from_shelf)
    local ConfirmBox = require("ui/widget/confirmbox")
    local title = book.name or book.title or _("未命名")

    local text, ok_text
    if remove_from_shelf then
        text = string.format(_("确定要彻底删除《%s》吗？\n\n这会删除本地文件，并从书架列表中彻底移除该书。"), title)
        ok_text = _("彻底删除")
    else
        text = string.format(_("确定要删除《%s》的本地文件和缓存吗？\n\n这只会删除已下载的文件，书籍仍会保留在书架中。"), title)
        ok_text = _("删除缓存")
    end

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text,
        ok_callback = function()
            -- 1. 删除本地文件
            local epub_path = plugin.bookshelf:get_epub_for_book(book)
            if epub_path and H.file_exists(epub_path) then
                os.remove(epub_path)
                Log.info("已删除本地书籍文件: " .. epub_path)
            end

            -- 2. 清理章节缓存
            local url = book.bookUrl or ""
            if url ~= "" then
                plugin.bookshelf:clear_book_cache(url)
            end

            -- 3. 仅「彻底删除」才从书架列表移除；「删除缓存」保留条目，
            --    这样非「仅显示已下载」视图中还能看到它。
            if remove_from_shelf then
                local idx_to_remove = nil
                for i, b in ipairs(plugin.bookshelf.books) do
                    if (b.bookUrl and b.bookUrl == url) or (b.name == title) then
                        idx_to_remove = i
                        break
                    end
                end
                if idx_to_remove then
                    table.remove(plugin.bookshelf.books, idx_to_remove)
                    plugin.bookshelf:rebuild_index()
                    plugin.bookshelf:save_bookshelf_cache()
                end
            end

            plugin.bookshelf:invalidate_epub_cache()
            if remove_from_shelf then
                plugin:showInfo(string.format(_("已彻底删除《%s》"), title))
            else
                plugin:showInfo(string.format(_("已删除《%s》的本地文件"), title))
            end

            -- 4. 刷新书架视图
            UIManager:scheduleIn(0.1, function()
                -- 统一用 menu 句柄（active_menu 已废弃，见 main.lua show()）：
                -- 两者原本永远同指一个 widget，多出来的那个句柄会让旧菜单被 close 两次。
                local menu_instance = UIHandles.get("menu")
                if menu_instance and not menu_instance._reading_closed then
                    UIManager:close(menu_instance)
                    plugin:show()
                end
            end)
        end,
    })
end

function M.delete_book_cache(self, book)
    confirm_delete_book(self, book, false)
end

function M.delete_book_completely(self, book)
    confirm_delete_book(self, book, true)
end

function M.start_reading(self, book)
    Log.info("开始阅读: " .. (book.name or book.title or ""))

    local epub_path = self.bookshelf:get_epub_for_book(book)
    Log.info("start_reading: get_epub_for_book 返回 = " .. tostring(epub_path))

    if epub_path then
        -- 校验文件真实存在，避免 showReader 静默失败
        local lfs = require("libs/libkoreader-lfs")
        local attr = lfs.attributes(epub_path)
        if not attr or attr.mode ~= "file" then
            Log.error("start_reading: 本地文件不存在或不可访问: " .. epub_path)
            -- 缓存可能过期，失效后重试一次
            self.bookshelf:invalidate_epub_cache()
            epub_path = self.bookshelf:get_epub_for_book(book)
            Log.info("start_reading: 失效缓存后重新查找 = " .. tostring(epub_path))
            attr = epub_path and lfs.attributes(epub_path) or nil
            if not epub_path or not attr or attr.mode ~= "file" then
                self:showInfo(string.format(_("本地文件丢失，请重新下载《%s》"), tostring(book.name or book.title or "")), false)
                return
            end
        end
        Log.info("start_reading: 文件校验通过，大小=" .. tostring(attr.size) .. " 字节，准备打开: " .. epub_path)
        self:open_epub_book(epub_path, book)
    else
        Log.info("start_reading: 本地未找到书籍，尝试从云端下载")
        self:showInfo(string.format(_("本地无此书，正在从云端下载《%s》..."), tostring(book.name or book.title or "")))
        UIManager:scheduleIn(0.5, function()
            self:download_epub_for_book(book, false)
        end)
    end
end

function M.download_epub_for_book(self, book, force_overwrite)
    force_overwrite = force_overwrite or false
    if not book then return end

    local book_name = book.name or book.title or ""
    local book_author = book.author or ""
    if book_name == "" then
        self:showInfo(_("书籍名称为空"))
        return
    end

    -- 登记「书籍下载」会话（单槽位）：这一步会先整体收掉上一次可能还在跑的下载 ——
    -- 无论它是本入口发起的，还是云端书库入口（downloader.download_cloud_book）发起的。
    -- 此前两条入口各存各的句柄（_download_epub_handle / _download_handle），互相取消
    -- 不到，同一本书会起两个子进程写同一个 save_path（及其 .tmp）。
    --
    -- ⚠️ 顺序不能颠倒：必须先登记（顺带收掉旧会话的 busy 提示与进度窗），**再** showBusy。
    --    否则旧会话的收尾会把本次刚弹出来的 busy 一起关掉。
    local session = self:_begin_book_download()
    session.on_dispose = function()
        -- 本次下载被另一条入口顶掉（或被 onClose 收掉）时，_async_run 的 on_done 不会再
        -- 执行（取消后 poll 直接 return），下面那句 closeBusy 就永远轮不到 ——
        -- busy 提示会永久留在屏幕最上层。这里补上。
        --
        -- ⚠️ busy_msg 是**共享槽位**（UIHandles.set 里同名会顶掉旧的），所以要先确认
        -- 槽里还是本次自己的那个 —— 否则会把此刻的别人的提示（例如云端书库的
        -- 「正在获取云端书库…」）一起关掉。
        if session.busy and UIHandles.get("busy_msg") == session.busy then
            self:closeBusy()
        end
    end

    self:showBusy(force_overwrite and _("正在更新书籍...") or _("正在下载书籍..."))
    -- 记下本次 busy 的归属，供上面的 on_dispose 做身份比对
    session.busy = UIHandles.get("busy_msg")

    local gen = Context.get_generation()
    local books_dir = H.get_books_dir()
    H.make_dir(books_dir)

    local sync_ref = self.sync
    local bookshelf_ref = self.bookshelf
    local self_ref = self
    local book_ref = book
    local force_ref = force_overwrite

    -- 整个 list + match + download 流程在子进程中执行，UI 不阻塞
    session.handle = self:_async_run(
        function()
            local ok, epub_files, err = sync_ref:list_books_directory()
            if not ok then
                return { ok = false, stage = "list", err = tostring(err) }
            end
            local matched_epub = bookshelf_ref:match_epub(book_name, epub_files, book_author)
            if not matched_epub then
                return { ok = false, stage = "match" }
            end
            -- 【更新不得留下旧文件】两道防线（真机反馈：点「更新书籍」后老书没删除）：
            -- ① 清理 Legado 重复导出的 " (N)" 后缀 —— 旧版本当初可能就是带后缀下载的
            --    （或不带），新版本去掉后缀后与旧文件同名，io.open "wb" 直接覆盖；
            -- ② 下载成功后再核对一次「这本书当前实际对应的本地文件」，若与新路径
            --    不同名（换源/改名导出等场景），删掉旧文件 —— 否则本地留两份，
            --    get_epub_for_book 的模糊匹配会在两份之间摇摆。
            local save_path = H.join_path(books_dir, H.clean_legado_filename(matched_epub.name))
            local old_path = bookshelf_ref:get_epub_for_book(book)
            local ok2, __, result = sync_ref:download_epub(matched_epub.path, save_path, force_overwrite, matched_epub.size)
            if not ok2 then
                return { ok = false, stage = "download", err = tostring(result) }
            end
            if old_path and old_path ~= save_path and H.file_exists(old_path) then
                os.remove(old_path)
                Log.info("更新书籍: 已删除旧版本文件 " .. old_path .. "（新文件 " .. save_path .. "）")
            end
            return { ok = true, save_path = save_path, result = result }
        end,
        function(ok, result, err)
            self_ref:_end_book_download(session)
            self_ref:closeBusy()
            if not ok then
                Log.error("EPUB下载异步失败: " .. tostring(err))
                self_ref:showInfo(T(_("下载失败:\n%1"), tostring(err)), false)
                return
            end
            if not result.ok then
                if result.stage == "match" then
                    self_ref:showInfo(T(_("云端未找到书籍: %1\n请在Legado中导出到legado/books目录"), tostring(book_name)), false)
                elseif result.stage == "list" then
                    self_ref:showInfo(T(_("查找书籍失败:\n%1"), tostring(result.err)), false)
                else
                    self_ref:showInfo(T(_("下载失败:\n%1"), tostring(result.err)), false)
                end
                return
            end
            Log.info("EPUB下载成功: " .. result.save_path)
            if result.result == "skipped" then
                self_ref:showInfo(_("文件未更新"))
            else
                self_ref.bookshelf:invalidate_epub_cache()
                self_ref:showInfo(force_ref and _("更新完成") or _("下载完成"))
                UIManager:scheduleIn(0.5, function()
                    if Context.get_generation() ~= gen then
                        Log.debug("download_epub_for_book: 阅读会话已变更，放弃打开书籍")
                        return
                    end
                    self_ref:open_epub_book(result.save_path, book_ref)
                end)
            end
        end,
        { timeout = 120 }
    )
end

function M.open_epub_book(self, epub_path, book)
    Context.set_current_book(book)
    Context.set_current_epub_path(epub_path)

    Log.info("open_epub_book: " .. epub_path)
    
    -- 每次打开书籍时，清空内存中的锚点表标记，防止 EPUB 版本更新后复用旧锚点
    if book then
        book._toc_anchors_loaded = nil
        book.toc_anchors = nil
        book._toc_anchors_dirty = false
    end

    local ReaderUI = require("apps/reader/readerui")
    local Event = require("ui/event")
    local InfoMessage = require("ui/widget/infomessage")
    Log.info("open_epub_book: ReaderUI.instance = " .. tostring(ReaderUI.instance))
    Log.info("open_epub_book: self.ui 类型 = " .. tostring(self.ui and self.ui.__ctype or "nil"))

    -- 【过渡提示】从「点开始阅读 / 下载完成」到阅读器真正上屏之间（Kindle 上常有
    -- 1~3 秒的 CREngine 加载），此前屏幕上没有任何反馈 —— 弹窗一关就是一段静止
    -- 画面，观感生硬（真机反馈）。而 seamless=true 恰好隐藏了上游 showReader
    -- 自带的 "Opening file" 提示（showReaderCoroutine 里 invisible=seamless），
    -- 所以这里自己补一条「正在打开…」，并在 ReaderReady 之后
    -- （showReader 的 after_open_callback，readerui.lua:525）关掉。
    -- timeout=60 只是兜底：万一打开流程在 ReaderReady 之前异常中断，
    -- 提示不至于永久挂在屏幕上（InfoMessage 默认可点掉）。
    local open_msg = InfoMessage:new{
        text = (book and (book.name or book.title))
            and T(_("正在打开《%1》..."), tostring(book.name or book.title))
            or _("正在打开书籍..."),
        timeout = 60,
    }
    UIManager:show(open_msg)

    local ok, err = pcall(function()
        -- 不用 switchDocument（其内部先 onClose 再 showReader，中间 forceRePaint 会闪现书架，
        -- 且旧实例的 onCloseDocument 会清掉刚设置的新书上下文与 pending_jump）。
        -- 直接用 showReader：doShowReader 在 nextTick 中关闭旧实例并打开新实例，无闪现。
        -- seamless=true 隐藏“打开文件”提示并避免全屏刷新（上游那条提示被上面的
        -- 「正在打开…」替代了，闪屏避免仍然保留）。
        if not ReaderUI.instance then
            -- 通知 FileManager 标记 tearing_down（不立即关闭），优化后续刷新，
            -- 与 cloudstorage/dictquicklookup 等内置模块的打开方式一致。
            Log.info("open_epub_book: 广播 SetupShowReader 事件")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
        end
        Log.info("open_epub_book: 调用 ReaderUI:showReader(" .. epub_path .. ", nil, true)")
        ReaderUI:showReader(epub_path, nil, true, nil, function()
            UIManager:close(open_msg)
        end)
        Log.info("open_epub_book: showReader 调用完成")
    end)
    if not ok then
        -- 失败路径也要关掉提示，否则它和 showError 的错误提示叠在一起
        UIManager:close(open_msg)
        Log.error("open_epub_book 失败: " .. tostring(err))
        self:showError(_("打开书籍"), err)
    else
        Log.info("open_epub_book: 流程正常结束")
    end
end

return M
