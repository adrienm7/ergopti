--- tests/hardware/run_xkb_localectl_variants.lua

--- ==============================================================================
--- MODULE: Native Localectl Variant Slot Regression
--- DESCRIPTION:
--- Compiles descriptors through the production RMLVO command and loads the real
--- keymap through KeyboardLayout.refresh. Localectl output is a text fixture;
--- compiler, files and libxkbcommon are native. No physical input is exercised.
--- ==============================================================================

local Rmlvo = require("infra.xkb_rmlvo")
local Shell = require("adapters.shell_runner")
local Layout = require("adapters.keyboard_layout")
local Capture = require("adapters.xkb_capture")
local FileSystem = require("adapters.file_system")

local _checks, _failures = 0, 0

--- Records a native production-path assertion.
--- @param condition boolean
--- @param label string
local function check(condition, label)
	_checks = _checks + 1
	if condition then
		print("PASS " .. label)
	else
		_failures = _failures + 1
		print("FAIL " .. label)
	end
end

local controls = {
	{ name = "empty first variant", variant = ",dvorak", expected_variant = "", expected_text = "q" },
	{ name = "spaced empty first variant", variant = " , intl", expected_variant = "", expected_text = "q" },
	{ name = "explicit first variant", variant = "dvorak,intl", expected_variant = "dvorak", expected_text = "'" },
	{ name = "absent variant", expected_variant = "", expected_text = "q" },
}

for _, control in ipairs(controls) do
	local status = "   X11 Layout: us,us\n"
	if control.variant then status = status .. "  X11 Variant: " .. control.variant .. "\n" end
	local desc = assert(Rmlvo.parse_localectl(status))
	check(desc.layout == "us" and desc.variant == control.expected_variant,
		control.name .. " keeps the variant paired with its first layout")
	local text, compile_error = Shell.exec(Rmlvo.compile_command(desc))
	assert(type(text) == "string" and text:find("xkb_keymap", 1, true),
		"native keymap compilation failed: " .. tostring(compile_error))
	local path = os.tmpname()
	assert(FileSystem.write(path, text))
	local ok, result = pcall(function()
		assert(Layout.refresh(path), "the real compiled keymap must load")
		local plan = assert(Layout.plan("q"), "the layout must plan its own ASCII q")
		local hit = plan[1]
		check(Capture.peek_text(16) == control.expected_text and #plan == 1
			and #hit.mods == 0 and Capture.peek_text(hit.keycode) == "q",
			control.name .. " uses the native first-layout mapping and lossless inverse plan")
	end)
	Capture.clear()
	assert(os.remove(path))
	if not ok then error(result, 0) end
end

assert(_checks == 8, "the native regression matrix must run all eight checks")
print(string.format("Native XKB localectl variants: %d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
