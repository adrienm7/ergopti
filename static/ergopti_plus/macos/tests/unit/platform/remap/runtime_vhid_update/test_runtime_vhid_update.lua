--- tests/unit/platform/remap/runtime_vhid_update/test_runtime_vhid_update.lua

--- ==============================================================================
--- MODULE: Owned Runtime VirtualHIDDevice Driver-Only Update
--- DESCRIPTION:
--- Pins platform/remap/runtime_vhid_update.lua with fake ports: the confirmed
--- update downloads the pinned pqrs package into Ergopti's own folder, checks
--- its size and digest, then runs one privileged shell that checks the digest
--- and the pqrs installer signature again on a root-owned copy before
--- /usr/sbin/installer, and finally asks pqrs' manager to activate it.
---
--- ROOT CAUSE ENCODED: an incompatible VirtualHIDDevice blocked the owned
--- runtime with no way out but a manual reinstall (ADR 011 "driver-only update
--- offer"). The update must install only the pinned, pqrs-signed driver: a
--- download trusted before its digest, a privileged install of the user-writable
--- file, a missing team check, or a cancelled prompt reported as a failure would
--- each break that promise.
--- ==============================================================================

local helpers = require("tests.helpers")
local AppDirs = require("core.fs.engine.app_dirs")

local HOME = "/Users/test/" .. AppDirs.macos.support_relative .. "/RemapRuntime/VirtualHIDDevice/8.5.0"
local DIGEST = "d73d6d9428f0f80b87b8a8ba8a1031f2cbc3bc1fa6b74842d1f1b764b2916fc9"
local FILE = "Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg"

--- The driver pin the shipped manifest carries.
--- @return table pin
local function pin()
	return {
		version = "8.5.0",
		team_identifier = "G43BCU2T37",
		file_name = FILE,
		source_url = "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v8.5.0/" .. FILE,
		sha256 = DIGEST,
		size = 2089117,
	}
end

--- Builds an updater over a fake Mac.
--- @param overrides table|nil Command answers keyed by executable basename.
--- @return table updater
--- @return table world { commands }
--- @return table Update The module.
local function fake(overrides)
	package.loaded["platform.remap.ke_paths"] = nil
	package.loaded["platform.remap.runtime_vhid_update"] = nil
	local Update = require("platform.remap.runtime_vhid_update")
	local world = { commands = {} }
	local answers = {
		stat = function() return 0, "2089117\n" end,
		shasum = function(args) return 0, DIGEST .. "  " .. args[3] .. "\n" end,
	}
	for name, answer in pairs(overrides or {}) do answers[name] = answer end
	local updater = Update.new({
		-- The production port wraps curl behind the network route (NET-001).
		network_command = function(curl_args) return "/usr/bin/curl", curl_args end,
		exec = function(executable, args, timeout, callback)
			local name = executable:match("[^/]+$")
			world.commands[#world.commands + 1] = { executable = executable, name = name, args = args, timeout = timeout }
			local answer = answers[name]
			if answer then return callback(answer(args)) end
			callback(0, "", "")
		end,
		expand = function(path) return (path:gsub("^~", "/Users/test")) end,
	})
	return updater, world, Update
end

--- Runs one update and returns its settlement.
--- @param updater table Updater.
--- @param candidate table Pin.
--- @return table result { ok, reason, detail }
local function update(updater, candidate)
	local result
	updater.update(candidate, function(ok, reason, detail) result = { ok = ok, reason = reason, detail = detail } end)
	return assert(result, "the update did not settle")
end

--- The executables a run called, in order.
--- @param world table Fake world.
--- @return table names
local function called(world)
	local names = {}
	for _, command in ipairs(world.commands) do names[#names + 1] = command.name end
	return names
end

--- The privileged command of a run.
--- @param world table Fake world.
--- @return table|nil command
local function osascript(world)
	for _, command in ipairs(world.commands) do
		if command.name == "osascript" then return command end
	end
	return nil
end





-- =================================
-- =================================
-- ======= 1/ The Happy Path =======
-- =================================
-- =================================

helpers.describe("VirtualHIDDevice driver update: the confirmed update", function()
	helpers.it("downloads, verifies, installs with administrator rights, then asks for activation", function()
		local updater, world, Update = fake()
		local result = update(updater, pin())
		helpers.assert_true(result.ok, tostring(result.detail))
		helpers.assert_eq(called(world), { "rm", "mkdir", "curl", "stat", "shasum", "mv", "osascript",
			"Karabiner-VirtualHIDDevice-Manager" })
		helpers.assert_eq(world.commands[8].executable, Update.MANAGER)
		helpers.assert_eq(world.commands[8].args, { "forceActivate" })
	end)

	helpers.it("downloads over https only into Ergopti's folder, bounded by the pinned size", function()
		local updater, world = fake()
		update(updater, pin())
		local curl = world.commands[3].args
		helpers.assert_contains(table.concat(curl, " "), "--proto =https")
		helpers.assert_contains(table.concat(curl, " "), "--max-filesize 2089117")
		helpers.assert_eq(curl[#curl], pin().source_url)
		for index = 1, 6 do
			for _, argument in ipairs(world.commands[index].args) do
				if argument:sub(1, 1) == "/" then
					helpers.assert_true(argument:sub(1, #HOME) == HOME, "a command reached outside the folder: " .. argument)
				end
			end
		end
	end)

	helpers.it("installs a root-owned copy only after checking its digest and the pqrs team again", function()
		local updater, world = fake()
		update(updater, pin())
		local command = assert(osascript(world), "no privileged command ran")
		helpers.assert_eq(command.args[1], "-e")
		local script = command.args[2]
		helpers.assert_contains(script, "with administrator privileges")
		local copy_at = script:find("/bin/cp -X '" .. HOME .. "/" .. FILE .. "'", 1, true)
		local digest_at = script:find(DIGEST, 1, true)
		local team_at = script:find("Developer ID Installer: .*\\\\(G43BCU2T37\\\\)", 1, true)
		local install_at = script:find('/usr/sbin/installer -pkg \\"$work/driver.pkg\\" -target /', 1, true)
		helpers.assert_true(copy_at ~= nil, "the package is not copied first: " .. script)
		helpers.assert_true(digest_at ~= nil and team_at ~= nil and install_at ~= nil, script)
		helpers.assert_true(copy_at < digest_at and digest_at < team_at and team_at < install_at,
			"the installer must run last, on the checked copy")
		helpers.assert_contains(script, "/usr/bin/mktemp -d /private/tmp/")
	end)
end)





-- =================================
-- =================================
-- ======= 2/ Named Refusals =======
-- =================================
-- =================================

helpers.describe("VirtualHIDDevice driver update: named refusals", function()
	helpers.it("refuses an incomplete pin without running anything", function()
		local updater, world, Update = fake()
		local partial = pin()
		partial.sha256 = nil
		local result = update(updater, partial)
		helpers.assert_eq(result.reason, Update.REASON.UNPINNED)
		helpers.assert_eq(#world.commands, 0)
		local quoted = pin()
		quoted.source_url = "https://example.com/x'y/" .. FILE
		helpers.assert_eq(update(updater, quoted).reason, Update.REASON.UNPINNED)
		local lower_team = pin()
		lower_team.team_identifier = "g43bcu2t37"
		helpers.assert_eq(update(updater, lower_team).reason, Update.REASON.UNPINNED)
	end)

	helpers.it("never prompts for a download of the wrong size or digest", function()
		local updater, world, Update = fake({ stat = function() return 0, "12\n" end })
		helpers.assert_eq(update(updater, pin()).reason, Update.REASON.SIZE)
		helpers.assert_eq(osascript(world), nil)
		local other, other_world = fake({ shasum = function() return 0, string.rep("0", 64) .. "  x\n" end })
		helpers.assert_eq(update(other, pin()).reason, Update.REASON.DIGEST)
		helpers.assert_eq(osascript(other_world), nil)
	end)

	helpers.it("names a refused download", function()
		local updater, world, Update = fake({ curl = function() return 22, "", "curl: (22) 404" end })
		local result = update(updater, pin())
		helpers.assert_eq(result.reason, Update.REASON.DOWNLOAD)
		helpers.assert_contains(result.detail, "404")
		helpers.assert_eq(osascript(world), nil)
	end)

	helpers.it("reads the privileged shell's own refusals and a cancelled prompt", function()
		local cases = {
			{ "0:12: execution error: User canceled. (-128)\n", "vhid_update_cancelled" },
			{ "0:300: execution error: The command exited with a non-zero status. (78)\n", "vhid_update_digest_mismatch" },
			{ "0:300: execution error: The command exited with a non-zero status. (79)\n", "vhid_update_signature_refused" },
			{ "0:300: execution error: installer: Error (1)\n", "vhid_update_install_failed" },
		}
		for _, case in ipairs(cases) do
			local updater, world = fake({ osascript = function() return 1, "", case[1] end })
			local result = update(updater, pin())
			helpers.assert_eq(result.reason, case[2], case[1])
			helpers.assert_eq(called(world)[#world.commands], "osascript", "nothing may follow a refused install")
		end
	end)

	helpers.it("names an activation macOS was not asked for", function()
		local updater, _, Update = fake({ ["Karabiner-VirtualHIDDevice-Manager"] = function() return 1, "", "denied" end })
		helpers.assert_eq(update(updater, pin()).reason, Update.REASON.ACTIVATE)
	end)

	helpers.it("runs one update at a time and settles every caller", function()
		local pending
		local _, _, Update = fake()
		local world = { count = 0 }
		local updater = Update.new({
			-- The production port wraps curl behind the network route (NET-001).
			network_command = function(curl_args) return "/usr/bin/curl", curl_args end,
			exec = function(_, _, _, callback)
				world.count = world.count + 1
				pending = callback
			end,
			expand = function(path) return path end,
		})
		local results = {}
		updater.update(pin(), function(ok) results[#results + 1] = ok end)
		updater.update(pin(), function(ok) results[#results + 1] = ok end)
		helpers.assert_eq(world.count, 1, "a second caller started a second update")
		pending(1, "", "rm failed")
		helpers.assert_eq(results, { false, false })
	end)
end)
