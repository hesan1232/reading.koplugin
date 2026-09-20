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
        sorted = false,
        toc_cache_mem = {},   -- TOC 内存缓存，避免频繁读盘
        bookshelf_cache_mtime = 0, -- 书架缓存文件的最后修改时间，避免重复加载
    }
    return setmetatable(obj, self)
end

function Bookshelf:load_sync_data(sync)
    Log.info("加载同步数据")
    self:apply_sync_data(sync:get_sync_data())
    return true
end

--- 从同步数据应用到本地书架（替代原 load_sync_data，解耦 Bookshelf 对 Sync 的直接依赖）
-- @param data table  { books, book_sources, replace_rules, read_records }
function Bookshelf:apply_sync_data(data)
    if not data then return end

    self.books = data.books or {}
    self.sources = data.book_sources or {}
    self.replace_rules = data.replace_rules or {}
    self.sorted = false
    self:rebuild_index()

    Log.info("加载完成: " .. #self.books .. " 本书")
end

--- 重建书名和URL索引，用于 O(1) 查找
function Bookshelf:rebuild_index()
    self.name_index = {}
    self.url_index = {}
    for _, book in ipairs(self.books) do
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

function Bookshelf:sort_books()
    if self.sorted then return end

    local sort_order = self.settings:get_shelf_sort_order()
    
    Log.debug("排序方式: " .. sort_order)
    
    local sort_func
    if sort_order == "last_read" then
        sort_func = function(a, b)
            local time_a = a.durChapterTime or a.lastCheckTime or 0
            local time_b = b.durChapterTime or b.lastCheckTime or 0
            return time_a > time_b
        end
    elseif sort_order == "progress" then
        sort_func = function(a, b)
            local progress_a = (a.durChapterIndex or 0) / (a.totalChapterNum or 1)
            local progress_b = (b.durChapterIndex or 0) / (b.totalChapterNum or 1)
            return progress_a < progress_b
        end
    elseif sort_order == "title" then
        sort_func = function(a, b)
            return (a.name or a.title or "") < (b.name or b.title or "")
        end
    elseif sort_order == "added" then
        sort_func = function(a, b)
            local time_a = a.lastCheckTime or a.durChapterTime or 0
            local time_b = b.lastCheckTime or b.durChapterTime or 0
            return time_a > time_b
        end
    else
        sort_func = function(a, b) return true end
    end
    
    table.sort(self.books, sort_func)
    self.sorted = true
end

function Bookshelf:get_books()
    return self.books
end

function Bookshelf:get_book_by_url(book_url)
    if not book_url or book_url == "" then return nil end
    return self.url_index[book_url]
end

function Bookshelf:_normalize_url(url)
    if not url then return "" end
    local normalized = url:lower()
    normalized = normalized:gsub("^https?://", "")
    normalized = normalized:gsub("^www%.", "")
    normalized = normalized:gsub("/$", "")
    normalized = normalized:gsub("#.*$", "")
    return normalized
end



function Bookshelf:get_progress_text(book)
    local dur_chapter_index = book.durChapterIndex or 0
    local total_chapters = book.totalChapterNum or 0
    
    if total_chapters > 0 then
        if dur_chapter_index >= total_chapters then
            return "已读完"
        else
            return string.format("%d/%d章", dur_chapter_index, total_chapters)
        end
    end
    
    return "未开始"
end

function Bookshelf:get_cover_path(book)
    if not book then return nil end
    
    local covers_dir = H.get_covers_dir()
    H.make_dir(covers_dir)
    
    local cover_url = book.customCoverUrl or book.coverUrl
    if not cover_url then return nil end
    
    local filename = string.gsub(book.name or book.title or "unknown", "[/\\:%*%?\"<>|]", "_") .. ".jpg"
    local cover_path = H.join_path(covers_dir, filename)
    
    if H.file_exists(cover_path) then
        local lfs = require("libs/libkoreader-lfs")
        local ok, attr = pcall(function()
            return lfs.attributes(cover_path)
        end)
        if ok and attr and attr.size and attr.size > 0 then
            return cover_path
        else
            os.remove(cover_path)
        end
    end
    
    if not self.settings:should_download_covers() then
        return nil
    end
    
    local ok, err = H.download_file(cover_url, cover_path)
    if ok then
        local lfs = require("libs/libkoreader-lfs")
        local attr_ok, attr = pcall(function()
            return lfs.attributes(cover_path)
        end)
        if attr_ok and attr and attr.size and attr.size > 0 then
            return cover_path
        else
            os.remove(cover_path)
        end
    end
    
    return nil
end

function Bookshelf:save_toc_cache(book_url, chapters)
    local toc_dir = H.get_toc_dir()
    H.make_dir(toc_dir)
    
    local file_path = H.join_path(toc_dir, H.url_encode(book_url) .. ".json")
    
    local toc_data = {
        chapters = chapters,
        saved_at = os.time(),
    }
    
    local json_data = H.json_encode(toc_data)
    if json_data then
        local file = io.open(file_path, "w")
        if file then
            file:write(json_data)
            file:close()
            self.toc_cache_mem[book_url] = chapters
            Log.debug("保存目录缓存: " .. book_url)
            return true
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
-- @param offset number           偏移量（epub_1based = legado_0based + offset）
-- @param derived_from_title string|nil  反推依据的章节标题（用于排查）
function Bookshelf:save_toc_offset(book_url, offset, derived_from_title)
    if not book_url or book_url == "" then return false end
    offset = tonumber(offset)
    if not offset then return false end

    local offset_dir = H.get_toc_offset_dir()
    H.make_dir(offset_dir)

    local file_path = H.join_path(offset_dir, H.url_encode(book_url) .. ".json")
    local tmp_path = file_path .. ".tmp"

    local data = {
        toc_offset = offset,
        derived_from_title = derived_from_title or "",
        updated_at = os.time(),
    }

    local json_data = H.json_encode(data)
    if not json_data then return false end

    -- 原子写入：先写 .tmp，成功后 rename 覆盖，防止中途断电导致半截文件
    local file = io.open(tmp_path, "w")
    if not file then return false end
    file:write(json_data)
    file:close()

    local ok, err = os.rename(tmp_path, file_path)
    if ok then
        Log.debug("保存 TOC 偏移量: " .. book_url .. " offset=" .. offset)
        return true
    end

    Log.error("保存 TOC 偏移量原子重命名失败: " .. tostring(err))
    os.remove(tmp_path)
    return false
end

--- 读取持久化的 TOC 偏移量
-- @param book_url string  书籍 URL
-- @return number|nil  偏移量；nil 表示无缓存
function Bookshelf:load_toc_offset(book_url)
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

    local offset = tonumber(data.toc_offset)
    if not offset then return nil end

    Log.debug("加载 TOC 偏移量: " .. book_url .. " offset=" .. offset)
    return offset
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
function Bookshelf:match_epub(book_name, candidates, book_author)
    if not book_name or book_name == "" then return nil end
    if not candidates or #candidates == 0 then return nil end

    local best_match = nil
    local best_score = 0

    for _, epub in ipairs(candidates) do
        -- 统一去掉扩展名（兼容 .epub / .txt）
        local epub_name = epub.name:gsub("%.epub$", ""):gsub("%.txt$", "")

        local score = 0

        if epub_name == book_name then
            -- 精确匹配
            score = 3
        else
            -- 前缀匹配：epub 名以书名开头（用 sub 避免 Lua 模式注入）
            if epub_name:sub(1, #book_name) == book_name then
                local rest = epub_name:sub(#book_name + 1)
                local separator_pattern = "^[%s_%-：·()（）]"
                if rest == "" then
                    score = 3
                elseif rest:match(separator_pattern) then
                    score = 2
                else
                    -- 书名是前缀但后面紧跟非分隔符（如书名"斗罗"匹配到"斗罗大陆"），不算匹配
                    goto continue
                end
            else
                goto continue
            end
        end

        -- 作者名加分：在书名之后的位置查找作者名
        if book_author and book_author ~= "" then
            local author_pos = epub_name:find(book_author, book_name:len() + 1, true)
            if author_pos then
                score = score + 1
            end
        end

        if score > best_score then
            best_score = score
            best_match = epub
        end

        ::continue::
    end

    if best_match then
        Log.debug(string.format("匹配到书籍: %s -> %s (得分 %d)", book_name, best_match.name, best_score))
    end

    return best_match, best_score
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

function Bookshelf:is_epub_available(book)
    return self:get_epub_for_book(book) ~= nil
end

function Bookshelf:load_chapter_cache(book_url)
    local chapters_dir = H.get_chapters_dir()
    local book_dir = H.join_path(chapters_dir, H.url_encode(book_url))
    
    if not H.dir_exists(book_dir) then
        return {}
    end
    
    local lfs = require("libs/libkoreader-lfs")
    local cached = {}
    
    for entry in lfs.dir(book_dir) do
        if entry ~= "." and entry ~= ".." then
            local file_path = H.join_path(book_dir, entry)
            local mode = lfs.attributes(file_path, "mode")
            if mode == "file" then
                local chapter_index = entry:match("^(.-)%.html$")
                if chapter_index then
                    local file = io.open(file_path, "r")
                    if file then
                        cached[chapter_index] = file:read("*all")
                        file:close()
                    end
                end
            end
        end
    end
    
    return cached
end

function Bookshelf:save_chapter_cache(book_url, chapter_index, content)
    local chapters_dir = H.get_chapters_dir()
    local book_dir = H.join_path(chapters_dir, H.url_encode(book_url))
    
    H.make_dir(book_dir)
    
    local file_path = H.join_path(book_dir, chapter_index .. ".html")
    local file = io.open(file_path, "w")
    if file then
        file:write(content)
        file:close()
        Log.debug("保存章节缓存: " .. book_url .. " 章节 " .. chapter_index)
        return true
    end
    
    return false
end

function Bookshelf:get_chapter_cache(book_url, chapter_index)
    local chapters_dir = H.get_chapters_dir()
    local book_dir = H.join_path(chapters_dir, H.url_encode(book_url))
    local file_path = H.join_path(book_dir, chapter_index .. ".html")
    
    if H.file_exists(file_path) then
        local file = io.open(file_path, "r")
        if file then
            local content = file:read("*all")
            file:close()
            return content
        end
    end
    
    return nil
end

function Bookshelf:clear_book_cache(book_url)
    local chapters_dir = H.get_chapters_dir()
    local book_dir = H.join_path(chapters_dir, H.url_encode(book_url))
    H.delete_dir(book_dir)
    self:clear_toc_cache(book_url)
    Log.debug("清除书籍缓存: " .. book_url)
    return true
end

function Bookshelf:save_bookshelf_cache(books)
    local data_dir = H.get_data_dir()
    local file_path = H.join_path(data_dir, "bookshelf_cache.json")
    local tmp_path = file_path .. ".tmp"

    books = books or self.books
    -- 防御：books 为空但缓存文件已存在时，拒绝覆盖。
    -- 场景：ReaderUI 实例未加载书架缓存，onCloseDocument/save_read_progress
    --       传空 books 调用本函数，会覆盖掉有数据的缓存，导致下次打开书架空白。
    if (not books or #books == 0) and H.file_exists(file_path) then
        Log.warn("save_bookshelf_cache: books 为空但缓存文件已存在，跳过保存防止覆盖")
        return false
    end

    local cache_data = {
        books = books,
        sources = self.sources,
        replace_rules = self.replace_rules,
        saved_at = os.time(),
    }

    local json_data = H.json_encode(cache_data)
    if json_data then
        -- 原子写入：先写 .tmp 文件，成功后 rename 覆盖目标文件，防止中途断电导致半截文件
        local file = io.open(tmp_path, "w")
        if file then
            file:write(json_data)
            file:close()
            local ok, err = os.rename(tmp_path, file_path)
            if ok then
                local lfs = require("libs/libkoreader-lfs")
                local attr = lfs.attributes(file_path)
                if attr then self.bookshelf_cache_mtime = attr.modification or 0 end
                Log.info("保存书架缓存: " .. #books .. " 本书")
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
    local data_dir = H.get_data_dir()
    local file_path = H.join_path(data_dir, "bookshelf_cache.json")

    if not H.file_exists(file_path) then
        Log.info("书架缓存文件不存在: " .. file_path)
        return nil
    end

    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(file_path)
    local current_mtime = attr and attr.modification or 0
    
    if current_mtime > 0 and current_mtime == self.bookshelf_cache_mtime and self.books and #self.books > 0 then
        Log.debug("书架缓存文件未修改，直接返回内存数据")
        return self.books
    end

    local file = io.open(file_path, "r")
    if not file then
        Log.warn("书架缓存文件无法打开: " .. file_path)
        return nil
    end
    local content = file:read("*all")
    file:close()

    local data = H.json_decode(content)
    if not data then
        Log.warn("书架缓存 JSON 解析失败: " .. file_path)
        return nil
    end
    if not data.books then
        Log.warn("书架缓存缺少 books 字段: " .. file_path)
        return nil
    end

    Log.info("加载书架缓存: " .. #data.books .. " 本书")

    if data.sources then
        self.sources = data.sources
        Log.info("加载缓存书源: " .. #self.sources .. " 个")
    end

    if data.replace_rules then
        self.replace_rules = data.replace_rules
        Log.info("加载缓存替换规则: " .. #self.replace_rules .. " 条")
    end

    self.books = data.books
    self.sorted = false
    self.bookshelf_cache_mtime = current_mtime
    self:rebuild_index()
    self:invalidate_epub_cache()
    return data.books
end

return Bookshelf