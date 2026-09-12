-- Collection-tag short-circuit: a pull whose collection ctag matches the
-- last successful pull fetches nothing. Repeated :e becomes discover +
-- push-check only. Servers without ctag always pull, as before.
local caldav = require("bloocky.sync.providers.caldav")
local config = require("bloocky.config")
local state = require("bloocky.state")
local store = require("bloocky.sync.store")
local sync = require("bloocky.sync")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local counter = 0

local CALHREF = "/dav/home/work/"
local CTAG = { value = "TAG-1" }
local RESOURCES = {}
local REPORTS = 0

local function ms(inner)
	return '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">'
		.. inner
		.. "</d:multistatus>"
end

local function ics(uid, summary)
	return table.concat({
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"BEGIN:VEVENT",
		"UID:" .. uid,
		"DTSTAMP:20260801T090000Z",
		"DTSTART:20260901T100000Z",
		"DTEND:20260901T110000Z",
		"SUMMARY:" .. summary,
		"END:VEVENT",
		"END:VCALENDAR",
	}, "\r\n")
end

local function esc(text)
	return (tostring(text):gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function setup()
	counter = counter + 1
	RESOURCES = { [CALHREF .. "a.ics"] = { etag = '"a"', data = ics("a", "Alpha") } }
	CTAG.value = "TAG-1"
	REPORTS = 0

	config.options.save_path = ("%s/blocks_ctag_%d.json"):format(tmpdir, counter)
	config.options.sync = {
		enabled = true,
		store_path = ("%s/sync_ctag_%d.json"):format(tmpdir, counter),
		window = { past_days = 30, future_days = 180 },
		conflict = { trail_limit = 50 },
		accounts = {
			{ id = "work", provider = "caldav", url = "https://dav.example.com/dav/", username = "me@example.com", password = "secret" },
		},
	}
	state.blocks = {}
	state.save_blocks()
	state.load_blocks()
	store.load()
	require("bloocky.sync.account").forget_secrets()

	caldav.transport = function(opts, callback)
		local body = opts.body or ""
		local method = opts.method or "GET"
		if method == "PROPFIND" then
			if body:find("sync%-token") then
				callback(nil, { status = 207, headers = {}, body = ms("<d:sync-token>9</d:sync-token>") })
				return
			end
			local ctag_el = CTAG.value and ("<cs:getctag>" .. CTAG.value .. "</cs:getctag>") or ""
			callback(nil, {
				status = 207,
				headers = {},
				body = ms("<d:response><d:href>"
					.. CALHREF
					.. "</d:href><d:propstat><d:prop>"
					.. "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>"
					.. "<d:displayname>Work</d:displayname>"
					.. ctag_el
					.. '<c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>'
					.. "</d:prop></d:propstat></d:response>"),
			})
			return
		end
		if method == "REPORT" then
			REPORTS = REPORTS + 1
			local parts = {}
			for href, resource in pairs(RESOURCES) do
				parts[#parts + 1] = "<d:response><d:href>"
					.. href
					.. "</d:href><d:propstat><d:prop><d:getetag>"
					.. resource.etag
					.. "</d:getetag><c:calendar-data>"
					.. esc(resource.data)
					.. "</c:calendar-data></d:prop></d:propstat></d:response>"
			end
			callback(nil, { status = 207, headers = {}, body = ms(table.concat(parts)) })
			return
		end
		callback(nil, { status = 405, headers = {}, body = "" })
	end
end

local function run_sync()
	local report
	sync.run("work", function(reports)
		report = reports and reports[1]
	end)
	vim.wait(2000, function()
		return report ~= nil
	end)
	assert(report ~= nil, "sync never finished")
	return report
end

describe("ctag short-circuit", function()
	it("pulls once, then skips the fetch while the collection is untouched", function()
		setup()
		local before = REPORTS
		local r1 = run_sync()
		truthy(REPORTS > before, "first sync must fetch")
		eq(store.calendar_ctag("work", CALHREF), "TAG-1", "ctag must be remembered")
		truthy(#state.blocks == 1, "event must be pulled")
		local after_first = REPORTS

		local r2 = run_sync()
		eq(REPORTS, after_first, "second sync must not fetch again")
		eq(r2.skipped.unchanged or 0, 1, "second sync must short-circuit")
		eq(#state.blocks, 1, "blocks must be intact")
		caldav.transport = nil
	end)

	it("pulls again when the ctag moves", function()
		setup()
		run_sync()
		local reports_after_first = REPORTS
		RESOURCES[CALHREF .. "b.ics"] = { etag = '"b"', data = ics("b", "Beta") }
		CTAG.value = "TAG-2"
		local r2 = run_sync()
		truthy(REPORTS > reports_after_first, "changed collection must be fetched")
		eq(#state.blocks, 2, "new event must be pulled")
		eq(store.calendar_ctag("work", CALHREF), "TAG-2", "ctag must advance")
		eq(r2.skipped.unchanged or 0, 0, "must not claim unchanged")
		caldav.transport = nil
	end)

	it("always pulls when the server sends no ctag", function()
		setup()
		CTAG.value = nil
		run_sync()
		local reports_after_first = REPORTS
		run_sync()
		truthy(REPORTS > reports_after_first, "ctag-less servers must pull every time")
		caldav.transport = nil
	end)
end)
