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
	local raw_bridge, document_fixture = Bridge, nil
	local native_push = Bridge._push
	local function install()
		if document_fixture then document_fixture.close() end
		Bridge = raw_bridge
		Bridge._reset()
		local get, calls = scripted_get()
		local pushed = {}
		Bridge._http_get = get
		Bridge._push = function(payload) pushed[#pushed + 1] = payload; return true end
		-- Complete native initialization with a setup-only inert transport. The
		-- test's scripted transport starts after genuine document admission.
		raw_bridge._http_get = function() end
		document_fixture = require("tests.support.document_fixture").new("changelog", raw_bridge, {})
		document_fixture.handshake()
		raw_bridge._http_get = get
		Bridge = document_fixture.proxy()
		return calls, pushed
	end

	--- Runs `body` with the updater following `channel`.
	local function following(channel, body)
		local previous = package.loaded["modules.updater.manager"]
		local real = require("modules.updater.manager")
		package.loaded["modules.updater.manager"] = setmetatable({
			get_channel = function() return channel end,
		}, { __index = real })
		local ok, err = pcall(body)
		-- The caller may release transport callbacks after this configuration scope.
		-- Keep its actual document lease until the next install() or group teardown.
		package.loaded["modules.updater.manager"] = previous
		if not ok then error(err, 0) end
	end

	helpers.it("opens on the prerelease channel when the installation follows it", function()
		following("dev", function()
			local calls, pushed = install()
			local initial = Bridge.on_message("ready", {})
			helpers.assert_eq(initial.channel, "dev",
				"on 'main' the page hides every prerelease: the window opened on an empty list")
			calls[1].callback(200, "[{\"tag_name\":\"v0.0.0-dev.134\",\"prerelease\":true}]", nil)
			helpers.assert_eq(pushed[1].channel, "dev")
			Bridge._reset()
		end)
	end)

	helpers.it("starts a bounded API fetch when the page is ready", function()
		local calls, pushed = install()
		local initial
		following("main", function() initial = Bridge.on_message("ready", {}) end)
		helpers.assert_eq(initial.action, "releases", "the cached fast path keeps its response shape")
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(calls[1].url, "https://api.github.com/repos/adrienm7/ergopti/releases?per_page=20")
		helpers.assert_eq(calls[1].timeout_ms, 15000)
		calls[1].callback(200, "[{\"tag_name\":\"v2.4.0\"}]", nil)
		helpers.assert_eq(#pushed, 1)
		helpers.assert_eq(pushed[1].action, "releases")
		helpers.assert_eq(pushed[1].json, "[{\"tag_name\":\"v2.4.0\"}]", "API text is pushed for the page to parse")
		helpers.assert_nil(pushed[1].feed)
		Bridge._reset()
	end)

	-- The window used to open on "main" whatever the user followed, so a dev
	-- subscriber saw an empty stable list first.
	for _, subscribed in ipairs({ "dev", "main" }) do
		helpers.it("opens on the subscribed channel (" .. subscribed .. ")", function()
			local calls, pushed = install()
			local real = require("modules.updater.manager")
			local previous = package.loaded["modules.updater.manager"]
			package.loaded["modules.updater.manager"] = setmetatable({
				get_channel = function() return subscribed end,
				get_cached_release = function() return nil end,
			}, { __index = real })
			local ok, err = pcall(function()
				local initial = Bridge.on_message("ready", {})
				helpers.assert_eq(initial.channel, subscribed, "the first view is the subscribed channel")
				calls[1].callback(200, "[]", nil)
				helpers.assert_eq(pushed[1].channel, subscribed, "the fetched list is pushed for that channel")
			end)
			package.loaded["modules.updater.manager"] = previous
			Bridge._reset()
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("refuses a fetch for a channel outside the registry", function()
		local calls = install()
		for _, unknown in ipairs({ "stable", "beta", "Main" }) do
			local answer = Bridge.on_message({ action = "fetch", channel = unknown }, {})
			helpers.assert_eq(answer.action, "releases_error", unknown .. " must be refused")
		end
		helpers.assert_eq(#calls, 0, "no request may start for an unknown channel")
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
		if document_fixture then document_fixture.close(); document_fixture = nil end
		Bridge = raw_bridge; Bridge._reset(); Bridge._push = native_push
		Bridge._http_get = function() end
		local native = require("tests.support.document_fixture").new("changelog", raw_bridge, {})
		native.handshake()
		local evaluated = native.effects
		local get, calls = scripted_get()
		Bridge._http_get = get
		Bridge.start_fetch("main")
		calls[1].callback(0, "", "timeout")
		calls[2].callback(0, "", "timeout")
		native.close()
		helpers.assert_eq(#evaluated, 1)
		helpers.assert_eq(evaluated[1].app, "changelog")
		local encoded = evaluated[1].code:match("__hostBridgeResponse%('changelog_bridge',true,'([^']+)'%)")
		helpers.assert_not_nil(encoded, "the push must use the base64 response hook")
		local decoded = require("json").decode(base64_decode(encoded))
		helpers.assert_eq(decoded.action, "releases_error")
		Bridge._reset()
	end)
	if document_fixture then document_fixture.close(); document_fixture = nil end
end)

-- The page's tabs used to be the only channel control the window had, and the
-- subscription lived in the menu alone: the page could not subscribe, and a
-- menu change never reached an open page.
helpers.describe("changelog_bridge: subscription", function()
	local Bridge = helpers.load_module("ui.changelog.bridge")

	--- Runs a body with a manager double over the real one (for its registry).
	--- @param subscribed string Channel the double starts on.
	--- @param accept boolean What set_channel answers.
	--- @param body function Receives the record of set_channel calls.
	local function with_manager(subscribed, accept, body)
		local real = require("modules.updater.manager")
		local previous = package.loaded["modules.updater.manager"]
		local record = { calls = {}, current = subscribed }
		package.loaded["modules.updater.manager"] = setmetatable({
			get_channel = function() return record.current end,
			get_cached_release = function() return nil end,
			set_channel = function(id)
				record.calls[#record.calls + 1] = id
				if accept then record.current = id end
				return accept
			end,
		}, { __index = real })
		Bridge._reset()
		local pushed = {}
		Bridge._http_get = function() end
		Bridge._push = function(payload) pushed[#pushed + 1] = payload; return true end
		record.pushed = pushed
		local native = require("tests.support.document_fixture").new("changelog", Bridge, {})
		local original = Bridge
		Bridge = native.proxy()
		local ok, err = pcall(body, record)
		native.close(); Bridge = original
		package.loaded["modules.updater.manager"] = previous
		Bridge._reset()
		if not ok then error(err, 0) end
	end

	helpers.it("tells the page which channel the user receives on opening", function()
		with_manager("dev", true, function()
			local initial = Bridge.on_message("ready", {})
			helpers.assert_eq(initial.subscribed_channel, "dev", "the banner needs the subscription")
		end)
	end)

	helpers.it("subscribes through the updater and rebuilds the menu", function()
		with_manager("dev", true, function(record)
			local rebuilt = 0
			local answer = Bridge.on_message({ action = "set_channel", channel = "main" },
				{ on_config_changed = function() rebuilt = rebuilt + 1 end })
			helpers.assert_eq(#record.calls, 1, "the updater must be asked once")
			helpers.assert_eq(record.calls[1], "main")
			helpers.assert_eq(rebuilt, 1, "the menu tick must follow the new channel")
			helpers.assert_eq(answer.action, "channel_changed")
			helpers.assert_eq(answer.channel, "main")
			helpers.assert_true(answer.ok, "an accepted change must be reported")
		end)
	end)

	helpers.it("refuses ids outside the registry without touching the updater", function()
		with_manager("dev", true, function(record)
			for _, unknown in ipairs({ "stable", "beta", "Main", 42 }) do
				local rebuilt = 0
				local answer = Bridge.on_message({ action = "set_channel", channel = unknown },
					{ on_config_changed = function() rebuilt = rebuilt + 1 end })
				helpers.assert_eq(answer.ok, false, tostring(unknown) .. " must be refused")
				helpers.assert_eq(answer.channel, "dev", "the answer keeps the current subscription")
				helpers.assert_eq(rebuilt, 0)
			end
			helpers.assert_eq(#record.calls, 0, "no unknown id may reach the updater")
		end)
	end)

	helpers.it("reports a refusal of the updater to the page", function()
		with_manager("dev", false, function(record)
			local answer = Bridge.on_message({ action = "set_channel", channel = "main" }, {})
			helpers.assert_eq(#record.calls, 1)
			helpers.assert_eq(answer.ok, false)
			helpers.assert_eq(answer.channel, "dev")
		end)
	end)

	helpers.it("pushes a menu change to an open page", function()
		with_manager("dev", true, function(record)
			helpers.assert_true(Bridge.push_subscribed_channel("main"))
			helpers.assert_eq(#record.pushed, 1)
			helpers.assert_eq(record.pushed[1].action, "channel_changed")
			helpers.assert_eq(record.pushed[1].channel, "main")
			helpers.assert_true(record.pushed[1].ok)
			helpers.assert_eq(Bridge.push_subscribed_channel("stable"), false, "aliases are not pushed")
			helpers.assert_eq(#record.pushed, 1)
		end)
	end)
end)
