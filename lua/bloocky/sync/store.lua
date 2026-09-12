-- The sync sidecar: everything the sync engine needs to remember, kept out of
-- the blocks file.
--
-- bloocky_blocks.json is a contract other readers rely on (see
-- docs/block-structure.md), so ETags, raw iCalendar payloads and cursors do
-- not belong in it. They live here, keyed by block id.

local config = require("bloocky.config")
local hash = require("bloocky.sync.hash")

local M = {}

-- Bump only for a breaking layout change. A file written by a *newer* bloocky
-- is read as best we can but never written back, so an older version can't
-- silently destroy state it doesn't understand.
local VERSION = 1

local data = nil
local read_only = false

local function empty()
	return {
		version = VERSION,
		accounts = {}, -- account id -> { cursor, last_sync }
		mappings = {}, -- block id   -> { account, calendar, uid, href, etag, base_hash, ... }
		tombstones = {}, -- synced blocks deleted locally, awaiting a remote DELETE
		conflicts = {}, -- the losing local versions, so remote-wins is recoverable
	}
end

function M.path()
	local sync = config.options.sync or {}
	if sync.store_path then
		return sync.store_path
	end
	return vim.fn.fnamemodify(config.options.save_path, ":h") .. "/bloocky_sync.json"
end

function M.load()
	data = empty()
	read_only = false

	local file = io.open(M.path(), "r")
	if not file then
		return data
	end
	local content = file:read("*a")
	file:close()
	if not content or content == "" then
		return data
	end

	local ok, decoded = pcall(vim.json.decode, content)
	if not ok or type(decoded) ~= "table" then
		vim.notify("Bloocky: could not parse " .. M.path() .. ", starting sync state fresh", vim.log.levels.WARN)
		return data
	end

	local version = tonumber(decoded.version) or VERSION
	if version > VERSION then
		read_only = true
		vim.notify(
			("Bloocky: %s was written by a newer version (%d > %d). Sync state is read-only until you upgrade."):format(
				M.path(),
				version,
				VERSION
			),
			vim.log.levels.ERROR
		)
	end

	-- A missing or wrong-typed section is replaced, never trusted.
	for _, key in ipairs({ "accounts", "mappings", "tombstones", "conflicts" }) do
		if type(decoded[key]) == "table" then
			data[key] = decoded[key]
		end
	end
	data.version = version
	return data
end

function M.ensure_loaded()
	if not data then
		M.load()
	end
	return data
end

-- Write via a temp file and rename. rename(2) is atomic within a filesystem,
-- so a crash mid-write leaves the previous state intact rather than a
-- truncated file that would look like "nothing was ever synced".
function M.save()
	if not data or read_only then
		return false
	end
	local path = M.path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

	local tmp = path .. ".tmp"
	-- Created 0600 like tokens.json: the mappings cache raw event payloads —
	-- descriptions, attendees, whole invitations — which are effectively a
	-- plaintext copy of the calendar and nobody else's business.
	local fd = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
	if not fd then
		vim.notify("Bloocky: could not write " .. tmp, vim.log.levels.ERROR)
		return false
	end
	vim.uv.fs_write(fd, vim.json.encode(data))
	vim.uv.fs_close(fd)

	local ok, err = vim.uv.fs_rename(tmp, path)
	if not ok then
		os.remove(tmp)
		vim.notify("Bloocky: could not replace " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

--------------------------------------------------------------------------
-- Mappings — the link between a local block and its remote event
--------------------------------------------------------------------------

function M.get_mapping(block_id)
	return M.ensure_loaded().mappings[block_id]
end

-- Record a successful round-trip. `base_hash` is stamped from the block as it
-- now stands, which is what makes the next "did it change?" check meaningful.
function M.mark_synced(block, fields)
	M.ensure_loaded()
	local mapping = data.mappings[block.id] or {}
	for key, value in pairs(fields or {}) do
		mapping[key] = value
	end
	mapping.base_hash = hash.block(block)
	mapping.synced_at = os.time()
	data.mappings[block.id] = mapping
	M.save()
	return mapping
end

function M.remove_mapping(block_id)
	M.ensure_loaded()
	data.mappings[block_id] = nil
	M.save()
end

--------------------------------------------------------------------------
-- Tombstones — deleted here, not yet deleted there
--------------------------------------------------------------------------

-- Without this, a local delete is indistinguishable from "never synced", and
-- the next pull would helpfully re-create the event you just got rid of.
function M.record_deletion(block)
	M.ensure_loaded()
	local mapping = data.mappings[block.id]
	if not mapping then
		return nil -- never synced: there is nothing upstream to delete
	end
	local tombstone = {
		id = block.id,
		account = mapping.account,
		calendar = mapping.calendar,
		uid = mapping.uid,
		href = mapping.href,
		etag = mapping.etag,
		title = block.title, -- kept for the report; the block itself is gone by then
		deleted_at = os.time(),
		teams = block.teams or mapping.teams,
		graph_id = mapping.graph_id,
	}
	table.insert(data.tombstones, tombstone)
	data.mappings[block.id] = nil
	M.save()
	return tombstone
end

function M.tombstones(account_id)
	M.ensure_loaded()
	if not account_id then
		return data.tombstones
	end
	return vim.tbl_filter(function(t)
		return t.account == account_id
	end, data.tombstones)
end

function M.clear_tombstone(block_id)
	M.ensure_loaded()
	for i, tombstone in ipairs(data.tombstones) do
		if tombstone.id == block_id then
			table.remove(data.tombstones, i)
			M.save()
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------
-- What the push phase has to do
--------------------------------------------------------------------------

-- Blocks with no mapping need creating; mapped blocks whose content no longer
-- matches the last synced hash need updating.
--
-- `blocked` is the third case: an edit to a block on a read-only calendar. It
-- cannot be pushed, and it must not simply be ignored either — the pull is
-- incremental, so if the server never changes, nothing would ever come down to
-- correct the block and it would display an edit the calendar has never had.
-- The caller hands these back to the user.
function M.local_changes(blocks)
	M.ensure_loaded()
	local created, updated, blocked = {}, {}, {}
	for _, block in ipairs(blocks) do
		local mapping = data.mappings[block.id]
		if not mapping then
			table.insert(created, block)
		elseif mapping.base_hash ~= hash.block(block) then
			if mapping.readonly then
				table.insert(blocked, block)
			else
				table.insert(updated, block)
			end
		end
	end
	return { created = created, updated = updated, blocked = blocked }
end

--------------------------------------------------------------------------
-- Cursors and the conflict trail
--------------------------------------------------------------------------

function M.account(account_id)
	M.ensure_loaded()
	data.accounts[account_id] = data.accounts[account_id] or {}
	return data.accounts[account_id]
end

function M.set_cursor(account_id, cursor)
	local account = M.account(account_id)
	account.cursor = cursor
	account.last_sync = os.time()
	M.save()
end

-- Sync tokens are per collection, not per account: two calendars on one
-- server advance independently.
function M.calendar_cursor(account_id, href)
	local account = M.account(account_id)
	account.cursors = account.cursors or {}
	return account.cursors[href]
end

function M.set_calendar_cursor(account_id, href, token)
	local account = M.account(account_id)
	account.cursors = account.cursors or {}
	account.cursors[href] = token
	account.last_sync = os.time()
	M.save()
end

-- Collection tags: the server's own "anything in here changed?" stamp
-- (cs:getctag). Stored per calendar next to the sync token; a match lets a
-- pull short-circuit without fetching when the collection is untouched.
function M.calendar_ctag(account_id, href)
	local account = M.account(account_id)
	account.ctags = account.ctags or {}
	return account.ctags[href]
end

function M.set_calendar_ctag(account_id, href, ctag)
	local account = M.account(account_id)
	account.ctags = account.ctags or {}
	account.ctags[href] = ctag
	account.last_sync = os.time()
	M.save()
end

-- Reverse lookup: remote identity -> block id. Built on demand rather than
-- maintained, so it cannot drift out of step with the mappings.
function M.index_by(field)
	M.ensure_loaded()
	local out = {}
	for block_id, mapping in pairs(data.mappings) do
		if mapping[field] then
			out[mapping[field]] = block_id
		end
	end
	return out
end

-- Remote-wins overwrites local work, so the losing version is kept and can be
-- restored as a new block. Oldest entries fall off the front.
function M.record_conflict(entry)
	M.ensure_loaded()
	entry.at = entry.at or os.time()
	table.insert(data.conflicts, entry)

	local sync = config.options.sync or {}
	local limit = (sync.conflict or {}).trail_limit or 50
	while #data.conflicts > limit do
		table.remove(data.conflicts, 1)
	end
	M.save()
	return entry
end

function M.conflicts()
	return M.ensure_loaded().conflicts
end

-- Blocks the calendar overwrote and you have not looked at yet. Reading the
-- report is what counts as looking, so the mark clears itself.
function M.conflicted_ids()
	M.ensure_loaded()
	local out = {}
	for _, entry in ipairs(data.conflicts) do
		if not entry.acknowledged and entry.block_id then
			out[entry.block_id] = true
		end
	end
	return out
end

function M.unacknowledged_count()
	M.ensure_loaded()
	local count = 0
	for _, entry in ipairs(data.conflicts) do
		if not entry.acknowledged then
			count = count + 1
		end
	end
	return count
end

function M.acknowledge_conflicts()
	M.ensure_loaded()
	local changed = false
	for _, entry in ipairs(data.conflicts) do
		if not entry.acknowledged then
			entry.acknowledged = true
			changed = true
		end
	end
	if changed then
		M.save()
	end
	return changed
end

-- Which calendar each synced block belongs to (href-based, stable for coloring).
function M.calendar_ids()
	M.ensure_loaded()
	local out = {}
	for block_id, mapping in pairs(data.mappings) do
		if mapping.calendar then
			out[block_id] = mapping.account .. "/" .. mapping.calendar
		end
	end
	return out
end

-- Human label for each block: "account/Calendar Name" or "account"
function M.calendar_labels()
	M.ensure_loaded()
	local out = {}
	for block_id, mapping in pairs(data.mappings) do
		if mapping.account then
			if mapping.calendar_name and mapping.calendar_name ~= "" then
				out[block_id] = mapping.account .. "/" .. mapping.calendar_name
			elseif mapping.calendar then
				-- fallback: last path segment
				local name = mapping.calendar:match("([^/]+)/?$") or mapping.calendar
				out[block_id] = mapping.account .. "/" .. name
			else
				out[block_id] = mapping.account
			end
		end
	end
	return out
end

-- Backfill friendly display names onto existing mappings after discovery.
-- Mappings created before calendar_name existed (or before the server
-- returned a displayname) keep calendar_name=nil and fall back to the raw
-- href segment (UUID). Refreshing here means one sync heals all pickers,
-- badges and detail views without waiting for every event to change.
local function norm_href(href)
	if not href then return nil end
	local path = tostring(href):gsub("^%a[%w%+%.%-]*://[^/]+", "")
	path = path:gsub("/+$", "")
	if path == "" then return nil end
	return path
end

function M.refresh_calendar_names(account_id, calendars)
	M.ensure_loaded()
	if not account_id or not calendars then return 0 end
	local by_href = {}
	for _, cal in ipairs(calendars) do
		local n = norm_href(cal.href)
		if n and cal.name and cal.name ~= "" then
			by_href[n] = cal.name
		end
	end
	if not next(by_href) then return 0 end
	local updated = 0
	for _, mapping in pairs(data.mappings) do
		if mapping.account == account_id and mapping.calendar then
			local n = norm_href(mapping.calendar)
			local friendly = n and by_href[n]
			if friendly and mapping.calendar_name ~= friendly then
				mapping.calendar_name = friendly
				updated = updated + 1
			end
		end
	end
	if updated > 0 then M.save() end
	return updated
end

-- Unique calendar identifiers present in store (account/href), for picker.
function M.known_calendars()
	M.ensure_loaded()
	local seen, out = {}, {}
	for _, mapping in pairs(data.mappings) do
		if mapping.account and mapping.calendar then
			local key = mapping.account .. "\0" .. mapping.calendar
			if not seen[key] then
				seen[key] = true
				table.insert(out, {
					account = mapping.account,
					href = mapping.calendar,
					name = mapping.calendar_name or mapping.calendar:match("([^/]+)/?$") or mapping.calendar,
					id = mapping.account .. "/" .. (mapping.calendar_name or mapping.calendar:match("([^/]+)/?$") or mapping.calendar),
				})
			end
		end
	end
	-- include configured calendars that have no blocks yet (so filter is discoverable)
	local cfg_ok, cfg = pcall(require, "bloocky.config")
	if cfg_ok then
		for _, acc in ipairs((cfg.options.sync or {}).accounts or {}) do
			for _, cal in ipairs(acc.calendars or {}) do
				local name = cal.name or cal.href
				if name then
					local key = acc.id .. "\0" .. (cal.href or name)
					if not seen[key] then
						seen[key] = true
						table.insert(out, { account = acc.id, href = cal.href or name, name = name, id = acc.id .. "/" .. name })
					end
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

-- Blocks living on a calendar we cannot write to.
function M.readonly_ids()
	M.ensure_loaded()
	local out = {}
	for block_id, mapping in pairs(data.mappings) do
		if mapping.readonly then
			out[block_id] = true
		end
	end
	return out
end

-- Drop state belonging to accounts that no longer exist in the config.
-- Tombstones are only ever drained by a sync of their own account, so without
-- this a deletion queued for a since-removed account would sit in the file
-- forever; orphaned mappings have the same shape of problem.
function M.prune_accounts(valid_ids)
	M.ensure_loaded()
	local changed = false
	for block_id, mapping in pairs(data.mappings) do
		if mapping.account and not valid_ids[mapping.account] then
			data.mappings[block_id] = nil
			changed = true
		end
	end
	local kept = {}
	for _, tombstone in ipairs(data.tombstones) do
		if not tombstone.account or valid_ids[tombstone.account] then
			table.insert(kept, tombstone)
		else
			changed = true
		end
	end
	if changed then
		data.tombstones = kept
		M.save()
	end
	return changed
end

-- Forget where we got to, forcing the next sync to be a full one. Mappings for
-- the account go too, so nothing points at stale ETags.
function M.reset(account_id)
	M.ensure_loaded()
	if not account_id then
		data = empty()
		M.save()
		return
	end
	data.accounts[account_id] = nil
	for block_id, mapping in pairs(data.mappings) do
		if mapping.account == account_id then
			data.mappings[block_id] = nil
		end
	end
	data.tombstones = vim.tbl_filter(function(t)
		return t.account ~= account_id
	end, data.tombstones)
	M.save()
end

return M
