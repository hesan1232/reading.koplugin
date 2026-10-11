local http = require("socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
-- lfs 必须显式 require：KOReader **不提供全局 lfs**（全仓库其余模块都是
-- `local lfs = require("libs/libkoreader-lfs")`）。断点续传要读「本地已有字节数」，
-- 裸用 lfs.attributes 在无全局 lfs 的环境会抛
-- "attempt to index a nil value (global 'lfs')"，续传检测直接失败。
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ffiUtil = require("ffi/util")
local Log = require("reading.log")
local Result = require("reading.result")

local WebDAV = {}
WebDAV.__index = WebDAV

-- JSON 库在**模块加载时**解析一次并提升为 upvalue（参照 async.lua），
-- 而不是在 _list_impl 里每次调用 pcall(require, "json") —— 坚果云走 JSON 响应，
-- 目录列表是同步链路上会被反复走到的路径。解析失败时保持 nil，
-- 下面的调用点会退回 XML 解析分支（与原行为一致）。
local _json
do
    local ok, json = pcall(require, "json")
    if not ok then
        ok, json = pcall(require, "rapidjson")
    end
    if ok then _json = json end
end

-- 网络重试配置：Kindle 网络不稳定，对瞬时错误自动重试，避免同步静默失败
local RETRY_CONFIG = {
    max_retries   = 2,   -- 最大重试次数（总请求次数 = 1 + max_retries = 3）
    initial_delay = 1,   -- 首次重试前等待秒数
    max_delay     = 4,   -- 退避延迟上限
}

-- 传输策略链：解决「自签 / 过期证书」「服务器只监听 HTTP」这两类其实连不上的情形。
--
-- ① HTTPS：默认**不显式设置 verify** —— 沿用 luasec 的默认（等价于不校验），
--    这是 KOReader 自身 WebDAV 客户端与 koobone 在同一类设备上的实际做法
--    （设备上通常没有 CA 证书库，强行 verify="peer" 会让所有服务器都握手失败）。
--    仅当用户显式打开「校验证书」开关时才传 verify="peer" + tlsv1_2。
-- ② HTTP 回退：**仅当用户显式允许**时，把 https:// 换成 http:// 再试一次。
--    明文会暴露 WebDAV 口令，所以默认关闭；启用后 `_request_with_fallback` 会打 WARN。
--
-- 返回数组，元素 { name, transport, url, ssl_opts }；空数组表示当前 URL 无任何可用传输。
local function build_transport_chain(url, verify_cert, allow_http_fallback)
    local chain = {}
    if url:match("^https://") then
        if ok_https then
            chain[#chain + 1] = {
                name      = verify_cert and "HTTPS+Verify" or "HTTPS",
                transport = https,
                url       = url,
                ssl_opts  = verify_cert and {
                    mode     = "client",
                    protocol = "tlsv1_2",
                    verify   = "peer",
                    options  = "all",
                } or nil,
            }
        end
        if allow_http_fallback then
            chain[#chain + 1] = {
                name      = "HTTP+Fallback",
                transport = http,
                url       = "http://" .. url:sub(9),   -- 去掉 "https://"（8 字符）后接原 host+path
            }
        end
    else
        chain[#chain + 1] = { name = "HTTP", transport = http, url = url }
    end
    return chain
end

-- 判断响应码是否为可重试的瞬时错误
-- 网络层错误（code 为错误字符串如 "timeout" 或 nil）、5xx 服务器错误、408 请求超时、429 限流 均可重试
-- 4xx 客户端错误（401/403/404 等）为确定性错误，重试无意义
local function is_retryable_code(code)
    -- code == nil：请求本身抛异常（连接重置等），是瞬时错误 → 重试。
    if code == nil then return true end
    -- 非数值但不是 nil：调用方用「业务错误」表达失败（见 _get_file_impl 里
    -- `return false, "重试前无法重新打开目标文件"`）。重试不可能让它变好，
    -- 而且必须**立刻停止** —— 继续重试会退化成「整本书读进内存后报成功、
    -- 但磁盘上什么都没有」（file_handle 那时已是 nil，sink 会改写内存表）。
    if type(code) ~= "number" then return false end
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
        -- 【异常路径也要复位 socket 超时】attempt 内部是
        --   set_timeout(15, FILE_TOTAL_TIMEOUT) → transport.request(...) → reset_timeout()
        -- 若 request 抛异常（连接被重置等），中间的 reset_timeout 会被跳过 —— 全局
        -- socket 超时就残留 15s，污染此后**所有没有自己 set 超时**的网络调用
        -- （含 KOReader 自身的）。重试路径会重设，但「最终失败的那一次」不复位。
        -- Lua 没有 finally，这里在 pcall 之后无条件补一次复位（正常路径重复复位无害）。
        pcall(function() socketutil:reset_timeout() end)
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

--- 是否对 HTTPS 校验证书（读不到设置时按「不校验」处理，与历史行为一致）。
function WebDAV:_verify_cert_enabled()
    local s = self.settings
    if s and s.get_webdav_verify_cert then
        local ok, v = pcall(s.get_webdav_verify_cert, s)
        if ok then return v == true end
    end
    return false
end

--- HTTPS 失败时是否允许降级 HTTP。
function WebDAV:_http_fallback_enabled()
    local s = self.settings
    if s and s.get_webdav_allow_http_fallback then
        local ok, v = pcall(s.get_webdav_allow_http_fallback, s)
        if ok then return v == true end
    end
    return false
end

--- 按策略链执行请求。
--
-- 同一请求在链上的**每个策略**上各走一遍 `_request_with_retry`（因此单策略内部仍有
-- 瞬时错误重试），任一策略返回**数值状态码**即停止并返回；全部策略都在传输层失败
-- （code 非数值）时返回最后一个结果，调用方按原有的「无响应」分支处理。
--
-- @param description string 日志用请求描述
-- @param url         string 目标 URL（由它推导策略链；策略内可能改写为 http://）
-- @param attempt_fn  function(strategy) -> code, status, sink
--        执行**一次**请求。strategy 提供 transport / url / ssl_opts（ssl_opts 需合并进
--        transport.request 的请求表）。约定与 `_request_with_retry` 的 request_fn 相同：
--        每次调用都要重建 sink / 计数器等状态。异常由本函数捕获并按瞬时错误处理。
function WebDAV:_request_with_fallback(description, url, attempt_fn)
    local chain = build_transport_chain(url, self:_verify_cert_enabled(), self:_http_fallback_enabled())
    if #chain == 0 then
        Log.error("WebDAV[" .. description .. "] 无可用传输（HTTPS 需要 ssl.https 模块）")
        return nil, "SSL模块不可用", nil
    end

    local last_code, last_status, last_sink
    for index, strategy in ipairs(chain) do
        if index > 1 then
            Log.warn(string.format("WebDAV[%s] 降级到策略 %s（%s）—— 前一个策略传输失败",
                description, strategy.name, strategy.url))
        end
        -- 适配器：_request_with_retry 需要「零参 request_fn」，这里把当前策略捆进去。
        local code, status, sink = self:_request_with_retry(
            description, function() return attempt_fn(strategy) end)
        if type(code) == "number" then
            return code, status, sink
        end
        last_code, last_status, last_sink = code, status, sink
    end

    -- 走到这里 = 所有策略都在传输层失败。若用户开了明文回退说明确实试过 HTTP，
    -- 否则提示他「可以开启降级」——这是自建 WebDAV 只开 HTTP 时最常见的死因。
    if url:match("^https://") and not self:_http_fallback_enabled() then
        Log.warn(string.format("WebDAV[%s] HTTPS 全部策略失败。若该服务器只监听 HTTP，"
            .. "可在 设置 → WebDAV → 允许降级 HTTP 打开明文回退", description))
    end
    return last_code, last_status, last_sink
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

    local data = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/><a:getlastmodified/></a:prop></a:propfind>]]

    local username = self:_get_username()
    local password = self:_get_password()

    local function attempt_request(strategy)
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local s = {}
        local req = {
            url      = strategy.url,
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
        }
        for k, v in pairs(strategy.ssl_opts or {}) do req[k] = v end
        local c, h, st = socket.skip(1, strategy.transport.request(req))
        socketutil:reset_timeout()
        return c, st, s
    end

    local code, status, sink = self:_request_with_fallback(
        "list " .. tostring(path), url, attempt_request)

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

        if _json then
            local ok2, data = pcall(_json.decode, response_body)
            if ok2 and type(data) == "table" then
                for __, item in ipairs(data) do
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
            
            -- FIX: 优化 XML 解析，解决部分 WebDAV 服务器 (如坚果云/Alist) 返回的节点带命名空间前缀导致匹配失败的问题
            -- 例如：<D:resourcetype/> 或 <d:getcontentlength>
            local is_not_collection = item:find("<[^>]*resourcetype%s*/>") or
                                      item:find("<[^>]*resourcetype>%s*</[^>]*resourcetype>")
            
            if is_not_collection then
                local file_size_str = item:match("<[^>]*getcontentlength[^>]*>(%d+)</[^>]*getcontentlength>")
                local file_size = tonumber(file_size_str)
                
                local last_modified = item:match("<[^>]*getlastmodified[^>]*>(.-)</[^>]*getlastmodified>")
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

--- 下载文件
-- @param path                WebDAV 上的相对路径
-- @param progress_callback   function(bytes_downloaded, total_size)|nil
-- @param total_size          number|nil 远端文件大小
-- @param file_handle         file*|nil 传入则以流式写入该句柄（否则整包读进内存返回）
-- @param local_path          string|nil 本地目标路径。**流式下载时应当传**：
--                            ① 断点续传靠它读「已有字节数」（配合 file_handle 的追加模式）；
--                            ② 服务器忽略 Range 返回 200 时，靠它删掉被污染的半截文件。
-- @return ok, content_or_nil, err_or_nil, final_file_handle
--         final_file_handle 可能在重试过程中被换成新句柄，调用方必须关闭「它」而不是最初传入的那个。
--         err 可能为 `"RANGE_UNSUPPORTED"`（专用信号：服务器不支持断点续传，半截文件已被删除，
--         调用方应以全新文件整包重下一次）。见 sync.lua 的 download_epub。
function WebDAV:get_file(path, progress_callback, total_size, file_handle, local_path)
    local ok, r1, r2, r3 = xpcall(function()
        return self:_get_file_impl(path, progress_callback, total_size, file_handle, local_path)
    end, function(err) return tostring(err) end)
    if not ok then
        local err = Result.format_error(r1)
        Log.error("WebDAV get_file 异常: " .. err)
        -- 异常路径下 _impl 内部的局部句柄已不可见，只能把调用方传入的那个交回；
        -- 它可能已被 _impl 关闭过，所以调用方必须用 pcall 关闭（sync.lua 已是这么做的）。
        return false, nil, "get_file 异常: " .. err, file_handle
    end
    if r1 then
        return true, r2, nil, r3
    else
        -- 失败也要透出第 4 项：重试可能已把句柄换成新的，不交回就泄漏。
        return false, nil, r2, r3
    end
end

function WebDAV:_get_file_impl(path, progress_callback, total_size, file_handle, local_path)
    local url = self:_build_url(path)
    Log.debug("获取文件: " .. url)

    local username = self:_get_username()
    local password = self:_get_password()

    -- ------------------------------------------------------------------
    -- 断点检测（发起任何请求之前）
    -- ------------------------------------------------------------------
    -- 与 koobone 的 `do_http_download_with_progress` 同款三分支：
    --   ① 本地已有 >= 远端大小 → 直接判成功，**连请求都不发**（弱网下省一次完整往返）；
    --   ② 本地有半截数据       → 本次带 Range 续传（从当前长度继续）；
    --   ③ 本地为空 / 无本地路径 → 普通整包下载。
    -- 只有流式模式（传了 file_handle + local_path）才谈得上续传；整包读进内存的模式没有落点。
    local resume_offset = 0
    if file_handle and local_path and local_path ~= "" then
        local exist_size = lfs.attributes(local_path, "size") or 0
        if exist_size > 0 then
            if total_size and total_size > 0 and exist_size >= total_size then
                Log.info("断点检测: 本地文件已完整，跳过下载 (" .. exist_size .. "/" .. total_size .. ")")
                if progress_callback then
                    progress_callback(exist_size, total_size)
                end
                return true, nil, file_handle
            end
            resume_offset = exist_size
            Log.info("断点续传: 从 " .. resume_offset .. " 字节继续（远端 "
                .. tostring(total_size) .. "）")
            if progress_callback then
                progress_callback(resume_offset, total_size)
            end
        end
    end

    -- 出口标志：最后一次尝试是否真的带了 Range（供下面 200 / 416 分支判断）
    local range_sent = false

    -- 每次尝试都重新构建 sink 与计数器，避免上次失败留下的半下载数据污染结果。
    -- （写成命名局部函数而不是内联闭包：本请求要跨「策略链 × 瞬时重试」两层，
    --   _request_with_fallback 会对每个策略各调用一次。）
    local function attempt_request(strategy)
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local s = {}
        local bytes_downloaded = 0

        -- ----------------------------------------------------------------
        -- 本次尝试的起始位置（断点续传）
        -- ----------------------------------------------------------------
        -- 【为什么重试不再截断】旧实现每次重试都以 "wb" 重开、从 0 重下：弱网下重试 3 次
        -- 就等于把已经下载的几 MB 全部丢弃重来。断点续传的语义是「只补剩下那部分」，
        -- 所以这里**重新读一次**当前文件长度（上一次尝试可能又写进去了一些字节），
        -- 再以追加模式（调用方用 "a+b" 打开）从该位置发 Range 请求。
        --
        -- 【真正需要截断的场景依然被覆盖】服务器忽略 Range、回 200 整包时，追加会把
        -- 整包粘在半截文件后面 —— 那种情况由请求返回后的 200 分支检测出来：删掉被污染的
        -- 文件并上报 "RANGE_UNSUPPORTED"，调用方（sync.download_epub）以 "wb" 重新开始。
        local range_header = nil
        if file_handle then
            if local_path and local_path ~= "" then
                local cur = lfs.attributes(local_path, "size") or 0
                if cur > 0 then
                    bytes_downloaded = cur
                    range_header = "bytes=" .. tostring(cur) .. "-"
                end
            else
                -- 没拿到本地路径 → 无法判断已有字节数，退化为整包重下。
                -- （原实现这里只做 file_handle:seek("set", 0)：seek 只移动写指针、
                --  不改变文件长度，于是「第一次写 10MB 后失败 → 第二次写 8MB 成功」
                --  会留下一个 10MB 的文件，尾部 2MB 是上一次的残留字节。EPUB 是 zip
                --  容器，尾部垃圾会破坏中央目录，产出一个「下载成功、大小看着也对，
                --  但打开就报错」的坏文件。）
                Log.warn("未提供 local_path，无法断点续传，将整包重新下载")
                pcall(function() file_handle:seek("set", 0) end)
            end
        end
        range_sent = range_header ~= nil

        local last_check_time = os.time()
        local last_check_bytes = bytes_downloaded
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
                    -- 必须检查返回值：write 在磁盘写满 / 配额耗尽 / 介质错误时返回 nil, err，
                    -- 视而不见的话 sink 仍会 return 1（表示"接收成功"），最终落盘一个
                    -- 截断的 EPUB（zip 中央目录缺失），而 get_file 报成功。
                    local write_ok, write_err = file_handle:write(chunk)
                    if not write_ok then
                        return nil, "写入文件失败: " .. tostring(write_err)
                    end
                else
                    table.insert(s, chunk)
                end
                
                if progress_callback then
                    progress_callback(bytes_downloaded, total_size)
                end
            end
            return 1 -- 返回非 nil 值表示接收成功
        end

        local req_opts = {
            url      = strategy.url,
            method   = "GET",
            user     = username,
            password = password,
            sink     = custom_sink,
        }
        if range_header then
            req_opts.headers = { ["Range"] = range_header }
        end
        for k, v in pairs(strategy.ssl_opts or {}) do req_opts[k] = v end
        local c, h, st = socket.skip(1, strategy.transport.request(req_opts))
        socketutil:reset_timeout()
        return c, st, s
    end

    local code, status, sink = self:_request_with_fallback(
        "get " .. tostring(path), url, attempt_request)

    -- ------------------------------------------------------------------
    -- 响应处理
    -- ------------------------------------------------------------------

    -- 【带了 Range 的情况必须区分 206 / 416 / 200】三者语义完全不同，
    -- 一律当成功会得到一个「大小看着对、打开就报错」的坏 EPUB。
    if range_sent and type(code) == "number" then
        if code == 416 then
            -- 请求区间不可满足 → 本地文件已经不小于远端（如两次下载并发、
            -- 或上一次其实已下完但没改名）。判成功；调用方会自行核对长度。
            local done_size = (local_path and lfs.attributes(local_path, "size")) or 0
            Log.info("断点续传: 服务器返回 416，本地文件已完整 (" .. tostring(done_size) .. ")")
            return true, nil, file_handle
        elseif code == 200 then
            -- 服务器不支持 Range（返回整包）。此时**追加写入已经把整包粘在半截文件后面**，
            -- 文件已损坏 —— 必须删掉重来，绝不能交给调用方当成成功。
            -- 用专用 err 字符串上报，让 sync.download_epub 以 "wb" 整包重下一次。
            Log.warn("服务器不支持断点续传（Range 请求返回 200），删除损坏的半截文件: "
                .. tostring(local_path))
            if file_handle then
                pcall(function() file_handle:close() end)
            end
            if local_path and local_path ~= "" then
                pcall(os.remove, local_path)
            end
            -- 句柄已随文件一起作废，第 4 项返回 nil，由调用方重新打开
            return false, nil, "RANGE_UNSUPPORTED", nil
        end
    end

    if type(code) ~= "number" then
        Log.error("WebDAV: cannot download file (non-numeric code):", tostring(status or code))
        -- 句柄必须一并交回：重试过程中它可能已被换成新句柄，
        -- 而调用方只持有最初那个 —— 不交回就永久泄漏一个 FILE*。
        return false, "下载失败: " .. tostring(status or code), file_handle
    end

    if code == 404 then
        -- 【不能当成成功】原先这里返回 `true, nil`（「业务成功但无数据」），对该函数的
        -- **流式**用法是致命的：调用方会把自己刚打开（截断过）的文件当成下载结果。
        -- 「列表里有、下载时已被删除/改名」的场景就会得到一个空文件 + 「下载成功」的假提示；
        -- 若还叠加了断点续传，半截文件更会被直接改名成正主。
        -- 统一按失败上报，调用方按需忽略（进度文件读不到本来就是「云端无进度」）。
        Log.info("WebDAV: 文件不存在 (404): " .. tostring(path))
        return false, nil, "远端文件不存在 (HTTP 404)", file_handle
    end

    if code ~= 200 and code ~= 206 then
        Log.error("WebDAV: cannot download file (HTTP " .. code .. "):", status)
        return false, "下载失败 (HTTP " .. code .. ")", file_handle
    end

    if file_handle then
        Log.info("获取文件成功，流式写入完成 (HTTP " .. code .. ")")
        -- 句柄可能因重试被换过，交回调用方关闭，避免新句柄既不落盘也不释放
        return true, nil, file_handle
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

    local username = self:_get_username()
    local password = self:_get_password()

    local function attempt_request(strategy)
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local req = {
            url      = strategy.url,
            method   = "PUT",
            user     = username,
            password = password,
            source   = ltn12.source.string(content),
            headers  = {
                ["Content-Length"] = #content,
            },
        }
        for k, v in pairs(strategy.ssl_opts or {}) do req[k] = v end
        local c, h, st = socket.skip(1, strategy.transport.request(req))
        socketutil:reset_timeout()
        return c, st, nil
    end

    local code, status = self:_request_with_fallback(
        "put " .. tostring(path), url, attempt_request)

    if type(code) == "number" and code >= 200 and code <= 299 then
        Log.info("上传文件成功")
        return true, "上传成功"
    else
        Log.error("WebDAV: cannot upload file:", status or code)
        return false, "上传失败: " .. tostring(status or code)
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

    local username = self:_get_username()
    local password = self:_get_password()

    local function attempt_request(strategy)
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local req = {
            url      = strategy.url,
            method   = "MKCOL",
            user     = username,
            password = password,
        }
        for k, v in pairs(strategy.ssl_opts or {}) do req[k] = v end
        local c, h, st = socket.skip(1, strategy.transport.request(req))
        socketutil:reset_timeout()
        return c, st, nil
    end

    local code, status = self:_request_with_fallback(
        "mkdir " .. tostring(path), url, attempt_request)

    if type(code) == "number" and code >= 200 and code <= 299 then
        Log.info("创建目录成功")
        return true, "创建成功"
    else
        Log.error("WebDAV: cannot create folder:", status or code)
        return false, "创建失败: " .. tostring(status or code)
    end
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

    local data = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/></a:prop></a:propfind>]]

    local username = self:_get_username()
    local password = self:_get_password()

    local function attempt_request(strategy)
        socketutil:set_timeout(15, socketutil.FILE_TOTAL_TIMEOUT)
        local s = {}
        local req = {
            url      = strategy.url,
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
        }
        for k, v in pairs(strategy.ssl_opts or {}) do req[k] = v end
        local c, h, st = socket.skip(1, strategy.transport.request(req))
        socketutil:reset_timeout()
        return c, st, nil
    end

    local code, status = self:_request_with_fallback("test_connection", url, attempt_request)

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
    for __, item in ipairs(items) do
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

return WebDAV
