local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local H = require("reading.helper")
local Log = require("reading.log")

local function status_text(book)
    local dur_chapter_index = tonumber(book.durChapterIndex or 0) or 0
    local total_chapters = tonumber(book.totalChapterNum or 0) or 0
    if total_chapters > 0 then
        if dur_chapter_index >= total_chapters then
            return _("已读完")
        else
            return string.format(_("%d/%d章"), dur_chapter_index, total_chapters)
        end
    end
    return _("未开始")
end

local ShelfItem = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function ShelfItem:init()
    self.ges_events = {
        TapSelect = {GestureRange:new{ges="tap", range=self.dimen}},
        HoldSelect = {GestureRange:new{ges="hold", range=self.dimen}},
    }

    local h = self.dimen.h
    local side = math.max(Size.padding.small, Screen:scaleBySize(4))
    local text_w = math.max(Screen:scaleBySize(120), self.dimen.w - side * 2)
    local title = TextBoxWidget:new{
        text = tostring(self.entry.title or _("未命名")),
        face = Font:getFace("cfont", math.min(22, Screen:scaleBySize(18))),
        width = text_w,
        height = math.floor(h * .52),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        bold = true,
    }

    local details = tostring(self.entry.author or "")
    if details ~= "" and tostring(self.entry.status or "") ~= "" then details = details .. " · " end
    details = details .. tostring(self.entry.status or "")
    local info = TextBoxWidget:new{
        text = details,
        face = Font:getFace("smallinfofont", math.min(17, Screen:scaleBySize(14))),
        width = text_w,
        height = math.floor(h * .30),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{height = math.max(1, Screen:scaleBySize(2))},
        info,
    }
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{width = side},
        LeftContainer:new{dimen=Geom:new{w=text_w, h=h}, text_group},
        HorizontalSpan:new{width = side},
    }

    self._underline = UnderlineContainer:new{
        dimen = self.dimen:copy(),
        linesize = Size.line.thin,
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        vertical_align = "center",
        row,
    }
    self[1] = self._underline
end

function ShelfItem:onTapSelect(arg, ges)
    local pos
    local dimen = self[1] and self[1].dimen
    if dimen and ges and ges.pos then
        pos = {
            x=(ges.pos.x - dimen.x) / math.max(1, dimen.w),
            y=(ges.pos.y - dimen.y) / math.max(1, dimen.h),
        }
    end
    self.menu:onMenuSelect(self.entry, pos)
    return true
end

function ShelfItem:onHoldSelect()
    if self.entry and self.entry.hold_callback then self.entry.hold_callback() end
    return true
end

function ShelfItem:onFocus()
    self._underline.color = Blitbuffer.COLOR_BLACK
    return true
end

function ShelfItem:onUnfocus()
    self._underline.color = Blitbuffer.COLOR_DARK_GRAY
    return true
end

local ShelfMenu = Menu:extend{
    on_page_changed = nil,
    on_close_callback = nil,
    _reading_closed = false,
    _suppress_page_callback = false,
}

function ShelfMenu:onMenuSelect(entry, pos)
    return Menu.onMenuSelect(self, entry)
end

function ShelfMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    Menu._recalculateDimen(self, no_recalculate_dimen)
    local offset = (self.page - 1) * self.perpage
    for index_on_page = 1, self.perpage do
        local index = offset + index_on_page
        local entry = self.item_table[index]
        if not entry then break end
        entry.idx = index
        if index == self.itemnumber then select_number = index_on_page end
        local item = ShelfItem:new{
            entry = entry,
            menu = self,
            dimen = self.item_dimen:copy(),
        }
        table.insert(self.item_group, item)
        table.insert(self.layout, {item})
    end
    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()
    UIManager:setDirty(self.show_parent, function()
        return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
    end)
    if not self._suppress_page_callback and not self._reading_closed and self.on_page_changed then
        local page = tonumber(self.page) or 1
        local first = (page - 1) * self.perpage + 1
        local last = math.min(#self.item_table, first + self.perpage - 1)
        UIManager:scheduleIn(0, function()
            if not self._reading_closed and self.on_page_changed then
                pcall(self.on_page_changed, page, first, last, self)
            end
        end)
    end
end

function ShelfMenu:onCloseWidget()
    self._reading_closed = true
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback, self)
    end
    if Menu.onCloseWidget then return Menu.onCloseWidget(self) end
end

local ShelfView = {}

function ShelfView.show(opts)
    opts = opts or {}
    local books = opts.books or {}

    Log.info("ShelfView.show 收到 " .. #books .. " 本书")
    
    local items = {}
    for _, book in ipairs(books) do
        local cover_path = book.cover_path
        if not cover_path and book.customCoverUrl then
            local covers_dir = H.get_covers_dir()
            H.make_dir(covers_dir)
            local filename = string.gsub(book.name or book.title or "unknown", "[/\\:%*%?\"<>|]", "_") .. ".jpg"
            local path = H.join_path(covers_dir, filename)
            if H.file_exists(path) then
                cover_path = path
            end
        end
        
        items[#items + 1] = {
            book_url = book.bookUrl,
            title = book.name or book.title or "未知标题",
            author = book.author or "",
            status = status_text(book),
            cover_path = cover_path,
            cover_url = book.customCoverUrl or book.coverUrl,
            show_cover = opts.show_covers ~= false,
            callback = function() if opts.on_select then opts.on_select(book) end end,
            hold_callback = function() if opts.on_hold then opts.on_hold(book) end end,
        }
    end

    Log.info("ShelfView.show 构建书籍 items: " .. #items .. " 个")

    local page_callback
    if opts.on_page_changed then
        page_callback = function(page, first, last, current)
            opts.on_page_changed(page, first, last, current)
        end
    end
    
    table.insert(items, {
        text = "--",
        separator = true,
    })
    
    table.insert(items, {
        text = "同步数据",
        callback = function()
            if opts.on_sync then
                opts.on_sync()
            end
        end,
    })
    
    table.insert(items, {
        text = "同步书籍",
        callback = function()
            if opts.on_sync_books then
                opts.on_sync_books()
            end
        end,
    })
    
    local menu = ShelfMenu:new{
        title = opts.title or _("书架"),
        item_table = items,
        items_per_page = 7,
        is_borderless = true,
        title_bar_fm_style = true,
        on_close_callback = opts.on_close,
        on_page_changed = page_callback,
    }
    
    UIManager:show(menu)
    return menu
end

function ShelfView.show_webdav_file_list(webdav, on_select)
    local ok_gettext, gettext = pcall(require, "gettext")
    local _ = ok_gettext and gettext or function(text) return text end

    local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
    local ok_Menu, Menu = pcall(require, "ui/widget/menu")
    local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")
    local ok_U, UIHandles = pcall(require, "reading/ui_handles")

    Log.info("显示WebDAV文件列表")

    -- webdav:list 已保证 no-throw，返回 (ok, result, err) 三元组
    local ok, items, err = webdav:list("")
    if not ok then
        Log.error("WebDAV文件列表获取失败: " .. tostring(err))
        if ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = _("无法获取文件列表: ") .. tostring(err),
                timeout = 3,
            })
        end
        return
    end

    local files = items

    if not files or type(files) ~= "table" or #files == 0 then
        if ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = _("未找到备份文件"),
                timeout = 3,
            })
        end
        return
    end

    Log.info("列出目录: " .. #files .. " 个文件")

    local item_table = {}
    for _, file in ipairs(files) do
        if file.is_file then
            local size_str = file.size or 0
            if size_str > 1024 * 1024 then
                size_str = string.format("%.2f MB", size_str / (1024 * 1024))
            elseif size_str > 1024 then
                size_str = string.format("%.2f KB", size_str / 1024)
            else
                size_str = size_str .. " B"
            end

            local time_str = ""
            if file.mtime then
                local ts = tonumber(file.mtime)
                if ts then
                    time_str = os.date("%Y-%m-%d %H:%M", ts)
                end
            end

            local fname, furl = file.name, file.url
            table.insert(item_table, {
                text = file.name,
                sub_item = size_str .. " | " .. time_str,
                filename = fname,
                url = furl,
                mtime = file.mtime,
                callback = function()
                    -- 1. 先关闭文件列表对话框，防止残留在书架后面
                    if ok_U and UIHandles.get("webdav_file_list") then
                        UIManager:close(UIHandles.get("webdav_file_list"))
                        UIHandles.clear("webdav_file_list")
                    end
                    -- 2. 再执行同步回调
                    if on_select then
                        on_select(fname, furl)
                    end
                end,
            })
        end
    end

    table.sort(item_table, function(a, b)
        -- 优先按 mtime 降序排序（最新的在最前面）
        local mtime_a = tonumber(a.mtime) or 0
        local mtime_b = tonumber(b.mtime) or 0
        if mtime_a ~= mtime_b then
            return mtime_a > mtime_b
        end
        -- 如果没有 mtime，按文件名降序排序
        return (a.text or "") > (b.text or "")
    end)

    local menu = Menu:new{
        title = _("选择备份文件"),
        item_table = item_table,
        is_borderless = true,
        title_bar_fm_style = true,
    }

    -- 保存对话框引用到全局 UIHandles，确保能可靠关闭
    if ok_U then
        UIHandles.set("webdav_file_list", menu)
    end

    UIManager:show(menu)
end

function ShelfView.show_settings_dialog(settings, on_save)
    local ok_gettext, gettext = pcall(require, "gettext")
    local _ = ok_gettext and gettext or function(text) return text end
    
    local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
    local ok_Menu, Menu = pcall(require, "ui/widget/menu")
    
    local items = {
        {
            text = _("重新加载 config.lua"),
            callback = function()
                settings:reload_config()
                if ok_UIManager then
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = _("配置已重新加载"),
                        timeout = 2,
                    })
                end
            end,
        },
        {
            text = _("清理缓存"),
            callback = function()
                local covers_dir = H.get_covers_dir()
                H.delete_dir(covers_dir)
                if ok_UIManager then
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = _("缓存已清理"),
                        timeout = 2,
                    })
                end
            end,
        },
    }
    
    local menu = Menu:new{
        title = _("设置"),
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    }
    
    UIManager:show(menu)
end

return ShelfView