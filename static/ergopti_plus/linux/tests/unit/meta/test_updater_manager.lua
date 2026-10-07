--- linux/tests/unit/meta/test_updater_manager.lua

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local Installer = helpers.load_module("modules.updater.installer")
local Fs = helpers.load_module("adapters.file_system")

--- Authors native evidence for controlled responses independently of request options.
--- Each literal endpoint names one fixture representation, including bodyless 304s.
local function etag_response(result, endpoint, validator, conditional)
	result.etag_receipt = { format = "curl-etag-final-v1", effective_url = endpoint,
		validator = validator, associated = true, conditional_sent = conditional == true,
		sent_validator = conditional == true and validator or nil }
	return result
end

helpers.describe("modules/updater/manager.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "modules.updater.manager")
		helpers.assert_true(ok, "require should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	local M = helpers.load_module("modules.updater.manager")

	-- Explicit portable native-port model only for the original controlled
	-- download tests below. Real Manager/Transfer execute their ownership laws.
	local function with_native_download_model(body)
		local previous = M
		local ok, failure = xpcall(function()
			require("tests.support.updater_native_model").with_fixture(function(fresh, prepare)
				M = fresh
				body(prepare)
			end)
		end, debug.traceback)
		M = previous
		if not ok then error(failure, 0) end
	end

	helpers.it("exposes public API surface", function()
		helpers.assert_true(type(M.check_for_updates) == "function", "check_for_updates")
		helpers.assert_true(type(M.release_api_url) == "function", "release_api_url")
		helpers.assert_true(type(M.releases_page_url) == "function", "releases_page_url")
		helpers.assert_true(type(M.current_version) == "function", "current_version")
		helpers.assert_true(type(M.repo_info) == "function", "repo_info")
		helpers.assert_true(type(M.get_channel) == "function", "get_channel")
		helpers.assert_true(type(M.set_channel) == "function", "set_channel")
		helpers.assert_true(type(M.get_check_interval) == "function", "get_check_interval")
		helpers.assert_true(type(M.set_check_interval) == "function", "set_check_interval")
		helpers.assert_true(type(M.get_state) == "function", "get_state")
		helpers.assert_true(type(M.get_cached_release) == "function", "get_cached_release")
		helpers.assert_true(type(M.clear_cached_release) == "function", "clear_cached_release")
		helpers.assert_true(type(M.get_menu_label) == "function", "get_menu_label")
		helpers.assert_true(type(M.download_update) == "function", "download_update")
		helpers.assert_true(type(M.install_update) == "function", "install_update")
		helpers.assert_true(type(M.cancel_update) == "function", "cancel_update")
		helpers.assert_true(type(M.start_background_checks) == "function", "start_background_checks")
		helpers.assert_true(type(M.stop_background_checks) == "function", "stop_background_checks")
		helpers.assert_true(type(M.init) == "function", "init")
		helpers.assert_true(type(M.INTERVAL_PRESETS) == "table", "INTERVAL_PRESETS")
	end)

	helpers.it("current_version returns the driver version", function()
		local v = M.current_version()
		helpers.assert_true(type(v) == "string", "version should be a string")
		helpers.assert_true(#v > 0, "version should not be empty")
		-- Should match semver or "local".
		helpers.assert_true(v:match("^%d+%.%d+%.%d+") ~= nil or v == "local",
			"version should be semver or 'local'")
	end)

	helpers.it("repo_info returns owner and repo", function()
		local info = M.repo_info()
		helpers.assert_true(type(info) == "table", "should return a table")
		helpers.assert_true(type(info.owner) == "string", "should have owner")
		helpers.assert_true(type(info.repo) == "string", "should have repo")
		helpers.assert_true(#info.owner > 0, "owner should not be empty")
		helpers.assert_true(#info.repo > 0, "repo should not be empty")
	end)

	helpers.it("selects only the canonical Linux bundle from shuffled release assets", function()
		helpers.assert_eq(M.LINUX_ASSET_NAME, "ergopti-plus-linux.tar.gz",
			"the updater must consume the release artifact contract")
		helpers.assert_eq(M.LINUX_CHECKSUM_ASSET_NAME, "ergopti-plus-linux.tar.gz.sha256")
		local canonical_url = "https://github.com/adrienm7/ergopti/releases/download/v4.0.0/"
			.. M.LINUX_ASSET_NAME
		local checksum_url = canonical_url .. ".sha256"
		local body = '{"assets":['
			.. '{"name":"ErgoptiPlus-linux-amd64.deb","browser_download_url":"https://example.invalid/wrong.deb"},'
			.. '{"name":"' .. M.LINUX_CHECKSUM_ASSET_NAME .. '","browser_download_url":"'
			.. checksum_url .. '"},'
			.. '{"name":"' .. M.LINUX_ASSET_NAME .. '","browser_download_url":"' .. canonical_url .. '"},'
			.. '{"name":"ErgoptiPlus-linux-x86_64.AppImage","browser_download_url":"https://example.invalid/wrong.AppImage"}'
			.. ']}'

		helpers.assert_eq(M._select_update_asset(body), canonical_url,
			"asset order and package kind must not affect exact selection")
		helpers.assert_eq(M._select_checksum_asset(body), checksum_url,
			"the checksum must be selected by its exact canonical name")
	end)

	helpers.it("fails closed when the canonical Linux bundle is absent", function()
		local body = '{"tag_name":"v4.0.0","assets":['
			.. '{"name":"ergopti-plus-linux.tar.gz.sig","browser_download_url":"https://example.invalid/deceptive"},'
			.. '{"name":"ErgoptiPlus-linux-noarch.rpm","browser_download_url":"https://example.invalid/wrong.rpm"},'
			.. '{"name":"unrelated.zip","browser_download_url":"https://example.invalid/first.zip"}'
			.. ']}'

		helpers.assert_eq(M._select_update_asset(body), "",
			"a missing exact asset must not fall back to the first download URL")

		local real_fetch = M._fetch_releases
		local real_current_version = M.current_version
		M._fetch_releases = function(_, callback)
			callback("[" .. body .. "]", 200, nil)
			return true
		end
		M.current_version = function() return "3.0.0" end
		M.clear_cached_release()
		local available = nil
		local ok, dispatched = pcall(M.check_for_updates, "main", function(value)
			available = value
		end)
		M._fetch_releases = real_fetch
		M.current_version = real_current_version

		helpers.assert_true(ok, "the closed failure must not raise: " .. tostring(dispatched))
		helpers.assert_eq(dispatched, true)
		helpers.assert_eq(available, false,
			"a release without the exact bundle must not become installable")
		helpers.assert_eq(M.get_state(), "idle",
			"the missing canonical artifact must close the update transaction")
		helpers.assert_nil(M.get_cached_release(),
			"no arbitrary release asset may reach the cached install state")
	end)

	helpers.it("fails closed when the canonical bundle has no checksum asset", function()
		local bundle_url = "https://example.invalid/" .. M.LINUX_ASSET_NAME
		local body = '{"tag_name":"v4.0.0","assets":['
			.. '{"name":"' .. M.LINUX_ASSET_NAME .. '","browser_download_url":"'
			.. bundle_url .. '"}]}'
		local real_current_version = M.current_version
		M.current_version = function() return "3.0.0" end
		M.clear_cached_release()
		local available = M._process_release_response("[" .. body .. "]", "main")
		M.current_version = real_current_version
		helpers.assert_eq(available, false,
			"an unauthenticated release must not become installable")
		helpers.assert_eq(M.get_state(), "idle")
		helpers.assert_nil(M.get_cached_release())
	end)

	-- The stable channel asked /releases/latest, which ignores prereleases and
	-- answers 404 while no stable release exists; the check then reported
	-- "not available" for what was a missing channel.
	helpers.it("every channel reads the shared release list, never /releases/latest", function()
		local url = M.release_api_url()
		helpers.assert_eq(url, "https://api.github.com/repos/adrienm7/ergopti/releases?per_page=100",
			"the list comes from defaults.json update_check.releases_url")
		helpers.assert_eq(url:find("/releases/latest", 1, true), nil)
		for _, id in ipairs(M.CHANNELS.ids()) do
			helpers.assert_eq(select(1, M._build_fetch_request(id)), url, id .. " reads the same list")
		end
	end)

	local function release(tag, prerelease)
		return string.format('{"tag_name":"%s","prerelease":%s,"assets":['
			.. '{"name":"%s","browser_download_url":"https://example.invalid/%s/bundle"},'
			.. '{"name":"%s","browser_download_url":"https://example.invalid/%s/sum"}]}',
			tag, tostring(prerelease), M.LINUX_ASSET_NAME, tag, M.LINUX_CHECKSUM_ASSET_NAME, tag)
	end

	helpers.it("keeps each channel's latest release from the publish-ordered list", function()
		local list = "[" .. table.concat({
			release("v0.0.0-dev.134", true), release("v1.2.0", false),
			release("v1.3.0-beta.1", true), release("v0.0.0-dev.133", true), release("v1.1.0", false),
		}, ",") .. "]"
		local Parser = require("updater.release_parser")
		helpers.assert_eq(Parser.parse_tag(M._select_channel_release(list, "main")), "v1.2.0",
			"the stable channel keeps its latest stable release, not the newest publication")
		helpers.assert_eq(Parser.parse_tag(M._select_channel_release(list, "dev")), "v0.0.0-dev.134")
		helpers.assert_nil(M._select_channel_release("[" .. release("v0.0.0-dev.134", true) .. "]", "main"),
			"a list without a stable release has no stable candidate")
		helpers.assert_nil(M._select_channel_release('{"message":"rate limited"}', "main"),
			"an API error object is no release list")
	end)

	helpers.it("a switch to dev offers the dev build over an installed stable", function()
		local real_current_version = M.current_version
		M.current_version = function() return "1.2.0" end
		M.clear_cached_release()
		local ok, available = pcall(M._process_release_response,
			"[" .. release("v0.0.0-dev.10", true) .. "," .. release("v1.2.0", false) .. "]", "dev")
		local cached = M.get_cached_release()
		M.current_version = real_current_version
		helpers.assert_true(ok, tostring(available))
		helpers.assert_eq(available, true,
			"an explicit channel change migrates to that channel's family (same rule as Windows)")
		helpers.assert_eq(cached and cached.tag, "v0.0.0-dev.10")
		M.clear_cached_release()
	end)

	helpers.it("a dev tag never satisfies the stable channel", function()
		local real_current_version = M.current_version
		M.current_version = function() return "0.0.0-dev.5" end
		M.clear_cached_release()
		local available = M._process_release_response("[" .. release("v0.0.0-dev.99", true) .. "]", "main")
		M.current_version = real_current_version
		helpers.assert_eq(available, false)
		helpers.assert_nil(M.get_cached_release())
	end)

	helpers.it("releases_page_url returns a github.com URL", function()
		local url = M.releases_page_url()
		helpers.assert_true(url:find("github.com") ~= nil, "should be a GitHub URL")
		helpers.assert_true(url:find("/releases") ~= nil, "should point to releases page")
	end)

	helpers.it("INTERVAL_PRESETS has expected structure", function()
		helpers.assert_true(#M.INTERVAL_PRESETS >= 5, "should have at least 5 presets")
		for _, p in ipairs(M.INTERVAL_PRESETS) do
			helpers.assert_true(type(p.code) == "string", "each preset should have a code")
			helpers.assert_true(type(p.seconds) == "number", "each preset should have seconds")
			helpers.assert_true(p.seconds >= 0, "seconds should be non-negative")
		end
		-- Verify the "never" preset exists with seconds=0.
		local has_never = false
		for _, p in ipairs(M.INTERVAL_PRESETS) do
			if p.seconds == 0 then has_never = true end
		end
		helpers.assert_true(has_never, "should have a 'never' preset with seconds=0")
	end)

	helpers.it("get_state returns a valid state initially", function()
		local state = M.get_state()
		helpers.assert_true(state == "idle" or state == "checking" or state == "available",
			"state should be a valid value, got: " .. tostring(state))
	end)

	helpers.it("get_cached_release returns nil initially", function()
		local rel = M.get_cached_release()
		helpers.assert_nil(rel, "should return nil when no check has succeeded")
	end)

	helpers.it("the channel defaults to the installed build's registry channel", function()
		helpers.assert_eq(M.get_channel(), M.installed_channel())
		helpers.assert_true(M.CHANNELS.channel(M.get_channel()) ~= nil,
			"the default must be a channel of the shared registry, not a second vocabulary")
		local real_current_version = M.current_version
		M.current_version = function() return "1.4.2" end
		local stable = M.installed_channel()
		M.current_version = function() return "0.0.0-dev.133" end
		local dev = M.installed_channel()
		M.current_version = function() return "local" end
		local source = M.installed_channel()
		M.current_version = real_current_version
		helpers.assert_eq(stable, "main")
		helpers.assert_eq(dev, "dev")
		helpers.assert_eq(source, M.CHANNELS.unreleased_build_channel,
			"a source checkout follows the registry's unreleased-build channel")
	end)

	--- Runs a body against a fresh manager bound to a temporary config.toml.
	local function with_config(initial, body)
		local path = os.tmpname()
		pcall(os.remove, path)
		if initial then
			local handle = assert(io.open(path, "w"))
			handle:write(initial)
			handle:close()
		end
		local previous = package.loaded["modules.updater.manager"]
		package.loaded["modules.updater.manager"] = nil
		local fresh = require("modules.updater.manager")
		local ok, err = pcall(function()
			fresh.init({ config_path = path })
			fresh.stop_background_checks()
			body(fresh, path)
		end)
		fresh.stop_background_checks()
		package.loaded["modules.updater.manager"] = previous
		pcall(os.remove, path)
		if not ok then error(err, 0) end
	end

	local function read_config(path)
		local handle = io.open(path, "r")
		if not handle then return nil end
		local decoded = require("toml_codec").decode(handle:read("*a"))
		handle:close()
		return decoded
	end

	helpers.it("set_channel persists [updater] channel in config.toml", function()
		with_config(nil, function(fresh, path)
			helpers.assert_true(fresh.set_channel("dev"), "a registry channel is accepted")
			helpers.assert_eq(fresh.get_channel(), "dev")
			helpers.assert_eq(read_config(path).updater.channel, "dev",
				"the channel lives in config.toml like on the other drivers")
			helpers.assert_true(fresh.set_channel("main"))
			helpers.assert_eq(read_config(path).updater.channel, "main")
		end)
	end)

	helpers.it("set_channel refuses aliases and ids outside the registry", function()
		with_config(nil, function(fresh)
			local before = fresh.get_channel()
			for _, value in ipairs({ "stable", "unknown_channel", "Main" }) do
				helpers.assert_eq(fresh.set_channel(value), false, value .. " must be refused")
				helpers.assert_eq(fresh.get_channel(), before, value .. " must not change the channel")
			end
		end)
	end)

	helpers.it("init reads the persisted channel through the registry", function()
		with_config('[updater]\nchannel = "stable"\n', function(fresh)
			helpers.assert_eq(fresh.get_channel(), "main", "the old 'stable' spelling reads as main")
		end)
		with_config('[updater]\nchannel = "dev"\n', function(fresh)
			helpers.assert_eq(fresh.get_channel(), "dev")
		end)
		with_config('[updater]\nchannel = "beta"\n', function(fresh)
			helpers.assert_eq(fresh.get_channel(), fresh.installed_channel(),
				"an unknown value follows the installed build's channel")
		end)
	end)

	helpers.it("set_check_interval and get_check_interval round-trip through config.toml", function()
		with_config(nil, function(fresh, path)
			helpers.assert_true(fresh.set_check_interval(3600))
			helpers.assert_eq(fresh.get_check_interval(), 3600, "interval should be 3600")
			helpers.assert_eq(read_config(path).updater.check_interval_seconds, 3600,
				"the interval lives in config.toml like on the other drivers")
		end)
	end)

	helpers.it("set_check_interval rejects negative values", function()
		local orig = M.get_check_interval()
		M.set_check_interval(-10)
		helpers.assert_eq(M.get_check_interval(), orig, "interval should not change on negative")
	end)

	helpers.it("keeps the durable channel and interval when persistence fails", function()
		local previous_storage = package.loaded["adapters.storage"]
		local previous_manager = package.loaded["modules.updater.manager"]
		local storage = Fakes.storage({ writes_fail = true })
		package.loaded["adapters.storage"] = storage
		package.loaded["modules.updater.manager"] = nil
		local failing = require("modules.updater.manager")
		-- A config.toml whose directory does not exist: the writer must refuse.
		local unwritable = os.tmpname() .. "-missing-dir/config.toml"
		failing.init({ config_path = unwritable })
		local before = failing.get_channel()
		local target = before == "dev" and "main" or "dev"

		local channel_changed = failing.set_channel(target)
		local interval_changed = failing.set_check_interval(3600)
		local channel = failing.get_channel()
		local interval = failing.get_check_interval()
		failing.stop_background_checks()

		package.loaded["adapters.storage"] = previous_storage
		package.loaded["modules.updater.manager"] = previous_manager
		helpers.assert_eq(channel_changed, false)
		helpers.assert_eq(interval_changed, false)
		helpers.assert_eq(channel, before, "a failed write must not switch the live release feed")
		helpers.assert_eq(interval, failing.DEFAULT_INTERVAL_SEC, "a failed write must not change the live schedule")
	end)

	helpers.it("clear_cached_release resets state to idle", function()
		M.clear_cached_release()
		helpers.assert_eq(M.get_state(), "idle", "state should be idle after clear")
		helpers.assert_nil(M.get_cached_release(), "cached release should be nil after clear")
	end)

	helpers.it("refuses to download a release other than the one the user chose", function()
		M._test_set_cached_release({ tag = "v2", download_url = "https://example.invalid/2.tar.gz",
			checksum_url = "https://example.invalid/2.sha256" })
		local answered = nil
		local dispatched = M.download_update("https://example.invalid/1.tar.gz", function(path, err)
			answered = { path = path, err = err }
		end)
		helpers.assert_true(dispatched == false, "a stale consent must not start a download")
		helpers.assert_true(answered ~= nil and answered.path == nil, "the caller learns the download was refused")
		M.clear_cached_release()
	end)

	helpers.it("get_menu_label returns a string for every state", function()
		-- Should return a non-empty string even without having checked.
		local label = M.get_menu_label()
		helpers.assert_true(type(label) == "string", "menu label should be a string")
		helpers.assert_true(#label > 0, "menu label should not be empty")
	end)

	-- Every one of these labels was hardcoded French, so a user on any of the
	-- other 20 locales read French in the update menu. "not empty" above could
	-- never have caught that, and neither can it catch i18n.get echoing the raw
	-- key back on a miss.
	helpers.it("the idle label comes from the shared catalogue", function()
		local i18n = require("infra.i18n")
		M.clear_cached_release()
		local label = M.get_menu_label()
		-- The registry channel is displayed on its own checked row.
		local expected = i18n.get("menu.about.check_for_updates")
		helpers.assert_eq(label, expected,
			"the idle label must be whatever the catalogue says for the active locale")
		helpers.assert_true(label ~= "menu.about.check_for_updates",
			"an echoed key means the catalogue was never reached")
	end)

	-- The row this label names runs check_for_updates. With a release cached it
	-- read "Update to <tag>", so the user clicked what looked like the update and
	-- only got another check, next to the "Download and install <tag>" row that
	-- really installs it.
	helpers.it("the check row still names a check while a release is available", function()
		local i18n = require("infra.i18n")
		M._test_set_cached_release({ tag = "v9.9.9-100%", prerelease = false })
		local label = M.get_menu_label()
		local expected = i18n.get("menu.about.check_for_updates")
		M.clear_cached_release()
		helpers.assert_eq(label, expected,
			"the row runs a check, so it must be labelled as one whatever the cached release")
		helpers.assert_true(label:find("v9.9.9-100%", 1, true) == nil,
			"the release belongs to the install row, not to the check row")
	end)

	helpers.it("stop_background_checks is safe to call even without active timers", function()
		-- Should not error.
		M.stop_background_checks()
		helpers.assert_eq(type(M.start_background_checks), "function",
			"a stop with no timers armed must leave the checks restartable")
	end)

	helpers.it("reports unavailable background scheduling instead of silently dropping checks", function()
		local previous_timer = package.loaded["adapters.timer_scheduler"]
		local previous_manager = package.loaded["modules.updater.manager"]
		package.loaded["adapters.timer_scheduler"] = {
			HAS_ASYNC = false,
			cancel = function() end,
		}
		package.loaded["modules.updater.manager"] = nil
		local unavailable = require("modules.updater.manager")
		local started = unavailable.start_background_checks(nil, 60)

		package.loaded["adapters.timer_scheduler"] = previous_timer
		package.loaded["modules.updater.manager"] = previous_manager
		helpers.assert_eq(started, false,
			"missing luv must be a truthful unavailable capability, not a green schedule")
	end)

	helpers.it("reports a schedule whose timer was not armed", function()
		local previous_timer = package.loaded["adapters.timer_scheduler"]
		local previous_manager = package.loaded["modules.updater.manager"]
		local timer = { HAS_ASYNC = true }
		function timer.after() return { id = "refused", armed = false, fired = true } end
		function timer.cancel(handle)
			handle.armed = false
			return true
		end
		package.loaded["adapters.timer_scheduler"] = timer
		package.loaded["modules.updater.manager"] = nil
		local refused = require("modules.updater.manager")
		refused.current_version = function() return "1.0.0" end
		local started = refused.start_background_checks()

		package.loaded["adapters.timer_scheduler"] = previous_timer
		package.loaded["modules.updater.manager"] = previous_manager
		helpers.assert_eq(started, false, "a refused timer must not read as a running schedule")
	end)

	helpers.it("init loads persisted settings and initialises", function()
		local path = os.tmpname()
		pcall(os.remove, path)
		local expected = M.installed_channel()
		M.init({ config_path = path })
		helpers.assert_eq(M.get_channel(), expected,
			"init with no opts must not silently move the user off their release channel")
		-- Channel should still be the same.
		local ch = M.get_channel()
		helpers.assert_true(M.CHANNELS.channel(ch) ~= nil, "channel should be a registry channel after init")
	end)

	helpers.it("check_for_updates dispatches and publishes asynchronously", function()
		local real_fetch = M._fetch_releases
		local pending = nil
		M._fetch_releases = function(_, callback)
			pending = callback
			return true
		end
		M.clear_cached_release()
		local completions = 0
		local completion_error = nil
		local dispatched = M.check_for_updates("main", function(_, _, err)
			completions = completions + 1
			completion_error = err
		end)
		helpers.assert_eq(dispatched, true)
		helpers.assert_eq(completions, 0,
			"dispatch must return before the network completion")
		helpers.assert_eq(type(pending), "function")
		pending(nil, 0, "offline")
		M._fetch_releases = real_fetch
		helpers.assert_eq(completions, 1)
		helpers.assert_eq(completion_error, "offline")
		helpers.assert_eq(M.get_state(), "idle")
	end)

	for _, mode in ipairs({ "transport", "conditional-transport", "conditional-false", "conditional-number", "conditional-table", "http-error", "invalid-json", "wrong-root", "oversized-page", "entries-mismatch", "dispatch-refusal", "cancel" }) do
		helpers.it("linux-updater-etag: " .. mode .. " forces a fresh page after an unknown native validator", function()
			local previous_fs, previous_manager = package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"]
			local real_fs = require("adapters.file_system")
			package.loaded["adapters.file_system"] = setmetatable({ exists = function() return true end }, { __index = real_fs })
			package.loaded["modules.updater.manager"] = nil
			local loaded, fresh = pcall(require, "modules.updater.manager")
			package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"] = previous_fs, previous_manager
			helpers.assert_true(loaded and type(fresh) == "table", tostring(fresh))
			local old = '[{"tag_name":"v1.0.0"}]'
			local new = '[{"tag_name":"v2.0.0"}]'
			local too_many = {}
			for _ = 1, 21 do too_many[#too_many + 1] = '{"tag_name":"v2.0.0"}' end
			local failure = {
				transport = { ok = false, status = 200, body = "", error = "truncated native transfer" },
				["conditional-transport"] = { ok = false, status = 304, body = "", error = "HTTP 304" },
				["conditional-false"] = { ok = false, status = 304, body = "", error = "HTTP 304", error_body = false },
				["conditional-number"] = { ok = false, status = 304, body = "", error = "HTTP 304", error_body = 0 },
				["conditional-table"] = { ok = false, status = 304, body = "", error = "HTTP 304", error_body = {} },
				["http-error"] = { ok = false, status = 503, body = "", error = "HTTP 503" },
				["invalid-json"] = { ok = true, status = 200, body = "{malformed" },
				["wrong-root"] = { ok = true, status = 200, body = '{"tag_name":"v2.0.0"}' },
				["oversized-page"] = { ok = true, status = 200, body = "[" .. table.concat(too_many, ",") .. "]" },
				["entries-mismatch"] = { ok = true, status = 200, body = '["not a release object"]' },
			}
			local requests, completions = {}, {}
			fresh._http_client = {
				get = function(_, _, options, callback)
					requests[#requests + 1] = options
					if #requests == 1 then callback(etag_response({ ok = true, status = 200, body = old },
						"https://etag-fixture.invalid/releases/page-1", '"OLD"', false))
					elseif #requests == 2 then
						if mode == "dispatch-refusal" then return false end
						if mode == "cancel" then return true end
						callback(failure[mode])
					else callback(etag_response({ ok = true, status = 200, body = new },
						"https://etag-fixture.invalid/releases/page-1", '"NEW"', false)) end
					return true
				end,
				cancel = function() return true end,
			}
			fresh._http_client = require("tests.support.release_http_fixture").attach(fresh._http_client)
			fresh._file_digest = { cancel = function() return true end }
			for index = 1, 3 do
				local count = 0
				fresh._fetch_releases("main", function(body, status, err, reason)
					completions[index] = { body = body, status = status, error = err, reason = reason }; count = count + 1
				end)
				if mode == "cancel" and index == 2 then helpers.assert_true(fresh.cancel_update()) end
				helpers.assert_eq(count, 1)
			end
			helpers.assert_nil(requests[1].etag_compare)
			helpers.assert_eq(requests[1].etag_affinity, true, "cold pages explicitly request final-endpoint evidence")
			helpers.assert_true(requests[2].etag_compare ~= nil, "accepted page retains its conditional association")
			helpers.assert_nil(requests[3].etag_compare, "failed page cannot associate a changed validator with its old body")
			helpers.assert_eq(completions[1].body, old)
			helpers.assert_nil(completions[2].body)
			helpers.assert_true(type(completions[2].error) == "string")
			if mode:match("^conditional%-") then
				helpers.assert_eq(completions[2].status, 304)
				helpers.assert_eq(completions[2].reason, "no_connection")
			end
			helpers.assert_eq(completions[3].body, new)
			helpers.assert_eq(completions[3].status, 200)
		end)
	end

	helpers.it("linux-updater-etag: a failed second page keeps the accepted first-page association", function()
		local previous_fs, previous_manager = package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"]
		local real_fs = require("adapters.file_system")
		package.loaded["adapters.file_system"] = setmetatable({ exists = function() return true end }, { __index = real_fs })
		package.loaded["modules.updater.manager"] = nil
		local loaded, fresh = pcall(require, "modules.updater.manager")
		package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"] = previous_fs, previous_manager
		helpers.assert_true(loaded and type(fresh) == "table", tostring(fresh))
		local entries = {}
		for index = 1, 20 do entries[index] = '{"tag_name":"v1.0.' .. index .. '"}' end
		local first_page = "[" .. table.concat(entries, ",") .. "]"
		local final_page = '[{"tag_name":"v2.0.0"}]'
		local responses = {
			{ ok = true, status = 200, body = first_page }, { ok = true, status = 200, body = '[{"tag_name":"v1.0.21"}]' },
			{ ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" }, { ok = false, status = 200, body = "", error = "truncated page" },
			{ ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" }, { ok = true, status = 200, body = final_page },
		}
		local page_one, page_two = "https://etag-fixture.invalid/releases/page-1", "https://etag-fixture.invalid/releases/page-2"
		etag_response(responses[1], page_one, '"PAGE-ONE"', false)
		etag_response(responses[2], page_two, '"PAGE-TWO"', false)
		etag_response(responses[3], page_one, '"PAGE-ONE"', true)
		etag_response(responses[5], page_one, '"PAGE-ONE"', true)
		etag_response(responses[6], page_two, '"PAGE-TWO-NEW"', false)
		local requests, results = {}, {}
		fresh._http_client = { get = function(_, _, options, callback)
			requests[#requests + 1] = options; callback(assert(table.remove(responses, 1))); return true
		end }
		fresh._http_client = require("tests.support.release_http_fixture").attach(fresh._http_client)
		for index = 1, 3 do
			local callbacks = 0
			helpers.assert_true(fresh._fetch_releases("main", function(body, status, err)
				results[index] = { body = body, status = status, error = err }; callbacks = callbacks + 1
			end))
			helpers.assert_eq(callbacks, 1)
		end
		helpers.assert_eq(#requests, 6)
		helpers.assert_nil(results[2].body)
		helpers.assert_true(type(results[2].error) == "string")
		helpers.assert_true(requests[5].etag_compare ~= nil, "an accepted earlier page keeps its own validator")
		helpers.assert_nil(requests[6].etag_compare, "the failed page alone must refetch fully")
		helpers.assert_true(results[3].body:find("v1.0.20", 1, true) ~= nil and results[3].body:find("v2.0.0", 1, true) ~= nil)
		helpers.assert_eq(results[3].status, 200)
	end)

	-- GitHub answers 304 Not Modified, with no body, when the list is unchanged
	-- since the ETag curl saved. check_for_updates cleared the cached release
	-- before fetching and a 304 then read as "nothing available": an update
	-- vanished at the next check, and a manual check said there was none.
	helpers.it("a 304 keeps the release the previous 200 found available", function()
		local real_fs = require("adapters.file_system")
		local previous_fs = package.loaded["adapters.file_system"]
		local previous_manager = package.loaded["modules.updater.manager"]
		-- The ETag cache directory exists, so the request is conditional as soon
		-- as the list it names is held.
		package.loaded["adapters.file_system"] = setmetatable({
			exists = function() return true end,
		}, { __index = real_fs })
		package.loaded["modules.updater.manager"] = nil
		local fresh = require("modules.updater.manager")
		package.loaded["adapters.file_system"] = previous_fs
		package.loaded["modules.updater.manager"] = previous_manager

		local list = "[" .. release("v0.0.0-dev.140", true) .. "," .. release("v1.2.0", false) .. "]"
		local responses = {
			{ ok = true, status = 200, body = list },
			{ ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" },
		}
		etag_response(responses[1], "https://etag-fixture.invalid/releases/page-1", '"AVAILABLE"', false)
		etag_response(responses[2], "https://etag-fixture.invalid/releases/page-1", '"AVAILABLE"', true)
		local requests = {}
		fresh._http_client = {
			get = function(_, _, options, callback)
				requests[#requests + 1] = options
				callback(table.remove(responses, 1))
				return true
			end,
			cancel = function() return true end,
		}
		fresh._http_client = require("tests.support.release_http_fixture").attach(fresh._http_client)
		fresh.current_version = function() return "local" end

		local results = {}
		for _ = 1, 2 do
			fresh.check_for_updates("main", function(available, release, err)
				results[#results + 1] = { available = available, tag = release and release.tag, err = err }
			end)
		end

		helpers.assert_eq(#requests, 2, "two checks, two requests")
		helpers.assert_nil(requests[1].etag_compare,
			"without the list an ETag names, the first request must be unconditional")
		helpers.assert_true(requests[1].etag_save ~= nil, "the first answer's ETag is saved")
		helpers.assert_true(requests[2].etag_compare ~= nil, "the second request is conditional")
		helpers.assert_eq(results[1].available, true, "the 200 finds the release")
		helpers.assert_eq(results[2].available, true, "the 304 keeps it available")
		helpers.assert_eq(results[2].tag, results[1].tag, "the same release stays cached")
		helpers.assert_eq(fresh.get_state(), "available")
		helpers.assert_eq(fresh.get_cached_release().tag, "v1.2.0")
	end)

	helpers.it("builds a bounded HTTPS release request for the updater owner", function()
		helpers.assert_true(type(M._build_fetch_request) == "function")
		local url, headers, options = M._build_fetch_request("main")
		helpers.assert_contains(url, "https://api.github.com/")
		helpers.assert_eq(headers.Accept, "application/vnd.github+json")
		helpers.assert_eq(options.owner, "updater")
		helpers.assert_eq(options.https_only, true)
		helpers.assert_eq(options.follow_redirects, true)
		helpers.assert_true(options.timeout_ms > 0)
		helpers.assert_true(options.max_body_bytes >= 1024)
	end)

	-- ========================================
	-- ======= 1b/ install_update transaction =
	-- ========================================

	local function shell_quote(value)
		return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
	end

	local function command_ok(command)
		return Installer._status_ok(os.execute(command))
	end

	local function write_file(path, content)
		local handle = assert(io.open(path, "w"))
		handle:write(content)
		handle:close()
	end

	local function read_file(path)
		local handle = io.open(path, "r")
		if not handle then return nil end
		local content = handle:read("*a")
		handle:close()
		return content
	end

	helpers.it("accepts only a checksum record bound to the canonical filename", function()
		local expected = string.rep("ab", 32)
		local parsed = M._parse_checksum(expected .. "  " .. M.LINUX_ASSET_NAME .. "\n")
		helpers.assert_eq(parsed, expected)
		local wrong, wrong_error = M._parse_checksum(expected .. "  unrelated.tar.gz\n")
		helpers.assert_nil(wrong)
		helpers.assert_contains(wrong_error, "canonical Linux bundle")
		local extra = M._parse_checksum(expected .. "  " .. M.LINUX_ASSET_NAME
			.. "\n" .. expected .. "  second.tar.gz\n")
		helpers.assert_nil(extra, "a multi-record manifest must not be partially trusted")
	end)

	helpers.it("refuses to install a local archive that bypassed verification", function()
		local archive = os.tmpname()
		write_file(archive, "unverified fixture")
		M._test_set_cached_release({ tag = "v4.0.0", prerelease = false })
		local installed = M.install_update(archive)
		local content = read_file(archive)
		Fs.delete(archive)
		M.clear_cached_release()
		helpers.assert_eq(installed, false)
		helpers.assert_eq(content, "unverified fixture",
			"refusal must happen before the installer can mutate the archive")
	end)

	for _, suffix in ipairs({ ".tar.gz", ".tar.gz.part" }) do
		for _, alias in ipairs({ "regular", "dangling" }) do
			helpers.it("linux-updater-temp-ownership: preserves unrelated " .. alias .. " " .. suffix, function()
				with_native_download_model(function(prepare_owned_http)
				M.cancel_update()
				local base = os.tmpname()
				local candidate, target = base .. suffix, base .. ".missing"
				local history = "Retained unrelated temporary bytes"
				if alias == "regular" then write_file(candidate, history)
				else helpers.assert_true(command_ok("ln -s -- " .. shell_quote(target) .. " " .. shell_quote(candidate))) end
				local real_tmpname, real_http = os.tmpname, M._http_client
				local callbacks, completion_error = 0, nil
				os.tmpname = function() return base end
				M._http_client = {
					get = function(_, _, _, callback)
						callback({ ok = false, status = 503, error = "synthetic checksum failure" })
						return true
					end,
					download = function() error("failed checksum must not download an archive") end,
					cancel = function() return true end,
				}
				prepare_owned_http()
				local ok, err = xpcall(function()
					helpers.assert_true(M.download_release({ tag = "v4.0.0", download_url = "https://example.invalid/archive",
						checksum_url = "https://example.invalid/checksum" }, function(path, failure)
						callbacks = callbacks + 1; completion_error = failure; helpers.assert_nil(path)
					end))
					helpers.assert_eq(callbacks, 1)
					helpers.assert_eq(completion_error, "synthetic checksum failure")
					if alias == "regular" then helpers.assert_eq(read_file(candidate), history)
					else
						helpers.assert_true(command_ok("test -L " .. shell_quote(candidate)))
						helpers.assert_nil(io.open(target, "r"))
					end
					helpers.assert_eq(M.get_state(), "idle")
					helpers.assert_eq(Fs.exists(base), false)
				end, debug.traceback)
				os.tmpname, M._http_client = real_tmpname, real_http
				M.cancel_update()
				os.remove(base); os.remove(candidate); os.remove(target)
				helpers.assert_true(ok, tostring(err))
				end)
			end)
		end
	end

	for _, api in ipairs({ "update", "release" }) do
		for _, wants_callback in ipairs({ true, false }) do
			helpers.it("linux-updater-temp-allocation: " .. api .. " acknowledges allocator refusal with callback " .. tostring(wants_callback), function()
				with_native_download_model(function(prepare_owned_http)
				M.cancel_update()
				local release = { tag = "v4.0.0", download_url = "https://example.invalid/archive",
					checksum_url = "https://example.invalid/checksum" }
				M._test_set_cached_release(release)
				local real_tmpname, real_http = os.tmpname, M._http_client
				os.tmpname = function() error("synthetic native allocator refusal") end
				M._http_client = { get = function() error("allocation refusal must precede HTTP") end, cancel = function() return true end }
				local callbacks, received_error = 0, nil
				local callback
				if wants_callback then callback = function(path, err) callbacks = callbacks + 1; received_error = err; helpers.assert_nil(path) end end
				prepare_owned_http()
				local ok, err = xpcall(function()
					local dispatched
					if api == "update" then dispatched = M.download_update(nil, callback)
					else dispatched = M.download_release(release, callback) end
					helpers.assert_eq(dispatched, false)
					helpers.assert_eq(callbacks, wants_callback and 1 or 0)
					if wants_callback then helpers.assert_eq(received_error, "temporary path unavailable") end
					helpers.assert_eq(M.get_state(), "available")
					helpers.assert_eq(M.get_cached_release().tag, release.tag)
				end, debug.traceback)
				os.tmpname, M._http_client = real_tmpname, real_http
				M.cancel_update()
				helpers.assert_true(ok, tostring(err))
				end)
			end)
		end
	end

	helpers.it("linux-digest-owner: downloads and hashes a verified archive under the updater owner", function()
		with_native_download_model(function(prepare_owned_http)
		local real_http = M._http_client
		local real_digest = M._file_digest
		local expected = string.rep("cd", 32)
		local downloaded_part = nil
		local http = {}
		function http.get(_, _, _, callback)
			callback({
				ok = true,
				status = 200,
				body = expected .. "  " .. M.LINUX_ASSET_NAME .. "\n",
			})
			return true
		end
		function http.download(_, _, destination, _, callback)
			downloaded_part = destination
			write_file(destination, "verified fixture archive")
			callback({ ok = true, status = 200, body = "" })
			return true
		end
		function http.cancel() return true end
		local digest = {
			sha256 = function(path, options, callback)
				helpers.assert_eq(path, downloaded_part)
				helpers.assert_eq(options.owner, "updater", "the archive digest must have the same owner as cancellation")
				callback(expected, nil)
				return true
			end,
			cancel = function() return true end,
		}
		M._http_client = http
		M._file_digest = digest
		M._test_set_cached_release({
			tag = "v4.0.0",
			prerelease = false,
			download_url = "https://example.invalid/" .. M.LINUX_ASSET_NAME,
			checksum_url = "https://example.invalid/" .. M.LINUX_CHECKSUM_ASSET_NAME,
		})
		local verified_path = nil
		local completion_error = nil
		prepare_owned_http()
		local ok, dispatched = pcall(M.download_update, nil, function(path, err)
			verified_path = path
			completion_error = err
		end)
		M._http_client = real_http
		M._file_digest = real_digest

		helpers.assert_true(ok, "verified download raised: " .. tostring(dispatched))
		helpers.assert_eq(dispatched, true)
		helpers.assert_eq(completion_error, nil)
		helpers.assert_true(type(verified_path) == "string" and Fs.exists(verified_path))
		helpers.assert_true(not Fs.exists(downloaded_part),
			"the owned partial path must be renamed after verification")
		helpers.assert_eq(M.get_state(), "available")
		Fs.delete(verified_path)
		M.clear_cached_release()
		end)
	end)

	helpers.it("removes a downloaded archive when SHA-256 does not match", function()
		with_native_download_model(function(prepare_owned_http)
		local real_http = M._http_client
		local real_digest = M._file_digest
		local expected = string.rep("ef", 32)
		local downloaded_part = nil
		local http = {}
		function http.get(_, _, _, callback)
			callback({ ok = true, status = 200,
				body = expected .. "  " .. M.LINUX_ASSET_NAME .. "\n" })
			return true
		end
		function http.download(_, _, destination, _, callback)
			downloaded_part = destination
			write_file(destination, "tampered fixture archive")
			callback({ ok = true, status = 200, body = "" })
			return true
		end
		function http.cancel() return true end
		local digest = {
			sha256 = function(_, _, callback)
				callback(string.rep("00", 32), nil)
				return true
			end,
			cancel = function() return true end,
		}
		M._http_client = http
		M._file_digest = digest
		M._test_set_cached_release({
			tag = "v4.0.0",
			prerelease = false,
			download_url = "https://example.invalid/" .. M.LINUX_ASSET_NAME,
			checksum_url = "https://example.invalid/" .. M.LINUX_CHECKSUM_ASSET_NAME,
		})
		local verified_path = nil
		local completion_error = nil
		prepare_owned_http()
		local ok, dispatched = pcall(M.download_update, nil, function(path, err)
			verified_path = path
			completion_error = err
		end)
		M._http_client = real_http
		M._file_digest = real_digest

		helpers.assert_true(ok, "checksum rejection raised: " .. tostring(dispatched))
		helpers.assert_eq(dispatched, true)
		helpers.assert_nil(verified_path)
		helpers.assert_contains(completion_error, "checksum mismatch")
		helpers.assert_true(not Fs.exists(downloaded_part),
			"a mismatched partial archive must be removed")
		helpers.assert_true(not Fs.exists(downloaded_part .. ".tar.gz"),
			"a mismatched archive must never be published")
		helpers.assert_eq(M.get_state(), "idle")
		M.clear_cached_release()
		end)
	end)

	helpers.it("cancel-update: a verified archive does not survive cancellation", function()
		-- Regression: cancel_update() cleared partial downloads but left a
		-- verified archive on disk with state "available", so install_update()
		-- still succeeded after the user — or the shutdown coordinator —
		-- requested cancellation.
		local real_http = M._http_client
		local real_digest = M._file_digest
		M._http_client = { cancel = function() return true end }
		M._file_digest = { cancel = function() return true end }
		local archive = os.tmpname()
		write_file(archive, "verified fixture archive")
		local ok, err = pcall(function()
			M._test_set_verified_archive(archive)
			helpers.assert_eq(M.get_state(), "available",
				"precondition: the archive is verified and installable")
			helpers.assert_true(M.cancel_update(), "cancel must succeed")
			helpers.assert_eq(M.get_state(), "idle",
				"cancel must leave no available update behind")
			helpers.assert_true(not Fs.exists(archive),
				"the verified archive must be deleted with the cancellation")
			helpers.assert_eq(M.install_update(archive), false,
				"a cancelled archive must no longer install")
		end)
		M._http_client = real_http
		M._file_digest = real_digest
		Fs.delete(archive)
		M.clear_cached_release()
		if not ok then error(err, 0) end
	end)

	helpers.it("normalises LuaJIT numeric process failures", function()
		helpers.assert_eq(Installer._status_ok(0), true)
		helpers.assert_eq(Installer._status_ok(256), false,
			"a numeric non-zero shell status is truthy in Lua but must remain failure")
		helpers.assert_eq(Installer._status_ok(true, "exit", 0), true)
		helpers.assert_eq(Installer._status_ok(nil, "exit", 1), false)
	end)

	helpers.it("resolves the complete standalone root and delegates flat package layouts", function()
		local standalone = Installer.resolve(
			"/opt/ergopti-prefix/lib/ergopti/linux/modules/updater/manager.lua",
			function() return true end
		)
		helpers.assert_eq(standalone.kind, "standalone")
		helpers.assert_eq(standalone.install_root, "/opt/ergopti-prefix/lib/ergopti")
		helpers.assert_eq(standalone.parent, "/opt/ergopti-prefix/lib")
		helpers.assert_eq(standalone.wrapper, "/opt/ergopti-prefix/bin/ergopti-hotstrings")

		local package_install = Installer.resolve(
			"/usr/lib/ergopti/modules/updater/manager.lua",
			function() return true end
		)
		helpers.assert_eq(package_install.kind, "package",
			".deb, RPM, Flatpak, AppImage and Nix layouts must keep their update owner")
	end)

	helpers.it("linux-native-cwd: updater shares the actual cwd owner for a relative source", function()
		local Paths = require("infra.paths")
		local installer = helpers.load_module("modules.updater.installer")
		local real_cwd, real_getenv = Paths.current_directory, os.getenv
		Paths.current_directory = function() return "/synthetic/prefix/lib/ergopti" end
		os.getenv = function(key) if key == "PWD" then return "/synthetic/stale" end; return real_getenv(key) end
		local ok, context = pcall(installer.resolve, "linux/modules/updater/manager.lua", function() return true end)
		Paths.current_directory, os.getenv = real_cwd, real_getenv
		helpers.assert_true(ok, tostring(context))
		helpers.assert_eq(context.kind, "standalone")
		helpers.assert_eq(context.install_root, "/synthetic/prefix/lib/ergopti")
		helpers.assert_eq(context.wrapper, "/synthetic/prefix/bin/ergopti-hotstrings")
	end)

	for _, component in ipairs({ "literal\\backslash", "double\\\\backslash", "\\leading" }) do
		helpers.it("linux-native-path-literal: updater keeps POSIX component " .. component, function()
			local real_config = package.config
			package.config = "/" .. real_config:sub(2)
			local prefix = "/synthetic/" .. component
			local ok, context = pcall(Installer.resolve, prefix .. "/lib/ergopti/linux/modules/updater/manager.lua",
				function() return true end)
			package.config = real_config
			helpers.assert_true(ok, tostring(context))
			helpers.assert_eq(context.kind, "standalone")
			helpers.assert_eq(context.install_root, prefix .. "/lib/ergopti")
			helpers.assert_eq(context.wrapper, prefix .. "/bin/ergopti-hotstrings")
		end)
	end

	helpers.it("upgrades the complete standalone root and keeps a verified backup", function()
		local base = os.tmpname():gsub("\\", "/")
		os.remove(base)
		helpers.assert_true(base:match("^/tmp/") ~= nil, "fixture must stay under /tmp")
		local prefix = base .. "/prefix"
		local install_root = prefix .. "/lib/ergopti"
		local wrapper = prefix .. "/bin/ergopti-hotstrings"
		local payload = base .. "/payload"
		local archive = base .. "/release.tar.gz"
		helpers.assert_true(command_ok("mkdir -p " .. shell_quote(install_root .. "/linux/infra")
			.. " " .. shell_quote(install_root .. "/linux/install")
			.. " " .. shell_quote(install_root .. "/_shared/lua")
			.. " " .. shell_quote(prefix .. "/bin")
			.. " " .. shell_quote(payload .. "/linux/infra")
			.. " " .. shell_quote(payload .. "/linux/install")
			.. " " .. shell_quote(payload .. "/_shared/lua")
			.. " " .. shell_quote(payload .. "/_shared/data/locales")
			.. " " .. shell_quote(payload .. "/bin")))

		write_file(install_root .. "/linux/ergopti_hotstrings.lua", "print('old-driver')\n")
		write_file(install_root .. "/linux/infra/version.lua", "return {}\n")
		write_file(install_root .. "/_shared/build_stamp.txt", "commit=" .. string.rep("a", 40) .. "\nversion=3.0.0\n")
		write_file(install_root .. "/_shared/lua/sentinel.lua", "return 'old-shared'\n")
		write_file(payload .. "/linux/ergopti_hotstrings.lua", "print('new-driver')\n")
		write_file(payload .. "/linux/infra/version.lua", "return {}\n")
		write_file(payload .. "/_shared/build_stamp.txt", "commit=" .. string.rep("b", 40) .. "\nversion=4.0.0\n")
		write_file(payload .. "/_shared/lua/sentinel.lua", "return 'new-shared'\n")
		write_file(payload .. "/_shared/data/locales/en.json", "{}\n")
		write_file(payload .. "/bin/ergopti-hotstrings", "#!/usr/bin/env bash\nexit 0\n")
		write_file(payload .. "/install.sh", "#!/usr/bin/env bash\nexit 0\n")
		-- The target need not ship the running updater's receipt implementation.
		write_file(install_root .. "/linux/install/ownership.sh",
			assert(read_file(helpers.driver_root() .. "/install/ownership.sh")))
		write_file(wrapper, "#!/usr/bin/env bash\nset -euo pipefail\n"
			.. "grep -q 'version=4.0.0' " .. shell_quote(install_root .. "/_shared/build_stamp.txt") .. "\n"
			.. "grep -q 'new-shared' " .. shell_quote(install_root .. "/_shared/lua/sentinel.lua") .. "\n"
			.. "test ! -e " .. shell_quote(install_root .. "/linux/linux") .. "\n"
			.. "exec bash " .. shell_quote(install_root .. "/bin/ergopti-hotstrings") .. "\n")
		helpers.assert_true(command_ok("chmod +x " .. shell_quote(wrapper)
			.. " " .. shell_quote(payload .. "/bin/ergopti-hotstrings")
			.. " " .. shell_quote(payload .. "/install.sh")))
		helpers.assert_true(command_ok("tar -czf " .. shell_quote(archive)
			.. " -C " .. shell_quote(payload)
			.. " linux _shared bin install.sh"))

		local real_resolver = M._resolve_installation
		M._resolve_installation = function()
			return {
				kind = "standalone",
				install_root = install_root,
				parent = prefix .. "/lib",
				wrapper = wrapper,
			}
		end
		M._test_set_cached_release({ tag = "v4.0.0", prerelease = false })
		M._test_set_verified_archive(archive)
		local logger = require("logger.shim")
		local real_error = logger.error
		local errors = {}
		logger.error = function(_tag, fmt, ...)
			errors[#errors + 1] = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
		end
		local call_ok, installed = pcall(M.install_update, archive)
		M._resolve_installation = real_resolver
		logger.error = real_error

		local new_version = read_file(install_root .. "/_shared/build_stamp.txt")
		local new_shared = read_file(install_root .. "/_shared/lua/sentinel.lua")
		local old_version = read_file(install_root .. ".old/_shared/build_stamp.txt")
		local nested = read_file(install_root .. "/linux/linux/ergopti_hotstrings.lua")
		local archive_left = read_file(archive)
		local ownership = read_file(install_root .. "/.ergopti-owned-files")
		M.clear_cached_release()
		command_ok("rm -rf -- " .. shell_quote(base))

		helpers.assert_true(call_ok, "real update transaction raised: " .. tostring(installed))
		helpers.assert_eq(installed, true, table.concat(errors, " | "))
		helpers.assert_contains(new_version or "", "version=4.0.0")
		helpers.assert_contains(new_shared or "", "new-shared")
		helpers.assert_contains(old_version or "", "version=3.0.0")
		helpers.assert_nil(nested, "the archive linux/ root must not become linux/linux")
		helpers.assert_nil(archive_left, "a committed update retires its downloaded archive")
		helpers.assert_contains(ownership or "", "linux/ergopti_hotstrings.lua",
			"an updated installation must retain file ownership for uninstall")
		helpers.assert_contains(ownership or "", "bin/ergopti-hotstrings",
			"the versioned launcher must be recorded with its payload")
	end)

	helpers.it("rolls back every fallible activation stage", function()
		local root = "/tmp/ergopti-fixture/lib/ergopti"
		local parent = "/tmp/ergopti-fixture/lib"
		local work = parent .. "/.ergopti-update.fixture"
		local candidate = work .. "/candidate"
		local backup = root .. ".old"
		local stages = {
			"validate_archive", "make_work_dir", "extract", "validate_layout",
			"validate_version", "mkdir_candidate", "move_linux", "move_shared", "move_bin",
			"record_ownership", "remove_backup", "backup_current", "activate_candidate", "smoke",
		}

		for _, failed_stage in ipairs(stages) do
			local state = { root = "old", backup = "old-previous", work = true }
			local ops = {}
			function ops.validate_archive()
				return failed_stage ~= "validate_archive", "fixture archive rejection"
			end
			function ops.make_work_dir()
				if failed_stage == "make_work_dir" then return nil end
				return work
			end
			function ops.extract() return failed_stage ~= "extract" end
			function ops.record_ownership() return failed_stage ~= "record_ownership" end
			function ops.is_file() return failed_stage ~= "validate_layout" end
			function ops.is_dir() return true end
			function ops.read()
				if failed_stage == "validate_version" then return "version=9.9.9\n" end
				return "version=4.0.0\n"
			end
			function ops.mkdir() return failed_stage ~= "mkdir_candidate" end
			function ops.exists(path) return path == backup end
			function ops.remove_tree(path)
				if path == backup then
					if failed_stage == "remove_backup" then return false end
					state.backup = nil
				end
				return true
			end
			function ops.move(source_path, destination_path)
				if source_path == work .. "/linux" then return failed_stage ~= "move_linux" end
				if source_path == work .. "/_shared" then return failed_stage ~= "move_shared" end
				if source_path == work .. "/bin" then return failed_stage ~= "move_bin" end
				if source_path == root and destination_path == backup then
					if failed_stage == "backup_current" then return false end
					state.root, state.backup = nil, "old"
					return true
				end
				if source_path == candidate and destination_path == root then
					if failed_stage == "activate_candidate" then return false end
					state.root = "new"
					return true
				end
				if source_path == root and destination_path == work .. "/failed" then
					state.root = nil
					return true
				end
				if source_path == backup and destination_path == root then
					state.root, state.backup = "old", nil
					return true
				end
				return true
			end
			function ops.smoke() return failed_stage ~= "smoke" end
			function ops.remove_file() return true end

			local installed = Installer.install({
				archive_path = "/tmp/release.tar.gz",
				expected_version = "v4.0.0",
				context = { kind = "standalone", install_root = root, parent = parent, wrapper = "/tmp/bin/ergopti" },
				ops = ops,
			})
			helpers.assert_eq(installed, false, failed_stage .. " must abort the transaction")
			helpers.assert_eq(state.root, "old", failed_stage .. " must retain or restore version N")
		end
	end)

	helpers.it("delegates package-managed installations without touching the archive", function()
		local tmp_dir = os.getenv("TMPDIR") or "/tmp"
		local archive = tmp_dir:gsub("\\", "/") .. "/ergopti_package_owned_update.tar.gz"
		write_file(archive, "not-owned-by-the-runtime")
		local real_resolver = M._resolve_installation
		local real_install = Installer.install
		local installer_called = false
		M._resolve_installation = function()
			return { kind = "package", reason = "owned by the system package manager" }
		end
		Installer.install = function()
			installer_called = true
			return true
		end
		M._test_set_verified_archive(archive)
		local call_ok, installed = pcall(M.install_update, archive)
		M._resolve_installation = real_resolver
		Installer.install = real_install
		local archive_content = read_file(archive)
		os.remove(archive)
		M.clear_cached_release()

		helpers.assert_true(call_ok, "package delegation raised: " .. tostring(installed))
		helpers.assert_eq(installed, false)
		helpers.assert_eq(installer_called, false, "package content must never enter the standalone installer")
		helpers.assert_eq(archive_content, "not-owned-by-the-runtime",
			"delegation leaves the package-manager-owned transaction untouched")
	end)

	-- ========================================
	-- ======= 2/ Menu Integration ============
	-- ========================================

	helpers.it("menu_builder renders updater section when updater context is present", function()
		local ok_mb, menu_builder = pcall(require, "ui.menu.menu_builder")
		-- Asserted, not skipped. ui/menu/menu_builder.lua ships with this driver, so
		-- "not available" can only mean it stopped loading — and the skip made that
		-- indistinguishable from a pass in six cases across three files.
		helpers.assert_true(ok_mb and menu_builder ~= nil,
			"ui.menu.menu_builder must load: " .. tostring(menu_builder))

		local items = menu_builder.build({
			_version = "3.0.0",
			updater = M,
		})

		-- Find the updater item.
		local found = false
		for _, item in ipairs(items) do
			if type(item) == "table" and item.title and item.title:find("Mises") then
				found = true
				helpers.assert_true(type(item.menu) == "table", "updater should have a submenu")
				helpers.assert_true(#item.menu > 0, "updater submenu should have items")
				break
			end
		end
		helpers.assert_true(found, "menu should contain an updater section")
	end)

	helpers.it("menu_builder handles nil updater context gracefully", function()
		local ok_mb, menu_builder = pcall(require, "ui.menu.menu_builder")
		-- Asserted, not skipped. ui/menu/menu_builder.lua ships with this driver, so
		-- "not available" can only mean it stopped loading — and the skip made that
		-- indistinguishable from a pass in six cases across three files.
		helpers.assert_true(ok_mb and menu_builder ~= nil,
			"ui.menu.menu_builder must load: " .. tostring(menu_builder))

		local items = menu_builder.build({
			_version = "3.0.0",
			updater = nil,
		})

		-- Should not error — the updater section should show a disabled stub.
		local found = false
		for _, item in ipairs(items) do
			if type(item) == "table" and item.title and item.title:find("Mises") then
				found = true
				break
			end
		end
		helpers.assert_true(found, "menu should contain an updater stub when updater is nil")
	end)
end)

-- Keep the full canonical candidate horizon within bounded transport pages.

local helpers = require("tests.helpers")
local Json = require("json")

helpers.describe("updater bounded pagination", function()
	local function page(first, count)
		local entries = {}
		for i = first, first + count - 1 do
			entries[#entries + 1] = { tag_name = i == 99 and "v9.9.9" or "v0.0.0-dev." .. i, assets = {}, body = string.rep("x", 25000) }
		end
		return Json.encode(entries)
	end

	helpers.it("collects all 100 candidates through bounded pages and keeps conditional page caches", function()
		local real_fs = require("adapters.file_system")
		local controlled_fs = setmetatable({ exists = function(path)
			if path:match("/%.cache$") or path:match("/%.cache/ergopti_updater_etag_[^/]+%.txt$") then return true end
			return real_fs.exists(path)
		end }, { __index = real_fs })
		local M = helpers.load_module_with_dependency("modules.updater.manager", "adapters.file_system", controlled_fs)
		local requests, completions, result = 0, 0, nil
		local cached = false
		M._http_client = { get = function(url, _, options, cb)
			requests = requests + 1
			local index = tonumber(url:match("&page=(%d+)$"))
			helpers.assert_true(index ~= nil, "requests carry an explicit page")
			helpers.assert_contains(url, "per_page=20")
			helpers.assert_eq(options.max_body_bytes, 2 * 1024 * 1024)
			local response = cached and { ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" } or { ok = true, status = 200, body = page((index - 1) * 20 + 1, 20) }
			etag_response(response, "https://etag-fixture.invalid/releases/page-" .. index, '"PAGE-' .. index .. '"', cached)
			if cached then helpers.assert_true(options.etag_compare ~= nil, "the controlled 304 sent a cached validator") end
			cb(response)
			cb(response)
			return true
		end }
		M._http_client = require("tests.support.release_http_fixture").attach(M._http_client)
		for _ = 1, 2 do
			M._fetch_releases("dev", function(body, _, err)
				completions = completions + 1
				helpers.assert_nil(err)
				result = Json.decode(body)
			end)
			cached = true
		end
		helpers.assert_eq(requests, 10)
		helpers.assert_eq(completions, 2)
		helpers.assert_eq(#result, 100)
		helpers.assert_eq(result[100].tag_name, "v0.0.0-dev.100")
		helpers.assert_contains(M._select_channel_release(Json.encode(result), "main"), "v9.9.9")
		helpers.assert_contains(M._select_channel_release(Json.encode(result), "dev"), "v0.0.0-dev.100")
	end)

	helpers.it("refuses incomplete invalid and cancelled lists without partial success or duplicate callbacks", function()
		for _, scenario in ipairs({ "http", "dispatch", "invalid", "cancel" }) do
			local M = helpers.load_module("modules.updater.manager")
			local completions, requests, pending, received_error = 0, 0, nil, nil
			M._http_client = {
				get = function(_, _, _, cb)
					requests = requests + 1
					if requests == 1 then cb({ ok = true, status = 200, body = page(1, 20) }); return true end
					pending = cb
					if scenario == "dispatch" then return false end
					if scenario == "http" then cb({ ok = false, status = 500, error = "failed page" }) end
					if scenario == "invalid" then cb({ ok = true, status = 200, body = "[invalid]" }) end
					return true
				end,
				cancel = function() return true end,
			}
			M._http_client = require("tests.support.release_http_fixture").attach(M._http_client)
			M._file_digest = { cancel = function() return true end }
			M._fetch_releases("dev", function(body, _, err)
				completions = completions + 1
				helpers.assert_nil(body, "incomplete lists cannot be published")
				received_error = err
			end)
			if scenario == "cancel" then helpers.assert_true(M.cancel_update()) end
			pending({ ok = true, status = 200, body = page(21, 20) })
			helpers.assert_eq(requests, 2, scenario)
			helpers.assert_eq(completions, 1, scenario)
			helpers.assert_true(type(received_error) == "string", scenario)
		end
	end)
end)
