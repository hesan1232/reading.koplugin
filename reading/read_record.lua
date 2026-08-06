local H = require("reading.helper")
local Log = require("reading.log")

local ReadRecord = {}
ReadRecord.__index = ReadRecord

function ReadRecord:new(settings)
    local obj = {
        settings = settings,
        records = {},
        save_path = H.join_path(H.get_data_dir(), "read_records.lua"),
    }
    setmetatable(obj, self)
    obj:load_records()
    Log.info("初始化阅读记录模块，已加载 " .. #obj.records .. " 条记录")
    return obj
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
                    Log.info("从文件加载阅读记录(JSON fallback): " .. #data2 .. " 条")
                    return
                end
                Log.warn("加载阅读记录失败: loadstring=" .. tostring(data) .. ", json=" .. tostring(data2))
            else
                Log.warn("加载阅读记录失败: loadstring=" .. tostring(data) .. ", json模块不可用")
            end
            self.records = {}
        else
            self.records = {}
        end
    else
        self.records = {}
    end
end

function ReadRecord:save_records()
    local file = io.open(self.save_path, "w")
    if file then
        file:write("return ")
        
        local ok, serpent = pcall(require, "serpent")
        if ok then
            file:write(serpent.block(self.records))
        else
            file:write(require("json").encode(self.records))
        end
        
        file:close()
        Log.debug("保存阅读记录")
        return true
    end
    return false
end

function ReadRecord:get_record(book_url)
    for _, record in ipairs(self.records) do
        if record.bookUrl == book_url then
            return record
        end
    end
    return nil
end

function ReadRecord:get_record_by_name(book_name)
    for _, record in ipairs(self.records) do
        if record.bookName == book_name then
            return record
        end
    end
    return nil
end

function ReadRecord:update_record(book_url, book_name, read_time, last_read)
    local record = self:get_record(book_url)
    
    if not record then
        record = {
            bookUrl = book_url,
            bookName = book_name or "",
            readTime = read_time or 0,
            lastRead = last_read or os.time() * 1000,
            lastCheckTime = os.time(),
        }
        table.insert(self.records, record)
        Log.info("新增阅读记录: " .. book_url)
    else
        if read_time then
            record.readTime = record.readTime + read_time
        end
        record.lastRead = last_read or os.time() * 1000
        record.lastCheckTime = os.time()
        Log.debug("更新阅读记录: " .. book_url)
    end
    
    self:save_records()
    return record
end

function ReadRecord:delete_record(book_url)
    for i = #self.records, 1, -1 do
        if self.records[i].bookUrl == book_url then
            table.remove(self.records, i)
            self:save_records()
            Log.info("删除阅读记录: " .. book_url)
            return true
        end
    end
    return false
end

function ReadRecord:merge_from_sync(sync_records)
    local updated_count = 0
    
    for _, sync_record in ipairs(sync_records) do
        local local_record = self:get_record_by_name(sync_record.bookName)
        
        if not local_record then
            table.insert(self.records, {
                bookName = sync_record.bookName,
                readTime = sync_record.readTime or 0,
                lastRead = sync_record.lastRead or os.time() * 1000,
                bookUrl = "",
                lastCheckTime = os.time(),
            })
            updated_count = updated_count + 1
            Log.info("从同步新增记录: " .. sync_record.bookName)
        else
            local sync_time = sync_record.lastRead or 0
            local local_time = local_record.lastRead or 0
            
            if sync_time > local_time then
                local_record.readTime = sync_record.readTime or local_record.readTime
                local_record.lastRead = sync_time
                local_record.lastCheckTime = os.time()
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

function ReadRecord:get_all_records()
    return self.records
end

function ReadRecord:get_sync_data()
    local sync_data = {}
    for _, record in ipairs(self.records) do
        table.insert(sync_data, {
            bookName = record.bookName or "",
            readTime = record.readTime or 0,
            lastRead = record.lastRead or os.time() * 1000,
            deviceId = "KOReader",
        })
    end
    return sync_data
end

function ReadRecord:get_read_time(book_url)
    local record = self:get_record(book_url)
    if not record then
        return 0
    end
    return record.readTime or 0
end

function ReadRecord:get_last_read(book_url)
    local record = self:get_record(book_url)
    if not record then
        return 0
    end
    return record.lastRead or 0
end

return ReadRecord