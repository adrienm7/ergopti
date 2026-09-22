--- tests/unit/meta/test_changelog_release_sources.lua

--- ==============================================================================
--- MODULE: Changelog Release Sources
--- DESCRIPTION:
--- The changelog used to depend on the page's own fetch of api.github.com,
--- which a corporate proxy can block while github.com stays reachable, and the
--- window then spun forever. These tests drive the shared source order (API,
--- then the Atom feed) and the Linux bridge that pushes the outcome, with a
--- scripted transport and the shared fixture feed.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
local SHARED_ROOT = DRIVER_ROOT .. "/../_shared"

--- Reads one shared file as bytes.
--- @param relative string Path below _shared.
--- @return string
local function read_shared(relative)
	local handle = assert(io.open(SHARED_ROOT .. "/" .. relative, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local FEED = read_shared("tests/corpus/updater/releases_feed.atom")

--- Returns the decoded shared updater defaults.
--- @return table
local function defaults()
	return require("json").decode(read_shared("modules/updater/defaults.json"))
end

--- Builds a transport double whose responses are released by the test.
--- @return function get, table calls
local function scripted_get()
	local calls = {}
	local function get(url, headers, timeout_ms, callback)
		calls[#calls + 1] = { url = url, headers = headers, timeout_ms = timeout_ms, callback = callback }
	end
	return get, calls
end

--- Records log lines by level.
--- @return table logger, table lines
local function recording_logger()
	local lines = {}
	local logger = {}
	for _, level in ipairs({ "info", "warn", "error", "debug", "start", "done", "success" }) do
		logger[level] = function(_tag, fmt, ...)
			lines[#lines + 1] = { level = level, text = string.format(fmt, ...) }
		end
	end
	return logger, lines
end

--- Returns whether any recorded line contains a plain substring.
--- @param lines table
--- @param needle string
--- @return boolean
local function logged(lines, needle)
	for _, line in ipairs(lines) do
		if line.text:find(needle, 1, true) then return true end
	end
	return false
end

helpers.describe("release_sources: shared defaults", function()
	local Sources = helpers.load_module("updater.release_sources")

	helpers.it("expands the canonical API, feed and page URLs", function()
		local sources = assert(Sources.resolve(defaults()))
		helpers.assert_eq(sources.api_url, "https://api.github.com/repos/adrienm7/ergopti/releases?per_page=20")
		helpers.assert_eq(sources.feed_url, "https://github.com/adrienm7/ergopti/releases.atom")
		helpers.assert_eq(sources.page_url, "https://github.com/adrienm7/ergopti/releases")
		helpers.assert_eq(sources.source_timeout_ms, 15000)
		helpers.assert_true(sources.watchdog_ms > sources.proxy_timeout_ms + 2 * sources.source_timeout_ms,
			"the page watchdog must outlast proxy resolution and both sources")
	end)

	helpers.it("refuses incomplete or inconsistent defaults instead of guessing", function()
		local base = defaults()
		base.release_sources = nil
		helpers.assert_nil(Sources.resolve(base))
		base = defaults()
		base.release_sources.atom_feed_url = "http://github.com/releases.atom"
		helpers.assert_nil(Sources.resolve(base), "a template without the repository must be refused")
		base = defaults()
		base.release_sources.ui_watchdog_sec = 20
		local sources, err = Sources.resolve(base)
		helpers.assert_nil(sources)
		helpers.assert_true(err:find("outlast", 1, true) ~= nil, "a watchdog shorter than both sources must be refused")
		base = defaults()
		base.github.owner = "evil/../x"
		helpers.assert_nil(Sources.resolve(base), "an owner that escapes the URL template must be refused")
	end)

	helpers.it("classifies proxy block pages as failures, not data", function()
		helpers.assert_true(Sources.classify_api(200, "[{\"tag_name\":\"v1\"}]\n"))
		helpers.assert_true(Sources.classify_api(200, "\239\187\191[]"))
		local ok, reason = Sources.classify_api(200, "<html>Blocked by policy</html>")
		helpers.assert_eq(ok, false)
		helpers.assert_eq(reason, "HTTP 200 without a JSON release array")
		helpers.assert_eq(select(2, Sources.classify_api(403, "")), "HTTP 403")
		helpers.assert_eq(select(2, Sources.classify_api(0, nil, "timeout")), "timeout")
		helpers.assert_eq(select(2, Sources.classify_api(nil, nil, nil)), "no response")
		helpers.assert_true(Sources.classify_feed(200, FEED))
		helpers.assert_eq(select(2, Sources.classify_feed(200, "<html></html>")), "HTTP 200 without an Atom feed")
	end)
end)

helpers.describe("release_sources: ordered fetch", function()
	local Sources = helpers.load_module("updater.release_sources")
	local sources = assert(Sources.resolve(defaults()))

	helpers.it("serves the API result without touching the feed", function()
		local get, calls = scripted_get()
		local logger, lines = recording_logger()
		local results = {}
		Sources.fetch(sources, get, logger, "test", function(result) results[#results + 1] = result end)
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(calls[1].url, sources.api_url)
		helpers.assert_eq(calls[1].timeout_ms, sources.source_timeout_ms, "every source must be bounded")
		helpers.assert_eq(calls[1].headers.Accept, "application/vnd.github+json")
		calls[1].callback(200, "[]", nil)
		helpers.assert_eq(#calls, 1, "a usable API answer must not trigger the feed")
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].source, Sources.SOURCE_API)
		helpers.assert_eq(results[1].kind, "json")
		helpers.assert_true(logged(lines, "served by the GitHub API"))
	end)

	helpers.it("falls back to the Atom feed when the API times out and logs why", function()
		local get, calls = scripted_get()
		local logger, lines = recording_logger()
		local results = {}
		Sources.fetch(sources, get, logger, "test", function(result) results[#results + 1] = result end)
		calls[1].callback(0, "", "timeout")
		helpers.assert_eq(#calls, 2, "a failed API attempt must try the alternate source")
		helpers.assert_eq(calls[2].url, sources.feed_url)
		helpers.assert_eq(calls[2].timeout_ms, sources.source_timeout_ms)
		helpers.assert_eq(calls[2].headers.Accept, "application/atom+xml")
		calls[2].callback(200, FEED, nil)
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].source, Sources.SOURCE_FEED)
		helpers.assert_eq(results[1].kind, "feed")
		helpers.assert_eq(results[1].body, FEED)
		helpers.assert_eq(results[1].api_failure, "timeout")
		helpers.assert_true(logged(lines, "GitHub API release list failed (timeout)"))
		helpers.assert_true(logged(lines, "served by the Atom feed (API failed: timeout)"))
	end)

	helpers.it("reports a rate limit only when GitHub throttled the API", function()
		local get, calls = scripted_get()
		local logger, lines = recording_logger()
		local result = nil
		Sources.fetch(sources, get, logger, "test", function(value) result = value end)
		calls[1].callback(403, "", "HTTP 403")
		calls[2].callback(0, "", "Could not resolve host: github.com")
		helpers.assert_eq(result.error_key, "changelog_window.error_rate_limited")
		helpers.assert_true(logged(lines, "API failed (HTTP 403), Atom feed failed (Could not resolve host: github.com)"))

		get, calls = scripted_get()
		Sources.fetch(sources, get, logger, "test", function(value) result = value end)
		calls[1].callback(200, "<html>proxy</html>", nil)
		calls[2].callback(200, "<html>proxy</html>", nil)
		helpers.assert_eq(result.error_key, "changelog_window.error_network")
		helpers.assert_true(result.error:find("without an Atom feed", 1, true) ~= nil)
	end)

	helpers.it("ignores duplicate transport callbacks and completes exactly once", function()
		local get, calls = scripted_get()
		local logger = recording_logger()
		local count = 0
		Sources.fetch(sources, get, logger, "test", function() count = count + 1 end)
		calls[1].callback(0, "", "timeout")
		calls[1].callback(200, "[]", nil)
		helpers.assert_eq(#calls, 2, "a late API answer must not start a second feed request")
		calls[2].callback(200, FEED, nil)
		calls[2].callback(0, "", "late")
		helpers.assert_eq(count, 1)
	end)
end)

helpers.describe("changelog_bridge: native fetch push", function()
	local Bridge = helpers.load_module("ui.changelog.bridge")

	--- Decodes padded RFC 4648 Base64 (the codec under test only encodes).
	--- @param text string
	--- @return string
	local function base64_decode(text)
		local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		local bytes = {}
		for offset = 1, #text, 4 do
			local chunk = text:sub(offset, offset + 3)
			local value, pad = 0, 0
			for index = 1, 4 do
				local ch = chunk:sub(index, index)
				local digit = ch == "=" and 0 or (alphabet:find(ch, 1, true) - 1)
				if ch == "=" then pad = pad + 1 end
				value = value * 64 + digit
			end
			local decoded = string.char(math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256)
			bytes[#bytes + 1] = decoded:sub(1, 3 - pad)
		end
		return table.concat(bytes)
	end

	--- Installs scripted seams and returns their records.
	local function install()
		Bridge._reset()
		local get, calls = scripted_get()
		local pushed = {}
		Bridge._http_get = get
		Bridge._push = function(payload) pushed[#pushed + 1] = payload; return true end
		return calls, pushed
	end

	helpers.it("starts a bounded API fetch when the page is ready", function()
		local calls, pushed = install()
		local initial = Bridge.on_message("ready", {})
		helpers.assert_eq(initial.action, "releases", "the cached fast path keeps its response shape")
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(calls[1].url, "https://api.github.com/repos/adrienm7/ergopti/releases?per_page=20")
		helpers.assert_eq(calls[1].timeout_ms, 15000)
		calls[1].callback(200, "[{\"tag_name\":\"v2.4.0\"}]", nil)
		helpers.assert_eq(#pushed, 1)
		helpers.assert_eq(pushed[1].action, "releases")
		helpers.assert_eq(pushed[1].channel, "main")
		helpers.assert_eq(pushed[1].json, "[{\"tag_name\":\"v2.4.0\"}]", "API text is pushed for the page to parse")
		helpers.assert_nil(pushed[1].feed)
		Bridge._reset()
	end)

	helpers.it("pushes the Atom feed when the API is blocked", function()
		local calls, pushed = install()
		Bridge.on_message({ action = "fetch", channel = "dev" }, {})
		calls[1].callback(0, "", "Failed to connect to api.github.com port 443")
		helpers.assert_eq(calls[2].url, "https://github.com/adrienm7/ergopti/releases.atom")
		calls[2].callback(200, FEED, nil)
		helpers.assert_eq(#pushed, 1)
		helpers.assert_eq(pushed[1].channel, "dev")
		helpers.assert_eq(pushed[1].feed, FEED)
		Bridge._reset()
	end)

	helpers.it("turns an exhausted fetch into a visible error key, never silence", function()
		local calls, pushed = install()
		Bridge.on_message({ action = "fetch", channel = "main" }, {})
		calls[1].callback(0, "", "timeout")
		calls[2].callback(0, "", "timeout")
		helpers.assert_eq(#pushed, 1)
		helpers.assert_eq(pushed[1].action, "releases_error")
		helpers.assert_eq(pushed[1].error_key, "changelog_window.error_network")
		Bridge._reset()
	end)

	helpers.it("discards a superseded fetch when the channel changes", function()
		local calls, pushed = install()
		Bridge.on_message({ action = "fetch", channel = "main" }, {})
		Bridge.on_message({ action = "fetch", channel = "dev" }, {})
		calls[1].callback(200, "[]", nil)
		helpers.assert_eq(#pushed, 0, "the stale stable answer must not overwrite the dev request")
		calls[2].callback(200, "[{}]", nil)
		helpers.assert_eq(#pushed, 1)
		helpers.assert_eq(pushed[1].channel, "dev")
		Bridge._reset()
	end)

	helpers.it("encodes the push for the page response hook", function()
		Bridge._reset()
		local previous = package.loaded["ui.webview_manager"]
		local evaluated = {}
		package.loaded["ui.webview_manager"] = {
			eval_js = function(app, code) evaluated[#evaluated + 1] = { app = app, code = code }; return true end,
		}
		local get, calls = scripted_get()
		Bridge._http_get = get
		Bridge.start_fetch("main")
		calls[1].callback(0, "", "timeout")
		calls[2].callback(0, "", "timeout")
		package.loaded["ui.webview_manager"] = previous
		helpers.assert_eq(#evaluated, 1)
		helpers.assert_eq(evaluated[1].app, "changelog")
		local encoded = evaluated[1].code:match("__hostBridgeResponse%('changelog_bridge',true,'([^']+)'%)")
		helpers.assert_not_nil(encoded, "the push must use the base64 response hook")
		local decoded = require("json").decode(base64_decode(encoded))
		helpers.assert_eq(decoded.action, "releases_error")
		Bridge._reset()
	end)
end)
