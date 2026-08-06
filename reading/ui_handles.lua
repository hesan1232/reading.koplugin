--[[
    UI 句柄管理模块

    封装所有需要跨 FileManager/ReaderUI 实例共享的 UI 句柄。
    修复了原 _state 中 current_chapter_list_menu 在 onClose 未被清理的泄漏 bug。

    设计要点：
    - set(name, widget) 注册同名句柄时自动关闭旧句柄，避免重复 UI 残留。
    - close(name) 用 pcall 包裹 UIManager:close，防御性处理已销毁的 widget。
    - close_all() 用于 onClose；close_all_except_busy() 用于需要保留 busy 提示的场景。
]]

local Log = require("reading.log")

local UIHandles = {}

-- 模块级私有句柄表
local _handles = {
    menu = nil,                  -- 书架主菜单
    detail_dialog = nil,         -- 书籍详情对话框
    active_menu = nil,           -- 当前活跃的次要菜单
    busy_msg = nil,              -- busy 提示
    chapter_list_menu = nil,     -- 章节列表菜单（修复原 _state 泄漏）
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

-------------------------------------------------------------------------------
-- 关闭除 busy_msg 外的所有句柄（需要保留 busy 提示的场景）
-------------------------------------------------------------------------------
function UIHandles.close_all_except_busy()
    for name in pairs(_handles) do
        if name ~= "busy_msg" then
            UIHandles.close(name)
        end
    end
end

return UIHandles
