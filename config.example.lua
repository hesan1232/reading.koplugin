-- 开源阅读插件配置文件
-- 复制此文件为 config.lua 并修改以下配置

return {
    -- WebDAV 配置
    -- server 已经包含 /dav/，所以 remote_path 不需要再加 /dav/
    -- 正确格式: "legado" 或 "/legado"
    -- 错误格式: "/dav/legado"（会导致 URL 重复）
    webdav = {
        server = "https://dav.jianguoyun.com/dav/",
        username = "",
        password = "",
        remote_path = "legado",
    },

    -- 同步配置
    sync = {
        sync_url = "",
        last_sync_time = 0,
    },

    -- 缓存配置
    cache = {
        max_size_mb = 512,
        pre_download_chapters = 3,
        download_cover_images = false,
    },

    -- 书架配置
    shelf = {
        sort_order = "last_read",
    },

    -- 高级配置
    advanced = {
        developer_logs = false,
    },
}
