local http = require("socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local ffiUtil = require("ffi/util")
local Log = require("reading.log")
local Result = require("reading.result")

local WebDAV = {}
WebDAV.__index = WebDAV

-- 网络重试配置：Kindle 网络不稳定，对瞬时错误自动重试，避免同步静默失败
local RETRY_CONFIG = {
    max_retries   = 2,   -- 最大重试次数（总请求次数 = 1 + max_retries = 3）
    initial_delay = 1,   -- 首次重试前等待秒数
    max_delay     = 4,   -- 退避延迟上限
}

-- 根据 URL 协议选择传输模块
local function get_transport(url)
    if url:match("^https://") then
        if not ok_https then
            Log.error("ssl.https模块不可用")
            return nil
        end
        return https
    end
    return http
end

-- 判断响应码是否为可重试的瞬时错误
-- 网络层错误（code 为错误字符串如 "timeout" 或 nil）、5xx 服务器错误、408 请求超时、429 限流 均可重试
-- 4xx 客户端错误（401/403/404 等）为确定性错误，重试无意义
local function is_retryable_code(code)
    if type(code) ~= "number" then return true end
    return (code >= 500 and code <= 599) or code == 408 or code == 429
end

-- 指数退避：第 attempt 次失败后的等待秒数（1s, 2s, 4s...，受 max_delay 封顶）
local function get_retry_delay(attempt)
    local delay = RETRY_CONFIG.initial_delay * (2 ^ (attempt - 1))
    if delay > RETRY_CONFIG.max_delay then
        delay = RETRY_CONFIG.max_delay
    end
    return delay
end

-- Trim leading & trailing slashes from string `s`
function WebDAV.trim_slashes(s)
    local from = s:match"^/*()"
    return from > #s and "" or s:match(".*[^/]", from)
end

-- Trim trailing slashes from string `s`
function WebDAV.rtrim_slashes(s)
    local n = #s
    while n > 0 and s:find("^/", n) do
        n = n - 1
    end
    return s:sub(1, n)
end

-- Append path to address with a slash separator
function WebDAV.get_joined_path(address, path)
    local path_encoded = util.urlEncode(path, "/") or ""
    local sane_path = WebDAV.trim_slashes(path_encoded)
    local sane_address = WebDAV.rtrim_slashes(address)
    return sane_address .. "/" .. sane_path
end

function WebDAV:new(settings)
    local obj = {
        settings = settings,
    }
    return setmetatable(obj, self)
end

--- 带重试的请求执行器
-- request_fn: 闭包，每次调用都应重新构建 sink 等状态并执行 transport.request，
--             返回 (code, status, sink_table) 三值
-- description: 用于日志的请求描述（如 "list books"）
-- 返回: code, status, sink_table（最终结果，无论成功或耗尽重试）
function WebDAV:_request_with_retry(description, request_fn)
    local code, status, sink_table
    local attempt = 0
    while true do
        attempt = attempt + 1
        local ok, err = pcall(function()
            code, status, sink_table = request_fn()
        end)
        if not ok then
            -- 请求本身抛异常（连接被重置等），视为可重试的瞬时错误
            code, status, sink_table = nil, tostring(err), nil
        end

        -- 非瞬时错误（4xx 等）或成功，直接返回
        if not is_retryable_code(code) then
            return code, status, sink_table
        end

        -- 瞬时错误：判断是否还有重试机会
        if attempt > RETRY_CONFIG.max_retries then
            Log.warn(string.format("WebDAV[%s] 重试 %d 次后仍失败: %s",
                description, RETRY_CONFIG.max_retries, tostring(status or code)))
            return code, status, sink_table
        end

        local delay = get_retry_delay(attempt)
        Log.warn(string.format("WebDAV[%s] 第 %d 次失败(%s)，%.1fs 后重试",
            description, attempt, tostring(status or code), delay))
        socket.sleep(delay)
    end
end

function WebDAV:_get_server()
    return self.settings:get_webdav_server()
end

function WebDAV:_get_username()
    return self.settings:get_webdav_username()
end

function WebDAV:_get_password()
    return self.settings:get_webdav_password()
end

function WebDAV:_get_remote_path()
    return self.settings:get_webdav_remote_path()
end

function WebDAV:_build_url(path)
    local server = self:_get_server()
    local remote_path = self:_get_remote_path()
    
    -- 构建基础 URL（server + remote_path）
    local base_url = WebDAV.get_joined_path(server, remote_path)
    
    -- 如果有额外路径，追加
    if path and path ~= "" then
        return WebDAV.get_joined_path(base_url, path)
    end
    
    return base_url
end

function WebDAV:list(path)
    local ok, r1, r2 = xpcall(function()
        return self:_list_impl(path)
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV list 异常: " .. err)
        return false, nil, "list 异常: " .. err
    end
    -- _list_impl 返回 (ok, result) 或 (ok, result, err)，统一补 nil
    if r1 then
        return true, r2, nil
    else
        return false, nil, r2
    end
end

function WebDAV:_list_impl(path)
    local url = self:_build_url(path or "")
    if url:sub(-1) ~= "/" then
        url = url .. "/"
    end

    Log.debug("列出目录: " .. url)

    local transport = get_transport(url)
    if not transport then
        return false, "SSL模块不可用"
    end

    local data = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/><a:getlastmodified/></a:prop></a:propfind>]]

    local username = self:_get_username()
    local password = self:_get_password()

    local code, status, sink = self:_request_with_retry("list " .. tostring(path), function()
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local s = {}
        local c, h, st = socket.skip(1, transport.request({
            url      = url,
            method   = "PROPFIND",
            headers  = {
                ["Content-Type"]   = "application/xml",
                ["Depth"]          = "1",
                ["Content-Length"] = #data,
            },
            user     = username,
            password = password,
            source   = ltn12.source.string(data),
            sink     = ltn12.sink.table(s),
        }))
        socketutil:reset_timeout()
        return c, st, s
    end)

    if type(code) ~= "number" then
        Log.error("WebDAV: listFolder: No response:", status or code)
        return false, "无响应"
    elseif code < 200 or code > 299 then
        Log.error("WebDAV: listFolder: Request failed:", status or code)
        return false, "请求失败: " .. tostring(status or code)
    end

    local response_body = table.concat(sink)
    if response_body == "" then
        return true, {}
    end
    
    -- 检测响应格式：JSON 或 XML
    local item_list = {}
    
    -- 尝试解析 JSON（坚果云使用这种格式）
    if response_body:sub(1, 1) == "[" then
        Log.debug("响应格式: JSON")
        
        local ok, json = pcall(require, "json")
        if not ok then
            ok, json = pcall(require, "rapidjson")
        end
        
        if ok then
            local ok2, data = pcall(json.decode, response_body)
            if ok2 and type(data) == "table" then
                for _, item in ipairs(data) do
                    if item.isDir == false and item.isDeleted == false then
                        -- 坚果云的 mtime 是毫秒时间戳，需要转换为秒
                        local mtime_sec = item.mtime and item.mtime / 1000 or 0
                        -- 转换为 RFC1123 格式字符串
                        local last_modified = ""
                        if mtime_sec > 0 then
                            last_modified = os.date("%a, %d %b %Y %H:%M:%S GMT", mtime_sec)
                        end
                        
                        table.insert(item_list, {
                            is_file = true,
                            name = item.name,
                            url = item.name,  -- 返回相对路径，由 get_file 构建完整 URL
                            size = item.size,
                            last_modified = last_modified,
                            mtime = mtime_sec,  -- 保存毫秒时间戳用于排序
                        })
                    end
                end
            end
        end
    else
        -- 标准 XML 格式
        Log.debug("响应格式: XML")
        
        for item in response_body:gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
            local item_fullpath = util.urlDecode(item:match("<[^:]*:href[^>]*>(.*)</[^:]*:href>"))
            local item_name = ffiUtil.basename(util.htmlEntitiesToUtf8(item_fullpath))
            
            local is_not_collection = item:find("<[^:]*:resourcetype%s*/>") or
                                      item:find("<[^:]*:resourcetype>%s*</[^:]*:resourcetype>")
            
            if is_not_collection then
                local file_size = tonumber(item:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>"))
                local last_modified = item:match("<[^:]*:getlastmodified[^>]*>(.*)</[^:]*:getlastmodified>")
                -- 将 RFC1123 时间转换为时间戳
                local mtime = last_modified and self:_parse_rfc1123_time(last_modified) or 0
                table.insert(item_list, {
                    is_file = true,
                    name = item_name,
                    url = item_name,  -- 返回相对路径，由 get_file 构建完整 URL
                    size = file_size,
                    last_modified = last_modified,
                    mtime = mtime,
                })
            end
        end
    end
    
    Log.info("列出目录: " .. #item_list .. " 个文件")
    return true, item_list
end

function WebDAV:get_file(path, progress_callback, total_size, file_handle)
    local ok, r1, r2 = xpcall(function()
        return self:_get_file_impl(path, progress_callback, total_size, file_handle)
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV get_file 异常: " .. err)
        return false, nil, "get_file 异常: " .. err
    end
    if r1 then
        return true, r2, nil
    else
        return false, nil, r2
    end
end

function WebDAV:_get_file_impl(path, progress_callback, total_size, file_handle)
    local url = self:_build_url(path)
    Log.debug("获取文件: " .. url)

    local transport = get_transport(url)
    if not transport then
        return false, "SSL模块不可用"
    end

    local username = self:_get_username()
    local password = self:_get_password()

    -- 每次重试都重新构建 sink 与计数器，避免上次失败留下的半下载数据污染结果
    local code, status, sink = self:_request_with_retry("get " .. tostring(path), function()
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local s = {}
        local bytes_downloaded = 0
        
        -- 如果重试，且有文件句柄，需要重置文件指针
        if file_handle then
            file_handle:seek("set", 0)
        end

        local last_check_time = os.time()
        local last_check_bytes = 0
        local STALL_TIMEOUT = 15
        local MIN_RATE = 1024 -- 1KB/s

        -- 使用闭包实现自定义 sink，KOReader 的 ltn12 可能不包含 sink.callback
        local custom_sink = function(chunk, err)
            if err then 
                Log.error("下载出错或超时: " .. tostring(err))
                return nil, err 
            end
            if chunk then
                bytes_downloaded = bytes_downloaded + #chunk
                
                -- 速率检测：连续 N 秒下载速率低于 1KB/s 则主动抛出异常，触发重试
                local current_time = os.time()
                if current_time - last_check_time >= STALL_TIMEOUT then
                    local rate = (bytes_downloaded - last_check_bytes) / (current_time - last_check_time)
                    if rate < MIN_RATE then
                        return nil, "download stalled"
                    end
                    last_check_time = current_time
                    last_check_bytes = bytes_downloaded
                end

                if file_handle then
                    file_handle:write(chunk)
                else
                    table.insert(s, chunk)
                end
                
                if progress_callback then
                    progress_callback(bytes_downloaded, total_size)
                end
            end
            return 1 -- 返回非 nil 值表示接收成功
        end

        local c, h, st = socket.skip(1, transport.request({
            url      = url,
            method   = "GET",
            user     = username,
            password = password,
            sink     = custom_sink,
        }))
        socketutil:reset_timeout()
        return c, st, s
    end)

    if type(code) ~= "number" then
        Log.error("WebDAV: cannot download file (non-numeric code):", tostring(status or code))
        return false, "下载失败: " .. tostring(status or code)
    end

    if code == 404 then
        Log.info("WebDAV: 文件不存在 (404): " .. tostring(path))
        return true, nil  -- 业务成功但无数据
    end

    if code ~= 200 then
        Log.error("WebDAV: cannot download file (HTTP " .. code .. "):", status)
        return false, "下载失败 (HTTP " .. code .. ")"
    end

    if file_handle then
        Log.info("获取文件成功，流式写入完成")
        return true, nil
    else
        local content = table.concat(sink)
        Log.info("获取文件成功，大小: " .. #content)
        return true, content
    end
end

function WebDAV:put_file(path, content)
    local ok, r1, r2 = xpcall(function()
        return self:_put_file_impl(path, content)
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV put_file 异常: " .. err)
        return false, nil, "put_file 异常: " .. err
    end
    if r1 then
        return true, r2, nil
    else
        return false, nil, r2
    end
end

function WebDAV:_put_file_impl(path, content)
    local url = self:_build_url(path)
    Log.debug("上传文件: " .. url)

    local transport = get_transport(url)
    if not transport then
        return false, "SSL模块不可用"
    end

    local username = self:_get_username()
    local password = self:_get_password()

    local code, status = self:_request_with_retry("put " .. tostring(path), function()
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local c, h, st = socket.skip(1, transport.request({
            url      = url,
            method   = "PUT",
            user     = username,
            password = password,
            source   = ltn12.source.string(content),
            headers  = {
                ["Content-Length"] = #content,
            },
        }))
        socketutil:reset_timeout()
        return c, st, nil
    end)

    if type(code) == "number" and code >= 200 and code <= 299 then
        Log.info("上传文件成功")
        return true, "上传成功"
    else
        Log.error("WebDAV: cannot upload file:", status or code)
        return false, "上传失败: " .. tostring(status or code)
    end
end

function WebDAV:delete_file(path)
    local ok, r1, r2 = xpcall(function()
        return self:_delete_file_impl(path)
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV delete_file 异常: " .. err)
        return false, nil, "delete_file 异常: " .. err
    end
    if r1 then
        return true, r2, nil
    else
        return false, nil, r2
    end
end

function WebDAV:_delete_file_impl(path)
    local url = self:_build_url(path)
    Log.debug("删除文件: " .. url)

    local transport = get_transport(url)
    if not transport then
        return false, "SSL模块不可用"
    end

    local username = self:_get_username()
    local password = self:_get_password()

    local code, status = self:_request_with_retry("delete " .. tostring(path), function()
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local c, h, st = socket.skip(1, transport.request({
            url      = url,
            method   = "DELETE",
            user     = username,
            password = password,
        }))
        socketutil:reset_timeout()
        return c, st, nil
    end)

    if type(code) == "number" and code >= 200 and code <= 299 then
        Log.info("删除文件成功")
        return true, "删除成功"
    else
        Log.error("WebDAV: cannot delete file:", status or code)
        return false, "删除失败: " .. tostring(status or code)
    end
end

function WebDAV:mkdir(path)
    local ok, r1, r2 = xpcall(function()
        return self:_mkdir_impl(path)
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV mkdir 异常: " .. err)
        return false, nil, "mkdir 异常: " .. err
    end
    if r1 then
        return true, r2, nil
    else
        return false, nil, r2
    end
end

function WebDAV:_mkdir_impl(path)
    local url = self:_build_url(path)
    Log.debug("创建目录: " .. url)

    local transport = get_transport(url)
    if not transport then
        return false, "SSL模块不可用"
    end

    local username = self:_get_username()
    local password = self:_get_password()

    local code, status = self:_request_with_retry("mkdir " .. tostring(path), function()
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local c, h, st = socket.skip(1, transport.request({
            url      = url,
            method   = "MKCOL",
            user     = username,
            password = password,
        }))
        socketutil:reset_timeout()
        return c, st, nil
    end)

    if type(code) == "number" and code >= 200 and code <= 299 then
        Log.info("创建目录成功")
        return true, "创建成功"
    else
        Log.error("WebDAV: cannot create folder:", status or code)
        return false, "创建失败: " .. tostring(status or code)
    end
end

function WebDAV:get_binary(url)
    if not url or url == "" then return nil end
    local transport = get_transport(url)
    if not transport then return nil end

    local resp = {}
    local code, hdrs, status = transport.request({
        url = url,
        method = "GET",
        sink = ltn12.sink.table(resp),
        -- 封面图片不需要带 WebDAV 的认证信息
    })

    if type(code) == "number" and code >= 200 and code <= 299 then
        return table.concat(resp)
    end
    return nil
end

function WebDAV:_parse_rfc1123_time(date_str)
    if not date_str then return 0 end
    
    local months = {
        ["Jan"] = 1, ["Feb"] = 2, ["Mar"] = 3, ["Apr"] = 4,
        ["May"] = 5, ["Jun"] = 6, ["Jul"] = 7, ["Aug"] = 8,
        ["Sep"] = 9, ["Oct"] = 10, ["Nov"] = 11, ["Dec"] = 12
    }
    
    local day, month_str, year, hour, min, sec = date_str:match("(%d+)%s+(%w+)%s+(%d+)%s+(%d+):(%d+):(%d+)")
    
    if day and month_str and year and hour and min and sec then
        local month = months[month_str]
        if month then
            return os.time{
                year = tonumber(year),
                month = month,
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec)
            }
        end
    end
    
    return 0
end

function WebDAV:test_connection()
    local ok, r1, r2 = xpcall(function()
        return self:_test_connection_impl()
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV test_connection 异常: " .. err)
        return false, nil, "test_connection 异常: " .. err
    end
    if r1 then
        return true, r2, nil
    else
        return false, nil, r2
    end
end

function WebDAV:_test_connection_impl()
    Log.info("测试WebDAV连接")

    local url = self:_build_url("")
    if url:sub(-1) ~= "/" then
        url = url .. "/"
    end

    local transport = get_transport(url)
    if not transport then
        return false, "SSL模块不可用"
    end

    local data = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/></a:prop></a:propfind>]]

    local username = self:_get_username()
    local password = self:_get_password()

    local code, status = self:_request_with_retry("test_connection", function()
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local s = {}
        local c, h, st = socket.skip(1, transport.request({
            url      = url,
            method   = "PROPFIND",
            headers  = {
                ["Content-Type"]   = "application/xml",
                ["Depth"]          = "0",
                ["Content-Length"] = #data,
            },
            user     = username,
            password = password,
            source   = ltn12.source.string(data),
            sink     = ltn12.sink.table(s),
        }))
        socketutil:reset_timeout()
        return c, st, nil
    end)

    if type(code) ~= "number" then
        Log.error("WebDAV连接测试失败: 无响应")
        return false, "无响应"
    elseif code < 200 or code > 299 then
        Log.error("WebDAV连接测试失败: " .. tostring(status or code))
        return false, "连接失败: " .. tostring(status or code)
    end

    Log.info("WebDAV连接测试成功")
    return true, "连接成功"
end

function WebDAV:get_backup_file()
    local ok, r1, r2, r3 = xpcall(function()
        return self:_get_backup_file_impl()
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV get_backup_file 异常: " .. err)
        return false, nil, "get_backup_file 异常: " .. err
    end
    -- _get_backup_file_impl 返回 (true, content, filename) 或 (false, nil, err)
    return r1, r2, r3
end

function WebDAV:_get_backup_file_impl()
    Log.info("获取备份文件")
    
    local ok, items, err = self:list("")
    if not ok then
        return false, nil, err
    end
    
    local backup_files = {}
    for _, item in ipairs(items) do
        if item.is_file and (item.name:match("%.zip$") or item.name:match("%.txt$")) then
            table.insert(backup_files, item)
        end
    end
    
    if #backup_files == 0 then
        return false, nil, "未找到备份文件"
    end
    
    table.sort(backup_files, function(a, b) return a.name > b.name end)
    local latest_file = backup_files[1]
    
    Log.info("找到最新备份文件: " .. latest_file.name)
    
    local ok2, content, err2 = self:get_file(latest_file.url)
    if not ok2 then
        return false, nil, err2
    end
    
    return true, content, latest_file.name
end

function WebDAV:upload_backup_file(filename, content)
    local ok, r1, r2 = xpcall(function()
        return self:_upload_backup_file_impl(filename, content)
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV upload_backup_file 异常: " .. err)
        return false, nil, "upload_backup_file 异常: " .. err
    end
    if r1 then
        return true, r2, nil
    else
        return false, nil, r2
    end
end

function WebDAV:_upload_backup_file_impl(filename, content)
    Log.info("上传备份文件: " .. filename)
    
    local ok, __, err = self:put_file(filename, content)
    if not ok then
        return false, err
    end
    
    return true, "上传成功"
end

return WebDAV
