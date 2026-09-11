local config = require("bloocky.config")
local utils = require("bloocky.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("bloocky_dialog")

-- Form layout: "full" and "left" open a new row, "right" joins the previous one
local LAYOUT = {
	{ "Title", "full" },
	{ "Date", "left" },
	{ "Start", "right" },
	{ "Duration", "left" },
	{ "Repeat", "right" },
	{ "Days", "left" },
	{ "Until", "right" },
	{ "Calendar", "full" },
	{ "Teams", "full" },
	{ "Notes", "full" },
	{ "Attendees", "full" },
}

-- Shown inside an input while it is empty
local HINTS = {
	Title = "what are you blocking time for?",
	Date = "YYYY-MM-DD",
	Start = "HH:MM (24h)",
	Duration = "1h30m · 45m · 2h",
	Repeat = "none · daily · weekly …",
	Days = "mon,wed,fri",
	Until = "empty = forever",
	Calendar = "izertis / icloud or account/calendar",
	Teams = "yes / no",
	Notes = "optional",
	Attendees = "name <email>, name2 <email2>",
}

-- Extmark ids inside each input buffer
local MARK_HINT = 1
local MARK_ERROR = 2

local WIDTH = 56
local PAD = 2
local GAP = 2

-- Positions of every label/input inside the container, and its height
local function layout()
	local inner = WIDTH - PAD * 2
	local half = math.floor((inner - GAP) / 2)
	local items, row = {}, 0
	for _, spec in ipairs(LAYOUT) do
		local field, slot = spec[1], spec[2]
		if slot == "right" then
			local rcol = PAD + half + GAP
			items[#items + 1] =
				{ field = field, label_row = row - 3, input_row = row - 2, col = rcol, width = WIDTH - PAD - rcol }
		else
			items[#items + 1] = {
				field = field,
				label_row = row,
				input_row = row + 1,
				col = PAD,
				width = (slot == "full") and inner or half,
			}
			row = row + 3
		end
	end
	return items, row - 1
end

local function calendar_initial(block, prefill)
	if block then
		local ok, lab = pcall(function() return require("bloocky.marks").calendar_label(block) end)
		if ok and lab and lab ~= "" then return lab end
		return block.calendar or block.source or ""
	end
	local ok, ui = pcall(require, "bloocky.ui")
	if ok and ui.calendar_filter then return ui.calendar_filter end
	local ok2, def = pcall(function() return require("bloocky.ui").default_calendar() end)
	if ok2 and def then return def end
	return ""
end

local function initial_values(opts)
	local block = opts.block
	if block then
		local r = block.recurrence
		local day_names = {}
		if r and type(r.days) == "table" then
			local rev = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
			for _, d in ipairs(r.days) do
				table.insert(day_names, rev[d])
			end
		end
	return {
		Title = block.title,
		Date = block.date,
		Start = utils.format_hhmm(block.start_min),
		Duration = utils.format_duration(block.duration_min),
		Repeat = r and r.type or "none",
		Days = table.concat(day_names, ","),
		Until = (r and r.until_date) or "",
		Calendar = calendar_initial(block, nil),
		Teams = block.teams and "yes" or "no",
		Notes = (block.notes or ""):gsub("\n", " "),
		Attendees = block.attendees and format_attendees(block.attendees) or "",
	}
end

local function format_attendees(attendees)
	if type(attendees) ~= "table" or #attendees == 0 then
		return ""
	end
	local parts = {}
	for _, a in ipairs(attendees) do
		if a.name and a.email then
			table.insert(parts, a.name .. " <" .. a.email .. ">")
		elseif a.email ~= "" then
			table.insert(parts, a.email)
		else
			table.insert(parts, a.name or "")
		end
	end
	return table.concat(parts, ", ")
end
	local prefill = opts.prefill or {}
	return {
		Title = "",
		Date = prefill.date or utils.date_to_str(utils.today()),
		Start = utils.format_hhmm(prefill.start_min or 9 * 60),
		Duration = "1h",
		Repeat = "none",
		Days = "",
		Until = "",
		Calendar = calendar_initial(nil, prefill),
		Teams = "no",
		Notes = "",
		Attendees = "",
	}
end

-- Parse "Alice <alice@b.com>, Bob <bob@b.com>" into { {name, email} }
local function parse_attendees(raw)
	local out = {}
	if not raw or raw == "" then
		return nil
	end
	local str = raw
	while true do
		local token = str:match("^%s*([^,]*),")
		if not token then
			token = str:match("^%s*(.+)")
			if not token or token:match("^%s*$") then
				break
			end
			token = token:gsub("^%s*(.-)%s*$", "%1")
			str = ""
		else
			str = str:sub(#token + 2)
			token = token:gsub("^%s*(.-)%s*$", "%1")
		end
		-- token may be "Name <email>" or just "email" or "Name"
		local name, email = token:match("^(.-)%s*<([^>]+)>%s*$")
		if name and email then
			name = name:gsub("^%s*(.-)%s*$", "%1")
			email = email:gsub("^%s*(.-)%s*$", "%1")
			table.insert(out, { name = name ~= "" and name or email, email = email })
		elseif token:match("@") then
			table.insert(out, { name = token, email = token })
		elseif token ~= "" then
			table.insert(out, { name = token, email = "" })
		end
		if str == "" then
			break
		end
	end
	return #out > 0 and out or nil
end

-- Validate raw field values (lowercase keys) into block fields.
-- Returns fields, or nil plus a { Field = "message" } table.
local function validate(raw)
	local errs = {}

	local title = vim.trim(raw.title or "")
	if title == "" then
		errs.Title = "required"
	end
	local date = utils.str_to_date(vim.trim(raw.date or ""))
	if not date then
		errs.Date = "use YYYY-MM-DD"
	end
	local start_min = utils.parse_hhmm(vim.trim(raw.start or ""))
	if not start_min then
		errs.Start = "use HH:MM (24h)"
	end
	local duration = utils.parse_duration(vim.trim(raw.duration or ""))
	if not duration then
		errs.Duration = "e.g. 1h30m"
	end

	local rtype = vim.trim(raw["repeat"] or ""):lower()
	if rtype == "" then
		rtype = "none"
	end
	local valid_repeat = { none = true, daily = true, weekly = true, weekdays = true, custom = true }
	if not valid_repeat[rtype] then
		errs.Repeat = "none/daily/weekly/weekdays/custom"
	end

	local days = nil
	if rtype == "custom" then
		days = {}
		for token in (raw.days or ""):gmatch("[^,%s]+") do
			local wd = utils.DAY_TOKENS[token:lower():sub(1, 3)]
			if wd then
				table.insert(days, wd)
			else
				errs.Days = "unknown day: " .. token
			end
		end
		if #days == 0 and not errs.Days then
			errs.Days = "e.g. mon,wed,fri"
		end
	end

	local until_date = nil
	local u_raw = vim.trim(raw["until"] or "")
	if u_raw ~= "" then
		local u = utils.str_to_date(u_raw)
		if u then
			until_date = utils.date_to_str(u)
		else
			errs.Until = "use YYYY-MM-DD"
		end
	end

	duration = math.max(1, duration)

	local recurrence = nil
	if rtype ~= "none" then
		recurrence = { type = rtype, days = days, until_date = until_date }
	end

	local teams = nil
	if raw.teams ~= nil then
		local t = vim.trim(tostring(raw.teams)):lower()
		if t == "yes" or t == "true" or t == "1" or t == "si" or t == "sí" or t == "teams" or t == "y" or t == "s" then
			teams = true
		elseif t == "no" or t == "false" or t == "0" or t == "n" then
			teams = false
		end
	end

	-- Calendar: which account/calendar to create in
	local calendar_id, calendar_account, calendar_href, calendar_name = nil, nil, nil, nil
	do
		local cal_raw = vim.trim(tostring(raw.calendar or ""))
		if cal_raw == "" then
			local ok, ui = pcall(require, "bloocky.ui")
			if ok and ui.calendar_filter and ui.calendar_filter ~= "" then
				cal_raw = ui.calendar_filter
			else
				local ok2, def = pcall(function() return require("bloocky.ui").default_calendar() end)
				if ok2 and def and def ~= "" then cal_raw = def end
			end
		end
		if cal_raw ~= "" and cal_raw:lower() ~= "all" and cal_raw:lower() ~= "local" then
			local avail = {}
			pcall(function() avail = require("bloocky.ui").available_calendars() end)
			local found = nil
			for _, c in ipairs(avail) do
				if c.id == cal_raw or c.id:lower() == cal_raw:lower() or c.account:lower() == cal_raw:lower() or c.name:lower() == cal_raw:lower() then
					found = c; break
				end
			end
			if not found then
				-- try prefix match
				for _, c in ipairs(avail) do
					if c.id:lower():find(vim.pesc(cal_raw:lower()), 1, true) then found = c; break end
				end
			end
			if not found then
				errs.Calendar = "unknown calendar: " .. cal_raw
			else
				calendar_id = found.id
				calendar_account = found.account
				calendar_href = found.href
				calendar_name = found.name
			end
		end
	end

	if next(errs) then
		return nil, errs
	end

	return {
		title = title,
		date = utils.date_to_str(date),
		start_min = start_min,
		duration_min = duration,
		notes = vim.trim(raw.notes or ""),
		recurrence = recurrence,
		attendees = parse_attendees(raw.attendees or ""),
		teams = teams,
		calendar = calendar_id,
		calendar_name = calendar_name,
		calendar_href = calendar_href,
		source = calendar_account,
	}
end

-- Expose for reuse/testing
M.validate = validate
M.parse_attendees = parse_attendees

-- Open the block dialog: a container window with one small input window
-- per field, navigated with Tab / Enter.
-- opts: { block = existing_block?, prefill = { date, start_min }?, on_save = fn(fields) }
-- Returns a handle { container, inputs } (used by tests).
function M.open(opts)
	opts = opts or {}
	local dmode = opts.mode or (config.options.dialog and config.options.dialog.mode) or "vsplit"
	if dmode == "vsplit" or dmode == "split" or dmode == "buffer" then
		return require("bloocky.form").open(opts)
	end
	local values = initial_values(opts)
	local items, height = layout()
	local aug = vim.api.nvim_create_augroup("bloocky_dialog", { clear = true })

	-- Where the dialog was opened from, so closing it hands focus back there
	-- instead of leaving it wherever Neovim happens to drop the cursor
	local prev_win = opts.return_win or vim.api.nvim_get_current_win()

	-- Container: labels only, not focusable
	local clines = {}
	for i = 1, height do
		clines[i] = string.rep(" ", WIDTH)
	end
	for _, it in ipairs(items) do
		local l = clines[it.label_row + 1]
		clines[it.label_row + 1] = l:sub(1, it.col) .. it.field .. l:sub(it.col + #it.field + 1)
	end

	local cbuf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, clines)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = cbuf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = cbuf })

	local cwin = vim.api.nvim_open_win(cbuf, false, {
		relative = "editor",
		width = WIDTH,
		height = height,
		row = math.floor((vim.o.lines - height) / 2) - 1,
		col = math.floor((vim.o.columns - WIDTH) / 2),
		style = "minimal",
		border = config.options.window.border,
		title = opts.block and "  Edit block " or "  New block ",
		title_pos = "center",
		footer = " ⏎ save · ⇥/⇧⇥ move · q cancel ",
		footer_pos = "center",
		focusable = false,
		zindex = 60,
	})
	for _, it in ipairs(items) do
		vim.api.nvim_buf_set_extmark(cbuf, ns, it.label_row, it.col, {
			end_col = it.col + #it.field,
			hl_group = "BloockyHeader",
			priority = 100,
		})
	end

	-- One tiny window per field
	local inputs = {}
	for i, it in ipairs(items) do
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { values[it.field] or "" })
		vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
		vim.api.nvim_set_option_value("filetype", "bloocky_dialog", { buf = buf })

		local win = vim.api.nvim_open_win(buf, false, {
			relative = "win",
			win = cwin,
			width = it.width,
			height = 1,
			row = it.input_row,
			col = it.col,
			style = "minimal",
			border = "none",
			zindex = 61,
		})
		vim.api.nvim_set_option_value("winhighlight", "Normal:BloockyInput", { win = win })
		inputs[i] = { field = it.field, buf = buf, win = win }
	end

	local function input_text(i)
		local lines = vim.api.nvim_buf_get_lines(inputs[i].buf, 0, -1, false)
		return vim.trim(table.concat(lines, " "))
	end

	local function refresh_hint(i)
		local it = inputs[i]
		if input_text(i) == "" then
			vim.api.nvim_buf_set_extmark(it.buf, ns, 0, 0, {
				id = MARK_HINT,
				virt_text = { { HINTS[it.field], "BloockyMore" } },
				virt_text_pos = "eol",
			})
		else
			pcall(vim.api.nvim_buf_del_extmark, it.buf, ns, MARK_HINT)
		end
	end

	local function clear_error(i)
		pcall(vim.api.nvim_buf_del_extmark, inputs[i].buf, ns, MARK_ERROR)
	end

	local closing = false
	local function close()
		if closing then
			return
		end
		closing = true
		vim.cmd("stopinsert")
		for _, it in ipairs(inputs) do
			if vim.api.nvim_win_is_valid(it.win) then
				vim.api.nvim_win_close(it.win, true)
			end
		end
		if vim.api.nvim_win_is_valid(cwin) then
			vim.api.nvim_win_close(cwin, true)
		end
		-- Deferred: close() also runs from WinClosed, where switching windows
		-- mid-teardown is unsafe
		vim.schedule(function()
			if vim.api.nvim_win_is_valid(prev_win) then
				pcall(vim.api.nvim_set_current_win, prev_win)
			end
		end)
	end

	local function goto_field(i, enter_insert)
		i = ((i - 1) % #inputs) + 1
		local it = inputs[i]
		if not vim.api.nvim_win_is_valid(it.win) then
			return
		end
		vim.api.nvim_set_current_win(it.win)
		local line = vim.api.nvim_buf_get_lines(it.buf, 0, 1, false)[1] or ""
		vim.api.nvim_win_set_cursor(it.win, { 1, math.max(0, #line) })
		if enter_insert and not vim.api.nvim_get_mode().mode:find("i") then
			vim.cmd("startinsert!")
		end
	end

	local function save()
		local raw = {}
		for i, it in ipairs(inputs) do
			clear_error(i)
			raw[it.field:lower()] = input_text(i)
		end
		local fields, errs = validate(raw)
		if not fields then
			local first = nil
			for i, it in ipairs(inputs) do
				if errs[it.field] then
					first = first or i
					vim.api.nvim_buf_set_extmark(it.buf, ns, 0, 0, {
						id = MARK_ERROR,
						virt_text = { { "✗ " .. errs[it.field] .. " ", "BloockyError" } },
						virt_text_pos = "right_align",
					})
				end
			end
			vim.cmd("stopinsert")
			if first then
				goto_field(first, false)
			end
			return
		end
		close()
		opts.on_save(fields)
	end

	-- Keymaps + autocmds per input
	for i, it in ipairs(inputs) do
		local kopts = { buffer = it.buf, noremap = true, silent = true, nowait = true }
		local map = vim.keymap.set

		map("n", "<CR>", save, kopts)
		map({ "n", "i" }, "<C-s>", save, kopts)
		map("n", "q", close, kopts)
		map("n", "<Esc>", close, kopts)

		-- ⏎ in insert advances through the form and saves from the last field
		map("i", "<CR>", function()
			if i == #inputs then
				save()
			else
				goto_field(i + 1, true)
			end
		end, kopts)

		map({ "n", "i" }, "<Tab>", function()
			goto_field(i + 1, vim.api.nvim_get_mode().mode:find("i") ~= nil)
		end, kopts)
		map({ "n", "i" }, "<S-Tab>", function()
			goto_field(i - 1, vim.api.nvim_get_mode().mode:find("i") ~= nil)
		end, kopts)
		for _, lhs in ipairs({ "j", "<Down>" }) do
			map("n", lhs, function()
				goto_field(i + 1, false)
			end, kopts)
		end
		for _, lhs in ipairs({ "k", "<Up>" }) do
			map("n", lhs, function()
				goto_field(i - 1, false)
			end, kopts)
		end

		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = it.buf,
			group = aug,
			callback = function()
				refresh_hint(i)
				clear_error(i)
			end,
		})
		refresh_hint(i)
	end

	-- Closing any window of the dialog closes all of them
	for _, w in ipairs({ cwin, unpack(vim.tbl_map(function(it)
		return it.win
	end, inputs)) }) do
		vim.api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(w),
			group = aug,
			once = true,
			callback = close,
		})
	end

	-- Start typing the title right away when creating
	goto_field(1, not opts.block)

	return { container = cwin, inputs = inputs }
end

return M
