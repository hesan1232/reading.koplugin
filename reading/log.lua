-- Reading Plugin Logger
-- Wraps KOReader's logger with configurable debug level and file output.

local Log = {}

-- State (module-level, shared across instances)
local _log_file_path = nil
-- 默认关闭 DEBUG 日志：每条日志都要 stat + open/write/close，
-- 在墨水屏设备上会明显影响翻页延迟并消耗 eMMC 写入寿命。
-- 实际取值由 Log.init(path, debug) 从 advanced.developer_logs 注入。
local _debug_enabled = false

-- Max log file size before rotation (512 KB)
local MAX_LOG_SIZE = 512 * 1024

-- 内存缓冲：原来每条日志都要 lfs.attributes(stat) + io.open/write/close，
-- main.lua 里有上百处 Log.* 调用，在墨水屏设备上这会明显拖慢翻页并消耗 eMMC。
-- 现在先攒进内存，满足任一条件才真正落盘：
--   · 攒够 FLUSH_MAX_LINES 行
--   · 或攒够 FLUSH_MAX_BYTES 字节
--   · 或距上次落盘超过 FLUSH_INTERVAL 秒
--   · 或这是一条 WARN/ERROR（异常现场丢了就白记了，立即落盘）
-- 另有一个后台定时器兜底，保证「最后几行」不会被无限期滞留。
--
-- 【这个兜底定时器是「按需存在」的，不要改回常驻】
-- 早先的实现在 Log.init 里无条件启动、回调里再无条件重排，于是从插件加载起
-- 就永久存在一个 2 秒周期的唤醒（onClose 也不取消，因为它是模块级状态），
-- 而它绝大多数的触发都只是「#_buffer == 0 立刻 return」——为了兜底几十行日志，
-- 付出的是常驻 0.5Hz 的事件循环唤醒。墨水屏设备上这类唤醒是实打实的电量成本。
-- 现在只在「确实有内容留在缓冲里」时才排下一次（见 ensure_flush_tick）。
local FLUSH_MAX_LINES = 32
local FLUSH_MAX_BYTES = 8 * 1024
local FLUSH_INTERVAL = 5      -- 秒
local FLUSH_TICK = 2          -- 秒：后台兜底落盘间隔

local _buffer = {}
local _buffer_bytes = 0
local _last_flush = os.time()
local _tick_pending = false

local ok_UIManager, UIManager = pcall(require, "ui/uimanager")

--- 初始化日志。debug 为 nil 时保持当前开关状态（默认关闭）。
-- @param log_path string  日志文件路径
-- @param debug boolean|nil  是否开启 DEBUG 级别
function Log.init(log_path, debug)
    _log_file_path = log_path
    if debug ~= nil then
        _debug_enabled = debug and true or false
    end
    _last_flush = os.time()
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

--- 把缓冲区内容一次性写入日志文件。空缓冲时立即返回，不做任何 I/O。
function Log.flush()
    if #_buffer == 0 then return end

    if not _log_file_path then
        _buffer = {}
        _buffer_bytes = 0
        return
    end

    -- 轮转检查从「每条日志」移到「每次落盘」，热路径上只剩字符串拼接
    rotate_if_needed()

    local file = io.open(_log_file_path, "a")
    if file then
        -- 【write / close 都要查】日志落盘失败不重试、不弹窗（避免日志本身把界面搞乱），
        -- 但必须在清空缓冲**之前**留个痕迹 —— 否则「日志莫名其妙不长了」无从查起。
        -- 走 KOReader 自己的 logger（不是本模块），不会递归。
        local write_ok, write_err = file:write(table.concat(_buffer))
        local close_ok, close_err = file:close()
        if not write_ok or close_ok == nil then
            pcall(function()
                require("logger"):warn("reading: 日志写盘失败: " .. tostring(write_err or close_err))
            end)
        end
    end

    _buffer = {}
    _buffer_bytes = 0
    _last_flush = os.time()
end

--- 后台兜底：确保有一个定时器在跑，把缓冲区刷进文件，避免长时间无新日志时
--- 最后几行滞留内存（写入路径只在「攒够行数/字节数/间隔」时才落盘，若此后再无
--- 日志进来，那几行就永远等不到下一次判断）。
--
--- **只应在缓冲区非空时调用**（write_to_file 的 else 分支）：
--- 回调里 flush 完若缓冲为空就**不再重排** —— 这正是「不空转」的关键。
local function ensure_flush_tick()
    if _tick_pending then return end
    if not ok_UIManager or not UIManager or not UIManager.scheduleIn then return end
    _tick_pending = true
    UIManager:scheduleIn(FLUSH_TICK, function()
        _tick_pending = false
        pcall(Log.flush)
        -- flush 之后仍有剩余（这次新写进来的、或路径未就绪没写成的）就续排；
        -- 缓冲为空则就此停下。
        if #_buffer > 0 then
            ensure_flush_tick()
        end
    end)
end

local function write_to_file(level_str, message)
    if not _log_file_path then return end

    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] %s: %s\n", timestamp, level_str, message)
    _buffer[#_buffer + 1] = line
    _buffer_bytes = _buffer_bytes + #line

    local urgent = (level_str == "WARN" or level_str == "ERROR")
    if urgent
        or #_buffer >= FLUSH_MAX_LINES
        or _buffer_bytes >= FLUSH_MAX_BYTES
        or (os.time() - _last_flush) >= FLUSH_INTERVAL then
        Log.flush()
    else
        -- 这条留在缓冲里了：保证有一个兜底 tick 会来收它
        ensure_flush_tick()
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
    -- 先丢弃缓冲，否则 clear 之后缓冲里的旧行会被下一次 flush 写回文件
    _buffer = {}
    _buffer_bytes = 0
    if _log_file_path then
        os.remove(_log_file_path)
        os.remove(_log_file_path .. ".old")
    end
end

function Log.read_log_content(max_length)
    -- 缓冲未落盘时直接读文件会看不到最新几条，先强制刷一次
    Log.flush()
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
