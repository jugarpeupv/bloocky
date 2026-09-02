local utils = require("bloocky.utils")

local M = {}

local function recurrence_label(block)
	local r = block.recurrence
	if not r or r == vim.NIL then
		return "none"
	end
	if r.type == "custom" and type(r.days) == "table" and #r.days > 0 then
		local rev = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
		local names = {}
		for _, d in ipairs(r.days) do
			table.insert(names, rev[d] or tostring(d))
		end
		local label = r.type .. " (" .. table.concat(names, ",") .. ")"
		if r.until_date and r.until_date ~= "" then
			label = label .. " until " .. r.until_date
		end
		return label
	end
	if r.until_date and r.until_date ~= "" then
		return r.type .. " until " .. r.until_date
	end
	return r.type
end

local function exdates_label(block)
	local r = block.recurrence
	if not r or r == vim.NIL or type(r.exdates) ~= "table" or #r.exdates == 0 then
		return nil
	end
	return table.concat(r.exdates, ", ")
end

function M.render(block)
	local lines = {}
	local function add(line)
		table.insert(lines, line or "")
	end

	add("# " .. (block.title ~= "" and block.title or "(untitled)"))
	add("")

	-- Date + weekday
	local date_str = block.date or ""
	local wday = ""
	local d = utils.str_to_date(date_str)
	if d then
		wday = utils.WDAYS_LONG[utils.wday(d)] or ""
	end
	if block.all_day then
		local days = math.max(1, math.ceil((block.duration_min or 1440) / 1440))
		if days == 1 then
			add("- **Date:** " .. date_str .. (wday ~= "" and " (" .. wday .. ")" or "") .. " — all day")
		else
			add("- **Date:** " .. date_str .. (wday ~= "" and " (" .. wday .. ")" or "") .. " - all day, " .. days .. " days")
		end
	else
		local start_s = utils.format_hhmm(block.start_min or 0)
		local end_min = (block.start_min or 0) + (block.duration_min or 0)
		local end_s = utils.format_hhmm(end_min % 1440)
		-- handle overflow beyond midnight for display
		if end_min >= 1440 then
			end_s = end_s .. " (+1d)"
		end
		add("- **Date:** " .. date_str .. (wday ~= "" and " (" .. wday .. ")" or ""))
		add("- **Time:** " .. start_s .. " - " .. end_s .. " (" .. utils.format_duration(block.duration_min or 0) .. ")")
	end

	add("- **Recurrence:** " .. recurrence_label(block))
	local ex = exdates_label(block)
	if ex then
		add("- **Excluded:** " .. ex)
	end
	local source = block.source or "local"
	add("- **Source:** " .. source)
	if block.id then
		add("- **ID:** `" .. block.id .. "`")
	end
	if block.location and block.location ~= "" then
		add("- **Location:** " .. block.location)
	end
	if block.teams then
		add("- **Teams:** Yes (Microsoft Teams Meeting)")
	end
	if block.organizer and (block.organizer.name or block.organizer.email) then
		local org = block.organizer
		local label = org.name or org.email or ""
		if org.name and org.email and org.name ~= org.email then
			label = org.name .. " <" .. org.email .. ">"
		end
		add("- **Organizer:** " .. label)
	end
	add("")
	add("---")
	add("")

	if block.attendees and type(block.attendees) == "table" and #block.attendees > 0 then
		add("## Attendees (" .. #block.attendees .. ")")
		add("")
		for _, att in ipairs(block.attendees) do
			local name = att.name or att.email or "(unknown)"
			local email = att.email or ""
			local display = name
			if email ~= "" and name ~= email then
				display = name .. " <" .. email .. ">"
			end
			local ps = att.partstat and att.partstat:upper() or ""
			local icon = ""
			if ps == "ACCEPTED" then
				icon = "✓ "
			elseif ps == "DECLINED" then
				icon = "✗ "
			elseif ps == "TENTATIVE" then
				icon = "~ "
			elseif ps == "NEEDS-ACTION" then
				icon = "○ "
			end
			local extra = ""
			if ps ~= "" then
				extra = " — " .. ps:lower()
				if att.role and att.role ~= "" then
					extra = extra .. ", " .. att.role:lower()
				end
			elseif att.role and att.role ~= "" then
				extra = " — " .. att.role:lower()
			end
			add("- " .. icon .. display .. extra)
		end
		add("")
		add("---")
		add("")
	end

	add("## Notes")
	add("")
	local notes = vim.trim(block.notes or "")
	if notes == "" then
		add("_No notes_")
	else
		-- preserve original line breaks in notes; split on \n
		for _, l in ipairs(vim.split(notes, "\n", { plain = true })) do
			add(l)
		end
	end
	add("")
	-- help footer
	add("---")
	add("")
	add("_Press `q` to close | `gx` on a URL to open it_")

	return lines
end

local function create_buf(block)
	local lines = M.render(block)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
	-- name helps :buffer navigation and which-key
	pcall(vim.api.nvim_buf_set_name, buf, "bloocky://" .. (block.id or "untitled") .. ".md")
	-- :e on a scratch buffer would otherwise try to read bloocky://... from disk and wipe it
	vim.api.nvim_create_autocmd("BufReadCmd", {
		buffer = buf,
		callback = function()
			vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
			pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
		end,
	})
	-- buffer-local close mapping
	vim.keymap.set("n", "q", "<cmd>bwipeout<cr>", { buffer = buf, silent = true, nowait = true, desc = "Close bloocky detail" })
	-- store block id for potential future edit integration
	vim.api.nvim_buf_set_var(buf, "bloocky_block_id", block.id)
	vim.b[buf].bloocky_block_id = block.id
	return buf
end

--- Open block details as markdown.
--- @param block table bloocky block
--- @param opts table|nil { split: "current"|"horizontal"|"vertical" }
function M.open(block, opts)
	opts = opts or {}
	local split = opts.split or "current"
	local buf = create_buf(block)

	-- Decide window handling based on calendar state.
	local ui_ok, ui = pcall(require, "bloocky.ui")
	local is_open = ui_ok and ui.is_open and ui.is_open() or false
	local mode = ui_ok and ui.mode or nil

	local function set_buf(win_id, target_buf)
		-- calendar buffer is nomodifiable but marked modified; clear it so
		-- nvim_win_set_buf does not hit E37 (No write since last change)
		local cur = vim.api.nvim_win_get_buf(win_id)
		pcall(vim.api.nvim_set_option_value, "modified", false, { buf = cur })
		vim.api.nvim_win_set_buf(win_id, target_buf)
	end

	if split == "horizontal" then
		if is_open and mode == "float" then
			ui.close()
			vim.cmd("split")
		elseif is_open and mode == "sidebar" then
			-- window 0 is the calendar sidebar; split from it
			vim.cmd("split")
		else
			vim.cmd("split")
		end
		set_buf(vim.api.nvim_get_current_win(), buf)
	elseif split == "vertical" then
		if is_open and mode == "float" then
			ui.close()
			vim.cmd("vsplit")
		elseif is_open and mode == "sidebar" then
			vim.cmd("vsplit")
		else
			vim.cmd("vsplit")
		end
		set_buf(vim.api.nvim_get_current_win(), buf)
	else -- "current"
		if is_open and mode == "sidebar" then
			-- close sidebar (its buffer is wipe) then show detail in the
			-- underlying window; keeps ui state consistent
			ui.close()
			set_buf(vim.api.nvim_get_current_win(), buf)
		elseif is_open and mode == "float" then
			-- close float, then replace buffer in the window below
			ui.close()
			set_buf(vim.api.nvim_get_current_win(), buf)
		elseif is_open and mode == "buffer" then
			-- buffer mode calendar is buflisted (hide); keep it hidden
			set_buf(vim.api.nvim_get_current_win(), buf)
		else
			set_buf(vim.api.nvim_get_current_win(), buf)
		end
	end

	-- put cursor at top
	pcall(vim.api.nvim_win_set_cursor, vim.api.nvim_get_current_win(), { 1, 0 })
	return buf
end

return M
