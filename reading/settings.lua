local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local H = require("reading.helper")
local Log = require("reading.log")

local Settings = {}
Settings.__index = Settings

local defaults = {
    sync = {
        enabled = true,
        last_sync_time = 0,
        -- 书架缓存「新鲜期」（小时）。超过它 → 打开书架时先渲染旧数据、
        -- 再后台静默同步（stale-while-revalidate）。见 main.lua 的 _maybe_bg_refresh_shelf。
        shelf_ttl_hours = 6,
        -- 后台自动刷新总开关（用户可在「设置」里关掉，避免在流量/弱网下自动联网）。
        auto_refresh = true,
    },
    webdav = {
        server = "https://dav.jianguoyun.com/dav/",
        username = "",
        password = "",
        remote_path = "legado",
        -- TLS 证书校验开关。默认 **false**（不校验）：
        --   电子墨水设备（Kindle/Kobo）上通常没有 CA 证书库，显式传 verify="peer"
        --   会把**所有**服务器都判成握手失败 —— KOReader 自带的 WebDAV 客户端
        --   （frontend/apps/cloudstorage/webdavapi.lua）与 koobone 都因此从不校验。
        --   打开后第一策略改用 verify="peer" + tlsv1_2，供「有 CA 库且想严格校验」的用户使用。
        verify_cert = false,
        -- HTTPS 连不上时是否允许降级为 HTTP（明文）重试一次。
        -- 默认 **false**：降级会把 WebDAV 口令暴露在明文里，属于安全降级，必须由用户显式开启
        -- （菜单「WebDAV → 允许降级 HTTP」）。自建 WebDAV 只监听 HTTP 的用户需要它；
        -- 连不上时日志会提示打开该开关。
        allow_http_fallback = false,
    },
    progress_sync = {
        auto_sync_enabled = true,
    },
    cache = {
        max_size_mb = 512,
        -- 缓存最长存活时长（小时）。超过即被 LRU 清理删除 —— 与 max_size_mb 是两个独立的
        -- 淘汰维度（前者按时间、后者按总量），任一触发都会清理。见 H.lru_cleanup。
        max_age_hours = 48,
        -- 曾有两个键 `pre_download_chapters` / `download_cover_images`，已删除 ——
        -- 二者都是「声明了但没有任何消费方」的死配置：
        --   · `pre_download_chapters`：需要「按章从远端取正文」的接口，而本插件只会
        --     整本下载 WebDAV 上的 EPUB/TXT（全仓库零个 Legado API 客户端、
        --     也没有章节级远端路径），这条功能无从实现；
        --   · `download_cover_images`：封面链路（下载 → 缓存 → 渲染）早已整体移除，
        --     连数据来源都不存在（详见 helper.lua 的 H.get_covers_dir 与 shelf_view.lua）。
        -- 若用户的 config.lua 里仍留着这两个键，它们只是被合并进配置表而已，无副作用。
    },
    shelf = {
        sort_order = "last_read",
        show_downloaded_only = false,
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

--- 用 config.lua 的值覆盖一份基准配置。
-- 表做深度合并（config.lua 中显式写出的键覆盖基准，未写出的键保留）；
-- 标量则直接覆盖基准。
local function override_with_config(base, from_config)
    if from_config == nil then
        return deepcopy(base)
    end
    if type(from_config) == "table" and type(base) == "table" then
        return merge_tables(base, from_config)
    end
    return deepcopy(from_config)
end

-- 一次性播种标记：标记该 store 已经用 config.lua 播种过。
-- 用于「首次运行」和「从旧版本（config.lua 被 LuaSettings 默认值遮蔽的版本）升级」两条路径。
local CONFIG_SEEDED_KEY = "_config_seeded"

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
    
    -- 播种默认值：config.lua 是「默认值的来源」，覆盖硬编码 defaults。
    --
    -- 历史 bug：这里曾经直接写入硬编码 defaults，而 defaults 里已经含有
    -- sync/webdav/cache/shelf/advanced 全部键，于是 Settings:get() 从 store 读到的
    -- 永远是硬编码默认值，config.lua 分支根本没有机会执行 —— 也就是 README
    -- 推荐的配置方式实际不生效（P0-2）。
    --
    -- 现在：仅在首次运行、或旧版本升级（store 里没有 _config_seeded 标记）时播种。
    -- 升级路径只让 config.lua 中「显式写出的键」覆盖 store，其余用户设置在 store 中保留，
    -- 避免把用户通过界面设置过的 WebDAV 账号等回退成默认值。
    -- 之后 UI 的修改（store）优先；config.lua 的后续改动需要显式调用 reload_config()。
    if not obj.store:has(CONFIG_SEEDED_KEY) then
        local first_run = not obj.store:has("sync")
        local cfg = obj.config or {}
        for key in pairs(defaults) do
            local existing = obj.store:readSetting(key, nil)
            if existing == nil then
                obj.store:saveSetting(key, override_with_config(defaults[key], cfg[key]))
            elseif not first_run and cfg[key] ~= nil then
                obj.store:saveSetting(key, override_with_config(existing, cfg[key]))
            end
        end
        obj.store:saveSetting(CONFIG_SEEDED_KEY, true)
        obj.store:flush()
        Log.info("Settings: 已用 config.lua 播种默认配置"
            .. (first_run and "（首次运行）" or "（升级迁移）"))
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
    
    -- 1. store（界面设置 + 播种结果）优先
    local result = self.store:readSetting(key, nil)
    
    -- 2. store 中缺失（通常只发生在 defaults 里没有的自定义键）时，
    --    用 config.lua 覆盖硬编码默认值，并落地一次，之后 UI 修改即可覆盖
    if result == nil and self.config and self.config[key] ~= nil then
        result = override_with_config(default, self.config[key])
        self.store:saveSetting(key, result)
        self.store:flush()
    end
    
    -- 3. 都没有则用硬编码默认值
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

function Settings:set_last_sync_time(time)
    local sync = self:get("sync") or {}
    sync.last_sync_time = time
    self:set("sync", sync)
    self:flush()
end

function Settings:is_developer_logs_enabled()
    return self:get("advanced") and self:get("advanced").developer_logs or false
end

--- 持久化 DEBUG 日志开关（「调试日志」菜单项的勾选项）。
-- 不持久化的话，重启后 Log.init() 会按 advanced.developer_logs 把它覆盖回默认值。
function Settings:set_developer_logs_enabled(enabled)
    local advanced = self:get("advanced") or {}
    advanced.developer_logs = enabled and true or false
    self:set("advanced", advanced)
    self:flush()
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

--- 是否对 HTTPS 做证书校验（默认 false，理由见 defaults.webdav.verify_cert 注释）。
function Settings:get_webdav_verify_cert()
    local webdav = self:get("webdav")
    if webdav and webdav.verify_cert ~= nil then
        return webdav.verify_cert == true
    end
    return false
end

function Settings:set_webdav_verify_cert(enabled)
    local webdav = self:get("webdav") or {}
    webdav.verify_cert = enabled and true or false
    self:set("webdav", webdav)
    self:flush()
end

--- HTTPS 失败时是否允许降级 HTTP（默认 false，安全降级，须用户显式开启）。
function Settings:get_webdav_allow_http_fallback()
    local webdav = self:get("webdav")
    if webdav and webdav.allow_http_fallback ~= nil then
        return webdav.allow_http_fallback == true
    end
    return false
end

function Settings:set_webdav_allow_http_fallback(enabled)
    local webdav = self:get("webdav") or {}
    webdav.allow_http_fallback = enabled and true or false
    self:set("webdav", webdav)
    self:flush()
end

function Settings:get_shelf_sort()
    local shelf = self:get("shelf")
    return shelf and shelf.sort_order or "last_read"
end

function Settings:set_shelf_sort(sort_key)
    local shelf = self:get("shelf") or {}
    shelf.sort_order = sort_key
    shelf.sort_asc = nil -- 切换排序键时恢复默认方向（时间类倒序 / 书名正序）
    self:set("shelf", shelf)
    self:flush()
end

--- 书架排序方向。nil = 当前排序键的默认方向（见 Bookshelf:sort_books），
--- 只有用户点过"再点一下翻转"才写入 true/false。
function Settings:get_shelf_sort_asc()
    local shelf = self:get("shelf")
    return shelf and shelf.sort_asc or nil
end

function Settings:set_shelf_sort_asc(asc)
    local shelf = self:get("shelf") or {}
    shelf.sort_asc = asc
    self:set("shelf", shelf)
    self:flush()
end

function Settings:get_show_downloaded_only()
    local shelf = self:get("shelf")
    if shelf and shelf.show_downloaded_only ~= nil then
        return shelf.show_downloaded_only
    end
    return false
end

function Settings:set_show_downloaded_only(show_only)
    local shelf = self:get("shelf") or {}
    shelf.show_downloaded_only = show_only
    self:set("shelf", shelf)
    self:flush()
end

--- 重新加载 config.lua，并把其中的配置强制应用到 store。
-- 这是显式操作（设置菜单里的「重新加载 config.lua」），所以 config.lua 的值会覆盖
-- 界面上做过的同类修改；config.lua 中没有出现的键，store 里的现值保持不变。
-- 旧的实现在这里只更新 self.config，而 get() 根本读不到它，因此是个空操作（P0-2）。
function Settings:reload_config()
    self.config = self:_load_config_file()
    if not self.config then
        return false
    end

    local applied = {}
    for key, value in pairs(self.config) do
        local current = self.store:readSetting(key, nil)
        self.store:saveSetting(key, override_with_config(current or defaults[key], value))
        applied[#applied + 1] = key
    end
    self.store:saveSetting(CONFIG_SEEDED_KEY, true)
    self:flush()

    Log.info("config.lua 重新加载并生效: " .. table.concat(applied, ", "))
    return true
end

function Settings:is_progress_auto_sync_enabled()
    return self:get("progress_sync") and self:get("progress_sync").auto_sync_enabled ~= false
end

--- 数据类缓存（章节 / 目录 / 锚点 / 半截下载）的总量上限（MB）。
--- 读不到或非法时回落到 512 —— 调用方（H.lru_cleanup）需要的是一个确定的数字，
--- 而不是 nil。注意：**不含用户下载的整本 EPUB**，那个是用户数据，永不 LRU 删除。
function Settings:get_cache_max_mb()
    local cache = self:get("cache")
    local mb = cache and tonumber(cache.max_size_mb)
    if not mb or mb <= 0 then mb = 512 end
    return mb
end

--- 数据类缓存的最长存活时长（小时）。
function Settings:get_cache_max_age_hours()
    local cache = self:get("cache")
    local hours = cache and tonumber(cache.max_age_hours)
    if not hours or hours <= 0 then hours = 48 end
    return hours
end

--- 上次成功同步的时间戳（秒）。0 表示从未同步过。
function Settings:get_last_sync_time()
    local sync = self:get("sync")
    return tonumber(sync and sync.last_sync_time) or 0
end

--- 书架缓存新鲜期（小时）。0 = 每次都后台刷新。
function Settings:get_shelf_refresh_ttl_hours()
    local sync = self:get("sync")
    local hours = sync and tonumber(sync.shelf_ttl_hours)
    if not hours or hours < 0 then hours = 6 end
    return hours
end

--- 后台自动刷新书架是否开启（默认开）。
function Settings:is_shelf_auto_refresh_enabled()
    local sync = self:get("sync")
    if sync and sync.auto_refresh ~= nil then
        return sync.auto_refresh ~= false
    end
    return true
end

function Settings:set_shelf_auto_refresh_enabled(enabled)
    local sync = self:get("sync") or {}
    sync.auto_refresh = enabled and true or false
    self:set("sync", sync)
    self:flush()
end

function Settings:set_progress_auto_sync_enabled(enabled)
    local progress_sync = self:get("progress_sync") or {}
    progress_sync.auto_sync_enabled = enabled
    self:set("progress_sync", progress_sync)
    self:flush()
end

return Settings
