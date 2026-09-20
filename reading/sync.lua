local H = require("reading.helper")
local Log = require("reading.log")
local WebDAV = require("reading.webdav")

local Sync = {}
Sync.__index = Sync

function Sync:new(settings)
    local obj = {
        settings = settings,
        bookshelf = {},
        book_sources = {},
        replace_rules = {},
        read_records = {},
        webdav = WebDAV:new(settings),
    }
    return setmetatable(obj, self)
end

function Sync:download_sync_file(url)
    Log.debug("开始下载同步文件: " .. url)
    
    local data, err = H.download_string(url)
    if not data then
        Log.error("下载失败: " .. err)
        return false, err
    end
    
    Log.debug("下载成功，数据大小: " .. #data)
    return true, data
end

function Sync:download_sync_zip(url)
    Log.debug("开始下载同步zip文件: " .. url)
    
    local sync_dir = H.get_sync_dir()
    H.make_dir(sync_dir)
    
    local zip_path = H.join_path(sync_dir, "sync_backup.zip")
    
    local ok, err = H.download_file(url, zip_path)
    if not ok then
        Log.error("下载zip失败: " .. err)
        return false, err
    end
    
    Log.debug("zip文件下载成功")
    return true, zip_path
end

function Sync:extract_zip(zip_path)
    Log.debug("开始解压zip文件: " .. zip_path)
    
    local sync_dir = H.get_sync_dir()
    local extract_dir = H.join_path(sync_dir, "extracted")
    
    H.delete_dir(extract_dir)
    
    local ok, err = H.unzip_file(zip_path, extract_dir)
    if not ok then
        Log.error("解压失败: " .. err)
        return false, err
    end
    
    Log.debug("解压成功，目录: " .. extract_dir)
    return true, extract_dir
end

function Sync:parse_backup(data)
    Log.debug("开始解析备份数据")
    
    local files = {}
    
    local current_file = nil
    local current_content = {}
    
    for line in data:gmatch("[^\n]+") do
        local trimmed_line = line:gsub("^%s+", ""):gsub("%s+$", "")
        
        local start_pos = trimmed_line:find("^%-%-%-")
        local end_pos = trimmed_line:find("%-%-%-$")
        
        if start_pos and end_pos then
            local filename = trimmed_line:sub(4, end_pos - 1)
            if current_file then
                files[current_file] = table.concat(current_content, "\n")
            end
            current_file = filename
            current_content = {}
        elseif current_file then
            table.insert(current_content, trimmed_line)
        end
    end
    
    if current_file then
        files[current_file] = table.concat(current_content, "\n")
    end
    
    local file_count = 0
    for _ in pairs(files) do file_count = file_count + 1 end
    Log.debug("解析完成，找到 " .. file_count .. " 个文件")
    return files
end

function Sync:load_from_extracted_dir(extract_dir)
    Log.debug("从解压目录加载数据: " .. extract_dir)
    
    self.bookshelf = {}
    self.book_sources = {}
    self.replace_rules = {}
    self.read_records = {}
    
    local lfs = require("libs/libkoreader-lfs")
    
    for entry in lfs.dir(extract_dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = H.join_path(extract_dir, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "file" then
                Log.debug("处理文件: " .. entry)
                
                local file = io.open(full_path, "r")
                if file then
                    local content = file:read("*all")
                    file:close()
                    
                    local data = H.json_decode(content)
                    if data and type(data) == "table" then
                        if entry == "bookshelf.json" then
                            for _, book in ipairs(data) do
                                table.insert(self.bookshelf, book)
                            end
                            Log.info("加载书架: " .. #self.bookshelf .. " 本书")
                        elseif entry == "bookSource.json" then
                            for _, source in ipairs(data) do
                                table.insert(self.book_sources, source)
                            end
                            Log.info("加载书源: " .. #self.book_sources .. " 个")
                        elseif entry == "replaceRule.json" then
                            for _, rule in ipairs(data) do
                                if rule.isEnabled ~= false then
                                    table.insert(self.replace_rules, rule)
                                end
                            end
                            Log.info("加载替换规则: " .. #self.replace_rules .. " 条")
                        elseif entry == "readRecord.json" then
                            for _, record in ipairs(data) do
                                table.insert(self.read_records, record)
                            end
                            Log.info("加载阅读记录: " .. #self.read_records .. " 条")
                        end
                    else
                        Log.warn("文件解析失败: " .. entry)
                    end
                else
                    Log.warn("无法打开文件: " .. entry)
                end
            end
        end
    end
    
    return true
end

function Sync:load_from_files(files)
    Log.debug("从文件表加载数据")
    
    self.bookshelf = {}
    self.book_sources = {}
    self.replace_rules = {}
    self.read_records = {}
    
    if files["bookshelf.json"] then
        local data = H.json_decode(files["bookshelf.json"])
        if data and type(data) == "table" then
            for _, book in ipairs(data) do
                table.insert(self.bookshelf, book)
            end
            Log.info("加载书架: " .. #self.bookshelf .. " 本书")
        end
    end
    
    if files["bookSource.json"] then
        local data = H.json_decode(files["bookSource.json"])
        if data and type(data) == "table" then
            for _, source in ipairs(data) do
                table.insert(self.book_sources, source)
            end
            Log.info("加载书源: " .. #self.book_sources .. " 个")
        end
    end
    
    if files["replaceRule.json"] then
        local data = H.json_decode(files["replaceRule.json"])
        if data and type(data) == "table" then
            for _, rule in ipairs(data) do
                if rule.isEnabled ~= false then
                    table.insert(self.replace_rules, rule)
                end
            end
            Log.info("加载替换规则: " .. #self.replace_rules .. " 条")
        end
    end

    if files["readRecord.json"] then
        local data = H.json_decode(files["readRecord.json"])
        if data and type(data) == "table" then
            for _, record in ipairs(data) do
                table.insert(self.read_records, record)
            end
            Log.info("加载阅读记录: " .. #self.read_records .. " 条")
        end
    end
    
    return true
end

function Sync:get_bookshelf()
    return self.bookshelf
end

function Sync:get_sync_data()
    return {
        books = self.bookshelf,
        book_sources = self.book_sources,
        replace_rules = self.replace_rules,
        read_records = self.read_records,
    }
end

function Sync:get_book_sources()
    return self.book_sources
end

function Sync:get_replace_rules()
    return self.replace_rules
end

function Sync:get_read_records()
    return self.read_records
end

function Sync:list_books_directory()
    Log.info("列出 legado/books 目录")
    
    -- webdav:list 已保证 no-throw，返回 (ok, result, err) 三元组
    local ok, items, err = self.webdav:list("books")
    if not ok then
        Log.error("列出legado/books目录失败: " .. tostring(err))
        return false, nil, err
    end
    
    local epub_files = {}
    for _, item in ipairs(items) do
        if item.name and item.name:match("%.epub$") then
            table.insert(epub_files, {
                name = item.name,
                path = "books/" .. item.name,
                size = item.size,
                modified = item.modified,
            })
        end
    end
    
    Log.info("找到 " .. #epub_files .. " 个 EPUB 文件")
    return true, epub_files, nil
end

function Sync:list_book_progress_directory()
    Log.info("列出 bookProgress 目录")
    
    local ok, items, err = self.webdav:list("bookProgress")
    if not ok then
        Log.error("列出bookProgress目录失败: " .. tostring(err))
        return false, nil, err
    end
    
    local progress_files = {}
    for _, item in ipairs(items) do
        if item.name and item.name:match("%.json$") then
            table.insert(progress_files, {
                name = item.name,
                path = "bookProgress/" .. item.name,
                modified = item.modified,
            })
        end
    end
    
    Log.info("找到 " .. #progress_files .. " 个进度文件")
    return true, progress_files, nil
end

function Sync:get_book_progress(book_name, book_author)
    -- 返回 (ok, result, err) 三元组：
    --   true,  data, nil   —— 找到进度
    --   true,  nil,  nil   —— 成功但云端无进度
    --   false, nil,  err   —— 失败
    if book_name == "" then
        Log.warn("书名为空，无法获取进度")
        return false, nil, "书名为空"
    end
    
    Log.info("尝试获取书籍进度，书名: " .. book_name .. ", 作者: " .. book_author)
    
    local candidates = {}
    if book_author ~= "" then
        table.insert(candidates, book_name .. "_" .. book_author .. ".json")
    end
    table.insert(candidates, book_name .. ".json")
    
    for i, candidate in ipairs(candidates) do
        local file_name_encoded = self:_normalize_file_name(candidate)
        
        Log.debug("尝试进度文件 [" .. i .. "/" .. #candidates .. "]: " .. file_name_encoded)
        
        local ok, content, err = self.webdav:get_file("bookProgress/" .. file_name_encoded)
        if ok and content then
            Log.info("找到进度文件: " .. file_name_encoded)
            Log.debug("进度文件内容长度: " .. #content)
            
            local data = H.json_decode(content)
            if data then
                Log.debug("解析进度成功: chapter=" .. tostring(data.durChapterIndex) .. ", pos=" .. tostring(data.durChapterPos))
                return true, data, nil
            else
                Log.warn("解析进度数据失败，内容: " .. content:sub(1, 100))
            end
        else
            Log.debug("进度文件不存在: " .. file_name_encoded .. ", 错误: " .. tostring(err))
        end
    end
    
    Log.debug("尝试通过目录列表查找进度文件（使用精确匹配策略）")
    
    local ok_list, progress_files, err_list = self:list_book_progress_directory()
    if not ok_list then
        Log.warn("列出进度目录失败: " .. tostring(err_list))
        return false, nil, err_list
    elseif not progress_files or #progress_files == 0 then
        Log.debug("进度目录为空")
        return true, nil, nil
    else
        Log.debug("进度目录中有 " .. #progress_files .. " 个文件")
        local best_match = nil
        local best_score = 0
        local normalized_book_name = self:_normalize_file_name(book_name)
        local normalized_author = book_author and book_author ~= "" and self:_normalize_file_name(book_author) or ""
        
        for _, file_info in ipairs(progress_files) do
            local file_name = file_info.name or ""
            local file_base = file_name:gsub("%.json$", "")
            
            local score = 0
            
            if file_base == normalized_book_name then
                score = 3
            elseif file_base == normalized_book_name .. "_" .. normalized_author and normalized_author ~= "" then
                score = 4
            else
                local separator_pattern = "^[%s_%-：·()（）]"
                if file_base:sub(1, #normalized_book_name) == normalized_book_name then
                    local rest = file_base:sub(#normalized_book_name + 1)
                    if rest == "" then
                        score = 3
                    elseif rest:match("^[_%-]") then
                        score = 2
                        if normalized_author ~= "" and rest:find(normalized_author, 2, true) then
                            score = score + 1
                        end
                    end
                end
            end
            
            if score > best_score then
                best_score = score
                best_match = file_info
            end
        end
        
        if best_match and best_score >= 2 then
            Log.info("通过目录匹配到进度文件: " .. best_match.name .. " (得分: " .. best_score .. ")")
            local ok_get, content, err_get = self.webdav:get_file(best_match.path)
            if ok_get and content then
                local data = H.json_decode(content)
                if data then
                    return true, data, nil
                else
                    Log.warn("解析进度数据失败")
                end
            else
                Log.debug("获取文件失败: " .. best_match.name .. ", err: " .. tostring(err_get))
            end
        end
    end
    
    Log.info("未找到书籍进度文件（云端无此书进度）")
    return true, nil, nil
end

function Sync:download_all_book_progress()
    local ok, progress_files, err = self:list_book_progress_directory()
    if not ok then
        return false, nil, err
    end
    
    local progress_map = {}
    for _, file in ipairs(progress_files) do
        local ok2, content, err2 = self.webdav:get_file(file.path)
        if ok2 then
            local data = H.json_decode(content)
            if data and data.name then
                progress_map[data.name .. "_" .. (data.author or "")] = data
            end
        else
            Log.debug("下载进度文件失败: " .. file.name .. ", err: " .. tostring(err2))
        end
    end
    
    return true, progress_map, nil
end

function Sync:_normalize_file_name(name)
    -- 将特殊字符替换为 "_"，并将连续的 "_" 合并为一个，同时去除首尾的 "_"
    return name:gsub("[\\/:*?\"<>|]", "_")
               :gsub("_+", "_")
               :gsub("^_", "")
               :gsub("_$", "")
end

function Sync:upload_book_progress(book_name, book_author, chapter_index, chapter_pos, chapter_title)
    local file_name = nil

    if book_name ~= "" then
        if book_author ~= "" then
            file_name = book_name .. "_" .. book_author .. ".json"
        else
            file_name = book_name .. ".json"
        end
    end

    if not file_name then
        Log.error("无法生成进度文件名")
        return false, nil, "无法生成进度文件名"
    end

    local file_name_encoded = self:_normalize_file_name(file_name)

    Log.info("上传书籍进度: " .. file_name_encoded)
    Log.debug("原始文件名: " .. file_name)
    Log.debug("标准化后文件名: " .. file_name_encoded)

    local progress_data = {
        name = book_name,
        author = book_author,
        durChapterIndex = chapter_index,
        durChapterPos = chapter_pos,
        durChapterTitle = chapter_title,
        durChapterTime = os.time() * 1000,
    }

    local json_content = H.json_encode(progress_data)

    Log.debug("上传路径: bookProgress/" .. file_name_encoded)

    -- 确保 bookProgress 目录存在（首次上传时目录可能不存在）
    self:_ensure_directory_exists("bookProgress")

    local ok, __, err = self.webdav:put_file("bookProgress/" .. file_name_encoded, json_content)
    if not ok then
        Log.error("上传进度失败: " .. tostring(err))
        return false, nil, err
    end

    Log.info("进度上传成功")
    return true, "上传成功", nil
end

--- 确保远程目录存在，不存在则创建（幂等操作）
function Sync:_ensure_directory_exists(dir_name)
    local ok = self.webdav:mkdir(dir_name)
    if ok then
        Log.info("目录已创建或已存在: " .. dir_name)
    else
        -- mkdir 失败可能是因为目录已存在，忽略错误
        Log.debug("目录创建结果(可能已存在): " .. dir_name)
    end
end

function Sync:download_epub(epub_path, save_path, force_overwrite, remote_size, progress_callback)
    Log.info("下载 EPUB 文件: " .. epub_path)
    
    local local_size = 0
    if H.file_exists(save_path) then
        local lfs = require("libs/libkoreader-lfs")
        local attr = lfs.attributes(save_path)
        if attr then
            local_size = attr.size or 0
        end
    end
    
    if not force_overwrite and remote_size and H.file_exists(save_path) and local_size >= remote_size then
        Log.info("本地文件已存在且大小相同或更大，跳过下载: " .. save_path)
        return true, save_path, "skipped"
    end
    
    local books_dir = H.get_books_dir()
    H.make_dir(books_dir)
    
    local file = io.open(save_path, "wb")
    if not file then
        Log.error("无法打开文件: " .. save_path)
        return false, nil, "无法打开文件"
    end
    
    local ok, content, err = self.webdav:get_file(epub_path, progress_callback, remote_size, file)
    
    file:close()
    
    if not ok then
        Log.error("下载EPUB失败: " .. tostring(err))
        -- 下载失败时删除可能不完整的文件
        os.remove(save_path)
        return false, nil, err
    end
    
    Log.info("EPUB下载成功: " .. save_path)
    return true, save_path, "downloaded"
end

function Sync:sync_from_url(url)
    Log.info("开始同步数据: " .. url)
    
    if url:match("%.zip$") then
        return self:sync_from_zip_url(url)
    end
    
    local ok, data = self:download_sync_file(url)
    if not ok then
        return false, data
    end
    
    local files = self:parse_backup(data)
    self:load_from_files(files)
    
    self.settings:set_last_sync_time(os.time())
    self.settings:flush()
    
    Log.info("同步完成")
    return true, "同步成功"
end

function Sync:sync_from_zip_url(url)
    Log.info("开始从zip文件同步")
    
    local ok, zip_path = self:download_sync_zip(url)
    if not ok then
        return false, zip_path
    end
    
    local ok2, extract_dir = self:extract_zip(zip_path)
    if not ok2 then
        return false, extract_dir
    end
    
    self:load_from_extracted_dir(extract_dir)
    
    self.settings:set_last_sync_time(os.time())
    self.settings:flush()
    
    Log.info("zip同步完成")
    return true, "同步成功"
end

function Sync:get_book_by_url(book_url)
    for _, book in ipairs(self.bookshelf) do
        if book.bookUrl == book_url then
            return book
        end
    end
    return nil
end

function Sync:get_source_by_url(url)
    for _, source in ipairs(self.book_sources) do
        local source_url = source.bookSourceUrl
        if source_url and (url:find(source_url, 1, true) or source_url:find(url, 1, true)) then
            return source
        end
    end
    return nil
end

function Sync:get_used_source_for_book(book)
    if not book or not book.origin then
        return nil
    end
    return self:get_source_by_url(book.origin)
end

function Sync:sync_from_webdav()
    Log.info("开始从WebDAV同步")
    
    local ok2, content, filename = self.webdav:get_backup_file()
    if not ok2 then
        Log.error("获取备份文件失败: " .. tostring(filename))
        return false, nil, tostring(filename)
    end
    
    Log.info("获取到备份文件: " .. filename .. ", 大小: " .. #content)
    
    if filename:match("%.zip$") then
        local sync_dir = H.get_sync_dir()
        Log.debug("同步目录: " .. sync_dir)
        
        H.make_dir(sync_dir)
        Log.debug("目录创建完成")
        
        local zip_path = H.join_path(sync_dir, "sync_backup.zip")
        Log.debug("准备保存到: " .. zip_path)
        
        local file, io_err = io.open(zip_path, "wb")
        if file then
            local bytes_written, write_err = file:write(content)
            file:close()
            
            if bytes_written then
                Log.info("zip文件保存成功，写入字节数: " .. #content)
                
                local ok3, extract_dir = self:extract_zip(zip_path)
                if not ok3 then
                    Log.error("解压失败: " .. tostring(extract_dir))
                    return false, nil, tostring(extract_dir)
                end
                
                Log.info("解压成功，目录: " .. extract_dir)
                self:load_from_extracted_dir(extract_dir)
            else
                Log.error("写入文件失败: " .. tostring(write_err))
                return false, nil, "写入文件失败: " .. tostring(write_err)
            end
        else
            Log.error("无法打开文件: " .. zip_path .. ", 错误: " .. tostring(io_err))
            return false, nil, "无法保存zip文件: " .. tostring(io_err)
        end
    else
        local files = self:parse_backup(content)
        self:load_from_files(files)
    end
    
    self.settings:set_last_sync_time(os.time())
    self.settings:flush()
    
    Log.info("WebDAV同步完成")
    return true, "同步成功", nil
end

function Sync:upload_to_webdav(book_url)
    Log.info("上传进度到WebDAV")
    
    local records = {}
    if book_url then
        for _, record in ipairs(self.read_records) do
            if record.bookUrl == book_url then
                table.insert(records, record)
            end
        end
    else
        records = self.read_records
    end
    
    if #records == 0 then
        return false, nil, "没有找到阅读记录"
    end
    
    local json_data = H.json_encode(records)
    if not json_data then
        return false, nil, "JSON编码失败"
    end
    
    local filename = "readRecord_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
    local ok2, __, err2 = self.webdav:upload_backup_file(filename, json_data)
    if not ok2 then
        return false, nil, err2
    end
    
    return true, "上传成功", nil
end

function Sync:upload_full_backup()
    Log.info("上传完整备份到WebDAV")
    
    local backup_data = {
        bookshelf = self.bookshelf,
        readRecord = self.read_records,
    }
    
    local json_data = H.json_encode(backup_data)
    if not json_data then
        return false, nil, "JSON编码失败"
    end
    
    local filename = "backup" .. os.date("%Y-%m-%d") .. ".json"
    local ok2, __, err2 = self.webdav:upload_backup_file(filename, json_data)
    if not ok2 then
        return false, nil, err2
    end
    
    return true, "备份上传成功", nil
end

function Sync:upload_read_record(record)
    Log.info("上传单条阅读记录")
    
    local json_data = H.json_encode(record)
    if not json_data then
        return false, nil, "JSON编码失败"
    end
    
    local filename = "record_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
    local ok2, __, err2 = self.webdav:upload_backup_file(filename, json_data)
    if not ok2 then
        return false, nil, err2
    end
    
    return true, "记录上传成功", nil
end

function Sync:test_webdav_connection()
    -- 透传 webdav:test_connection 的 (ok, result, err) 三元组
    return self.webdav:test_connection()
end

return Sync