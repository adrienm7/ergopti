--- tests/hardware/run_keymap_native_dump.lua

--- ==============================================================================
--- MODULE: In-process X11 Keymap Dump (real X server)
--- DESCRIPTION:
--- On X11 the layout is resolved from the keymap the source probe serializes
--- through libxkbcommon-x11 (adapters/xkb_source_probe.dump_keymap), instead of
--- forking xkbcomp: about 40 ms a resolve before, 12 ms after, measured on Xvfb
--- on 2026-11-11.
---
--- WHAT IT PINS, PER LAYOUT (us, fr, de, ch(fr), us(dvorak)):
--- 1. The text parser reads both dumps alike: infra/xkb_keymap entries from the
---    in-process text equal those from `xkbcomp -xkb` for every key, level and
---    keysym the parser knows, so the text model behind base_symbol() and the
---    heatmap labels cannot change with the dump's origin.
--- 2. keyboard_layout.refresh() resolves through the in-process dump and types
---    the same characters as a refresh through xkbcomp's text.
--- 3. A refresh through the in-process dump stays under REFRESH_BUDGET_MS.
---
--- HOW TO RUN IT (run_perf_budget_container.py does it in CI):
---   xvfb-run -a luajit tests/hardware/run_keymap_native_dump.lua
--- Exit 0 = every assertion held. 1 = a failure. 2 = no X server or tool.
--- ==============================================================================

local luv = require("luv")

-- Through xkbcomp a refresh took 38 to 45 ms on Xvfb, through the in-process
-- dump 11 to 14 ms; the budget sits between them with room for a slow runner.
local REFRESH_BUDGET_MS = 25
local LAYOUTS = { { "us" }, { "fr" }, { "de" }, { "ch", "fr" }, { "us", "dvorak" } }

if not os.getenv("DISPLAY") or os.getenv("DISPLAY") == "" then
	io.stderr:write("ENVIRONMENT: no DISPLAY\n")
	os.exit(2)
end
local ok_xkbcomp = os.execute("command -v xkbcomp >/dev/null 2>&1")
if not (ok_xkbcomp == true or ok_xkbcomp == 0) then
	io.stderr:write("ENVIRONMENT: xkbcomp is missing\n")
	os.exit(2)
end

local logger = require("core.logger.engine")
logger.set_sink(function() end)
logger.set_level(40)
local Probe = require("layouts.adapters.xkb_source_probe")
local KeyboardLayout = require("layouts.adapters.keyboard_layout")
local XkbKeymap = require("layouts.engine.xkb_keymap")

local failures = 0
local function check(condition, message)
	print((condition and "  ok   " or "  FAIL ") .. message)
	if not condition then failures = failures + 1 end
end

local function shell(command)
	local handle = assert(io.popen(command))
	local out = handle:read("*a")
	handle:close()
	return out
end

--- Every parsed entry as one sorted list of "keycode level keysym" rows.
local function entries(text)
	local rows = {}
	for _, entry in ipairs(XkbKeymap.parse(text, 1)) do
		rows[#rows + 1] = string.format("%d %d %s", entry.keycode, entry.level, tostring(entry.keysym))
	end
	table.sort(rows)
	return rows
end

--- The first rows two sorted lists disagree on, for the failure message.
local function first_difference(left, right)
	for index = 1, math.max(#left, #right) do
		if left[index] ~= right[index] then
			return tostring(left[index]) .. " / " .. tostring(right[index])
		end
	end
	return "none"
end

--- The characters the resolved layout can type, as one sorted string.
local function typable()
	local chars = {}
	for _, char in ipairs({ "a", "q", "z", "y", "w", "m", ";", "é", "è", "à", "ç", "ü", "ö", "ä", "ß", "€", "@", "#" }) do
		if KeyboardLayout.resolve(char) then chars[#chars + 1] = char end
	end
	return table.concat(chars, " ")
end

for _, layout in ipairs(LAYOUTS) do
	local name = layout[1] .. (layout[2] and ("(" .. layout[2] .. ")") or "")
	local switched = os.execute("setxkbmap " .. layout[1] .. (layout[2] and (" -variant " .. layout[2]) or ""))
	check(switched == true or switched == 0, name .. ": setxkbmap applied the layout")
	local native, reason = Probe.dump_keymap()
	check(native ~= nil and native:find("xkb_keymap", 1, true) ~= nil,
		name .. ": the probe serializes the server keymap (" .. tostring(reason) .. ")")
	local tool = shell('xkbcomp -xkb "$DISPLAY" - 2>/dev/null')
	local from_native, from_tool = entries(native or ""), entries(tool)
	check(#from_native > 100 and #from_native == #from_tool and first_difference(from_native, from_tool) == "none",
		string.format("%s: the parser reads both dumps alike (%d / %d entries; first difference %s)",
			name, #from_native, #from_tool, first_difference(from_native, from_tool)))

	local started = luv.hrtime()
	check(KeyboardLayout.refresh() == true, name .. ": refresh() resolves the layout")
	local elapsed = (luv.hrtime() - started) / 1e6
	check(KeyboardLayout.source() == "libxkbcommon-x11 (in process)",
		name .. ": through the in-process dump (" .. tostring(KeyboardLayout.source()) .. ")")
	check(elapsed < REFRESH_BUDGET_MS, string.format("%s: refresh took %.1f ms (budget %d ms)", name, elapsed,
		REFRESH_BUDGET_MS))
	local native_chars = typable()
	local override = os.tmpname()
	local handle = assert(io.open(override, "wb"))
	handle:write(tool)
	handle:close()
	check(KeyboardLayout.refresh(override) == true, name .. ": refresh() resolves xkbcomp's text as an override")
	os.remove(override)
	check(typable() == native_chars, name .. ": both dumps type the same characters (" .. native_chars .. ")")
end

os.execute("setxkbmap us")
Probe.close()
os.exit(failures == 0 and 0 or 1)
