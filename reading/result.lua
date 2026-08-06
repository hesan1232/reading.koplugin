--[[
    错误处理工具模块

    提供统一的 pcall 包装、错误格式化、调用约定辅助。
    不引入 Result 类型，保持 Lua 多返回值习惯。

    统一返回约定：(ok, result, err)
    - true,  data,  nil   —— 成功有数据
    - true,  nil,   nil   —— 成功但无数据（如云端无进度文件，正常情况）
    - false, nil,   err   —— 失败带错误信息
]]

local Log = require("reading.log")

local Result = {}

-------------------------------------------------------------------------------
-- 错误格式化：截断控制字符、限制 500 字符长度
-- 替代原 main.lua 中的 log_error 函数
-------------------------------------------------------------------------------
function Result.format_error(err)
    if err == nil then return "" end
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

-------------------------------------------------------------------------------
-- 包装"不遵守约定的第三方/KOReader API"，捕获异常转为 (ok, result, err)
-- 用于调用 lfs.attributes、json.decode、socket.request 等
--
-- @param fn    无参闭包，返回单一值（或 nil）
-- @param label 可选，用于日志标识
-- @return ok, result, err
-------------------------------------------------------------------------------
function Result.try(fn, label)
    local ok, ret = xpcall(fn, function(err) return tostring(err) end)
    if ok then
        return true, ret, nil
    end
    local err = Result.format_error(ret)
    if label then
        Log.error(label .. " 异常: " .. err)
    end
    return false, nil, err
end

return Result
