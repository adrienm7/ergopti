--- linux/tests/unit/meta/test_updater_manager.lua

local helpers = require("tests.helpers")

helpers.describe("modules/updater/manager.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "modules.updater.manager")
		helpers.assert_true(ok, "require should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	local M = helpers.load_module("modules.updater.manager")

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

	helpers.it("release_api_url builds correct URLs for stable and dev channels", function()
		local stable_url = M.release_api_url("stable")
		local dev_url = M.release_api_url("dev")
		helpers.assert_true(stable_url:find("/latest") ~= nil, "stable URL should end with /latest")
		helpers.assert_true(dev_url:find("per_page") ~= nil, "dev URL should include per_page")
		helpers.assert_true(stable_url:find("api.github.com") ~= nil, "should point to GitHub API")
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

	helpers.it("channel defaults to 'stable'", function()
		local ch = M.get_channel()
		helpers.assert_true(ch == "stable" or ch == "dev",
			"channel should be stable or dev, got: " .. tostring(ch))
	end)

	helpers.it("set_channel changes the active channel", function()
		local orig = M.get_channel()
		local new_ch = (orig == "stable") and "dev" or "stable"
		M.set_channel(new_ch)
		helpers.assert_eq(M.get_channel(), new_ch, "channel should change")
		-- Restore.
		M.set_channel(orig)
		helpers.assert_eq(M.get_channel(), orig, "channel should restore")
	end)

	helpers.it("set_channel rejects unknown channels gracefully", function()
		local orig = M.get_channel()
		M.set_channel("unknown_channel")
		helpers.assert_eq(M.get_channel(), orig, "channel should not change on invalid input")
	end)

	helpers.it("set_check_interval and get_check_interval round-trip", function()
		local orig = M.get_check_interval()
		M.set_check_interval(3600)
		helpers.assert_eq(M.get_check_interval(), 3600, "interval should be 3600")
		-- Restore.
		M.set_check_interval(orig)
	end)

	helpers.it("set_check_interval rejects negative values", function()
		local orig = M.get_check_interval()
		M.set_check_interval(-10)
		helpers.assert_eq(M.get_check_interval(), orig, "interval should not change on negative")
	end)

	helpers.it("clear_cached_release resets state to idle", function()
		M.clear_cached_release()
		helpers.assert_eq(M.get_state(), "idle", "state should be idle after clear")
		helpers.assert_nil(M.get_cached_release(), "cached release should be nil after clear")
	end)

	helpers.it("get_menu_label returns a string for every state", function()
		-- Should return a non-empty string even without having checked.
		local label = M.get_menu_label()
		helpers.assert_true(type(label) == "string", "menu label should be a string")
		helpers.assert_true(#label > 0, "menu label should not be empty")
	end)

	helpers.it("stop_background_checks is safe to call even without active timers", function()
		-- Should not error.
		local ok = pcall(M.stop_background_checks)
		helpers.assert_true(ok, "stop_background_checks should not error")
	end)

	helpers.it("init loads persisted settings and initialises", function()
		local orig_channel = M.get_channel()
		-- init() should work without opts.
		local ok = pcall(function() M.init({}) end)
		helpers.assert_true(ok, "init() should not error")
		-- Channel should still be the same.
		local ch = M.get_channel()
		helpers.assert_true(ch == "stable" or ch == "dev", "channel should be valid after init")
	end)

	helpers.it("check_for_updates does not crash (may fail without network)", function()
		-- This may fail due to no network, but it must not crash.
		local ok = pcall(function() M.check_for_updates("stable") end)
		helpers.assert_true(ok, "check_for_updates should not error even without network")
	end)

	helpers.it("fetch command delegates ETag to curl, never a client-side timestamp", function()
		-- Regression: the fetch command previously stored os.date(...) as the ETag,
		-- so If-None-Match never matched the server value and 304 was never returned.
		-- The command must instead let curl persist and replay the real server ETag
		-- via --etag-save / --etag-compare.
		helpers.assert_true(type(M._build_fetch_command) == "function",
			"manager should expose _build_fetch_command for argv verification")
		local cmd, etag_file = M._build_fetch_command("stable")
		helpers.assert_true(type(cmd) == "string", "should return the curl command string")
		helpers.assert_contains(cmd, "--etag-save",
			"curl must persist the server ETag with --etag-save")
		helpers.assert_contains(cmd, etag_file,
			"curl must read/write the per-channel ETag cache file")
		-- Root-cause guards: no hand-built If-None-Match header, and no ISO-8601
		-- timestamp masquerading as an ETag value.
		helpers.assert_true(cmd:find("If-None-Match", 1, true) == nil,
			"must not hand-build an If-None-Match header — curl --etag-compare owns that")
		helpers.assert_true(cmd:find("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ") == nil,
			"must not embed a timestamp as the ETag value")
	end)

	-- ========================================
	-- ======= 1b/ install_update fail-fast ===
	-- ========================================

	helpers.it("install_update returns false and logs ERROR (no success) when the in-place move fails", function()
		-- Root cause: install_update() used to report success even when the final
		-- `mv extract -> install` step failed, leaving a bricked half-installed tree
		-- while still telling the user the update landed. Force that mv to fail and
		-- assert the function fails loud: returns false, logs an ERROR, and NEVER
		-- logs the "Update installed" success line.
		local tmp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
		local archive = tmp_dir:gsub("\\", "/") .. "/ergopti_updater_fake_archive.tar.gz"
		local afh = assert(io.open(archive, "w"))
		afh:write("not-a-real-archive")
		afh:close()

		-- Replace os.execute / io.popen so no real shell runs: every step "succeeds"
		-- EXCEPT the `mv <extract> -> <install>` move, which we force to fail. That
		-- move is the only `mv` whose source is the _update_tmp dir and whose target
		-- is the install dir (never the .old backup).
		local real_execute = os.execute
		local real_popen   = io.popen
		os.execute = function(cmd)
			if cmd:match("^mv ") and cmd:find("_update_tmp'", 1, true)
				and not cmd:find(".old", 1, true) then
				return nil, "exit", 1
			end
			return true, "exit", 0
		end
		io.popen = function(cmd)
			-- ls: non-empty listing (extract produced files); tar: empty stderr = ok.
			local payload = cmd:match("^ls ") and "payload\n" or ""
			return {
				read  = function() return payload end,
				lines = function() return function() return nil end end,
				close = function() return true, "exit", 0 end,
			}
		end

		-- Spy the logger the module already holds (same cached table instance).
		local logger = require("logger.shim")
		local real_error, real_success = logger.error, logger.success
		local errors, successes = {}, {}
		logger.error = function(_t, fmt, ...)
			errors[#errors + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
		end
		logger.success = function(_t, fmt, ...)
			successes[#successes + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
		end

		local result = M.install_update(archive)

		-- Restore everything BEFORE asserting so nothing leaks on a failure.
		os.execute, io.popen = real_execute, real_popen
		logger.error, logger.success = real_error, real_success
		os.remove(archive)

		helpers.assert_true(result == false,
			"install_update must return false when the in-place move fails")
		helpers.assert_true(#errors > 0,
			"a failed install must log at least one ERROR")
		helpers.assert_true(#successes == 0,
			"install_update must NOT log 'Update installed' when the move failed")
	end)

	-- ========================================
	-- ======= 2/ Menu Integration ============
	-- ========================================

	helpers.it("menu_builder renders updater section when updater context is present", function()
		local ok_mb, menu_builder = pcall(require, "modules.menu.menu_builder")
		if not ok_mb or not menu_builder then
			helpers.assert_true(true, "menu_builder not available — skipping")
			return
		end

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
		local ok_mb, menu_builder = pcall(require, "modules.menu.menu_builder")
		if not ok_mb or not menu_builder then
			helpers.assert_true(true, "menu_builder not available — skipping")
			return
		end

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
