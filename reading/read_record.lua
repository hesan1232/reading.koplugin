local H = require("reading.helper")
local Log = require("reading.log")

local ReadRecord = {}
ReadRecord.__index = ReadRecord

function ReadRecord:new(settings)
    local obj = {
        settings = settings,
        records = {},
        url_index = {},      -- bookUrl -> record 哈希索引，O(1) 查找
        name_index = {},     -- bookName -> record 哈希索引，O(1) 查找
        save_path = H.join_path(H.get_data_dir(), "read_records.lua"),
    }
    setmetatable(obj, self)
    obj:load_records()
    Log.info("初始化阅读记录模块，已加载 " .. #obj.records .. " 条记录")
    return obj
end

function ReadRecord:rebuild_index()
    self.url_index = {}
    self.name_index = {}
    for __, record in ipairs(self.records) do
        if record.bookUrl and record.bookUrl ~= "" then
            self.url_index[record.bookUrl] = record
        end
        if record.bookName and record.bookName ~= "" then
            self.name_index[record.bookName] = record
        end
    end
end

function ReadRecord:load_records()
    if H.file_exists(self.save_path) then
        local file = io.open(self.save_path, "r")
        if file then
            local content = file:read("*all")
            file:close()

            -- 优先尝试 loadstring（serpent/Lua 表格式：return {...}）
            local ok, data = pcall(loadstring, content)
            if ok and type(data) == "table" then
                self.records = data
                self:rebuild_index()
                Log.debug("从文件加载阅读记录: " .. #data .. " 条")
                return
            end

            -- fallback: 尝试 JSON 解码（去掉 "return " 前缀，兼容旧版 json.encode 保存的文件）
            local json_ok, json = pcall(require, "json")
            if json_ok and json then
                local json_content = content:gsub("^return%s*", "")
                local ok2, data2 = pcall(json.decode, json_content)
                if ok2 and type(data2) == "table" then
                    self.records = data2
                    self:rebuild_index()
                    Log.info("从文件加载阅读记录(JSON fallback): " .. #data2 .. " 条")
                    return
                end
                Log.warn("加载阅读记录失败: loadstring=" .. tostring(data) .. ", json=" .. tostring(data2))
            else
                Log.warn("加载阅读记录失败: loadstring=" .. tostring(data) .. ", json模块不可用")
            end
            self.records = {}
            self:rebuild_index()
        else
            self.records = {}
            self:rebuild_index()
        end
    else
        self.records = {}
        self:rebuild_index()
    end
end

--- 原子保存阅读记录
--
-- 先写 save_path.tmp 再 rename 覆盖。原实现是直接 io.open(save_path, "w") 写入，
-- 一旦在写入过程中掉电 / 进程被杀，磁盘上会留下半截 Lua 文件：
-- load_records 的 loadstring 失败 → JSON fallback 也失败 → **静默返回 {}**，
-- 用户看到的现象是「全部阅读时长凭空清零」。
-- 同插件的 bookshelf.save_toc_anchors / save_bookshelf_cache 已是同一套 .tmp + rename 模式。
function ReadRecord:save_records()
    local tmp_path = self.save_path .. ".tmp"

    local file = io.open(tmp_path, "w")
    if not file then
        Log.error("保存阅读记录失败: 无法写入临时文件 " .. tostring(tmp_path))
        return false
    end

    -- 【write 也要查】磁盘满 / 只读时会直接返回 nil + 错误信息；只在 close 检查会晚一步，
    -- 且报错点会落在 close 上，定位不到是哪一次写失败。三次写的结果逐一收拢。
    local write_ok, write_err = file:write("return ")

    -- ⚠️ KOReader 里的模块名是 `ffi/serpent`（frontend/ffi/serpent.lua），
    -- 顶层 `serpent` **不存在**（见 frontend/logger.lua、frontend/persist.lua 的写法）。
    -- 这里曾只试 `require("serpent")`，于是 KOReader 上永远走 JSON 兜底分支 ——
    -- 文件内容变成 `return {json}`，加载时 loadstring 必然失败、每次都退到 JSON 解码，
    -- 「Lua 表零反序列化」的设计意图从未生效。现按 ffi/serpent → serpent 的顺序探测。
    local ok, serpent = pcall(require, "ffi/serpent")
    if not ok then
        ok, serpent = pcall(require, "serpent")
    end
    if ok and serpent then
        local w_ok, w_err = file:write(serpent.block(self.records, { comment = false }))
        if not w_ok then write_ok, write_err = w_ok, w_err end
    else
        local json_ok, json = pcall(require, "json")
        if json_ok and json then
            local w_ok, w_err = file:write(json.encode(self.records))
            if not w_ok then write_ok, write_err = w_ok, w_err end
        else
            file:close()
            os.remove(tmp_path)
            Log.error("保存阅读记录失败: serpent 和 json 模块均不可用")
            return false
        end
    end

    -- 磁盘写满时 write 常常不报错、close 才暴露错误，必须两者都检查
    local close_ok, close_err = file:close()
    if not write_ok or close_ok == nil then
        os.remove(tmp_path)
        Log.error("保存阅读记录失败: 写入/关闭临时文件出错 " .. tostring(write_err or close_err))
        return false
    end

    local renamed, rename_err = os.rename(tmp_path, self.save_path)
    if not renamed then
        os.remove(tmp_path)
        Log.error("保存阅读记录失败: 原子重命名失败 " .. tostring(rename_err))
        return false
    end

    Log.debug("保存阅读记录（原子写）")
    return true
end

function ReadRecord:get_record(book_url)
    if not book_url or book_url == "" then return nil end
    return self.url_index[book_url]
end

function ReadRecord:get_record_by_name(book_name)
    if not book_name or book_name == "" then return nil end
    return self.name_index[book_name]
end

--- 更新阅读记录（新增或累加）
--
-- 【单位约定】本仓库所有 `*Time` / `*CheckTime` 字段一律**毫秒**（`os.time() * 1000`）。
-- 这条约定以前被破坏过：book.lastCheckTime（progress.lua）与这里的 record.lastCheckTime
-- 都写成过秒，而读取侧是 `tonumber(durChapterTime) or tonumber(lastCheckTime)` 直接比较，
-- 秒值会小三个数量级，导致排序错乱、以及 apply_sync_data 误判「云端更新」。
-- 新增时间字段时请沿用毫秒，不要再引入第二套单位。
function ReadRecord:update_record(book_url, book_name, read_time, last_read)
    local record = self:get_record(book_url)
    
    if not record then
        record = {
            bookUrl = book_url,
            bookName = book_name or "",
            readTime = read_time or 0,
            lastRead = last_read or os.time() * 1000,
            lastCheckTime = os.time() * 1000,
        }
        table.insert(self.records, record)
        if book_url and book_url ~= "" then self.url_index[book_url] = record end
        if book_name and book_name ~= "" then self.name_index[book_name] = record end
        Log.info("新增阅读记录: " .. book_url)
    else
        if read_time then
            record.readTime = record.readTime + read_time
        end
        record.lastRead = last_read or os.time() * 1000
        record.lastCheckTime = os.time() * 1000
        Log.debug("更新阅读记录: " .. book_url)
    end

    -- 仅更新内存，不立即写盘，避免切章时阻塞 UI
    -- 持久化由 onCloseDocument 中的 save_records 调用负责
    self._dirty = true
    return record
end

function ReadRecord:merge_from_sync(sync_records)
    local updated_count = 0
    
    for __, sync_record in ipairs(sync_records) do
        local local_record = self:get_record_by_name(sync_record.bookName)
        
        if not local_record then
            local new_record = {
                bookName = sync_record.bookName,
                readTime = sync_record.readTime or 0,
                lastRead = sync_record.lastRead or os.time() * 1000,
                bookUrl = "",
                lastCheckTime = os.time() * 1000,
            }
            table.insert(self.records, new_record)
            if sync_record.bookName and sync_record.bookName ~= "" then
                self.name_index[sync_record.bookName] = new_record
            end
            updated_count = updated_count + 1
            Log.info("从同步新增记录: " .. sync_record.bookName)
        else
            local sync_time = sync_record.lastRead or 0
            local local_time = local_record.lastRead or 0
            
            if sync_time > local_time then
                local_record.readTime = sync_record.readTime or local_record.readTime
                local_record.lastRead = sync_time
                local_record.lastCheckTime = os.time() * 1000
                updated_count = updated_count + 1
                Log.info("从同步更新记录: " .. sync_record.bookName)
            end
        end
    end
    
    if updated_count > 0 then
        self:save_records()
    end
    
    Log.info("合并同步记录完成，更新 " .. updated_count .. " 条")
    return updated_count
end

return ReadRecord