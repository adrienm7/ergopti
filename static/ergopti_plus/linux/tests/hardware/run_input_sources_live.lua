--- tests/hardware/run_input_sources_live.lua

--- ==============================================================================
--- MODULE: Layout > « Input sources » On A Real Desktop Session
--- DESCRIPTION:
--- Run by run_input_sources_live.sh inside a headless desktop session (GNOME
--- Shell Wayland, KWin Wayland or X11, openbox on Xvfb, sway). Drives the
--- production chain: adapters/input_source_switch.lua with its native port
--- (gsettings, the KDE keyboard daemon through gdbus, setxkbmap), the menu's
--- rows (ui/menu/active_layout_rows.lua), and the pause switch
--- (modules/keymap/pause_layout_switch.lua) with the real preferences reader
--- on a private config.toml.
---
--- Every switch is checked against the desktop itself, never against the
--- adapter's own reading: ERGOPTI_LIVE_ACTIVE_CMD prints the layout the
--- session types with (the X server's or XWayland's locked group, named by
--- the session's own layout list).
---
--- Environment: ERGOPTI_LIVE_DESKTOP (gnome, kde, x11 or unsupported),
--- ERGOPTI_LIVE_ACTIVE_CMD, ERGOPTI_LIVE_LAYOUTS (what <AD01> types on each of
--- the session's layouts, space separated, in its order), XDG_CONFIG_HOME.
--- Exit 0 = every check held.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path

local uv = require("luv")

local DESKTOP = assert(os.getenv("ERGOPTI_LIVE_DESKTOP"), "run through run_input_sources_live.sh")
local SETTLE_MS = 15000
local _checks, _failures = 0, 0

local function check(condition, text)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local function capture(command)
	local handle = assert(io.popen(command, "r"))
	local output = handle:read("*a")
	handle:close()
	return (output:gsub("%s+$", ""))
end

--- The layout the desktop types with now, read from the desktop itself.
local function desktop_active()
	return capture(assert(os.getenv("ERGOPTI_LIVE_ACTIVE_CMD")) .. " 2>/dev/null")
end

--- Runs the event loop until the switcher settles.
local function settle(switcher)
	local settled = false
	switcher.when_settled(function() settled = true end)
	local timer = uv.new_timer()
	timer:start(50, 50, function() end)
	local deadline = uv.now() + SETTLE_MS
	while not settled and uv.now() < deadline do uv.run("once") end
	timer:stop()
	timer:close()
	-- The desktop applies a setting after the command returns.
	uv.sleep(700)
	return settled
end

local function write_config(on_pause, on_resume)
	local dir = assert(os.getenv("XDG_CONFIG_HOME")) .. "/ergopti"
	os.execute("mkdir -p '" .. dir .. "'")
	local handle = assert(io.open(dir .. "/config.toml", "wb"))
	handle:write(string.format('[layout]\npause_switch_enabled = true\non_pause = "%s"\non_resume = "%s"\n',
		on_pause, on_resume))
	handle:close()
end

local InputSourceSwitch = require("adapters.input_source_switch")
local PauseSwitch = require("modules.keymap.pause_layout_switch")
local Rows = require("ui.menu.active_layout_rows")

local function new_switch()
	PauseSwitch._reset_for_test()
	PauseSwitch.init({
		switcher = InputSourceSwitch.new(InputSourceSwitch.native_port()),
		preferences = require("infra.pause_layout_preferences"),
	})
	return PauseSwitch.switcher()
end

local function menu_rows()
	local errors = {}
	local rows = Rows.rows({
		t = function(key) return key end,
		on_changed = function() end,
		show_error = function(message) errors[#errors + 1] = message end,
		switch = PauseSwitch,
	})
	return rows, errors
end

print("=== Layout > « Input sources » on " .. DESKTOP .. " ===")
local switcher = new_switch()

if DESKTOP == "unsupported" then
	check(switcher.backend() == nil, "the session has no input source backend")
	local rows = menu_rows()
	-- The reason row, in any locale the session may run in.
	local reasons = {}
	for _, locale in ipairs({ "en", "fr" }) do
		local handle = assert(io.open("../_shared/data/locales/" .. locale .. ".json", "rb"))
		local catalogue = require("json").decode(handle:read("*a"))
		handle:close()
		reasons[catalogue["menu.layout.active_layouts_unsupported_desktop"]] = true
	end
	check(#rows == 1 and rows[1].disabled == true and reasons[rows[1].label] == true,
		"the menu shows the unsupported-desktop reason row: " .. tostring(rows[1] and rows[1].label))
	print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
	os.exit(_failures == 0 and 0 or 1)
end

check(switcher.backend() == DESKTOP, "the session's backend is " .. DESKTOP .. " (" .. tostring(switcher.backend()) .. ")")
switcher.refresh()
check(settle(switcher), "the layout listing settles")
local choices = switcher.choices()
local expected = {}
for name in assert(os.getenv("ERGOPTI_LIVE_LAYOUTS")):gmatch("%S+") do expected[#expected + 1] = name end
local ids, ticked = {}, 0
for _, choice in ipairs(choices) do
	ids[#ids + 1] = choice.id
	if choice.active then ticked = ticked + 1 end
end
check(#choices == #expected, "the session's " .. #expected .. " layouts are listed: " .. table.concat(ids, ", "))

local rows = menu_rows()
local labels, checked = {}, 0
for _, row in ipairs(rows) do
	labels[#labels + 1] = tostring(row.label)
	if row.checked then checked = checked + 1 end
end
check(#rows == #expected, "the menu has one row per layout: " .. table.concat(labels, " | "))
if DESKTOP == "x11" then
	check(ticked == 0 and checked == 0, "X11 ticks no row (the active group is not read)")
else
	check(ticked == 1 and checked == 1, DESKTOP .. " ticks exactly one row")
	for index, choice in ipairs(choices) do
		if choice.active then
			check(expected[index] == desktop_active(), "the ticked row is the layout the desktop types with ("
				.. tostring(expected[index]) .. " / " .. desktop_active() .. ")")
		end
	end
end

-- What each layout types on <AD01>, by id, from the first listing (the X11
-- switch reorders the groups, so a row's position names nothing).
local signature_of, id_order = {}, {}
for index, choice in ipairs(choices) do
	signature_of[choice.id] = expected[index]
	id_order[index] = choice.id
end

--- Picks the menu row of one layout and checks the desktop follows.
local function pick(id)
	local row
	for _, candidate in ipairs(menu_rows()) do if candidate.label == id or candidate.id == id then row = candidate end end
	if row == nil then
		for index, choice in ipairs(switcher.choices()) do if choice.id == id then row = menu_rows()[index] end end
	end
	if not check(row ~= nil and type(row.action) == "function", "the row of " .. id .. " can be chosen") then return end
	row.action()
	settle(switcher)
	if desktop_active() ~= signature_of[id] and os.getenv("ERGOPTI_LIVE_GNOME_UNSAFE") then
		print("diagnostic: shell view " .. capture("gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell"
			.. " --method org.gnome.Shell.Eval 'const m = Main.panel.statusArea.keyboard._inputSourceManager;"
			.. " JSON.stringify({current: m.currentSource && m.currentSource.id, mru: m._mruSources.map(s => s.id)})'"))
	end
	check(desktop_active() == signature_of[id], "choosing " .. id .. " switches the desktop to it (<AD01> types "
		.. desktop_active() .. ", " .. id .. " types " .. signature_of[id] .. ")")
end

local start_active = desktop_active()
local first = signature_of[id_order[1]] == start_active and id_order[2] or id_order[1]
pick(first)
pick(first == id_order[1] and id_order[2] or id_order[1])

-- Pause switch: a start running selects the resume layout; a start after a
-- paused reload keeps the pause one.
local pause_id, resume_id = id_order[1], id_order[2]
write_config(pause_id, resume_id)
pick(pause_id)
switcher = new_switch()
PauseSwitch.start_safely(false)
settle(switcher)
check(desktop_active() == signature_of[resume_id], "a running start selects the resume layout " .. resume_id
	.. " (desktop reads " .. desktop_active() .. ")")
switcher = new_switch()
PauseSwitch.start_safely(true)
settle(switcher)
check(desktop_active() == signature_of[pause_id], "a start after a paused reload keeps the pause layout " .. pause_id
	.. " (desktop reads " .. desktop_active() .. ")")
PauseSwitch.on_pause_change(false)
settle(switcher)
check(desktop_active() == signature_of[resume_id], "resuming selects " .. resume_id .. " (<AD01> types "
	.. desktop_active() .. ")")

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
