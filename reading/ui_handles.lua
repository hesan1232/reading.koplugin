--[[
    UI 句柄管理模块

    封装所有需要跨 FileManager/ReaderUI 实例共享的 UI 句柄。
    修复了原 _state 中 current_chapter_list_menu 在 onClose 未被清理的泄漏 bug。

    设计要点：
    - set(name, widget) 注册同名句柄时自动关闭旧句柄，避免重复 UI 残留。
    - close(name) 用 pcall 包裹 UIManager:close，防御性处理已销毁的 widget。
    - close_all() 用于 onClose。
]]

local Log = require("reading.log")

local UIHandles = {}

-- 模块级私有句柄表
-- 下表只是**清单**（Lua 表不预声明也能工作），列出当前实际在用的句柄名 ——
-- 新增句柄时请一并登记，否则这份清单会慢慢变成一份错误的文档。
-- 注：active_menu 已删除 —— 它与 menu 永远同指同一个 widget，
--     导致旧菜单在「打开书架」时被 close 两次。
local _handles = {
    menu = nil,                  -- 书架主菜单
    detail_dialog = nil,         -- 书籍详情对话框
    busy_msg = nil,              -- busy 提示
    chapter_list_menu = nil,     -- 章节列表菜单（修复原 _state 泄漏）
    sort_dialog = nil,           -- 书架排序/筛选对话框
    webdav_file_list = nil,      -- WebDAV 备份文件列表
    cloud_library_list = nil,    -- 云端书库 / 多版本选择列表
    cloud_list_menu = nil,       -- 云端书库左上角菜单（排序/筛选）
    progress_dialog = nil,       -- 「进度同步」选择框
}

-------------------------------------------------------------------------------
-- 内部辅助：安全关闭 widget（防御性处理已销毁的对象）
-------------------------------------------------------------------------------
local function _safe_close(widget)
    if not widget then return end
    local UIManager = require("ui/uimanager")
    local ok = pcall(function()
        UIManager:close(widget)
    end)
    if not ok then
        Log.debug("UIHandles: 关闭 widget 时忽略异常（可能已销毁）")
    end
end

-------------------------------------------------------------------------------
-- 注册句柄：若同名旧句柄存在，自动关闭
-------------------------------------------------------------------------------
function UIHandles.set(name, widget)
    if _handles[name] and _handles[name] ~= widget then
        _safe_close(_handles[name])
    end
    _handles[name] = widget
end

-------------------------------------------------------------------------------
-- 获取句柄
-------------------------------------------------------------------------------
function UIHandles.get(name)
    return _handles[name]
end

-------------------------------------------------------------------------------
-- 只置 nil 不 close（widget 已自行关闭时用）
-------------------------------------------------------------------------------
function UIHandles.clear(name)
    _handles[name] = nil
end

-------------------------------------------------------------------------------
-- 关闭并置 nil
-------------------------------------------------------------------------------
function UIHandles.close(name)
    _safe_close(_handles[name])
    _handles[name] = nil
end

-------------------------------------------------------------------------------
-- 关闭所有句柄（onClose 调用）
-------------------------------------------------------------------------------
function UIHandles.close_all()
    for name in pairs(_handles) do
        UIHandles.close(name)
    end
end

return UIHandles
