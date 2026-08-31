--- linux/tests/unit/meta/test_updater_manager.lua

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local Installer = helpers.load_module("modules.updater.installer")

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

	helpers.it("selects only the canonical Linux bundle from shuffled release assets", function()
		helpers.assert_eq(M.LINUX_ASSET_NAME, "ergopti-plus-linux.tar.gz",
			"the updater must consume the release artifact contract")
		local canonical_url = "https://github.com/adrienm7/ergopti/releases/download/v4.0.0/"
			.. M.LINUX_ASSET_NAME
		local body = '{"assets":['
			.. '{"name":"ErgoptiPlus-linux-amd64.deb","browser_download_url":"https://example.invalid/wrong.deb"},'
			.. '{"name":"checksums.txt","browser_download_url":"https://example.invalid/checksums.txt"},'
			.. '{"name":"' .. M.LINUX_ASSET_NAME .. '","browser_download_url":"' .. canonical_url .. '"},'
			.. '{"name":"ErgoptiPlus-linux-x86_64.AppImage","browser_download_url":"https://example.invalid/wrong.AppImage"}'
			.. ']}'

		helpers.assert_eq(M._select_update_asset(body), canonical_url,
			"asset order and package kind must not affect exact selection")
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
		M._fetch_releases = function() return body, 200 end
		M.current_version = function() return "3.0.0" end
		M.clear_cached_release()
		local ok, available = pcall(M.check_for_updates, "stable")
		M._fetch_releases = real_fetch
		M.current_version = real_current_version

		helpers.assert_true(ok, "the closed failure must not raise: " .. tostring(available))
		helpers.assert_eq(available, false,
			"a release without the exact bundle must not become installable")
		helpers.assert_eq(M.get_state(), "idle",
			"the missing canonical artifact must close the update transaction")
		helpers.assert_nil(M.get_cached_release(),
			"no arbitrary release asset may reach the cached install state")
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

	helpers.it("keeps the durable channel and interval when storage fails", function()
		local previous_storage = package.loaded["adapters.storage"]
		local previous_manager = package.loaded["modules.updater.manager"]
		local storage = Fakes.storage({
			initial = { ["updater.channel"] = "stable", ["updater.interval_sec"] = 7200 },
			writes_fail = true,
		})
		package.loaded["adapters.storage"] = storage
		package.loaded["modules.updater.manager"] = nil
		local failing = require("modules.updater.manager")
		failing.init({})

		local channel_changed = failing.set_channel("dev")
		local interval_changed = failing.set_check_interval(3600)
		local channel = failing.get_channel()
		local interval = failing.get_check_interval()
		failing.stop_background_checks()

		package.loaded["adapters.storage"] = previous_storage
		package.loaded["modules.updater.manager"] = previous_manager
		helpers.assert_eq(channel_changed, false)
		helpers.assert_eq(interval_changed, false)
		helpers.assert_eq(channel, "stable", "a failed write must not switch the live release feed")
		helpers.assert_eq(interval, 7200, "a failed write must not change the live schedule")
		helpers.assert_eq(storage.get("updater.channel"), "stable")
		helpers.assert_eq(storage.get("updater.interval_sec"), 7200)
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

	-- Every one of these labels was hardcoded French, so a user on any of the
	-- other 20 locales read French in the update menu. "not empty" above could
	-- never have caught that, and neither can it catch i18n.get echoing the raw
	-- key back on a miss.
	helpers.it("the idle label comes from the shared catalogue", function()
		local i18n = require("infra.i18n")
		M.clear_cached_release()
		local label = M.get_menu_label()
		helpers.assert_eq(label, i18n.get("menu.about.check_for_updates"),
			"the idle label must be whatever the catalogue says for the active locale")
		helpers.assert_true(label ~= "menu.about.check_for_updates",
			"an echoed key means the catalogue was never reached")
	end)

	helpers.it("the update-available label carries the tag through the catalogue template", function()
		local i18n = require("infra.i18n")
		-- A tag containing "%" is the reason the substitution is done on plain
		-- indices: gsub would read it as a capture reference in the REPLACEMENT
		-- string and raise "invalid use of '%'".
		M._test_set_cached_release({ tag = "v9.9.9-100%", prerelease = false })
		local label = M.get_menu_label()
		helpers.assert_true(label:find("v9.9.9-100%", 1, true) ~= nil,
			"the tag must appear verbatim in the label, percent signs included")
		helpers.assert_true(label:find("{tag}", 1, true) == nil,
			"the {tag} placeholder must be substituted, not rendered")
		helpers.assert_true(label ~= i18n.get("menu.about.update_now"),
			"the template must have been filled in, not returned as-is")
		M.clear_cached_release()
	end)

	helpers.it("stop_background_checks is safe to call even without active timers", function()
		-- Should not error.
		M.stop_background_checks()
		helpers.assert_eq(type(M.start_background_checks), "function",
			"a stop with no timers armed must leave the checks restartable")
	end)

	helpers.it("init loads persisted settings and initialises", function()
		local orig_channel = M.get_channel()
		-- init() should work without opts.
		M.init({})
		helpers.assert_eq(M.get_channel(), orig_channel,
			"init with no opts must not silently move the user off their release channel")
		-- Channel should still be the same.
		local ch = M.get_channel()
		helpers.assert_true(ch == "stable" or ch == "dev", "channel should be valid after init")
	end)

	helpers.it("check_for_updates does not crash (may fail without network)", function()
		-- This may fail due to no network, but it must not crash.
		-- With no network the check must ANSWER, not hang or vanish: the menu row
		-- shows "up to date" or "check failed" on it, and a nil leaves it blank.
		local result = M.check_for_updates("stable")
		helpers.assert_true(result == nil or type(result) == "boolean" or type(result) == "table",
			"check_for_updates must answer something the menu row can render")
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
			.. " " .. shell_quote(install_root .. "/_shared/lua")
			.. " " .. shell_quote(prefix .. "/bin")
			.. " " .. shell_quote(payload .. "/linux/infra")
			.. " " .. shell_quote(payload .. "/_shared/lua")
			.. " " .. shell_quote(payload .. "/bin")))

		write_file(install_root .. "/linux/ergopti_hotstrings.lua", "print('old-driver')\n")
		write_file(install_root .. "/linux/infra/version.lua", 'local M = {}\nM.VERSION = "3.0.0"\nreturn M\n')
		write_file(install_root .. "/_shared/lua/sentinel.lua", "return 'old-shared'\n")
		write_file(payload .. "/linux/ergopti_hotstrings.lua", "print('new-driver')\n")
		write_file(payload .. "/linux/infra/version.lua", 'local M = {}\nM.VERSION = "4.0.0"\nreturn M\n')
		write_file(payload .. "/_shared/lua/sentinel.lua", "return 'new-shared'\n")
		write_file(payload .. "/bin/ergopti-hotstrings", "#!/usr/bin/env bash\nexit 0\n")
		write_file(payload .. "/install.sh", "#!/usr/bin/env bash\nexit 0\n")
		write_file(payload .. "/kanata.kbd", "(defcfg)\n")
		write_file(wrapper, "#!/usr/bin/env bash\nset -euo pipefail\n"
			.. "grep -q '\"4.0.0\"' " .. shell_quote(install_root .. "/linux/infra/version.lua") .. "\n"
			.. "grep -q 'new-shared' " .. shell_quote(install_root .. "/_shared/lua/sentinel.lua") .. "\n"
			.. "test ! -e " .. shell_quote(install_root .. "/linux/linux") .. "\n")
		helpers.assert_true(command_ok("chmod +x " .. shell_quote(wrapper)
			.. " " .. shell_quote(payload .. "/bin/ergopti-hotstrings")
			.. " " .. shell_quote(payload .. "/install.sh")))
		helpers.assert_true(command_ok("tar -czf " .. shell_quote(archive)
			.. " -C " .. shell_quote(payload)
			.. " linux _shared bin install.sh kanata.kbd"))

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
		local logger = require("logger.shim")
		local real_error = logger.error
		local errors = {}
		logger.error = function(_tag, fmt, ...)
			errors[#errors + 1] = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
		end
		local call_ok, installed = pcall(M.install_update, archive)
		M._resolve_installation = real_resolver
		logger.error = real_error

		local new_version = read_file(install_root .. "/linux/infra/version.lua")
		local new_shared = read_file(install_root .. "/_shared/lua/sentinel.lua")
		local old_version = read_file(install_root .. ".old/linux/infra/version.lua")
		local nested = read_file(install_root .. "/linux/linux/ergopti_hotstrings.lua")
		local archive_left = read_file(archive)
		M.clear_cached_release()
		command_ok("rm -rf -- " .. shell_quote(base))

		helpers.assert_true(call_ok, "real update transaction raised: " .. tostring(installed))
		helpers.assert_eq(installed, true, table.concat(errors, " | "))
		helpers.assert_contains(new_version or "", 'M.VERSION = "4.0.0"')
		helpers.assert_contains(new_shared or "", "new-shared")
		helpers.assert_contains(old_version or "", 'M.VERSION = "3.0.0"')
		helpers.assert_nil(nested, "the archive linux/ root must not become linux/linux")
		helpers.assert_nil(archive_left, "a committed update retires its downloaded archive")
	end)

	helpers.it("rolls back every fallible activation stage", function()
		local root = "/tmp/ergopti-fixture/lib/ergopti"
		local parent = "/tmp/ergopti-fixture/lib"
		local work = parent .. "/.ergopti-update.fixture"
		local candidate = work .. "/candidate"
		local backup = root .. ".old"
		local stages = {
			"validate_archive", "make_work_dir", "extract", "validate_layout",
			"validate_version", "mkdir_candidate", "move_linux", "move_shared",
			"remove_backup", "backup_current", "activate_candidate", "smoke",
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
			function ops.is_file() return failed_stage ~= "validate_layout" end
			function ops.is_dir() return true end
			function ops.read()
				if failed_stage == "validate_version" then return 'M.VERSION = "9.9.9"' end
				return 'M.VERSION = "4.0.0"'
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
		local call_ok, installed = pcall(M.install_update, archive)
		M._resolve_installation = real_resolver
		Installer.install = real_install
		local archive_content = read_file(archive)
		os.remove(archive)

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
