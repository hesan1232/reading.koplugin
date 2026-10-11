local H = require("reading.helper")
local Log = require("reading.log")

local Bookshelf = {}
Bookshelf.__index = Bookshelf

function Bookshelf:new(settings)
    local obj = {
        settings = settings,
        books = {},
        cache = {},
        name_index = {},      -- 书名 -> book 哈希索引，O(1) 查找
        url_index = {},       -- bookUrl -> book 哈希索引，O(1) 查找
        epub_cache = nil,     -- 本地 EPUB 文件列表缓存
        epub_cache_dirty = true,
        epub_path_cache = nil, -- bookUrl -> epub_path，或 false 表示「查过了、没有」；失效点同 invalidate_epub_cache
        sorted = false,
        toc_cache_mem = {},   -- TOC 内存缓存，避免频繁读盘
        cache_loaded = false, -- 是否已从磁盘确认过缓存状态（单例下用于替代 mtime 比对）
        bookshelf_cache_mtime = 0, -- 书架缓存文件的最后修改时间，避免重复加载
    }
    return setmetatable(obj, self)
end

--- 从同步数据应用到本地书架（替代原 load_sync_data，解耦 Bookshelf 对 Sync 的直接依赖）
-- 策略：以云端数据（Legado）为基准，如果本地存在该书的阅读进度等数据，则合并到云端记录中
-- @param data table  { books, read_records }
function Bookshelf:apply_sync_data(data)
    if not data then return end

    local remote_books = data.books or {}
    
    -- 构建本地现有书架索引（按 bookUrl）
    local local_index = {}
    for __, book in ipairs(self.books) do
        if book.bookUrl and book.bookUrl ~= "" then
            local_index[book.bookUrl] = book
        end
    end

    local merged_bookshelf = {}
    local seen_keys = {}
    local seen_names = {}
    
    for __, remote_book in ipairs(remote_books) do
        -- Legado 书架去重逻辑：主要以 bookUrl 为主，但有时云端脏数据会出现 URL 一样但名字不同的残影。
        -- 采用 (name + author) 组合去重更严谨，避免同名书籍因书源不同产生多条。
        local name = remote_book.name or remote_book.title or ""
        local author = remote_book.author or ""
        
        -- 跳过无用的空书籍（可能是 Legado 生成的脏数据或解析错误）
        if name ~= "" and name ~= "未命名" then
            local unique_key = name .. "|" .. author
            local url = remote_book.bookUrl or ""
            
            if not seen_keys[unique_key] then
                seen_keys[unique_key] = true
                seen_names[name] = true
                
                -- 尝试在本地书架查找此书
                local local_book = local_index[url]
                if local_book then
                    -- 保留本地特有字段 (toc_anchors 已改为独立文件存储，不再保留在书架缓存中)
                    remote_book.is_local_only = local_book.is_local_only
                    remote_book.original_filename = local_book.original_filename
                    
                    -- 比较阅读时间，若本地更新则采用本地进度
                    local remote_time = tonumber(remote_book.durChapterTime) or tonumber(remote_book.lastCheckTime) or 0
                    local local_time = tonumber(local_book.durChapterTime) or tonumber(local_book.lastCheckTime) or 0
                    
                    if local_time > remote_time then
                        Log.debug("apply_sync_data: 使用本地进度覆盖云端: " .. (remote_book.name or ""))
                        remote_book.durChapterIndex = local_book.durChapterIndex
                        remote_book.durChapterPos = local_book.durChapterPos
                        remote_book.durChapterTitle = local_book.durChapterTitle
                        remote_book.durChapterTime = local_book.durChapterTime
                        remote_book.lastCheckTime = local_book.lastCheckTime
                    end
                end
                table.insert(merged_bookshelf, remote_book)
            end
        end
    end

    -- 补充逻辑：保留已被云端删除，但本地已下载（存在EPUB或缓存）的书籍
    --
    -- P1-7 同款优化：原实现对每本「云端已删除」的书调 is_epub_available
    -- → get_epub_for_book → 对**本地全部文件**打分并排序，整体 O(已删书数 × 本地文件数)：
    -- 云端删 300 本、本地 300 个文件时，每次同步都要跑 300 次全量匹配 + 排序。
    -- 改为预建一次索引后 O(1) 查表（与 main.lua show() 的做法对齐）。
    -- 惰性建索引 —— 只有循环里真的遇到「云端已删除的本地书」时才付这一次扫描。
    local downloaded_index = nil
    for __, local_book in ipairs(self.books) do
        local name = local_book.name or local_book.title or ""
        local author = local_book.author or ""
        if name ~= "" and name ~= "未命名" then
            local unique_key = name .. "|" .. author
            if not seen_keys[unique_key] then
                -- 防重复：如果是本地生成的无作者书籍，而云端已同步了同名书籍，则跳过（云端书籍会自动接管本地文件）
                if seen_names[name] and (author == "" or local_book.is_local_only) then
                    Log.debug("apply_sync_data: 跳过重复的本地同名书籍: " .. name)
                else
                    -- 这本书在云端已被删除，检查本地是否有下载（O(1) 查表而非全量匹配）
                    if downloaded_index == nil then
                        downloaded_index = self:build_downloaded_index()
                    end
                    if downloaded_index[name] then
                        Log.debug("apply_sync_data: 保留云端已删但本地已下载的书籍: " .. name)
                        seen_keys[unique_key] = true
                        table.insert(merged_bookshelf, local_book)
                    end
                end
            end
        end
    end

    self.books = merged_bookshelf
    self.sorted = false
    self:rebuild_index()
    -- 注意：不调用 invalidate_epub_cache，因为云端书架数据变化不影响本地 epub 文件列表

    Log.info("加载并合并完成，现存: " .. #self.books .. " 本书")
end

--- 重建书名和URL索引，用于 O(1) 查找
function Bookshelf:rebuild_index()
    self.name_index = {}
    self.url_index = {}
    for __, book in ipairs(self.books) do
        local name = book.name or book.title or ""
        if name ~= "" then
            self.name_index[name:lower()] = book
        end
        if book.bookUrl and book.bookUrl ~= "" then
            self.url_index[book.bookUrl] = book
        end
    end
end

--- 按书名 O(1) 查找书籍
function Bookshelf:get_book_by_name(name)
    if not name or name == "" then return nil end
    return self.name_index[name:lower()]
end

function Bookshelf:sort_books(force_resort)
    if self.sorted and not force_resort then return end

    local sort_order = self.settings:get_shelf_sort()
    -- 方向：nil 时按排序键取默认（书名正序，时间类倒序=最近/最新在前）
    local sort_asc = self.settings:get_shelf_sort_asc()
    if sort_asc == nil then
        sort_asc = (sort_order == "title" or sort_order == "book_name")
    end

    Log.debug("排序方式: " .. sort_order .. (sort_asc and " 正序" or " 倒序"))

    -- 性能优化：在 O(N log N) 的排序循环中，重复执行 or 逻辑和字符串操作会严重消耗 CPU。
    -- 采用 Schwartzian Transform 思想：先 O(N) 预处理出需要用于排序的 key，
    -- 然后排序，避免在 sort_func 里成千上万次地进行 a.name or a.title 计算。
    for __, book in ipairs(self.books) do
        book._sort_name = book.name or book.title or ""
        if sort_order == "last_read" or sort_order == "default" then
            book._sort_time = tonumber(book.durChapterTime) or tonumber(book.lastCheckTime) or 0
        elseif sort_order == "latest_update" then
            book._sort_time = tonumber(book.latestChapterTime) or 0
        end
    end

    local sort_func
    if sort_order == "last_read" or sort_order == "default" or (not sort_order) then
        sort_func = function(a, b)
            if a._sort_time ~= b._sort_time then
                if sort_asc then return a._sort_time < b._sort_time end
                return a._sort_time > b._sort_time
            end
            -- 次键（书名）方向跟随主排序，与云端书库列表一致
            if sort_asc then return a._sort_name < b._sort_name end
            return a._sort_name > b._sort_name
        end
    elseif sort_order == "latest_update" then
        sort_func = function(a, b)
            if a._sort_time ~= b._sort_time then
                if sort_asc then return a._sort_time < b._sort_time end
                return a._sort_time > b._sort_time
            end
            if sort_asc then return a._sort_name < b._sort_name end
            return a._sort_name > b._sort_name
        end
    elseif sort_order == "title" or sort_order == "book_name" then
        sort_func = function(a, b)
            if sort_asc then return a._sort_name < b._sort_name end
            return a._sort_name > b._sort_name
        end
    end
    
    if sort_func then
        table.sort(self.books, sort_func)
    end
    self.sorted = true
end

function Bookshelf:get_books()
    return self.books
end

--- 保存「Legado 侧章节列表」缓存
--
-- ⚠️ 当前没有任何调用方，且**数据源在 Legado 的 WebDAV 备份中并不存在**：
-- Legado 的备份（bookshelf.json / bookProgress/*.json）只含 BookProgress 与 Book 元数据，
-- 没有章节表（章节数据在 Legado 本地 SQLite 的 chapters 表里，不参与 WebDAV 备份）。
-- 相关校验：legado-E-main/app/src/main/java/io/legado/app/help/storage/Backup.kt 的
-- backupFileNames 清单，以及 data/entities/BookProgress.kt / Book.kt 的字段。
--
-- 因此 main.lua 的 _verify_legado_index_by_title / _verify_epub_index_by_title 目前恒返回 nil，
-- _calc_initial_anchors 的第 2 优先级也不会触发（均安全降级，不会出错）。
-- 保留本函数是为了将来接入真正的数据源：把云端 Legado 导出的 EPUB 的 TOC 解析后写入
-- （那才是「手机端纯净目录」），届时上述三条链路会自动恢复工作。
function Bookshelf:save_toc_cache(book_url, chapters)
    local toc_dir = H.get_toc_dir()
    H.make_dir(toc_dir)

    local file_path = H.join_path(toc_dir, H.url_encode(book_url) .. ".json")

    -- 序列化前清理 _find_chapter_by_title 缓存的标题索引字段，避免写入 JSON
    local saved_title_index = chapters._title_index
    local saved_norm_title_index = chapters._norm_title_index
    chapters._title_index = nil
    chapters._norm_title_index = nil

    local toc_data = {
        chapters = chapters,
        saved_at = os.time(),
    }

    local json_data = H.json_encode(toc_data)

    -- 恢复索引字段，避免后续查找需要重新构建
    chapters._title_index = saved_title_index
    chapters._norm_title_index = saved_norm_title_index
    if json_data then
        -- 原子写入：与 save_bookshelf_cache / ReadRecord:save_records 保持一致，
        -- 先写 .tmp 再 rename，避免中途断电留下半截 JSON
        local tmp_path = file_path .. ".tmp"
        local file = io.open(tmp_path, "w")
        if file then
            file:write(json_data)
            file:close()
            local ok, err = os.rename(tmp_path, file_path)
            if ok then
                self.toc_cache_mem[book_url] = chapters
                Log.debug("保存目录缓存: " .. book_url)
                return true
            end
            Log.error("目录缓存重命名失败: " .. tostring(err))
            os.remove(tmp_path)
        end
    end
    
    return false
end

function Bookshelf:load_toc_cache(book_url)
    if self.toc_cache_mem[book_url] then
        return self.toc_cache_mem[book_url]
    end

    local toc_dir = H.get_toc_dir()
    local file_path = H.join_path(toc_dir, H.url_encode(book_url) .. ".json")
    
    if not H.file_exists(file_path) then
        return nil
    end
    
    local file = io.open(file_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        
        local data = H.json_decode(content)
        if data and data.chapters then
            Log.debug("加载目录缓存: " .. book_url)
            self.toc_cache_mem[book_url] = data.chapters
            return data.chapters
        end
    end
    
    return nil
end

function Bookshelf:clear_toc_cache(book_url)
    self.toc_cache_mem[book_url] = nil
    local toc_dir = H.get_toc_dir()
    local file_path = H.join_path(toc_dir, H.url_encode(book_url) .. ".json")
    H.delete_file(file_path)
end

--- 持久化 TOC 偏移量（标题对齐反推校准后的偏移量）
-- 独立于 toc_cache 存储，避免 apply_sync_data 替换 self.books 时丢失
-- @param book_url string         书籍 URL（作为索引键）
-- @param anchors table           锚点表 { {legado=..., epub=..., title=...}, ... }
-- @param epub_path string|nil    当前绑定的 EPUB 文件路径（用于绑定版本）
function Bookshelf:save_toc_anchors(book_url, anchors, epub_path)
    if not book_url or book_url == "" then return false end
    if type(anchors) ~= "table" then return false end

    local offset_dir = H.get_toc_offset_dir()
    H.make_dir(offset_dir)

    local file_path = H.join_path(offset_dir, H.url_encode(book_url) .. ".json")
    local tmp_path = file_path .. ".tmp"

    -- 获取 EPUB 文件的修改时间或大小作为版本指纹
    local epub_fingerprint = ""
    if epub_path and H.file_exists(epub_path) then
        local lfs = require("libs/libkoreader-lfs")
        local ok, attr = pcall(function() return lfs.attributes(epub_path) end)
        if ok and attr then
            epub_fingerprint = tostring(attr.size) .. "_" .. tostring(attr.modification)
        end
    end

    local data = {
        toc_anchors = anchors,
        epub_fingerprint = epub_fingerprint,
        updated_at = os.time(),
    }

    local json_data = H.json_encode(data)
    if not json_data then return false end

    -- 原子写入：先写 .tmp，成功后 rename 覆盖，防止中途断电导致半截文件
    local file = io.open(tmp_path, "w")
    if not file then return false end
    -- ⚠️ write/close 返回值必须检查：否则磁盘满时会 rename 成功地把一个**截断的 JSON**
    -- 换上去 —— 锚点表损坏后两点校准静默失效，进度同步会跳到错误章节。
    local write_ok, write_err = file:write(json_data)
    local close_ok, close_err = file:close()
    if not write_ok or close_ok == nil then
        Log.error("保存 TOC 锚点表失败: 写入/关闭临时文件出错 "
            .. tostring(write_err or close_err))
        os.remove(tmp_path)
        return false
    end

    local ok, err = os.rename(tmp_path, file_path)
    if ok then
        Log.debug("保存 TOC 锚点表: " .. book_url .. " 锚点数=" .. #anchors)
        return true
    end

    Log.error("保存 TOC 锚点表原子重命名失败: " .. tostring(err))
    os.remove(tmp_path)
    return false
end

--- 读取持久化的 TOC 锚点表
-- @param book_url string  书籍 URL
-- @param epub_path string|nil 当前绑定的 EPUB 文件路径（用于校验版本指纹）
-- @return table|nil  锚点表；nil 表示无缓存或版本不匹配
function Bookshelf:load_toc_anchors(book_url, epub_path)
    if not book_url or book_url == "" then return nil end

    local offset_dir = H.get_toc_offset_dir()
    local file_path = H.join_path(offset_dir, H.url_encode(book_url) .. ".json")
    if not H.file_exists(file_path) then return nil end

    local file = io.open(file_path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()

    local data = H.json_decode(content)
    if not data then return nil end

    -- 兼容旧版 toc_offset
    if data.toc_offset and not data.toc_anchors then
        data.toc_anchors = {
            { legado = 0, epub = data.toc_offset, title = data.derived_from_title or "" }
        }
    end

    -- 校验 EPUB 版本指纹，如果不匹配说明书籍已更新或替换，废弃旧缓存
    if epub_path and data.epub_fingerprint and data.epub_fingerprint ~= "" then
        local current_fingerprint = ""
        if H.file_exists(epub_path) then
            local lfs = require("libs/libkoreader-lfs")
            local ok, attr = pcall(function() return lfs.attributes(epub_path) end)
            if ok and attr then
                current_fingerprint = tostring(attr.size) .. "_" .. tostring(attr.modification)
            end
        end
        if current_fingerprint ~= "" and current_fingerprint ~= data.epub_fingerprint then
            Log.warn("加载 TOC 锚点表: EPUB 版本指纹不匹配，废弃旧缓存 (" .. book_url .. ")")
            os.remove(file_path)
            return nil
        end
    end

    local anchors = data.toc_anchors
    if type(anchors) ~= "table" then return nil end

    Log.debug("加载 TOC 锚点表: " .. book_url .. " 锚点数=" .. #anchors)
    return anchors
end

function Bookshelf:get_local_epub_files()
    if self.epub_cache and not self.epub_cache_dirty then
        return self.epub_cache
    end

    local books_dir = H.get_books_dir()
    H.make_dir(books_dir)
    
    local lfs = require("libs/libkoreader-lfs")
    local epub_files = {}
    
    for entry in lfs.dir(books_dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = H.join_path(books_dir, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "file" then
                local book_name = nil
                if entry:match("%.epub$") then
                    book_name = entry:gsub("%.epub$", "")
                elseif entry:match("%.txt$") then
                    book_name = entry:gsub("%.txt$", "")
                end
                
                if book_name then
                    table.insert(epub_files, {
                        name = book_name,
                        filename = entry,
                        path = full_path,
                    })
                end
            end
        end
    end
    
    self.epub_cache = epub_files
    self.epub_cache_dirty = false
    Log.debug("找到本地 EPUB 文件: " .. #epub_files .. " 个")
    return epub_files
end

--- 标记 EPUB 缓存为脏，下次 get_local_epub_files 将重新扫描
function Bookshelf:invalidate_epub_cache()
    self.epub_cache_dirty = true
    -- 路径缓存与文件列表同源（都由本地目录扫描得到），必须一起失效：
    -- 否则「删掉/新增本地文件」后，get_epub_path_cached 仍会返回旧路径，
    -- 锚点落盘就会拿一个不存在的文件去算指纹（指纹恒为空串）。
    self.epub_path_cache = nil
end

--- 统一的书名匹配方法（本地/云端通用）
-- 评分规则：
--   3 分：精确匹配（epub 名去掉扩展名后与书名完全一致）
--   3 分：前缀匹配且 epub 名剩余部分为空（即前缀匹配等价于精确，与 3 分一致）
--   2 分：前缀匹配，且剩余部分以分隔符（空格/下划线/连字符/括号等）开头
--   +1 分：若提供了 book_author 且 epub 名在书名之后的位置包含作者名
-- 取最高分候选；若最高分相同，取第一个。
-- @param book_name 书名（不可空）
-- @param candidates 候选列表，每个元素需有 .name 字段；可选 .path / .size
-- @param book_author 可选，作者名（用于加分）
-- @return matched_candidate, score  无匹配时返回 nil
function Bookshelf:match_all_epubs(book_name, candidates, book_author)
    if not book_name or book_name == "" then return {} end
    if not candidates or #candidates == 0 then return {} end

    local matches = {}
    local book_name_len = #book_name

    for __, epub in ipairs(candidates) do
        local epub_name = epub.name
        if epub_name:sub(-5) == ".epub" then
            epub_name = epub_name:sub(1, -6)
        elseif epub_name:sub(-4) == ".txt" then
            epub_name = epub_name:sub(1, -5)
        end
        
        local score = 0
        local is_match = false

        if epub_name == book_name then
            score = 3
            is_match = true
        else
            if epub_name:sub(1, book_name_len) == book_name then
                local rest = epub_name:sub(book_name_len + 1)
                local separator_pattern = "^[%s_%-：·()（）]"
                if rest == "" then
                    score = 3
                    is_match = true
                elseif rest:match(separator_pattern) then
                    score = 2
                    is_match = true
                end
            end
        end

        if is_match then
            if book_author and book_author ~= "" then
                local author_pos = epub_name:find(book_author, book_name_len + 1, true)
                if author_pos then
                    score = score + 1
                end
            end

            if score > 0 then
                epub.match_score = score
                table.insert(matches, epub)
            end
        end
    end

    table.sort(matches, function(a, b)
        if a.match_score ~= b.match_score then
            return a.match_score > b.match_score
        end
        local mtime_a = tonumber(a.modified) or 0
        local mtime_b = tonumber(b.modified) or 0
        if mtime_a ~= mtime_b then
            return mtime_a > mtime_b
        end
        return (a.name or "") > (b.name or "")
    end)

    return matches
end

--- 匹配单个最佳候选。等价于 match_all_epubs 取排序后的第一个。
--- 原实现是 match_all_epubs 的逐行复制（65 行），两者打分规则必须同步修改，
--- 留着必然漂移，故统一为一次委托。
--- @return matched_candidate|nil, score
function Bookshelf:match_epub(book_name, candidates, book_author)
    local matches = self:match_all_epubs(book_name, candidates, book_author)
    local best = matches and matches[1]
    if not best then return nil, 0 end

    Log.debug(string.format("匹配到书籍: %s -> %s (得分 %d)",
        book_name, best.name, best.match_score or 0))
    return best, best.match_score or 0
end

function Bookshelf:get_epub_for_book(book)
    local book_name = book.name or book.title or ""
    if book_name == "" then return nil end

    local epub_files = self:get_local_epub_files()
    local matched = self:match_epub(book_name, epub_files, book.author)

    if matched then
        return matched.path
    end

    return nil
end

--- 带缓存的「书名 → 本地 EPUB 路径」查询
--
-- 与 get_epub_for_book 的唯一区别是**结果会被缓存**，用于那些只需要路径本身、
-- 不需要实时性的调用（典型是锚点落盘：抓路径只为算 EPUB 版本指纹）。
-- get_epub_for_book 每次都要对本地全部文件打分 + 排序，而锚点落盘由
-- _add_toc_anchor 的 5 秒去抖触发 —— 跨章读下去等于每次都要全量匹配一遍。
--
-- 缓存挂在 **Bookshelf** 上按 bookUrl 索引，而不是挂在 book 对象上：
-- apply_sync_data 每次同步都会用云端对象替换 self.books，挂在 book 上的缓存会随之丢失。
-- 失效点唯一 —— invalidate_epub_cache()（本地文件增删的必经之路）。
--
-- @return string|nil  本地 EPUB 路径；nil 表示本地没有这本书
function Bookshelf:get_epub_path_cached(book)
    if not book then return nil end

    local url = book.bookUrl or ""
    if url == "" then
        -- 无 URL 无法作缓存键，退回实时查询
        return self:get_epub_for_book(book)
    end

    local cache = self.epub_path_cache
    if cache and cache[url] ~= nil then
        local hit = cache[url]
        return hit == false and nil or hit
    end

    -- 存 false 而不是 nil：nil 在表里等同于「没有这个键」，
    -- 会把「查过且没有」也变成每次都重查（那正是要避免的开销）。
    local path = self:get_epub_for_book(book) or false
    if not cache then
        cache = {}
        self.epub_path_cache = cache
    end
    cache[url] = path
    return path == false and nil or path
end

--- 构建「本地文件 → 可能的书名」索引，供书架「仅显示已下载」筛选做 O(1) 查询。
---
--- match_epub 的匹配规则是：本地名 == 书名，或 本地名以「书名 + 分隔符」开头。
--- 这等价于「书名 ∈ 本地文件名在任一分隔符处截断得到的前缀」。所以把这些前缀
--- 一次性收进集合，查询时一次哈希命中即可。
---
--- 复杂度：建索引 O(本地文件名字符总数)，查询 O(1)。
--- 原实现（每本书调 get_epub_for_book）是 O(书架数 × 本地文件数)，1000×1000 时
--- 每次打开书架都要跑约 1e6 次字符串比较。
function Bookshelf:build_downloaded_index()
    local index = {}
    for __, f in ipairs(self:get_local_epub_files()) do
        local n = f.name or ""
        if n ~= "" then
            index[n] = true
            local pos = 1
            while true do
                local sep = n:find("[%s_%-：·()（）]", pos)
                if not sep then break end
                local prefix = n:sub(1, sep - 1)
                if prefix ~= "" then index[prefix] = true end
                pos = sep + 1
            end
        end
    end
    return index
end

function Bookshelf:clear_book_cache(book_url)
    local chapters_dir = H.get_chapters_dir()
    local book_dir = H.join_path(chapters_dir, H.url_encode(book_url))
    H.delete_dir(book_dir)
    self:clear_toc_cache(book_url)
    Log.debug("清除书籍缓存: " .. book_url)
    return true
end

-- ============================================================================
-- 书架缓存持久化
-- ============================================================================
-- 新格式是 **Lua 源码表**（`return {...}`），加载时用 loadfile 直接执行 ——
-- 省掉「读全文 → JSON 反序列化」这两步，大书架（数千本）打开时快得多。
-- 旧格式（bookshelf_cache.json，纯 JSON）**仍然会被读取**：加载侧优先找 .lua，
-- 找不到才退回 .json；一旦新格式成功落盘，旧文件会被删除（避免两份数据并存）。
-- 序列化器优先 KOReader 自带的 `ffi/serpent`（`serpent` 这个模块名在 KOReader 里
-- **不存在** —— 见 frontend/logger.lua、frontend/persist.lua 都写 `ffi/serpent`）；
-- 万一不可用则退回 JSON 文本，加载侧有 `^return` 剥离 + JSON 解码的兜底分支。
local CACHE_FILE_NAME = "bookshelf_cache.lua"
local LEGACY_CACHE_FILE_NAME = "bookshelf_cache.json"

--- @return string 新格式缓存路径, string 旧格式（JSON）缓存路径
local function bookshelf_cache_paths()
    local data_dir = H.get_data_dir()
    return H.join_path(data_dir, CACHE_FILE_NAME),
           H.join_path(data_dir, LEGACY_CACHE_FILE_NAME)
end

--- 序列化书架缓存。返回 (content, is_lua)；content 为 nil 表示两种序列化器都失败。
local function serialize_bookshelf_cache(cache_data)
    local ok, serpent = pcall(require, "ffi/serpent")
    if not ok then
        ok, serpent = pcall(require, "serpent")
    end
    if ok and serpent then
        -- comment=false：serpent 默认会给每个键加 --[[key]] 注释，会让缓存文件体积翻倍
        local ok2, block = pcall(serpent.block, cache_data, { comment = false })
        if ok2 and type(block) == "string" and block ~= "" then
            return "return " .. block, true
        end
        Log.warn("书架缓存 serpent 序列化失败，退回 JSON")
    end

    local json = H.json_encode(cache_data)
    if json then
        return "return " .. json, false
    end
    return nil, false
end

function Bookshelf:save_bookshelf_cache(books)
    local file_path, legacy_path = bookshelf_cache_paths()
    local tmp_path = file_path .. ".tmp"

    books = books or self.books
    -- 防御：仅在「尚未确认过缓存状态」时拒绝空表覆盖。
    -- 场景（双实例时代）：某个实例还没加载过缓存，books 是空表，
    --   onCloseDocument / save_read_progress 拿这个假空表调本函数，会覆盖掉真正的数据。
    -- P0-4 单例化后 books 在 Store.get() 就已加载，cache_loaded 恒为 true；
    --   因此这里不再阻止「用户删掉最后一本书后正常落盘」这一合法空表写入
    --   （旧写法会让删空书架永远无法持久化，缓存文件下次又把它复活）。
    -- 两个路径都算「已有缓存」：升级后第一次写盘时磁盘上可能只有旧 .json。
    if (not books or #books == 0) and not self.cache_loaded
        and (H.file_exists(file_path) or H.file_exists(legacy_path)) then
        Log.warn("save_bookshelf_cache: 缓存状态未知且 books 为空，跳过保存防止覆盖")
        return false
    end

    local cache_data = {
        -- 剔除 _sort_name / _sort_time / _toc_anchors_loaded
        -- 等下划线前缀的瞬态字段，避免它们被写进缓存文件
        books = H.sanitize_for_persist(books),
        saved_at = os.time(),
    }

    local content, is_lua = serialize_bookshelf_cache(cache_data)
    if content then
        -- 原子写入：先写 .tmp 文件，成功后 rename 覆盖目标文件，防止中途断电导致半截文件
        local file = io.open(tmp_path, "w")
        if file then
            -- ⚠️ write/close 返回值必须检查：失败时若不提前返回，rename 会把一个截断的
            -- 缓存换上去，损坏的是**整个书架缓存**（下次启动读到损坏缓存）。
            local write_ok, write_err = file:write(content)
            local close_ok, close_err = file:close()
            if not write_ok or close_ok == nil then
                Log.error("保存书架缓存失败: 写入/关闭临时文件出错 "
                    .. tostring(write_err or close_err))
                os.remove(tmp_path)
                return false
            end
            local ok, err = os.rename(tmp_path, file_path)
            if ok then
                -- 迁移收尾：新格式已落盘，删掉旧 JSON 缓存（否则它会一直躺在 data 目录里）
                if H.file_exists(legacy_path) then
                    pcall(os.remove, legacy_path)
                    Log.info("书架缓存已迁移为 Lua 表格式，删除旧的 " .. LEGACY_CACHE_FILE_NAME)
                end
                local lfs = require("libs/libkoreader-lfs")
                local attr = lfs.attributes(file_path)
                if attr then self.bookshelf_cache_mtime = attr.modification or 0 end
                Log.info("保存书架缓存: " .. #books .. " 本书（"
                    .. (is_lua and "Lua 表" or "JSON 兜底") .. "）")
                return true
            else
                Log.error("原子重命名缓存文件失败: " .. tostring(err))
                os.remove(tmp_path)
            end
        end
    end

    os.remove(tmp_path)
    return false
end

function Bookshelf:load_bookshelf_cache()
    local lua_path, legacy_path = bookshelf_cache_paths()

    -- 优先新格式；退回旧格式（升级后的首次启动）
    local file_path = nil
    if H.file_exists(lua_path) then
        file_path = lua_path
    elseif H.file_exists(legacy_path) then
        file_path = legacy_path
    end

    if not file_path then
        Log.info("书架缓存文件不存在: " .. lua_path)
        -- 没有缓存文件 = 空书架就是真实状态，标记为已确认
        self.cache_loaded = true
        return nil
    end

    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(file_path)
    local current_mtime = attr and attr.modification or 0

    if current_mtime > 0 and current_mtime == self.bookshelf_cache_mtime
        and self.books and #self.books > 0 then
        Log.debug("书架缓存文件未修改，直接返回内存数据")
        return self.books
    end

    -- ① 新格式：Lua 源码表，loadfile 直接编译执行（零 JSON 反序列化）
    local data = nil
    if file_path == lua_path then
        local chunk, load_err = loadfile(file_path)
        if type(chunk) == "function" then
            local ok, result = pcall(chunk)
            if ok and type(result) == "table" then
                data = result
            else
                Log.warn("书架缓存执行失败: " .. tostring(result))
            end
        else
            Log.warn("书架缓存无法编译（文件可能损坏）: " .. tostring(load_err))
        end
    end

    -- ② 兜底：旧 JSON 文件，或 .lua 内容其实是 JSON（历史上文件名复用）时
    if not data then
        local file = io.open(file_path, "r")
        if not file then
            Log.warn("书架缓存文件无法打开: " .. file_path)
            return nil
        end
        local content = file:read("*all")
        file:close()
        data = H.json_decode((content or ""):gsub("^return%s*", ""))
    end

    if not data then
        Log.warn("书架缓存解析失败: " .. file_path)
        return nil
    end
    if not data.books then
        Log.warn("书架缓存缺少 books 字段: " .. file_path)
        return nil
    end

    Log.info("加载书架缓存: " .. #data.books .. " 本书")

    self.books = data.books
    self.sorted = false
    self.cache_loaded = true
    self.bookshelf_cache_mtime = current_mtime
    self:rebuild_index()
    -- 注意：不调用 invalidate_epub_cache，加载书架缓存不改变本地 epub 文件列表
    return data.books
end

return Bookshelf