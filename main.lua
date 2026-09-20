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

local lfs = safe_require("libs/libkoreader-lfs")

local UIManager = safe_require("ui/uimanager")

local InfoMessage = safe_require("ui/widget/infomessage")

local ConfirmBox = safe_require("ui/widget/confirmbox")

local InputDialog = safe_require("ui/widget/inputdialog")

local Menu = safe_require("ui/widget/menu")

local H = require("reading.helper")

local Event = safe_require("ui/event")

local logger = safe_require("logger")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or function(str, ...) return str end

local util = safe_require("util")

local Device = safe_require("device")
local Screen = Device and Device.screen

-- Local libs
local Settings = safe_require("reading.settings")
local Sync = safe_require("reading.sync")
local Bookshelf = safe_require("reading.bookshelf")
local ReadRecord = safe_require("reading.read_record")
local ShelfView = safe_require("reading.shelf_view")
local Log = safe_require("reading.log")
local Result = safe_require("reading.result")
local Async = safe_require("reading.async")

local unpack_args = unpack or table.unpack

-- 阅读上下文状态（替代原 _state 中的阅读会话字段，含 generation 令牌防竞态）
local Context = require("reading.reading_context")
-- UI 句柄管理（替代原 _state 中的 UI 字段，修复 chapter_list_menu 泄漏）
local UIHandles = require("reading.ui_handles")

local ReadingPlugin = WidgetContainer:extend{
    name = "reading",
    is_doc_only = false,
    fullname = "开源阅读",
    version = "0.1.0",
}

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
        -- ReaderUI 实例的 bookshelf 默认为空（init 不加载缓存），
        -- 这里按需加载缓存，确保能匹配到当前书籍并恢复 current_book（进度同步依赖此）。
        if #books == 0 then
            local cached = self.bookshelf:load_bookshelf_cache()
            if cached and #cached > 0 then
                books = cached
                Log.info("ReaderUI 实例按需加载书架缓存: " .. #books .. " 本书")
            end
        end

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
        Log.info("阅读界面就绪，章节变化时将自动异步上传进度")

        -- 阅读器就绪后加载章节，并执行 pending_jump（如果有）
        self:_load_chapters_from_document()

        -- 初始化已上传章节标记为当前章节，避免进入阅读时立即触发上传
        local book = Context.get_current_book()
        if book then
            self._last_synced_chapter = book.durChapterIndex
        end

        -- 进入阅读界面时自动拉取云端进度并对比
        self:_auto_pull_and_compare()
    end
end

function ReadingPlugin:init()
    self.settings = Settings:new()
    
    local H = require("reading.helper")
    Log.init(H.get_data_dir() .. "/reading.log")
    
    self.sync = Sync:new(self.settings)
    self.bookshelf = Bookshelf:new(self.settings)
    self.read_record = ReadRecord:new(self.settings)
    
    -- 章节变化触发的进度上传：记录上次已上传的章节索引，避免同章内重复上传
    self._last_synced_chapter = nil
    
    -- 用于管理当前正在运行的异步任务的句柄集合
    self._async_handles = {}
    
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    
    Log.info("开源阅读插件初始化完成")
end

function ReadingPlugin:showBusy(text)
    -- 使用 UIHandles 共享句柄，确保 FileManager 和 ReaderUI 实例都能关闭 busy 消息
    UIHandles.set("busy_msg", InfoMessage:new{ text = text, norefresh = true })
    UIManager:show(UIHandles.get("busy_msg"))
    UIManager:forceRePaint()
end

function ReadingPlugin:closeBusy()
    UIHandles.close("busy_msg")
end

function ReadingPlugin:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

--- 统一错误展示：closeBusy + log + showInfo
function ReadingPlugin:showError(label, err)
    self:closeBusy()
    local fmt_err = Result and Result.format_error(err) or tostring(err)
    Log.error(label .. " 失败: " .. fmt_err)
    self:showInfo(T(_("%1 failed:\n%2"), label, fmt_err))
end

--- 统一的同步完成处理：更新书架 + 保存缓存 + 合并阅读记录 + 刷新 UI
-- @param sync_data table  { books, book_sources, replace_rules, read_records }
function ReadingPlugin:_complete_sync(sync_data)
    if not sync_data then return end

    self.bookshelf:apply_sync_data(sync_data)
    self.bookshelf:save_bookshelf_cache(self.bookshelf:get_books())

    local records = sync_data.read_records or {}
    if #records > 0 then
        local updated_count = self.read_record:merge_from_sync(records)
        self:showInfo(T(_("同步成功，更新了 %1 条阅读记录"), updated_count))
    else
        self:showInfo(_("同步成功"))
    end

    if UIHandles.get("menu") then
        UIManager:close(UIHandles.get("menu"))
    end
    self:show()
end

--- 统一的回调保护包装器（替代原 safeCallback 和 _safeAsync）
-- @param label 描述（日志和错误提示用）
-- @param callback 实际函数
-- @return 包装后的函数，接受任意参数
function ReadingPlugin:_guard(label, callback)
    local self_ref = self
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, function(err) return tostring(err) end)
        if not ok then
            self_ref:showError(label, err)
        end
    end
end

--- 异步执行 work_func（在子进程中），完成后在 UI 线程回调 on_done(ok, result, err)。
--- Async 模块不可用时自动降级为 scheduleIn 同步执行（仍会短暂阻塞 UI）。
--- @param work_func function  子进程中执行的无参闭包，返回可 JSON 序列化值
--- @param on_done function|nil  回调 function(ok, result, err)
--- @param opts table|nil  { timeout=60, poll_interval=0.125, delay=0 }
function ReadingPlugin:_async_run(work_func, on_done, opts)
    -- 包装 on_done 以捕获回调异常（回调在 UI 线程执行，异常不应中断 UIManager）
    local safe_on_done = nil
    local handle_id = tostring(os.clock()) .. "_" .. tostring(math.random(10000, 99999))
    local self_ref = self
    
    if on_done then
        safe_on_done = function(ok, result, err)
            -- 任务完成后清理句柄引用
            if self_ref._async_handles then
                self_ref._async_handles[handle_id] = nil
            end
            
            local call_ok, call_err = xpcall(function()
                on_done(ok, result, err)
            end, function(e) return tostring(e) end)
            if not call_ok then
                Log.error("_async_run 回调异常: " .. call_err)
            end
        end
    else
        safe_on_done = function()
            if self_ref._async_handles then
                self_ref._async_handles[handle_id] = nil
            end
        end
    end
    
    if Async and Async.run then
        local handle = Async.run(work_func, safe_on_done, opts)
        if handle and self._async_handles then
            self._async_handles[handle_id] = handle
        end
        return handle
    end
    -- 降级：scheduleIn 同步执行（UI 线程阻塞）
    opts = opts or {}
    UIManager:scheduleIn(opts.delay or 0, function()
        local ok, result = pcall(work_func)
        if safe_on_done then
            if ok then safe_on_done(true, result, nil)
            else safe_on_done(false, nil, tostring(result)) end
        end
    end)
    return nil
end

--- 取消特定的异步任务或所有任务
function ReadingPlugin:_cancel_async(handle_or_id)
    if not self._async_handles then return end
    
    if handle_or_id == nil then
        -- 取消所有任务
        for id, handle in pairs(self._async_handles) do
            if type(handle) == "table" and type(handle.cancel) == "function" then
                pcall(handle.cancel)
            end
        end
        self._async_handles = {}
    elseif type(handle_or_id) == "string" then
        -- 按 ID 取消
        local handle = self._async_handles[handle_or_id]
        if handle and type(handle) == "table" and type(handle.cancel) == "function" then
            pcall(handle.cancel)
            self._async_handles[handle_or_id] = nil
        end
    elseif type(handle_or_id) == "table" and type(handle_or_id.cancel) == "function" then
        -- 直接通过句柄取消
        pcall(handle_or_id.cancel)
        -- 尝试从集合中移除
        for id, h in pairs(self._async_handles) do
            if h == handle_or_id then
                self._async_handles[id] = nil
                break
            end
        end
    end
end

function ReadingPlugin:getSettingsMenuItems()
    -- 直接展开 WebDAV 设置，去除多余的"同步文件链接"层级
    return self:getWebDAVMenuItems()
end

function ReadingPlugin:getWebDAVMenuItems()
    local server = self.settings:get_webdav_server()
    local username = self.settings:get_webdav_username()
    local password = self.settings:get_webdav_password()
    local remote_path = self.settings:get_webdav_remote_path()
    
    local display_username = username and username ~= "" and username or "未设置"
    local display_server = server and server ~= "" and server or "未设置"
    local display_remote_path = remote_path and remote_path ~= "" and remote_path or "未设置"
    
    return {
        {
            text = _("使用 config.lua 配置（推荐）"),
            separator = true,
        },
        {
            text = _("重新加载 config.lua"),
            keep_menu_open = true,
            callback = function()
                local ok = self.settings:reload_config()
                if ok then
                    self:showInfo(_("config.lua 已重新加载"))
                else
                    self:showInfo(_("config.lua 加载失败，请检查文件是否存在"))
                end
            end,
        },
        {
            text = _("界面设置（仅当前设备有效）"),
            separator = true,
        },
        {
            text = T(_("服务器: %1"), display_server),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("server", server, "请输入 WebDAV 服务器地址")
            end,
        },
        {
            text = T(_("用户名: %1"), display_username),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("username", username, "请输入 WebDAV 用户名")
            end,
        },
        {
            text = _("密码: ******"),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("password", password, "请输入 WebDAV 密码")
            end,
        },
        {
            text = T(_("远程路径: %1"), display_remote_path),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("remote_path", remote_path, "请输入远程路径")
            end,
        },
        {
            text = _("测试连接"),
            keep_menu_open = true,
            callback = function()
                self:test_webdav_connection()
            end,
        },
        {
            text = _("选择备份文件同步"),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_file_list()
            end,
        },
    }
end

function ReadingPlugin:getLogMenuItems()
    local is_debug_on = Log.is_debug_enabled()
    return {
        {
            text = _("查看日志文件"),
            keep_menu_open = true,
            callback = function()
                self:view_log()
            end,
        },
        {
            text = is_debug_on and _("关闭调试日志") or _("开启调试日志"),
            keep_menu_open = true,
            checked_func = function()
                return is_debug_on
            end,
            callback = function()
                Log.set_debug_enabled(not is_debug_on)
                self:showInfo(is_debug_on and _("调试日志已关闭") or _("调试日志已开启"))
            end,
        },
        {
            text = _("清除日志"),
            keep_menu_open = true,
            callback = function()
                Log.clear_log()
                self:showInfo(_("日志已清除"))
            end,
        },
    }
end

function ReadingPlugin:show_sync_url_dialog()
    local current_url = self.settings:get_sync_url()
    local dialog
    dialog = InputDialog:new{
        title = _("同步文件链接"),
        input = current_url,
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        self.settings:set_sync_url(url)
                        UIManager:show(InfoMessage:new{
                            text = _("设置已保存"),
                        })
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ReadingPlugin:show_webdav_input_dialog(field, current_value, hint)
    Log.debug("打开WebDAV设置对话框: " .. field .. ", 当前值: " .. tostring(current_value))
    local dialog
    dialog = InputDialog:new{
        title = _("WebDAV " .. field),
        input = current_value,
        input_hint = hint,
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        Log.debug("保存WebDAV设置: " .. field .. " = " .. tostring(value))
                        if field == "server" then
                            self.settings:set_webdav_server(value)
                        elseif field == "username" then
                            self.settings:set_webdav_username(value)
                        elseif field == "password" then
                            self.settings:set_webdav_password(value)
                        elseif field == "remote_path" then
                            self.settings:set_webdav_remote_path(value)
                        end
                        
                        UIManager:show(InfoMessage:new{
                            text = _("设置已保存"),
                        })
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ReadingPlugin:test_webdav_connection()
    self:showBusy(_("正在测试连接..."))
    local sync_ref = self.sync
    local self_ref = self
    self:_async_run(
        function()
            local ok, _, err = sync_ref:test_webdav_connection()
            return { ok = ok, err = err }
        end,
        function(ok, result, err)
            self_ref:closeBusy()
            if ok and result and result.ok then
                self_ref:showInfo(_("WebDAV 连接成功"))
            else
                self_ref:showInfo(T(_("WebDAV 连接失败:\n%1"), err or (result and result.err)))
            end
        end,
        { timeout = 30 }
    )
end

function ReadingPlugin:sync_from_webdav_auto()
    Log.info("执行一键同步（从WebDAV自动拉取最新备份）")
    self:showBusy(_("正在同步..."))
    local sync_ref = self.sync
    local self_ref = self
    self:_async_run(
        function()
            local ok, __, err = sync_ref:sync_from_webdav()
            if not ok then
                return { ok = false, err = err }
            end
            return { ok = true, data = sync_ref:get_sync_data() }
        end,
        function(ok, result, err)
            self_ref:closeBusy()
            if not ok or not result or not result.ok then
                self_ref:showInfo(T(_("同步失败: %1"), err or (result and result.err)))
                return
            end
            self_ref:_complete_sync(result.data)
        end,
        { timeout = 60 }
    )
end

function ReadingPlugin:show_webdav_file_list()
    Log.info("显示WebDAV文件列表")
    self:showBusy(_("正在连接..."))

    local sync_ref = self.sync
    local self_ref = self
    self:_async_run(
        function()
            local ok2, items, err2 = sync_ref.webdav:list("")
            if not ok2 then
                return { ok = false, err = err2 or _("列出文件失败") }
            end
            return { ok = true, items = items }
        end,
        function(ok, result, err)
            self_ref:closeBusy()
            if not ok or not result or not result.ok then
                self_ref:showInfo(T(_("WebDAV 连接失败:\n%1"), err or (result and result.err)))
                return
            end
            ShelfView.show_webdav_file_list(sync_ref.webdav, function(filename, url)
                self_ref:perform_sync_from_file(filename, url)
            end)
        end,
        { timeout = 30 }
    )
end

function ReadingPlugin:perform_sync_from_file(filename, url)
    -- 双重保险：确保文件列表对话框关闭（即使 callback 中关闭失败，这里也处理）
    if UIHandles.get("webdav_file_list") then
        UIManager:close(UIHandles.get("webdav_file_list"))
        UIHandles.clear("webdav_file_list")
    end
    Log.info("开始同步文件: " .. filename)
    local self_ref = self
    local sync_ref = self.sync
    local sync_dir = H.get_sync_dir()

    self:showBusy(_("正在下载与解析..."))
    self:_async_run(
        function()
            local ok, content = sync_ref.webdav:get_file(url)
            if not ok then
                return { ok = false, err = content }
            end

            if filename:match("%.zip$") then
                H.make_dir(sync_dir)
                local zip_path = H.join_path(sync_dir, "sync_backup.zip")
                local file = io.open(zip_path, "wb")
                if not file then
                    return { ok = false, err = _("无法保存文件") }
                end
                file:write(content)
                file:close()

                local ok2, extract_dir = sync_ref:extract_zip(zip_path)
                if not ok2 then
                    return { ok = false, err = T(_("解压失败:\n%1"), extract_dir) }
                end
                sync_ref:load_from_extracted_dir(extract_dir)
            else
                local files = sync_ref:parse_backup(content)
                sync_ref:load_from_files(files)
            end

            return { ok = true, data = sync_ref:get_sync_data() }
        end,
        function(ok, result, err)
            self_ref:closeBusy()
            if not ok or not result or not result.ok then
                self_ref:showInfo(T(_("同步失败:\n%1"), err or (result and result.err)))
                return
            end
            self_ref:_complete_sync(result.data)
        end,
        { timeout = 60 }
    )
end

function ReadingPlugin:show()
    -- 标识当前实例类型（FileManager / ReaderUI），辅助定位书架空白问题
    local instance_type = (self.ui and self.ui.document) and "ReaderUI" or "FileManager"
    Log.info("show() 入口 [" .. instance_type .. "]")

    local cached_books = self.bookshelf:load_bookshelf_cache()
    Log.info("show() load_bookshelf_cache 返回: " .. (cached_books and #cached_books or "nil") .. " 本")

    local books = self.bookshelf:get_books()
    Log.info("show() get_books 返回: " .. #books .. " 本")

    -- 构建阅读记录查找表（O(1) 替代原线性查找）
    local record_index = {}
    for _, rec in ipairs(self.read_record.records) do
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

    -- 从已排序的 books 构建 valid_books，保持排序顺序
    local valid_books = {}
    for ___, book in ipairs(books) do
        local title = book.name or book.title or ""
        if title ~= "" then
            valid_books[#valid_books + 1] = book
        end
    end
    books = valid_books
    Log.info("show() valid_books 过滤后: " .. #books .. " 本，准备显示书架")
    
    UIHandles.set("menu", ShelfView.show{
        books = books,
        bookshelf = self.bookshelf,
        settings = self.settings,
        on_select = function(book)
            self:show_book_detail(book)
        end,
        on_sync = function()
            self:show_webdav_file_list()
        end,
        on_sync_books = function()
            self:sync_epub_files()
        end,
        on_settings = function()
            -- Settings are in main menu now
            if UIHandles.get("menu") then
                UIManager:close(UIHandles.get("menu"))
            end
        end,
        on_close = function()
            UIHandles.clear("menu")
        end,
    })
    UIHandles.set("active_menu", UIHandles.get("menu"))
end

function ReadingPlugin:perform_sync(url)
    self:showBusy(_("正在同步..."))
    local sync_ref = self.sync
    local self_ref = self
    self:_async_run(
        function()
            local ok, msg = sync_ref:sync_from_url(url)
            if not ok then
                return { ok = false, err = msg }
            end
            return { ok = true, data = sync_ref:get_sync_data() }
        end,
        function(ok, result, err)
            self_ref:closeBusy()
            if not ok or not result or not result.ok then
                self_ref:showInfo(T(_("同步失败: %1"), err or (result and result.err)))
                return
            end
            self_ref:_complete_sync(result.data)
        end,
        { timeout = 60 }
    )
end

function ReadingPlugin:show_book_detail(book)
    Context.set_current_book(book)

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
    local chapter_text = book.durChapterIndex and T(_("当前章节: 第 %1 章"), book.durChapterIndex + 1) or ""

    local function build_info_text(status_text)
        local result = book_name
        if author_text ~= "" then
            result = result .. "\n" .. author_text
        end
        if chapter_text ~= "" then
            result = result .. "\n" .. chapter_text
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
                    text = _("查看简介"),
                    callback = function()
                        self_ref:show_book_intro(book)
                    end,
                },
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
    local initial_status = has_local_epub and T(_("[本地已下载: %1]"), H.format_file_size(local_size)) or _("[检查云端中...]")
    show_detail_dialog(initial_status, false, nil)

    -- 异步检查云端书籍，完成后用新对话框替换旧对话框（callback 正确绑定）
    UIManager:scheduleIn(0.1, self:_guard(_("检查云端书籍"), function()
        local ok, epub_files, err = self_ref.sync:list_books_directory()
        if not ok then
            Log.warn("列出云端书籍失败: " .. tostring(err))
            no_cloud_fallback()
            return
        end

        local book_name_for_match = book.name or book.title or ""
        if book_name_for_match == "" then
            no_cloud_fallback()
            return
        end

        local matched_epub = self_ref.bookshelf:match_epub(book_name_for_match, epub_files, book.author)

        local has_remote_epub = matched_epub ~= nil
        local remote_epub_name = has_remote_epub and matched_epub.name or ""
        local remote_size = has_remote_epub and (matched_epub.size or 0) or 0

        Log.debug("更新对话框: has_remote_epub=" .. tostring(has_remote_epub) .. ", has_local_epub=" .. tostring(has_local_epub))

        local status_text = ""
        local pull_button_enabled = false
        local pull_button_text = has_local_epub and _("更新书籍") or _("拉取书籍")

        if has_remote_epub then
            if has_local_epub then
                -- 不用文件大小判断是否有更新：云端可能是不同章节范围的导出
                -- （如之前导出1-300章，云端导出300-350章，文件更小但内容不同）
                if remote_size > local_size then
                    status_text = T(_("[本地: %1] [云端有更新: %2]"), H.format_file_size(local_size), H.format_file_size(remote_size))
                elseif remote_size < local_size then
                    status_text = T(_("[本地: %1] [云端文件不同: %2]"), H.format_file_size(local_size), H.format_file_size(remote_size))
                else
                    status_text = T(_("[本地: %1] [云端大小相同]"), H.format_file_size(local_size))
                end
                pull_button_enabled = true
                pull_button_text = _("更新书籍")
            else
                status_text = T(_("[云端有书籍: %1 (%2)]"), remote_epub_name, H.format_file_size(remote_size))
                pull_button_enabled = true
                pull_button_text = _("拉取书籍")
            end
        else
            if has_local_epub then
                status_text = T(_("[本地已下载: %1]"), H.format_file_size(local_size))
            else
                status_text = _("[云端无书籍，请在Legado中导出到legado/books目录]")
            end
            pull_button_enabled = false
        end

        Log.debug("按钮状态: enabled=" .. tostring(pull_button_enabled) .. ", text=" .. pull_button_text)
        show_detail_dialog(status_text, pull_button_enabled, pull_button_text)
    end))
end

function ReadingPlugin:show_book_intro(book)
    local intro = book.intro or book.desc or book.description
    
    if not intro or type(intro) ~= "string" or intro == "" then
        intro = _("暂无简介")
    end
    
    if intro:len() > 500 then
        intro = intro:sub(1, 500) .. "..."
    end
    
    -- UIManager:show 为第三方 UI 调用，用 Result.try 统一包装为 (ok, result, err)
    local ok, __, err = Result.try(function()
        UIManager:show(InfoMessage:new{
            text = intro,
            timeout = 0,
        })
    end, "显示简介")

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("显示简介失败"),
            timeout = 2,
        })
    end
end

function ReadingPlugin:start_reading(book)
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
                self:showInfo(T(_("本地文件丢失，请重新下载《%1》"), book.name or book.title or ""))
                return
            end
        end
        Log.info("start_reading: 文件校验通过，大小=" .. tostring(attr.size) .. " 字节，准备打开: " .. epub_path)
        self:open_epub_book(epub_path, book)
    else
        Log.info("start_reading: 本地未找到书籍，尝试从云端下载")
        self:showInfo(T(_("本地无此书，正在从云端下载《%1》..."), book.name or book.title or ""))
        UIManager:scheduleIn(0.5, function()
            self:download_epub_for_book(book, false)
        end)
    end
end

function ReadingPlugin:open_book(book)
    self:show_book_detail(book)
end

function ReadingPlugin:download_epub_for_book(book, force_overwrite)
    force_overwrite = force_overwrite or false
    if not book then return end

    local book_name = book.name or book.title or ""
    local book_author = book.author or ""
    if book_name == "" then
        self:showInfo(_("书籍名称为空"))
        return
    end

    -- 取消之前的书籍下载任务，避免并发下载或回调混乱
    if self._download_epub_handle then
        self:_cancel_async(self._download_epub_handle)
        self._download_epub_handle = nil
    end

    self:showBusy(force_overwrite and _("正在更新书籍...") or _("正在下载书籍..."))

    local gen = Context.get_generation()
    local books_dir = H.get_books_dir()
    H.make_dir(books_dir)

    local sync_ref = self.sync
    local bookshelf_ref = self.bookshelf
    local self_ref = self
    local book_ref = book
    local force_ref = force_overwrite

    -- 整个 list + match + download 流程在子进程中执行，UI 不阻塞
    self._download_epub_handle = self:_async_run(
        function()
            local ok, epub_files, err = sync_ref:list_books_directory()
            if not ok then
                return { ok = false, stage = "list", err = tostring(err) }
            end
            local matched_epub = bookshelf_ref:match_epub(book_name, epub_files, book_author)
            if not matched_epub then
                return { ok = false, stage = "match" }
            end
            local save_path = H.join_path(books_dir, matched_epub.name)
            local ok2, _, result = sync_ref:download_epub(matched_epub.path, save_path, force_overwrite, matched_epub.size)
            if not ok2 then
                return { ok = false, stage = "download", err = tostring(result) }
            end
            return { ok = true, save_path = save_path, result = result }
        end,
        function(ok, result, err)
            self_ref._download_epub_handle = nil
            self_ref:closeBusy()
            if not ok then
                Log.error("EPUB下载异步失败: " .. tostring(err))
                self_ref:showInfo(_("下载失败: ") .. tostring(err))
                return
            end
            if not result.ok then
                if result.stage == "match" then
                    self_ref:showInfo(T(_("云端未找到书籍: %1\n请在Legado中导出到legado/books目录"), book_name))
                elseif result.stage == "list" then
                    self_ref:showInfo(_("查找书籍失败: ") .. tostring(result.err))
                else
                    self_ref:showInfo(_("下载失败: ") .. tostring(result.err))
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

function ReadingPlugin:open_epub_book(epub_path, book)
    Context.set_current_book(book)
    Context.set_current_epub_path(epub_path)

    Log.info("open_epub_book: " .. epub_path)

    local ReaderUI = require("apps/reader/readerui")
    local Event = require("ui/event")
    Log.info("open_epub_book: ReaderUI.instance = " .. tostring(ReaderUI.instance))
    Log.info("open_epub_book: self.ui 类型 = " .. tostring(self.ui and self.ui.__ctype or "nil"))

    local ok, err = pcall(function()
        -- 不用 switchDocument（其内部先 onClose 再 showReader，中间 forceRePaint 会闪现书架，
        -- 且旧实例的 onCloseDocument 会清掉刚设置的新书上下文与 pending_jump）。
        -- 直接用 showReader：doShowReader 在 nextTick 中关闭旧实例并打开新实例，无闪现。
        -- seamless=true 隐藏“打开文件”提示并避免全屏刷新。
        if not ReaderUI.instance then
            -- 通知 FileManager 标记 tearing_down（不立即关闭），优化后续刷新，
            -- 与 cloudstorage/dictquicklookup 等内置模块的打开方式一致。
            Log.info("open_epub_book: 广播 SetupShowReader 事件")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
        end
        Log.info("open_epub_book: 调用 ReaderUI:showReader(" .. epub_path .. ", nil, true)")
        ReaderUI:showReader(epub_path, nil, true)
        Log.info("open_epub_book: showReader 调用完成")
    end)
    if not ok then
        Log.error("open_epub_book 失败: " .. tostring(err))
        self:showError(_("打开书籍"), err)
    else
        Log.info("open_epub_book: 流程正常结束")
    end
end

function ReadingPlugin:_load_chapters_from_document(retry_count)
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

    local toc = reader.document:getToc()
    if toc and #toc > 0 then
        Context.set_current_chapters({})
        for ___, entry in ipairs(toc) do
            local title = entry.title or ""
            table.insert(Context.get_current_chapters(), {
                name = title,
                -- 预处理并缓存 normalize 后的标题，优化查找效率
                norm_name = title:gsub("%s+", ""),
                xpointer = entry.xpointer or "",
                page = entry.page or 1,
            })
        end
        Log.info("加载目录完成，共 " .. #Context.get_current_chapters() .. " 章")
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
            local jump_index = legado_index  -- 最终传给 read_chapter 的索引（Legado 基准）

            -- 优先用章节标题匹配，解决 Legado 与 EPUB TOC 索引偏移（目录/简介等前置条目）
            if chapter_title and chapter_title ~= "" then
                local matched_epub_idx = self:_find_chapter_by_title(Context.get_current_chapters(), chapter_title)
                if matched_epub_idx then
                    -- 标题匹配到的是 EPUB TOC 1-based 索引，反推 Legado 0-based 索引
                    -- legado_0based = epub_1based - toc_offset
                    local book = Context.get_current_book()
                    local offset = book and book.toc_offset or 1
                    jump_index = math.max(0, matched_epub_idx - offset)
                    Log.info("pending_jump 标题匹配: 云端第" .. legado_index .. "章 '" .. chapter_title .. "' -> EPUB TOC " .. matched_epub_idx .. " (offset=" .. offset .. ") -> Legado " .. jump_index)
                else
                    Log.warn("pending_jump 标题匹配失败，回退使用索引: 第" .. legado_index .. "章")
                end
            end

            -- 最终跳转索引的边界保护（Legado 0-based：0 ~ totalChapters-1）
            if jump_index < 0 then jump_index = 0 end
            local offset_for_max = (Context.get_current_book() and Context.get_current_book().toc_offset) or 1
            local max_legado = #Context.get_current_chapters() - offset_for_max  -- EPUB 总数 - offset = Legado 最大 0-based 索引
            if jump_index > max_legado then jump_index = max_legado end

            self:read_chapter(jump_index, chapter_pos)

            -- 跳转完成后才显示成功消息
            local book = Context.get_current_book()
            local offset = book and book.toc_offset or 1
            local jumped_epub_idx = jump_index + offset
            if jumped_epub_idx < 1 then jumped_epub_idx = 1 end
            if jumped_epub_idx > #Context.get_current_chapters() then
                jumped_epub_idx = #Context.get_current_chapters()
            end
            local jumped_title = Context.get_current_chapters()[jumped_epub_idx].name or ""
            self:showInfo(T(_("已跳转到第 %1 章 %2"), jump_index + 1, jumped_title))
        else
            Log.warn("_load_chapters_from_document: 目录为空，无法跳转")
            self:showInfo(_("目录为空，无法跳转"))
        end
    end

    self:closeBusy()
end



function ReadingPlugin:show_chapter_list()
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

    -- book.durChapterIndex 是 Legado 0-based，ShelfView 用 Lua 1-based，需要 +1
    local current_chapter_index = (book.durChapterIndex or 0) + 1

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
            -- ShelfView 回调 index 是 Lua 1-based，read_chapter 期望 Legado 0-based，需要 -1
            self:read_chapter(index - 1)
        end,
        function()
            self:refresh_toc()
        end,
        book.name or book.title or "目录"
    ))
end

function ReadingPlugin:refresh_toc()
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

function ReadingPlugin:read_chapter(chapter_index, chapter_pos)
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

    -- 获取 TOC 偏移量：epub_1based = legado_0based + toc_offset
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local toc = reader and reader.document and reader.document:getToc() or nil
    local toc_offset = self:_get_toc_offset(book, toc)

    -- 转换为 EPUB TOC 1-based 索引（用于查 chapters 表和 toc 表）
    local epub_index = chapter_index + toc_offset

    -- 标题验证（反向）：从 Legado 章节列表获取标题，在 EPUB TOC 中查找
    -- 处理"作者有话说""紧急求助"等动态插入导致偏移量失效的情况
    local verified_epub = self:_verify_epub_index_by_title(book, chapter_index, toc or chapters)
    if verified_epub then
        epub_index = verified_epub
    end

    -- 边界保护（epub_index 是 1-based）
    if epub_index < 1 then epub_index = 1 end
    if epub_index > #chapters then epub_index = #chapters end

    -- 反算合法的 Legado 索引（防止越界后数据不一致）
    local legado_index = epub_index - toc_offset
    if legado_index < 0 then legado_index = 0 end

    Log.debug("read_chapter: Legado " .. chapter_index .. " + offset " .. toc_offset .. " = EPUB " .. epub_index)

    -- 用 EPUB 1-based 索引查 chapters 表
    Context.set_current_chapter_index(epub_index)
    local chapter = chapters[epub_index]

    -- 存入 book 的是 Legado 0-based 索引（与 Legado App 一致）
    book.durChapterIndex = legado_index
    book.durChapterTitle = chapter.name
    book.durChapterPos = chapter_pos
    book.lastCheckTime = os.time()

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
                self:showInfo(T(_("无法跳转到第 %1 章"), legado_index + 1))
            end
        else
            Log.warn("目录为空或章节索引无效: EPUB TOC=" .. epub_index)
            self:showInfo(T(_("无法跳转到第 %1 章"), legado_index + 1))
        end
    else
        Log.warn("ReaderUI实例或文档为空")
        self:showInfo(_("请先打开书籍"))
    end
end





function ReadingPlugin:_auto_pull_and_compare()
    if not self.settings:is_progress_auto_sync_enabled() then return end
    local book = Context.get_current_book()
    if not book then return end

    local book_name = book.name or book.title or ""
    local book_author = book.author or ""
    if book_name == "" then return end

    -- 捕获 generation 令牌，异步回调执行时校验，防止切书后旧回调上传旧书进度
    local gen = Context.get_generation()

    Log.info("自动拉取云端进度进行对比: " .. book_name)

    UIManager:scheduleIn(0.5, self:_guard(_("自动拉取云端进度"), function()
        -- 令牌校验：若期间切换了书籍，放弃本次回调
        if Context.get_generation() ~= gen then
            Log.debug("自动拉取: 阅读会话已变更，放弃")
            return
        end

        local sync_ref = self.sync
        local self_ref = self

        -- get_book_progress 在子进程中执行，不阻塞 UI
        self:_async_run(
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
    end))
end

function ReadingPlugin:save_read_progress(chapter_index)
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
            local ok, _, err = sync_ref:upload_book_progress(
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

function ReadingPlugin:pull_cloud_progress()
    if not Context.get_current_book() then return end

    -- 捕获 generation 令牌，异步回调执行时校验
    local gen = Context.get_generation()

    self:showBusy(_("正在拉取云端进度..."))

    UIManager:scheduleIn(0.1, self:_guard(_("拉取云端进度"), function()
        if Context.get_generation() ~= gen then
            Log.debug("拉取云端进度: 阅读会话已变更，放弃")
            self:closeBusy()
            return
        end

        local book = Context.get_current_book()
        if not book then
            self:closeBusy()
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
                self_ref:closeBusy()
                if not ok then
                    Log.warn("拉取进度异步失败: " .. tostring(err))
                    self_ref:showInfo(T(_("拉取进度失败:\n%1"), err))
                    return
                end
                if not result or not result.ok then
                    self_ref:showInfo(T(_("拉取进度失败:\n%1"), result and result.err or err))
                    return
                end
                if not result.data then
                    self_ref:showInfo(_("云端没有该书的进度"))
                    return
                end
                self_ref:_handle_pulled_progress(book, result.data, gen)
            end,
            { timeout = 30 }
        )
    end))
end

--- 处理拉取到的云端进度：对比本地进度并提示用户（从 pull_cloud_progress 提取，便于复用）
--- @param silent boolean|nil  true 时非"云端超前"情况不显示提示（自动对比用）
function ReadingPlugin:_handle_pulled_progress(book, progress_data, gen, silent)
    if not book or not progress_data then return end
    if gen and Context.get_generation() ~= gen then
        Log.debug("_handle_pulled_progress: 阅读会话已变更，放弃")
        return
    end

    local remote_record = {
        durChapterIndex = progress_data.durChapterIndex or 0,
        durChapterPos = progress_data.durChapterPos or 0,
        durChapterTitle = progress_data.durChapterTitle or "",
        durChapterTime = progress_data.durChapterTime or 0,
    }

    -- 刷新本地进度，同时取出 EPUB TOC 1-based 索引用于标题对齐对比
    local _, local_epub_idx = self:_refresh_current_progress()
    local local_chapter_index = book.durChapterIndex or 0   -- Legado 0-based，用于展示
    local local_chapter_pos = book.durChapterPos or 0

    Log.debug("本地进度: 第" .. (local_chapter_index + 1) .. "章(0based=" .. local_chapter_index ..
             ", EPUB=" .. tostring(local_epub_idx) .. "), 位置: " .. local_chapter_pos)
    Log.debug("云端进度: 第" .. ((remote_record.durChapterIndex or 0) + 1) ..
             "章(0based=" .. (remote_record.durChapterIndex or 0) .. "), 位置: " .. remote_record.durChapterPos ..
             ", 标题: " .. (remote_record.durChapterTitle or ""))

    -- 对比走标题对齐：优先用云端 durChapterTitle 在本地 EPUB TOC 匹配，
    -- 反推偏移量并持久化，供后续上传/跳转链路复用
    local compare_result, derived_offset = self:_compare_progress_by_title(book, local_epub_idx, remote_record)

    -- 持久化校准出的偏移量，并同步更新内存缓存
    if derived_offset then
        if book.bookUrl and book.bookUrl ~= "" then
            self.bookshelf:save_toc_offset(book.bookUrl, derived_offset, remote_record.durChapterTitle or "")
        end
        book.toc_offset = derived_offset
    end

    if compare_result == "remote_ahead" then
        local ButtonDialog = require("ui/widget/buttondialog")

        local info_text = T(_("云端进度更靠前") .. "\n\n" ..
            _("本地进度: 第%1章 %2") .. "\n" ..
            _("云端进度: 第%3章 %4"),
            local_chapter_index + 1,
            book.durChapterTitle or "",
            (remote_record.durChapterIndex or 0) + 1,
            remote_record.durChapterTitle or ""
        )

        local self_ref = self
        local dialog = ButtonDialog:new{
            title = _("进度同步"),
            info_text = info_text,
            buttons = {
                {
                    {
                        text = _("跳转到云端进度"),
                        callback = function()
                            UIManager:close(dialog)
                            self_ref:_jump_to_cloud_progress(remote_record)
                        end,
                    },
                    {
                        text = _("保持本地进度"),
                        callback = function()
                            UIManager:close(dialog)
                            self_ref:showInfo(_("保持本地进度"))
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
    elseif compare_result == "same" then
        if not silent then
            self:showInfo(_("进度一致，无需跳转"))
        end
    else
        if not silent then
            self:showInfo(T(_("本地进度超前，云端进度: 第%1章 %2"),
                (remote_record.durChapterIndex or 0) + 1,
                remote_record.durChapterTitle or ""))
        end
    end
end

function ReadingPlugin:_compare_progress(local_chapter, local_pos, remote_chapter, remote_pos)
    local_chapter = local_chapter or 0
    local_pos = local_pos or 0
    remote_chapter = remote_chapter or 0
    remote_pos = remote_pos or 0

    -- 章节不同时，直接以章节为准判断进度先后
    -- 注意：Legado durChapterIndex 是 0-based，数值越大表示越靠后
    if local_chapter > remote_chapter then
        return "local_ahead"
    elseif local_chapter < remote_chapter then
        return "remote_ahead"
    else
        -- 同章时：由于 Legado App 和 KOReader 的 durChapterPos 计算方式/单位可能不一致
        -- （Legado 可能用页码或不同比例，KOReader 用 0-1000 千分比），
        -- 直接数值比较会产生误判。同章视为进度一致，不触发跳转。
        -- 只有章节不同才有可靠的对齐基准（章节标题 + 索引）。
        return "same"
    end
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
-- @return derived_offset|nil     标题匹配命中时反推的偏移量（可为负数）；nil 表示未命中不持久化
function ReadingPlugin:_compare_progress_by_title(book, local_epub_idx, remote_record)
    if not book or not remote_record then return "same", nil end

    local doc_toc = Context.get_current_chapters() or {}
    local remote_title = remote_record.durChapterTitle or ""
    local remote_legado_idx = tonumber(remote_record.durChapterIndex) or 0
    local local_epub = tonumber(local_epub_idx) or 0

    -- 1. 优先：云端标题在本地 EPUB TOC 匹配
    if remote_title ~= "" and #doc_toc > 0 then
        local remote_epub_idx = self:_find_chapter_by_title(doc_toc, remote_title)
        if remote_epub_idx then
            -- 反推偏移量（允许负数）：offset = epub_1based - legado_0based
            -- 完整导出为正（前置条目数），部分导出为负（起始章节全书索引 - 前置数）
            local derived_offset = remote_epub_idx - remote_legado_idx

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
                     "' → offset=" .. derived_offset .. ") → " .. result)
            return result, derived_offset
        else
            Log.warn("标题对齐: 云端标题 '" .. remote_title .. "' 在本地 EPUB TOC 未匹配，回退数值对比")
        end
    end

    -- 2. 回退：用持久化偏移量把本地 EPUB 索引转 Legado，再数值对比
    local stored_offset = nil
    if book.bookUrl and book.bookUrl ~= "" then
        stored_offset = self.bookshelf:load_toc_offset(book.bookUrl)
    end
    local offset = stored_offset or book.toc_offset or 1
    local local_legado = local_epub - offset
    if local_legado < 0 then local_legado = 0 end

    local result
    if local_legado > remote_legado_idx then
        result = "local_ahead"
    elseif local_legado < remote_legado_idx then
        result = "remote_ahead"
    else
        result = "same"
    end

    Log.info("数值对比回退: 本地EPUB=" .. local_epub .. " - offset=" .. offset ..
             " = Legado=" .. local_legado ..
             ", 云端Legado=" .. remote_legado_idx .. " → " .. result ..
             (stored_offset and " (用持久化offset)" or " (用内存offset)"))
    return result, nil
end

function ReadingPlugin:_refresh_current_progress()
    local book = Context.get_current_book()
    if not book then return false, nil, nil, nil end
    if not self.ui or not self.ui.document then return false, nil, nil, nil end

    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return false, nil, nil, nil end

    local toc = doc:getToc()
    if not toc or #toc == 0 then
        local current_page = doc:getCurrentPage() or 1
        local progress_percent = current_page / total_pages
        book.durChapterPos = math.floor(progress_percent * 1000)
        return true, nil, nil, nil  -- 无 TOC，无法返回章节索引
    end

    local current_page = doc:getCurrentPage() or 1
    local chapter_index = #toc
    local chapter_pos = 1000

    local left, right = 1, #toc
    while left <= right do
        local mid = math.floor((left + right) / 2)
        local current_start = toc[mid].page or 1
        local next_start = (mid < #toc) and (toc[mid + 1].page or total_pages + 1) or (total_pages + 1)

        if current_page >= current_start and current_page < next_start then
            chapter_index = mid
            local chapter_pages = next_start - current_start
            if chapter_pages > 0 then
                chapter_pos = math.floor((current_page - current_start) / chapter_pages * 1000)
            else
                chapter_pos = 0
            end
            Context.set_chapter_range_cache({
                start_page = current_start,
                end_page = next_start,
                chapter_index = chapter_index,
                chapter_title = toc[chapter_index] and toc[chapter_index].title or "",
            })
            break
        elseif current_page < current_start then
            right = mid - 1
        else
            left = mid + 1
        end
    end

    -- 从 EPUB TOC 索引转换为 Legado 章节索引
    -- 注意：Legado durChapterIndex 是 0-based（Book.kt L97 默认 0，L166 lastChapterIndex=totalChapterNum-1）
    local toc_offset = self:_get_toc_offset(book, toc)
    local legado_index = chapter_index - toc_offset
    local legado_title = toc[chapter_index] and toc[chapter_index].title or ""

    -- 标题验证：用 EPUB TOC 当前章节标题在 Legado 章节列表中查找，
    -- 处理"作者有话说""紧急求助"等动态插入导致偏移量失效的情况
    local verified_index = self:_verify_legado_index_by_title(book, legado_title, legado_index)
    if verified_index then
        legado_index = verified_index
    elseif legado_index < 0 then
        -- 落在 TOC 前置条目（封面/内容简介），用 Legado 第1章（索引0）兜底
        legado_index = 0
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
    book.toc_offset = toc_offset

    Log.debug("强制刷新进度: TOC=" .. chapter_index .. " - offset=" .. toc_offset .. " = Legado=" .. legado_index .. "章, 位置=" .. chapter_pos)
    -- 多返回值：ok, epub_idx(1-based), legado_idx(0-based), chapter_title
    -- 旧调用点 `local ok = ...` 只取第一个返回值，兼容不变
    return true, chapter_index, legado_index, legado_title
end

--- 通过标题验证 Legado 章节索引是否正确
-- 处理"作者有话说""紧急求助"等动态插入导致固定偏移量失效的情况。
-- 用 EPUB TOC 当前章节标题在 Legado 章节列表中查找，如果找到且索引不一致，用匹配到的索引。
-- @param book table  当前书籍对象
-- @param title string EPUB TOC 当前章节标题
-- @param fallback_index number 偏移量计算的 Legado 索引（0-based）
-- @return number|nil  验证后的 Legado 索引（0-based），nil 表示无法验证（用 fallback）
function ReadingPlugin:_verify_legado_index_by_title(book, title, fallback_index)
    if not title or title == "" then return nil end

    -- 加载 Legado 原始章节列表
    local book_url = book.bookUrl or ""
    if book_url == "" then return nil end
    local legado_chapters = self.bookshelf:load_toc_cache(book_url)
    if not legado_chapters or #legado_chapters == 0 then return nil end

    -- 在 Legado 章节列表中查找标题匹配
    local matched_idx = self:_find_chapter_by_title(legado_chapters, title)
    if not matched_idx then return nil end

    -- matched_idx 是 Lua 1-based，转为 Legado 0-based
    local verified_legado = matched_idx - 1

    if verified_legado ~= fallback_index then
        Log.info("标题验证(EPUB→Legado): 偏移量计算=" .. fallback_index .. ", 标题匹配=" .. verified_legado ..
                 "（标题 '" .. title .. "' 可能因动态插入导致偏移失效，采用标题匹配结果）")
    end
    return verified_legado
end

--- 通过标题验证 EPUB TOC 索引是否正确（反向：Legado → EPUB）
-- 处理"作者有话说""紧急求助"等动态插入导致固定偏移量失效的情况。
-- 从 Legado 章节列表获取指定索引的标题，在 EPUB TOC 中查找对应位置。
-- @param book table  当前书籍对象
-- @param legado_index number Legado 0-based 章节索引
-- @param doc_toc table  EPUB TOC（1-based Lua 表）
-- @return number|nil  验证后的 EPUB TOC 索引（1-based），nil 表示无法验证（用 fallback）
function ReadingPlugin:_verify_epub_index_by_title(book, legado_index, doc_toc)
    if not doc_toc or #doc_toc == 0 then return nil end

    -- 加载 Legado 原始章节列表
    local book_url = book.bookUrl or ""
    if book_url == "" then return nil end
    local legado_chapters = self.bookshelf:load_toc_cache(book_url)
    if not legado_chapters or #legado_chapters == 0 then return nil end

    -- 获取 Legado 章节标题（legado_index 是 0-based，转 1-based 查表）
    local legado_1based = legado_index + 1
    if legado_1based < 1 or legado_1based > #legado_chapters then return nil end
    local legado_ch = legado_chapters[legado_1based]
    local title = legado_ch and (legado_ch.name or legado_ch.title) or ""
    if title == "" then return nil end

    -- 在 EPUB TOC 中查找标题匹配
    local matched_epub = self:_find_chapter_by_title(doc_toc, title)
    if not matched_epub then return nil end

    Log.debug("标题验证(Legado→EPUB): Legado " .. legado_index .. " '" .. title .. "' -> EPUB TOC " .. matched_epub)
    return matched_epub
end

--- 计算 EPUB TOC 与 Legado 章节列表的偏移量
-- 统一公式: epub_1based_index = legado_0based_index + toc_offset
--   - epub_1based_index: EPUB TOC 的 Lua 1-based 索引
--   - legado_0based_index: Legado durChapterIndex（0-based，Book.kt L97 默认 0）
--   - toc_offset: 本函数计算的偏移量
--
-- Legado 导出 EPUB 时固定在正文前插入 2 个前置条目：
--   1. "封面" (R.string.img_cover) / "Cover"
--   2. "内容简介" (R.string.book_intro) / "Book description"
-- 参考: legado/app/src/main/java/io/legado/app/service/ExportBookService.kt L483-506
-- 结果缓存到 book.toc_offset，避免重复计算。
function ReadingPlugin:_calc_toc_offset(book, doc_toc)
    if not book or not doc_toc or #doc_toc == 0 then
        return 1  -- 无前置时，epub_1based = legado_0based + 1
    end

    -- 1. 第一优先级：检测 Legado 导出 EPUB 的固定前置条目（封面 + 内容简介）
    --    参考: ExportBookService.kt L483-506, strings.xml L236/L269
    local legado_prefix_titles = {
        "封面", "Cover",
        "内容简介", "Book description",
        "简介", "Intro",
        "目录", "Contents", "Table of Contents",
    }
    local first_real_chapter_idx = nil
    for i = 1, math.min(5, #doc_toc) do
        local title = doc_toc[i] and doc_toc[i].title or ""
        local is_prefix = false
        for __, pat in ipairs(legado_prefix_titles) do
            if title == pat or title:find(pat, 1, true) then
                is_prefix = true
                break
            end
        end
        if not is_prefix then
            first_real_chapter_idx = i
            break
        end
    end
    if first_real_chapter_idx then
        -- EPUB TOC[first_real_chapter_idx] = Legado durChapterIndex=0（正文第1章）
        -- epub_1based = legado_0based + offset → offset = first_real_chapter_idx - 0 = first_real_chapter_idx
        local offset = first_real_chapter_idx
        Log.info("_calc_toc_offset: 检测到 Legado 前置条目，首章 TOC=" .. first_real_chapter_idx .. ", 偏移=" .. offset)
        return offset
    end

    -- 2. 第二优先级：用当前 book.durChapterTitle 在 EPUB TOC 中匹配
    local legado_chapters = nil
    local book_url = book.bookUrl or ""
    if book_url ~= "" then
        legado_chapters = self.bookshelf:load_toc_cache(book_url)
    end

    local probe_title = book.durChapterTitle or ""
    -- durChapterIndex 是 0-based，Legado 章节列表是 1-based（Lua），需要 +1
    if probe_title == "" and book.durChapterIndex and legado_chapters then
        local legado_idx = book.durChapterIndex + 1  -- 0-based 转 1-based
        if legado_idx >= 1 and legado_idx <= #legado_chapters then
            local legado_ch = legado_chapters[legado_idx]
            if legado_ch then
                probe_title = legado_ch.name or legado_ch.title or ""
            end
        end
    end

    if probe_title and probe_title ~= "" then
        local matched_idx = self:_find_chapter_by_title(doc_toc, probe_title)
        if matched_idx then
            -- matched_idx 是 Lua 1-based EPUB TOC 索引
            -- book.durChapterIndex 是 0-based Legado 索引
            -- epub_1based = legado_0based + offset → offset = matched_idx - legado_0based
            local legado_base = book.durChapterIndex or 0
            local offset = matched_idx - legado_base
            if offset < 1 then offset = 1 end
            Log.info("_calc_toc_offset: 标题 '" .. probe_title .. "' 匹配 TOC " .. matched_idx .. " = Legado " .. legado_base .. ", 偏移=" .. offset)
            return offset
        end
    end

    -- 3. 第三优先级：Legado 章节列表前3章 vs EPUB TOC
    if legado_chapters and #legado_chapters > 0 then
        local probe_count = math.min(3, #legado_chapters)
        for li = 1, probe_count do
            local legado_name = legado_chapters[li] and (legado_chapters[li].name or legado_chapters[li].title) or ""
            if legado_name ~= "" then
                local epub_idx = self:_find_chapter_by_title(doc_toc, legado_name)
                if epub_idx then
                    -- epub_idx 是 Lua 1-based，li 是 Lua 1-based（对应 Legado 0-based 的 li-1）
                    -- epub_1based = legado_0based + offset = (li - 1) + offset
                    -- offset = epub_idx - (li - 1) = epub_idx - li + 1
                    local offset = epub_idx - li + 1
                    if offset < 1 then offset = 1 end
                    Log.info("_calc_toc_offset: Legado 第" .. li .. "章 '" .. legado_name .. "' = TOC " .. epub_idx .. ", 偏移=" .. offset)
                    return offset
                end
            end
        end
    end

    -- 4. 第四优先级：默认偏移 3（Legado 导出 EPUB：封面 + 内容简介 + Lua 1-based 基准）
    Log.warn("_calc_toc_offset: 无法精确匹配，使用 Legado 默认偏移 3（封面+内容简介+1based）")
    return 3
end

--- 获取并缓存 TOC 偏移量（存在 book 对象上，同一次阅读会话复用）
-- 优先级：内存 book.toc_offset > 持久化偏移量（标题对齐校准过）> _calc_toc_offset 现算
-- 持久化偏移由 _handle_pulled_progress 通过标题对齐反推并写入，
-- 比关键词匹配/默认值更可靠，能修正"作者有话说/紧急求助"等动态插入导致的漂移
function ReadingPlugin:_get_toc_offset(book, doc_toc)
    if not book then return 1 end  -- 无 book 时最小偏移（Lua 1-based 基准）
    if book.toc_offset == nil then
        -- 优先复用持久化偏移（标题对齐校准过的更可靠）
        local stored = nil
        if book.bookUrl and book.bookUrl ~= "" then
            stored = self.bookshelf:load_toc_offset(book.bookUrl)
        end
        if stored then
            book.toc_offset = stored
            Log.debug("_get_toc_offset: 复用持久化偏移 " .. stored)
        else
            book.toc_offset = self:_calc_toc_offset(book, doc_toc)
        end
    end
    return book.toc_offset
end

--- 通过标题在章节列表中查找章节索引（解决 Legado 与 EPUB TOC 索引偏移问题）
-- Legado 章节列表与 EPUB TOC 可能因"目录""简介"等前置条目导致索引不一致，
-- 用标题匹配可精确定位，避免差 1~N 章的跳转偏差。
-- @param chapters table  章节列表（Context.get_current_chapters()）
-- @param title string    目标章节标题（来自云端 durChapterTitle）
-- @return number|nil     匹配到的索引，nil 表示未找到
function ReadingPlugin:_find_chapter_by_title(chapters, title)
    if not chapters or #chapters == 0 then return nil end
    if not title or title == "" then return nil end

    -- 兼容 EPUB TOC（title/norm_name 字段）和 Legado 章节列表（name/title 字段）
    local get_name = function(ch)
        return ch and (ch.name or ch.title) or ""
    end

    -- 1. 精确匹配
    for i, ch in ipairs(chapters) do
        if get_name(ch) == title then
            Log.debug("_find_chapter_by_title: 精确匹配: '" .. title .. "' -> 第" .. i .. "章")
            return i
        end
    end

    -- 2. 去空格匹配（标题可能因 EPUB/Legado 解析差异导致空格不同）
    local norm_title = title:gsub("%s+", "")
    if norm_title ~= "" then
        for i, ch in ipairs(chapters) do
            -- 如果有预处理好的 norm_name，直接使用，否则实时计算并缓存
            local ch_norm = ch.norm_name
            if not ch_norm then
                ch_norm = get_name(ch):gsub("%s+", "")
                ch.norm_name = ch_norm
            end
            
            if ch_norm == norm_title then
                Log.debug("_find_chapter_by_title: 去空格匹配: '" .. title .. "' -> 第" .. i .. "章 (" .. get_name(ch) .. ")")
                return i
            end
        end

        -- 3. 子串匹配（一方包含另一方，处理标题前后缀差异）
        for i, ch in ipairs(chapters) do
            local norm_ch = ch.norm_name
            if not norm_ch then
                norm_ch = get_name(ch):gsub("%s+", "")
                ch.norm_name = norm_ch
            end
            
            if norm_ch ~= "" and (norm_ch:find(norm_title, 1, true) or norm_title:find(norm_ch, 1, true)) then
                Log.debug("_find_chapter_by_title: 子串匹配: '" .. title .. "' -> 第" .. i .. "章 (" .. get_name(ch) .. ")")
                return i
            end
        end
    end

    Log.warn("_find_chapter_by_title: 未找到匹配章节: '" .. title .. "'")
    return nil
end

function ReadingPlugin:_jump_to_cloud_progress(remote_record)
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
            local jump_index = legado_index  -- 最终传给 read_chapter 的索引（Legado 基准）

            -- 优先用章节标题匹配，解决 Legado 与 EPUB TOC 索引偏移（目录/简介等前置条目）
            if chapter_title and chapter_title ~= "" then
                local matched_epub_idx = self:_find_chapter_by_title(Context.get_current_chapters(), chapter_title)
                if matched_epub_idx then
                    -- 标题匹配到的是 EPUB TOC 1-based 索引，反推 Legado 0-based 索引
                    -- legado_0based = epub_1based - toc_offset
                    local book = Context.get_current_book()
                    local offset = book and book.toc_offset or 1
                    jump_index = math.max(0, matched_epub_idx - offset)
                    Log.info("标题匹配: 云端第" .. legado_index .. "章 '" .. chapter_title .. "' -> EPUB TOC " .. matched_epub_idx .. " (offset=" .. offset .. ") -> Legado " .. jump_index)
                else
                    Log.warn("标题匹配失败，回退使用云端索引: 第" .. legado_index .. "章")
                end
            end

            if jump_index < 0 then
                jump_index = 0
            end
            local offset_for_max = (Context.get_current_book() and Context.get_current_book().toc_offset) or 1
            local max_legado = #Context.get_current_chapters() - offset_for_max
            if jump_index > max_legado then
                jump_index = max_legado
            end

            Log.info("跳转到云端进度: 第" .. jump_index .. "章, 位置: " .. chapter_pos)

            self:read_chapter(jump_index, chapter_pos)

            -- 跳转完成后显示成功消息
            local book = Context.get_current_book()
            local offset = book and book.toc_offset or 1
            local jumped_epub_idx = jump_index + offset
            if jumped_epub_idx < 1 then jumped_epub_idx = 1 end
            if jumped_epub_idx > #Context.get_current_chapters() then
                jumped_epub_idx = #Context.get_current_chapters()
            end
            local jumped_title = Context.get_current_chapters()[jumped_epub_idx].name or ""
            self:showInfo(T(_("已跳转到第 %1 章 %2"), jump_index + 1, jumped_title))
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

function ReadingPlugin:push_cloud_progress()
    if not Context.get_current_book() then
        self:showInfo(_("请先选择书籍"))
        return
    end

    self:_refresh_current_progress()

    local book = Context.get_current_book()
    local chapter_index = book.durChapterIndex or (Context.get_current_chapter_index() or 0)
    local chapter_pos = book.durChapterPos or 0
    local chapter_title = book.durChapterTitle or ""

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("确认覆盖云端进度？\n\n本地进度: 第%1章 %2"), chapter_index + 1, chapter_title),
        ok_text = _("确认覆盖"),
        cancel_text = _("取消"),
        callback = function()
            self:showBusy(_("正在上传进度..."))

            local gen = Context.get_generation()
            local sync_ref = self.sync
            local self_ref = self
            self:_async_run(
                function()
                    local ok, _, err = sync_ref:upload_book_progress(
                        book.name or book.title or "",
                        book.author or "",
                        chapter_index, chapter_pos, chapter_title
                    )
                    return { ok = ok, err = err }
                end,
                function(ok, result, err)
                    if Context.get_generation() ~= gen then
                        self_ref:closeBusy()
                        Log.debug("push_cloud_progress: 阅读会话已变更，放弃回调")
                        return
                    end
                    self_ref:closeBusy()
                    if ok and result and result.ok then
                        self_ref:showInfo(_("进度已上传到云端"))
                    else
                        self_ref:showInfo(T(_("上传失败: %1"), err or (result and result.err)))
                    end
                end,
                { timeout = 30 }
            )
        end,
    })
end

function ReadingPlugin:next_chapter()
    if not Context.get_current_chapters() or #Context.get_current_chapters() == 0 then
        self:showInfo(_("目录未加载"))
        return
    end

    local book = Context.get_current_book()
    if not book then return end
    -- book.durChapterIndex 是 Legado 0-based，+1 得到下一章
    local next_legado = (book.durChapterIndex or 0) + 1
    local toc_offset = book.toc_offset or 1
    -- 转换为 EPUB 1-based 检查边界
    local next_epub = next_legado + toc_offset
    if next_epub <= #Context.get_current_chapters() then
        self:read_chapter(next_legado)
    else
        self:showInfo(_("已经是最后一章"))
    end
end

function ReadingPlugin:prev_chapter()
    if not Context.get_current_chapters() or #Context.get_current_chapters() == 0 then
        self:showInfo(_("目录未加载"))
        return
    end

    local book = Context.get_current_book()
    if not book then return end
    -- book.durChapterIndex 是 Legado 0-based，-1 得到上一章
    local prev_legado = (book.durChapterIndex or 0) - 1
    if prev_legado >= 0 then
        self:read_chapter(prev_legado)
    else
        self:showInfo(_("已经是第一章"))
    end
end

function ReadingPlugin:sync_epub_files()
    local DownloadProgress = require("reading.download_progress")
    
    local progress = DownloadProgress:new{
        title = _("同步书籍"),
        on_cancel = function()
            self._download_cancelled = true
        end,
    }
    progress:show()
    
    UIManager:scheduleIn(0.1, self:_guard(_("批量下载书籍"), function()
        if progress:isCanceled() then
            progress:close()
            return
        end

        progress:setState{ stage = "prepare", message = _("正在获取书籍列表...") }

        local ok, epub_files, err = self.sync:list_books_directory()
        if not ok then
            progress:setState{ stage = "error", message = tostring(err) }
            UIManager:scheduleIn(2, function() progress:close() end)
            return
        end

        local total = #epub_files
        if total == 0 then
            progress:setState{ stage = "done", message = _("云端没有书籍") }
            UIManager:scheduleIn(2, function() progress:close() end)
            return
        end

        Log.info("云端找到 " .. total .. " 个EPUB文件")

        local books_dir = H.get_books_dir()
        H.make_dir(books_dir)

        local downloaded_count = 0
        local skipped_count = 0
        local failed_count = 0
        local current = 0

        local download_next
        download_next = self:_guard(_("下载下一本"), function()
            if progress:isCanceled() then
                progress:setState{ stage = "cancelled" }
                UIManager:scheduleIn(1, function() progress:close() end)
                return
            end

            current = current + 1
            if current > total then
                progress:setState{
                    stage = "done",
                    message = T(_("同步完成\n下载: %1\n已存在: %2\n失败: %3"), downloaded_count, skipped_count, failed_count)
                }
                UIManager:scheduleIn(2, function() progress:close() end)
                return
            end

            local epub = epub_files[current]
            progress:setState{
                stage = "content",
                file = epub.name,
                current = current,
                total = total,
                percent = current / total,
                message = _("正在下载...")
            }

            local save_path = H.join_path(books_dir, epub.name)

            if H.file_exists(save_path) then
                local local_size = H.get_file_size(save_path)
                local remote_size = epub.size
                if local_size and remote_size and local_size == remote_size then
                    skipped_count = skipped_count + 1
                    Log.debug("文件已存在且大小一致，跳过: " .. epub.name)
                    UIManager:scheduleIn(0.1, download_next)
                    return
                else
                    Log.info("文件大小不一致，重新下载: " .. epub.name ..
                        " (本地: " .. tostring(local_size) ..
                        ", 云端: " .. tostring(remote_size) .. ")")
                end
            end

            -- download_epub 返回 (ok, save_path, err)：失败时 err 在第三返回值
            local ok2, __, err = self.sync:download_epub(epub.path, save_path)
            if ok2 then
                downloaded_count = downloaded_count + 1
                Log.info("下载成功: " .. epub.name)
            else
                failed_count = failed_count + 1
                Log.error("下载失败: " .. epub.name .. ", 错误: " .. tostring(err))
            end

            UIManager:scheduleIn(0.1, download_next)
        end)

        self.bookshelf:invalidate_epub_cache()
        download_next()
    end))
end

function ReadingPlugin:view_log()
    local content, err = Log.read_log_content(5000)
    if content then
        UIManager:show(InfoMessage:new{
            text = content,
            timeout = 0,
        })
    else
        self:showInfo(T(_("查看日志失败: %1"), err))
    end
end

function ReadingPlugin:onClose()
    -- 清理所有未完成的异步任务，防止插件关闭后回调仍被触发
    self:_cancel_async()
    
    -- 一次性关闭所有 UI 句柄（含 menu、detail_dialog、active_menu、busy_msg、chapter_list_menu）
    -- 修复原 _state 中 current_chapter_list_menu 在 onClose 未被清理的泄漏 bug
    UIHandles.close_all()
end

function ReadingPlugin:onCloseWidget()
    self:onClose()
end

function ReadingPlugin:onCloseDocument()
    if not self.ui or not self.ui.document then return end

    -- 以“正在关闭的文档”自身路径为准判断，不依赖可能已被切书覆盖的 Context
    local closing_doc_path = self.ui.document.file or self.ui.document.path or ""
    if closing_doc_path == "" then return end

    local books_dir = H.get_books_dir()
    -- 只处理 reading 插件目录下的书籍
    if closing_doc_path:lower():sub(1, books_dir:lower():len()) ~= books_dir:lower() then
        return
    end

    -- 清理章节变化追踪状态（定时器机制已移除，改为章节变化触发上传）
    self._last_synced_chapter = nil

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

    -- 更新阅读记录并刷新进度，然后通过 Context.snapshot_progress() 捕获快照（含 generation 令牌）
    local book = Context.get_current_book()
    if book then
        book.lastCheckTime = os.time()
        self.read_record:update_record(
            book.bookUrl,
            book.name or book.title or "",
            0,
            os.time() * 1000
        )
        self:_refresh_current_progress()
        -- 持久化 lastCheckTime 到书架缓存，确保书架排序能反映最近阅读时间
        self.bookshelf:save_bookshelf_cache(self.bookshelf:get_books())
    end

    -- 使用快照数据上传，不依赖 Context 全局状态（清理后仍可安全上传）
    local snapshot = Context.snapshot_progress()
    if snapshot then
        local gen = snapshot.generation
        UIManager:scheduleIn(0.1, self:_guard(_("关闭文档保存进度"), function()
            -- 令牌校验：若关闭后又打开了新书籍，放弃旧快照上传
            if Context.get_generation() ~= gen then
                Log.debug("关闭文档上传: 阅读会话已变更，放弃旧快照")
                return
            end
            local ok, __, err = self.sync:upload_book_progress(
                snapshot.name,
                snapshot.author,
                snapshot.durChapterIndex,
                snapshot.durChapterPos,
                snapshot.durChapterTitle
            )
            if ok then
                Log.info("关闭文档时自动上传进度成功: " .. snapshot.name)
            else
                Log.warn("关闭文档时自动上传进度失败: " .. snapshot.name .. ", " .. tostring(err))
            end
        end))
    end

    -- 统一清理阅读上下文（generation 不重置，旧异步回调仍能识别过期）
    Context.clear_reading_context()
end

function ReadingPlugin:onPageUpdate(pageno)
    if not Context.get_current_epub_path() then return end

    if not self.ui or not self.ui.document then return end

    local book = Context.get_current_book()
    if not book then return end

    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return end

    local toc = doc:getToc()
    if toc and #toc > 0 then
        local cache = Context.get_chapter_range_cache()
        -- 获取 TOC 偏移量（EPUB 前置条目导致的偏差，用于 Legado <-> EPUB 索引互转）
        local toc_offset = self:_get_toc_offset(book, toc)

        -- 快速路径：页码在缓存的章节范围内，O(1) 计算位置
        if cache and pageno >= cache.start_page and pageno < cache.end_page then
            local chapter_pages = cache.end_page - cache.start_page
            local chapter_pos = 0
            if chapter_pages > 0 then
                chapter_pos = math.floor((pageno - cache.start_page) / chapter_pages * 1000)
            end
            -- EPUB TOC 索引减去偏移量得到 Legado 章节索引（0-based）
            local legado_index = cache.chapter_index - toc_offset
            if legado_index < 0 then legado_index = 0 end
            book.durChapterIndex = legado_index
            book.durChapterPos = chapter_pos
            book.durChapterTitle = cache.chapter_title
            book.toc_offset = toc_offset
        else
            -- 慢路径：跨章了，扫描 TOC 找到新章节
            local chapter_index = #toc
            local chapter_pos = 1000
            local chapter_title = ""

            local left, right = 1, #toc
            while left <= right do
                local mid = math.floor((left + right) / 2)
                local current_start = toc[mid].page or 1
                local next_start = (mid < #toc) and (toc[mid + 1].page or total_pages + 1) or (total_pages + 1)

                if pageno >= current_start and pageno < next_start then
                    chapter_index = mid
                    chapter_title = toc[mid] and toc[mid].title or ""
                    local chapter_pages = next_start - current_start
                    if chapter_pages > 0 then
                        chapter_pos = math.floor((pageno - current_start) / chapter_pages * 1000)
                    else
                        chapter_pos = 0
                    end

                    -- 更新缓存（存 EPUB 原生索引 + 原生标题）
                    Context.set_chapter_range_cache({
                        start_page = current_start,
                        end_page = next_start,
                        chapter_index = chapter_index,
                        chapter_title = chapter_title,
                    })
                    break
                elseif pageno < current_start then
                    right = mid - 1
                else
                    left = mid + 1
                end
            end

            -- EPUB TOC 索引减去偏移量得到 Legado 章节索引（0-based）
            local legado_index = chapter_index - toc_offset
            -- 标题验证：处理"作者有话说"等动态插入导致偏移量失效
            local verified_index = self:_verify_legado_index_by_title(book, chapter_title, legado_index)
            if verified_index then
                legado_index = verified_index
            elseif legado_index < 0 then
                legado_index = 0
            end
            book.durChapterIndex = legado_index
            book.durChapterPos = chapter_pos
            book.durChapterTitle = chapter_title
            book.toc_offset = toc_offset
            -- 跨章时更新 lastCheckTime 并持久化到书架缓存（确保书架排序反映最近阅读时间）
            book.lastCheckTime = os.time()
            self.bookshelf:save_bookshelf_cache(self.bookshelf:get_books())
        end
    else
        local progress_percent = pageno / total_pages
        book.durChapterPos = math.floor(progress_percent * 1000)
    end

    -- 章节变化时异步上传进度（替代原定时器机制）
    -- 仅在 durChapterIndex 发生变化且自动同步开启时触发，避免同章内重复上传
    local current_chapter = book.durChapterIndex
    if current_chapter ~= self._last_synced_chapter then
        self._last_synced_chapter = current_chapter
        if self.settings:is_progress_auto_sync_enabled() then
            Log.debug("章节变化触发异步上传: " .. tostring(self._last_synced_chapter) .. " -> " .. tostring(current_chapter))
            self:save_read_progress(current_chapter)
        end
    end
end

function ReadingPlugin:addToMainMenu(menu_items)
    menu_items.reading = {
        text = _("开源阅读"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function ReadingPlugin:getMainMenuItems()
    local items = {
        {
            text = _("书架"),
            callback = self:_guard(_("书架"), function()
                self:show()
            end),
        },
        {
            text = _("快捷同步"),
            callback = self:_guard(_("快捷同步"), function()
                self:sync_from_webdav_auto()
            end),
        },
    }
    
    if self:isCurrentDocReading() then
        table.insert(items, {
            text = _("阅读进度"),
            sub_item_table_func = function()
                return self:getReadingProgressMenuItems()
            end,
        })
    end
    
    table.insert(items, {
        text = _("设置"),
        sub_item_table_func = function()
            return self:getSettingsMenuItems()
        end,
    })
    
    table.insert(items, {
        text = _("调试日志"),
        sub_item_table_func = function()
            return self:getLogMenuItems()
        end,
    })
    
    table.insert(items, {
        text = _("关于"),
        callback = self:_guard(_("关于"), function()
            UIManager:show(InfoMessage:new{
                text = T(_("开源阅读插件 v%1\n\n在 KOReader 中阅读网络小说，支持书架同步、书源解析和阅读进度同步。"), self.version),
            })
        end),
    })
    
    return items
end

function ReadingPlugin:getReadingProgressMenuItems()
    local auto_sync_enabled = self.settings:is_progress_auto_sync_enabled()
    return {
        {
            text = auto_sync_enabled and _("自动同步: 开启") or _("自动同步: 关闭"),
            checked_func = function()
                return auto_sync_enabled
            end,
            callback = self:_guard(_("切换自动同步"), function()
                local new_val = not auto_sync_enabled
                self.settings:set_progress_auto_sync_enabled(new_val)
                if new_val then
                    self:showInfo(_("自动同步已开启（章节变化时上传）"))
                else
                    self:showInfo(_("自动同步已关闭"))
                end
            end),
        },
        {
            text = _("手动同步"),
            separator = true,
        },
        {
            text = _("拉取云端进度"),
            callback = self:_guard(_("拉取云端进度"), function()
                self:pull_cloud_progress()
            end),
        },
        {
            text = _("覆盖云端进度"),
            callback = self:_guard(_("覆盖云端进度"), function()
                self:push_cloud_progress()
            end),
        },
        {
            text = _("显示目录"),
            callback = self:_guard(_("显示目录"), function()
                self:show_chapter_list()
            end),
        },
        {
            text = _("刷新目录"),
            callback = self:_guard(_("刷新目录"), function()
                self:refresh_toc()
            end),
        },
    }
end

return ReadingPlugin
