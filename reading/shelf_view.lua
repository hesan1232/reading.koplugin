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
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local Log = require("reading.log")
-- 注：原先这里还有 require("reading.helper")。封面链路移除后本文件不再用到 H，
-- 已删除该 require（未使用的模块级 local 会被 lua_upvalue_lint 报出来）。

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

function ShelfItem:onTapSelect()
    -- 【不要在这里算相对坐标】这里原先把点击的相对位置算成 pos 传给
    -- `menu:onMenuSelect(entry, pos)`，而那个 pos 从来没人用：
    -- ShelfMenu:onMenuSelect 直接把它丢掉，上游 `Menu:onMenuSelect(item)`
    -- 更是**只有一个参数**（koreader-master/frontend/ui/widget/menu.lua:1364）。
    -- 也就是说每次点击都白做一次除法 + 建表。（评审文档里「改回 pos 就没这段了」
    -- 的说法是错的 —— 上游没有 pos 这个参数，正确做法就是整段删掉。）
    self.menu:onMenuSelect(self.entry)
    return true
end

function ShelfItem:onHoldSelect()
    -- 目前没有任何调用方传 on_hold（见 ShelfView.show 的 opts 契约），所以长按现在
    -- 只是把事件吃掉（返回 true 阻止默认处理），不做别的事。
    -- 将来若要给书架条目加长按行为，在这里接即可。
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
    on_close_callback = nil,
    on_left_button_tap = nil,
    _reading_closed = false,
}

function ShelfMenu:onLeftButtonTap()
    if self.on_left_button_tap then
        self.on_left_button_tap(self)
    end
end

function ShelfMenu:onMenuSelect(entry)
    return Menu.onMenuSelect(self, entry)
end

--- ⚠️ 这是 `Menu:updateItems` 的**手工分叉副本**（有意保留，不是待清理的重复代码）。
--
-- 分叉动机：需要给每个条目挂自定义 widget（`ShelfItem`：标题粗体 + 灰色小字副标题 +
-- 下划线分隔 + 焦点变色），而上游 Menu 没有「自定义 item widget」的扩展点 ——
-- 它只提供 text / mandatory 两行的原生样式。
--
-- 已知漂移（上游有、这里没有）：is_enable_shortcut / item_shortcut 键盘快捷键、
-- item.dim / bold / mandatory 透传、items_max_lines，以及 updatePageInfo 里的
-- `self.itemnumber = nil -- focus only once`。
--
-- 反向的漂移也清理过一次：副本里曾额外加了「翻页后回调 on_page_changed」的整块逻辑
-- （含 `_suppress_page_callback` 开关），但全仓库**没有任何调用方**传 on_page_changed
-- （ShelfView.show 的调用点都没传），已删除 —— 让这个副本尽量贴着上游，是为了将来
-- 有机会时能一眼看出差异。
--
-- 保留的理由：本插件跑在 Kindle 这类触摸设备上，快捷键与 DPad 焦点基本用不到，
-- 而条目外观是当前唯一可用的视觉。将来若上游 Menu 开放了自定义 item 的扩展点，
-- 或者需要键盘导航，应改回上游实现而不是继续加东西到这里。
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

--- 显示书架。
---
--- **opts 契约**（传参式接口没有编译期检查，写错键名只会静默失效 —— 所以列在这里）：
---   books                  table  要显示的书籍数组（必需）
---   title                  string 标题栏文案，默认「书架」
---   on_select(book)        fn     点击某本书
---   on_left_button_tap(menu) fn   左上角菜单按钮
---   on_close(menu)         fn     关闭书架
--- 任何不在此列表中的键都不会被读取。新增键时请同步更新此处与调用方。
---
--- 注：`show_covers` 已删除 —— 它读进 opts 之后没有任何消费方（封面渲染从未实现，
--- 且封面文件没有下载来源），留着只会让人以为「传 false 能关掉封面」。
--- 同理 `on_hold(book)` / `on_page_changed(...)` 也已删除：它们同样没有任何调用方，
--- 长按与翻页回调在书架、章节列表两条链路上都是空操作。
function ShelfView.show(opts)
    opts = opts or {}
    local books = opts.books or {}

    Log.info("ShelfView.show 收到 " .. #books .. " 本书")
    
    local items = {}
    for __, book in ipairs(books) do
        -- 【封面链路已移除，不要再凭印象加回来】
        -- 这里曾为每本书算出 cover_path / cover_url / show_cover 三个字段，但
        -- `ShelfItem:init` 一行都没引用它们；更要命的是这三个字段**没有任何赋值来源**——
        -- book.cover_path / customCoverUrl / coverUrl 全仓库无人写入，
        -- H.get_covers_dir() 下的 *.jpg 也没有任何下载逻辑。
        -- 于是每次打开书架都白付一次 lfs.attributes（首次还多一次 make_dir），
        -- 换来的封面永远不会出现。这属于「声明了但没有数据源」的死链路
        -- （与本插件那条没有源头的 save_toc_cache 同类）。
        -- 将来要做封面，必须把「下载 → 缓存 → 渲染」作为一个完整功能一起加，
        -- 只补渲染是没用的（无图可渲染）。

        local title_text = book.name or book.title or "未知标题"
        -- 移除 original_filename 的显示，保持书架界面整洁
        -- original_filename 仅作为内部映射字段使用

        items[#items + 1] = {
            book_url = book.bookUrl,
            title = title_text,
            author = book.author or "",
            status = status_text(book),
            callback = function() if opts.on_select then opts.on_select(book) end end,
        }
    end

    Log.info("ShelfView.show 构建书籍 items: " .. #items .. " 个")

    local menu = ShelfMenu:new{
        title = opts.title or _("书架"),
        title_bar_left_icon = "appbar.menu",
        item_table = items,
        -- 书架条目是**双行布局**（粗体标题 + 作者/进度小字副标题，见 ShelfItem:init），
        -- 一条的纵向空间需求约为上游单行条目的两倍。全局「每页条目数」是为单行菜单
        -- 设计的（默认 14）：直接沿用（1.3 修复后的行为）会把每条压得太矮，
        -- 副标题被省略号截断（真机反馈「文字都没展示全」）。
        -- 这里按「全局值的一半」换算（下限 5），仍然跟随用户的 KOReader 设置偏好：
        -- 全局 14 → 书架 7；用户调大调小都按比例生效。
        -- 章节列表（show_chapter_list）是单行条目，**不**做这个换算，继续听全局设置。
        items_per_page = math.max(5, math.floor(
            (G_reader_settings:readSetting("items_per_page") or 14) / 2)),
        -- 【不要把每页条目数写死】Menu:_recalculateDimen 的取值顺序是
        --   self.items_per_page or G_reader_settings:readSetting("items_per_page") or 14
        -- 硬编码一个固定数字会**跳过用户在 KOReader 全局设置里调过的「每页条目数」**
        -- （此处曾硬编码 items_per_page = 7），也跳过 items_per_page_default ——
        -- 于是同一份代码在不同 DPI 的设备上空余/拥挤程度不一致。
        is_borderless = true,
        title_bar_fm_style = true,
        on_close_callback = opts.on_close,
        on_left_button_tap = opts.on_left_button_tap,
    }
    
    UIManager:show(menu)
    return menu
end

function ShelfView.show_webdav_file_list(files, on_select)
    local ok_gettext, gettext = pcall(require, "gettext")
    local _ = ok_gettext and gettext or function(text) return text end

    local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
    local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")
    local ok_U, UIHandles = pcall(require, "reading/ui_handles")

    Log.info("显示WebDAV文件列表")

    -- files 由调用方异步预获取，避免 UI 线程同步阻塞
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
    for __, file in ipairs(files) do
        if file.is_file then
            local size_num = tonumber(file.size) or 0
            local size_str
            if size_num > 1024 * 1024 then
                size_str = string.format("%.2f MB", size_num / (1024 * 1024))
            elseif size_num > 1024 then
                size_str = string.format("%.2f KB", size_num / 1024)
            else
                size_str = size_num .. " B"
            end

            local time_str = ""
            if file.mtime then
                local ts = tonumber(file.mtime)
                if ts then
                    time_str = os.date("%Y-%m-%d %H:%M", ts)
                end
            end

            local fname, furl = file.name, file.url
            -- 同 show_cloud_library_list：sub_item 上游不渲染，双行信息走 ShelfItem
            table.insert(item_table, {
                title = file.name,
                author = size_str,
                status = time_str,
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
        return (a.title or "") > (b.title or "")
    end)

    local menu = ShelfMenu:new{
        title = _("选择备份文件"),
        item_table = item_table,
        -- 双行条目（同书架）：按全局「每页条目数」的一半换算
        items_per_page = math.max(5, math.floor(
            (G_reader_settings:readSetting("items_per_page") or 14) / 2)),
        is_borderless = true,
        title_bar_fm_style = true,
    }

    -- 保存对话框引用到全局 UIHandles，确保能可靠关闭
    if ok_U then
        UIHandles.set("webdav_file_list", menu)
    end

    UIManager:show(menu)
end

function ShelfView.show_cloud_library_list(files, on_select, custom_title)
    local ok_gettext, gettext = pcall(require, "gettext")
    local _ = ok_gettext and gettext or function(text) return text end
    local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
    local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")
    local ok_U, UIHandles = pcall(require, "reading/ui_handles")

    if not files or type(files) ~= "table" or #files == 0 then
        if ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = _("云端未找到书籍文件"),
                timeout = 3,
            })
        end
        return
    end

    -- ===== 视图状态（函数局部闭包，每次从菜单打开云端书库都重置为默认）=====
    local sort_key = "mtime"   -- "mtime" 按修改时间 | "name" 按文件名
    local sort_asc = false     -- false 倒序（默认，最新在前）| true 正序
    local filter_text = ""

    -- 【为什么用 ShelfMenu 而不是原生 Menu】此前列表项把大小/时间写进 `sub_item`，
    -- 但上游 `MenuItem` 根本不渲染这个字段（全 frontend 无任何消费方，menu.lua 只读
    -- text / mandatory / bold / dim / state / indent）——于是用户只看到文件名。
    -- （这与进度弹窗 `info_text` 是同一类 bug：传了不存在的字段，静默丢弃。）
    -- ShelfMenu + ShelfItem 是本模块现成的双行条目（粗体标题 + 灰色小字副标题），
    -- 副标题由 entry.author 与 entry.status 用 " · " 拼成，正好放「大小 · 修改时间」。
    local function build_item_table()
        local item_table = {}
        local lf = string.lower(filter_text)
        for __, file in ipairs(files) do
            local name = file.name or ""
            -- plain find（第 4 参 true）：关键字按字面匹配，文件名里的 . ( ) 等不是 pattern
            if lf == "" or string.find(string.lower(name), lf, 1, true) then
                local size_num = tonumber(file.size) or 0
                local size_str
                if size_num > 1024 * 1024 then
                    size_str = string.format("%.2f MB", size_num / (1024 * 1024))
                elseif size_num > 1024 then
                    size_str = string.format("%.2f KB", size_num / 1024)
                else
                    size_str = size_num .. " B"
                end

                local time_str = ""
                local mtime = tonumber(file.mtime) or 0
                if mtime > 0 then
                    time_str = os.date("%Y-%m-%d %H:%M", mtime)
                end

                item_table[#item_table + 1] = {
                    title = name,
                    author = size_str,
                    status = time_str,
                    mtime = mtime,
                    callback = function()
                        if ok_U and UIHandles.get("cloud_library_list") then
                            UIManager:close(UIHandles.get("cloud_library_list"))
                            UIHandles.clear("cloud_library_list")
                        end
                        if on_select then
                            on_select(file)
                        end
                    end,
                }
            end
        end

        table.sort(item_table, function(a, b)
            local a_v, b_v
            if sort_key == "name" then
                a_v, b_v = string.lower(a.title or ""), string.lower(b.title or "")
            else
                a_v, b_v = a.mtime, b.mtime
            end
            if a_v ~= b_v then
                if sort_asc then
                    return a_v < b_v
                end
                return a_v > b_v
            end
            -- 主键相同时按文件名稳定排序（方向跟随主排序）
            if sort_asc then
                return (a.title or "") < (b.title or "")
            end
            return (a.title or "") > (b.title or "")
        end)
        return item_table
    end

    -- 前向声明：refresh（渲染列表）与 show_list_menu（左上角菜单）互相引用
    -- —— 没有这一行，refresh 里的 show_list_menu() 会解析成全局查找（运行期 nil）。
    local show_list_menu

    local function refresh()
        local item_table = build_item_table()
        if #item_table == 0 then
            -- 筛选把所有文件都滤掉了：提示并保留旧列表，用户还能再开菜单改筛选
            if ok_InfoMessage then
                UIManager:show(InfoMessage:new{
                    text = _("没有匹配的文件"),
                    timeout = 3,
                })
            end
            return
        end
        if ok_U and UIHandles.get("cloud_library_list") then
            UIManager:close(UIHandles.get("cloud_library_list"))
            UIHandles.clear("cloud_library_list")
        end
        local title = custom_title or _("云端书库")
        if filter_text ~= "" then
            title = title .. " [" .. filter_text .. "]"
        end
        local menu = ShelfMenu:new{
            title = title,
            title_bar_left_icon = "appbar.menu",
            item_table = item_table,
            -- 双行条目（同书架）：按全局「每页条目数」的一半换算，避免副标题被压矮截断。
            -- 章节列表是单行条目，不在此列。
            items_per_page = math.max(5, math.floor(
                (G_reader_settings:readSetting("items_per_page") or 14) / 2)),
            is_borderless = true,
            title_bar_fm_style = true,
            on_left_button_tap = function()
                show_list_menu()
            end,
        }
        if ok_U then
            UIHandles.set("cloud_library_list", menu)
        end
        UIManager:show(menu)
    end

    function show_list_menu()
        local ok_ButtonDialog, ButtonDialog = pcall(require, "ui/widget/buttondialog")
        if not ok_ButtonDialog then return end

        local function close_dlg()
            if ok_U and UIHandles.get("cloud_list_menu") then
                UIManager:close(UIHandles.get("cloud_list_menu"))
                UIHandles.clear("cloud_list_menu")
            end
        end

        -- 排序合并为一键一项：点一下切换到该键（用默认方向），已是当前键时再点
        -- 一下翻转方向。避免正/倒序四个独立菜单项把菜单撑长（书架菜单同款精简）。
        local function toggle_sort(key)
            close_dlg()
            if sort_key == key then
                sort_asc = not sort_asc
            else
                sort_key = key
                sort_asc = (key == "name")  -- 书名默认正序，时间默认倒序（最新在前）
            end
            refresh()
        end

        -- 未生效的键显示它的默认方向；已生效的键显示实际方向 + ✓
        local function sort_btn_text(key, label)
            local asc = (sort_key == key) and sort_asc or (key == "name")
            return label .. "（" .. (asc and _("正序") or _("倒序")) .. "）"
                .. (sort_key == key and "  ✓" or "")
        end

        local function show_filter_dialog()
            close_dlg()
            local ok_InputDialog, InputDialog = pcall(require, "ui/widget/inputdialog")
            if not ok_InputDialog then return end
            local dlg
            dlg = InputDialog:new{
                title = _("筛选文件名"),
                input = filter_text,
                input_hint = _("输入关键字，留空清除筛选"),
                buttons = {
                    {
                        {
                            text = _("取消"),
                            callback = function()
                                UIManager:close(dlg)
                            end,
                        },
                    },
                    {
                        {
                            text = _("确定"),
                            is_enter_default = true,
                            callback = function()
                                local text = dlg:getInputText() or ""
                                filter_text = text:match("^%s*(.-)%s*$") or ""
                                UIManager:close(dlg)
                                refresh()
                            end,
                        },
                    },
                },
            }
            UIManager:show(dlg)
        end

        -- ✓ 标记当前生效的排序/筛选（与书架 show_sort_dialog 同款样式）
        local btns = {
            {
                {
                    text = sort_btn_text("mtime", _("按时间")),
                    callback = function() toggle_sort("mtime") end,
                }
            },
            {
                {
                    text = sort_btn_text("name", _("按书名")),
                    callback = function() toggle_sort("name") end,
                }
            },
            {
                {
                    text = (filter_text ~= "" and _("筛选") .. ": " .. filter_text or _("文字筛选")),
                    callback = show_filter_dialog,
                }
            },
            {
                {
                    text = _("取消"),
                    callback = close_dlg,
                }
            },
        }

        local dlg = ButtonDialog:new{
            title = _("菜单"),
            title_align = "center",
            align = "center",
            buttons = btns,
        }
        if ok_U then
            UIHandles.set("cloud_list_menu", dlg)
        end
        UIManager:show(dlg)
    end

    refresh()
end

--- 显示章节目录。
---
--- ⚠️ 这个函数曾经**不存在** —— `progress.lua` 从最早版本起就调用
--- `ShelfView.show_chapter_list(...)`，但本模块从未导出过它（备份里的
--- `main.lua:1683` 同样是这支调用），于是「查看目录」一执行就抛
--- `attempt to call a nil value (field 'show_chapter_list')`，章节列表功能完全不可用。
--- 这类错误语法检查/作用域检查/可达性分析**都看不见**（它们只判断「名字有没有绑定」，
--- 不判断「这个表里有没有这个字段」），所以要靠跨文件字段检查才能发现。
--- 现按与 show_webdav_file_list 相同的风格补回。
---
--- 契约（位置参数）：
---   chapters         table      章节数组；每项取 name/title 作为显示文本
---   current_index    number|nil 1-based 高亮/定位项（nil 则停在第一页）
---   on_select(index) fn         点击第 index 项（1-based）
---   on_refresh()     fn         标题栏左侧按钮回调（重新加载目录）
---   title            string|nil 标题栏文案
--- @return widget|nil 菜单实例
function ShelfView.show_chapter_list(chapters, current_index, on_select, on_refresh, title)
    if not chapters or type(chapters) ~= "table" or #chapters == 0 then
        Log.warn("show_chapter_list: 章节列表为空，不打开菜单")
        return nil
    end

    local ok_U, UIHandles = pcall(require, "reading/ui_handles")

    local item_table = {}
    for index, chapter in ipairs(chapters) do
        local name = chapter.name or chapter.title
        if not name or name == "" then
            name = string.format(_("第 %d 章"), index)
        end
        item_table[#item_table + 1] = {
            text = name,
            callback = function()
                -- 先关菜单再跳转：跳章会触发重新分页，菜单若还在 UI 栈上
                -- 会残留在新页面上（与 show_webdav_file_list 同样的处理顺序）。
                if ok_U and UIHandles.get("chapter_list_menu") then
                    UIManager:close(UIHandles.get("chapter_list_menu"))
                    UIHandles.clear("chapter_list_menu")
                end
                if on_select then
                    on_select(index)
                end
            end,
        }
    end

    local menu = ShelfMenu:new{
        title = title or _("目录"),
        title_bar_left_icon = "appbar.menu",
        item_table = item_table,
        is_borderless = true,
        title_bar_fm_style = true,
        itemnumber = current_index,   -- 打开时定位到当前章所在页
        on_left_button_tap = on_refresh and function() on_refresh() end or nil,
    }

    UIManager:show(menu)
    return menu
end

return ShelfView