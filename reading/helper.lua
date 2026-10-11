local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local Log = require("reading.log")

local H = {}

-- JSON 库在**模块加载时**解析一次并提升为 upvalue（参照 async.lua 的写法）。
-- 原实现在 json_encode / json_decode 里每次调用都做一遍 pcall(require, "json")、
-- 失败再试 rapidjson。require 有 package.loaded 缓存所以单次不算贵，但它落在热路径上：
--   · downloader.lua 的 progress_callback 是 WebDAV 的 sink，**每个 chunk 调一次**
--     （20MB 的 EPUB 按 8KB 分块约 2500 次）；
--   · save_bookshelf_cache / upload_book_progress 每次落盘、上传各一次。
-- 解析失败时 _json 保持 nil，两个函数会走「JSON 编码/解码失败」分支（与原行为一致）。
local _json
do
    local ok, json = pcall(require, "json")
    if not ok then
        ok, json = pcall(require, "rapidjson")
    end
    if ok then _json = json end
end

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

function H.url_encode(str)
    if not str then return "" end
    return str:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

function H.json_decode(str)
    if not str then return nil end

    if _json then
        local ok, result = pcall(_json.decode, str)
        if ok then
            return result
        end
    end

    Log.warn("JSON解码失败")
    return nil
end

function H.json_encode(obj)
    if not obj then return nil end

    if _json then
        local ok, result = pcall(_json.encode, obj)
        if ok then
            return result
        end
    end

    Log.warn("JSON编码失败")
    return nil
end

--- 剔除「仅对当前内存实例有意义」的瞬态字段后返回浅拷贝，供写盘使用。
---
--- 约定：瞬态字段一律以下划线开头（_sort_name / _sort_time /
--- _toc_anchors_loaded / _toc_anchors_dirty）。持久字段（name / author /
--- bookUrl / toc_anchors / durChapterIndex / lastCheckTime …）都没有下划线前缀。
---
--- 不做这件事的后果：这些字段会被序列化进书架缓存文件（bookshelf_cache.lua），
--- 并随缓存反复读写，既污染数据文件，也会让「内存态」和「磁盘态」产生虚假的一致感。
--- 原对象不被修改。
function H.sanitize_for_persist(list)
    if type(list) ~= "table" then return list end
    local out = {}
    for i, item in ipairs(list) do
        if type(item) == "table" then
            local copy = {}
            for k, v in pairs(item) do
                if type(k) ~= "string" or k:sub(1, 1) ~= "_" then
                    copy[k] = v
                end
            end
            out[i] = copy
        else
            out[i] = item
        end
    end
    return out
end

function H.get_file_size(path)
    local size = lfs.attributes(path, "size")
    return size or 0
end

--- 文件字节数。与 koobone 的 `H.file_size` **同名** —— 从那边移植过来的
--- dir_size / lru_cleanup / safe_rmtree 直接调它，保持两边可逐行对照。
function H.file_size(path)
    return H.get_file_size(path)
end

--- 递归统计目录占用字节数（只累加文件，目录自身不占空间）。
--- 目录不存在时返回 0（调用方不必先判存在）。
function H.dir_size(dir)
    if not H.dir_exists(dir) then return 0 end
    local total = 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = H.join_path(dir, entry)
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                total = total + H.dir_size(full)
            else
                total = total + H.file_size(full)
            end
        end
    end
    return total
end

--- 递归删除目录（容错版）。koobone 里叫 safe_rmtree，这里保持同名以便对照。
--- 清理缓存是**尽力而为**的事：某个子项删不掉（被占用 / 权限）不该中断整轮清理、
--- 更不该把异常抛给调用方（LRU 清理跑在书架渲染 / 同步回调里，抛出去就是弹错误框）。
function H.safe_rmtree(dir)
    local ok, err = pcall(H.delete_dir, dir)
    if not ok then
        Log.warn("safe_rmtree 失败: " .. tostring(dir) .. " - " .. tostring(err))
    end
end

--- 从完整路径提取文件名（含扩展名），兼容 / 与 \ 分隔符
function H.get_filename(path)
    if not path then return "" end
    return path:match("([^/\\]+)$") or path
end

--- 清理 Legado 重复导出产生的 " (N)" 后缀（如 "书名 (1).epub" → "书名.epub"）。
---
--- Legado 每次重新导出同一本书时，若云端已有同名文件，会自动追加 " (1)"、" (2)"…
--- 后缀。若照原始文件名落盘，「更新书籍」会写成**另一个**文件而不是覆盖旧文件，
--- 本地就留下两份（真机反馈：更新后老书没删除）。去掉后缀后新旧版本同名，
--- io.open(path, "wb") 直接截断重写。
--- 扩展名原样保留；没有后缀的名字不受影响。
function H.clean_legado_filename(filename)
    if not filename or filename == "" then return filename end
    local ext = filename:match("%.[a-zA-Z0-9]+$") or ""
    local base = filename:sub(1, #filename - #ext)
    base = base:gsub("%s*%(%d+%)$", "")
    return base .. ext
end

function H.get_data_dir()
    return DataStorage:getFullDataDir() .. "/reading"
end

function H.get_cache_dir()
    return H.get_data_dir() .. "/cache"
end

--- 封面缓存目录。
-- 注意：当前**没有任何调用方** —— 书架那条封面链路因缺乏数据源（没人写
-- book.cover_path / customCoverUrl，也没有下载封面的代码）已被整体移除，
-- 详见 shelf_view.lua 里的说明。保留本函数是为了将来做封面时
-- 「下载 → 缓存 → 渲染」能直接接着用，**不要按「零调用」当死代码删掉**。
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
-- 存储标题对齐反推出的 toc_anchors，避免每次阅读会话重复计算/漂移
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
            if entry_path:sub(1, #norm_dest) ~= norm_dest then
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
                    local file, open_err = io.open(entry_path, "wb")
                    if file then
                        -- ⚠️ write/close 的返回值必须检查：Lua 的 stdio 是带缓冲的，
                        -- 磁盘写满 / 配额耗尽时 write 往往**不报错**，错误要到 close
                        -- 才暴露（有时甚至只在 flush 时暴露）。只看 io.open 成功就会
                        -- 留下一个「打开成功、内容截断」的文件，后续被当完整文件使用。
                        local write_ok, write_err = file:write(content)
                        local close_ok, close_err = file:close()
                        if not write_ok or close_ok == nil then
                            Log.warn("解压写入失败，已删除半截文件: " .. entry_path
                                .. " (" .. tostring(write_err or close_err) .. ")")
                            os.remove(entry_path)
                        else
                            Log.debug("解压文件: " .. raw_entry)
                        end
                    else
                        Log.warn("无法创建文件: " .. entry_path
                            .. " (" .. tostring(open_err) .. ")")
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

--- LRU 缓存清理（从 koobone 的 `H.lru_cleanup` 移植）。
---
--- 两级淘汰，一次遍历完成：
---   ① **过期**：`atime`（取 `access`，缺失时退回 `modification`）比 `max_age` 更早 → 直接删。
---   ② **超量**：剩余条目总字节数超过 `max_bytes` → 按 atime 从旧到新删，直到降到
---      `max_bytes * 0.8`（留出余量，避免下次刚刚好又超一点就再跑一整轮删除）。
---
--- ⚠️ `opts.filter(name, attr)` 是**必须**的护栏（koobone 版没有这个参数，因为它清的是
--- 插件自有的纯 cache 目录）。本插件要清理的 `books/` 里混着**用户下载的整本书**——
--- 用户数据绝不能被 LRU 当成缓存删掉。凡是清理非纯缓存目录，都要传 filter 把候选
--- 收窄到明确的缓存文件名（例如只认 `*.epub.tmp` 这种半截下载）。
---
--- 全程 pcall 兜底：清理失败只记一条 warn，绝不向调用方抛异常
--- （调用点在书架渲染与同步回调里，抛出去就是一个错误弹窗）。
---
--- @param cache_dir string 目标目录
--- @param opts table
---        max_age    number  最大存活秒数，默认 24h
---        max_bytes  number  总字节上限，默认 512MB
---        filter     function|nil  function(name, attr) -> boolean，返回 true 才是候选
---        label      string|nil  日志前缀，默认 "[ReadingCache]"
function H.lru_cleanup(cache_dir, opts)
    opts = opts or {}
    local max_age = tonumber(opts.max_age) or (24 * 3600)
    local max_bytes = tonumber(opts.max_bytes) or (512 * 1024 * 1024)
    local filter = opts.filter
    local label = opts.label or "[ReadingCache]"

    if not H.dir_exists(cache_dir) then
        return 0
    end

    local now_ts = os.time()
    local entries = {}
    local total_bytes = 0
    local removed = 0

    local ok, err = pcall(function()
        for name in lfs.dir(cache_dir) do
            if name ~= "." and name ~= ".." then
                local p = H.join_path(cache_dir, name)
                local attr_ok, attr = pcall(lfs.attributes, p)
                if attr_ok and attr then
                    local candidate = true
                    if filter then
                        local f_ok, f_res = pcall(filter, name, attr)
                        candidate = f_ok and f_res == true
                    end

                    if candidate then
                        local atime = attr.access or attr.modification or now_ts
                        if max_age > 0 and (now_ts - atime) > max_age then
                            if attr.mode == "directory" then
                                Log.info(label .. " 清理过期目录: " .. name)
                                H.safe_rmtree(p)
                            else
                                Log.info(label .. " 清理过期文件: " .. name)
                                os.remove(p)
                            end
                            removed = removed + 1
                        else
                            local size = 0
                            if attr.mode == "directory" then
                                size = H.dir_size(p)
                            else
                                size = attr.size or 0
                            end
                            total_bytes = total_bytes + size
                            table.insert(entries, {
                                atime = atime, size = size, path = p, name = name,
                            })
                        end
                    end
                end
            end
        end

        if total_bytes > max_bytes then
            -- 删到 80%，避免「刚好压线 → 下次又超一点点 → 又跑一整轮扫描」
            local limit_bytes = math.floor(max_bytes * 0.8)
            table.sort(entries, function(a, b) return a.atime < b.atime end)
            for __, entry in ipairs(entries) do
                if total_bytes <= limit_bytes then break end
                local attr_ok2, attr2 = pcall(lfs.attributes, entry.path)
                if attr_ok2 and attr2 then
                    if attr2.mode == "directory" then
                        Log.info(label .. " 清理最旧目录(超上限): " .. entry.name)
                        H.safe_rmtree(entry.path)
                    else
                        Log.info(label .. " 清理最旧文件(超上限): " .. entry.name)
                        os.remove(entry.path)
                    end
                    removed = removed + 1
                end
                total_bytes = total_bytes - entry.size
            end
        end
    end)

    if not ok then
        Log.warn(label .. " LRU 清理异常: " .. tostring(err))
    end

    return removed
end

return H