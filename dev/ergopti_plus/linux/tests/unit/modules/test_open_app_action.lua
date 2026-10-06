--- tests/unit/modules/test_open_app_action.lua

--- ==============================================================================
--- MODULE: open_app and its app parameter (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/app_vectors.json, which the
--- macOS and Windows suites replay too, through the gesture validator, then
--- runs open_app through the real executor with a recording shell: the
--- binding's desktop-file id is handed to gtk-launch, quoted, in the background.
---
--- ROOT CAUSE ENCODED:
--- No action could open a chosen application.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/action_parameters/app_vectors.json"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the app corpus is not valid JSON")
end

--- Runs `body` with os.execute recording instead of running.
--- @param body function Receives the recorded command table.
local function with_recorded_shell(body)
	local commands = {}
	local real = os.execute
	os.execute = function(cmd)
		commands[#commands + 1] = tostring(cmd)
		return true
	end
	local ok, err = pcall(body, commands)
	os.execute = real
	if not ok then error(err, 0) end
end

helpers.describe("open_app replays the shared app corpus (Linux)", function()
	local Gestures = helpers.load_module("modules.gestures.manager")
	local corpus = read_corpus()

	helpers.it("the parameter is declared (open-app)", function()
		helpers.assert_eq(Gestures.get_action_parameter_spec("open_app"), "app")
		helpers.assert_true(#corpus.vectors >= 15, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("app vector '" .. vector.id .. "' (open-app)", function()
			helpers.assert_eq(Gestures.validate_action_parameter("open_app", vector.value), vector.valid ~= false,
				vector.id .. ": validation")
		end)
	end

	helpers.it("launches the binding's desktop entry through gtk-launch (open-app)", function()
		local saved = Gestures.get_action_parameter("tap_3", "open_app")
		helpers.assert_eq(saved, "", "the binding starts with no application")
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_app", "tap_3")
			helpers.assert_eq(#commands, 0, "no application stored, nothing launched")
		end)
		helpers.assert_true(Gestures.set_action_parameter("tap_3", "open_app", "org.gnome.Nautilus"))
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_app", "tap_3")
			helpers.assert_eq(commands[#commands], "gtk-launch -- 'org.gnome.Nautilus' 2>/dev/null &")
		end)
	end)

	helpers.it("hands option-looking desktop ids to the launcher as applications (open-app-operand)", function()
		for _, application in ipairs({ "--version", "-help", "app with ' quote" }) do
			helpers.assert_true(Gestures.set_action_parameter("tap_3", "open_app", application))
			with_recorded_shell(function(commands)
				Gestures.execute_action("open_app", "tap_3")
				helpers.assert_eq(#commands, 1)
				local quoted = require("adapters.shell_runner").quote(application)
				helpers.assert_eq(commands[1], "gtk-launch -- " .. quoted .. " 2>/dev/null &")
			end)
		end
	end)
end)
