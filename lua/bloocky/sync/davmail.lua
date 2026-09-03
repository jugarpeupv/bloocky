-- Helper to integrate with DavMail's cached OAuth tokens and Microsoft Graph API
-- for automatic Teams meeting generation.

local account_config = require("bloocky.sync.account")
local async = require("bloocky.sync.async")
local http = require("bloocky.sync.http")
local tz = require("bloocky.sync.tz")

local M = {}

local function find_davmail_jar()
	local candidates = {
		"/opt/homebrew/Cellar/davmail/6.8.1/libexec/davmail.jar",
		"/opt/homebrew/share/davmail/davmail.jar",
		"/usr/local/share/davmail/davmail.jar",
		"/usr/share/davmail/davmail.jar",
	}
	-- Also check glob for any homebrew version
	local brew_glob = vim.fn.glob("/opt/homebrew/Cellar/davmail/*/libexec/davmail.jar", false, true)
	if type(brew_glob) == "table" and #brew_glob > 0 then
		table.insert(candidates, 1, brew_glob[#brew_glob])
	end
	for _, p in ipairs(candidates) do
		if vim.fn.filereadable(p) == 1 then
			return p
		end
	end
	return nil
end

local function get_davmail_props()
	local p = vim.fn.expand("~/.davmail.properties")
	if vim.fn.filereadable(p) ~= 1 then p = vim.fn.expand("~/.config/davmail/davmail.properties") end
	if vim.fn.filereadable(p) ~= 1 then p = vim.fn.expand("~/dotfiles/davmail/.davmail.properties") end
	return p
end

local function read_prop(key)
	local prop_path = get_davmail_props()
	if vim.fn.filereadable(prop_path) == 1 then
		for _, line in ipairs(vim.fn.readfile(prop_path)) do
			local k, v = line:match("^%s*([^#][^=]*)=(.*)$")
			if k and k:match("^%s*" .. key .. "%s*$") then
				return v:gsub("^%s+", ""):gsub("%s+$", "")
			end
		end
	end
	return nil
end

local function token_file_path(account)
	local candidates = {}

	local explicit = account.davmail_token_file or account.token_file
	if explicit and explicit ~= "" then
		table.insert(candidates, { path = vim.fn.expand(explicit), source = "account config (davmail_token_file)" })
	end

	local prop_path = get_davmail_props()
	if prop_path and vim.fn.filereadable(prop_path) == 1 then
		local prop_val = read_prop("davmail.oauth.tokenFilePath")
		if prop_val and prop_val ~= "" then
			table.insert(candidates, { path = vim.fn.expand(prop_val), source = prop_path .. " [davmail.oauth.tokenFilePath]" })
		end
	end

	for _, c in ipairs(candidates) do
		if vim.fn.filereadable(c.path) == 1 then
			return c.path, nil
		end
	end

	local searched = {}
	for _, c in ipairs(candidates) do
		table.insert(searched, string.format("'%s' (%s)", c.path, c.source))
	end

	local prop_sources = { "~/.davmail.properties", "~/.config/davmail/davmail.properties", "~/dotfiles/davmail/.davmail.properties" }
	local msg
	if #searched > 0 then
		msg = string.format("DavMail token file not found on disk. Checked: [%s]", table.concat(searched, ", "))
	else
		msg = string.format(
			"DavMail token file is not configured for account %s. Please set `davmail_token_file` in setup() or configure `davmail.oauth.tokenFilePath` in DavMail properties (searched: %s).",
			account.id or "default",
			table.concat(prop_sources, ", ")
		)
	end

	return nil, msg
end

--- Extract refresh token from DavMail's store (decrypting with Java if {AES} encrypted)
function M.get_refresh_token(account)
	local token_file, err = token_file_path(account)
	if not token_file then
		vim.notify("Bloocky: " .. err, vim.log.levels.ERROR)
		return nil, err
	end

	local username = (account.username or ""):lower()
	local raw_value = nil
	for line in io.lines(token_file) do
		local trimmed = vim.trim(line)
		if not trimmed:match("^#") and trimmed:match("=") then
			local k, v = trimmed:match("^([^=]+)=(.*)$")
			if k and vim.trim(k):lower() == username then
				raw_value = vim.trim(v)
				break
			end
		end
	end

	if not raw_value or raw_value == "" then
		return nil, "no token entry found for user " .. username .. " in " .. token_file
	end

	-- If not encrypted, return directly!
	if not raw_value:match("^{AES}") then
		return raw_value, nil
	end

	-- If encrypted with {AES}, decrypt using DavMail's StringEncryptor
	local jar = find_davmail_jar()
	if not jar then
		return nil, "davmail.jar not found to decrypt {AES} token"
	end

	local password = account_config.secret(account, "password") or account.password or ""
	local java_code = string.format([[
import davmail.Settings;
import davmail.exchange.auth.O365Token;
import java.io.*;
import java.lang.reflect.*;

public class GetDavmailToken {
    public static void main(String[] args) {
        try {
            File propFile = new File("%s");
            if (!propFile.exists()) {
                propFile = new File("%s");
            }
            if (propFile.exists()) {
                FileInputStream fis = new FileInputStream(propFile);
                Settings.load(fis);
                fis.close();
            }
            Settings.setProperty("davmail.oauth.tokenFilePath", "%s");
            Settings.setProperty("davmail.oauth.persistToken", "true");
            
            String tenantId = Settings.getProperty("davmail.oauth.tenantId", "common");
            String clientId = Settings.getProperty("davmail.oauth.clientId", "d3590ed6-52b3-4102-aeff-aad2292ab01c");
            String redirectUri = Settings.getProperty("davmail.oauth.redirectUri", "urn:ietf:wg:oauth:2.0:oob");

            Method loadMethod = O365Token.class.getDeclaredMethod(
                "load", String.class, String.class, String.class, String.class, String.class
            );
            loadMethod.setAccessible(true);
            
            O365Token token = (O365Token) loadMethod.invoke(
                null,
                tenantId,
                clientId,
                redirectUri,
                "%s",
                "%s"
            );
            if (token != null) {
                String rt = token.getRefreshToken();
                if (rt != null && !rt.isEmpty()) {
                    System.out.println("TOKEN_OUTPUT:" + rt);
                    return;
                }
            }
            System.err.println("Failed to obtain token from DavMail store");
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
]], vim.fn.expand("~/.davmail.properties"), vim.fn.expand("~/dotfiles/davmail/.davmail.properties"), token_file, username, password:gsub('\\', '\\\\'):gsub('"', '\\"'))

	local tmp_dir = vim.fn.tempname()
	vim.fn.mkdir(tmp_dir, "p")
	local java_file = tmp_dir .. "/GetDavmailToken.java"
	local f = io.open(java_file, "w")
	if not f then
		return nil, "could not write temp java file"
	end
	f:write(java_code)
	f:close()

	local compile_cmd = string.format('javac -cp %s -d %s %s 2>&1', vim.fn.shellescape(jar), vim.fn.shellescape(tmp_dir), vim.fn.shellescape(java_file))
	local compile_out = vim.fn.system(compile_cmd)
	if vim.v.shell_error ~= 0 then
		vim.fn.delete(tmp_dir, "rf")
		return nil, "javac failed: " .. compile_out
	end

	local run_cmd = string.format('java -cp %s:%s GetDavmailToken', vim.fn.shellescape(jar), vim.fn.shellescape(tmp_dir))
	local run_out = vim.fn.system(run_cmd)
	vim.fn.delete(tmp_dir, "rf")

	local token = run_out:match("TOKEN_OUTPUT:(%S+)")
	if not token then
		return nil, "could not decrypt davmail token: " .. run_out
	end
	return token, nil
end

--- Get Microsoft Graph access token using the refresh token
function M.get_access_token(account)
	local refresh_token, err = M.get_refresh_token(account)
	if not refresh_token then
		return nil, err
	end

	local client_id = account.client_id or "d3590ed6-52b3-4102-aeff-aad2292ab01c"
	local body = "client_id=" .. client_id .. "&grant_type=refresh_token&refresh_token=" .. refresh_token .. "&scope=" .. vim.uri_encode("https://graph.microsoft.com/.default offline_access", "rfc2396")

	local req_err, res = async.await(function(cb)
		http.request({
			url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
			method = "POST",
			headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
			body = body,
		}, function(e, response)
			cb(e, response)
		end)
	end)

	if req_err then
		return nil, req_err
	end

	local decoded = nil
	if res.body and res.body ~= "" then
		pcall(function()
			decoded = vim.json.decode(res.body)
		end)
	end

	if res.status >= 400 or not (decoded and decoded.access_token) then
		local msg = decoded and (decoded.error_description or decoded.error) or ("HTTP " .. tostring(res.status))
		return nil, "Graph token error: " .. tostring(msg)
	end

	return decoded.access_token, nil
end

--- Create an online meeting in Microsoft Graph API and attach Teams join details to block
function M.create_online_meeting(account, block)
	local token, err = M.get_access_token(account)
	if not token then
		return nil, err
	end

	local lz = tz.local_zone()
	local function slot(min)
		local h = math.floor(min / 60)
		local m = min % 60
		return {
			dateTime = string.format("%sT%02d:%02d:00", block.date, h, m),
			timeZone = lz,
		}
	end

	local initial_notes = vim.trim(block.notes or "")
	local formatted_notes = initial_notes
	if formatted_notes ~= "" then
		formatted_notes = formatted_notes .. "\n\n"
	end

	local body = {
		subject = block.title,
		body = {
			contentType = "text",
			content = formatted_notes,
		},
		start = slot(block.start_min),
		["end"] = slot(block.start_min + block.duration_min),
		isOnlineMeeting = true,
		onlineMeetingProvider = "teamsForBusiness",
	}

	if block.attendees and #block.attendees > 0 then
		local atts = {}
		for _, a in ipairs(block.attendees) do
			if a.email and a.email ~= "" then
				table.insert(atts, {
					emailAddress = { address = a.email, name = a.name or a.email },
					type = "required",
				})
			end
		end
		if #atts > 0 then
			body.attendees = atts
		end
	end

	local request_body = vim.json.encode(body)
	local err, res = async.await(function(cb)
		http.request({
			url = "https://graph.microsoft.com/v1.0/me/events",
			method = "POST",
			bearer = token,
			body = request_body,
			headers = {
				["Content-Type"] = "application/json",
				["Prefer"] = 'outlook.timezone="' .. lz .. '"',
			},
		}, function(req_err, response)
			cb(req_err, response)
		end)
	end)

	if err then
		return nil, err
	end

	local decoded = nil
	if res.body and res.body ~= "" then
		pcall(function()
			decoded = vim.json.decode(res.body)
		end)
	end

	if res.status >= 400 then
		local msg = decoded and decoded.error and (decoded.error.message or decoded.error) or ("HTTP " .. res.status)
		return nil, tostring(msg)
	end

	local join_url = decoded and (decoded.onlineMeeting and decoded.onlineMeeting.joinUrl or decoded.onlineMeetingUrl)
	if join_url and join_url ~= "" then
		-- Update block with the real Teams join URL
		local teams_header = "Microsoft Teams Meeting: " .. join_url
		if block.notes and block.notes ~= "" then
			block.notes = block.notes .. "\n\n" .. teams_header
		else
			block.notes = teams_header
		end
	end

	return decoded, nil
end

--- Delete an online meeting via Microsoft Graph API
function M.delete_online_meeting(account, tombstone)
	local token, err = M.get_access_token(account)
	if not token then
		return nil, err
	end

	local event_id = tombstone.graph_id
	if not event_id and tombstone.uid then
		-- Lookup event ID by iCalUId
		local query_err, query_res = async.await(function(cb)
			http.request({
				url = "https://graph.microsoft.com/v1.0/me/events?$filter=iCalUId%20eq%20%27" .. vim.uri_encode(tombstone.uid, "rfc2396") .. "%27",
				method = "GET",
				bearer = token,
			}, function(e, response)
				cb(e, response)
			end)
		end)
		if not query_err and query_res and query_res.status == 200 and query_res.body then
			local ok, dec = pcall(vim.json.decode, query_res.body)
			if ok and dec and dec.value and #dec.value > 0 then
				event_id = dec.value[1].id
			end
		end
	end

	if not event_id then
		return nil, "could not resolve Graph event ID for " .. (tombstone.title or tombstone.uid or "?")
	end

	local del_err, del_res = async.await(function(cb)
		http.request({
			url = "https://graph.microsoft.com/v1.0/me/events/" .. event_id,
			method = "DELETE",
			bearer = token,
		}, function(e, response)
			cb(e, response)
		end)
	end)

	if del_err then
		return nil, del_err
	end

	if del_res.status == 204 or del_res.status == 404 then
		return true, nil
	end

	return nil, "HTTP " .. del_res.status .. " deleting Teams meeting"
end

return M
