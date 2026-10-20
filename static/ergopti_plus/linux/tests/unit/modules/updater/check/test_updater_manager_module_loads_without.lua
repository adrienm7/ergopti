--- tests/unit/modules/updater/check/test_updater_manager_module_loads_without.lua

package.loaded["tests.support.modules.updater.check.updater_manager_fixture"] = nil
local Fixture = require("tests.support.modules.updater.check.updater_manager_fixture")
local helpers, with_config, read_config =
	Fixture.helpers, Fixture.with_config, Fixture.read_config




helpers.describe("modules/updater/manager.lua", function()
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

	local function release(tag, prerelease)
		return string.format('{"tag_name":"%s","prerelease":%s,"assets":['
			.. '{"name":"%s","browser_download_url":"https://example.invalid/%s/bundle"},'
			.. '{"name":"%s","browser_download_url":"https://example.invalid/%s/sum"}]}',
			tag, tostring(prerelease), M.LINUX_ASSET_NAME, tag, M.LINUX_CHECKSUM_ASSET_NAME, tag)
	end

	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "modules.updater.manager")
		helpers.assert_true(ok, "require should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

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
			.. '{"name":"ErgoptiPlus-x86_64.AppImage","browser_download_url":"https://example.invalid/wrong.AppImage"}'
			.. ']}'

		helpers.assert_eq(M._select_update_asset(body), canonical_url,
			"asset order and package kind must not affect exact selection")
		helpers.assert_eq(M._select_checksum_asset(body), checksum_url,
			"the checksum must be selected by its exact canonical name")
	end)

	helpers.it("fails closed when the canonical Linux bundle is absent", function()
		local body = '{"tag_name":"v4.0.0","assets":['
			.. '{"name":"ergopti-plus-linux.tar.gz.sig","browser_download_url":"https://example.invalid/deceptive"},'
			.. '{"name":"ErgoptiPlus-linux-x86_64.rpm","browser_download_url":"https://example.invalid/wrong.rpm"},'
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
end)

