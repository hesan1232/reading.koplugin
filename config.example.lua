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
        -- HTTPS 证书校验。默认 false = 不校验（电子墨水设备通常没有 CA 证书库，
        -- 强行校验会让所有服务器都握手失败；KOReader 自带 WebDAV 也不校验）。
        -- 置 true 后改用 verify="peer" + TLS 1.2，需设备上有可用 CA 库。
        verify_cert = false,
        -- HTTPS 连不上时是否降级为明文 HTTP 重试。默认 false。
        -- 开启会把 WebDAV 口令暴露在明文里，仅用于「自建服务器只监听 HTTP」的场景。
        -- 也可在界面「设置 → WebDAV → 允许降级 HTTP」切换。
        allow_http_fallback = false,
    },

    -- 同步配置
    sync = {
        last_sync_time = 0,
        -- 书架缓存「新鲜期」（小时）：打开书架时先用本地缓存秒开，
        -- 超过这个时长才在后台静默同步一次（stale-while-revalidate）。
        shelf_ttl_hours = 6,
        -- 后台自动刷新总开关（界面「设置 → 打开书架时自动刷新」对应此项）
        auto_refresh = true,
    },

    -- 缓存配置
    cache = {
        -- 缓存总量上限（MB）。超过后按「最久未访问」清理到 80%。
        -- 只作用于章节 / 目录 / 锚点这类可重建的数据缓存，**不会**删你下载的书。
        max_size_mb = 512,
        -- 缓存最长存活时长（小时）。超过即清理（与 max_size_mb 是两个独立的淘汰维度）。
        max_age_hours = 48,
        -- pre_download_chapters / download_cover_images 已移除：
        -- 两者都没有任何消费方（详见 settings.lua 的说明），
        -- 留着只会让人以为「改了它有用」。
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
