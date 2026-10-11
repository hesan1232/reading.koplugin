--[[
    TOC 锚点校准：把 Legado 章节索引与 EPUB TOC 索引对齐（两点锚定）。
    核心是「输入 book + TOC 表 → 输出索引映射」的纯表运算，可脱离 KOReader 单测；
    唯一的外部依赖是 UIManager:scheduleIn（用于锚点落盘的 5 秒去抖）。

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
local Log = safe_require("reading.log")

local M = {}

--- 通过标题验证 Legado 章节索引是否正确
-- 处理"作者有话说""紧急求助"等动态插入导致固定偏移量失效的情况。
-- 用 EPUB TOC 当前章节标题在 Legado 章节列表中查找，如果找到且索引不一致，用匹配到的索引。
-- @param book table  当前书籍对象
-- @param title string EPUB TOC 当前章节标题
-- @param fallback_index number 偏移量计算的 Legado 索引（0-based）
-- @return number|nil  验证后的 Legado 索引（0-based），nil 表示无法验证（用 fallback）
function M._verify_legado_index_by_title(self, book, title, fallback_index)
    if not title or title == "" then return nil end

    -- 加载 Legado 原始章节列表
    local book_url = book.bookUrl or ""
    if book_url == "" then return nil end
    local legado_chapters = self.bookshelf:load_toc_cache(book_url)
    if not legado_chapters or #legado_chapters == 0 then return nil end

    -- 在 Legado 章节列表中查找标题匹配
    local matched_idx = self:_find_chapter_by_title(legado_chapters, title)
    if not matched_idx then return nil end

    -- matched_idx 是 Lua 1-based，转为 Legado 0-based
    local verified_legado = matched_idx - 1

    if verified_legado ~= fallback_index then
        Log.info("标题验证(EPUB→Legado): 偏移量计算=" .. fallback_index .. ", 标题匹配=" .. verified_legado ..
                 "（标题 '" .. title .. "' 可能因动态插入导致偏移失效，采用标题匹配结果）")
    end
    return verified_legado
end

--- 通过标题验证 EPUB TOC 索引是否正确（反向：Legado → EPUB）
-- 处理"作者有话说""紧急求助"等动态插入导致固定偏移量失效的情况。
-- 从 Legado 章节列表获取指定索引的标题，在 EPUB TOC 中查找对应位置。
-- @param book table  当前书籍对象
-- @param legado_index number Legado 0-based 章节索引
-- @param doc_toc table  EPUB TOC（1-based Lua 表）
-- @return number|nil  验证后的 EPUB TOC 索引（1-based），nil 表示无法验证（用 fallback）
function M._verify_epub_index_by_title(self, book, legado_index, doc_toc)
    if not doc_toc or #doc_toc == 0 then return nil end

    -- 加载 Legado 原始章节列表
    local book_url = book.bookUrl or ""
    if book_url == "" then return nil end
    local legado_chapters = self.bookshelf:load_toc_cache(book_url)
    if not legado_chapters or #legado_chapters == 0 then return nil end

    -- 获取 Legado 章节标题（legado_index 是 0-based，转 1-based 查表）
    local legado_1based = legado_index + 1
    if legado_1based < 1 or legado_1based > #legado_chapters then return nil end
    local legado_ch = legado_chapters[legado_1based]
    local title = legado_ch and (legado_ch.name or legado_ch.title) or ""
    if title == "" then return nil end

    -- 在 EPUB TOC 中查找标题匹配
    local matched_epub = self:_find_chapter_by_title(doc_toc, title)
    if not matched_epub then return nil end

    Log.debug("标题验证(Legado→EPUB): Legado " .. legado_index .. " '" .. title .. "' -> EPUB TOC " .. matched_epub)
    return matched_epub
end

--- 计算初始 TOC 锚点表
--
-- 【数据源说明】Legado 的 WebDAV 备份（bookshelf.json / bookProgress/）里**没有完整章节表**，
-- 它能提供的「手机端目录」侧信息只有两个端点标题：
--   · book.durChapterTitle     —— 当前阅读章节标题，对应 legado 索引 book.durChapterIndex
--   · book.latestChapterTitle  —— 最新章节标题，对应 legado 索引 book.totalChapterNum - 1
-- 因此这里优先用这两个真实标题去本地 EPUB TOC 里反查锚点。
-- 完整章节表的路径是 load_toc_cache（当前无数据源写入，见 Bookshelf:save_toc_cache 注释），
-- 一旦将来接入「云端 EPUB TOC 落盘」，下面的 legado_chapters 分支即可自动生效。
function M._calc_initial_anchors(self, book, doc_toc)
    local anchors = {}
    if not book or not doc_toc or #doc_toc == 0 then
        table.insert(anchors, { legado = 0, epub = 1, title = "Fallback" })
        return anchors
    end

    local legado_chapters = nil
    local book_url = book.bookUrl or ""
    if book_url ~= "" then
        legado_chapters = self.bookshelf:load_toc_cache(book_url)
    end

    -- 1. 第一优先级：用当前阅读进度中的标题进行精准对齐
    local probe_title = book.durChapterTitle or ""
    if probe_title == "" and book.durChapterIndex and legado_chapters then
        local legado_idx = book.durChapterIndex + 1
        if legado_idx >= 1 and legado_idx <= #legado_chapters then
            local legado_ch = legado_chapters[legado_idx]
            if legado_ch then
                probe_title = legado_ch.name or legado_ch.title or ""
            end
        end
    end

    if probe_title and probe_title ~= "" then
        local matched_idx = self:_find_chapter_by_title(doc_toc, probe_title)
        if matched_idx then
            local legado_base = book.durChapterIndex or 0
            Log.info("_calc_initial_anchors: 标题 '" .. probe_title .. "' 匹配 TOC " .. matched_idx .. " = Legado " .. legado_base)
            table.insert(anchors, { legado = legado_base, epub = matched_idx, title = probe_title })
            -- 顺带尝试追加「最新章节」锚点：两点锚定比单点推算稳得多
            self:_append_latest_chapter_anchor(book, doc_toc, anchors)
            return anchors
        end
    end

    -- 2. 第二优先级：用 EPUB TOC 的前几个正文章节去 Legado 目录中反查
    local legado_prefix_titles = {
        "封面", "Cover",
        "内容简介", "Book description",
        "简介", "Intro",
        "目录", "Contents", "Table of Contents",
    }
    
    if legado_chapters and #legado_chapters > 0 then
        for i = 1, math.min(20, #doc_toc) do
            local epub_title = doc_toc[i] and (doc_toc[i].name or doc_toc[i].title) or ""
            local clean_title = epub_title:gsub("^%s+", ""):gsub("%s+$", "")
            local is_prefix = false
            for __, pat in ipairs(legado_prefix_titles) do
                if clean_title == pat then
                    is_prefix = true
                    break
                end
            end
            
            if not is_prefix and epub_title ~= "" then
                local matched_legado_1based = self:_find_chapter_by_title(legado_chapters, epub_title)
                if matched_legado_1based then
                    local legado_0based = matched_legado_1based - 1
                    Log.info("_calc_initial_anchors: EPUB 正文标题 '" .. epub_title .. "' (TOC " .. i .. ") 匹配 Legado " .. legado_0based)
                    table.insert(anchors, { legado = legado_0based, epub = i, title = epub_title })
                    return anchors
                end
            end
        end
    end

    -- 3. 第三优先级：如果 Legado 目录缺失，退回基于前置条目数量的猜测（仅适用于完整导出）
    local first_real_chapter_idx = nil
    for i = 1, math.min(20, #doc_toc) do
        local title = doc_toc[i] and (doc_toc[i].name or doc_toc[i].title) or ""
        local clean_title = title:gsub("^%s+", ""):gsub("%s+$", "")
        local is_prefix = false
        for __, pat in ipairs(legado_prefix_titles) do
            if clean_title == pat then
                is_prefix = true
                break
            end
        end
        if not is_prefix then
            first_real_chapter_idx = i
            break
        end
    end
    if first_real_chapter_idx then
        Log.info("_calc_initial_anchors: 猜测为完整导出，首章 TOC=" .. first_real_chapter_idx)
        table.insert(anchors, { legado = 0, epub = first_real_chapter_idx, title = "Guessed First Chapter" })
        -- 即便首章只能靠猜，若能看到「最新章节」标题，仍可用它把尾部钉住
        self:_append_latest_chapter_anchor(book, doc_toc, anchors)
        return anchors
    end

    -- 4. 兜底：无法校准时不再猜测偏移量
    -- 历史上这里硬编码 { legado = 0, epub = 3 }（"Default Offset"）。该魔法值会把
    -- 「校准失败」伪装成「已校准」，用户看到的现象是「跳转到了错误的章节」而不是
    -- 「同步失败」，比直接报错危害大得多。返回 nil 让 _get_epub_index /
    -- _get_legado_index 退化为恒等映射（不写入任何锚点文件），
    -- 后续任一次成功的云端进度拉取（_compare_progress_by_title）都能建立正确锚点。
    Log.warn("_calc_initial_anchors: 无法校准目录偏移（Legado 侧标题均未能在本地 EPUB TOC 中匹配），"
        .. "本次不写入锚点表，按恒等映射处理；执行一次云端进度拉取即可建立校准。")
    return nil
end

--- 用 Legado 的「最新章节标题」追加一个锚点（尾部锚定）
--
-- Legado 的 Book.latestChapterTitle 对应全书最后一章（legado 索引 = totalChapterNum - 1）。
-- 它和 durChapterTitle 一起，构成 Legado 侧唯二真实可得的目录端点。
-- 两点锚定的价值：单锚点靠「偏移量恒定」的假设外推；一旦 EPUB 与 Legado 目录的
-- 差异不是常量偏移（中间夹了「作者有话说」等动态插入章节），单点外推就会越走越偏。
-- 失败时静默跳过（例如 EPUB 是导出快照、不含后来更新的最新章节），不影响主锚点。
--
-- @param book table   书籍对象（来自 bookshelf.json，含 latestChapterTitle/totalChapterNum）
-- @param doc_toc table 本地 EPUB TOC（1-based，元素含 name/title）
-- @param anchors table 已建立的锚点表（原地追加）
-- @return boolean 是否成功追加
function M._append_latest_chapter_anchor(self, book, doc_toc, anchors)
    if not book or not doc_toc or not anchors then return false end

    local latest_title = book.latestChapterTitle or ""
    if latest_title == "" then return false end

    local total = tonumber(book.totalChapterNum) or 0
    if total <= 0 then return false end

    local matched = self:_find_chapter_by_title(doc_toc, latest_title)
    if not matched then
        Log.debug("_append_latest_chapter_anchor: 最新章节标题 '" .. latest_title .. "' 未在本地 TOC 匹配，跳过")
        return false
    end

    local legado_last = total - 1
    for __, a in ipairs(anchors) do
        if a.legado == legado_last then return false end
    end

    table.insert(anchors, { legado = legado_last, epub = matched, title = latest_title })
    Log.info("_calc_initial_anchors: 尾部锚定 '" .. latest_title ..
             "' Legado " .. legado_last .. " = EPUB TOC " .. matched)
    return true
end

--- 确保锚点表已加载
function M._ensure_toc_anchors(self, book, doc_toc)
    if not book then return end
    if book._toc_anchors_loaded then return end
    
    if book.bookUrl and book.bookUrl ~= "" then
        -- 走带缓存的查询（见 Bookshelf:get_epub_path_cached）：这里只是给
        -- load_toc_anchors 校验 EPUB 版本指纹，顺便把路径缓存填好，
        -- 后面 _save_toc_anchors 就能直接命中、不必再全量匹配一次。
        local epub_path = self.bookshelf:get_epub_path_cached(book)
        local stored = self.bookshelf:load_toc_anchors(book.bookUrl, epub_path)
        if stored and #stored > 0 then
            book.toc_anchors = stored
            book._toc_anchors_loaded = true
            Log.debug("_ensure_toc_anchors: 从独立文件加载最新锚点表, 数量=" .. #stored)
            return
        end
    end
    
    -- 独立文件无或版本不匹配：重新计算，不用内存里的旧值
    local anchors = self:_calc_initial_anchors(book, doc_toc)
    book._toc_anchors_loaded = true
    if not anchors then
        -- 校准失败：保持 toc_anchors 为空，_get_epub_index/_get_legado_index 会退化为
        -- 恒等映射。不标脏、不写盘，避免把「未知偏移」持久化成一份错误锚点表，
        -- 也保证后续第一次成功的标题对齐（_add_toc_anchor）能成为权威锚点。
        book.toc_anchors = nil
        book._toc_anchors_dirty = nil
        Log.warn("_ensure_toc_anchors: 无法校准目录偏移, book=" .. tostring(book.bookUrl))
        return
    end
    book.toc_anchors = anchors
    book._toc_anchors_dirty = true -- 显式标脏，确保初始锚点被写入
    self:_save_toc_anchors(book)
end

--- 保存 TOC 锚点表
function M._save_toc_anchors(self, book)
    if book and book.bookUrl and book.bookUrl ~= "" and book.toc_anchors then
        if book._toc_anchors_dirty then
            -- 这里要的只是 epub_path，用来算版本指纹（size + mtime）。
            -- 原实现每次调 get_epub_for_book，对**本地全部 epub** 打分并排序；
            -- 而本函数由 _add_toc_anchor 的 5 秒去抖触发 —— 跨章读下去，
            -- 等于每次落盘都要全量匹配一遍。改用带缓存的查询
            -- （Bookshelf:get_epub_path_cached，失效点是 invalidate_epub_cache）。
            local epub_path = self.bookshelf:get_epub_path_cached(book)
            self.bookshelf:save_toc_anchors(book.bookUrl, book.toc_anchors, epub_path)
            book._toc_anchors_dirty = false
            -- 移除 save_bookshelf_cache，避免双存储不一致和频繁写盘
        end
    end
end

--- 添加 TOC 锚点
function M._add_toc_anchor(self, book, legado_index, epub_index, title)
    if not book then return end
    if not book.toc_anchors then
        book.toc_anchors = {}
    end
    
    for i, anchor in ipairs(book.toc_anchors) do
        if anchor.legado == legado_index and anchor.epub == epub_index then
            return
        end
        if anchor.legado == legado_index then
            anchor.epub = epub_index
            anchor.title = title or anchor.title
            book._toc_anchors_dirty = true
            return
        end
    end
    
    table.insert(book.toc_anchors, {
        legado = legado_index,
        epub = epub_index,
        title = title or ""
    })
    
    table.sort(book.toc_anchors, function(a, b) return a.legado < b.legado end)
    
    -- 限制锚点数量，采用智能采样：保留首尾，以及偏移量发生变化的锚点
    if #book.toc_anchors > 64 then
        local new_anchors = {}
        table.insert(new_anchors, book.toc_anchors[1])
        local last_offset = book.toc_anchors[1].epub - book.toc_anchors[1].legado
        
        for i = 2, #book.toc_anchors - 1 do
            local current_offset = book.toc_anchors[i].epub - book.toc_anchors[i].legado
            if current_offset ~= last_offset then
                table.insert(new_anchors, book.toc_anchors[i])
                last_offset = current_offset
            end
        end
        
        -- 确保最后一个锚点被保留
        if #book.toc_anchors > 1 then
            local last_anchor = book.toc_anchors[#book.toc_anchors]
            if new_anchors[#new_anchors].legado ~= last_anchor.legado then
                table.insert(new_anchors, last_anchor)
            end
        end
        
        -- 如果智能采样后还是很多（极端情况），再做一次均匀采样
        if #new_anchors > 64 then
            local final_anchors = {}
            local step = #new_anchors / 32
            for i = 1, 32 do
                local idx = math.floor((i - 1) * step) + 1
                if idx > #new_anchors then idx = #new_anchors end
                table.insert(final_anchors, new_anchors[idx])
            end
            if final_anchors[#final_anchors].legado ~= new_anchors[#new_anchors].legado then
                table.insert(final_anchors, new_anchors[#new_anchors])
            end
            new_anchors = final_anchors
        end
        
        book.toc_anchors = new_anchors
    end
    
    book._toc_anchors_dirty = true
    
    -- Debounce 定时写盘：5 秒内的多次锚点改动只落盘一次，避免频繁 I/O。
    --
    -- ⚠️ 用独立布尔标志，**不能**用 `handle = UIManager:scheduleIn(...)` 的返回值：
    --    `UIManager:scheduleIn` 没有 return（koreader-master/frontend/ui/uimanager.lua:335），
    --    返回值恒为 nil，于是 `if not book._toc_anchors_flush_handle then` 这句守卫
    --    **每次调用都成立** —— debounce 反而变成「每加一个锚点就排一次写盘」，
    --    一本需要校准的书会连着触发几十次同步文件写入，正是这段代码想避免的事。
    if not book._toc_anchors_flush_pending then
        book._toc_anchors_flush_pending = true
        UIManager:scheduleIn(5, function()
            book._toc_anchors_flush_pending = nil
            self:_save_toc_anchors(book)
        end)
    end
end

--- 根据 Legado 索引获取 EPUB 索引
function M._get_epub_index(self, book, legado_index, doc_toc)
    if not book then return legado_index + 1 end
    self:_ensure_toc_anchors(book, doc_toc)
    
    if not book.toc_anchors or #book.toc_anchors == 0 then
        return legado_index + 1
    end
    
    local best_anchor = book.toc_anchors[1]
    local min_diff = math.huge
    for i = 1, #book.toc_anchors do
        local anchor = book.toc_anchors[i]
        local diff = math.abs(anchor.legado - legado_index)
        if diff < min_diff then
            min_diff = diff
            best_anchor = anchor
        end
    end
    
    return best_anchor.epub + (legado_index - best_anchor.legado)
end

--- 根据 EPUB 索引获取 Legado 索引
function M._get_legado_index(self, book, epub_index, doc_toc)
    if not book then return epub_index - 1 end
    self:_ensure_toc_anchors(book, doc_toc)
    
    if not book.toc_anchors or #book.toc_anchors == 0 then
        return epub_index - 1
    end
    
    local best_anchor = book.toc_anchors[1]
    local min_diff = math.huge
    for i = 1, #book.toc_anchors do
        local anchor = book.toc_anchors[i]
        local diff = math.abs(anchor.epub - epub_index)
        if diff < min_diff then
            min_diff = diff
            best_anchor = anchor
        end
    end
    
    return best_anchor.legado + (epub_index - best_anchor.epub)
end

--- 取当前文档的 EPUB TOC，并缓存到 **doc** 上。
--
-- 【为什么必须缓存】`doc:getToc()` 不是查表，而是让 crengine **重建整棵 Lua 表**：
-- N 个章节就是 N 次 table 分配 + N 次字符串拷贝。上游 KOReader 全前端只在
-- `frontend/apps/reader/modules/readertoc.lua:171` 取一次并缓存进 `self.toc`，
-- 之后所有模块都复用那一份。
-- 而本插件此前在**每次翻页**（onPageUpdate）与**每次切章**（save_read_progress →
-- _refresh_current_progress）都重新取一次 —— 一本 2000 章的网文，每翻一页要付两次
-- 全量重建，这是墨水屏上最不该有的开销。
--
-- 【为什么缓存在 doc 上，而不是 book 上】book 是内存里常驻的书架条目，跨次打开
-- 会被复用；同一本书的 EPUB 只要被重新下载，TOC 就变了，而挂在 book 上的旧目录
-- 仍会被拿去算章节偏移 —— 进度会被映射到错误的章节。doc 与「一次打开」一一对应，
-- 随文档关闭一起回收，缓存生命周期与「目录可能变化」的粒度天然对齐：
-- 既不串目录，也不会把 doc 引用长期挂在书架条目上（那样等于泄漏文档对象）。
-- 空表不缓存 —— 否则 `_load_chapters_from_document` 的「目录为空就重试」会永远拿到空表。
--
-- 注：`book` 参数保留只是为了不改变调用点签名，本函数已不再使用它。
function M._get_doc_toc(self, doc, book)
    if not doc then return nil end
    if doc._reading_toc then
        return doc._reading_toc
    end
    local toc = doc:getToc()
    if toc and #toc > 0 then
        doc._reading_toc = toc
    end
    return toc
end

--- 扫描 TOC，把「页码」定位为「章节索引 + 章内位置」。
--
-- 【为什么有这个函数】这段逻辑此前在 `lifecycle.onPageUpdate` 的慢路径与
-- `progress._refresh_current_progress` 里**逐行复制了两份**（各约 55 行），
-- 历史上已经因为两处漂移出过一次 bug（见 progress 侧的注释）。现统一到此处，
-- 两边共用同一份实现，任何修正只需改一个地方。
--
-- 【唯一的副作用】在 `toc` 上记忆化 `_monotonic` 布尔（目录页码是否单调递增）。
-- 挂在 toc 而不是 book：toc 由 `_get_doc_toc` 按 doc 缓存，目录一旦变化就会拿到
-- 新的 toc 表，这个布尔缓存也随之自然失效。
--
-- @param toc table        章节表 { {page=, title=}, ... }（1-based）
-- @param pageno number    当前页码（1-based）
-- @param total_pages number 全书总页数（用于给末章取上界：total_pages + 1）
-- @return number chapter_index  命中的 TOC 索引（1-based）
-- @return number chapter_pos    章内位置（0-1000 的千分比）
-- @return number current_start  该章起始页
-- @return number next_start     下一章起始页（末章为 total_pages + 1）
-- @return string chapter_title  该章标题（无标题时为空串）
function M._scan_toc_for_page(self, toc, pageno, total_pages)
    local chapter_index = 1
    local chapter_pos = 0

    -- 检查 TOC 页码是否单调递增 (缓存在 toc 表上，随文档一起失效)
    if toc._monotonic == nil then
        toc._monotonic = true
        for i = 2, #toc do
            local a = toc[i-1].page or 1
            local b = toc[i].page or 1
            if b < a then
                toc._monotonic = false
                break
            end
        end
    end

    if toc._monotonic then
        -- 使用二分查找优化 TOC 扫描性能 (O(log N) 代替 O(N))
        local left, right = 1, #toc
        while left <= right do
            local mid = math.floor((left + right) / 2)
            local current_start = toc[mid].page or 1
            if pageno >= current_start then
                chapter_index = mid
                left = mid + 1
            else
                right = mid - 1
            end
        end
    else
        -- 使用稳健的线性扫描，处理 TOC 页码非严格递增的情况
        for i = 1, #toc do
            local current_start = toc[i].page or 1
            if pageno >= current_start then
                chapter_index = i
            end
        end
    end

    local current_start = toc[chapter_index].page or 1
    local next_start = total_pages + 1
    for i = chapter_index + 1, #toc do
        local p = toc[i].page or 1
        if p > current_start then
            next_start = p
            break
        end
    end

    local chapter_pages = next_start - current_start
    if chapter_pages > 0 then
        -- 防止 pageno < current_start (例如落在第一章之前)
        local offset = math.max(0, pageno - current_start)
        chapter_pos = math.floor(offset / chapter_pages * 1000)
    else
        chapter_pos = 0
    end

    local chapter_title = toc[chapter_index] and toc[chapter_index].title or ""
    return chapter_index, chapter_pos, current_start, next_start, chapter_title
end

--- 为目录列表构建标题哈希索引（精确 + 去空格），缓存在 toc 表上
-- 索引字段：_title_index（精确标题 -> 1-based 索引）、_norm_title_index（去空格标题 -> 索引）
-- 同一个 toc 表被多次查找时，索引只构建一次，后续查询 O(1)
--
-- 注：参数名用中性的 toc，因为本函数对「EPUB TOC」和「Legado 章节表」都适用 ——
-- 两者元素都是 { name/title = ... }，但索引体系完全不同（见 _find_chapter_by_title）。
function M._ensure_title_index(self, toc)
    if toc._title_index then return end

    local get_name = function(ch)
        return ch and (ch.name or ch.title) or ""
    end

    local exact = {}
    local norm = {}
    for i, ch in ipairs(toc) do
        local name = get_name(ch)
        if name ~= "" then
            if exact[name] == nil then
                exact[name] = i
            end
            local norm_name = name:gsub("%s+", "")
            if norm_name ~= "" and norm[norm_name] == nil then
                norm[norm_name] = i
            end
            -- 顺便缓存 norm_name 到章节对象，供其他逻辑复用
            if not ch.norm_name then
                ch.norm_name = norm_name
            end
        end
    end
    toc._title_index = exact
    toc._norm_title_index = norm
end

--- 通过标题在目录列表中查找条目索引（解决 Legado 与 EPUB TOC 索引偏移问题）
-- Legado 章节列表与 EPUB TOC 可能因"目录""简介"等前置条目导致索引不一致，
-- 用标题匹配可精确定位，避免差 1~N 章的跳转偏差。
--
-- ⚠️ 参数 toc 有**两种**来源，调用方必须自己记住拿到的索引属于哪个体系：
--   · EPUB TOC   —— Context.get_current_chapters()，索引即 EPUB 的 1-based 章节号
--   · Legado 章节 —— Bookshelf:load_toc_cache()，索引即 Legado 的 1-based 章节号
--   两者都形如 { {name=...}, ... }，故此处统一以 toc 命名，借中性词避免误用。
-- @param toc table  目录列表（EPUB TOC 或 Legado 章节表，见上）
-- @param title string    目标章节标题（来自云端 durChapterTitle）
-- @return number|nil     匹配到的索引，nil 表示未找到
function M._find_chapter_by_title(self, toc, title)
    if not toc or #toc == 0 then return nil end
    if not title or title == "" then return nil end

    self:_ensure_title_index(toc)

    -- 1. 精确匹配 O(1)
    local idx = toc._title_index[title]
    if idx then
        Log.debug("_find_chapter_by_title: 精确匹配: '" .. title .. "' -> 第" .. idx .. "章")
        return idx
    end

    -- 2. 去空格匹配 O(1)
    local norm_title = type(title) == "string" and title:gsub("%s+", "") or ""
    if norm_title ~= "" then
        idx = toc._norm_title_index[norm_title]
        if idx then
            local get_name = function(ch)
                return ch and (ch.name or ch.title) or ""
            end
            Log.debug("_find_chapter_by_title: 去空格匹配: '" .. title .. "' -> 第" .. idx .. "章 (" .. get_name(toc[idx]) .. ")")
            return idx
        end
    end

    Log.warn("_find_chapter_by_title: 未找到匹配章节: '" .. title .. "'")
    return nil
end

return M
