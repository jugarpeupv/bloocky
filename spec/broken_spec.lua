-- Brokened events: a gateway that aborts a body-carrying REPORT mid-stream
-- (DavMail + an iCal line its parser rejects, surfacing as curl 56) must not
-- take down the whole calendar. Multiget bisects transport failures to
-- isolate the brokened href; initial fetch falls back to etag-only
-- enumeration plus a client-side window filter.
local caldav = require("bloocky.sync.providers.caldav")
local config = require("bloocky.config")
local async = require("bloocky.sync.async")

config.options.sync = config.options.sync or {}
config.options.sync.timeout_s = 15

local CAL = "https://dav.example.com/dav/home/work/"
local ACCOUNT = { id = "work", provider = "caldav", url = "https://dav.example.com/dav/", username = "me@example.com", password = "secret" }
local WINDOW = { start = "20250801T000000Z", ["end"] = "20270301T000000Z" }

local function ms(inner)
	return '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
		.. inner
		.. "</d:multistatus>"
end

local function ics(uid, summary, dtstart)
	return table.concat({
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"BEGIN:VEVENT",
		"UID:" .. uid,
		"DTSTAMP:20260801T090000Z",
		"DTSTART:" .. (dtstart or "20260901T100000Z"),
		"DTEND:" .. "20260901T110000Z",
		"SUMMARY:" .. summary,
		"END:VEVENT",
		"END:VCALENDAR",
	}, "\r\n")
end

-- Mock transport: calendar-query REPORT always dies mid-stream (the DavMail
-- broken case); multiget dies iff the slice names broken.ics; PROPFINDs are
-- etag-only and always healthy.
local RESOURCES = {
	["/dav/home/work/a.ics"] = ics("a", "Alpha"),
	["/dav/home/work/broken.ics"] = ics("broken", "Broken"),
	["/dav/home/work/b.ics"] = ics("b", "Beta"),
}

local function broken_transport(fail_query)
	return function(opts, callback)
		local body = opts.body or ""
		if (opts.method or "GET") == "PROPFIND" then
			if body:find("sync%-token") then
				callback(nil, { status = 207, headers = {}, body = ms("<d:sync-token>7</d:sync-token>") })
				return
			end
			local parts = {}
			for href in pairs(RESOURCES) do
				parts[#parts + 1] = "<d:response><d:href>" .. href .. "</d:href></d:response>"
			end
			parts[#parts + 1] = "<d:response><d:href>/dav/home/work/</d:href></d:response>"
			callback(nil, { status = 207, headers = {}, body = ms(table.concat(parts)) })
			return
		end
		if body:find("calendar%-query") then
			if fail_query then
				callback("curl: (56) chunk hex-length char not a hex digit: 0x48", nil)
			else
				callback(nil, { status = 207, headers = {}, body = ms("") })
			end
			return
		end
		if body:find("multiget") then
			if body:find("broken%.ics") then
				callback("curl: (56) chunk hex-length char not a hex digit: 0x48", nil)
				return
			end
			local parts = {}
			for href in body:gmatch("<d:href>([^<]+)</d:href>") do
				if RESOURCES[href] then
					parts[#parts + 1] = "<d:response><d:href>"
						.. href
						.. "</d:href><d:propstat><d:prop><d:getetag>\"1\"</d:getetag><c:calendar-data>"
						.. RESOURCES[href]:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
						.. "</c:calendar-data></d:prop></d:propstat></d:response>"
				end
			end
			callback(nil, { status = 207, headers = {}, body = ms(table.concat(parts)) })
			return
		end
		callback(nil, { status = 207, headers = {}, body = ms("") })
	end
end

local function run_async(fn)
	local done = false
	local result = nil
	async.run(function()
		result = { fn() }
		done = true
	end)
	vim.wait(2000, function()
		return done
	end)
	assert(done, "async body never finished")
	return result
end

describe("brokened events", function()
	describe("multiget", function()
		it("isolates a brokened href and returns the rest", function()
			caldav.transport = broken_transport(true)
			local r = run_async(function()
				return caldav.multiget(ACCOUNT, CAL, { "/dav/home/work/a.ics", "/dav/home/work/broken.ics", "/dav/home/work/b.ics" })
			end)
			local out, err, skipped = r[1], r[2], r[3]
			eq(err, nil, "broken must not be fatal")
			eq(#out, 2, "healthy hrefs must come back")
			truthy(skipped, "broken href must be reported")
			eq(#skipped, 1)
			truthy(skipped[1]:find("broken%.ics"), "skipped href must be the broken one")
			caldav.transport = nil
		end)

		it("keeps HTTP statuses fatal", function()
			caldav.transport = function(_, callback)
				callback(nil, { status = 500, headers = {}, body = "" })
			end
			local r = run_async(function()
				return caldav.multiget(ACCOUNT, CAL, { "/dav/home/work/a.ics" })
			end)
			truthy(r[1] == nil and r[2] ~= nil, "HTTP 500 must stay fatal")
			caldav.transport = nil
		end)
	end)

	describe("initial fetch", function()
		it("falls back to enumeration when the REPORT dies mid-stream", function()
			caldav.transport = broken_transport(true)
			local r = run_async(function()
				return caldav.initial_fetch(ACCOUNT, CAL, WINDOW)
			end)
			local result, err = r[1], r[2]
			eq(err, nil, "fallback must recover")
			eq(#result.changed, 2, "good events must be pulled")
			truthy(result.skipped and #result.skipped == 1, "broken must be listed as skipped")
			eq(result.token, "7", "sync token must still be captured")
			caldav.transport = nil
		end)
	end)

	describe("in_window", function()
		it("keeps overlaps and series, drops provable outsiders", function()
			local ws, we = "20250801", "20270301"
			local function blk(fields)
				return vim.tbl_extend("force", { date = "2026-09-01", duration_min = 60 }, fields or {})
			end
			local ev = {}
			truthy(caldav.in_window(blk(), ev, ws, we), "inside one-off")
			falsy(caldav.in_window(blk({ date = "2025-01-01" }), ev, ws, we), "old one-off")
			falsy(caldav.in_window(blk({ date = "2028-01-01" }), ev, ws, we), "future one-off")
			truthy(caldav.in_window(blk({ date = "2025-01-01", recurrence = { type = "daily" } }), ev, ws, we), "open series")
			falsy(
				caldav.in_window(blk({ date = "2025-01-01", recurrence = { type = "daily", until_date = "2025-02-01" } }), ev, ws, we),
				"ended series"
			)
			truthy(caldav.in_window(blk(), { cancelled = true }, ws, we), "cancelled carries a delete")
			truthy(caldav.in_window(blk({ date = "2020-01-01" }), { lossy = "x" }, ws, we), "lossy placement uncertain")
			truthy(
				caldav.in_window(blk({ date = "2025-07-30", duration_min = 3 * 1440 }), ev, ws, we),
				"multi-day overlapping start"
			)
			falsy(
				caldav.in_window(blk({ date = "2025-07-01", duration_min = 3 * 1440 }), ev, ws, we),
				"multi-day fully outside"
			)
		end)
	end)
end)
