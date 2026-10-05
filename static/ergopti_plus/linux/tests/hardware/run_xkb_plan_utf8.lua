--- tests/hardware/run_xkb_plan_utf8.lua

--- ==============================================================================
--- MODULE: Native Keyboard Layout UTF-8 Plan Regression
--- DESCRIPTION:
--- Loads an actual compiled French map through the public layout adapter and
--- refuses malformed payloads before a partial inverse plan can report success.
--- Native libxkbcommon replay proves healthy output. No physical device is used.
--- ==============================================================================

local Layout = require("adapters.keyboard_layout")
local Capture = require("adapters.xkb_capture")
local Shell = require("adapters.shell_runner")
local FileSystem = require("adapters.file_system")
local Rmlvo = require("infra.xkb_rmlvo")
local Codes = require("infra.evdev_codes")

local _checks, _failures = 0, 0

--- Records a production-path assertion with actual native XKB state.
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

--- Replays only a successful public plan through the actual capture backend.
--- @param plan table
--- @return string
local function replay(plan)
	local output = {}
	for _, hit in ipairs(plan) do
		for _, name in ipairs(hit.mods) do assert(select(3, Capture.process(Codes.LEVEL_MODIFIER_CODE[name], 1)) == nil) end
		local text, _, err = Capture.process(hit.keycode, 1)
		assert(err == nil)
		assert(select(3, Capture.process(hit.keycode, 0)) == nil)
		for i = #hit.mods, 1, -1 do assert(select(3, Capture.process(Codes.LEVEL_MODIFIER_CODE[hit.mods[i]], 0)) == nil) end
		output[#output + 1] = text or ""
	end
	return table.concat(output)
end

local desc = assert(Rmlvo.parse_gnome("[('xkb', 'fr')]"))
local map = Shell.exec(Rmlvo.compile_command(desc))
assert(type(map) == "string" and map:find("xkb_keymap", 1, true), "the native compiler must produce a French keymap")
local path = os.tmpname()
assert(FileSystem.write(path, map))
local ok, err = pcall(function()
	assert(Layout.refresh(path), "the real compiled map must load through the production adapter")
	for _, spec in ipairs({
		{ name = "leading continuation", text = string.char(0x80) .. "az" },
		{ name = "leading invalid byte", text = string.char(0xFF) .. "az" },
		{ name = "interspersed overlong encoding", text = "a" .. string.char(0xC0, 0xAF) .. "z" },
		{ name = "trailing invalid lead", text = "az" .. string.char(0xF5, 0x80, 0x80, 0x80) },
		{ name = "truncated two-byte sequence", text = "a" .. string.char(0xC2) },
		{ name = "invalid continuation", text = string.char(0xC2) .. "az" },
		{ name = "overlong three-byte scalar", text = string.char(0xE0, 0x80, 0xAF) .. "az" },
		{ name = "UTF-16 surrogate", text = string.char(0xED, 0xA0, 0x80) .. "az" },
		{ name = "out-of-range scalar", text = string.char(0xF4, 0x90, 0x80, 0x80) .. "az" },
	}) do
		local plan, blocker = Layout.plan(spec.text)
		local received = plan and replay(plan) or ""
		check(plan == nil and blocker == nil, spec.name .. " refuses whole-input planning; original native output " .. string.format("%q", received))
	end
	for _, text in ipairs({ "", "az", "Bonjour", "éàçù", "€ @?!" }) do
		local plan, blocker = Layout.plan(text)
		check(plan ~= nil and blocker == nil and replay(plan) == text,
			"valid UTF-8 retains exact native output " .. string.format("%q", text))
	end
	local unsupported, blocker = Layout.plan("a😀z")
	check(unsupported == nil and blocker == "😀", "valid unsupported scalar still refuses without a partial plan")
	local nul_plan, nul_blocker = Layout.plan("a\0z")
	check(nul_plan == nil and nul_blocker == "\0", "valid UTF-8 NUL retains its existing unsupported-character receipt")
end)
Capture.clear()
assert(os.remove(path))
if not ok then error(err, 0) end
assert(_checks == 16, "the native UTF-8 plan matrix must run all sixteen checks")
print(string.format("Native XKB UTF-8 plans: %d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
