--- tests/unit/adapters/system/test_accessibility_copies.lua

--- ==============================================================================
--- MODULE: Accessibility copies adapter (accessibility-other-copies)
--- DESCRIPTION:
--- A local build and the installed prerelease share the runtime bundle
--- identifier, and the Accessibility switch the user turned on could be the
--- other copy's; the boot then reset the entry at every reload (field report
--- 2026-11-05). The probe must report every other copy whose signature
--- differs, by the app path the user sees, and turn a refused probe into an
--- error rather than an empty list.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "adapters.accessibility_copies", "adapters.shell_runner" }
local OWN = "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app"

--- Runs body against a fresh adapter whose shell runner records each spawn.
--- @param body function Receives the adapter and the recorded spawns.
local function with_probe(body)
	helpers.with_fresh_modules(MODULES, function()
		local spawns = {}
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local spawn = { executable = executable, args = args, on_done = on_done, started = true }
				spawns[#spawns + 1] = spawn
				return { start = function() return spawn.started end }
			end,
		}
		body(require("adapters.accessibility_copies"), spawns)
		package.loaded["adapters.shell_runner"] = nil
	end)
end

helpers.describe("accessibility copies adapter (accessibility-other-copies)", function()
	helpers.it("names each other copy by its app, once, in order", function()
		with_probe(function(copies)
			local paths = copies.parse(table.concat({
				"/Users/me/build/macos/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app",
				"/Applications/Old ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app",
				"/Users/me/build/macos/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app",
				"/Applications/Hammerspoon.app",
				"",
			}, "\n"))
			helpers.assert_eq(#paths, 3, table.concat(paths, ","))
			helpers.assert_eq(paths[1], "/Applications/Hammerspoon.app")
			helpers.assert_eq(paths[2], "/Applications/Old ErgoptiPlus.app")
			helpers.assert_eq(paths[3], "/Users/me/build/macos/ErgoptiPlus.app")
			helpers.assert_eq(#copies.parse(""), 0, "no line, no copy")
		end)
	end)

	helpers.it("probes both registries and compares designated requirements", function()
		with_probe(function(copies, spawns)
			helpers.assert_eq(copies.find("com.ergoptiplus.app.hammerspoon", OWN, function() end), true)
			local spawn = spawns[1]
			helpers.assert_eq(spawn.executable, "/bin/sh")
			helpers.assert_eq(spawn.args[1], "-c")
			helpers.assert_eq(spawn.args[4], "com.ergoptiplus.app.hammerspoon")
			helpers.assert_eq(spawn.args[5], OWN)
			helpers.assert_contains(spawn.args[6], "/LaunchServices.framework/Support/lsregister")
			local script = spawn.args[2]
			helpers.assert_contains(script, "/usr/bin/mdfind", "Spotlight lists the indexed copies")
			helpers.assert_contains(script, '"$lsr" -dump', "LaunchServices lists every registered one")
			helpers.assert_contains(script, "codesign -d -r-", "TCC matches a client by its designated requirement")
			helpers.assert_contains(script, '[ "$path" != "$own_path" ]', "the running copy is never reported")
		end)
	end)

	helpers.it("answers the parsed copies, or an error for a refused probe", function()
		with_probe(function(copies, spawns)
			local answers = {}
			local function record(paths, detail) answers[#answers + 1] = { paths = paths, detail = detail } end
			copies.find("com.ergoptiplus.app.hammerspoon", OWN, record)
			spawns[1].on_done(0, "/Users/me/b/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app\n", "")
			helpers.assert_eq(answers[1].paths[1], "/Users/me/b/ErgoptiPlus.app")
			copies.find("com.ergoptiplus.app.hammerspoon", OWN, record)
			spawns[2].on_done(3, "", "")
			helpers.assert_nil(answers[2].paths, "a copy with no requirement cannot be compared")
			helpers.assert_contains(answers[2].detail, "no readable designated requirement")
			copies.find("com.ergoptiplus.app.hammerspoon", OWN, record)
			spawns[3].on_done(1, "", "lsregister: denied")
			helpers.assert_nil(answers[3].paths, "a failed probe is never an empty list")
			helpers.assert_contains(answers[3].detail, "lsregister: denied")
		end)
	end)

	helpers.it("reports a probe that did not start", function()
		with_probe(function(copies)
			package.loaded["adapters.shell_runner"].spawn = function()
				return { start = function() return false end }
			end
			helpers.assert_eq(copies.find("com.ergoptiplus.app.hammerspoon", OWN, function() end), false)
		end)
	end)

	helpers.it("refuses an identifier or path that could escape the probe", function()
		with_probe(function(copies, spawns)
			for _, bad in ipairs({ "com.x' ; rm -rf ~ ; '", "", 42 }) do
				local ok = pcall(copies.find, bad, OWN, function() end)
				helpers.assert_eq(ok, false, tostring(bad))
			end
			helpers.assert_eq(pcall(copies.find, "com.x", "relative/App.app", function() end), false)
			helpers.assert_eq(#spawns, 0, "nothing ran")
		end)
	end)
end)
