--[[
    阅读上下文状态模块

    封装"当前阅读会话"状态，提供访问器、generation 令牌、进度快照、统一清理。
    所有字段对外通过 getter/setter 访问，禁止直接读写。

    设计要点：
    - _generation 在 set_current_book 时自增；异步回调捕获快照，执行时比对，
      不一致即放弃，避免切书瞬间旧回调上传旧书进度。
    - clear_reading_context() 不重置 generation，让旧回调仍能识别自己已过期。
    - snapshot_progress() 提取进度快照（带 generation），供 onCloseDocument 异步上传使用。
]]

local Log = require("reading.log")

local Context = {}

-- 模块级私有状态（外部无法直接访问）
local _ctx = {
    current_book = nil,
    current_chapters = nil,
    current_chapter_index = 1,
    current_epub_path = nil,
    pending_jump = nil,
    chapter_range_cache = nil,
}

-- 生成令牌：每次 set_current_book 自增
local _generation = 0

-------------------------------------------------------------------------------
-- current_book
-------------------------------------------------------------------------------
function Context.get_current_book()
    return _ctx.current_book
end

function Context.set_current_book(book)
    -- 换书时章节范围缓存必然失效，必须清掉。
    --
    -- 这个缓存是「当前页 → 章节」的快速路径（onPageUpdate 命中它就不扫 TOC），
    -- 内容全是**上一本书**的 start_page / end_page / chapter_index。
    -- 唯一原本的清理点是 clear_reading_context()，但它在「切书」路径上走不到 ——
    -- lifecycle.lua 的 onCloseDocument 一检测到 is_switching 就提前 return 了。
    -- 后果：打开新书后若当前页恰好落在旧书的页区间内（恢复上次阅读页很容易命中），
    -- 快速路径就会拿**旧书的 chapter_index 去索引新书的 toc**，把错误的章节索引与
    -- 标题写进 book.durChapterIndex/durChapterTitle，随后被当作正常进度上传到云端。
    _ctx.chapter_range_cache = nil
    _ctx.current_book = book
    if book then
        _generation = _generation + 1
    end
    Log.debug("Context.set_current_book: generation=" .. _generation ..
        ", book=" .. tostring(book and (book.name or book.title)))
end

-------------------------------------------------------------------------------
-- current_chapters
-------------------------------------------------------------------------------
function Context.get_current_chapters()
    return _ctx.current_chapters
end

function Context.set_current_chapters(chapters)
    _ctx.current_chapters = chapters
end

-------------------------------------------------------------------------------
-- current_chapter_index
-------------------------------------------------------------------------------
function Context.get_current_chapter_index()
    return _ctx.current_chapter_index
end

function Context.set_current_chapter_index(index)
    _ctx.current_chapter_index = index
end

-------------------------------------------------------------------------------
-- current_epub_path
-------------------------------------------------------------------------------
function Context.get_current_epub_path()
    return _ctx.current_epub_path
end

function Context.set_current_epub_path(path)
    _ctx.current_epub_path = path
end

-------------------------------------------------------------------------------
-- pending_jump
-------------------------------------------------------------------------------
function Context.get_pending_jump()
    return _ctx.pending_jump
end

function Context.set_pending_jump(jump)
    _ctx.pending_jump = jump
end

-------------------------------------------------------------------------------
-- chapter_range_cache
-------------------------------------------------------------------------------
function Context.get_chapter_range_cache()
    return _ctx.chapter_range_cache
end

function Context.set_chapter_range_cache(cache)
    _ctx.chapter_range_cache = cache
end

-------------------------------------------------------------------------------
-- generation 令牌
-------------------------------------------------------------------------------
function Context.get_generation()
    return _generation
end

-------------------------------------------------------------------------------
-- 进度快照（含 generation），用于异步上传
-- 返回 nil 表示当前无打开书籍
-------------------------------------------------------------------------------
function Context.snapshot_progress()
    local b = _ctx.current_book
    if not b then return nil end
    return {
        name = b.name or b.title or "",
        author = b.author or "",
        durChapterIndex = b.durChapterIndex or 1,
        durChapterPos = b.durChapterPos or 0,
        durChapterTitle = b.durChapterTitle or "",
        generation = _generation,
    }
end

-------------------------------------------------------------------------------
-- 统一清理：onCloseDocument 调用
-- 注意：generation 不重置，旧异步回调仍能识别过期
-------------------------------------------------------------------------------
function Context.clear_reading_context()
    _ctx.current_book = nil
    _ctx.current_chapters = nil
    _ctx.current_chapter_index = 1
    _ctx.current_epub_path = nil
    _ctx.pending_jump = nil
    _ctx.chapter_range_cache = nil
    Log.debug("Context.clear_reading_context: 已清理阅读上下文（generation 保持 " .. _generation .. "）")
end

return Context
