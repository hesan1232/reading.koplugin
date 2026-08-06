local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local Log = require("reading.log")

local H = {}

function H.make_dir(path)
    if not path or path == "" then return end
    if H.dir_exists(path) then return end
    
    -- 递归创建父目录
    local parent = path:match("^(.*)[/\\]")
    if parent and parent ~= path then
        H.make_dir(parent)
    end
    
    Log.debug("创建目录: " .. path)
    local ok, err = lfs.mkdir(path)
    if not ok then
        Log.error("创建目录失败: " .. path .. ", 错误: " .. tostring(err))
    end
end

function H.dir_exists(path)
    local mode = lfs.attributes(path, "mode")
    return mode == "directory"
end

function H.file_exists(path)
    local mode = lfs.attributes(path, "mode")
    return mode == "file"
end

function H.delete_file(path)
    if H.file_exists(path) then
        Log.debug("删除文件: " .. path)
        os.remove(path)
    end
end

function H.delete_dir(path)
    if not H.dir_exists(path) then return end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = H.join_path(path, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                H.delete_dir(full_path)
            else
                H.delete_file(full_path)
            end
        end
    end
    lfs.rmdir(path)
end

function H.join_path(...)
    local args = {...}
    local path = args[1]
    for i = 2, #args do
        local part = args[i]
        if path:sub(-1) == "/" then
            path = path .. part
        else
            path = path .. "/" .. part
        end
    end
    return path
end

function H.is_str(value)
    return type(value) == "string"
end

function H.is_tbl(value)
    return type(value) == "table"
end

function H.trim(str)
    if not str then return "" end
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end

function H.url_encode(str)
    if not str then return "" end
    return str:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

function H.json_decode(str)
    if not str then return nil end
    
    local ok, json = pcall(require, "json")
    if not ok then
        ok, json = pcall(require, "rapidjson")
    end
    
    if ok then
        local ok2, result = pcall(json.decode, str)
        if ok2 then
            return result
        end
    end
    
    Log.warn("JSON解码失败")
    return nil
end

function H.json_encode(obj)
    if not obj then return nil end
    
    local ok, json = pcall(require, "json")
    if not ok then
        ok, json = pcall(require, "rapidjson")
    end
    
    if ok then
        local ok2, result = pcall(json.encode, obj)
        if ok2 then
            return result
        end
    end
    
    Log.warn("JSON编码失败")
    return nil
end

function H.download_file(url, save_path)
    return H.download_file_with_headers(url, save_path, {})
end

function H.download_string(url)
    return H.download_string_with_headers(url, {})
end

function H.download_file_with_headers(url, save_path, headers)
    local ltn12 = require("ltn12")
    local default_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    
    url = H.trim(url):gsub("\n", ""):gsub("\r", "")
    
    Log.debug("下载文件: " .. url .. " -> " .. save_path)
    
    local file = io.open(save_path, "wb")
    if not file then
        Log.error("无法打开文件: " .. save_path)
        return false, "无法打开文件: " .. save_path
    end
    
    local is_https = url:find("^https://") == 1
    local http_module
    
    if is_https then
        local ok_ssl, ssl = pcall(require, "ssl.https")
        if ok_ssl then
            http_module = ssl
        else
            file:close()
            Log.warn("HTTPS不可用，无法下载文件: " .. url)
            return false, "SSL不可用"
        end
    else
        http_module = require("socket.http")
    end
    
    local request_options = {
        url = url,
        sink = ltn12.sink.file(file),
        timeout = 30,
        headers = {
            ["User-Agent"] = default_ua,
            ["Referer"] = url:match("^(https?://[^/]+)") or "",
        },
    }
    
    for key, value in pairs(headers or {}) do
        request_options.headers[key] = value
    end
    
    local result, status = http_module.request(request_options)
    
    if status ~= 200 then
        H.delete_file(save_path)
        Log.error("HTTP请求失败: " .. tostring(status))
        return false, "HTTP请求失败: " .. tostring(status)
    end
    
    Log.debug("下载成功")
    return true
end

function H.download_string_with_headers(url, headers)
    local ltn12 = require("ltn12")
    local default_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    
    Log.debug("下载字符串: " .. url)
    
    local data = {}
    
    local is_https = url:find("^https://") == 1
    local http_module
    
    if is_https then
        local ok_ssl, ssl = pcall(require, "ssl.https")
        if ok_ssl then
            http_module = ssl
        else
            Log.warn("HTTPS不可用，无法下载字符串: " .. url)
            return nil, "SSL不可用"
        end
    else
        http_module = require("socket.http")
    end
    
    local request_options = {
        url = url,
        sink = ltn12.sink.table(data),
        timeout = 30,
        headers = {
            ["User-Agent"] = default_ua,
            ["Referer"] = url:match("^(https?://[^/]+)") or "",
        },
    }
    
    for key, value in pairs(headers or {}) do
        request_options.headers[key] = value
    end
    
    local result, status = http_module.request(request_options)
    
    if status ~= 200 then
        Log.error("HTTP请求失败: " .. tostring(status))
        return nil, "HTTP请求失败: " .. tostring(status)
    end
    
    return table.concat(data)
end

function H.get_file_size(path)
    local size = lfs.attributes(path, "size")
    return size or 0
end

--- 从完整路径提取文件名（含扩展名），兼容 / 与 \ 分隔符
function H.get_filename(path)
    if not path then return "" end
    return path:match("([^/\\]+)$") or path
end

function H.get_data_dir()
    return DataStorage:getFullDataDir() .. "/reading"
end

function H.get_cache_dir()
    return H.get_data_dir() .. "/cache"
end

function H.get_covers_dir()
    return H.get_cache_dir() .. "/covers"
end

function H.get_chapters_dir()
    return H.get_cache_dir() .. "/chapters"
end

function H.get_toc_dir()
    return H.get_cache_dir() .. "/toc"
end

--- TOC 偏移量持久化目录（按 book_url 索引的独立 JSON 文件）
-- 存储标题对齐反推出的 toc_offset，避免每次阅读会话重复计算/漂移
function H.get_toc_offset_dir()
    return H.get_cache_dir() .. "/toc_offset"
end

function H.get_sync_dir()
    return H.get_cache_dir() .. "/sync"
end

function H.get_books_dir()
    return H.get_data_dir() .. "/books"
end

function H.format_file_size(bytes)
    if not bytes or bytes <= 0 then
        return "0 MB"
    end
    
    local kb = bytes / 1024
    local mb = kb / 1024
    
    if mb >= 1 then
        return string.format("%.2f MB", mb)
    elseif kb >= 1 then
        return string.format("%.0f KB", kb)
    else
        return string.format("%.0f B", bytes)
    end
end

function H.unzip_file(zip_path, dest_dir)
    Log.debug("解压文件: " .. zip_path .. " -> " .. dest_dir)
    
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok then
        Log.error("无法加载archiver库")
        return false, "无法加载archiver库"
    end
    
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        Log.error("无法打开zip文件: " .. zip_path)
        return false, "无法打开zip文件"
    end
    
    -- 规范化 dest_dir 用于安全检查（确保绝对路径无末尾斜杠变化）
    local norm_dest = dest_dir:gsub("[/\\]+$", "")
    
    H.make_dir(dest_dir)
    
    for entry in arc:iterate() do
        local raw_entry = entry.path
        -- 安全检查：禁止包含 .. 的路径穿越
        if raw_entry:find("%.%.") then
            Log.warn("跳过疑似路径穿越的条目: " .. raw_entry)
        else
            local entry_path = H.join_path(dest_dir, raw_entry)
            -- 二次安全检查：确保解析后的路径仍在 dest_dir 内
            if not entry_path:sub(1, #norm_dest) == norm_dest then
                Log.warn("跳过逃逸目标目录的条目: " .. raw_entry)
            elseif entry.mode == "directory" then
                H.make_dir(entry_path)
            elseif entry.mode == "file" then
                -- 创建父目录
                local parent_dir = entry_path:match("^(.*)[/\\]")
                if parent_dir then
                    H.make_dir(parent_dir)
                end
                
                local content = arc:extractToMemory(entry.path)
                if content then
                    local file = io.open(entry_path, "wb")
                    if file then
                        file:write(content)
                        file:close()
                        Log.debug("解压文件: " .. raw_entry)
                    else
                        Log.warn("无法创建文件: " .. entry_path)
                    end
                else
                    Log.warn("无法提取文件内容: " .. raw_entry)
                end
            end
        end
    end
    
    arc:close()
    Log.debug("解压完成")
    return true
end

return H