-- CalDAV: RFC 4791, plus RFC 6578 for incremental sync.
--
-- Everything that builds a request body or reads a response is a pure
-- function, so the protocol can be tested without a server. Only the handful
-- of `request`-shaped functions touch the network.

local account_config = require("bloocky.sync.account")
local async = require("bloocky.sync.async")
local http = require("bloocky.sync.http")
local xml = require("bloocky.sync.xml")

local M = {}

local NS = 'xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/"'

-- Debug log for auth/sync: written only when sync.debug = true, never includes secrets.
local function debug_log(msg)
	local ok, cfg = pcall(require, "bloocky.config")
	local sync = ok and cfg.options.sync or {}
	if not (sync.debug) then
		return
	end
	local ok2, http = pcall(require, "bloocky.sync.http")
	local redacted = ok2 and http.redact(tostring(msg)) or tostring(msg)
	local path = vim.fn.stdpath("state") .. "/bloocky/debug.log"
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local line = os.date("%Y-%m-%dT%H:%M:%S") .. " " .. redacted .. "\n"
	local fd = vim.uv.fs_open(path, "a", tonumber("600", 8))
	if not fd then
		return
	end
	vim.uv.fs_write(fd, line)
	vim.uv.fs_close(fd)
end

--------------------------------------------------------------------------
-- Request bodies
--------------------------------------------------------------------------

function M.propfind_body(props)
	local lines = { '<?xml version="1.0" encoding="utf-8"?>', "<d:propfind " .. NS .. "><d:prop>" }
	for _, prop in ipairs(props) do
		table.insert(lines, "<" .. prop .. "/>")
	end
	table.insert(lines, "</d:prop></d:propfind>")
	return table.concat(lines)
end

local function escape_xml(text)
	return (tostring(text):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- The token is the server's own opaque string coming back around; escaped all
-- the same, so nothing it contains can restructure the request.
function M.sync_collection_body(token)
	return table.concat({
		'<?xml version="1.0" encoding="utf-8"?>',
		"<d:sync-collection " .. NS .. ">",
		"<d:sync-token>" .. escape_xml(token or "") .. "</d:sync-token>",
		"<d:sync-level>1</d:sync-level>",
		"<d:prop><d:getetag/></d:prop>",
		"</d:sync-collection>",
	})
end

function M.multiget_body(hrefs)
	local lines = {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<c:calendar-multiget " .. NS .. ">",
		"<d:prop><d:getetag/><c:calendar-data/></d:prop>",
	}
	for _, href in ipairs(hrefs) do
		table.insert(lines, "<d:href>" .. escape_xml(href) .. "</d:href>")
	end
	table.insert(lines, "</c:calendar-multiget>")
	return table.concat(lines)
end

-- A time-bounded query, used for the first sync so we do not drag down years
-- of history. `start_utc` and `end_utc` are "YYYYMMDDTHHMMSSZ".
function M.calendar_query_body(start_utc, end_utc)
	return table.concat({
		'<?xml version="1.0" encoding="utf-8"?>',
		"<c:calendar-query " .. NS .. ">",
		"<d:prop><d:getetag/><c:calendar-data/></d:prop>",
		'<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">',
		('<c:time-range start="%s" end="%s"/>'):format(start_utc, end_utc),
		"</c:comp-filter></c:comp-filter></c:filter>",
		"</c:calendar-query>",
	})
end

--------------------------------------------------------------------------
-- Response parsing
--------------------------------------------------------------------------

-- One entry per <response>: href, the WebDAV status if given, the ETag, and
-- the calendar payload when it was asked for.
function M.parse_multistatus(body)
	local root = xml.parse(body)
	local out = { responses = {}, sync_token = xml.find_text(root, "sync-token") }

	for _, response in ipairs(xml.find_all(root, "response")) do
		local href = xml.find_text(response, "href")
		if href then
			table.insert(out.responses, {
				href = href,
				status = xml.status_code(response),
				etag = xml.find_text(response, "getetag"),
				data = xml.find_text(response, "calendar-data"),
			})
		end
	end
	return out
end

-- Which of the collections under a calendar-home are usable event calendars.
-- Servers advertise address books and task lists in the same listing, so
-- filtering on resourcetype and component set is not optional.
function M.parse_calendars(body)
	local root = xml.parse(body)
	local out = {}

	for _, response in ipairs(xml.find_all(root, "response")) do
		local href = xml.find_text(response, "href")
		local resourcetype = xml.find(response, "resourcetype")
		local is_calendar = resourcetype and xml.find(resourcetype, "calendar") ~= nil

		if href and is_calendar then
			-- An explicit component set that omits VEVENT means a task or
			-- journal collection. Absent means "everything".
			local supports_events = true
			local comp_set = xml.find(response, "supported-calendar-component-set")
			if comp_set then
				supports_events = false
				for _, comp in ipairs(xml.find_all(comp_set, "comp")) do
					if (comp.attrs.name or ""):upper() == "VEVENT" then
						supports_events = true
					end
				end
			end

			-- Only trust a privilege set that is actually present; its absence
			-- is not evidence of read-only.
			local readonly = false
			local privileges = xml.find(response, "current-user-privilege-set")
			if privileges then
				readonly = xml.find(privileges, "write-content") == nil and xml.find(privileges, "write") == nil
			end

			if supports_events then
				local display = xml.find_text(response, "displayname")
				local desc = xml.find_text(response, "calendar-description")
				-- iCloud sometimes leaves displayname empty or as UUID; prefer description if displayname looks cryptic
				local name = display and display:match("%S") and vim.trim(display) or nil
				if not name or name:match("^[A-Z0-9%-]+$") and #name <= 10 then
					-- fallback to description if it looks more friendly
					if desc and desc:match("%S") then name = vim.trim(desc) end
				end
				name = name or href
				-- debug: show raw mapping when debug enabled
				if require("bloocky.config").options.sync.debug then
					debug_log(("[cal] %s -> displayname=%s desc=%s => name=%s"):format(href, tostring(display), tostring(desc), tostring(name)))
				end
				table.insert(out, {
					href = href,
					name = name,
					ctag = xml.find_text(response, "getctag"),
					readonly = readonly,
				})
			end
		end
	end
	return out
end

--------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------

-- Resolve an href against the account's base URL. Servers reply with paths,
-- not absolute URLs.
--
-- An absolute href is honoured even when it names a different host: iCloud
-- legitimately hands out a calendar-home on a pXX-caldav.icloud.com partition
-- host, so a same-origin rule would break real servers. What makes that
-- acceptable is http.check_url, which every request passes through — a
-- delegated host gets credentials only ever over verified TLS.
function M.resolve(base, href)
	if href:match("^https?://") then
		return href
	end
	local scheme, authority = base:match("^(%a[%w%+%.%-]*)://([^/]+)")
	if not scheme then
		return href
	end
	if href:sub(1, 1) ~= "/" then
		href = "/" .. href
	end
	return scheme .. "://" .. authority .. href
end

-- The seam tests use in place of a live server.
M.transport = nil

local function secret_diag(account)
	return account_config.secret_source(account, "password")
end

local function auth_hint(account)
	local url = tostring(account.url or "")
	if url:find("localhost", 1, true) or url:find("127.0.0.1", 1, true) then
		return "is DavMail running at " .. url .. "? try :BloockySyncAuth " .. account.id .. " to refresh the token; :checkhealth bloocky"
	end
	if url:find("icloud.com", 1, true) or url:find("apple.com", 1, true) then
		return "check app-specific password at appleid.apple.com (2FA required), username must be Apple ID email; if discovery fails set calendar_home per CALENDARS.md#icloud"
	end
	return "check username and " .. secret_diag(account) .. "; :checkhealth bloocky"
end

-- Basic auth for a plain CalDAV server; a bearer token for one behind OAuth
-- (Google's CalDAV bridge). Either way the credential goes into http.lua's
-- 0600 config file, never onto the command line.
local function trim(s)
	return vim.trim(tostring(s or ""))
end

local function authorise(account, opts)
	if account.provider ~= "caldav" or account.bearer_auth then
		local oauth = require("bloocky.sync.oauth")
		local token, err = oauth.access_token(account)
		if not token then
			return err
		end
		opts.bearer = token
		return nil
	end

	local password, err = account_config.secret(account, "password")
	if not password then
		local diag = secret_diag(account)
		local hint = auth_hint(account)
		local raw_user = tostring(account.username or "")
		local user_diag = ("len=%d%s"):format(#raw_user, raw_user ~= trim(raw_user) and " has_ws=true" or "")
		local msg = ("authentication failed for %s: %s | url=%s user_len=%s secret=%s | hint: %s"):format(
			account.id,
			http.redact(tostring(err)),
			http.redact(account.url or "?"),
			user_diag,
			diag,
			hint
		)
		debug_log("[auth] " .. msg .. " raw_user=" .. http.redact(raw_user))
		return msg
	end
	-- Trim whitespace (common when username comes from vim.fn.system without gsub)
	opts.auth = { user = trim(account.username), password = password }
	return nil
end

local function request(account, opts, callback)
	local err = authorise(account, opts)
	if err then
		return callback(err, nil)
	end
	opts.headers = opts.headers or {}
	opts.headers["User-Agent"] = "bloocky.nvim"
	return (M.transport or http.request)(opts, callback)
end

-- Awaitable wrapper: returns (err, res) inside an async.run coroutine.
local function call(account, opts)
	return async.await(function(cb)
		request(account, opts, function(err, res)
			cb(err, res)
		end)
	end)
end

local function dav(account, method, url, body, headers, depth, extra)
	headers = headers or {}
	headers["Content-Type"] = body and 'application/xml; charset="utf-8"' or nil
	if depth then
		headers.Depth = depth
	end
	local opts = { url = url, method = method, body = body, headers = headers, follow = true }
	if extra then
		for k, v in pairs(extra) do
			opts[k] = v
		end
	end
	return call(account, opts)
end

--------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------

-- url -> principal -> calendar-home-set -> the calendars themselves.
-- Each hop is skippable: a user who configured a calendar URL directly should
-- not pay for three extra round trips.
function M.discover(account)
	local base = account.url

	if account.calendar_home then
		return M.list_calendars(account, M.resolve(base, account.calendar_home))
	end

	-- Direct calendar/home URL check (e.g. DavMail /users/<email>/ or /calendar/)
	local direct = M.list_calendars(account, base)
	if direct and #direct > 0 then
		return direct, nil
	end

	local err, res = dav(account, "PROPFIND", base, M.propfind_body({ "d:current-user-principal" }), nil, "0")
	if err then
		debug_log("[discover] " .. account.id .. " PROPFIND " .. tostring(base) .. " err: " .. tostring(err))
		return nil, err
	end
	if res.status == 401 then
		local wa = res.headers and (res.headers["www-authenticate"] or res.headers["WWW-Authenticate"]) or ""
		local body_snip = http.redact((res.body or ""):sub(1, 300):gsub("%s+", " "))
		local diag = secret_diag(account)
		local hint = auth_hint(account)
		local raw_user = tostring(account.username or "")
		local user_diag = ("len=%d%s"):format(#raw_user, raw_user ~= trim(raw_user) and " has_ws=true" or "")
		local msg = ("authentication failed for %s (HTTP 401) at %s | user_len=%s secret=%s | hint: %s"):format(
			account.id,
			http.redact(base),
			user_diag,
			diag,
			hint
		)
		if wa ~= "" then
			msg = msg .. " | www-authenticate: " .. http.redact(wa)
		end
		if body_snip:match("%S") then
			msg = msg .. " | body: " .. body_snip
		end
		debug_log("[discover 401] " .. msg .. " raw_user=" .. http.redact(raw_user))
		return nil, msg
	end
	if res.status == 503 then
		local body_snip = http.redact((res.body or ""):sub(1, 300):gsub("%s+", " "))
		local base_msg = ("server returned 503 for %s (DavMail/MFA session expired - run :BloockySyncAuth %s)"):format(account.id, account.id)
		local msg = base_msg .. " | url=" .. http.redact(base) .. " secret=" .. secret_diag(account)
		if body_snip:match("%S") then
			msg = msg .. " | body: " .. body_snip
		end
		debug_log("[discover 503] " .. msg)
		return nil, msg
	end
	if res.status >= 400 then
		local body_snip = http.redact((res.body or ""):sub(1, 500):gsub("%s+", " "))
		local msg = ("discovery failed at %s (HTTP %d) | user=%s secret=%s"):format(http.redact(base), res.status, http.redact(account.username or "?"), secret_diag(account))
		if body_snip:match("%S") then
			msg = msg .. " | body: " .. body_snip
		end
		debug_log("[discover] " .. msg)
		return nil, msg
	end

	local principal = xml.find_text(xml.find(xml.parse(res.body), "current-user-principal"), "href")
		or xml.find_text(xml.parse(res.body), "href")
	if not principal then
		return nil, "server did not return a current-user-principal"
	end

	local home_err, home_res =
		dav(account, "PROPFIND", M.resolve(base, principal), M.propfind_body({ "c:calendar-home-set" }), nil, "0")
	if home_err then
		return nil, home_err
	end

	local home = xml.find_text(xml.find(xml.parse(home_res.body), "calendar-home-set"), "href")
	if not home then
		return nil, "server did not return a calendar-home-set"
	end

	return M.list_calendars(account, M.resolve(base, home))
end

function M.list_calendars(account, home_url)
	local err, res = dav(
		account,
		"PROPFIND",
		home_url,
		M.propfind_body({
			"d:resourcetype",
			"d:displayname",
			"c:calendar-description",
			"cs:getctag",
			"c:supported-calendar-component-set",
			"d:current-user-privilege-set",
			"cs:source", -- some servers expose friendly source
		}),
		nil,
		"1"
	)
	if err then
		debug_log("[list_calendars] " .. account.id .. " err: " .. tostring(err))
		return nil, err
	end
	if res.status >= 400 then
		local body_snip = http.redact((res.body or ""):sub(1, 500):gsub("%s+", " "))
		local msg = ("could not list calendars for %s at %s (HTTP %d) | user=%s secret=%s"):format(
			account.id,
			http.redact(home_url),
			res.status,
			http.redact(account.username or "?"),
			secret_diag(account)
		)
		if body_snip:match("%S") then
			msg = msg .. " | body: " .. body_snip
		end
		if res.status == 401 then
			msg = msg .. " | hint: " .. auth_hint(account)
		end
		debug_log("[list_calendars " .. res.status .. "] " .. msg)
		return nil, msg
	end
	return M.parse_calendars(res.body), nil
end

--------------------------------------------------------------------------
-- Reading events
--------------------------------------------------------------------------

-- The first sync for a calendar: everything in the window, plus a sync-token
-- to make the next one incremental.
function M.initial_fetch(account, calendar_url, window)
	local err, res = dav(
		account,
		"REPORT",
		calendar_url,
		M.calendar_query_body(window.start, window["end"]),
		nil,
		"1"
	)
	if err then
		-- Transport failure (not an HTTP status): some gateways (DavMail)
		-- abort a body-carrying REPORT mid-stream when a single event
		-- contains bytes their iCal parser rejects. Fall back to an
		-- etag-only enumeration plus isolated multigets so one broken
		-- event cannot take down the whole calendar.
		return M.initial_fetch_enum(account, calendar_url, window)
	end
	if res.status >= 400 then
		return nil, ("calendar-query failed (HTTP %d)"):format(res.status)
	end

	local parsed = M.parse_multistatus(res.body)
	local token = M.fetch_sync_token(account, calendar_url)
	return { changed = parsed.responses, removed = {}, token = token }, nil
end

-- Initial fetch tolerant of broken events: list member hrefs (no bodies,
-- so the server never touches its iCal parser), fetch bodies in isolated
-- chunks, and keep only what overlaps the sync window.
-- Recurrence-uncertain events (lossy: COUNT/RDATE/overrides) and
-- cancellations are always kept — dropping them could hide visible
-- instances or a remote delete.
function M.initial_fetch_enum(account, calendar_url, window)
	local err, res = dav(account, "PROPFIND", calendar_url, M.propfind_body({ "d:resourcetype" }), nil, "1")
	if err then
		return nil, err
	end
	if res.status >= 400 then
		return nil, ("initial PROPFIND failed (HTTP %d)"):format(res.status)
	end

	local self_url = tostring(calendar_url):gsub("/+$", "")
	local hrefs = {}
	for _, response in ipairs(M.parse_multistatus(res.body).responses) do
		local href = response.href
		if href and M.resolve(account.url, href):gsub("/+$", "") ~= self_url then
			table.insert(hrefs, href)
		end
	end

	local changed, skipped = {}, nil
	if #hrefs > 0 then
		local data, fetch_err, skipped_hrefs = M.multiget(account, calendar_url, hrefs)
		if fetch_err then
			return nil, fetch_err
		end
		skipped = skipped_hrefs
		local win_start = window.start:sub(1, 8)
		local win_end = window["end"]:sub(1, 8)
		local mapper = require("bloocky.sync.mapper")
		for _, response in ipairs(data) do
			if response.data then
				local ok, event = pcall(mapper.from_ical, response.data)
				if ok and event == nil then
					-- Parsed fine but no VEVENT (e.g. a task): the REPORT
					-- path never returned these, so skip quietly.
				elseif ok and event and event.block and not M.in_window(event.block, event, win_start, win_end) then
					-- Outside the sync window: skip.
				else
					-- In window, or unparseable here (apply_remote reports it).
					table.insert(changed, response)
				end
			end
		end
	end

	local token = M.fetch_sync_token(account, calendar_url)
	return { changed = changed, removed = {}, token = token, skipped = skipped }, nil
end

-- Client-side replacement for the server's time-range filter, used only by
-- the broken-event fallback. Anything whose placement is uncertain
-- (cancelled carrying a delete signal, lossy recurrence) is kept.
function M.in_window(block, event, win_start, win_end)
	if event.cancelled then
		return true
	end
	if event.lossy then
		return true
	end
	local bdate = (block.date or ""):gsub("-", "")
	if bdate == "" then
		return true
	end
	-- End date from duration: multi-day events can start before the window
	-- and still overlap it.
	local end_date = bdate
	local y, m, d = (block.date or ""):match("^(%d+)-(%d+)-(%d+)$")
	if y and (block.duration_min or 0) > 0 then
		end_date = os.date("%Y%m%d", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) + (block.duration_min or 0) * 60)
	end
	if end_date < win_start then
		local r = block.recurrence
		if r == vim.NIL then
			r = nil
		end
		if not r then
			return false
		end
		if r.until_date and r.until_date ~= "" and r.until_date:gsub("-", "") < win_start then
			return false
		end
		return true
	end
	if bdate > win_end then
		return false
	end
	return true
end

-- A sync-token with no changes attached, so the *next* sync can be
-- incremental even though this one was a full fetch.
function M.fetch_sync_token(account, calendar_url)
	local err, res = dav(account, "PROPFIND", calendar_url, M.propfind_body({ "d:sync-token" }), nil, "0")
	if err or not res or res.status >= 400 then
		return nil
	end
	return xml.find_text(xml.parse(res.body), "sync-token")
end

-- RFC 6578 incremental sync. Returns changed hrefs (with data fetched via
-- multiget) and removed hrefs.
function M.incremental_fetch(account, calendar_url, token)
	local err, res = dav(account, "REPORT", calendar_url, M.sync_collection_body(token), nil, "1")
	if err then
		return nil, err
	end
	-- 400/403/409 here generally means the token expired or the server never
	-- really supported sync-collection. Either way, fall back to a full fetch.
	if res.status == 400 or res.status == 403 or res.status == 409 or res.status >= 500 then
		return nil, "resync"
	end
	if res.status >= 400 then
		return nil, ("sync-collection failed (HTTP %d)"):format(res.status)
	end

	local parsed = M.parse_multistatus(res.body)
	local changed_hrefs, removed = {}, {}
	for _, response in ipairs(parsed.responses) do
		if response.status == 404 or response.status == 410 then
			table.insert(removed, response.href)
		else
			table.insert(changed_hrefs, response.href)
		end
	end

	local changed, skipped = {}, nil
	if #changed_hrefs > 0 then
		local data, fetch_err, skipped_hrefs = M.multiget(account, calendar_url, changed_hrefs)
		if fetch_err then
			return nil, fetch_err
		end
		changed = data
		skipped = skipped_hrefs
	end

	return { changed = changed, removed = removed, token = parsed.sync_token or token, skipped = skipped }, nil
end

-- Fetch bodies for hrefs, isolating broken items. Some gateways (DavMail)
-- abort a whole multiget mid-stream with a malformed chunked body when a
-- single event contains bytes their iCal parser rejects. On a TRANSPORT
-- error (curl-level) the slice is bisected until the failing singleton(s)
-- are isolated; those hrefs are skipped and reported via the third return
-- value. HTTP statuses keep their current meaning: fatal for the whole
-- call. Returns (responses, err, skipped_hrefs).
--
-- Bisection runs without retries (fast isolation: smaller halves usually
-- succeed outright, which also heals transient blips). A failing singleton
-- is confirmed once with normal retries before being declared broken, so a
-- lone transient failure is recovered, not skipped.
function M.multiget(account, calendar_url, hrefs)
	local out, skipped = {}, {}

	local function do_slice(slice, extra)
		local err, res = dav(account, "REPORT", calendar_url, M.multiget_body(slice), nil, "1", extra)
		if err then
			return nil, err, true
		end
		if res.status >= 400 then
			return nil, ("calendar-multiget failed (HTTP %d)"):format(res.status), false
		end
		local responses = {}
		for _, response in ipairs(M.parse_multistatus(res.body).responses) do
			if response.data then
				table.insert(responses, response)
			end
		end
		return responses, nil, false
	end

	local function fetch_slice(slice)
		local responses, err, transport = do_slice(slice, { retries = 0 })
		if not err then
			return responses, nil
		end
		if not transport then
			return nil, err
		end
		if #slice <= 1 then
			local cresponses, cerr, ctransport = do_slice(slice, nil)
			if not cerr then
				return cresponses, nil
			end
			if not ctransport then
				return nil, cerr
			end
			table.insert(skipped, slice[1])
			return {}, nil
		end
		local mid = math.floor(#slice / 2)
		local left, left_err = fetch_slice(vim.list_slice(slice, 1, mid))
		if left_err then
			return nil, left_err
		end
		local right, right_err = fetch_slice(vim.list_slice(slice, mid + 1, #slice))
		if right_err then
			return nil, right_err
		end
		for _, response in ipairs(right) do
			table.insert(left, response)
		end
		return left, nil
	end

	-- Chunked: a multiget naming several thousand hrefs is a request body some
	-- servers simply refuse.
	local CHUNK = 75
	for start = 1, #hrefs, CHUNK do
		local slice = vim.list_slice(hrefs, start, math.min(start + CHUNK - 1, #hrefs))
		local responses, err = fetch_slice(slice)
		if err then
			return nil, err
		end
		for _, response in ipairs(responses) do
			table.insert(out, response)
		end
	end
	return out, nil, (#skipped > 0 and skipped or nil)
end

--------------------------------------------------------------------------
-- Writing events
--------------------------------------------------------------------------

-- Create or replace a calendar object.
--
-- `etag` is the version we believe is on the server. Sending it as If-Match
-- is what turns a blind overwrite into a detectable conflict: a 412 means
-- somebody changed the event since we last looked.
function M.put(account, url, body, etag)
	local headers = { ["Content-Type"] = "text/calendar; charset=utf-8" }
	if etag then
		headers["If-Match"] = etag
	else
		headers["If-None-Match"] = "*" -- create only; never clobber a stranger
	end

	local err, res = call(account, { url = url, method = "PUT", body = body, headers = headers })
	if err then
		return nil, err
	end
	if res.status == 412 then
		return { conflict = true, status = res.status }, nil
	end
	if res.status >= 400 then
		return nil, ("PUT failed (HTTP %d)"):format(res.status)
	end
	-- Servers may omit the new ETag, in which case the caller re-reads it.
	return { etag = res.headers.etag, status = res.status }, nil
end

function M.delete(account, url, etag)
	local headers = {}
	if etag then
		headers["If-Match"] = etag
	end
	local err, res = call(account, { url = url, method = "DELETE", headers = headers })
	if err then
		return nil, err
	end
	if res.status == 412 then
		return { conflict = true, status = res.status }, nil
	end
	-- Already gone is a success: the desired state is "not there".
	if res.status == 404 or res.status == 410 then
		return { status = res.status, missing = true }, nil
	end
	if res.status >= 400 then
		return nil, ("DELETE failed (HTTP %d)"):format(res.status)
	end
	return { status = res.status }, nil
end

--------------------------------------------------------------------------
-- The interface the orchestrator actually uses
--------------------------------------------------------------------------
--
-- Everything above is CalDAV plumbing. These four wrap it in terms the sync
-- engine can express for any provider: a block goes up, a change comes down.
-- Building the payload belongs to the provider, because only it knows whether
-- that means iCalendar text or JSON.

function M.create_event(account, calendar, block)
	local mapper = require("bloocky.sync.mapper")
	local body, build_err = mapper.to_ical(block)
	if not body then
		return nil, build_err
	end

	local href = calendar.href:gsub("/$", "") .. "/" .. mapper.href_for(block)
	local url = M.resolve(account.url, href)
	local result, err = M.put(account, url, body, nil)
	if not result then
		return nil, err
	end
	if result.conflict then
		return { conflict = true }, nil
	end

	local etag = result.etag
	if not etag then
		-- Some servers omit the ETag on PUT; read it back so the next update
		-- can send If-Match and get conflict detection.
		local fetched = M.get(account, url)
		etag = fetched and fetched.etag
	end
	return { href = href, uid = mapper.uid_for(block), etag = etag, raw = body }, nil
end

function M.update_event(account, mapping, block)
	local ical = require("bloocky.sync.ical")
	local mapper = require("bloocky.sync.mapper")
	if not mapping.raw then
		return nil, "no cached payload; it will re-sync on the next run"
	end

	-- Patch the server's own bytes rather than rebuilding: see the note at the
	-- top of ical.lua.
	local body = ical.patch(mapping.raw, mapper.patch_changes(block, {
		lossy = mapping.lossy,
		all_day = mapping.all_day,
		tzid = mapping.tz,
	}))
	local result, err = M.put(account, M.resolve(account.url, mapping.href), body, mapping.etag)
	if not result then
		return nil, err
	end
	if result.conflict then
		return { conflict = true }, nil
	end
	return { etag = result.etag, raw = body }, nil
end

function M.delete_event(account, tombstone)
	return M.delete(account, M.resolve(account.url, tombstone.href or ""), tombstone.etag)
end

-- Incremental when we have a cursor, falling back to a full fetch when the
-- server says the token is no longer usable.
function M.fetch(account, calendar, cursor, window)
	local url = M.resolve(account.url, calendar.href)
	local result, err
	if cursor then
		result, err = M.incremental_fetch(account, url, cursor)
		if err == "resync" then
			result, err = nil, nil
		end
	end
	if not result and not err then
		result, err = M.initial_fetch(account, url, window)
	end
	-- `cursor` is the name the orchestrator persists; CalDAV happens to call
	-- its own a sync-token.
	if result then
		result.cursor = result.token
	end
	return result, err
end

-- Read one object back, for when a PUT did not return an ETag.
function M.get(account, url)
	local err, res = call(account, { url = url, method = "GET" })
	if err then
		return nil, err
	end
	if res.status >= 400 then
		return nil, ("GET failed (HTTP %d)"):format(res.status)
	end
	return { etag = res.headers.etag, data = res.body }, nil
end

return M
