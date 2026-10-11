--[[
    主菜单/WebDAV 菜单项注册与相关设置对话框。

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
local InputDialog = safe_require("ui/widget/inputdialog")
local H = require("reading.helper")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or function(str, ...) return str end
local ShelfView = safe_require("reading.shelf_view")
local Log = safe_require("reading.log")
local UIHandles = require("reading.ui_handles")

local M = {}

function M.getSettingsMenuItems(self)
    -- 直接展开 WebDAV 设置，去除多余的"同步文件链接"层级
    return self:getWebDAVMenuItems()
end

function M.getWebDAVMenuItems(self)
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
                    self:showInfo(_("config.lua 加载失败，请检查文件是否存在"), false)
                end
            end,
        },
        {
            text = _("界面设置（仅当前设备有效）"),
            separator = true,
        },
        {
            text = T(_("服务器: %1"), tostring(display_server)),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("server", server, _("请输入 WebDAV 服务器地址"))
            end,
        },
        {
            text = T(_("用户名: %1"), tostring(display_username)),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("username", username, _("请输入 WebDAV 用户名"))
            end,
        },
        {
            text = _("密码: ******"),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("password", password, _("请输入 WebDAV 密码"))
            end,
        },
        {
            text = T(_("远程路径: %1"), tostring(display_remote_path)),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_input_dialog("remote_path", remote_path, _("请输入远程路径"))
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
            -- 默认关闭。开启后 HTTPS 第一策略改用 verify="peer" 严格校验证书 ——
            -- 需要设备上有可用 CA 证书库，否则会**连原本能连的服务器也连不上**。
            text = _("校验证书（需 CA 证书库）"),
            keep_menu_open = true,
            checked_func = function()
                return self.settings:get_webdav_verify_cert()
            end,
            callback = function()
                local new_val = not self.settings:get_webdav_verify_cert()
                self.settings:set_webdav_verify_cert(new_val)
                if new_val then
                    self:showInfo(_("已开启证书校验：若设备没有 CA 证书库，HTTPS 会全部握手失败"))
                else
                    self:showInfo(_("已关闭证书校验（与 KOReader 自带 WebDAV 一致）"))
                end
            end,
        },
        {
            -- 安全降级开关，默认关闭：开启后 HTTPS 连不上时会把 https:// 换成
            -- http:// 重试一次，**明文传输 WebDAV 口令**。自建 WebDAV 只监听 HTTP
            -- 且无法启用 TLS 时才需要打开。
            text = _("允许降级 HTTP（明文，有风险）"),
            keep_menu_open = true,
            checked_func = function()
                return self.settings:get_webdav_allow_http_fallback()
            end,
            callback = function()
                local new_val = not self.settings:get_webdav_allow_http_fallback()
                self.settings:set_webdav_allow_http_fallback(new_val)
                if new_val then
                    self:showInfo(_("已开启：HTTPS 失败时会用明文 HTTP 重试，口令可能被窃听"), false)
                else
                    self:showInfo(_("已关闭明文回退"))
                end
            end,
        },
        {
            text = _("选择备份文件同步"),
            keep_menu_open = true,
            callback = function()
                self:show_webdav_file_list()
            end,
        },
        {
            -- stale-while-revalidate 的总开关。默认开：打开书架时先用本地缓存
            -- 秒开，缓存超过一定时长才在后台静默同步（见 _maybe_bg_revalidate_shelf）。
            -- 弱网 / 流量敏感的用户可以关掉，改用手动「快捷同步」。
            text = _("打开书架时自动刷新"),
            keep_menu_open = true,
            checked_func = function()
                return self.settings:is_shelf_auto_refresh_enabled()
            end,
            callback = function()
                local new_val = not self.settings:is_shelf_auto_refresh_enabled()
                self.settings:set_shelf_auto_refresh_enabled(new_val)
                if new_val then
                    self:showInfo(T(_("已开启：缓存超过 %1 小时会在后台自动刷新"),
                        tostring(self.settings:get_shelf_refresh_ttl_hours())))
                else
                    self:showInfo(_("已关闭后台自动刷新（仍可手动「快捷同步」）"))
                end
            end,
        },
    }
end

function M.getLogMenuItems(self)
    return {
        {
            text = _("查看日志文件"),
            callback = function()
                self:view_log()
            end,
        },
        {
            text = _("调试日志"),
            checked_func = function()
                return Log.is_debug_enabled()
            end,
            callback = function()
                local new_state = not Log.is_debug_enabled()
                Log.set_debug_enabled(new_state)
                -- 持久化到 advanced.developer_logs，否则重启后会被 init() 覆盖回默认值
                self.settings:set_developer_logs_enabled(new_state)
                self:showInfo(new_state and _("调试日志已开启") or _("调试日志已关闭"))
            end,
        },
        {
            text = _("清除日志"),
            callback = function()
                Log.clear_log()
                self:showInfo(_("日志已清除"))
            end,
        },
    }
end

function M.show_webdav_input_dialog(self, field, current_value, hint)
    Log.debug("打开WebDAV设置对话框: " .. field .. ", 当前值: " .. tostring(current_value))
    local dialog
    dialog = InputDialog:new{
        -- 不要把变量拼进 gettext 的 key（key 里带 "server"/"username" 之类永远不会命中翻译表）
        title = T(_("WebDAV %1"), tostring(field)),
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
                            timeout = 3,
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

function M.test_webdav_connection(self)
    -- 【身份比对】记下本次 busy 的句柄：收尾时只有槽位里还是它才关
    -- （否则关掉的是后来居上的别人的提示，见 downloader.closeBusy 的说明）
    local busy = self:showBusy(_("正在测试连接..."))
    local sync_ref = self.sync
    local self_ref = self
    self:_async_run(
        function()
            local ok, __, err = sync_ref:test_webdav_connection()
            return { ok = ok, err = err }
        end,
        function(ok, result, err)
            self_ref:closeBusy(busy)
            if ok and result and result.ok then
                self_ref:showInfo(_("WebDAV 连接成功"))
            else
                self_ref:showInfo(T(_("WebDAV 连接失败:\n%1"), tostring(err or (result and result.err) or "")), false)
            end
        end,
        { timeout = 30 }
    )
end

function M.sync_from_webdav_auto(self)
    Log.info("执行一键同步（从WebDAV自动拉取最新备份）")
    local busy = self:showBusy(_("正在同步..."))
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
            self_ref:closeBusy(busy)
            if not ok or not result or not result.ok then
                local err_msg = tostring(err or (result and result.err) or _("未知错误"))
                self_ref:showInfo(T(_("同步失败:\n%1"), err_msg), false)
                return
            end
            self_ref:_complete_sync(result.data)
        end,
        { timeout = 60 }
    )
end

function M.show_webdav_file_list(self)
    Log.info("显示WebDAV文件列表")
    local busy = self:showBusy(_("正在连接..."))

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
            self_ref:closeBusy(busy)
            if not ok or not result or not result.ok then
                local err_msg = tostring(err or (result and result.err) or _("未知错误"))
                self_ref:showInfo(T(_("WebDAV 连接失败:\n%1"), err_msg), false)
                return
            end
            ShelfView.show_webdav_file_list(result.items, function(filename, url)
                self_ref:perform_sync_from_file(filename, url)
            end)
        end,
        { timeout = 30 }
    )
end

function M.perform_sync_from_file(self, filename, url)
    -- 双重保险：确保文件列表对话框关闭（即使 callback 中关闭失败，这里也处理）
    if UIHandles.get("webdav_file_list") then
        UIManager:close(UIHandles.get("webdav_file_list"))
        UIHandles.clear("webdav_file_list")
    end
    Log.info("开始同步文件: " .. filename)
    local self_ref = self
    local sync_ref = self.sync
    local sync_dir = H.get_sync_dir()

    local busy = self:showBusy(_("正在下载与解析..."))
    self:_async_run(
        function()
            local ok, content = sync_ref.webdav:get_file(url)
            if not ok then
                return { ok = false, err = content }
            end

            if filename:match("%.zip$") then
                H.make_dir(sync_dir)
                local zip_path = H.join_path(sync_dir, "sync_backup.zip")
                -- 【必须检查 write / close 的返回值】磁盘满时 write 常常**不报错**、close 才暴露，
                -- 原先直接 `file:write(content); file:close()` 就会拿着半截 zip 去解压，
                -- 最终报「解压失败」把排查引偏。做法与 sync.lua 的 zip 分支
                -- （sync_from_webdav）保持一致：失败即清掉临时文件再返回。
                local file, io_err = io.open(zip_path, "wb")
                if not file then
                    Log.warn("无法创建临时 zip 文件: " .. tostring(io_err))
                    return { ok = false, err = T(_("无法保存文件:\n%1"), tostring(io_err)) }
                end
                local written, write_err = file:write(content)
                local close_ok, close_err = file:close()
                if not written or close_ok == nil then
                    os.remove(zip_path)
                    Log.warn("写入 zip 失败: " .. tostring(write_err or close_err))
                    return { ok = false, err = T(_("写入文件失败:\n%1"), tostring(write_err or close_err)) }
                end

                local ok2, extract_dir = sync_ref:extract_zip(zip_path)
                if not ok2 then
                    return { ok = false, err = T(_("解压失败:\n%1"), tostring(extract_dir)) }
                end
                sync_ref:load_from_extracted_dir(extract_dir)
            else
                local files = sync_ref:parse_backup(content)
                sync_ref:load_from_files(files)
            end

            return { ok = true, data = sync_ref:get_sync_data() }
        end,
        function(ok, result, err)
            self_ref:closeBusy(busy)
            if not ok or not result or not result.ok then
                local err_msg = tostring(err or (result and result.err) or _("未知错误"))
                self_ref:showInfo(T(_("同步失败:\n%1"), err_msg), false)
                return
            end
            self_ref:_complete_sync(result.data)
        end,
        { timeout = 60 }
    )
end

function M.show_sort_dialog(self, menu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local current_sort = self.settings:get_shelf_sort()
    local show_downloaded_only = self.settings:get_show_downloaded_only()
    
    local function close_dlg()
        if UIHandles.get("sort_dialog") then
            UIManager:close(UIHandles.get("sort_dialog"))
            UIHandles.clear("sort_dialog")
        end
    end

    -- 与云端书库同款交互：已是当前排序时再点一下翻转正/倒序。
    -- 方向持久化在 settings 的 shelf.sort_asc；切键时 set_shelf_sort 会清掉它恢复默认。
    local function toggle_sort(sort_key)
        if current_sort == sort_key then
            local asc = self.settings:get_shelf_sort_asc()
            if asc == nil then
                asc = (sort_key == "book_name") -- 各键的默认方向
            end
            self.settings:set_shelf_sort_asc(not asc)
        else
            self.settings:set_shelf_sort(sort_key)
        end
        self.bookshelf:sort_books(true)
        close_dlg()
        if menu_instance and not menu_instance._reading_closed then
            UIManager:close(menu_instance)
            self:show()
        end
    end

    -- 未生效的键显示默认方向；已生效的显示实际方向 + ✓
    local function sort_btn_text(sort_key, label)
        local asc = self.settings:get_shelf_sort_asc()
        if asc == nil then
            asc = (sort_key == "book_name")
        end
        return label .. "（" .. (asc and _("正序") or _("倒序")) .. "）"
            .. (current_sort == sort_key and "  ✓" or "")
    end

    local function toggle_downloaded_only()
        close_dlg()
        self.settings:set_show_downloaded_only(not show_downloaded_only)
        if menu_instance and not menu_instance._reading_closed then
            UIManager:close(menu_instance)
            self:show()
        end
    end

    local function show_cloud_library()
        close_dlg()
        self:show_cloud_library(menu_instance)
    end

    -- 书架搜索：关键字存 self._shelf_filter_text（会话级，见 main.lua init 的说明），
    -- 匹配书名或作者；输入留空 = 清除搜索。搜索生效时书架标题栏显示 [关键字]。
    local current_filter = self._shelf_filter_text or ""
    local function show_search_dialog()
        close_dlg()
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = _("搜索书架"),
            input = current_filter,
            input_hint = _("输入书名或作者，留空清除"),
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
                            self._shelf_filter_text = text:match("^%s*(.-)%s*$") or ""
                            if self._shelf_filter_text == "" then
                                self._shelf_filter_text = nil
                            end
                            UIManager:close(dlg)
                            -- 与 toggle_sort / toggle_downloaded_only 同款重渲染路径
                            if menu_instance and not menu_instance._reading_closed then
                                UIManager:close(menu_instance)
                                self:show()
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(dlg)
    end

    local btns = {}
    table.insert(btns, {
        {
            text = _("云端书库"),
            callback = show_cloud_library,
        }
    })
    table.insert(btns, {
        {
            text = current_filter ~= "" and _("搜索") .. ": " .. current_filter or _("搜索"),
            callback = show_search_dialog,
        }
    })
    table.insert(btns, {
        {
            text = _("仅显示已下载") .. (show_downloaded_only and "  ✓" or ""),
            callback = toggle_downloaded_only,
        }
    })
    table.insert(btns, {
        {
            text = sort_btn_text("last_read", _("按最后阅读")),
            callback = function() toggle_sort("last_read") end,
        }
    })
    table.insert(btns, {
        {
            text = sort_btn_text("latest_update", _("按更新时间")),
            callback = function() toggle_sort("latest_update") end,
        }
    })
    table.insert(btns, {
        {
            text = sort_btn_text("book_name", _("按书名")),
            callback = function() toggle_sort("book_name") end,
        }
    })
    table.insert(btns, { { text = _("取消"), callback = close_dlg } })

    local dlg = ButtonDialog:new{
        title = _("菜单"),
        title_align = "center",
        align = "center",
        buttons = btns,
    }
    
    UIHandles.set("sort_dialog", dlg)
    UIManager:show(dlg)
end

function M.addToMainMenu(self, menu_items)
    menu_items.reading = {
        text = _("开源阅读"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function M.getMainMenuItems(self)
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
        text = _("检查更新"),
        sub_item_table_func = function()
            local ok, UpdaterUI = pcall(require, "reading.updater_ui")
            if not ok or not UpdaterUI then
                return { { text = _("更新模块未加载，请查看日志"), enabled = false } }
            end
            local ok_menu, sub_items = xpcall(function()
                return UpdaterUI.menu_items(self)
            end, debug.traceback)
            if not ok_menu or type(sub_items) ~= "table" then
                return { { text = _("更新菜单构建失败，请查看日志"), enabled = false } }
            end
            return sub_items
        end,
    })

    table.insert(items, {
        text = _("关于"),
        callback = self:_guard(_("关于"), function()
            UIManager:show(InfoMessage:new{
                text = T(_("开源阅读插件 v%1\n\n在 KOReader 中阅读网络小说，支持书架同步、书源解析和阅读进度同步。"), tostring(self.version or "?")),
            })
        end),
    })
    
    return items
end

function M.getReadingProgressMenuItems(self)
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
            -- 章数多的书（几千章）用这个，别去跟「每页 N 条」心算页码
            text = _("跳转到章节…"),
            callback = self:_guard(_("跳转到章节"), function()
                self:show_chapter_jump_dialog()
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

return M
