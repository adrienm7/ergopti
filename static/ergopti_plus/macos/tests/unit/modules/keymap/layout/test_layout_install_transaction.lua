--- tests/unit/modules/keymap/layout/test_layout_install_transaction.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Install Transaction Regression
--- DESCRIPTION:
--- A replacement bundle is staged and verified before any installed copy is
--- moved, cancellation never removes the other scope, and failed attempts
--- invalidate the discovery cache before the menu reads it again.
--- ==============================================================================

local helpers = require("tests.helpers")
local original_getenv = os.getenv
os.getenv = function(name)
	if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus" end
	return original_getenv(name)
end


--- The listing is the user folder's; the system folder is empty unless
--- `in_system` says the same bundle is there too.
local function with_fake_bundle_listing(initial_name, callback, in_system)
	local original_popen = io.popen
	local listing = initial_name
	local scans = 0
	io.popen = function(command)
		local system_scan = tostring(command):find("'/Library/Keyboard Layouts", 1, true) ~= nil
		if not system_scan then scans = scans + 1 end
		local delivered = system_scan and in_system ~= true
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
			scan_count = function() return scans end,
		})
	end, debug.traceback)
	io.popen = original_popen
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
	helpers.it("refuses standalone installation before authorization (layout-install-native-role)", function()
		local getenv = os.getenv
		os.getenv = function(name) if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return nil end; return getenv(name) end
		local ok, err = xpcall(function()
			local prompts = 0
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				osascript = { applescript = function() prompts = prompts + 1; return true end },
			})
			local installed, reason = install.install_system("/tmp/source", "Ergopti_v2.0.0.bundle")
			helpers.assert_eq(installed, false)
			helpers.assert_eq(reason, "launcher_unavailable")
			helpers.assert_eq(prompts, 0)
		end, debug.traceback)
		os.getenv = getenv
		if not ok then error(err, 0) end
	end)

	helpers.it("reports only the retained backup path from an AppleScript failure", function()
		local previous = package.loaded["infra.logger"]
		local logger, messages = helpers.make_logger_stub(), {}
		logger.error = function(_, fmt, ...) messages[#messages + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"] = logger
		local ok, err = xpcall(function()
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				osascript = { applescript = function() return false, nil,
					"native private text /Library/Keyboard Layouts/.ergopti-install.Abc123/backup. ignored" end },
			})
			helpers.assert_eq(install.install_system("/tmp/source", "Ergopti_v2.0.0.bundle"), false)
			helpers.assert_eq(messages[#messages],
				"Keyboard layout backups retained at /Library/Keyboard Layouts/.ergopti-install.Abc123/backup.")
		end, debug.traceback)
		package.loaded["infra.logger"] = previous
		if not ok then error(err, 0) end
	end)
	helpers.it("retains the backup when a concurrent bundle occupies rollback (layout-rollback-exclusive)", function()
		local quote = require("text_utils").shell_quote
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
			local committed = os.execute("PATH=" .. quote(root .. ":" .. getenv("PATH"))
				.. " /bin/sh -c " .. quote(rewritten) .. " >/dev/null 2>&1")
			helpers.assert_eq(committed, nil, "the collision must refuse publication")
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

	helpers.it("does not remove the user copy before administrator approval", function()
		local execute_calls = {}
		local scripts = {}
		local install = helpers.load_with_stubs("modules.keymap.layout_install", {
			execute = function(command)
				execute_calls[#execute_calls + 1] = command
				return "", true, "exit", 0
			end,
			osascript = {
				applescript = function(script)
					scripts[#scripts + 1] = script
					return false, nil, "cancelled"
				end,
			},
		})

		helpers.assert_eq(
			install.install_system("/tmp/layout source/", "Ergopti_v2.0.0.bundle"),
			false)
		helpers.assert_eq(#scripts, 1, "system install must request authorization once")
		helpers.assert_eq(#execute_calls, 0,
			"a cancelled privileged transaction must leave the user copy untouched")
		assert_copy_precedes_replacement(scripts[1], "system install")
	end)

	helpers.it("removes the other scope only after the new user bundle commits", function()
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
		helpers.assert_eq(#commands, 2)
		assert_copy_precedes_replacement(commands[1], "user install")
		helpers.assert_true(commands[2]:find("/Library/Keyboard Layouts", 1, true) ~= nil,
			"system-scope cleanup must run only after the user transaction commits")
	end)

	helpers.it("removes the user scope only after the system transaction commits", function()
		local events = {}
		local install = helpers.load_with_stubs("modules.keymap.layout_install", {
			execute = function(command)
				events[#events + 1] = { kind = "cleanup", payload = command }
				return "", true, "exit", 0
			end,
			osascript = {
				applescript = function(script)
					events[#events + 1] = { kind = "privileged", payload = script }
					return true, nil, ""
				end,
			},
		})

		helpers.assert_eq(
			install.install_system("/tmp/layout source/", "Ergopti_v2.0.0.bundle"),
			true)
		helpers.assert_eq(#events, 2)
		helpers.assert_eq(events[1].kind, "privileged",
			"the privileged copy transaction must commit before user cleanup")
		assert_copy_precedes_replacement(events[1].payload, "system install")
		helpers.assert_eq(events[2].kind, "cleanup")
	end)

	helpers.it("refuses reentrant installs across both bundle scopes", function()
		local execute_calls = 0
		local privileged_calls = 0
		local nested_system_result
		local nested_user_result
		local install
		install = helpers.load_with_stubs("modules.keymap.layout_install", {
			execute = function()
				execute_calls = execute_calls + 1
				return "", true, "exit", 0
			end,
			osascript = {
				applescript = function()
					privileged_calls = privileged_calls + 1
					if privileged_calls == 1 then
						nested_system_result = install.install_system(
							"/tmp/layout source/", "Ergopti_v2.0.0.bundle")
						nested_user_result = install.install_user(
							"/tmp/layout source/", "Ergopti_v2.0.0.bundle")
					end
					return false, nil, "cancelled"
				end,
			},
		})

		helpers.assert_eq(
			install.install_system("/tmp/layout source/", "Ergopti_v2.0.0.bundle"),
			false)
		helpers.assert_eq(privileged_calls, 1,
			"a reentrant system install must not open a second administrator prompt")
		helpers.assert_eq(execute_calls, 0,
			"a reentrant user install must not mutate either shared layout directory")
		helpers.assert_eq(nested_system_result, false)
		helpers.assert_eq(nested_user_result, false)

		helpers.assert_eq(
			install.install_user("/tmp/layout source/", "Ergopti_v2.0.0.bundle"),
			true,
			"the install owner must be released after the first attempt returns")
		helpers.assert_eq(execute_calls, 2,
			"the admitted user install must run one replacement and one cleanup")
	end)
end)

os.getenv = original_getenv


-- The macOS 26 TIS probe showed that the same bundle in both folders makes macOS load both copies
-- and renumber one; a user install must not write the second copy.
helpers.describe("layout_install: one copy per bundle (composer-macos26)", function()
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
			helpers.assert_eq(install.install_user("/tmp/bundles", "Ergopti_v1.0.0.bundle"), true)
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
		local original_fs, original_dir = package.loaded["adapters.file_system"], package.loaded["infra.fs_dir"]
		package.loaded["adapters.file_system"], package.loaded["infra.fs_dir"] = nil, nil
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
		package.loaded["adapters.file_system"], package.loaded["infra.fs_dir"] = original_fs, original_dir
		if not ok then error(err, 0) end
	end)

	helpers.it("does not publish a partial native resource enumeration", function()
		local original_popen = io.popen
		local original_fs, original_dir = package.loaded["adapters.file_system"], package.loaded["infra.fs_dir"]
		package.loaded["adapters.file_system"], package.loaded["infra.fs_dir"] = nil, nil
		local ok, err = xpcall(function()
			local scans, fail_stat = 0, false
			io.popen = function()
				scans = scans + 1
				local delivered = false
				return { lines = function() return function()
					if delivered then return nil end
					delivered = true
					return "/root/Fallback.bundle/Contents/Resources/fallback.keylayout"
				end end, close = function() return true end }
			end
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				fs = {
					symlinkAttributes = function()
						if fail_stat then error("attribute read refused") end
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
		end, debug.traceback)
		io.popen = original_popen
		package.loaded["adapters.file_system"], package.loaded["infra.fs_dir"] = original_fs, original_dir
		if not ok then error(err, 0) end
	end)
end)
