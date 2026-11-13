--- tests/unit/modules/keymap/layout/test_layout_install_transaction.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Install Transaction Regression
--- DESCRIPTION:
--- A replacement bundle is staged and verified before any installed copy is
--- moved, cancellation never removes the other scope, and failed attempts
--- invalidate the discovery cache before the menu reads it again.
--- ==============================================================================

local helpers = require("tests.helpers")
local original_resolver = package.loaded["keyboard.adapters.karabiner.lease_helper"]
package.loaded["keyboard.adapters.karabiner.lease_helper"] = {
	resolve = function() return os.getenv("ERGOPTI_LAUNCHER_EXECUTABLE") end,
}
local original_getenv = os.getenv
os.getenv = function(name)
	if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus" end
	return original_getenv(name)
end


--- The listing is the user folder's; the system folder is empty unless
--- `in_system` says the same bundle is there too.
local function with_fake_bundle_listing(initial_name, callback, in_system)
	local original_popen = io.popen
	local original_dir = package.loaded["core.fs.engine.dir"]
	local original_fs = package.loaded["core.fs.adapters.file_system"]
	package.loaded["core.fs.adapters.file_system"] = setmetatable({
		classify_no_follow = function() return { mode = "directory" }, "ok" end,
	}, { __index = original_fs or {} })
	local listing = initial_name
	local system_present = in_system == true
	local scans = 0
	package.loaded["core.fs.engine.dir"] = { try_entries = function(dir)
		local system_scan = dir:sub(1, 1) == "/" and dir:find("/Library/Keyboard Layouts", 1, true) == 1
		if system_scan and not system_present then return {}, true end
		if not system_scan then scans = scans + 1 end
		return listing and { listing } or {}, true
	end }
	io.popen = function(command)
		local system_scan = tostring(command):find("'/Library/Keyboard Layouts", 1, true) ~= nil
		if not system_scan then scans = scans + 1 end
		local delivered = system_scan and not system_present
		return {
			lines = function()
				return function()
					if delivered or not listing then return nil end
					delivered = true
					return listing
				end
			end,
			close = function() return true end,
		}
	end

	local ok, err = xpcall(function()
		callback({
			set_listing = function(name) listing = name end,
			set_system = function(value) system_present = value end,
			scan_count = function() return scans end,
		})
	end, debug.traceback)
	io.popen = original_popen
	package.loaded["core.fs.engine.dir"] = original_dir
	package.loaded["core.fs.adapters.file_system"] = original_fs
	if not ok then error(err, 0) end
end


local function assert_copy_precedes_replacement(command, label)
	helpers.assert_true(type(command) == "string" and command ~= "",
		label .. " must dispatch one non-empty shell transaction")
	local command_view = command:gsub('\\"', '"')
	local copy_at = command_view:find("cp -R", 1, true)
	local replacement_at = command_view:find("for prior in", 1, true)
	helpers.assert_true(copy_at ~= nil,
		label .. " must stage the source bundle before touching installed copies")
	helpers.assert_true(replacement_at ~= nil,
		label .. " must retain installed copies in a rollback area")
	helpers.assert_true(copy_at < replacement_at,
		label .. " must finish the staging copy before moving installed bundles")
	helpers.assert_true(
		command_view:sub(1, copy_at - 1):find("Ergopti_v*.bundle", 1, true) == nil,
		label .. " must not delete or move an installed bundle before staging")
	helpers.assert_true(command_view:find("restore_install", 1, true) ~= nil,
		label .. " must own a rollback path after installed bundles move")
	helpers.assert_true(command_view:find('--release-rename move "$prior" "$target/${prior##*/}"', 1, true) ~= nil,
		label .. " must restore retained bundles only with an exclusive native rename")
	helpers.assert_true(command_view:find("restore_ok=0", 1, true) ~= nil,
		label .. " must preserve the rollback directory when restoration refuses")
end


helpers.describe("layout_install: transactional replacement", function()
	helpers.it("keeps the old bundle when the staged bundle has no layouts (layout-empty-staging)", function()
		local quote = require("core.text.engine.utils_core").shell_quote
		local root = os.tmpname(); os.remove(root)
		local target, source, launcher = root .. "/target", root .. "/source", root .. "/launcher"
		local old, new = "Ergopti_v1.0.0.bundle", "Ergopti_v2.0.0.bundle"
		local fixture = helpers.driver_root() .. "/tests/support/release_rename_physical_port.py"
		local ok, err = xpcall(function()
			assert(os.execute("mkdir -p " .. quote(target .. "/" .. old) .. " " .. quote(source .. "/" .. new .. "/Contents")))
			assert(os.execute("mkdir -p " .. quote(target .. "/Ergopti_vcustom.bundle")))
			local resources = source .. "/" .. new .. "/Contents/Resources"
			assert(os.execute("mkdir -p " .. quote(resources)))
			assert(os.execute("ln -s . " .. quote(resources .. "/Directory.keylayout")))
			assert(os.execute("ln -s missing " .. quote(resources .. "/Dangling.keylayout")))
			local f = assert(io.open(source .. "/" .. new .. "/Contents/Info.plist", "w")); f:write("staged"); f:close()
			f = assert(io.open(target .. "/" .. old .. "/original", "w")); f:write("original"); f:close()
			f = assert(io.open(target .. "/Ergopti_vcustom.bundle/foreign", "w")); f:write("keep"); f:close()
			f = assert(io.open(launcher, "w")); f:write("#!/bin/sh\nexec /usr/bin/env python3 " .. quote(fixture) .. " \"$@\"\n"); f:close()
			assert(os.execute("chmod +x " .. quote(launcher)))
			local command
			local getenv = os.getenv
			os.getenv = function(name) if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return launcher end; return getenv(name) end
			local captured, capture_err = pcall(function()
				local install = helpers.load_with_stubs("modules.keymap.layout_install", { execute = function(value) command = value; return "", false end })
				install.install_user(source, new)
			end)
			os.getenv = getenv
			assert(captured, capture_err); assert(type(command) == "string")
			local rewritten, count = command:gsub("^target=.-;", "target=" .. quote(target) .. ";", 1); assert(count == 1)
			local result = os.execute("/bin/sh -c " .. quote(rewritten) .. " >/dev/null 2>&1")
			helpers.assert_true(result ~= true, "a bundle without keylayout files must be refused")
			f = assert(io.open(target .. "/" .. old .. "/original", "r")); f:close()
			helpers.assert_eq(io.open(target .. "/" .. new .. "/Contents/Info.plist", "r"), nil)
			f = assert(io.open(resources .. "/real", "w")); f:write("layout"); f:close()
			assert(os.execute("ln -s real " .. quote(resources .. "/Linked.keylayout")))
			f = assert(io.open(root .. "/rm", "w")); f:write("#!/bin/sh\nexit 1\n"); f:close()
			assert(os.execute("chmod +x " .. quote(root .. "/rm")))
			local process = assert(io.popen("PATH=" .. quote(root .. ":" .. getenv("PATH"))
				.. " /bin/sh -c " .. quote(rewritten) .. " 2>&1", "r"))
			local output = assert(process:read("*a"))
			helpers.assert_true(process:close(), "cleanup failure must not undo a completed install")
			helpers.assert_true(output:find("Keyboard layout installation cleanup failed; retained at " .. target, 1, true) ~= nil,
				"cleanup failure must report the retained recovery path")
			f = assert(io.open(target .. "/Ergopti_vcustom.bundle/foreign", "r")); helpers.assert_eq(f:read("*a"), "keep"); f:close()
			f = assert(io.open(target .. "/" .. new .. "/Contents/Resources/Linked.keylayout", "r")); f:close()
		end, debug.traceback)
		os.execute("rm -rf " .. quote(root))
		if not ok then error(err, 0) end
	end)
	helpers.it("refuses reentrant installs while a user replacement is running", function()
		local install, calls, nested_user, nested_system
		calls = 0
		install = helpers.load_with_stubs("modules.keymap.layout_install", {
			execute = function()
				calls = calls + 1
				nested_user = install.install_user("/tmp/source", "Ergopti_v2.0.0.bundle")
				nested_system = install.install_system("/tmp/source", "Ergopti_v2.0.0.bundle")
				return "", true
			end,
		})
		helpers.assert_eq(install.install_user("/tmp/source", "Ergopti_v2.0.0.bundle"), true)
		helpers.assert_eq(nested_user, false); helpers.assert_eq(nested_system, false)
		helpers.assert_eq(calls, 1)
	end)

	helpers.it("refuses system installation before authorization (layout-system-unavailable)", function()
		local calls = 0
		local install = helpers.load_with_stubs("modules.keymap.layout_install", {
			execute = function() calls = calls + 1; return "", true end,
			osascript = { applescript = function() calls = calls + 1; return true end },
		})
		local installed, reason = install.install_system("/tmp/source", "Ergopti_v2.0.0.bundle")
		helpers.assert_eq(installed, false)
		helpers.assert_eq(reason, "system_install_unavailable")
		helpers.assert_eq(calls, 0, "no privileged or filesystem command may start")
	end)

	helpers.it("refuses an unreadable other scope before mutation (layout-other-scope-unverified)", function()
		local old_dir, old_fs = package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"]
		package.loaded["core.fs.engine.dir"] = { try_entries = function() return {}, false end }
		package.loaded["core.fs.adapters.file_system"] = { classify_no_follow = function() return nil, "error" end }
		local ok, err = xpcall(function()
			local calls = 0
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				execute = function() calls = calls + 1; return "", true end,
				osascript = { applescript = function() calls = calls + 1; return true end },
			})
			local committed, reason = install.install_user("/tmp/source", "Ergopti_v2.0.0.bundle")
			helpers.assert_eq(committed, false); helpers.assert_eq(reason, "other_scope_unverified")
			helpers.assert_eq(calls, 0, "unverified scope cannot authorize mutation")
		end, debug.traceback)
		package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"] = old_dir, old_fs
		if not ok then error(err, 0) end
	end)

	helpers.it("warns when the post-install other-scope check becomes unreadable", function()
		local old_dir, old_fs, old_notify = package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"],
			package.loaded["core.ui.engine.notifications"]
		local reads, notices = 0, {}
		package.loaded["core.fs.engine.dir"] = { try_entries = function()
			reads = reads + 1; return {}, reads <= 2
		end }
		package.loaded["core.fs.adapters.file_system"] = { classify_no_follow = function() return nil, "error" end }
		package.loaded["core.ui.engine.notifications"] = { notify = function(message) notices[#notices + 1] = message end }
		local ok, err = xpcall(function()
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				execute = function() return "", true end,
			})
			local committed, reason = install.install_user("/tmp/source", "Ergopti_v2.0.0.bundle")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(reason, "other_scope_unverified")
			helpers.assert_eq(notices, {}, "a partial publication must not claim success")
		end, debug.traceback)
		package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"], package.loaded["core.ui.engine.notifications"] =
			old_dir, old_fs, old_notify
		if not ok then error(err, 0) end
	end)
	helpers.it("refuses an unverified launcher before user installation", function()
		local previous = package.loaded["keyboard.adapters.karabiner.lease_helper"]
		package.loaded["keyboard.adapters.karabiner.lease_helper"] = { resolve = function() return nil, "identity mismatch" end }
		local ok, err = xpcall(function()
			local prompts = 0
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				osascript = { applescript = function() prompts = prompts + 1; return true end },
			})
			local installed, reason = install.install_user("/tmp/source", "Ergopti_v2.2.0.bundle")
			helpers.assert_eq(installed, false)
			helpers.assert_eq(reason, "launcher_unavailable")
			helpers.assert_eq(prompts, 0, "an unverified executable must never start installation")
		end, debug.traceback)
		package.loaded["keyboard.adapters.karabiner.lease_helper"] = previous
		if not ok then error(err, 0) end
	end)

	helpers.it("retains the backup when a concurrent bundle occupies rollback (layout-rollback-exclusive)", function()
		local quote = require("core.text.engine.utils_core").shell_quote
		local root = os.tmpname()
		os.remove(root)
		local target, source, launcher = root .. "/target", root .. "/source", root .. "/launcher"
		local old, new = "Ergopti_v1.0.0.bundle", "Ergopti_v2.0.0.bundle"
		local fixture = helpers.driver_root() .. "/tests/support/release_rename_physical_port.py"
		local ok, err = xpcall(function()
			assert(os.execute("mkdir -p " .. quote(target .. "/" .. old)
				.. " " .. quote(source .. "/" .. new .. "/Contents")))
			local file = assert(io.open(source .. "/" .. new .. "/Contents/Info.plist", "w"))
			assert(file:write("staged")); assert(file:close())
			assert(os.execute("mkdir -p " .. quote(source .. "/" .. new .. "/Contents/Resources")))
			file = assert(io.open(source .. "/" .. new .. "/Contents/Resources/valid.keylayout", "w"))
			assert(file:write("layout")); assert(file:close())
			file = assert(io.open(target .. "/" .. old .. "/original", "w"))
			assert(file:write("original")); assert(file:close())
			file = assert(io.open(launcher, "w"))
			assert(file:write("#!/bin/sh\ncase \"$3\" in */.ergopti-install.*/" .. new .. ")\n"
				.. "mkdir -p " .. quote(target .. "/" .. old) .. "\n"
				.. "ls -di " .. quote(target .. "/" .. old) .. " > " .. quote(root .. "/identity") .. "\nexit 1;; esac\n"
				.. "exec /usr/bin/env python3 " .. quote(fixture) .. " \"$@\"\n"))
			assert(file:close()); assert(os.execute("chmod +x " .. quote(launcher)))
			-- The old shell implementation uses mv; inject the identical race at
			-- its publication call so this test fails against that implementation.
			file = assert(io.open(root .. "/mv", "w"))
			assert(file:write("#!/bin/sh\ncase \"$1\" in */.ergopti-install.*/" .. new .. ")\n"
				.. "mkdir -p " .. quote(target .. "/" .. old) .. "\n"
				.. "ls -di " .. quote(target .. "/" .. old) .. " > " .. quote(root .. "/identity") .. "\nexit 1;; esac\n"
				.. "exec /bin/mv \"$@\"\n"))
			assert(file:close()); assert(os.execute("chmod +x " .. quote(root .. "/mv")))
			local command
			local getenv = os.getenv
			os.getenv = function(name) if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return launcher end; return getenv(name) end
			local captured, capture_error = pcall(function()
				local install = helpers.load_with_stubs("modules.keymap.layout_install", {
					execute = function(value) command = value; return "", false end,
				})
				install.install_user(source, new)
			end)
			os.getenv = getenv
			assert(captured, capture_error)
			assert(type(command) == "string")
			local rewritten, count = command:gsub("^target=.-;", "target=" .. quote(target) .. ";", 1)
			assert(count == 1)
			local process = assert(io.popen("PATH=" .. quote(root .. ":" .. getenv("PATH"))
				.. " /bin/sh -c " .. quote(rewritten) .. " 2>/dev/null", "r"))
			local output = assert(process:read("*a"))
			local committed = process:close()
			helpers.assert_eq(committed, nil, "the collision must refuse publication")
			helpers.assert_true(output:find("Keyboard layout backups retained at " .. target .. "/.ergopti-install.", 1, true) ~= nil,
				"the user install must receive the retained backup path on stdout")
			local identity = assert(io.open(root .. "/identity", "r"))
			local before = assert(identity:read("*l")):match("^%s*(%d+)"); identity:close()
			local listing = assert(io.popen("ls -di " .. quote(target .. "/" .. old), "r"))
			local after = assert(listing:read("*l")):match("^%s*(%d+)"); listing:close()
			helpers.assert_eq(after, before, "the concurrent empty bundle must remain untouched")
			local found = os.execute("find " .. quote(target) .. " -path "
				.. quote("*/backup/" .. old .. "/original") .. " -print | grep -q .")
			helpers.assert_true(found == true, "the original remains recoverable in the backup")
		end, debug.traceback)
		os.execute("rm -rf " .. quote(root))
		if not ok then error(err, 0) end
	end)

	helpers.it("stages before replacement and invalidates cache after user failure", function()
		with_fake_bundle_listing("Ergopti_v1.0.0.bundle", function(listing)
			local commands = {}
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				execute = function(command)
					commands[#commands + 1] = command
					return "copy failed", false, "exit", 1
				end,
				fs = {
					attributes = function() return { mode = "file" } end,
				},
			})

			local before = install.highest_installed(install.USER_LAYOUTS_DIR)
			helpers.assert_eq(before.name, "Ergopti_v1.0.0.bundle")
			helpers.assert_eq(listing.scan_count(), 1)
			listing.set_listing("Ergopti_v2.0.0.bundle")

			helpers.assert_eq(
				install.install_user("/tmp/layout source/", "Ergopti_v2.0.0.bundle"),
				false)
			helpers.assert_eq(#commands, 1,
				"a failed staging copy must not dispatch a separate destructive cleanup")
			assert_copy_precedes_replacement(commands[1], "user install")

			local after = install.highest_installed(install.USER_LAYOUTS_DIR)
			helpers.assert_eq(after.name, "Ergopti_v2.0.0.bundle",
				"the post-failure menu read must not reuse the pre-attempt cache")
			helpers.assert_eq(listing.scan_count(), 2)
		end)
	end)

	helpers.it("does not remove the other scope after the new user bundle commits", function()
		local commands = {}
		local install = helpers.load_with_stubs("modules.keymap.layout_install", {
			execute = function(command)
				commands[#commands + 1] = command
				return "", true, "exit", 0
			end,
		})

		helpers.assert_eq(
			install.install_user("/tmp/layout source/", "Ergopti_v2.0.0.bundle"),
			true)
		helpers.assert_eq(#commands, 1)
		assert_copy_precedes_replacement(commands[1], "user install")
	end)

	helpers.it("preserves and reports an other-scope bundle that appears during installation", function()
		with_fake_bundle_listing("Ergopti_v1.0.0.bundle", function(listing)
			local notices, commands = {}, {}
			local saved = package.loaded["core.ui.engine.notifications"]
			package.loaded["core.ui.engine.notifications"] = { notify = function(message) notices[#notices + 1] = message end }
			local ok, err = xpcall(function()
				local install = helpers.load_with_stubs("modules.keymap.layout_install", {
					execute = function(command)
						commands[#commands + 1] = command
						listing.set_system(true)
						return "", true, "exit", 0
					end,
				})
				local committed, reason = install.install_user("/tmp/layout source/", "Ergopti_v2.0.0.bundle")
				helpers.assert_eq(committed, false)
				helpers.assert_eq(reason, "other_scope_occupied")
				helpers.assert_eq(#commands, 1, "no second command may delete the concurrent bundle")
				helpers.assert_eq(notices, {}, "a partial publication must not claim success")
			end, debug.traceback)
			package.loaded["core.ui.engine.notifications"] = saved
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("checks the user scope before accepting an existing system copy", function()
		local old_dir, old_fs, old_popen = package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"], io.popen
		local readable = true
		package.loaded["core.fs.adapters.file_system"] = { classify_no_follow = function() return { mode = "directory" }, "ok" end }
		package.loaded["core.fs.engine.dir"] = { try_entries = function(dir)
			if dir:find("/Library/Keyboard Layouts", 1, true) == 1 then return { "Ergopti_v1.0.0.bundle" }, true end
			return {}, readable
		end }
		io.popen = function() return nil end
		local ok, err = xpcall(function()
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				fs = { attributes = function() return { mode = "file" } end },
			})
			helpers.assert_eq(install.install_user("/tmp/bundles", "Ergopti_v1.0.0.bundle"), true)
			readable = false
			local installed, reason = install.install_user("/tmp/bundles", "Ergopti_v1.0.0.bundle")
			helpers.assert_eq(installed, false)
			helpers.assert_eq(reason, "other_scope_unverified")
		end, debug.traceback)
		package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"], io.popen = old_dir, old_fs, old_popen
		if not ok then error(err, 0) end
	end)

	helpers.it("writes no user copy of a bundle the system folder already holds", function()
		with_fake_bundle_listing("Ergopti_v1.0.0.bundle", function()
			local commands = {}
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				execute = function(command)
					commands[#commands + 1] = command
					return "", true, "exit", 0
				end,
				fs = { attributes = function() return { mode = "file" } end },
			})
			local installed, reason = install.install_user("/tmp/bundles", "Ergopti_v1.0.0.bundle")
			helpers.assert_eq(installed, false)
			helpers.assert_eq(reason, "other_scope_occupied")
			for _, command in ipairs(commands) do
				helpers.assert_true(command:find("cp -R", 1, true) == nil, "no copy is staged: " .. command)
			end
			helpers.assert_eq(install.duplicate_bundles()[1], "Ergopti_v1.0.0.bundle",
				"the listing sees the bundle in both folders")
		end, true)
	end)
end)

helpers.describe("layout_install: fresh bundle resources", function()
	helpers.it("sees added and removed layouts without launching a directory scan", function()
		local layouts = { "first.keylayout" }
		local original_popen = io.popen
		local original_fs, original_dir = package.loaded["core.fs.adapters.file_system"], package.loaded["core.fs.engine.dir"]
		package.loaded["core.fs.adapters.file_system"], package.loaded["core.fs.engine.dir"] = nil, nil
		local ok, err = xpcall(function()
			io.popen = function() error("native enumeration must not spawn find") end
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				fs = {
					symlinkAttributes = function() return { mode = "directory" } end,
					dir = function(path)
						local rows = {}
						if path:match("/Resources$") then rows = layouts
						elseif path:match("/Keyboard Layouts$") then rows = { "Custom.bundle" } end
						local position = 0
						return function()
							position = position + 1
							return rows[position]
						end
					end,
				},
			})
			local names = install.bundle_keylayout_names()
			helpers.assert_true(names.first)
			layouts = { "second.keylayout" }
			names = install.bundle_keylayout_names()
			helpers.assert_nil(names.first)
			helpers.assert_true(names.second)
		end, debug.traceback)
		io.popen = original_popen
		package.loaded["core.fs.adapters.file_system"], package.loaded["core.fs.engine.dir"] = original_fs, original_dir
		if not ok then error(err, 0) end
	end)

	helpers.it("does not publish a partial native resource enumeration", function()
		local original_popen = io.popen
		local original_fs, original_dir = package.loaded["core.fs.adapters.file_system"], package.loaded["core.fs.engine.dir"]
		package.loaded["core.fs.adapters.file_system"], package.loaded["core.fs.engine.dir"] = nil, nil
		local ok, err = xpcall(function()
			local scans, fail_stat, fail_find = 0, false, false
			io.popen = function()
				scans = scans + 1
				local delivered = false
				return { lines = function() return function()
					if delivered then return nil end
					delivered = true
					return "/root/Fallback.bundle/Contents/Resources/fallback.keylayout"
				end end, close = function() return not fail_find end }
			end
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				fs = {
					symlinkAttributes = function(path)
						if fail_stat and path:find("Custom.bundle", 1, true) then error("attribute read refused") end
						return { mode = "directory" }
					end,
					dir = function(path)
						if path:match("/Resources$") then error("unreadable") end
						local delivered = false
						return function()
							if delivered then return nil end
							delivered = true
							return "Custom.bundle"
						end
					end,
				},
			})
			helpers.assert_true(install.bundle_keylayout_names().fallback)
			helpers.assert_eq(scans, 2, "both failed native reads must retry via find")
			fail_stat = true
			helpers.assert_true(install.bundle_keylayout_names().fallback)
			helpers.assert_eq(scans, 4, "attribute errors must also retry via find")
			fail_find = true
			helpers.assert_nil(install.bundle_keylayout_names(), "a failed fallback cannot publish a partial index")
		end, debug.traceback)
		io.popen = original_popen
		package.loaded["core.fs.adapters.file_system"], package.loaded["core.fs.engine.dir"] = original_fs, original_dir
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("layout_install: failed listings are not cached", function()
	helpers.it("retries an incomplete listing without reusing its partial result", function()
		local original_popen = io.popen
		local original_dir, original_fs = package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"]
		package.loaded["core.fs.engine.dir"] = { try_entries = function() return {}, false end }
		package.loaded["core.fs.adapters.file_system"] = { classify_no_follow = function() return nil, "error" end }
		local scans = 0
		local ok, err = xpcall(function()
			io.popen = function()
				scans = scans + 1
				local delivered = false
				local succeeded = scans > 1
				return {
					lines = function() return function()
						if delivered then return nil end
						delivered = true
						return "Ergopti_v1.0.0.bundle"
					end end,
					close = function() return succeeded end,
				}
			end
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				fs = { attributes = function() return { mode = "directory", size = 1, modification = 1 } end },
			})
			local first, listed = install.highest_installed("/layouts")
			helpers.assert_nil(first)
			helpers.assert_eq(listed, false)
			local second, retried = install.highest_installed("/layouts")
			helpers.assert_eq(second.name, "Ergopti_v1.0.0.bundle")
			helpers.assert_eq(retried, true)
			helpers.assert_eq(scans, 2)
		end, debug.traceback)
		io.popen = original_popen
		package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"] = original_dir, original_fs
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("layout_install: missing optional directories", function()
	helpers.it("proves absence before requesting a directory listing", function()
		local old_dir, old_fs = package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"]
		local listings = 0
		package.loaded["core.fs.engine.dir"] = { try_entries = function() listings = listings + 1; return {}, false end }
		package.loaded["core.fs.adapters.file_system"] = { classify_no_follow = function() return nil, "absent" end }
		local ok, err = xpcall(function()
			local install = helpers.load_with_stubs("modules.keymap.layout_install")
			local result, listed = install.highest_installed("/missing")
			helpers.assert_nil(result)
			helpers.assert_true(listed)
			helpers.assert_eq(install.bundle_keylayout_names(), {})
			helpers.assert_eq(listings, 0, "a proven missing scope needs no error-producing listing")
		end, debug.traceback)
		package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"] = old_dir, old_fs
		if not ok then error(err, 0) end
	end)
end)

package.loaded["keyboard.adapters.karabiner.lease_helper"] = original_resolver
