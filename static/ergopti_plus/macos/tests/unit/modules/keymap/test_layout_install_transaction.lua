--- tests/unit/modules/keymap/test_layout_install_transaction.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Install Transaction Regression
--- DESCRIPTION:
--- A replacement bundle is staged and verified before any installed copy is
--- moved, cancellation never removes the other scope, and failed attempts
--- invalidate the discovery cache before the menu reads it again.
--- ==============================================================================

local helpers = require("tests.helpers")


local function with_fake_bundle_listing(initial_name, callback)
	local original_popen = io.popen
	local listing = initial_name
	local scans = 0
	io.popen = function(_command)
		scans = scans + 1
		local delivered = false
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
	helpers.assert_true(command_view:find('mv "$prior" "$target/"', 1, true) ~= nil,
		label .. " must restore every retained bundle after a publication failure")
	helpers.assert_true(command_view:find("restore_ok=0", 1, true) ~= nil,
		label .. " must preserve the rollback directory when restoration refuses")
end


helpers.describe("layout_install: transactional replacement", function()
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
end)
