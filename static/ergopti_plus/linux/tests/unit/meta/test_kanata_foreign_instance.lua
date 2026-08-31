--- tests/unit/meta/test_kanata_foreign_instance.lua

--- ==============================================================================
--- MODULE: Kanata Started By Somebody Else
--- DESCRIPTION:
--- What the daemon may and may not do to a kanata process it did not spawn.
---
--- THE DEFECT THIS PINS:
--- `is_running()` answered only for the process this module had started. Most
--- installs run kanata under systemd, so on those machines the answer was
--- always false and the tray\'s "Start kanata" launched a SECOND instance beside
--- the service. Two kanatas grab the same keyboard and both re-emit it: every
--- keystroke arrives twice, or the second grab fails and the remap silently
--- stops applying. Neither symptom points anywhere near the menu item that
--- caused it.
---
--- AND THE SYMMETRIC HALF:
--- Once `is_running()` sees a foreign process, `stop()` must not kill it.
--- systemd would bring it straight back with the config it already had, so the
--- menu would report "stopped" while the remap stayed live — and on a machine
--- without a supervisor it would leave the user\'s session unmapped by a service
--- this daemon was never asked to manage.
---
--- WHY THE SHELL IS STUBBED RATHER THAN RUN:
--- The assertions are about which commands are ISSUED. Running them would need
--- a real kanata on the machine, which neither CI nor the maintainer\'s has, and
--- a test that skips when it is absent asserts nothing on the platform that
--- gates the merge.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs `body` with os.execute answering from a routing table.
---
--- @param answers table Array of { match = string, code = number }, first match
---        wins; anything unmatched succeeds.
--- @param body function Receives the freshly loaded manager and the command log.
local function with_shell(answers, body)
	local module_name = "platform.remap.manager"
	local previous_execute = os.execute
	local previous_popen = io.popen
	local previous_module = package.loaded[module_name]

	local commands = {}
	os.execute = function(command)
		commands[#commands + 1] = command
		for _, answer in ipairs(answers) do
			if command:find(answer.match, 1, true) then return answer.code end
		end
		return 0
	end
	io.popen = function(command)
		commands[#commands + 1] = "POPEN " .. command
		return {
			read = function() return "4242" end,
			lines = function() return function() return nil end end,
			close = function() return true end,
		}
	end

	package.loaded[module_name] = nil
	local ok, err = pcall(function() body(require(module_name), commands) end)

	os.execute = previous_execute
	io.popen = previous_popen
	package.loaded[module_name] = previous_module
	helpers.assert_true(ok, "the manager must not throw: " .. tostring(err))
end

--- Whether any issued command contains `needle`.
--- @param commands table
--- @param needle string
--- @return boolean
local function issued(commands, needle)
	for _, command in ipairs(commands) do
		if command:find(needle, 1, true) then return true end
	end
	return false
end

-- pgrep exits 0 when it finds a process and 1 when it does not.
local FOUND, ABSENT = 0, 1




-- =================================================================
-- =================================================================
-- ======= 1/ It sees a process it did not start ===================
-- =================================================================
-- =================================================================

helpers.describe("kanata: a foreign instance", function()

	helpers.it("is reported as running", function()
		with_shell({ { match = "pgrep -x kanata", code = FOUND } }, function(manager)
			helpers.assert_true(manager.is_running(),
				"the answer used to come only from this module's own pid, so on every "
					.. "systemd install it was false and the tray offered to start a "
					.. "daemon that was already running")
			helpers.assert_true(not manager.owns_process(),
				"and it must stay distinguishable from one we spawned, because that "
					.. "distinction is what makes stopping safe")
		end)
	end)

	helpers.it("is not joined by a second instance", function()
		with_shell({ { match = "pgrep -x kanata", code = FOUND } }, function(manager, commands)
			helpers.assert_true(manager.start(), "start must report the daemon as up")
			helpers.assert_true(not issued(commands, "POPEN kanata"),
				"two kanatas grab the same keyboard and both re-emit it: every "
					.. "keystroke arrives twice, or the second grab fails and the remap "
					.. "silently stops applying")
		end)
	end)

	helpers.it("is not killed", function()
		with_shell({ { match = "pgrep -x kanata", code = FOUND } }, function(manager, commands)
			manager.stop()
			helpers.assert_true(not issued(commands, "kill "),
				"systemd would bring it straight back with the config it already had, "
					.. "so the menu would report 'stopped' while the remap stayed live")
		end)
	end)

	helpers.it("makes restart say what it could not do", function()
		with_shell({ { match = "pgrep -x kanata", code = FOUND } }, function(manager, commands)
			local restarted = manager.restart()
			helpers.assert_true(not restarted,
				"killing a supervised process is not a restart: it comes back with the "
					.. "config it already had, and reporting success would be a lie the "
					.. "user has no way to check")
			helpers.assert_true(not issued(commands, "kill "),
				"and it still must not kill anything on the way to saying so")
		end)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ With nothing running it behaves as before ============
-- =================================================================
-- =================================================================

helpers.describe("kanata: no instance anywhere", function()

	helpers.it("reports not running", function()
		with_shell({ { match = "pgrep -x kanata", code = ABSENT } }, function(manager)
			helpers.assert_true(not manager.is_running(),
				"the new check must not answer yes for every machine, which would "
					.. "make the tray refuse to start kanata at all")
		end)
	end)

	helpers.it("still starts one", function()
		with_shell({
			{ match = "pgrep -x kanata", code = ABSENT },
			{ match = "kill -0", code = ABSENT },
		}, function(manager, commands)
			manager.start()
			helpers.assert_true(issued(commands, "command -v 'kanata'"),
				"with nothing else running, start() must get past the coordination "
					.. "check and go looking for the binary. A fix that disables the "
					.. "thing it coordinates is not a fix.")
		end)
	end)

end)
