-- Reading Plugin Logger
-- Wraps KOReader's logger with configurable debug level and file output.

local ok_ko_logger, ko_logger = pcall(require, "logger")
if not ok_ko_logger then
    ko_logger = nil
end

local Log = {}
local LOG_MODULE = "[Reading]"

-- State (module-level, shared across instances)
local _log_file_path = nil
local _debug_enabled = true

-- Max log file size before rotation (512 KB)
local MAX_LOG_SIZE = 512 * 1024

function Log.init(log_path)
    _log_file_path = log_path
end

function Log.set_debug_enabled(enabled)
    _debug_enabled = enabled
end

function Log.is_debug_enabled()
    return _debug_enabled
end

-- Rotate log file if it exceeds MAX_LOG_SIZE
local function rotate_if_needed()
    if not _log_file_path then return end
    local lfs = require("libs/libkoreader-lfs")
    local ok, attr = pcall(function()
        return lfs.attributes(_log_file_path)
    end)
    if ok and attr and attr.size and attr.size > MAX_LOG_SIZE then
        local old_path = _log_file_path .. ".old"
        os.remove(old_path)
        os.rename(_log_file_path, old_path)
    end
end

local function write_to_file(level_str, message)
    if not _log_file_path then return end
    rotate_if_needed()
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] %s: %s\n", timestamp, level_str, message)
    local file = io.open(_log_file_path, "a")
    if file then
        file:write(line)
        file:close()
    end
end

local function format_args(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            table.insert(parts, v)
        else
            table.insert(parts, tostring(v))
        end
    end
    return table.concat(parts, " ")
end

function Log.debug(msg, ...)
    if not _debug_enabled then return end
    local message = format_args(msg, ...)
    write_to_file("DEBUG", message)
end

function Log.info(msg, ...)
    local message = format_args(msg, ...)
    write_to_file("INFO", message)
end

function Log.warn(msg, ...)
    local message = format_args(msg, ...)
    write_to_file("WARN", message)
end

function Log.error(msg, ...)
    local message = format_args(msg, ...)
    write_to_file("ERROR", message)
end

function Log.get_log_file_path()
    return _log_file_path
end

function Log.clear_log()
    if _log_file_path then
        os.remove(_log_file_path)
        os.remove(_log_file_path .. ".old")
    end
end

function Log.read_log_content(max_length)
    max_length = max_length or 5000
    if not _log_file_path then
        return nil, "日志文件路径未设置"
    end
    
    local lfs = require("libs/libkoreader-lfs")
    local ok, attr = pcall(function()
        return lfs.attributes(_log_file_path)
    end)
    if not ok or not attr or attr.mode ~= "file" then
        return nil, "日志文件不存在"
    end
    
    local file = io.open(_log_file_path, "r")
    if not file then
        return nil, "无法打开日志文件"
    end
    
    local content = file:read("*a")
    file:close()
    
    if #content > max_length then
        content = "...(仅显示最后" .. max_length .. "字符)\n" .. content:sub(-max_length)
    end
    
    return content
end

return Log
