local H = require("reading.helper")
local Log = require("reading.log")
local WebDAV = require("reading.webdav")

local Sync = {}
Sync.__index = Sync

function Sync:new(settings)
    local obj = {
        settings = settings,
        bookshelf = {},
        read_records = {},
        webdav = WebDAV:new(settings),
    }
    return setmetatable(obj, self)
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
    for __ in pairs(files) do file_count = file_count + 1 end
    Log.debug("解析完成，找到 " .. file_count .. " 个文件")
    return files
end

--- 从解压目录加载备份数据。
--
-- 只认两个文件，且各有明确消费方：
--   · `bookshelf.json` —— 书架主数据（Legado 备份必含）；
--   · `readRecord.json` —— 各书阅读时长/最后阅读时间，由 downloader._complete_sync
--     合并进本地阅读记录（README「后台静默刷新同样会合并云端阅读记录」依赖它）。
-- ⚠️ 历史上 target_files 只列了 bookshelf.json，于是下面两个 elseif 分支
-- （bookSource.json / replaceRule.json）**永远不成立** —— 配套的
-- `self.book_sources` / `self.replace_rules` 也永远为空，而这两个字段除了在缓存里
-- 来回搬运之外没有任何消费方，属于纯粹的搬运开销。现按「有消费方才保留」原则
-- 一并移除（分支 + 字段 + `Sync:get_sync_data` 的导出），同时把 readRecord.json
-- 加进 target_files，让阅读记录合并链路真正生效。
function Sync:load_from_extracted_dir(extract_dir)
    Log.debug("从解压目录加载数据: " .. extract_dir)
    
    self.bookshelf = {}
    self.read_records = {}
    
    local lfs = require("libs/libkoreader-lfs")
    
    local target_files = {
        ["bookshelf.json"] = true,
        ["readRecord.json"] = true,
    }

    for entry in lfs.dir(extract_dir) do
        if target_files[entry] then
            local full_path = H.join_path(extract_dir, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "file" then
                Log.debug("处理文件: " .. entry)
                
                local file = io.open(full_path, "r")
                if file then
                    local content = file:read("*all")
                    file:close()
                    
                    local data = nil
                    local is_json = entry:match("%.json$")
                    
                    if is_json then
                        local ok, decoded = pcall(H.json_decode, content)
                        if ok and decoded then
                            data = decoded
                        else
                            Log.warn("JSON解码失败: " .. entry)
                        end
                    end
                    
                    if data and type(data) == "table" then
                        if entry == "bookshelf.json" then
                            for __, book in ipairs(data) do
                                table.insert(self.bookshelf, book)
                            end
                            Log.info("加载书架: " .. #self.bookshelf .. " 本书")
                        elseif entry == "readRecord.json" then
                            for __, record in ipairs(data) do
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
        else
            if entry ~= "." and entry ~= ".." then
                Log.debug("跳过无关文件: " .. entry)
            end
        end
    end
    
    return true
end

--- 把一段备份内容解码成 Lua table。
-- 输入可能是「已解码的 table」，也可能是 JSON 字符串（.txt 备份的每一段都是字符串）。
-- @param raw table|string|nil
-- @return table|nil
local function decode_backup_entry(raw)
    if type(raw) == "table" then return raw end
    if type(raw) ~= "string" then return nil end
    local ok, decoded = pcall(H.json_decode, raw)
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

function Sync:load_from_files(files)
    Log.debug("从文件表加载数据")
    
    self.bookshelf = {}
    self.read_records = {}
    
    -- ⚠️ 必须与 load_from_extracted_dir 保持一致：两条加载路径都要处理
    -- bookshelf.json 与 readRecord.json。此前这里只读 bookshelf.json，导致
    -- 非 zip（.txt）备份的阅读记录被静默丢弃 —— 而 parse_backup 其实已经把
    -- readRecord.json 段解析出来了（它按 `---文件名---` 通用分段），只是没人读。
    local books = decode_backup_entry(files["bookshelf.json"])
    if books then
        for __, book in ipairs(books) do
            table.insert(self.bookshelf, book)
        end
        Log.info("加载书架: " .. #self.bookshelf .. " 本书")
    end

    local records = decode_backup_entry(files["readRecord.json"])
    if records then
        for __, record in ipairs(records) do
            table.insert(self.read_records, record)
        end
        Log.info("加载阅读记录: " .. #self.read_records .. " 条")
    end
    
    return true
end

function Sync:get_sync_data()
    return {
        books = self.bookshelf,
        read_records = self.read_records,
    }
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
    for __, item in ipairs(items) do
        if item.name and (item.name:match("%.epub$") or item.name:match("%.txt$")) then
            table.insert(epub_files, {
                name = item.name,
                path = "books/" .. item.name,
                size = item.size,
                mtime = item.mtime or item.modified,
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
    for __, item in ipairs(items) do
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
        
        for __, file_info in ipairs(progress_files) do
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

    local lfs = require("libs/libkoreader-lfs")

    -- 已存在的完整文件 → 跳过。
    -- 判断的是 save_path（正主）：半截数据一律在 .tmp 里，见下面的原子落盘说明。
    if not force_overwrite and remote_size and H.file_exists(save_path) then
        local local_size = lfs.attributes(save_path, "size") or 0
        if local_size >= remote_size then
            Log.info("本地文件已存在且大小相同或更大，跳过下载: " .. save_path)
            return true, save_path, "skipped"
        end
    end

    local books_dir = H.get_books_dir()
    H.make_dir(books_dir)

    -- ================================================================
    -- 【原子落盘】先写 <name>.tmp，成功后再 rename 覆盖正主
    -- ================================================================
    -- 为什么必须这么做：直接写 save_path 时，任何中途失败（网络断、息屏、进程被杀）
    -- 都会在 books/ 里留下一个**扩展名合法**的半截 EPUB —— 书架扫描
    -- （get_local_epub_files 按 %.epub$ 匹配）会立刻把它当成一本可读的书，点进去
    -- 打开失败；get_epub_for_book 的模糊匹配还会在「半截文件」和「真文件」之间摇摆。
    -- `.tmp` 后缀不在匹配范围内，所以半截数据对书架**完全不可见**。
    -- 它同时还是断点续传的载体：失败时保留，下次从这里继续（webdav 侧的 Range 逻辑）。
    local tmp_path = save_path .. ".tmp"

    --- 单次尝试。
    -- @param start_size number > 0 表示复用断点（以 "a+b" 追加续传）；<= 0 表示从零开始
    --                   （先删残留，再以 "wb" 新建）。
    -- @return ok, err, downloaded
    local function attempt(start_size)
        if start_size <= 0 and H.file_exists(tmp_path) then
            -- 从零开始：必须先把残留的半截文件删掉。"wb" 本身也会截断，但显式删除能让
            -- 「文件被占用 / 权限异常导致截断失败」这类情况在日志里一眼可见。
            os.remove(tmp_path)
        end

        local file = io.open(tmp_path, start_size > 0 and "a+b" or "wb")
        if not file then
            Log.error("无法打开临时文件: " .. tmp_path)
            return false, "无法打开文件"
        end

        local ok, __, err, final_file = self.webdav:get_file(
            epub_path, progress_callback, remote_size, file, tmp_path)

        -- 句柄收尾：webdav 在重试过程中可能换过句柄，交回的是最终那个。
        -- 对已被关闭的句柄再次 close 会抛 "attempt to use a closed file"，统一 pcall 兜底。
        if final_file and final_file ~= file then
            pcall(function() final_file:close() end)
        end
        pcall(function() file:close() end)

        if not ok then
            return false, err
        end

        local downloaded = H.get_file_size(tmp_path)

        -- ① 内容为空：webdav 已把 404 按失败上报，这里兜的是「远端回 200 但 body 为空」
        --    这种更罕见的情况。
        if downloaded == 0 then
            os.remove(tmp_path)
            Log.warn("下载EPUB: 远端返回空内容（文件可能已不存在）: " .. tostring(epub_path))
            return false, "远端文件为空或已不存在"
        end

        -- ② 长度必须严丝合缝，否则绝不能 rename 成正主（那会用坏文件顶替掉可用的旧版本）。
        if remote_size and remote_size > 0 and downloaded ~= remote_size then
            if downloaded > remote_size then
                -- 越界 ⇒ 本次用的断点属于**另一个版本**（或服务器把 Range 当追加了）。
                -- 上报专用错误，外层会删掉它、用全新文件重下一遍。
                Log.warn("下载EPUB: 落盘长度超出远端 " .. downloaded .. "/" .. remote_size
                    .. "，判定断点已失效")
                return false, "BREAKPOINT_OVERSIZE"
            end
            -- 不足 ⇒ 传输被中途截断，保留 .tmp 供下次续传（这正是断点的价值）
            Log.warn("下载EPUB: 长度不足 " .. downloaded .. "/" .. remote_size .. "，保留断点供续传")
            return false, "下载不完整: " .. downloaded .. "/" .. remote_size .. " 字节"
        end

        -- 【原子替换】rename 要求源与目标同目录（tmp 与正主同目录，满足）。
        local renamed, rename_err = os.rename(tmp_path, save_path)
        if not renamed then
            Log.error("下载完成但重命名失败: " .. tostring(rename_err))
            return false, "保存文件失败: " .. tostring(rename_err)
        end

        Log.info("EPUB下载成功: " .. save_path .. " (" .. downloaded .. " 字节)")
        return true, nil, downloaded
    end

    -- ------------------------------------------------------------------
    -- 断点的可用性判定
    -- ------------------------------------------------------------------
    -- 【断点复用的铁律】① 更新场景（force_overwrite）一律不复用 —— 远端内容已变，
    -- 旧断点的字节与新版本后半段拼接会得到一个「长度正确、内容错乱」的坏 EPUB，
    -- 而长度校验**恰恰拦不住**它（前半段旧 + 后半段新 = 正好等于新版本长度）。
    -- ② 断点长度已超过远端 ⇒ 它不是「差一点」而是越界/陈旧，删掉。
    local start_size = H.get_file_size(tmp_path)
    if start_size > 0 then
        if force_overwrite then
            Log.info("更新书籍: 丢弃旧断点文件 (" .. start_size .. " 字节)")
            os.remove(tmp_path)
            start_size = 0
        elseif remote_size and remote_size > 0 and start_size > remote_size then
            Log.info("丢弃越界断点（" .. start_size .. " > 远端 " .. remote_size .. "）")
            os.remove(tmp_path)
            start_size = 0
        end
    end

    -- 长度恰好吻合的断点 = 上一次其实已经下完、只是没来得及改名 → 直接补一次 rename，
    -- 省掉整包重下（「下载完成后立刻断电 / 进程被杀」就是这条路径）。
    if start_size > 0 and remote_size and remote_size > 0 and start_size == remote_size then
        if os.rename(tmp_path, save_path) then
            Log.info("断点文件已完整，直接原子改名完成下载: " .. save_path)
            return true, save_path, "downloaded"
        end
        Log.warn("断点文件改名失败，改为重新下载: " .. tmp_path)
        os.remove(tmp_path)
        start_size = 0
    end

    local ok, err = attempt(start_size)

    -- 【一次性自愈】这两个错误都说明「本次用的断点/协议不可用」，用全新文件再来一遍
    -- 即可成功（这条路不会再发 Range，因为起始长度是 0）。
    --   · RANGE_UNSUPPORTED：服务器忽略 Range，webdav 已删掉被污染的半截文件；
    --   · BREAKPOINT_OVERSIZE：断点属于另一个版本，拼接后越界。
    if not ok and (err == "RANGE_UNSUPPORTED" or err == "BREAKPOINT_OVERSIZE") then
        Log.warn("断点不可用（" .. tostring(err) .. "），改为整文件重新下载: " .. tostring(epub_path))
        ok, err = attempt(0)
    end

    if not ok then
        -- 【失败时保留 .tmp】不删除：它是断点续传的载体，下次从这里继续。
        -- 它不进书架、不会被误当成书；长期残留由 cleanup_caches 按 max_age 兜底清理。
        Log.error("下载EPUB失败（保留断点文件 " .. tmp_path .. "）: " .. tostring(err))
        return false, nil, err
    end

    return true, save_path, "downloaded"
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
            -- 【close 也要查】磁盘满时 write 常常**不报错**、close 才暴露错误。原先只查
            -- write 就直接关文件并打印「zip文件保存成功」，会拿着半截 zip 去 extract_zip，
            -- 最终报「解压失败」把排查方向引偏。写法与 menus.lua 的 perform_sync_from_file
            -- zip 分支（menus.lua:357-368）保持一致：失败即清掉临时文件再返回。
            local close_ok, close_err = file:close()
            if close_ok == nil then
                os.remove(zip_path)
                Log.error("写入 zip 文件失败（close）: " .. tostring(close_err))
                return false, nil, "写入文件失败: " .. tostring(close_err)
            end
            
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

function Sync:test_webdav_connection()
    -- 透传 webdav:test_connection 的 (ok, result, err) 三元组
    return self.webdav:test_connection()
end

return Sync