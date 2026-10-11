--[[
    异步执行框架与云端书库下载。

    本文件由 `main.lua` 按职责拆出（架构报告 §9-2 / P0-6）。
    函数以「同名 mixin」方式合并回 `ReadingPlugin`：方法名与调用约定与拆分前完全一致，
    因此 `main.lua` 中的调用点（`self:xxx()`）无需任何改动。

    文件顶部的 require 前导是**自动推导**的：只列出本文件函数真正引用的自由变量，
    由 `lua_upvalue_lint.py`（作用域感知，非 grep）校验过，不存在漏引用的 upvalue。
]]

local LOG_MODULE = "[Reading]"
local function safe_require(module_name, required)
    local ok, result = pcall(require, module_name)
    if not ok then
        if required then
            print(LOG_MODULE, "fatal: failed to load required module:", module_name, "-", result)
            return nil, false
        else
            print(LOG_MODULE, "warning: failed to load optional module:", module_name, "-", result)
            return nil, true
        end
    end
    return result, true
end
local UIManager = safe_require("ui/uimanager")
local InfoMessage = safe_require("ui/widget/infomessage")
local H = require("reading.helper")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or function(str, ...) return str end
local ShelfView = safe_require("reading.shelf_view")
local Log = safe_require("reading.log")
local Result = safe_require("reading.result")
local Async = safe_require("reading.async")
local unpack_args = unpack or table.unpack

-- 阅读上下文状态（替代原 _state 中的阅读会话字段，含 generation 令牌防竞态）
local UIHandles = require("reading.ui_handles")

local M = {}

--- 异步任务句柄名的自增序号（模块级，跨实例共享也无妨：它只要求「同一次进程运行内
--- 不重复」）。
--
-- 【为什么不用 os.clock() + math.random()】原实现是
-- `tostring(os.clock()) .. "_" .. tostring(math.random(10000, 99999))`，而
-- `math.randomseed` 全仓库没有任何调用 → 随机序列每次启动都相同；os.clock() 的分辨率
-- 也有限。后果是**同一 tick 内连发两个异步任务会拿到同一个 handle_id**，
-- 后者把自己的句柄覆盖进 `self._async_handles[id]`，于是 `_cancel_async` 只会取消
-- 其中一个，另一个成了「取消不掉的孤儿任务」。
local _async_handle_seq = 0

local function next_async_handle_id()
    _async_handle_seq = _async_handle_seq + 1
    return "async_" .. _async_handle_seq
end

function M.showBusy(self, text)
    -- 使用 UIHandles 共享句柄，确保 FileManager 和 ReaderUI 实例都能关闭 busy 消息
    local msg = InfoMessage:new{ text = text, norefresh = true }
    UIHandles.set("busy_msg", msg)
    UIManager:show(msg)
    UIManager:forceRePaint()
    -- 返回本次 busy 的句柄：调用方应把它存下来，收尾时传给 closeBusy 做身份比对
    return msg
end

--- 关闭 busy 提示。
--
-- @param expect widget|nil
--        「期望关闭的就是这一个」——showBusy 的返回值。传入时先做身份比对。
--
-- 【为什么要比对】busy_msg 是一个**共享槽位**：UIHandles.set 遇到同名会先把旧的关掉
-- 再覆盖。于是「A 流程的 busy 被 B 流程顶掉」之后，A 的异步回调迟到时若无条件
-- closeBusy()，关掉的是**此刻 B 的那一个** —— 用户会看到「正在获取云端书库…」在
-- 中途莫名消失（而请求还在跑）。传 nil 保持旧行为（无条件关），仅适用于
-- 「错误收尾，关什么都要关」这类场景（如 showError）。
function M.closeBusy(self, expect)
    if expect ~= nil and UIHandles.get("busy_msg") ~= expect then
        return
    end
    UIHandles.close("busy_msg")
end

--- 一般提示的默认停留秒数。失败类提示会显式传 `false`（不自动消失）。
local DEFAULT_INFO_TIMEOUT = 3

--- 显示提示。
--
-- @param text string
-- @param timeout number|false|nil
--        正数 = 该秒数后自动消失；nil = 用 DEFAULT_INFO_TIMEOUT；
--        **false = 不自动消失**，必须手动点掉（失败 / 需要用户采取行动的提示）。
--
-- ⚠️ 不要用 `0` 表示「不消失」：`InfoMessage:onShow` 写的是 `if self.timeout then`，
-- 而 Lua 里 0 为真 —— 传 0 会变成「排一个 0 秒后的关闭定时器」= 弹出即消失。
function M.showInfo(self, text, timeout)
    if timeout == nil then
        timeout = DEFAULT_INFO_TIMEOUT
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- 统一错误展示：closeBusy + log + showInfo
--- 错误必须手动点掉（多为多行，含排查所需的详情），所以这里是 sticky 的。
function M.showError(self, label, err)
    self:closeBusy()
    local fmt_err = Result and Result.format_error(err) or tostring(err)
    Log.error(label .. " 失败: " .. fmt_err)
    self:showInfo(T(_("%1 failed:\n%2"), tostring(label), tostring(fmt_err)), false)
end

--- 判断 widget 是不是当前**最上层**的窗口。
--
-- 后台刷新只在书架「还在最上面」时才允许原地重渲染：用户点了某本书之后，书架菜单
-- 只是被详情页/对话框**盖住**，`UIHandles.get("menu")` 依然非 nil、令牌也没变
-- （因为期间没有新的 show()）—— 此时若 show() 一次，就会把书架重新推到最上层，
-- 相当于凭空糊住用户正在看的界面。
--
-- KOReader 没有公开的 topmost 查询 API，只能读 `UIManager._window_stack`（私有）。
-- 拿不到（结构改动 / 访问失败）时**保守返回 false**：宁可不刷新（数据与缓存仍然
-- 已更新，下次打开书架自然是最新的），也不能糊屏。
--
-- ⚠️ 以 mixin 方法（`self:is_widget_on_top(w)`）暴露：main.lua 的 show() 渲染去重
-- 也要用它判断「当前屏幕上的书架是不是就在最上层」。`self` 不使用。
function M.is_widget_on_top(self, widget)
    if not widget then return false end
    if not (UIManager and UIManager._window_stack) then return false end
    local ok, top = pcall(function()
        local stack = UIManager._window_stack
        local entry = stack[#stack]
        return entry and entry.widget
    end)
    if not ok then return false end
    return top == widget
end

--- 书架内容的轻量指纹：用来判断「后台同步是否真的改变了要显示的东西」。
--
-- 用途只有一个：**数据没变就不重渲染**。墨水屏上「整屏重画」的成本很高，
-- 而且 reading 的 show() 是全新构建菜单 —— 重渲染会把用户正在浏览的页码打回第一页。
-- 因此只有当书名 / 作者 / 阅读进度这几项真的变了，才值得换一屏。
--
-- 排序后再拼串：这样「用户改了排序方式」不会让指纹变化（排序不是数据变化，
-- 而且 show() 自己会重新排序，不该被后台刷新当成「内容变了」而重画）。
--
-- ⚠️ 历史上它是 `local function`，且**必须写在使用点（_complete_sync）之前** ——
-- 否则那处调用会解析成**全局查找**（运行期 nil，一调用就崩），静态检查也未必报出来。
-- 现改为模块方法（mixin 到插件上）：main.lua 的 show() 渲染去重也要用它算
-- 「内容键」（见 ReadingPlugin:_shelf_content_key），跨文件必须可见；改成方法后
-- 也不再受「定义位置必须在调用点之前」的约束。`self` 不使用。
function M.shelf_signature(self, books)
    if type(books) ~= "table" then return "" end
    local parts = {}
    for __, b in ipairs(books) do
        parts[#parts + 1] = tostring(b.name or b.title or "") .. "\1"
            .. tostring(b.author or "") .. "\1"
            .. tostring(b.durChapterIndex or "") .. "\1"
            .. tostring(b.totalChapterNum or "")
    end
    table.sort(parts)
    return #parts .. "#" .. table.concat(parts, "\2")
end

--- 统一的同步完成处理：更新书架 + 保存缓存 + 合并阅读记录 + 刷新 UI
-- @param sync_data table  { books, read_records }
-- @param opts table|nil
--        silent       boolean  true = 后台静默刷新：**不弹任何提示**，且只在
--                     「书架仍开着、令牌未被后续 show() 刷新」时原地重渲染。
--        expect_token number   配合 silent 使用的书架身份令牌（见 main.lua 的
--                     _shelf_token 说明）。
--        expect_sig   string|nil 同步前的书架指纹（见 shelf_signature）。一致则说明
--                     本次同步没带来任何要显示的变化 → 跳过重渲染。
function M._complete_sync(self, sync_data, opts)
    if not sync_data then return end
    opts = opts or {}

    self.bookshelf:apply_sync_data(sync_data)
    self.bookshelf:save_bookshelf_cache(self.bookshelf:get_books())

    -- 书架数据刚落盘，顺手做一次缓存 LRU 清理（同步本身已经付过网络往返的代价，
    -- 在这里搭车做文件系统扫描不会让用户多等一次卡顿）。
    pcall(function() self:cleanup_caches() end)

    local records = sync_data.read_records or {}

    -- 阅读记录合并**两种路径都要做**（这是数据，不是提示）：静默刷新若跳过它，
    -- 后台刷新就等于「云端阅读记录被丢掉」，下次手动同步才会补上 —— 语义不一致。
    local updated_count = 0
    if #records > 0 then
        updated_count = self.read_record:merge_from_sync(records)
    end

    if opts.silent then
        -- 【静默刷新】不弹「同步成功」，也**不能无条件重渲染**：
        --   · 用户可能已经点了某本书进详情页 / 退出了书架 —— 此时 show() 会把书架
        --     重新推到最上层，等于凭空弹一个界面出来（书架被盖住时句柄仍在，
        --     所以还要靠 is_widget_on_top 判「是不是还在最上层」）；
        --   · 期间可能又手动同步/切过筛选（又一次 show()），此时令牌已变，
        --     重渲染会把用户当前看到的那一份冲掉；
        --   · 内容压根没变（绝大多数后台刷新都是这种）—— 却整屏重画一次，
        --     还把用户正在浏览的页码打回第一页，纯亏。
        -- 四个条件都满足才重渲染：还是这一次渲染 + 句柄在 + 还在最上层 + 数据真的变了。
        local menu = UIHandles.get("menu")
        if not (opts.expect_token and self._shelf_token == opts.expect_token and menu) then
            Log.info("后台静默刷新完成，但书架已变化/已关闭，仅更新数据与缓存")
            return
        end
        if not self:is_widget_on_top(menu) then
            Log.info("后台静默刷新完成，但书架已不在最上层（用户已进入别的界面），仅更新数据与缓存")
            return
        end
        if opts.expect_sig and self:shelf_signature(self.bookshelf:get_books()) == opts.expect_sig then
            Log.info("后台静默刷新完成，书架内容无变化，跳过重渲染")
            return
        end
        Log.info("后台静默刷新完成，书架内容有更新，原地重渲染")
        self:show()
        return
    end

    if updated_count > 0 then
        self:showInfo(T(_("同步成功，更新了 %1 条阅读记录"), tostring(updated_count)))
    else
        self:showInfo(_("同步成功"))
    end

    if UIHandles.get("menu") then
        UIManager:close(UIHandles.get("menu"))
    end
    self:show()
end

--- 缓存 LRU 清理（上限 + 过期）。
--
-- 清理对象是**纯数据缓存**：章节缓存目录、TOC 缓存、TOC 锚点缓存。
-- ⚠️ `books/`（用户下载的整本 EPUB）**不在**清理范围内 —— 那是用户数据，
--    LRU 只能碰「删了还能自动重建」的东西。books/ 里唯一会被清的是
--    `*.epub.tmp` / `*.txt.tmp` 这类半截下载残留（断点续传的载体），
--    用 filter 精确收窄，绝不会误伤正主。
--
-- 由 _complete_sync 与插件 init 各调一次；重复调用是安全的（幂等）。
--
-- ⚠️ 本函数会在 **UI 线程**同步遍历若干目录（几万次 lfs.attributes），墨水屏上是有
-- 可感成本的。所以设了两道闸：① 进程级短路（每次启动最多一轮）；② 12 小时时间短路
-- （即使重启也不至于一天扫好几次）。清理本身是「删了还会自动重建」的数据，晚一点无妨。
-- @param force boolean 跳过两道短路（测试/调试用）
function M.cleanup_caches(self, force)
    -- 标记挂在**单例** bookshelf 上，才能跨插件实例共享（self 是实例级的）。
    local guard = self.bookshelf
    if not force and guard then
        if guard._cache_cleanup_done then return 0 end
        local last = guard._cache_cleanup_at or 0
        if (os.time() - last) < 12 * 3600 then return 0 end
        guard._cache_cleanup_done = true
        guard._cache_cleanup_at = os.time()
    end

    local max_age = (self.settings:get_cache_max_age_hours() or 48) * 3600
    local max_bytes_total = (self.settings:get_cache_max_mb() or 512) * 1024 * 1024

    -- 三个缓存目录各分到总量的 1/3：它们体量相近、又互相独立，
    -- 均分可以避免「章节缓存把整块预算吃光 → TOC 缓存刚写就被删」这种饥饿。
    local per_dir_bytes = math.max(1, math.floor(max_bytes_total / 3))

    local removed = 0
    for __, dir in ipairs({
        H.get_chapters_dir(),
        H.get_toc_dir(),
        H.get_toc_offset_dir(),
    }) do
        removed = removed + (H.lru_cleanup(dir, {
            max_age = max_age,
            max_bytes = per_dir_bytes,
            label = "[ReadingCache]",
        }) or 0)
    end

    -- books/ 里的半截下载残留：只清「陈旧到不可能再续传」的 *.tmp。
    -- 用一个比其它缓存更宽的窗口（≥ 3 天），否则「昨天取消的下载今天就续不上了」。
    local books_dir = H.get_books_dir()
    removed = removed + (H.lru_cleanup(books_dir, {
        max_age = math.max(max_age, 3 * 24 * 3600),
        max_bytes = math.huge,   -- 只按时间淘汰，不参与总量竞争（不能让残留挤掉正主）
        label = "[ReadingCache]",
        filter = function(name)
            return name:sub(-4) == ".tmp"
        end,
    }) or 0)

    if removed > 0 then
        Log.info("缓存清理完成，共删除 " .. removed .. " 项")
    end
    return removed
end

--- 书架「陈旧即后台刷新」——stale-while-revalidate。
--
-- `show()` 已经用本地缓存**同步渲染完毕**（打开书架永远零等待），这里只判断
-- 「缓存是不是已经很旧」，旧的话在后台补一次 WebDAV 同步：
--   · 成功且书架仍是「刚才那一次渲染」→ 用新数据原地重渲染，用户看到书架自己变新了；
--   · 成功但用户已切走 / 已关闭  → 只更新数据与缓存，不重渲染（绝不凭空弹界面）；
--   · 失败                      → 静默吞掉（**不弹任何提示**），下次打开书架再试。
--
-- 【为什么不用 showBusy】后台刷新对用户应该是无感的。一次网络抖动就在他打开书架时
-- 弹「同步失败」，比不刷新还糟。同理，这里也不调 showError。
--
-- @param shelf_token number  show() 本次渲染分配的令牌（见 main.lua 的 _shelf_token 说明）
function M._maybe_bg_revalidate_shelf(self, shelf_token)
    -- ① 只在文件管理器实例上跑：从阅读界面用派发器打开书架时，用户正在读书，
    --    不该有任何后台网络动作打扰（也避免与阅读进度同步抢网络）。
    if self.ui and self.ui.document then return end

    -- ② 重入保护用**时间戳**而不是布尔标志：_async_run 的句柄会在 onClose 时被
    --    整体取消，那一刻 on_done 不会再执行 —— 纯布尔标志会永久卡在 true，
    --    后台刷新从此彻底失效（一个非常难查的「静默失效」）。
    local started = self._bg_refresh_started_at
    if started and (os.time() - started) < 180 then
        Log.debug("后台书架刷新仍在进行（" .. (os.time() - started) .. "s），跳过")
        return
    end

    -- ③ 开关与前置条件。
    if not self.settings:is_shelf_auto_refresh_enabled() then return end
    local sync_cfg = self.settings:get("sync") or {}
    if sync_cfg.enabled == false then return end
    if (self.settings:get_webdav_server() or "") == "" then return end

    -- ④ 新鲜度：距上次成功同步还不到 TTL 就不折腾。
    local ttl_hours = self.settings:get_shelf_refresh_ttl_hours()
    local last = self.settings:get_last_sync_time()
    local age = os.time() - last
    if last > 0 and age < ttl_hours * 3600 then
        Log.debug(string.format("书架缓存尚新（%.1f 小时前同步过），跳过后台刷新", age / 3600))
        return
    end

    Log.info("书架缓存已陈旧（" .. (last == 0 and "从未同步" or string.format("%.1f 小时未同步", age / 3600))
        .. "），安排后台静默刷新")

    self._bg_refresh_started_at = os.time()
    local sync_ref = self.sync
    local self_ref = self
    -- 同步前先记下书架指纹，回来时比对：一致就不重渲染（见 shelf_signature）。
    local sig_before = self:shelf_signature(self.bookshelf:get_books())

    -- 延迟 0.3s：先让书架这一帧渲染出去（墨水屏刷屏本身有成本），再起后台任务。
    UIManager:scheduleIn(0.3, function()
        self_ref:_async_run(
            function()
                local ok, __, err = sync_ref:sync_from_webdav()
                if not ok then
                    return { ok = false, err = tostring(err) }
                end
                return { ok = true, data = sync_ref:get_sync_data() }
            end,
            function(ok, result, err)
                self_ref._bg_refresh_started_at = nil
                if not ok or not result or not result.ok then
                    -- 静默失败：后台刷新不该打断用户，日志留痕即可。
                    Log.warn("书架后台刷新失败（静默）: " .. tostring(err or (result and result.err)))
                    return
                end
                self_ref:_complete_sync(result.data, {
                    silent = true,
                    expect_token = shelf_token,
                    expect_sig = sig_before,
                })
            end,
            { timeout = 60 }
        )
    end)
end

--- 统一的回调保护包装器（替代原 safeCallback 和 _safeAsync）
-- @param label 描述（日志和错误提示用）
-- @param callback 实际函数
-- @return 包装后的函数，接受任意参数
function M._guard(self, label, callback)
    local self_ref = self
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, function(err) return tostring(err) end)
        if not ok then
            self_ref:showError(label, err)
        end
    end
end

--- 异步执行 work_func（在子进程中），完成后在 UI 线程回调 on_done(ok, result, err)。
--- Async 模块不可用时自动降级为 scheduleIn 同步执行（仍会短暂阻塞 UI）。
--- @param work_func function  子进程中执行的无参闭包，返回可 JSON 序列化值
--- @param on_done function|nil  回调 function(ok, result, err)
--- @param opts table|nil  { timeout=60, poll_interval=0.125, delay=0 }
function M._async_run(self, work_func, on_done, opts)
    -- 包装 on_done 以捕获回调异常（回调在 UI 线程执行，异常不应中断 UIManager）
    local safe_on_done = nil
    local handle_id = next_async_handle_id()
    local self_ref = self
    
    if on_done then
        safe_on_done = function(ok, result, err)
            -- 任务完成后清理句柄引用
            if self_ref._async_handles then
                self_ref._async_handles[handle_id] = nil
            end
            
            local call_ok, call_err = xpcall(function()
                on_done(ok, result, err)
            end, function(e) return tostring(e) end)
            if not call_ok then
                Log.error("_async_run 回调异常: " .. call_err)
            end
        end
    else
        safe_on_done = function()
            if self_ref._async_handles then
                self_ref._async_handles[handle_id] = nil
            end
        end
    end
    
    if Async and Async.run then
        local handle = Async.run(work_func, safe_on_done, opts)
        if handle and self._async_handles then
            self._async_handles[handle_id] = handle
        end
        return handle
    end
    -- 降级：scheduleIn 同步执行（UI 线程阻塞）
    opts = opts or {}
    UIManager:scheduleIn(opts.delay or 0, function()
        local ok, result = pcall(work_func)
        if safe_on_done then
            if ok then safe_on_done(true, result, nil)
            else safe_on_done(false, nil, tostring(result)) end
        end
    end)
    return nil
end

--- 取消特定的异步任务或所有任务
--
-- 调用方只会传 nil（取消全部）或一个句柄 table（download_cloud_book 的
-- `self:_cancel_async(h)`）。历史上还有一条 `type(handle_or_id) == "string"` 的
-- 「按 ID 取消」分支，但全仓没有任何调用点走它 —— 已删。
function M._cancel_async(self, handle_or_id)
    if not self._async_handles then return end

    if handle_or_id == nil then
        -- 取消所有任务
        for id, handle in pairs(self._async_handles) do
            if type(handle) == "table" and type(handle.cancel) == "function" then
                pcall(handle.cancel)
            end
        end
        self._async_handles = {}
    elseif type(handle_or_id) == "table" and type(handle_or_id.cancel) == "function" then
        -- 直接通过句柄取消
        pcall(handle_or_id.cancel)
        -- 尝试从集合中移除
        for id, h in pairs(self._async_handles) do
            if h == handle_or_id then
                self._async_handles[id] = nil
                break
            end
        end
    end
end

-- ============================================================================
-- 「书籍下载」会话（单槽位）
-- ============================================================================
--
-- 【为什么必须收敛成一个句柄】详情页的「下载 / 更新书籍」（reading/book_detail.lua）
-- 与云端书库的「下载」（本文件 download_cloud_book）是两条独立入口，此前各自在实例上
-- 存自己的字段（`_download_epub_handle` 与 `_download_handle`），于是：
--   ① 两条路径互相 `_cancel_async` 不到 —— 用户从详情页点下载、又去云端书库点同一本，
--      会**同时跑两个子进程**，两个都往 `books/<name>.epub`（以及它的 `.tmp`）里写，
--      落盘结果互相覆盖，最终是一份谁都不认识的坏文件；
--   ② 屏幕上会同时挂两个「下载中」进度窗，各自显示一半进度；
--   ③ 先发起的那条路径写坏的 `.tmp` 还会被后来的续传当成断点继续追加。
--
-- 现在两条路径共用 `self._book_download` 这**一个**槽位：
--   · 开始前调 `_begin_book_download()`（会先整体收掉上一次会话）；
--   · 完成 / 失败时调 `_end_book_download(session)`。
--
-- ⚠️ 刻意**不**做成队列：本插件的下载是「用户点一本书、等它下完」，没有并发度控制、
--    没有优先级、没有暂停恢复；加一个队列等于引入一整套新的失败面（队列卡死、
--    进度归属、取消语义）。单槽位 + 「后来的顶掉先前的」是当前 UI 下最不容易出错的语义。

--- 登记一个新的「书籍下载」会话（单槽位）。已有会话会被先整体收掉。
-- @return table 新会话 `{}`，调用方自行挂 `handle` / `progress` / `on_dispose`
function M._begin_book_download(self)
    self:_cancel_book_download()
    local session = {}
    self._book_download = session
    Log.debug("开始新的书籍下载会话（单槽位）")
    return session
end

--- 收掉当前登记中的「书籍下载」会话：取消子进程 + 执行会话自带的清理 + 关掉进度窗。
--
-- @param keep_progress_widget boolean|nil
--        传 true 表示**不**关闭进度窗，交给调用方自己收 —— 用于「用户主动点取消」：
--        要先把「下载已取消」这句提示渲染出去，延迟 0.8s 再关窗，
--        否则点下去窗口瞬间消失，用户会以为自己点错了。
-- @param expect table|nil
--        只收掉这一个会话（身份比对）：不匹配就什么都不做。
--        用于「某个进度窗的取消按钮」—— 窗口可能是上一次下载遗留的，
--        它的按钮**绝不能**去杀掉当前正在跑的那个会话。
-- @return table|nil 被收掉的会话（便于调用方接管进度窗）；没有会话 / 身份不匹配时返回 nil
function M._cancel_book_download(self, keep_progress_widget, expect)
    local s = self._book_download
    if not s then return nil end
    if expect and s ~= expect then return nil end
    self._book_download = nil

    -- 会话自带的清理（停轮询定时器、删 .progress 临时文件、关 busy 提示等）。
    -- 必须在取消子进程**之前**跑：那些句柄是会话的一部分，先跑完才不会留下孤儿定时器。
    if s.on_dispose then
        local ok, err = pcall(s.on_dispose)
        if not ok then
            Log.warn("书籍下载会话清理异常: " .. tostring(err))
        end
    end

    if s.handle then
        local h = s.handle
        s.handle = nil
        local ok, err = pcall(function() self:_cancel_async(h) end)
        if not ok then
            Log.warn("终止下载子进程失败: " .. tostring(err))
        end
    end

    if s.progress and not keep_progress_widget then
        pcall(function() s.progress:close() end)
    end
    return s
end

--- 结束会话：**仅当它仍是当前会话时**才清空。
--
-- 身份比对（而不是无条件置 nil）是必需的：若 A 被后来的 B 顶掉，而 A 的收尾回调
-- 迟到（降级同步路径下 on_done 可能已经排进 UIManager 队列），无条件置 nil 会把
-- **B 的会话**抹掉 —— 于是 B 再也无法被取消，进度窗也再没人关（静默失效，很难查）。
function M._end_book_download(self, session)
    if session and self._book_download == session then
        self._book_download = nil
        return true
    end
    return false
end

function M.show_cloud_library(self, menu_instance)
    local busy = self:showBusy(_("正在获取云端书库..."))
    
    local sync_ref = self.sync
    local self_ref = self
    self:_async_run(
        function()
            local ok, epub_files, err = sync_ref:list_books_directory()
            if not ok then
                return { ok = false, err = err }
            end
            return { ok = true, files = epub_files }
        end,
        function(ok, result, err)
            self_ref:closeBusy(busy)
            if not ok or not result or not result.ok then
                local err_msg = tostring(err or (result and result.err) or _("未知错误"))
                self_ref:showInfo(T(_("获取云端书库失败:\n%1"), err_msg), false)
                return
            end
            ShelfView.show_cloud_library_list(result.files, function(file)
                self_ref:download_cloud_book(file, menu_instance)
            end)
        end,
        { timeout = 30 }
    )
end

-- @param opts table|nil
--        opts.overwrite_confirmed boolean
--            内部使用：用户已在「覆盖确认」框里点过「覆盖」。带它重入本函数会跳过确认，
--            避免「确认 → 再确认」的死循环。外部调用点**不要**传这个键。
function M.download_cloud_book(self, file, menu_instance, opts)
    opts = opts or {}
    local DownloadProgress = require("reading.download_progress")

    -- 清理文件名：去除 Legado 导出的重复后缀如 " (1)"，以便直接覆盖旧文件，防止产生两条书架记录。
    -- （实现已抽到 H.clean_legado_filename，与「更新书籍」路径 download_epub_for_book 共用 ——
    --  那条路径原先没有这个清理，更新后本地会留下新旧两份文件。）
    -- 路径在进入 0.1s 延迟前就算好（纯字符串运算，不阻塞 UI），
    -- 这样 on_cancel 才拿得到路径去清理临时 .progress 文件。
    local clean_filename = H.clean_legado_filename(file.name)
    local save_path = H.join_path(H.get_books_dir(), clean_filename)

    -- ==================================================================
    -- 【覆盖前的二次确认】
    -- ==================================================================
    -- 本入口的语义是「把这本书的**这个云端版本**下到本地」。若本地已有同名文件，
    -- sync.download_epub 落盘时那句 `os.rename(tmp_path, save_path)` 会**静默替换**它。
    -- 而用户完全可能自己换过一份同名 EPUB、或手工拷进来过 —— 覆盖不可逆，必须先问一句。
    --
    -- 三个条件同时成立才判定为「覆盖」（缺一不可）：
    --   ① 本地文件存在   —— 不存在就谈不上覆盖；
    --   ② 云端 size 已知 —— 拿不到 size 就无法判定「是不是同一份」；
    --   ③ 两边 size 不同 —— size 相同 = 同一份，下面 0.1s 延迟里的短路分支会直接提示
    --      「文件已存在」，那种情况**根本不下载**，弹确认框纯属多余。
    --
    -- ⚠️ 时机：必须在 `_begin_book_download()` **之前**。确认框还挂在屏幕上时，
    --    ① 不该抢掉别的下载会话（登记会取消前一个）；② 不该先把进度窗建出来 ——
    --    否则用户点「取消」时那个窗口归谁收就成了新问题。
    --    由此得到一条顺序不变式：本函数一旦走到「登记」那一步，就必须紧接着建进度窗，
    --    两者之间不允许再有任何可能提前 return 的分支。
    if not opts.overwrite_confirmed then
        local existing_size = H.get_file_size(save_path)
        if existing_size > 0 and file.size and file.size > 0 and existing_size ~= file.size then
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = T(_("本地已有同名文件《%1》\n\n本地 %2\n云端 %3\n\n继续将用云端版本覆盖本地文件，且无法恢复。"),
                    clean_filename,
                    H.format_file_size(existing_size),
                    H.format_file_size(file.size)),
                ok_text = _("覆盖"),
                cancel_text = _("取消"),
                ok_callback = function()
                    -- 延后一帧再重入：ok_callback 是在 ConfirmBox 关闭自己的过程中被调用的，
                    -- 此刻同步 show 出一个新 widget（进度窗）容易和它这一帧的收尾打架。
                    -- 重入这一步包 _guard：它下面就是异步下载入口，抛错会掀掉整个 KOReader。
                    UIManager:scheduleIn(0.1, self:_guard(_("覆盖本地书籍"), function()
                        self:download_cloud_book(file, menu_instance, { overwrite_confirmed = true })
                    end))
                end,
            })
            return
        end
    end

    -- 【单会话登记】第一件事就是收掉上一次可能还在跑的书籍下载（无论它来自本入口
    -- 还是详情页入口），并把本次登记为当前会话。理由见文件上方「书籍下载会话」一节。
    --
    -- ⚠️ 顺序：先登记（顺带收掉旧会话的进度窗），再建本次的进度窗 ——
    --    反过来会让旧会话的收尾把本次刚弹出来的窗口一起关掉。
    local session = self:_begin_book_download()

    local progress_path = save_path .. ".progress"

    local self_ref = self

    -- 进度轮询的停止开关。
    --
    -- ⚠️ 不能用 `handle = UIManager:scheduleIn(...)` 的返回值来停定时器：
    --    `UIManager:scheduleIn` **没有 return**（koreader-master/frontend/ui/uimanager.lua:335
    --    内部只调 `self:schedule(when, action)`），返回值恒为 nil。
    --    写成 `local h = UIManager:scheduleIn(...)` + `if h then unschedule(h) end`
    --    时，`h` 永远是 nil → 停止逻辑是死代码 → 轮询以 1Hz **永远跑下去**：
    --    每完成一次下载就多留一个常驻定时器，墨水屏设备再也进不了空闲。
    --    正确做法：独立布尔标志 + 用「函数自身」作为 unschedule 的键。
    local poll_stopped = false
    local poll_progress

    local function stop_poll()
        poll_stopped = true
        if poll_progress then
            UIManager:unschedule(poll_progress)
        end
    end

    -- 取消 / 超时 / 网络失败后的收尾。
    --
    -- 【为什么不再删除半截文件】下载已改为「.tmp + rename 原子写」（见 sync.download_epub）：
    -- 半截数据落在 `save_path .. ".tmp"` 里，**对书架完全不可见**（书架只按 %.epub$ 匹配），
    -- 于是原先「留着半截 EPUB 会被当成一本打不开的书」的动机已经消失；
    -- 而保留它正是**断点续传**的前提 —— 下次下载同一本书直接从已有字节继续。
    -- 长期残留由 cleanup_caches 按 max_age（≥3 天）兜底清理。
    local function note_partial_kept()
        local partial = H.get_file_size(save_path .. ".tmp")
        if partial > 0 then
            Log.info("保留断点文件 " .. partial .. " 字节供续传: " .. tostring(save_path))
        end
    end

    -- 会话被外部收掉时（被另一条入口的下载顶掉，或插件 onClose）的清理动作。
    -- 与「用户点取消」共用同一套收尾，区别只在进度窗的措辞与关闭时机。
    session.on_dispose = function()
        stop_poll()
        os.remove(progress_path)
        note_partial_kept()
    end

    local progress
    progress = DownloadProgress:new{
        title = _("下载书籍"),
        on_cancel = function()
            -- P1-2 修复：原实现只置 self._download_cancelled = true，而该标志全仓库
            -- 从未被读取，子进程会一直下载到结束、临时文件也不会清理。
            -- 现在统一走会话收尾：真正终止子进程 + 停轮询 + 清临时进度文件
            -- （这三件事在 session.on_dispose 里）。
            --
            -- keep_progress=true：进度窗**不**在这里关 —— 先把「下载已取消」渲染出去，
            -- 0.8s 后再收；否则点下去窗口瞬间消失，用户会以为是自己点错了。
            -- expect=session：只允许这个按钮收掉**它自己的**那个会话。
            local s = self_ref:_cancel_book_download(true, session)
            if not s then
                -- 会话已经结束（下载其实已成功/失败，只是窗口还没收）或已被顶掉：
                -- 直接收窗，别把它停在按钮刚写上的「正在取消……」那一帧。
                UIManager:scheduleIn(0.3, function()
                    pcall(function() progress:close() end)
                end)
                return
            end
            if s.progress then
                local p = s.progress
                pcall(function()
                    p:setState{ stage = "cancelled", message = _("下载已取消") }
                end)
                UIManager:scheduleIn(0.8, function()
                    pcall(function() p:close() end)
                end)
            end
        end,
    }
    session.progress = progress
    progress:show()
    
    UIManager:scheduleIn(0.1, self:_guard(_("下载书籍"), function()
        if progress:isCanceled() then
            -- 用户在 0.1s 延迟里就点了取消：on_cancel 已收掉会话，这里只补关窗口。
            self_ref:_end_book_download(session)
            progress:close()
            return
        end

        progress:setState{ 
            stage = "content", 
            file = file.name,
            current = 1,
            total = 1,
            percent = 0,
            message = _("正在下载...") 
        }

        local books_dir = H.get_books_dir()
        H.make_dir(books_dir)

        if H.file_exists(save_path) then
            local local_size = H.get_file_size(save_path)
            if local_size and file.size and local_size == file.size then
                self_ref:_end_book_download(session)
                progress:setState{ stage = "done", message = _("文件已存在") }
                UIManager:scheduleIn(1, function() 
                    progress:close() 
                    self:_ensure_book_in_shelf(clean_filename, file.name)
                    if menu_instance and not menu_instance._reading_closed then
                        UIManager:close(menu_instance)
                        self:show()
                    end
                end)
                return
            end
        end

        local sync_ref = self.sync

        -- 保存句柄到会话，供「取消下载」与「被另一条入口顶掉」真正终止子进程使用
        session.handle = self:_async_run(
            function()
                -- 【进度文件写盘失败只告警一次】本回调每个 HTTP chunk 都可能触发，
                -- 磁盘满时逐次打日志会把日志刷爆，也没有意义（父进程只会一直读到旧进度）。
                local progress_write_warned = false
                -- 【进度落盘节流】本回调每个 HTTP chunk（约 8KB）都会触发，原实现对每个
                -- chunk 都 json_encode + 开/写/关一个进度文件 —— 一本 20MB 的书约 2500 次
                -- 落盘 + 2500 次 JSON 编码，在墨水屏设备上是可观的 eMMC 写入。
                -- 改为「距上次落盘 ≥1s 或新增 ≥64KB 才落盘」，但**最后一次
                -- （downloaded >= total）必定落盘**，保证父进程能读到 100%。
                local PROGRESS_MIN_INTERVAL = 1        -- 秒（os.time 的粒度）
                local PROGRESS_MIN_BYTES = 64 * 1024
                local last_progress_t = 0
                local last_progress_bytes = -1
                local progress_cb = function(downloaded, total)
                    local now = os.time()
                    local is_final = (total and total > 0 and downloaded >= total)
                    if not is_final and last_progress_t > 0
                        and (now - last_progress_t) < PROGRESS_MIN_INTERVAL
                        and (downloaded - last_progress_bytes) < PROGRESS_MIN_BYTES then
                        return
                    end
                    last_progress_t = now
                    last_progress_bytes = downloaded
                    -- IPC 机制：将进度写入临时文件，父进程轮询读取
                    local progress_data = {
                        downloaded = downloaded,
                        total = total,
                        time = os.time()
                    }
                    local pfile, open_err = io.open(progress_path, "w")
                    if pfile then
                        -- 同日志模块：write 与 close 都要查（ENOSPC 常常只在 close 暴露）
                        local w_ok, w_err = pfile:write(H.json_encode(progress_data))
                        local c_ok, c_err = pfile:close()
                        if (not w_ok or c_ok == nil) and not progress_write_warned then
                            progress_write_warned = true
                            Log.warn("写入下载进度文件失败: " .. tostring(w_err or c_err))
                        end
                    elseif not progress_write_warned then
                        progress_write_warned = true
                        Log.warn("无法创建下载进度文件: " .. tostring(open_err))
                    end
                end
                
                -- force_overwrite = false：本路径的语义是「把这本书下到本地」，不是
                -- 「强制用云端覆盖本地版本」——「已存在且大小相同」的短路判断上面已经
                -- 单独做过（见 H.file_exists(save_path) 那段），不需要再靠 force 来兜。
                -- 传 false 的**关键收益**是允许断点续传：上一版传 true，会让
                -- sync.download_epub 一律丢弃已有断点（那是「更新书籍」才需要的保护）。
                local ok, __, result = sync_ref:download_epub(file.path, save_path, false, file.size, progress_cb)
                if not ok then
                    return { ok = false, err = result }
                end
                return { ok = true, skipped = (result == "skipped") }
            end,
            function(ok, result, err)
                self_ref:_end_book_download(session)
                -- 清理轮询定时器和临时进度文件
                stop_poll()
                os.remove(progress_path)
                
                if not ok or not result or not result.ok then
                    -- 超时 / 网络失败与取消一样会留下半截文件 —— 但**不删**：
                    -- 那是断点续传的载体（在 save_path .. ".tmp" 里，对书架不可见）。
                    note_partial_kept()
                    progress:setState{ stage = "error", message = tostring(err or (result and result.err) or _("未知错误")) }
                    UIManager:scheduleIn(1.5, function() progress:close() end)
                    return
                end

                progress:setState{ stage = "done", percent = 1,
                    message = result.skipped and _("文件已存在") or _("下载成功") }
                UIManager:scheduleIn(1.0, function() 
                    progress:close() 
                    self_ref:_ensure_book_in_shelf(clean_filename, file.name)
                    if menu_instance and not menu_instance._reading_closed then
                        UIManager:close(menu_instance)
                        self_ref:show()
                    end
                end)
            end,
            { timeout = 120 }
        )
        
        -- 父进程轮询读取进度并更新 UI
        poll_progress = function()
            if poll_stopped or progress:isCanceled() then return end
            local progress_file = io.open(progress_path, "r")
            if progress_file then
                local content = progress_file:read("*all")
                progress_file:close()
                if content and content ~= "" then
                    local data = H.json_decode(content)
                    if data and data.total and data.total > 0 then
                        local percent = data.downloaded / data.total
                        local msg = string.format("已下载 %.1f MB / %.1f MB", data.downloaded/1024/1024, data.total/1024/1024)
                        progress:setState{ stage = "content", percent = percent, message = msg }
                    end
                end
            end
            UIManager:scheduleIn(1.0, poll_progress)
        end
        UIManager:scheduleIn(1.0, poll_progress)
    end))
end

return M
