--- tests/hardware/run_xkb_plan_utf8_missing_map.lua

--- ==============================================================================
--- MODULE: Public UTF-8 Plan Receipts Before and After Native Layout Availability
--- DESCRIPTION:
--- Starts with a genuinely fresh production adapter, then loads an actual
--- compiled French map. Malformed inputs must have no blocker in either state;
--- valid missing-map, native mapping and nonstring receipts remain unchanged.
--- No fake backend, graphical session or physical keyboard is exercised.
--- ==============================================================================

local Layout = require("adapters.keyboard_layout")
local Capture = require("adapters.xkb_capture")
local Shell = require("adapters.shell_runner")
local FileSystem = require("adapters.file_system")
local Rmlvo = require("infra.xkb_rmlvo")
local _checks, _failures = 0, 0

--- Records a production public API receipt.
--- @param condition boolean
--- @param label string
local function check(condition, label)
	_checks = _checks + 1
	print((condition and "PASS " or "FAIL ") .. label)
	if not condition then _failures = _failures + 1 end
end

local malformed = { string.char(0x80) .. "az", string.char(0xFF) .. "az",
	"a" .. string.char(0xC0, 0xAF) .. "z", "az" .. string.char(0xF5, 0x80, 0x80, 0x80),
	"a" .. string.char(0xC2), string.char(0xC2) .. "az", string.char(0xE0, 0x80, 0xAF) .. "az",
	string.char(0xED, 0xA0, 0x80) .. "az", string.char(0xF4, 0x90, 0x80, 0x80) .. "az" }

--- Compares the same public contract in both genuine availability states.
--- @param ready boolean
local function receipts(ready)
	check(Layout.is_ready() == ready, ready and "actual compiled map is ready" or "fresh public adapter has no map")
	for index, text in ipairs(malformed) do
		local plan, blocker = Layout.plan(text)
		check(plan == nil and blocker == nil, "malformed input " .. index .. " has no blocker with ready=" .. tostring(ready))
	end
	for _, text in ipairs({ "", "a", "é", "\0", "😀" }) do
		local plan, blocker = Layout.plan(text)
		if not ready then
			check(plan == nil and blocker == text:sub(1, 1), "valid missing-map receipt " .. string.format("%q", text))
		elseif text == "\0" or text == "😀" then
			check(plan == nil and blocker == text, "valid unsupported scalar receipt " .. string.format("%q", text))
		else
			local output, plain = {}, true
			for _, hit in ipairs(plan or {}) do
				plain = plain and #hit.mods == 0
				output[#output + 1] = Capture.peek_text(hit.keycode) or ""
			end
			check(plan ~= nil and blocker == nil and plain and table.concat(output) == text,
				"valid supported receipt equals genuine native text " .. string.format("%q", text))
		end
	end
	for _, text in ipairs({ false, 17, {} }) do
		local plan, blocker = Layout.plan(text)
		check(plan == nil and blocker == nil, "nonstring receipt with ready=" .. tostring(ready) .. " type=" .. type(text))
	end
	local nil_plan, nil_blocker = Layout.plan(nil)
	check(nil_plan == nil and nil_blocker == nil, "nil input receipt with ready=" .. tostring(ready))
end

receipts(false)
local map = Shell.exec(Rmlvo.compile_command(assert(Rmlvo.parse_gnome("[('xkb', 'fr')]"))))
assert(type(map) == "string" and map:find("xkb_keymap", 1, true), "the genuine compiler must produce a French map")
local path = os.tmpname()
assert(FileSystem.write(path, map))
local ok, err = pcall(function()
	assert(Layout.refresh(path), "the actual map must load through public refresh")
	receipts(true)
end)
Capture.clear()
assert(os.remove(path))
if not ok then error(err, 0) end
assert(_checks == 38, "all nineteen before-map and nineteen native-loaded receipts must run")
print(string.format("Public native UTF-8 plan availability: %d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
