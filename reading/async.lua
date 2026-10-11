-- reading/async.lua
-- 异步子进程执行模块：把阻塞的网络/IO 操作放到子进程，UI 线程通过
-- UIManager:scheduleIn 轮询管道，保持 KOReader 界面响应。
--
-- 设计参考 fanqie/async.lua 的管道通信模式（runInSubProcess + pipe），
-- 以及 koreader frontend/ui/trapper.lua 的 dismissableRunInSubprocess。
-- 区别于 trapper 的是：本模块不依赖 TrapWidget，采用纯回调驱动（on_done），
-- 适合"后台静默执行"的进度上传 / 进度拉取 / EPUB 下载场景。
--
-- 协议：子进程执行 work_func，把结果以 JSON 写入管道后关闭 fd：
--   成功: {"ok":true,"result":<可序列化值>}
--   失败: {"ok":false,"err":"<错误信息>"}
-- 父进程在 UI 线程轮询 getNonBlockingReadSize / isSubProcessDone，
-- 一次性 readAllFromFD 读取并解析，最后回调 on_done(ok, result, err)。
--
-- 不支持子进程时（Windows 测试环境 / 旧版无 fork）自动降级为
-- "延后同步执行"，保证功能可用，只是仍会短暂阻塞。

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Log, Log = pcall(require, "reading.log")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Async = {}

--- 当前运行环境是否支持子进程（POSIX fork + 管道）。
function Async.is_available()
    return ok_ffiutil
        and ffiutil
        and type(ffiutil.runInSubProcess) == "function"
        and type(ffiutil.writeToFD) == "function"
        and type(ffiutil.readAllFromFD) == "function"
        and type(ffiutil.getNonBlockingReadSize) == "function"
        and type(ffiutil.isSubProcessDone) == "function"
end

local function json_encode(v)
    if not ok_json or not json then return nil end
    local ok, s = pcall(function()
        if json.encode then return json.encode(v) end
        return json:encode(v)
    end)
    if ok then return s end
    return nil
end

local function json_decode(s)
    if not ok_json or not json then return nil end
    local ok, v = pcall(function()
        if json.decode then return json.decode(s) end
        return json:decode(s)
    end)
    if ok then return v end
    return nil
end

-- 把任意错误信息清理成单行字符串，避免 JSON/协议被换行污染。
local function sanitize_err(err)
    local s = tostring(err or "unknown error")
    s = s:gsub("[%c]", " ")
    if #s > 1000 then s = s:sub(1, 1000) .. "..." end
    return s
end

--- 延后同步执行（降级路径）：在 UI 线程跑 work_func，立即回调。
local function run_sync(work_func, on_done, delay)
    if not ok_UIManager or not UIManager then
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
        return nil
    end
    UIManager:scheduleIn(delay or 0, function()
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
    end)
    return nil
end

--- 在子进程中执行 work_func（无参闭包，返回可 JSON 序列化值或抛错），
--- 完成后在 UI 线程回调 on_done(ok, result, err)。
---
--- @param work_func function  子进程内执行的工作函数（闭包捕获的状态在 fork 时被继承）
--- @param on_done    function|nil  回调 function(ok, result, err)，在 UI 线程运行
--- @param opts       table|nil  { delay=0, poll_interval=0.125, timeout=60 }
--- @return handle|nil  返回句柄 { cancel=fn, pid=... }；降级同步时返回 nil
function Async.run(work_func, on_done, opts)
    opts = opts or {}
    -- 轮询间隔：0.125s（8Hz）。原为 0.05s（20Hz）—— 一次 10 分钟下载会多出
    -- 上万次 scheduleIn 与 FFI 调用，而进度显示并不需要 20Hz 的精度。
    local poll_interval = opts.poll_interval or 0.125
    local timeout = opts.timeout or 60
    local delay = opts.delay or 0

    if not Async.is_available() then
        if ok_Log then Log.debug("[async] 子进程不可用，降级同步执行") end
        return run_sync(work_func, on_done, delay)
    end

    -- 子进程入口：执行 work_func，把结果以 JSON 写回管道并关闭 fd。
    local function child_entry(pid, child_write_fd)
        local ok, result = pcall(work_func)
        local payload
        if ok then
            local enc = json_encode({ ok = true, result = result })
            payload = enc or '{"ok":true,"result":null}'
        else
            local enc = json_encode({ ok = false, err = sanitize_err(result) })
            payload = enc or '{"ok":false,"err":"encode failed"}'
        end
        -- ⚠️ pcall 的返回值必须看：写管道失败（对端已关闭 / 管道已满）时若静默丢弃，
        -- 父进程侧会走「子进程已结束但读不到数据 → 视为成功、result=nil」（见下方 poll），
        -- 于是「子进程写不出去」被当成「子进程成功且无返回值」。这里至少留一条日志。
        local write_ok, write_err = pcall(ffiutil.writeToFD, child_write_fd, payload, true)
        if not write_ok and ok_Log then
            Log.warn("[async] 子进程写回结果失败（父进程可能误判为「无输出=成功」）: "
                .. tostring(write_err))
        end
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(child_entry, true)
    if not pid then
        if ok_Log then Log.warn("[async] runInSubProcess 启动失败，降级同步") end
        return run_sync(work_func, on_done, delay)
    end

    local handle = { pid = pid, fd = parent_read_fd, _cancelled = false }
    local start_clock = os.time()

    -- 收尸间隔（秒）。取消/超时后不阻塞等子进程，交给 UIManager 稍后来收。
    local REAP_INTERVAL = 5
    -- 收尸次数上限：避免「terminateSubProcess 不可用 + 子进程卡在 I/O」时无限
    -- scheduleIn，既刷爆事件队列又永不关闭管道 fd。12 次 ≈ 60s，足够覆盖正常收尾，
    -- 超出即放弃轮询（日志告警），把 fd 留给进程退出时的兜底清理。
    local REAP_MAX_ATTEMPTS = 12

    -- 异步收尸：关闭管道 fd、并让内核 reap 掉子进程，避免 fd 泄漏与僵尸进程。
    --
    -- ⚠️ 这里**绝不能**同步阻塞读。ffiutil.readAllFromFD 会一直读到写端关闭，
    -- 子进程还在下载时它一秒都不会返回。也就是说：若「先排空管道、再杀进程」
    -- （fanqie/koobone 版 async.lua 的原始顺序，本文件此前照抄了它），
    -- 点「取消」这个动作本身就会把 UI 冻到下载自然结束 —— 取消按钮等于没有，
    -- 而且用户会以为是自己点错了。见 koreader 上游
    -- frontend/ui/trapper.lua:dismissableRunInSubprocess 的 collect_and_clean：
    -- 那边同样是「先 terminateSubProcess，再 scheduleIn 异步收」，从不同步读。
    local function reap(pid_ref, fd_ref, attempt)
        attempt = attempt or 0
        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            -- 还在跑（已收到终止信号但尚未被 wait 掉，或终止 API 缺失）。
            -- 稍后再来，绝不在 UI 线程上等它。
            if attempt >= REAP_MAX_ATTEMPTS then
                if ok_Log then
                    Log.warn("[async] 收尸重试超过 " .. REAP_MAX_ATTEMPTS
                        .. " 次仍未结束，放弃轮询；fd 交由进程退出时回收")
                end
                return
            end
            UIManager:scheduleIn(REAP_INTERVAL, function()
                reap(pid_ref, fd_ref, attempt + 1)
            end)
            return
        end
        -- 子进程已结束：此刻读管道会立即 EOF，顺带关闭自己这一端的 fd
        if fd_ref then
            pcall(ffiutil.readAllFromFD, fd_ref)
        end
    end

    -- 非阻塞地终止子进程，并把收尾交给异步收尸。「取消」与「超时」共用。
    local function abort_subprocess()
        local pid_ref, fd_ref = handle.pid, handle.fd
        handle.fd = nil   -- 句柄交给收尸函数，poll 不再碰它

        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            if type(ffiutil.terminateSubProcess) == "function" then
                pcall(ffiutil.terminateSubProcess, pid_ref)
            elseif ok_Log then
                Log.warn("[async] terminateSubProcess 不可用，改为等待子进程自然结束")
            end
        end

        reap(pid_ref, fd_ref)
    end

    handle.cancel = function()
        if handle._cancelled then return end   -- 幂等：连点两次取消不会重复收尸
        handle._cancelled = true
        abort_subprocess()
    end

    -- 读取宽限期（秒）：发现管道有数据、但子进程尚未结束时，先等这么久再读。
    -- 正常路径下子进程写完 payload 立刻退出，会走 subprocess_done 分支立即读取；
    -- 只有 payload 撑爆管道（Linux 默认 64KB）导致子进程 write 阻塞时，
    -- 才由这条兜底路径把数据读走、解开僵局。
    local READ_GRACE = 2
    local data_seen_at = nil

    local function poll()
        if handle._cancelled then return end

        if os.difftime(os.time(), start_clock) > timeout then
            if ok_Log then Log.warn("[async] 子进程超时 " .. timeout .. "s，终止") end
            abort_subprocess()
            if on_done then on_done(false, nil, "async timeout") end
            return
        end

        local subprocess_done = ffiutil.isSubProcessDone(pid)
        local has_data = parent_read_fd ~= nil
            and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0

        if has_data and not data_seen_at then
            data_seen_at = os.time()
        end

        -- ⚠️ readAllFromFD 是**阻塞读到 EOF**，只有两种情况才允许调用：
        --   ① subprocess_done 为真：写端已关闭，read 会立即 EOF；
        --   ② 管道已有数据、但子进程迟迟不结束且超过宽限期：说明 payload 撑爆了
        --      管道容量，子进程正卡在 write 上，必须由父进程读走才能解开。
        -- 其余情况（子进程在跑、还没写出东西）一律不读 —— 否则界面会被冻住，
        -- 这正是「点取消却卡住」那个 bug 的同源问题。
        local should_read = has_data
            and (subprocess_done
                or os.difftime(os.time(), data_seen_at) >= READ_GRACE)

        if not should_read and not subprocess_done then
            UIManager:scheduleIn(poll_interval, poll)
            return
        end

        local result_ok, result_val, result_err
        if should_read then
            local ret_str = ffiutil.readAllFromFD(parent_read_fd)
            handle.fd, parent_read_fd = nil, nil
            local decoded = ret_str and json_decode(ret_str)
            if type(decoded) == "table" then
                if decoded.ok then
                    result_ok, result_val = true, decoded.result
                else
                    result_ok, result_err = false, decoded.err or "unknown error"
                end
            elseif subprocess_done then
                result_ok, result_val = true, nil
            else
                result_ok, result_err = false, "malformed subprocess output"
            end
        else
            -- 子进程已结束，但没有通过管道返回数据。这在 KOReader 的异步网络请求中经常发生，应视为无返回值的成功。
            if parent_read_fd then
                pcall(ffiutil.readAllFromFD, parent_read_fd)
                handle.fd, parent_read_fd = nil, nil
            end
            result_ok, result_val = true, nil
        end

        -- 若此刻子进程尚未结束（走的是宽限期兜底路径），交给异步收尸，绝不阻塞等待。
        -- subprocess_done 为真时 reap 会立即返回，不产生额外开销。
        reap(pid, nil, 0)

        if on_done and not handle._cancelled then
            if result_ok then
                on_done(true, result_val, nil)
            else
                on_done(false, nil, result_err)
            end
        end
    end

    UIManager:scheduleIn(delay, poll)
    return handle
end

return Async
