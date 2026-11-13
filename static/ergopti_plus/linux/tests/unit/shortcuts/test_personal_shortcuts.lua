--- tests/unit/shortcuts/test_personal_shortcuts.lua

--- ==============================================================================
--- MODULE: Personal Shortcuts Source (Linux)
--- DESCRIPTION:
--- `open_personal_shortcuts` used to open `personal_shortcuts.toml`, a file no
--- Linux code read. It now opens the programmable personal source, as Windows
--- (personal .ahk) and macOS (personal_shortcuts.lua) do: the file is created
--- from its template when absent, never overwritten, and the daemon runs it
--- once at start without letting an error in it stop the start.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body with a fresh module whose configuration folder is a new directory.
--- @param body function Receives the module and the folder.
local function with_folder(body)
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute("mkdir -p '" .. dir .. "'")
	assert(made == true or made == 0, "mkdir")
	local saved_paths = package.loaded["settings.engine.paths"]
	local saved_module = package.loaded["shortcuts.engine.personal_shortcuts"]
	package.loaded["settings.engine.paths"] = { config = function(rel) return dir .. "/" .. rel end }
	package.loaded["shortcuts.engine.personal_shortcuts"] = nil
	local ok, err = pcall(body, require("shortcuts.engine.personal_shortcuts"), dir)
	package.loaded["settings.engine.paths"] = saved_paths
	package.loaded["shortcuts.engine.personal_shortcuts"] = saved_module
	os.execute("rm -rf '" .. dir .. "'")
	if not ok then error(err, 0) end
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

local function write(path, content)
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

helpers.describe("linux personal shortcuts source (linux-open-personal-shortcuts)", function()
	helpers.it("personal shortcuts: the open action resolves to the programmable Lua source, created from the template", function()
		with_folder(function(Personal, dir)
			local path = Personal.path_for_editing()
			helpers.assert_eq(path, dir .. "/personal_shortcuts.lua")
			helpers.assert_eq(read(path), Personal.TEMPLATE, "an absent file is created from the template")
			helpers.assert_true(load(Personal.TEMPLATE) ~= nil, "the template itself is valid Lua")
		end)
	end)

	helpers.it("personal shortcuts: an existing file is opened as it is, never replaced", function()
		with_folder(function(Personal, dir)
			write(dir .. "/personal_shortcuts.lua", "-- mine\n")
			helpers.assert_eq(Personal.path_for_editing(), dir .. "/personal_shortcuts.lua")
			helpers.assert_eq(read(dir .. "/personal_shortcuts.lua"), "-- mine\n")
		end)
	end)

	helpers.it("personal shortcuts: the daemon runs the file once, and an error in it is contained", function()
		with_folder(function(Personal, dir)
			_G.__ergopti_personal_test_runs = 0
			write(dir .. "/personal_shortcuts.lua", "__ergopti_personal_test_runs = __ergopti_personal_test_runs + 1\n")
			helpers.assert_eq(Personal.load(), true)
			helpers.assert_eq(_G.__ergopti_personal_test_runs, 1, "the user code ran")
			local ok = pcall(Personal.load)
			helpers.assert_eq(ok, false, "a second load in one process is refused")
			helpers.assert_eq(_G.__ergopti_personal_test_runs, 1)
			_G.__ergopti_personal_test_runs = nil
		end)
		with_folder(function(Personal, dir)
			write(dir .. "/personal_shortcuts.lua", "error('boom')\n")
			helpers.assert_eq(Personal.load(), false, "the error is reported, not raised")
		end)
	end)

	helpers.it("personal shortcuts: the gesture action opens the Lua source, not the dead TOML", function()
		with_folder(function(_, dir)
			local commands, real = {}, os.execute
			os.execute = function(cmd) commands[#commands + 1] = tostring(cmd) return true end
			local ok, err = pcall(function()
				local Gestures = helpers.load_module("gestures.engine.manager")
				Gestures.execute_action("open_personal_shortcuts", "test__slot")
			end)
			os.execute = real
			if not ok then error(err, 0) end
			local text = table.concat(commands, "\n")
			helpers.assert_true(text:find(dir .. "/personal_shortcuts.lua", 1, true) ~= nil, text)
			helpers.assert_true(text:find("personal_shortcuts.toml", 1, true) == nil, text)
		end)
	end)
end)
