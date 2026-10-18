--- tests/unit/modules/updater/check/test_updater_manager_resolves_complete_standalone.lua

package.loaded["tests.support.modules.updater.check.updater_manager_fixture"] = nil
local Fixture = require("tests.support.modules.updater.check.updater_manager_fixture")
local helpers, Installer, etag_response, Json, shell_quote, command_ok, write_file, read_file =
	Fixture.helpers, Fixture.Installer, Fixture.etag_response, Fixture.Json, Fixture.shell_quote, Fixture.command_ok, Fixture.write_file, Fixture.read_file




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

