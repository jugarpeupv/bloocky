local config = require("bloocky.config")
local utils = require("bloocky.utils")
local state = require("bloocky.state")
local highlights = require("bloocky.highlights")

local M = {}

local views = {
	month = require("bloocky.views.month"),
	week = require("bloocky.views.week"),
	day = require("bloocky.views.day"),
}
local view_order = { "day", "week", "month" }

local buf, win = nil, nil
local last_grid = nil -- { view, slots, day_cols, slot_days } from the last render
local ns = vim.api.nvim_create_namespace("bloocky")

M.view = nil
M.mode = nil -- "float" | "sidebar" | "buffer"
M.cursor = nil -- { date = { year, month, day }, min = minutes from midnight }
M.calendar_filter = nil -- nil = all calendars, else "account" or "account/calendar_name" or "account/href"
M.calendar_filter_label = nil

local function is_open()
	if win == nil or buf == nil then
		return false
	end
	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	-- In buffer mode the user can navigate away (e.g. jump back to the
	-- previous buffer) leaving the window showing another buffer. The
	-- calendar is then hidden, not open: reopening must restore the full
	-- buffer, not just repaint the winbar over someone else's file.
	local ok, cur = pcall(vim.api.nvim_win_get_buf, win)
	return ok and cur == buf
end
M.is_open = is_open

local function clear_winbar(win_id)
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win_id })
	end
end

-- Calendar filter: nil = all, else per-account or per-calendar
function M.available_calendars()
	local marks = require("bloocky.marks")
	local list = marks.known_calendars() or {}
	-- also ensure at least accounts are listed even with no blocks yet
	local seen = {}
	for _, c in ipairs(list) do seen[c.id] = true end
	local cfg_accounts = (config.options.sync or {}).accounts or {}
	for _, acc in ipairs(cfg_accounts) do
		if not seen[acc.id] then
			table.insert(list, { account = acc.id, href = acc.url or "", name = acc.id, id = acc.id })
		end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

function M.default_calendar()
	local sync = config.options.sync or {}
	if sync.default_calendar and sync.default_calendar ~= "" then
		return sync.default_calendar
	end
	-- respect per-calendar default flag
	for _, acc in ipairs(sync.accounts or {}) do
		for _, cal in ipairs(acc.calendars or {}) do
			if cal.default then
				return acc.id .. "/" .. (cal.name or cal.href or acc.id)
			end
		end
	end
	-- fallback: first account (user config order)
	if sync.accounts and sync.accounts[1] and sync.accounts[1].id then
		return sync.accounts[1].id
	end
	return nil
end

function M.set_calendar_filter(filter, label)
	if filter == "" then filter = nil end
	M.calendar_filter = filter
	M.calendar_filter_label = label or filter
	if is_open() then M.render() end
end

function M.clear_calendar_filter()
	M.set_calendar_filter(nil, nil)
end

local function ui_select(items, opts, on_choice)
	-- Prefer snacks.nvim picker if available
	local ok_snacks, snacks = pcall(require, "snacks")
	if ok_snacks and snacks.picker and snacks.picker.select then
		local ok = pcall(snacks.picker.select, items, opts, on_choice)
		if ok then return end
	end
	local ok_p, picker = pcall(require, "snacks.picker")
	if ok_p and picker and picker.select then
		local ok = pcall(picker.select, items, opts, on_choice)
		if ok then return end
	end
	-- Try telescope
	local has_tel, pickers = pcall(require, "telescope.pickers")
	if has_tel then
		local ok_f, finders = pcall(require, "telescope.finders")
		local ok_c, conf = pcall(require, "telescope.config")
		local ok_a, actions = pcall(require, "telescope.actions")
		local ok_s, action_state = pcall(require, "telescope.actions.state")
		if ok_f and ok_c and ok_a and ok_s then
			pickers.new({}, {
				prompt_title = opts.prompt or "Select",
				finder = finders.new_table({
					results = items,
					entry_maker = function(entry)
						local display = opts.format_item and opts.format_item(entry) or tostring(entry.label or entry.id or entry)
						return { value = entry, display = display, ordinal = display }
					end,
				}),
				sorter = conf.values.generic_sorter({}),
				attach_mappings = function(bufnr)
					actions.select_default:replace(function()
						actions.close(bufnr)
						local sel = action_state.get_selected_entry()
						on_choice(sel and sel.value or nil)
					end)
					return true
				end,
			}):find()
			return
		end
	end
	vim.ui.select(items, opts, on_choice)
end

function M.pick_calendar()
	local items = { { id = nil, label = "All calendars", desc = "show every calendar", name = "All" } }
	for _, c in ipairs(M.available_calendars()) do
		local friendly = c.name ~= c.account and c.name or c.id
		table.insert(items, { id = c.id, href = c.href, account = c.account, label = friendly, desc = c.account, name = c.name })
	end
	ui_select(items, {
		prompt = "Calendar filter",
		format_item = function(it)
			if it.id == nil then return it.label end
			if it.label == it.desc then return it.label end
			return it.label .. " (" .. it.desc .. ")"
		end,
	}, function(choice)
		if not choice then return end
		if choice.id == nil then
			M.clear_calendar_filter()
			vim.notify("Bloocky: showing all calendars", vim.log.levels.INFO)
		else
			M.set_calendar_filter(choice.id, choice.label)
			vim.notify("Bloocky: filter → " .. choice.label, vim.log.levels.INFO)
		end
	end)
end

-- internal helper used by form.lua calendar field <CR> picker
-- Whole-account entries ("icloud (all)") are excluded: creation needs a
-- concrete calendar. They only make sense in the filter picker (f).
function M._pick_calendar_for_form(buf, win, on_choice)
	local avail = M.available_calendars()
	if #avail == 0 then
		vim.notify("Bloocky: no calendars available (sync first)", vim.log.levels.WARN)
		return
	end
	local items = {}
	for _, c in ipairs(avail) do
		if c.id ~= c.account then table.insert(items, c) end
	end
	if #items == 0 then
		-- nothing concrete known yet (no sync): fall back to whole-account
		for _, c in ipairs(avail) do table.insert(items, c) end
	end
	ui_select(items, {
		prompt = "Pick calendar",
		format_item = function(it)
			-- whole-account entry (name == account): show as account-wide target
			if it.name == it.account then return it.account .. "  (all)" end
			return it.name .. "  [" .. it.account .. "]"
		end,
	}, function(choice)
		if not choice then return end
		if on_choice then on_choice(choice.id) end
	end)
end

local function calendar_matches(block)
	if not M.calendar_filter then return true end
	local cal = require("bloocky.marks").calendar_of(block)
	if not cal then return false end
	-- filter may be "account" prefix or full "account/calendar_name" id
	if cal == M.calendar_filter then return true end
	if cal:find("^" .. vim.pesc(M.calendar_filter) .. "/") then return true end
	-- also match via label: e.g. filter = "izertis/Work" should match href-based cal
	local label = require("bloocky.marks").calendar_label(block)
	if label and label == M.calendar_filter then return true end
	if label and label:find("^" .. vim.pesc(M.calendar_filter) .. "/") then return true end
	return false
end

function M.calendar_badge(block)
	if not block then return nil end
	-- when filtered, badge is redundant
	if M.calendar_filter then return nil end
	if not require("bloocky.marks").needs_badge() then return nil end
	local label = require("bloocky.marks").calendar_label(block)
	if label then
		-- show only account id (e.g. "icloud" not "icloud/AAx...") to keep columns readable
		return label:match("^[^/]+") or label
	end
	return block.source and block.source ~= "local" and block.source or nil
end

-- Called by detail view when it replaces the calendar window's buffer
-- (buffer mode). Keeps the calendar buffer (buflisted, hidden) but marks
-- the calendar as closed so :Bloocky toggle works again.
function M._on_detail_replaced_buffer()
	win = nil
	-- keep buf (buflisted) for :b jump
end

--------------------------------------------------------------------------
-- The "syncing" indicator
--------------------------------------------------------------------------
-- A small float over the middle of the editor. The point is that the calendar
-- opens *now* and the network happens behind it, so this has to be entirely
-- passive: unfocusable, no autocmds, and it never blocks a keystroke.

local status = { win = nil, buf = nil, timer = nil, depth = 0 }
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function status_teardown()
	if status.timer then
		pcall(function()
			status.timer:stop()
			status.timer:close()
		end)
	end
	if status.win and vim.api.nvim_win_is_valid(status.win) then
		pcall(vim.api.nvim_win_close, status.win, true)
	end
	status = { win = nil, buf = nil, timer = nil, depth = 0 }
end

-- Nested calls are counted, so two overlapping syncs do not leave the
-- indicator hanging when the first one finishes.
function M.show_status(text)
	status.depth = status.depth + 1
	if status.win or not is_open() then
		return
	end

	local frame = 1
	local function label()
		return "  " .. SPINNER[frame] .. "  " .. text .. "  "
	end

	local width = utils.dw(label())
	status.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(status.buf, 0, -1, false, { label() })

	local ok, win_id = pcall(vim.api.nvim_open_win, status.buf, false, {
		relative = "editor",
		width = width,
		height = 1,
		row = math.floor((vim.o.lines - vim.o.cmdheight) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = config.options.window.border,
		-- Above the calendar (45) so it is not hidden behind it.
		zindex = 200,
		focusable = false,
		noautocmd = true,
	})
	if not ok then
		status.buf = nil
		return
	end
	status.win = win_id
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:BloockySyncStatus,FloatBorder:BloockySyncStatus",
		{ win = status.win }
	)

	status.timer = vim.uv.new_timer()
	status.timer:start(
		90,
		90,
		vim.schedule_wrap(function()
			if not (status.buf and vim.api.nvim_buf_is_valid(status.buf)) then
				return
			end
			frame = frame % #SPINNER + 1
			vim.api.nvim_buf_set_lines(status.buf, 0, -1, false, { label() })
		end)
	)
end

function M.hide_status()
	status.depth = math.max(0, status.depth - 1)
	if status.depth == 0 then
		status_teardown()
	end
end

--------------------------------------------------------------------------

local function sidebar_options()
	return config.options.window.sidebar or {}
end

local function resolve_mode(mode)
	if mode == "replace" then
		return "buffer"
	end
	if mode == "buffer" or mode == "sidebar" or mode == "float" then
		return mode
	end
	return "float"
end

local function sync_enabled()
	local sync = config.options.sync
	return sync and sync.enabled and #(sync.accounts or {}) > 0
end

local function filtered_account()
	if not M.calendar_filter then return nil end
	return M.calendar_filter:match("^[^/]+")
end

-- Sync now, showing the indicator while it runs and redrawing after.
-- `quiet` is for syncs the user did not ask for by hand.
-- When a calendar filter is active (e.g. Bloocky week izertis), :e and periodic
-- syncs limit themselves to that account so we don't refresh every calendar.
function M.sync(opts)
	opts = opts or {}
	if not sync_enabled() then
		if not opts.quiet then
			vim.notify("Bloocky: sync is not enabled (see sync.accounts)", vim.log.levels.WARN)
		end
		return
	end

	local target = opts.account or filtered_account()
	if target then
		-- label reflects the filter so spinner isn't misleading
		opts.label = opts.label or ("syncing " .. target)
	end
	M.show_status(opts.label or "syncing")
	require("bloocky.sync").run(target, function(reports)
		M.hide_status()
		M.render()
		if opts.on_done then
			opts.on_done(reports)
		end
	end, { quiet = opts.quiet })
end

--------------------------------------------------------------------------
-- Keeping up while the window is open
--------------------------------------------------------------------------
-- A repeating pull, but one that gets out of the way. A laptop that has been
-- shut in a bag offline for an hour should not have spent that hour retrying
-- every fifteen minutes, so consecutive failures widen the gap.

local periodic = { timer = nil, failures = 0 }

local function stop_periodic()
	if periodic.timer then
		pcall(function()
			periodic.timer:stop()
			periodic.timer:close()
		end)
	end
	periodic.timer = nil
end

local MAX_BACKOFF_STEPS = 3 -- 15m -> 30m -> 60m -> 120m, then level off

local function schedule_periodic()
	stop_periodic()

	local sync = config.options.sync or {}
	local minutes = sync.interval_min
	if not (sync_enabled() and type(minutes) == "number" and minutes > 0) then
		return
	end

	local multiplier = 2 ^ math.min(periodic.failures, MAX_BACKOFF_STEPS)
	periodic.timer = vim.defer_fn(function()
		periodic.timer = nil
		-- The window may have closed, or sync been turned off, while we waited.
		if not (is_open() and sync_enabled()) then
			return
		end
		M.sync({
			quiet = true,
			on_done = function(reports)
				-- Any failed account backs the whole timer off. Otherwise, with
				-- one broken account and one healthy one, whether the failure
				-- was seen would depend on which finished last.
				local failed = false
				for _, report in ipairs(reports or {}) do
					if #report.errors > 0 then
						failed = true
					end
				end
				if failed then
					periodic.failures = periodic.failures + 1
				else
					periodic.failures = 0
				end
				schedule_periodic()
			end,
		})
	end, math.floor(minutes * 60 * 1000 * multiplier))
end

-- Exposed for the specs; the lifecycle is otherwise tied to the window.
M.start_periodic_sync = schedule_periodic
M.stop_periodic_sync = stop_periodic

function M.periodic_state()
	return { running = periodic.timer ~= nil, failures = periodic.failures }
end

-- One sync for a burst of edits, rather than one per keystroke. Public so the
-- coalescing can be tested: without it, editing five blocks in a row would
-- fire five syncs at the server.
local edit_timer = nil

function M.schedule_sync()
	local sync = config.options.sync
	if not (sync_enabled() and sync.sync_on_edit ~= false) then
		return
	end
	if edit_timer then
		pcall(function()
			edit_timer:stop()
			edit_timer:close()
		end)
		edit_timer = nil
	end
	edit_timer = vim.defer_fn(function()
		edit_timer = nil
		M.sync({ quiet = true })
	end, sync.edit_debounce_ms or 1500)
end

-- Columns the sidebar split asks for
local function sidebar_width()
	local w = sidebar_options().width or 46
	if w <= 1 then
		w = vim.o.columns * w
	end
	return math.floor(math.max(20, math.min(w, vim.o.columns - 4)))
end

-- A size option is either a single value or one value per view
local function per_view(value)
	if type(value) == "table" then
		return value[M.view]
	end
	return value
end

-- Cells the border steals from the editor (title and footer live in it)
local function border_cells()
	local b = config.options.window.border
	if not b or b == "none" or b == "shadow" then
		return 0
	end
	return 2
end

local function content_width()
	if M.mode == "sidebar" then
		-- The split may have been resized by hand, so trust the window itself
		return is_open() and vim.api.nvim_win_get_width(win) or sidebar_width()
	end
	if M.mode == "buffer" then
		return is_open() and vim.api.nvim_win_get_width(win) or vim.o.columns
	end

	local usable = math.max(20, vim.o.columns - border_cells())
	local w = per_view(config.options.window.width) or 0.8
	if w == "full" then
		return usable
	end
	if w > 1 then
		return math.floor(math.min(w, usable))
	end
	return math.floor(math.min(vim.o.columns * w, usable))
end

-- Rows usable for content: the editor minus the command line and the border,
-- keeping one spare row so the window never sits flush against the cmdline.
local function max_height()
	if M.mode == "sidebar" then
		local h = is_open() and vim.api.nvim_win_get_height(win) or (vim.o.lines - vim.o.cmdheight - 2)
		-- The winbar carries the title and takes a row out of the window
		return math.max(6, h - 1)
	end
	if M.mode == "buffer" then
		local h = is_open() and vim.api.nvim_win_get_height(win) or (vim.o.lines - vim.o.cmdheight - 1)
		return math.max(6, h - 1)
	end
	return math.max(6, vim.o.lines - vim.o.cmdheight - border_cells() - 1)
end

-- Rows the view is laid out in, and whether it should stretch to cover them.
-- "auto" lets the view stay compact inside everything on offer, anything else
-- pins a height the view fills exactly.
local function target_height()
	local max = max_height()
	local h = per_view(config.options.window.height) or "auto"
	if h == "full" then
		return max, true
	end
	if type(h) == "number" then
		local want = (h > 1) and h or ((vim.o.lines - vim.o.cmdheight) * h)
		return math.max(6, math.min(math.floor(want), max)), true
	end
	return max, false
end

local function clamp_cursor()
	local h0 = config.options.hours.start
	local h1 = config.options.hours["end"]
	local min = M.cursor.min or h0 * 60
	-- last grid sub-row starts 15 min before the end of the visible range
	M.cursor.min = math.min(math.max(min, h0 * 60), h1 * 60 - 15)
end

local function footer_text(width)
	local km = config.options.keymaps.calendar
	local sync_hint = (km.sync and sync_enabled()) and (" · " .. km.sync .. " sync") or ""
	local filter_hint = ""
	pcall(function()
		if require("bloocky.marks").distinct_calendars() > 1 or M.calendar_filter then
			filter_hint = " · " .. (km.filter_calendar or "f") .. " filter"
		end
	end)
	local full = string.format(
		" %s add · %s edit · %s delete · %s view · %s today%s%s · %s close ",
		km.add or "-",
		km.edit or "-",
		km.delete or "-",
		km.cycle_view or "-",
		km.today or "-",
		sync_hint,
		filter_hint,
		km.close or "-"
	)
	if width and utils.dw(full) > width then
		return string.format(" %s add · %s edit · %s close ", km.add or "-", km.edit or "-", km.close or "-")
	end
	return full
end

-- Redraw the calendar for the current view/cursor
function M.render()
	if not is_open() then
		return
	end
	clamp_cursor()
	-- Once per redraw, not once per block.
	require("bloocky.marks").refresh()

	local height, fill = target_height()
	local ctx = {
		width = content_width(),
		height = height,
		fill = fill,
		cursor = M.cursor,
		today = utils.today(),
		config = config.options,
	}
	local lines, hls, meta = views[M.view].render(ctx)

	-- calendar filter badge in title
	if M.calendar_filter then
		local label = M.calendar_filter_label or M.calendar_filter
		meta.title = (meta.title or " Bloocky "):gsub("%s+$", "") .. " [" .. label .. "] "
	elseif require("bloocky.marks").distinct_calendars() > 1 then
		meta.title = (meta.title or " Bloocky "):gsub("%s+$", "") .. " — All "
	end

	if M.mode == "sidebar" or M.mode == "buffer" then
		-- A split / buffer cannot carry a float title, so the winbar stands in for it
		local title = (meta.title or " Bloocky "):gsub("%%", "%%%%")
		pcall(vim.api.nvim_set_option_value, "winbar", "%=" .. title .. "%=", { win = win })
		if M.mode == "buffer" then
			-- keep footer visible as last line hint in buffer mode? no float footer
		end
	else
		local width = meta.width or ctx.width
		local rows = math.min(#lines, ctx.height)
		-- Centre inside the rows the editor actually offers, border included
		local usable = vim.o.lines - vim.o.cmdheight
		local row = math.floor((usable - (rows + border_cells())) / 2)
		vim.api.nvim_win_set_config(win, {
			relative = "editor",
			width = width,
			height = rows,
			row = math.max(0, row),
			col = math.max(0, math.floor((vim.o.columns - width) / 2)),
			title = meta.title or " Bloocky ",
			title_pos = "center",
			footer = footer_text(width),
			footer_pos = "center",
		})
	end

	if not pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf }) then
		return
	end
	if not pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines) then
		return
	end
	pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
	pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

	if not pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1) then
		return
	end
	for _, h in ipairs(hls) do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.s, {
			end_col = h.e,
			hl_group = h.group,
			priority = h.prio or 100,
		})
	end

	pcall(vim.api.nvim_win_set_cursor, win, { meta.cursor_line or 1, 0 })

	-- Reverse map for native cursor moves (arrows/mouse): grid line -> slot.
	last_grid = { view = M.view, slots = meta.slots, day_cols = meta.day_cols, slot_days = meta.slot_days }
end

-- Native cursor moves (arrow keys, mouse) bypass move_cursor, leaving
-- M.cursor stale so actions target the wrong slot. Sync it from the window
-- position using the last render's slot map; no-op when already in sync
-- (including our own programmatic cursor placement, so no render loop).
local function sync_cursor_from_window()
	if not is_open() or not last_grid or not last_grid.slots then
		return
	end
	if M.view == "month" then
		return
	end
	local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
	if not ok then
		return
	end
	local rec = last_grid.slots[pos[1] - 1]
	if not rec then
		return
	end
	local new_date, new_min = M.cursor.date, rec.s
	if last_grid.view == "week" and last_grid.day_cols and last_grid.slot_days then
		for i, range in ipairs(last_grid.day_cols) do
			if pos[2] >= range.s and pos[2] < range.e then
				new_date = last_grid.slot_days[i]
				break
			end
		end
	end
	local same_date = new_date.year == M.cursor.date.year and new_date.month == M.cursor.date.month and new_date.day == M.cursor.date.day
	if same_date and new_min == M.cursor.min then
		return
	end
	M.cursor.date = new_date
	M.cursor.min = new_min
	M.render()
end

-- Floating cheatsheet with every calendar keymap, built from the live
-- config so user overrides always show their real bindings.
local function show_help()
	local km = config.options.keymaps.calendar
	local function key(name)
		return "`" .. (km[name] or ("<" .. name .. ">")) .. "`"
	end
	local rows = {
		{ key("nav_left") .. " / " .. key("nav_right") .. "  (b / w, ← / →)", "previous / next day" },
		{ key("nav_up") .. " / " .. key("nav_down") .. "  (↑ / ↓)", "previous / next slot" },
		{ key("prev_period") .. " / " .. key("next_period"), "previous / next week (month in month view)" },
		{ key("goto_first_col"), "first column of the row" },
		{ key("goto_top") .. " / " .. key("goto_bottom"), "first / last slot of the column" },
		{ key("view_day") .. " / " .. key("view_week") .. " / " .. key("view_month") .. " / " .. key("cycle_view"), "day / week / month view / cycle" },
		{ key("today"), "go to today" },
		{ key("add"), "new event on this slot" },
		{ key("edit"), "event details (picker when overlapping)" },
		{ key("detail_hsplit") .. " / " .. key("detail_vsplit"), "details in split / vsplit" },
		{ key("delete"), "delete event under cursor" },
	}
	if km.sync and sync_enabled() then
		table.insert(rows, { key("sync"), "sync now" })
	end
	table.insert(rows, { key("filter_calendar"), "calendar filter (all vs single)" })
	table.insert(rows, { key("help"), "this help" })
	table.insert(rows, { key("close"), "close calendar" })

	local lines = { "# Bloocky keymaps", "" }
	local width = 20
	for _, row in ipairs(rows) do
		local line = "- " .. row[1] .. "  " .. row[2]
		table.insert(lines, line)
		width = math.max(width, utils.dw(line))
	end
	width = math.min(width + 2, vim.o.columns - 4)

	local hbuf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = hbuf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = hbuf })
	vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = hbuf })
	vim.api.nvim_set_option_value("modified", false, { buf = hbuf })

	local hwin = vim.api.nvim_open_win(hbuf, true, {
		relative = "editor",
		width = width,
		height = math.min(#lines, math.max(5, vim.o.lines - 6)),
		row = math.max(0, math.floor((vim.o.lines - #lines) / 2 - 1)),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		style = "minimal",
		border = "rounded",
		title = " Bloocky keymaps ",
		title_pos = "center",
	})
	local kopts = { buffer = hbuf, noremap = true, silent = true, nowait = true }
	vim.keymap.set("n", "q", "<cmd>close<cr>", kopts)
	vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", kopts)
	pcall(vim.api.nvim_win_set_cursor, hwin, { 1, 0 })
end

-- First/last visible date in the cursor's weekday column (month view).
local function month_column_edge(date, first)
	local one = { year = date.year, month = date.month, day = 1 }
	local gs = utils.week_start_of(one, config.options.week_start)
	local last = { year = date.year, month = date.month, day = utils.days_in_month(date.year, date.month) }
	local span_days = math.floor((utils.date_to_time(last) - utils.date_to_time(gs)) / 86400) + 1
	local weeks = math.ceil(span_days / 7)
	local diff = (utils.wday(date) - utils.wday(gs)) % 7
	if first then
		return utils.add_days(gs, diff)
	end
	return utils.add_days(gs, diff + 7 * (weeks - 1))
end

-- Cursor movement / period jumps
local function move_cursor(action)
	local c = M.cursor
	if action == "left" then
		c.date = utils.add_days(c.date, -1)
	elseif action == "right" then
		c.date = utils.add_days(c.date, 1)
	elseif action == "up" then
		if M.view == "month" then
			c.date = utils.add_days(c.date, -7)
		else
			-- one grid sub-row in day/week views
			c.min = c.min - utils.slot_min(config.options.window)
		end
	elseif action == "down" then
		if M.view == "month" then
			c.date = utils.add_days(c.date, 7)
		else
			c.min = c.min + utils.slot_min(config.options.window)
		end
	elseif action == "prev" then
		if M.view == "month" then
			c.date = utils.add_months(c.date, -1)
		else
			c.date = utils.add_days(c.date, -7)
		end
	elseif action == "next" then
		if M.view == "month" then
			c.date = utils.add_months(c.date, 1)
		else
			c.date = utils.add_days(c.date, 7)
		end
	elseif action == "today" then
		c.date = utils.today()
	elseif action == "top" then
		if M.view == "month" then
			c.date = month_column_edge(c.date, true)
		else
			c.min = config.options.hours.start * 60
		end
	elseif action == "bottom" then
		if M.view == "month" then
			c.date = month_column_edge(c.date, false)
		else
			c.min = config.options.hours["end"] * 60 - 15
		end
	elseif action == "first_col" then
		-- Day view has a single column: stay. Week/month jump to the first
		-- visible day of the current row (week start).
		if M.view == "week" or M.view == "month" then
			c.date = utils.week_start_of(c.date, config.options.week_start)
		end
	end
	M.render()
end

-- Blocks under the cursor: whole day in month view, the 15-minute sub-row
-- otherwise, so picking matches exactly what the grid cell shows.
local function hits_at_cursor()
	local blocks = state.blocks_for_date(M.cursor.date)
	if M.view == "month" then
		return blocks
	end
	local s = M.cursor.min
	local e = s + 15
	local out = {}
	for _, block in ipairs(blocks) do
		if block.start_min < e and block.start_min + block.duration_min > s then
			table.insert(out, block)
		end
	end
	return out
end

local function pick_block(blocks, callback)
	if #blocks == 1 then
		callback(blocks[1])
		return
	end
	-- Same picker chain as calendars (snacks → telescope → vim.ui.select),
	-- so overlapping events never fall back to type-a-number.
	ui_select(blocks, {
		prompt = "Which block?",
		format_item = function(block)
			local badge = M.calendar_badge(block)
			badge = badge and ("[" .. badge .. "] ") or ""
			return utils.format_hhmm(block.start_min) .. " " .. badge .. block.title
		end,
	}, function(choice)
		if choice then
			callback(choice)
		end
	end)
end

-- The window the dialog should hand focus back to once it closes. Passed
-- explicitly because vim.ui.select may still own the cursor at that point.
local function return_win()
	return is_open() and win or nil
end

-- Open the creation dialog prefilled with the cursor slot
function M.add_block()
	require("bloocky.dialog").open({
		return_win = return_win(),
		prefill = {
			date = utils.date_to_str(M.cursor.date),
			start_min = (M.view == "month") and 9 * 60 or M.cursor.min,
		},
		on_save = function(fields)
			state.add_block(fields)
			M.render()
			M.schedule_sync()
		end,
	})
end

-- Edit the block under the cursor (or create one on an empty slot)
function M.edit_block()
	local blocks = hits_at_cursor()
	if #blocks == 0 then
		M.add_block()
		return
	end
	local back = return_win()
	pick_block(blocks, function(block)
		require("bloocky.dialog").open({
			block = block,
			return_win = back,
			on_save = function(fields)
				state.update_block(block.id, fields)
				M.render()
				M.schedule_sync()
			end,
		})
	end)
end

-- Show block details as markdown (replaces dialog for viewing)
function M.open_detail(split)
	local blocks = hits_at_cursor()
	if #blocks == 0 then
		M.add_block()
		return
	end
	pick_block(blocks, function(block)
		require("bloocky.detail").open(block, { split = split or "current" })
	end)
end

-- Delete the block under the cursor
function M.delete_block()
	local blocks = hits_at_cursor()
	if #blocks == 0 then
		vim.notify("Bloocky: no block under the cursor", vim.log.levels.INFO)
		return
	end
	pick_block(blocks, function(block)
		local label = block.title
		-- vim.NIL, not just nil: a block written with an explicit
		-- `"recurrence": null` by another writer is still a one-off, and must
		-- not get the scary whole-series warning.
		if block.recurrence and block.recurrence ~= vim.NIL then
			label = label .. " (recurring — the whole series will be deleted)"
		end
		if vim.fn.confirm('Delete "' .. label .. '"?', "&Yes\n&No", 2) == 1 then
			state.delete_block(block.id)
			M.render()
			M.schedule_sync()
		end
	end)
end

function M.set_view(view)
	if views[view] then
		M.view = view
		M.render()
	end
end

function M.cycle_view()
	for i, v in ipairs(view_order) do
		if v == M.view then
			M.view = view_order[(i % #view_order) + 1]
			break
		end
	end
	M.render()
end

local function setup_keymaps()
	local km = config.options.keymaps.calendar
	local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
	local map = function(lhs, fn)
		if lhs then
			vim.keymap.set("n", lhs, fn, opts)
		end
	end
	map(km.nav_left, function()
		move_cursor("left")
	end)
	map(km.nav_right, function()
		move_cursor("right")
	end)
	map(km.nav_up, function()
		move_cursor("up")
	end)
	map(km.nav_down, function()
		move_cursor("down")
	end)
	-- `w`/`b` behave like `l`/`h` (next/previous day), matching the arrows
	-- below: buffer-local, so global mappings are untouched.
	vim.keymap.set("n", "w", function()
		move_cursor("right")
	end, opts)
	vim.keymap.set("n", "b", function()
		move_cursor("left")
	end, opts)
	-- Arrow keys always work too, so the visual cursor and M.cursor can
	-- never disagree about which slot actions target.
	vim.keymap.set("n", "<Up>", function()
		move_cursor("up")
	end, opts)
	vim.keymap.set("n", "<Down>", function()
		move_cursor("down")
	end, opts)
	vim.keymap.set("n", "<Left>", function()
		move_cursor("left")
	end, opts)
	vim.keymap.set("n", "<Right>", function()
		move_cursor("right")
	end, opts)
	map(km.prev_period, function()
		move_cursor("prev")
	end)
	map(km.next_period, function()
		move_cursor("next")
	end)
	map(km.today, function()
		move_cursor("today")
	end)
	map(km.goto_top or "gg", function()
		move_cursor("top")
	end)
	map(km.goto_bottom or "G", function()
		move_cursor("bottom")
	end)
	map(km.goto_first_col or "0", function()
		move_cursor("first_col")
	end)
	map(km.help or "g?", function()
		show_help()
	end)
	map(km.view_day, function()
		M.set_view("day")
	end)
	map(km.view_week, function()
		M.set_view("week")
	end)
	map(km.view_month, function()
		M.set_view("month")
	end)
	map(km.cycle_view, M.cycle_view)
	map(km.add, M.add_block)
	-- <CR> now shows markdown details instead of the floating edit dialog
	map(km.edit or "<CR>", function()
		M.open_detail("current")
	end)
	-- splits for details: <C-s> horizontal, <C-v> vertical
	map(km.detail_hsplit or "<C-s>", function()
		M.open_detail("horizontal")
	end)
	map(km.detail_vsplit or "<C-v>", function()
		M.open_detail("vertical")
	end)
	map(km.delete, M.delete_block)
	if km.sync and sync_enabled() then
		map(km.sync, function()
			M.sync()
		end)
	end
	map(km.filter_calendar or "f", M.pick_calendar)
	map(km.close, M.close)
	if M.mode == "float" then
		-- In sidebar/buffer <Esc> is too eager: they are windows you keep around
		map("<Esc>", M.close)
	end
end

local function open_float()
	win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 20,
		height = 10,
		row = 3,
		col = 3,
		style = "minimal",
		border = config.options.window.border,
		title = " Bloocky ",
		title_pos = "center",
		zindex = 45,
	})
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })
end

local function open_sidebar()
	-- A split cannot be opened from a floating window, so step out of one first
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.api.nvim_win_get_config(w).relative == "" then
				vim.api.nvim_set_current_win(w)
				break
			end
		end
	end

	local side = sidebar_options().position == "left" and "topleft" or "botright"
	vim.cmd(side .. " vsplit")
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_width(win, sidebar_width())

	for name, value in pairs({
		cursorline = false,
		wrap = false,
		number = false,
		relativenumber = false,
		list = false,
		spell = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		winfixwidth = true,
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
end

local function open_buffer()
	-- Replace current buffer in current window (or a normal window if we are in a float)
	local target = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_config(target).relative ~= "" then
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.api.nvim_win_get_config(w).relative == "" then
				target = w
				break
			end
		end
	end
	win = target
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_buf(win, buf)
	-- Mirror sidebar window opts so width maths match text area (otherwise
	-- number/signcolumn eat 4+ columns and Sunday gets chopped with `wrap=false`)
	for name, value in pairs({
		cursorline = false,
		wrap = false,
		number = false,
		relativenumber = false,
		list = false,
		spell = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
	}) do
		pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
	end
end

-- Normalise the public argument: a view name, or { view = ..., mode = ... }
local function normalize(opts)
	if type(opts) == "string" then
		return { view = opts }
	end
	return opts or {}
end

-- Open the calendar (optionally forcing a view and/or a window mode)
function M.open(opts)
	opts = normalize(opts)
	highlights.setup()
	state.ensure_loaded()

	if opts.calendar_filter ~= nil then
		M.calendar_filter = opts.calendar_filter ~= "" and opts.calendar_filter or nil
		M.calendar_filter_label = opts.calendar_filter_label or M.calendar_filter
	elseif opts.calendar ~= nil then
		M.calendar_filter = opts.calendar ~= "" and opts.calendar or nil
		M.calendar_filter_label = opts.calendar_label or M.calendar_filter
	end

	local raw_mode = opts.mode or (is_open() and M.mode) or config.options.window.mode or "float"
	local mode = resolve_mode(raw_mode)

	local keep_cursor, keep_view = nil, nil
	if is_open() then
		if mode == M.mode then
			if opts.view and views[opts.view] then
				M.view = opts.view
			end
			vim.api.nvim_set_current_win(win)
			M.render()
			return
		end
		-- Switching mode rebuilds the window, so carry the cursor and view across
		keep_cursor, keep_view = M.cursor, M.view
		M.close()
	end

	M.mode = mode
	M.view = opts.view or keep_view or (mode == "sidebar" and sidebar_options().view) or config.options.default_view
	if not views[M.view] then
		M.view = "week"
	end

	local now = os.date("*t")
	M.cursor = keep_cursor or { date = utils.today(), min = now.hour * 60 }

	-- Reuse existing buflisted buffer when in buffer mode
	if mode == "buffer" and buf and vim.api.nvim_buf_is_valid(buf) then
		-- keep existing buffer, just ensure filetype
		vim.api.nvim_set_option_value("filetype", "bloocky", { buf = buf })
	else
		local listed = mode == "buffer"
		buf = vim.api.nvim_create_buf(listed, false)
		vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
		vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
		if mode == "buffer" then
			vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
			pcall(vim.api.nvim_buf_set_name, buf, "bloocky://calendar/" .. mode)
		else
			vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
		end
		vim.api.nvim_set_option_value("filetype", "bloocky", { buf = buf })

		-- :e on calendar buffer re-renders and triggers sync
		vim.api.nvim_create_autocmd("BufReadCmd", {
			buffer = buf,
			callback = function()
				M.render()
				if sync_enabled() then
					M.schedule_sync()
				end
			end,
		})
	end

	if mode == "sidebar" then
		open_sidebar()
	elseif mode == "buffer" then
		open_buffer()
	else
		open_float()
	end

	setup_keymaps()

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			win = nil
			if M.mode ~= "buffer" then
				buf = nil
			end
			-- buffer mode keeps buf (buflisted) so we can :b bloocky
		end,
	})

	-- External wipe (e.g. `:bwipeout!`) bypasses M.close(): drop the stale
	-- window title and internal state so a reopen starts fresh instead of
	-- rendering into an invalid buffer.
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			clear_winbar(win)
			status_teardown()
			stop_periodic()
			win = nil
			buf = nil
			last_grid = nil
		end,
	})

	-- Native moves (arrow keys, mouse) bypass move_cursor: re-derive the
	-- slot from the window position so actions target the visible cell.
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			sync_cursor_from_window()
		end,
	})

	-- Refit the layout to the new terminal size
	vim.api.nvim_create_autocmd("VimResized", {
		buffer = buf,
		callback = function()
			if not is_open() then
				return true
			end
			if M.mode == "sidebar" then
				pcall(vim.api.nvim_win_set_width, win, sidebar_width())
			end
			M.render()
		end,
	})

	if mode == "sidebar" then
		-- WinResized is matched against window IDs, so it cannot be buffer-local:
		-- watch globally and drop out once the sidebar is gone
		local last_w, last_h
		vim.api.nvim_create_autocmd("WinResized", {
			callback = function()
				if not is_open() then
					return true
				end
				local w, h = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
				if w ~= last_w or h ~= last_h then
					last_w, last_h = w, h
					M.render()
				end
			end,
		})
	end

	M.render()

	-- Deferred so the window is on screen before any network work starts:
	-- opening the calendar must never wait on a server.
	local sync = config.options.sync
	if sync_enabled() and sync.sync_on_open ~= false then
		vim.schedule(function()
			M.sync({ quiet = true })
		end)
	end
	-- A fresh window starts from a clean slate rather than inheriting the
	-- backoff of whatever went wrong last time.
	periodic.failures = 0
	schedule_periodic()
end

function M.open_sidebar(view)
	local so = sidebar_options()
	local mode = resolve_mode(config.options.window.mode or "float")
	M.open({ view = view or so.view, mode = mode })
end

function M.close()
	status_teardown()
	stop_periodic()
	if is_open() then
		if M.mode == "buffer" then
			clear_winbar(win)
			-- keep buffer listed; just close window or hide it
			if not pcall(vim.api.nvim_win_close, win, true) then
				-- last window - hide buffer instead of deleting
				pcall(vim.api.nvim_set_option_value, "bufhidden", "hide", { buf = buf })
				-- try to switch to alternate buffer
				pcall(vim.cmd, "b#")
			end
			win = nil
			-- keep buf for :b jump (buflisted)
			return
		end
		-- Closing the last window of a tab is refused; drop the buffer instead
		if not pcall(vim.api.nvim_win_close, win, true) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	win = nil
	buf = nil
end

-- Close when the calendar already shows what was asked for, open otherwise
function M.toggle(opts)
	opts = normalize(opts)
	if is_open() and (not opts.mode or opts.mode == M.mode) then
		M.close()
	else
		M.open(opts)
	end
end

function M.toggle_sidebar(view)
	local so = sidebar_options()
	local mode = resolve_mode(config.options.window.mode or "float")
	M.toggle({ view = view or so.view, mode = mode })
end

return M
