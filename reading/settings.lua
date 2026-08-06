local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local H = require("reading.helper")
local Log = require("reading.log")

local Settings = {}
Settings.__index = Settings

local defaults = {
    sync = {
        enabled = true,
        sync_url = "",
        last_sync_time = 0,
    },
    webdav = {
        server = "https://dav.jianguoyun.com/dav/",
        username = "",
        password = "",
        remote_path = "legado",
    },
    progress_sync = {
        auto_sync_enabled = true,
        auto_sync_interval = 300,
    },
    cache = {
        max_size_mb = 512,
        pre_download_chapters = 3,
        download_cover_images = true,
    },
    shelf = {
        sort_order = "last_read",
    },
    advanced = {
        developer_logs = false,
    },
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    setmetatable(out, getmetatable(value))
    return out
end

local function merge_tables(default, override)
    local result = deepcopy(default)
    if type(override) ~= "table" then
        return result
    end
    for key, value in pairs(override) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = merge_tables(result[key], value)
        else
            result[key] = value
        end
    end
    return result
end

function Settings:new()
    local data_dir = H.get_data_dir()
    H.make_dir(data_dir)
    
    local obj = {
        data_dir = data_dir,
        settings_file = DataStorage:getSettingsDir() .. "/reading.lua",
        config = nil,
        config_path = nil,
    }
    obj.store = LuaSettings:open(obj.settings_file)
    
    -- 先设置元表，才能调用方法
    setmetatable(obj, self)
    
    -- 加载 config.lua
    obj.config_path = obj:_get_config_path()
    obj.config = obj:_load_config_file()
    
    -- 初始化默认值（仅第一次运行时）
    if not obj.store:has("sync") then
        obj.store:saveSetting("sync", deepcopy(defaults.sync))
        obj.store:saveSetting("webdav", deepcopy(defaults.webdav))
        obj.store:saveSetting("cache", deepcopy(defaults.cache))
        obj.store:saveSetting("shelf", deepcopy(defaults.shelf))
        obj.store:saveSetting("advanced", deepcopy(defaults.advanced))
        obj.store:flush()
    end
    
    return obj
end

function Settings:_get_config_path()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    local plugin_dir = path:match("^(.*)[/\\][^/\\]+$") or "."
    plugin_dir = plugin_dir:match("^(.*)[/\\][^/\\]+$") or plugin_dir
    return plugin_dir .. "/config.lua"
end

function Settings:_load_config_file()
    if not self.config_path then
        return nil
    end
    
    local file = io.open(self.config_path, "r")
    if not file then
        Log.debug("config.lua 不存在，使用默认配置")
        return nil
    end
    file:close()
    
    local ok, config = pcall(dofile, self.config_path)
    if not ok or type(config) ~= "table" then
        Log.error("config.lua 加载失败: " .. tostring(config))
        return nil
    end
    
    Log.info("config.lua 加载成功")
    return config
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    
    -- 优先从 LuaSettings 读取
    local result = self.store:readSetting(key, nil)
    
    -- 如果 LuaSettings 中没有，从 config.lua 读取
    if result == nil and self.config and self.config[key] ~= nil then
        result = deepcopy(self.config[key])
    end
    
    -- 如果都没有，使用默认值
    if result == nil then
        result = deepcopy(default)
    end
    
    return result
end

function Settings:set(key, value)
    Log.debug("设置 " .. key .. ": " .. tostring(value))
    self.store:saveSetting(key, value)
end

function Settings:flush()
    Log.debug("刷新设置到文件: " .. self.settings_file)
    local ok, err = pcall(function()
        self.store:flush()
    end)
    if ok then
        Log.debug("设置刷新成功")
    else
        Log.error("设置刷新失败: " .. tostring(err))
    end
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:get_sync_url()
    return self:get("sync") and self:get("sync").sync_url or ""
end

function Settings:set_sync_url(url)
    local sync = self:get("sync") or {}
    sync.sync_url = url
    self:set("sync", sync)
    self:flush()
end

function Settings:set_last_sync_time(time)
    local sync = self:get("sync") or {}
    sync.last_sync_time = time
    self:set("sync", sync)
    self:flush()
end

function Settings:get_last_sync_time()
    return self:get("sync") and self:get("sync").last_sync_time or 0
end

function Settings:is_sync_enabled()
    return self:get("sync") and self:get("sync").enabled or false
end

function Settings:get_cache_max_size_mb()
    return self:get("cache") and self:get("cache").max_size_mb or 512
end

function Settings:get_pre_download_chapters()
    return self:get("cache") and self:get("cache").pre_download_chapters or 3
end

function Settings:should_download_covers()
    return self:get("cache") and self:get("cache").download_cover_images or true
end

function Settings:get_shelf_sort_order()
    return self:get("shelf") and self:get("shelf").sort_order or "last_read"
end

function Settings:set_shelf_sort_order(order)
    local shelf = self:get("shelf") or {}
    shelf.sort_order = order
    self:set("shelf", shelf)
    self:flush()
end

function Settings:is_developer_logs_enabled()
    return self:get("advanced") and self:get("advanced").developer_logs or false
end

function Settings:clear_all_cache()
    local cache_dir = H.get_cache_dir()
    H.delete_dir(cache_dir)
    H.make_dir(cache_dir)
    H.make_dir(H.get_covers_dir())
    H.make_dir(H.get_chapters_dir())
    return true
end

function Settings:get_cache_stats()
    local lfs = require("libs/libkoreader-lfs")
    local stats = {
        book_count = 0,
        total_size = 0,
        chapter_count = 0
    }
    local cache_dir = H.get_cache_dir()
    if not H.dir_exists(cache_dir) then
        return stats
    end
    for entry in lfs.dir(cache_dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = H.join_path(cache_dir, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                if entry == "chapters" then
                    for book_dir in lfs.dir(full_path) do
                        if book_dir ~= "." and book_dir ~= ".." then
                            stats.book_count = stats.book_count + 1
                            local book_path = H.join_path(full_path, book_dir)
                            for file_entry in lfs.dir(book_path) do
                                if file_entry ~= "." and file_entry ~= ".." then
                                    local file_path = H.join_path(book_path, file_entry)
                                    local file_mode = lfs.attributes(file_path, "mode")
                                    if file_mode == "file" then
                                        local size = lfs.attributes(file_path, "size") or 0
                                        stats.total_size = stats.total_size + size
                                        if file_path:match("%.html$") then
                                            stats.chapter_count = stats.chapter_count + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                elseif entry == "covers" then
                    for cover_file in lfs.dir(full_path) do
                        if cover_file ~= "." and cover_file ~= ".." then
                            local file_path = H.join_path(full_path, cover_file)
                            local size = lfs.attributes(file_path, "size") or 0
                            stats.total_size = stats.total_size + size
                        end
                    end
                end
            end
        end
    end
    return stats
end

function Settings:get_webdav_server()
    return self:get("webdav") and self:get("webdav").server or ""
end

function Settings:set_webdav_server(server)
    local webdav = self:get("webdav") or {}
    webdav.server = server
    self:set("webdav", webdav)
    self:flush()
end

function Settings:get_webdav_username()
    return self:get("webdav") and self:get("webdav").username or ""
end

function Settings:set_webdav_username(username)
    local webdav = self:get("webdav") or {}
    webdav.username = username
    self:set("webdav", webdav)
    self:flush()
end

function Settings:get_webdav_password()
    return self:get("webdav") and self:get("webdav").password or ""
end

function Settings:set_webdav_password(password)
    local webdav = self:get("webdav") or {}
    webdav.password = password
    self:set("webdav", webdav)
    self:flush()
end

function Settings:get_webdav_remote_path()
    return self:get("webdav") and self:get("webdav").remote_path or "legado"
end

function Settings:set_webdav_remote_path(path)
    local webdav = self:get("webdav") or {}
    webdav.remote_path = path
    self:set("webdav", webdav)
    self:flush()
end

function Settings:reload_config()
    self.config = self:_load_config_file()
    if self.config then
        Log.info("config.lua 重新加载成功")
        return true
    end
    return false
end

function Settings:is_progress_auto_sync_enabled()
    return self:get("progress_sync") and self:get("progress_sync").auto_sync_enabled ~= false
end

function Settings:set_progress_auto_sync_enabled(enabled)
    local progress_sync = self:get("progress_sync") or {}
    progress_sync.auto_sync_enabled = enabled
    self:set("progress_sync", progress_sync)
    self:flush()
end

function Settings:get_progress_auto_sync_interval()
    return self:get("progress_sync") and self:get("progress_sync").auto_sync_interval or 300
end

function Settings:set_progress_auto_sync_interval(interval)
    local progress_sync = self:get("progress_sync") or {}
    progress_sync.auto_sync_interval = interval
    self:set("progress_sync", progress_sync)
    self:flush()
end

return Settings
