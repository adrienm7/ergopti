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
		write_file(install_root .. "/linux/install/ownership_schema.sh",
			assert(read_file(helpers.driver_root() .. "/install/ownership_schema.sh")))
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
			"record_ownership", "verify_backup", "capture_backup", "revalidate_backup",
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
			function ops.record_ownership() return failed_stage ~= "record_ownership" end
			function ops.is_file() return failed_stage ~= "validate_layout" end
			function ops.is_dir() return true end
			function ops.read()
				if failed_stage == "validate_version" then return "version=9.9.9\n" end
				return "version=4.0.0\n"
			end
			function ops.mkdir() return failed_stage ~= "mkdir_candidate" end
			function ops.exists(path) return path == backup end
			function ops.backup_is_owned(path)
				if path == backup then return failed_stage ~= "verify_backup", "previous-owned" end
				return failed_stage ~= "revalidate_backup" and path == state.retired_path, "previous-owned"
			end
			function ops.remove_tree(path)
				if path == state.retired_path then
					if failed_stage == "remove_backup" then return false end
					state.backup = nil
				end
				return true
			end
			function ops.move(source_path, destination_path)
				if source_path == backup and destination_path ~= root then
					if failed_stage == "capture_backup" then return false end
					state.retired_path, state.backup = destination_path, nil
					return true
				end
				if source_path == state.retired_path and destination_path == backup then
					state.backup = "old-previous"
					return true
				end
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


helpers.describe("installer-backup-ownership", function()
	local NativeFixture = require("tests.support.modules.updater.installer_native_fixture")
	local uv = require("luv")
	helpers.it("(installer-backup-ownership) a pre-existing backup namespace is never deleted", function()
		local installer = helpers.load_module("modules.updater.installer")
		local fixture = NativeFixture.create(installer)
		local foreign = fixture.installed .. ".old"
		assert(uv.fs_mkdir(foreign, 448))
		NativeFixture.write(foreign .. "/unrelated.marker", "unrelated user backup\n")
		local identity = assert(uv.fs_stat(foreign))
		local ok, failure = pcall(function()
			installer.install({ archive_path = fixture.archive, expected_version = "1.2.3",
				context = fixture.context, ops = fixture.ops })
			helpers.assert_eq(NativeFixture.read(foreign .. "/unrelated.marker"), "unrelated user backup\n",
				"the complete native updater must not retire an unowned fixed sibling")
			local retained = assert(uv.fs_stat(foreign))
			helpers.assert_eq({ retained.dev, retained.ino }, { identity.dev, identity.ino })
		end)
		NativeFixture.remove(fixture.root)
		if not ok then error(failure, 0) end
	end)
end)

helpers.describe("installer-backup-ownership native receipts", function()
	local NativeFixture = require("tests.support.modules.updater.installer_native_fixture")
	local uv = require("luv")
	local Shell = require("adapters.shell_runner")
	local function receipt(fixture)
		assert(uv.fs_rename(fixture.installed .. "/old.marker", fixture.installed .. "/linux/old.marker"))
		NativeFixture.write(fixture.installed .. "/linux/binary.marker", "\0owned binary\255\n")
		assert(Shell.run("bash " .. Shell.quote(fixture.installed .. "/linux/install/ownership.sh")
			.. " " .. Shell.quote(fixture.installed .. "/linux") .. " " .. Shell.quote(fixture.installed .. "/_shared")
			.. " " .. Shell.quote(fixture.installed)))
	end
	local function external_receipt(fixture)
		receipt(fixture)
		local manifest = fixture.installed .. "/.ergopti-owned-files"
		local content, rows = assert(NativeFixture.read(manifest)), {}
		for _, role in ipairs({ "wrapper", "unit", "autostart" }) do
			local source = role == "wrapper" and fixture.context.wrapper or fixture.root .. "/external-" .. role
			if role ~= "wrapper" then NativeFixture.write(source, "external " .. role .. " bytes\n") end
			rows[role] = assert(require("adapters.crypto").sha256(assert(NativeFixture.read(source)))) .. "\t@" .. role .. "\n"
			content = content .. rows[role]
		end
		NativeFixture.write(manifest, content)
		return manifest, content, rows
	end

	helpers.it("(installer-current-ownership) regular receipts retain every actual external ownership row", function()
		local installer = helpers.load_module("modules.updater.installer")
		local fixture = NativeFixture.create(installer)
		local ok, failure = pcall(function()
			local manifest, _, rows = external_receipt(fixture)
			local installed, reason = installer.install({ archive_path = fixture.archive, expected_version = "1.2.3", context = fixture.context, ops = fixture.ops })
			helpers.assert_eq(installed, true, tostring(reason))
			local selected = assert(NativeFixture.read(manifest))
			for _, row in pairs(rows) do helpers.assert_true(selected:find(row, 1, true) ~= nil, "the canonical recorder must retain the exact external SHA-256 row") end
		end)
		NativeFixture.remove(fixture.root)
		if not ok then error(failure, 0) end
	end)

	for _, mode in ipairs({ "fifo", "directory", "file-link", "dangling-link" }) do
		helpers.it("(installer-current-ownership) a " .. mode .. " receipt cannot become a missing external ownership record", function()
			local installer = helpers.load_module("modules.updater.installer")
			local fixture = NativeFixture.create(installer)
			local ok, failure = pcall(function()
				local manifest, content = external_receipt(fixture)
				assert(uv.fs_unlink(manifest))
				if mode == "fifo" then assert(Shell.run("mkfifo -- " .. Shell.quote(manifest)))
				elseif mode == "directory" then assert(uv.fs_mkdir(manifest, 448))
				elseif mode == "file-link" then
					NativeFixture.write(fixture.root .. "/linked-receipt", content)
					assert(uv.fs_symlink(fixture.root .. "/linked-receipt", manifest))
				else assert(uv.fs_symlink(fixture.root .. "/missing-receipt", manifest)) end
				local current = assert(uv.fs_stat(fixture.installed))
				local installed = installer.install({ archive_path = fixture.archive, expected_version = "1.2.3", context = fixture.context, ops = fixture.ops })
				if installed then
					local selected = assert(NativeFixture.read(manifest))
					for _, role in ipairs({ "wrapper", "unit", "autostart" }) do
						print("CURRENT_RECEIPT_LOST role=" .. role .. " lost=" .. tostring(not selected:find("@" .. role, 1, true)))
					end
				end
				helpers.assert_eq(installed, false, "an unreadable ownership receipt must abort before rotating the installed root")
				local after = assert(uv.fs_stat(fixture.installed))
				helpers.assert_eq({ after.dev, after.ino }, { current.dev, current.ino })
				helpers.assert_eq(assert(uv.fs_lstat(manifest)).type, mode == "fifo" and "fifo" or mode == "directory" and "directory" or "link")
				helpers.assert_true(uv.fs_stat(fixture.archive) ~= nil)
			end)
			NativeFixture.remove(fixture.root)
			if not ok then error(failure, 0) end
		end)
	end

	local function clone_backup(fixture)
		assert(Shell.run("cp -a -- " .. Shell.quote(fixture.installed) .. " " .. Shell.quote(fixture.installed .. ".old")))
	end


	helpers.it("(installer-backup-ownership) empty owned subtrees contain no unlisted personal data", function()
		local installer = helpers.load_module("modules.updater.installer")
		local owner = helpers.load_module("modules.updater.ownership_receipt")
		local fixture = NativeFixture.create(installer)
		local backup = fixture.installed .. ".old"
		local ok, failure = pcall(function()
			receipt(fixture); clone_backup(fixture)
			assert(Shell.run("mkdir -p -- " .. Shell.quote(backup .. "/linux/empty/nested")))
			local identity, detail = owner.verify(backup, fixture.installed)
			helpers.assert_true(type(identity) == "string", "file-only receipts must admit empty payload directories: " .. tostring(detail))
			NativeFixture.write(backup .. "/linux/empty/nested/personal.data", "unlisted nested personal bytes\n")
			helpers.assert_nil(owner.verify(backup, fixture.installed), "an unlisted file inside the same subtree must refuse ownership")
			helpers.assert_eq(NativeFixture.read(backup .. "/linux/empty/nested/personal.data"), "unlisted nested personal bytes\n")
			assert(uv.fs_unlink(backup .. "/linux/empty/nested/personal.data"))
			helpers.assert_true(type(owner.verify(backup, fixture.installed)) == "string")
			assert(uv.fs_symlink(fixture.installed .. "/linux", backup .. "/linux/empty/nested/alias"))
			helpers.assert_nil(owner.verify(backup, fixture.installed), "unlisted directory links are never empty owned subtrees")
			assert(uv.fs_unlink(backup .. "/linux/empty/nested/alias"))
			assert(Shell.run("mkfifo -- " .. Shell.quote(backup .. "/linux/empty/nested/fifo")))
			helpers.assert_nil(owner.verify(backup, fixture.installed), "unlisted special children must refuse without opening them")
			assert(uv.fs_unlink(backup .. "/linux/empty/nested/fifo"))
			helpers.assert_true(type(owner.verify(backup, fixture.installed)) == "string")
			assert(uv.fs_mkdir(backup .. "/foreign-empty", 448))
			helpers.assert_nil(owner.verify(backup, fixture.installed), "unlisted root siblings do not belong to the payload trees")
		end)
		NativeFixture.remove(fixture.root)
		if not ok then error(failure, 0) end
	end)

	helpers.it("(installer-backup-ownership) first and second native updates rotate only complete unchanged receipts", function()
		local installer = helpers.load_module("modules.updater.installer")
		local fixture = NativeFixture.create(installer)
		local ok, failure = pcall(function()
			receipt(fixture)
			local before = assert(uv.fs_stat(fixture.installed))
			local installed, reason = installer.install({ archive_path = fixture.archive, expected_version = "1.2.3", context = fixture.context, ops = fixture.ops })
			helpers.assert_eq(installed, true, tostring(reason))
			local first_backup = assert(uv.fs_stat(fixture.installed .. ".old"))
			helpers.assert_eq({ first_backup.dev, first_backup.ino }, { before.dev, before.ino })
			helpers.assert_eq(NativeFixture.read(fixture.installed .. ".old/linux/binary.marker"), "\0owned binary\255\n")
			local previous = assert(uv.fs_stat(fixture.installed))
			NativeFixture.write(fixture.archive, "validated archive collaborator\n")
			NativeFixture.write(fixture.root .. "/payload/_shared/build_stamp.txt", "commit=" .. string.rep("b", 40) .. "\nversion=1.2.4\n")
			installed, reason = installer.install({ archive_path = fixture.archive, expected_version = "1.2.4", context = fixture.context, ops = fixture.ops })
			helpers.assert_eq(installed, true, tostring(reason))
			local second_backup = assert(uv.fs_stat(fixture.installed .. ".old"))
			helpers.assert_eq({ second_backup.dev, second_backup.ino }, { previous.dev, previous.ino })
			helpers.assert_contains(NativeFixture.read(fixture.installed .. "/_shared/build_stamp.txt"), "version=1.2.4")
			helpers.assert_eq(uv.fs_stat(fixture.archive), nil)
		end)
		NativeFixture.remove(fixture.root)
		if not ok then error(failure, 0) end
	end)

	for _, mode in ipairs({ "modified", "extra", "duplicate", "traversal", "nul", "file-link", "manifest-link", "manifest-fifo" }) do
		helpers.it("(installer-backup-ownership) native receipt refuses " .. mode .. " without retiring data", function()
			local installer = helpers.load_module("modules.updater.installer")
			local fixture = NativeFixture.create(installer)
			local backup = fixture.installed .. ".old"
			local ok, failure = pcall(function()
				receipt(fixture); clone_backup(fixture)
				local manifest = backup .. "/.ergopti-owned-files"
				if mode == "modified" then NativeFixture.write(backup .. "/linux/old.marker", "user modification\n")
				elseif mode == "extra" then NativeFixture.write(backup .. "/linux/private.data", "unowned private bytes\n")
				elseif mode == "duplicate" then
					local bytes = assert(NativeFixture.read(manifest)); NativeFixture.write(manifest, bytes .. bytes:match("([^\n]+\n)"))
				elseif mode == "traversal" then
					NativeFixture.write(manifest, assert(NativeFixture.read(manifest)) .. string.rep("a", 64) .. "\tlinux/../../outside\n")
				elseif mode == "nul" then NativeFixture.write(manifest, assert(NativeFixture.read(manifest)) .. "\0")
				elseif mode == "file-link" then
					assert(uv.fs_unlink(backup .. "/linux/old.marker")); assert(uv.fs_symlink(fixture.installed .. "/linux/old.marker", backup .. "/linux/old.marker"))
				elseif mode == "manifest-link" then
					assert(uv.fs_unlink(manifest)); assert(uv.fs_symlink(fixture.installed .. "/.ergopti-owned-files", manifest))
				elseif mode == "manifest-fifo" then
					assert(uv.fs_unlink(manifest)); assert(Shell.run("mkfifo -- " .. Shell.quote(manifest)))
				end
				local current, old = assert(uv.fs_stat(fixture.installed)), assert(uv.fs_stat(backup))
				local installed = installer.install({ archive_path = fixture.archive, expected_version = "1.2.3", context = fixture.context, ops = fixture.ops })
				helpers.assert_eq(installed, false, "a modified/unowned backup must block mutation")
				local kept, live = assert(uv.fs_stat(backup)), assert(uv.fs_stat(fixture.installed))
				helpers.assert_eq({ kept.dev, kept.ino }, { old.dev, old.ino })
				helpers.assert_eq({ live.dev, live.ino }, { current.dev, current.ino })
				helpers.assert_eq(NativeFixture.read(backup .. "/linux/binary.marker"), "\0owned binary\255\n")
				if mode == "modified" then helpers.assert_eq(NativeFixture.read(backup .. "/linux/old.marker"), "user modification\n") end
				if mode == "extra" then helpers.assert_eq(NativeFixture.read(backup .. "/linux/private.data"), "unowned private bytes\n") end
				helpers.assert_true(uv.fs_stat(fixture.archive) ~= nil)
			end)
			NativeFixture.remove(fixture.root)
			if not ok then error(failure, 0) end
		end)
	end

	for _, blocked in ipairs({ false, true }) do
		helpers.it("(installer-backup-ownership) native capture race preserves foreign tree with restore blocked=" .. tostring(blocked), function()
			local installer = helpers.load_module("modules.updater.installer")
			local fixture = NativeFixture.create(installer)
			local backup, retired, foreign = fixture.installed .. ".old", nil, nil
			local injected, work = false, nil
			local ops = {}; for name, operation in pairs(fixture.ops) do ops[name] = operation end
			local make_work_dir = ops.make_work_dir or installer.DEFAULT_OPS.make_work_dir
			ops.make_work_dir = function(...) work = make_work_dir(...); return work end
			local ok, failure = pcall(function()
				receipt(fixture); clone_backup(fixture)
				local current = assert(uv.fs_stat(fixture.installed))
				ops.move = function(source, destination)
					if not injected and source == backup and destination ~= fixture.installed then
						helpers.assert_true(work ~= nil and destination:sub(1, #work + 1) == work .. "/", "capture must enter the transaction-owned private staging directory")
						assert(installer.DEFAULT_OPS.move(backup, fixture.root .. "/displaced-owned"))
						assert(uv.fs_mkdir(backup, 448)); NativeFixture.write(backup .. "/foreign.marker", "raced foreign bytes\n")
						foreign = assert(uv.fs_stat(backup)); retired, injected = destination, true
						local moved = installer.DEFAULT_OPS.move(source, destination)
						if moved and blocked then
							assert(uv.fs_mkdir(backup, 448)); NativeFixture.write(backup .. "/blocker.marker", "concurrent old-path owner\n")
						end
						return moved
					end
					return installer.DEFAULT_OPS.move(source, destination)
				end
				local installed, reason = installer.install({ archive_path = fixture.archive, expected_version = "1.2.3", context = fixture.context, ops = ops })
				helpers.assert_eq(injected, true, "the real atomic backup-capture boundary must execute")
				helpers.assert_eq(installed, false)
				local preserved = blocked and retired or backup
				helpers.assert_eq(NativeFixture.read(preserved .. "/foreign.marker"), "raced foreign bytes\n")
				local kept = assert(uv.fs_stat(preserved))
				helpers.assert_eq({ kept.dev, kept.ino }, { foreign.dev, foreign.ino })
				if blocked then
					helpers.assert_contains(reason, "unverified tree retained at " .. retired)
					helpers.assert_eq(NativeFixture.read(backup .. "/blocker.marker"), "concurrent old-path owner\n")
				end
				local live = assert(uv.fs_stat(fixture.installed))
				helpers.assert_eq({ live.dev, live.ino }, { current.dev, current.ino })
				helpers.assert_true(uv.fs_stat(fixture.archive) ~= nil)
			end)
			NativeFixture.remove(fixture.root)
			if not ok then error(failure, 0) end
		end)
	end
end)
