-- Root controls use the retained native-port fixture, never copied production bodies.
local repository = assert(arg[1], "Pass the repository root")
local directory = assert(arg[0]:match("^(.*)/[^/]+$"), "Pass the program path")
local file = assert(io.open(directory .. "/../linux/owner-probe.lua", "rb"))
local source = assert(file:read("*a"))
file:close()
local boundary = assert(source:find('\nscenario("normal-10-second-idle"', 1, true), "Fixture boundary changed")
local scenario = assert((loadstring or load)(source:sub(1, boundary - 1) .. "\nreturn scenario\n", "@retained-capsword-native-port-fixture"))()
local config = [[
[shortcuts.caps_word]
idle_timeout_seconds = 0
terminators = []
[shortcuts.caps_word.pointer]
gesture = false
pointer_motion = false
left_click = false
right_click = false
middle_click = false
other_buttons = false
]]
local observations = {}
for _, entry in ipairs({ { name = "escape", code = 1 }, { name = "left", code = 105 } }) do
	scenario("root-fixed-exit-" .. entry.name, config, function(context)
		context.seed()
		assert(context.manager.is_caps_word_active())
		assert(context.drive({ { type = 1, code = entry.code, value = 1, at_ms = 10 },
			{ type = 1, code = entry.code, value = 0, at_ms = 11 } }) == 2)
		assert(context.semantic[#context.semantic].key == entry.name)
		assert(context.manager.is_caps_word_active() and context.capture.caps_locked())
		observations[#observations + 1] = { key = entry.name, active = true, observed_control = true }
	end)
end
print("ROOT_FIXED_EXITS=" .. assert(require("json").encode({
	qualification = "Actual Linux hook and manager over recorded XKB/uinput ports; no native application receiving. The macOS comparison comes from its separately executed actual generator tests, not this fixture.",
	observations = observations,
})))
