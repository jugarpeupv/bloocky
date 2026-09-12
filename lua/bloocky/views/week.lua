local utils = require("bloocky.utils")
local state = require("bloocky.state")
local dooing = require("bloocky.dooing")
local highlights = require("bloocky.highlights")
local marks = require("bloocky.marks")

local M = {}

-- First block covering [row_s, row_e) and how many overlap it
local function occ_at(blocks, row_s, row_e)
	local found, count = nil, 0
	for _, block in ipairs(blocks) do
		if block.start_min < row_e and (block.start_min + block.duration_min) > row_s then
			count = count + 1
			if not found then
				found = block
			end
		end
	end
	return found, count
end

-- Block still running at minute `min` (spans across it)
local function spanning(blocks, min)
	for _, block in ipairs(blocks) do
		if block.start_min < min and (block.start_min + block.duration_min) > min then
			return block
		end
	end
	return nil
end

-- Blocks covering [s, e)
local function covering(blocks, s, e)
	local out = {}
	for _, block in ipairs(blocks) do
		if block.start_min < e and (block.start_min + block.duration_min) > s then
			table.insert(out, block)
		end
	end
	return out
end

-- Overlap layout for one day: clusters of transitively-overlapping blocks
-- with greedy first-fit columns (optimal for interval partitioning), so
-- overlapping events render side by side in stable columns.
-- Returns { clusters, of } where of[block] is its cluster holding
-- { blocks, col = { [block] = col_index }, ncols }.
local function layout_day(blocks)
	local sorted = {}
	for _, b in ipairs(blocks) do
		table.insert(sorted, b)
	end
	table.sort(sorted, function(a, b)
		if a.start_min ~= b.start_min then
			return a.start_min < b.start_min
		end
		return (a.start_min + a.duration_min) > (b.start_min + b.duration_min)
	end)
	local clusters, cur = {}, nil
	for _, b in ipairs(sorted) do
		local e = b.start_min + b.duration_min
		if cur and b.start_min < cur.max_end then
			table.insert(cur.blocks, b)
			if e > cur.max_end then
				cur.max_end = e
			end
		else
			cur = { blocks = { b }, max_end = e }
			table.insert(clusters, cur)
		end
	end
	local of = {}
	for _, cl in ipairs(clusters) do
		cl.col, cl.ends = {}, {}
		for _, b in ipairs(cl.blocks) do
			local c = 1
			while cl.ends[c] and cl.ends[c] > b.start_min do
				c = c + 1
			end
			cl.col[b] = c
			cl.ends[c] = b.start_min + b.duration_min
		end
		cl.ncols = #cl.ends
		for _, b in ipairs(cl.blocks) do
			of[b] = cl
		end
	end
	return { clusters = clusters, of = of }
end

function M.render(ctx)
	local cfg = ctx.config
	local gutter = 7
	-- Each day column is preceded by a "│" separator. Filling spends the cells
	-- that do not divide evenly on the columns instead of dropping them.
	local inner = math.max(7, ctx.width - gutter - 7)
	local cws = utils.share(ctx.fill and inner or (math.floor(inner / 7) * 7), 7)
	local width = gutter + 7
	for _, c in ipairs(cws) do
		width = width + c
	end

	local lines, hls = {}, {}
	local meta = { width = width }

	local function push(chunks)
		local line, line_hls, spans = utils.compose(chunks)
		table.insert(lines, line)
		local lnum = #lines - 1
		for _, h in ipairs(line_hls) do
			h.line = lnum
			table.insert(hls, h)
		end
		return lnum, spans
	end

	local wstart = utils.week_start_of(ctx.cursor.date, cfg.week_start)
	local days = {}
	for i = 0, 6 do
		days[i + 1] = utils.add_days(wstart, i)
	end
	local wend = days[7]

	-- Day header
	local header = { { string.rep(" ", gutter) } }
	for i, d in ipairs(days) do
		local label = utils.WDAYS_SHORT[utils.wday(d)] .. " " .. string.format("%02d", d.day)
		local grp = "BloockyHeader"
		if utils.same_day(d, ctx.today) then
			grp = "BloockyToday"
		end
		table.insert(header, { "│", "BloockyGrid" })
		table.insert(header, { utils.center(label, cws[i]), grp })
	end
	local header_lnum, header_spans = push(header)
	for i, d in ipairs(days) do
		if utils.same_day(d, ctx.cursor.date) then
			local span = header_spans[2 * i + 1]
			table.insert(hls, { line = header_lnum, s = span.s, e = span.e, group = "BloockyCursor", prio = 60 })
		end
	end

	-- Blocks for the week, split once: all-day ones go in a strip above the
	-- grid, timed ones into it.
	local occ, all_day = {}, {}
	for i, d in ipairs(days) do
		all_day[i], occ[i] = state.split_for_date(d)
	end

	-- All-day strip
	local any_all_day = false
	for i in ipairs(days) do
		if #all_day[i] > 0 then
			any_all_day = true
		end
	end
	if any_all_day then
		local chunks = { { utils.fit(" " .. cfg.icons.all_day, gutter), "BloockyTime" } }
		for i in ipairs(days) do
			table.insert(chunks, { "│", "BloockyGrid" })
			if #all_day[i] > 0 then
				local block = all_day[i][1]
				local badge = require("bloocky.ui").calendar_badge(block)
				if badge then badge = badge:sub(1, 2) .. " " end
				badge = badge or ""
				local text = marks.icon(block) .. badge .. block.title
				if #all_day[i] > 1 then
					text = marks.icon(block) .. badge .. "×" .. #all_day[i] .. " " .. block.title
				end
				table.insert(chunks, { utils.fit(text, cws[i]), highlights.block_group(block), 100 })
			else
				table.insert(chunks, { string.rep(" ", cws[i]) })
			end
		end
		push(chunks)
	end

	-- Dooing deadline strip
	local due = {}
	local any_due = false
	for i, d in ipairs(days) do
		due[i] = dooing.tasks_for_date(utils.date_to_str(d))
		if #due[i] > 0 then
			any_due = true
		end
	end
	if any_due then
		local chunks = { { utils.fit(" due", gutter), "BloockyTime" } }
		for i in ipairs(days) do
			table.insert(chunks, { "│", "BloockyGrid" })
			if #due[i] > 0 then
				local text = cfg.icons.dooing .. " " .. due[i][1].text
				if #due[i] > 1 then
					text = cfg.icons.dooing .. "×" .. #due[i] .. " " .. due[i][1].text
				end
				table.insert(chunks, { utils.fit(text, cws[i]), "BloockyDooing" })
			else
				table.insert(chunks, { string.rep(" ", cws[i]) })
			end
		end
		push(chunks)
	end

	local rule = { { string.rep("─", gutter), "BloockyGrid" } }
	for i = 1, 7 do
		table.insert(rule, { "┼" .. string.rep("─", cws[i]), "BloockyGrid" })
	end
	push(rule)

	-- Hour grid
	local cursor_col = nil
	for i, d in ipairs(days) do
		if utils.same_day(d, ctx.cursor.date) then
			cursor_col = i
		end
	end

	local h0, h1 = cfg.hours.start, cfg.hours["end"]
	-- Run layout: each hour is split into sub-rows (30-min slots by default:
	-- a 30-min event fills one line, an hour two; 15-min slots give 2 and 4
	-- lines). Overlapping events share the day column side by side.
	-- Buffer/sidebar windows scroll, so they always get the full grid;
	-- floats degrade to coarser slots (then the legacy hourly layout) to fit
	-- the window instead of cutting content off.
	local ui_mode = nil
	pcall(function()
		ui_mode = require("bloocky.ui").mode
	end)
	local slot = utils.slot_min(cfg.window)
	if ui_mode == "float" then
		local hours = math.max(1, h1 - h0)
		local avail = ctx.height - #lines
		local per_hour = 60 / slot
		while per_hour > 2 and avail < hours * per_hour do
			per_hour = per_hour / 2
		end
		slot = (avail < hours * per_hour) and 60 or (60 / per_hour)
	end

	-- Full first-line text for an event (fitted to the column at use site).
	-- Title only, no clock time: the sub-row position already shows when it
	-- is, and the height shows how long it lasts.
	local function full_text(block)
		local badge = require("bloocky.ui").calendar_badge(block)
		-- week columns are narrow: 2-char short id keeps the title visible
		if badge then
			badge = badge:sub(1, 2) .. " "
		end
		badge = badge or ""
		local text = marks.icon(block) .. badge .. block.title
		if block.recurrence then
			text = text .. " " .. cfg.icons.recurring
		end
		return text
	end

	-- Reverse map for native cursor moves (arrows/mouse): grid line -> slot,
	-- day column x-ranges + dates. ui.lua keeps M.cursor in sync from these.
	meta.slots, meta.day_cols, meta.slot_days = {}, {}, {}
	for i, d in ipairs(days) do
		local span = header_spans[2 * i + 1]
		meta.day_cols[i] = { s = span.s, e = span.e }
		meta.slot_days[i] = d
	end

	if slot == 60 then
		-- Legacy adaptive hourly layout for short floats: every hour always
		-- visible, grouping them if the window is short.
		for _, row in ipairs(utils.hour_layout(h0, h1, ctx.height - #lines, ctx.fill)) do
			local row_s, row_e = row.s, row.e

			-- The cell of every day for this slot, laid out once and reused by the
			-- lines the slot spans (only the first one carries the block's text)
			local cells = {}
			for i in ipairs(days) do
				local block, n = occ_at(occ[i], row_s, row_e)
				local text
				if block then
					if block.start_min >= row_s then
						text = full_text(block)
					else
						text = marks.icon(block)
					end
					if n > 1 then
						text = utils.fit(text, cws[i] - 2) .. "+ "
					else
						text = utils.fit(text, cws[i])
					end
				end
				cells[i] = { block = block, text = text }
			end

			local on_cursor = cursor_col and ctx.cursor.min >= row_s and ctx.cursor.min < row_e
			for r = 1, row.lines do
				local chunks = {
					{ (r == 1) and row.label or string.rep(" ", gutter), (r == 1) and "BloockyTime" or nil },
				}
				for i in ipairs(days) do
					table.insert(chunks, { "│", "BloockyGrid" })
					local cell = cells[i]
					if cell.block then
						local text = (r == 1) and cell.text or string.rep(" ", cws[i])
						table.insert(chunks, { text, highlights.block_group(cell.block), 100 })
					else
						table.insert(chunks, { string.rep(" ", cws[i]) })
					end
				end
			local lnum, spans = push(chunks)
			meta.slots[lnum] = { s = row_s, e = row_e }
			if on_cursor then
				local span = spans[2 * cursor_col + 1]
				table.insert(hls, { line = lnum, s = span.s, e = span.e, group = "BloockyCursor", prio = 200 })
				meta.cursor_line = meta.cursor_line or (lnum + 1)
			end
		end

		-- Dotted divider between hours; blocks spanning the boundary stay solid
		if row.div then
				local bmin = row_e
				local div = { { string.rep(" ", gutter) } }
				for i in ipairs(days) do
					table.insert(div, { "│", "BloockyGrid" })
					local cont = spanning(occ[i], bmin)
					if cont then
						table.insert(div, { string.rep(" ", cws[i]), highlights.block_group(cont), 100 })
					else
						table.insert(div, { string.rep("┄", cws[i]), "BloockyGridDim" })
					end
				end
				push(div)
			end
		end
	else
		-- Sub-row grid: one terminal line per `slot` minutes. An event's
		-- first sub-row carries its text, the rest only its icon; a day
		-- column shared by overlapping events is split into stable columns.
		local layouts = {}
		for i in ipairs(days) do
			layouts[i] = layout_day(occ[i])
		end

		local m = h0 * 60
		while m < h1 * 60 do
			local s, e = m, m + slot
			local hour_start = m % 60 == 0
			local chunks = {
				{
					hour_start and string.format(" %02d:00 ", math.floor(m / 60)) or string.rep(" ", gutter),
					hour_start and "BloockyTime" or nil,
				},
			}
			local cs, ce = nil, nil
			for i in ipairs(days) do
				table.insert(chunks, { "│", "BloockyGrid" })
				if i == cursor_col then
					cs = #chunks + 1
				end
				local cov = covering(occ[i], s, e)
				if #cov == 0 then
					table.insert(chunks, { string.rep(" ", cws[i]) })
				elseif #cov == 1 then
					local b = cov[1]
					local text
					if b.start_min >= s and b.start_min < e then
						text = utils.fit(full_text(b), cws[i])
					else
						text = utils.fit(marks.icon(b), cws[i])
					end
					table.insert(chunks, { text, highlights.block_group(b), 100 })
				else
					local cl = layouts[i].of[cov[1]]
					local ncols = (cl and cl.ncols) or #cov
					if math.floor(cws[i] / ncols) < 4 then
						-- Too narrow for columns: first event plus overflow mark.
						local b = cov[1]
						local text = (b.start_min >= s and b.start_min < e) and full_text(b) or marks.icon(b)
						table.insert(chunks, { utils.fit(text, cws[i] - 2) .. "+ ", highlights.block_group(b), 100 })
					else
						local widths = utils.share(cws[i], ncols)
						for col = 1, ncols do
							local b = nil
							for _, cand in ipairs(cov) do
								if cl and cl.col[cand] == col then
									b = cand
									break
								end
							end
							if not b and col == 1 then
								b = cov[1]
							end
							if b then
								local text
								if b.start_min >= s and b.start_min < e then
									text = utils.fit(full_text(b), widths[col])
								else
									text = utils.fit(marks.icon(b), widths[col])
								end
								table.insert(chunks, { text, highlights.block_group(b), 100 })
							else
								table.insert(chunks, { string.rep(" ", widths[col]) })
							end
						end
					end
				end
				if i == cursor_col then
					ce = #chunks
				end
			end
			local lnum, spans = push(chunks)
			meta.slots[lnum] = { s = s, e = e }
			local on_cursor = cursor_col and ctx.cursor.min >= s and ctx.cursor.min < e
			if on_cursor and cs and ce then
				table.insert(hls, { line = lnum, s = spans[cs].s, e = spans[ce].e, group = "BloockyCursor", prio = 200 })
				meta.cursor_line = meta.cursor_line or (lnum + 1)
			end
			-- Borders between slots: solid (─) on the hour, dotted (┄) on
			-- the half hour (between the 2nd and 3rd sub-row). Spanning
			-- blocks stay solid across both.
			if e < h1 * 60 and (e % 60 == 0 or e % 60 == 30) then
				local ch = (e % 60 == 0) and "─" or "┄"
				local div = { { string.rep(" ", gutter) } }
				for i in ipairs(days) do
					table.insert(div, { "│", "BloockyGrid" })
					local cont = spanning(occ[i], e)
					if cont then
						table.insert(div, { string.rep(" ", cws[i]), highlights.block_group(cont), 100 })
					else
						table.insert(div, { string.rep(ch, cws[i]), ch == "┄" and "BloockyGridDim" or "BloockyGrid" })
					end
				end
				push(div)
			end
			m = m + slot
		end
	end

	meta.title = string.format(
		" 󰃭 %s %02d – %s %02d, %d — Week ",
		utils.MONTHS_SHORT[wstart.month],
		wstart.day,
		utils.MONTHS_SHORT[wend.month],
		wend.day,
		wend.year
	)
	return lines, hls, meta
end

return M
