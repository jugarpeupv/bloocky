local config = require("bloocky.config")
local dialog = require("bloocky.dialog")
local utils = require("bloocky.utils")

local M = {}

--- Render lines for structured markdown buffer
function M.render(opts)
	local block = opts.block
	local prefill = opts.prefill or {}
	local title = block and block.title or ""
	local date_str = block and block.date or (prefill.date or utils.date_to_str(utils.today()))
	local start_str = block and utils.format_hhmm(block.start_min) or utils.format_hhmm(prefill.start_min or 9 * 60)
	local duration_str = block and utils.format_duration(block.duration_min) or "1h"
	local r = block and block.recurrence
	local rtype = r and r.type or "none"
	local day_names = {}
	if r and type(r.days) == "table" then
		local rev = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
		for _, d in ipairs(r.days) do
			table.insert(day_names, rev[d])
		end
	end
	local days_str = table.concat(day_names, ",")
	local until_str = (r and r.until_date) or ""
	local attendees_str = ""
	if block and block.attendees then
		local parts = {}
		for _, a in ipairs(block.attendees) do
			if a.name and a.email and a.name ~= a.email then
				table.insert(parts, a.name .. " <" .. a.email .. ">")
			elseif a.email and a.email ~= "" then
				table.insert(parts, a.email)
			elseif a.name then
				table.insert(parts, a.name)
			end
		end
		attendees_str = table.concat(parts, ", ")
	end
	local notes_str = block and (block.notes or "") or ""
	-- Calendar field for creation: show current calendar or filter
	local calendar_str = ""
	do
		if block then
			local ok, lab = pcall(function() return require("bloocky.marks").calendar_label(block) end)
			calendar_str = (ok and lab) and lab or (block.calendar or block.source or "")
		else
				local ok, ui = pcall(require, "bloocky.ui")
			if ok and ui.calendar_filter then
				calendar_str = ui.calendar_filter
			else
				local ok2, def = pcall(function() return require("bloocky.ui").default_calendar() end)
				if ok2 and def then
					calendar_str = def
				else
					local sync = config.options.sync or {}
					if sync.accounts and sync.accounts[1] then calendar_str = sync.accounts[1].id end
				end
			end
		end
	end

	local lines = {}
	table.insert(lines, "# " .. (title ~= "" and title or "New Event"))
	table.insert(lines, "")
	table.insert(lines, "- **Date:** " .. date_str)
	table.insert(lines, "- **Start:** " .. start_str)
	table.insert(lines, "- **Duration:** " .. duration_str)
	table.insert(lines, "- **Repeat:** " .. rtype)
	table.insert(lines, "- **Days:** " .. days_str)
	table.insert(lines, "- **Until:** " .. until_str)
	table.insert(lines, "- **Teams:** " .. (block and block.teams and "yes" or "no"))
	table.insert(lines, "- **Calendar:** " .. calendar_str)
	table.insert(lines, "- **Attendees:** " .. attendees_str)
	table.insert(lines, "")
	table.insert(lines, "## Notes")
	table.insert(lines, "")
	if notes_str ~= "" then
		for _, l in ipairs(vim.split(notes_str, "\n", { plain = true })) do
			table.insert(lines, l)
		end
	end
	table.insert(lines, "")
	table.insert(lines, "---")
	table.insert(lines, "_`:w` or `<C-s>` save | `<CR>` on Calendar to pick | `q` cancel_")

	return lines
end

--- Parse lines back into block fields, or nil + errors table
function M.parse(lines)
	local raw = {
		title = "",
		date = "",
		start = "",
		duration = "",
		["repeat"] = "none",
		days = "",
		["until"] = "",
		attendees = "",
		calendar = "",
		notes = "",
	}
	local in_notes = false
	local note_lines = {}

	for _, line in ipairs(lines) do
		local trimmed = vim.trim(line)
		if trimmed == "---" or trimmed:match("^_.*to save.*_$") or trimmed:match("^_.*cancel.*_$") then
			in_notes = false
		elseif trimmed:match("^##%s*Notes") then
			in_notes = true
		elseif in_notes then
			table.insert(note_lines, line)
		elseif trimmed:match("^#%s*(.*)$") then
			local t = trimmed:match("^#%s*(.*)$")
			if t ~= "New Event" or raw.title == "" then
				raw.title = t
			end
		else
			local key, val = line:match("^%s*[-*]%s*%*%*([^:*]+):%*%*%s*(.*)$")
			if not key then
				key, val = line:match("^%s*[-*]%s*%*%*([^:*]+)%*%*:%s*(.*)$")
			end
			if not key then
				key, val = line:match("^%s*[-*]%s*([^:]+):%s*(.*)$")
			end
			if not key then
				key, val = line:match("^%s*([^:]+):%s*(.*)$")
			end
			if key and val then
				local k = vim.trim(key):lower()
				local v = vim.trim(val)
				if k == "date" then
					if v ~= "" or raw.date == "" then raw.date = v end
				elseif k == "start" or k == "time" then
					local s = v:match("^(%d+:%d+)") or v
					if s ~= "" or raw.start == "" then raw.start = s end
				elseif k == "duration" then
					if v ~= "" or raw.duration == "" then raw.duration = v end
				elseif k == "repeat" or k == "recurrence" then
					if v ~= "" or raw["repeat"] == "" then raw["repeat"] = v end
				elseif k == "days" then
					if v ~= "" or raw.days == "" then raw.days = v end
				elseif k == "until" then
					if v ~= "" or raw["until"] == "" then raw["until"] = v end
				elseif k == "teams" or k == "online" then
					if v ~= "" or raw.teams == nil then raw.teams = v end
				elseif k == "calendar" then
					if v ~= "" or raw.calendar == "" then raw.calendar = v end
				elseif k == "attendees" or k == "attendee" or k == "attendants" then
					if v ~= "" or raw.attendees == "" then raw.attendees = v end
				end
			end
		end
	end

	-- Trim trailing blank lines from notes
	while #note_lines > 0 and vim.trim(note_lines[#note_lines]) == "" do
		table.remove(note_lines)
	end
	raw.notes = table.concat(note_lines, "\n")

	return dialog.validate(raw)
end

--- Open structured buffer in a split
--- opts: { block = existing_block?, prefill = { date, start_min }?, on_save = fn(fields), return_win = win_id? }
function M.open(opts)
	opts = opts or {}
	local prev_win = opts.return_win or vim.api.nvim_get_current_win()
	local lines = M.render(opts)

	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

	local buf_name = "bloocky://event-" .. (opts.block and opts.block.id or "new") .. ".md"
	pcall(vim.api.nvim_buf_set_name, buf, buf_name)

	-- Open split
	local split_cmd = (config.options.dialog and config.options.dialog.mode == "split") and "split" or "vsplit"
	vim.cmd(split_cmd)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)

	local function save()
		local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local fields, errs = M.parse(cur_lines)
		if not fields then
			local msg = {}
			for k, v in pairs(errs) do
				table.insert(msg, k .. ": " .. v)
			end
			vim.notify("Bloocky error: " .. table.concat(msg, ", "), vim.log.levels.ERROR)
			return false
		end
		pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
		-- Close split first so the calendar window expands back to full width before re-rendering
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if vim.api.nvim_win_is_valid(prev_win) then
			pcall(vim.api.nvim_set_current_win, prev_win)
		end
		if opts.on_save then
			opts.on_save(fields)
		end
		vim.notify("Bloocky: saved block", vim.log.levels.INFO)
		return true
	end

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if vim.api.nvim_win_is_valid(prev_win) then
			pcall(vim.api.nvim_set_current_win, prev_win)
		end
	end

	-- Autocmd for :w / :write
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			save()
		end,
	})

	-- Buffer keymaps
	local kopts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		save()
	end, kopts)
	vim.keymap.set("n", "q", function()
		close()
	end, kopts)

	-- Pick calendar on <CR> when on Calendar line
	local function pick_calendar_for_form()
		local ok_ui, ui = pcall(require, "bloocky.ui")
		if not (ok_ui and ui._pick_calendar_for_form) then
			vim.notify("Bloocky: calendar picker not available", vim.log.levels.WARN)
			return
		end
		ui._pick_calendar_for_form(buf, win, function(choice_id)
			local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			for idx, l in ipairs(cur) do
				if l:lower():find("calendar") and l:find(":") then
					local new_line = "- **Calendar:** " .. choice_id
					pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
					vim.api.nvim_buf_set_lines(buf, idx - 1, idx, false, { new_line })
					pcall(vim.api.nvim_set_option_value, "modified", true, { buf = buf })
					pcall(vim.api.nvim_win_set_cursor, win, { idx, 0 })
					break
				end
			end
		end)
	end

	vim.keymap.set("n", "<CR>", function()
		local cur_line = 1
		if vim.api.nvim_win_is_valid(win) then
			local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
			if ok then cur_line = pos[1] end
		end
		local line = vim.api.nvim_buf_get_lines(buf, cur_line - 1, cur_line, false)[1] or ""
		if line:lower():find("calendar") then
			pick_calendar_for_form()
		else
			-- allow normal <CR> to not be swallowed: move down or insert?
			-- in normal mode, <CR> is not needed; just stay
		end
	end, kopts)

	-- Position cursor on title or first field
	pcall(vim.api.nvim_win_set_cursor, win, { 1, 2 })

	return { buf = buf, win = win }
end

return M
