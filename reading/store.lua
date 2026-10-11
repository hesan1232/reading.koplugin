--[[
    进程级单例状态容器（架构报告 §9-1 / P0-4）。

    问题：KOReader 会为 FileManager 与每个 ReaderUI 各创建一个插件实例，而每个实例
    的 init() 都会各自 Settings:new() / Sync:new() / Bookshelf:new() / ReadRecord:new()，
    于是同一批磁盘文件（reading.lua、bookshelf_cache.lua、read_records.lua）被两套
    内存模型并发读写 —— 这就是「状态归属分裂」。代码里原有的三处「补丁」全是它的症状：
      ① load_bookshelf_cache 的 mtime 比对
      ② save_bookshelf_cache 的「books 为空则拒绝保存」守卫
      ③ _detect_current_book 里「ReaderUI 实例按需重新加载缓存」

    现在把这 4 个有状态模块收敛到本单例，所有实例共享同一份内存模型。

    ⚠️ 刻意**不**纳入单例的实例级状态：
      - _async_handles / _book_download：onClose 会无条件调用 _cancel_async()
        取消「本实例」的全部任务；若共享，关闭阅读器就会误杀书架实例正在跑的下载。
        （_book_download 是「书籍下载」单槽位会话，见 downloader._begin_book_download。）
      - _last_seen_chapter / _last_seen_page：位置去抖的「上一次观察值」，
        只在阅读会话内才有意义，属 ReaderUI 实例私有 —— 页码是**每本书各自编号**的，
        跨实例共享会让新书的首帧被误判成「翻页」，从而凭空安排一次上传。
      - _pending_progress_upload：去抖上传的定时器句柄（闭包），同理属实例私有 ——
        若共享，一个实例的 onClose 会把另一个实例正在等的上传取消掉。
      - _pending_auto_compare：自动对比（打开书 / 回到前台）的任务句柄（闭包），同上。
]]

local H = require("reading.helper")
local Log = require("reading.log")
local Settings = require("reading.settings")
local Sync = require("reading.sync")
local Bookshelf = require("reading.bookshelf")
local ReadRecord = require("reading.read_record")

local Store = {}

local instance = nil

--- 取得（首次调用时构造）进程级单例状态。
-- 所有实例共享同一份 settings / sync / bookshelf / read_record。
function Store.get()
    if instance then
        return instance
    end

    -- ① 先建立日志文件路径（此时保持默认关闭），
    --    这样 Settings:new() 内部 config.lua 的播种 / 升级迁移过程才能落盘。
    Log.init(H.get_data_dir() .. "/reading.log")

    local settings = Settings:new()

    -- ② 配置就绪后立刻按 advanced.developer_logs（或 config.lua）决定 DEBUG 级别，
    --    保证紧随其后的三个模块构造日志能按用户选择输出。
    Log.set_debug_enabled(settings:is_developer_logs_enabled())
    Log.info("调试日志: " .. (Log.is_debug_enabled() and "开启" or "关闭")
        .. "，日志文件: " .. tostring(Log.get_log_file_path()))

    instance = {
        settings = settings,
        sync = Sync:new(settings),
        bookshelf = Bookshelf:new(settings),
        read_record = ReadRecord:new(settings),
    }

    -- ③ 单例下书架缓存只加载一次，此后内存即权威副本。
    --    这一步是「消除补丁」的前提：只有 books 一开始就非空，
    --    才不会出现「某实例拿空表去覆盖缓存」的场景。
    instance.bookshelf:load_bookshelf_cache()

    return instance
end

--- 仅供测试 / 热重载使用：丢弃单例（下次 Store.get() 重新构造）。
function Store.reset()
    instance = nil
end

return Store
