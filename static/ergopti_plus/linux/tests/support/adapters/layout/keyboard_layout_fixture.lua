--- tests/support/adapters/layout/keyboard_layout_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_keyboard_layout
--- DESCRIPTION:
--- Prelude shared by the test_keyboard_layout_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

-- A real `xkbcli dump-keymap-x11` shape for fr(azerty), cut to the keys the
-- cases below use. Both spellings of a key definition are present on purpose:
-- the short `{ [ … ] }` form and the long `{ type=…, symbols[Group1]= [ … ] }`
-- one, because a real dump contains both and a parser that knows only the short
-- form drops every key that carries an explicit type.
local AZERTY_DUMP = [[

xkb_keymap {

xkb_keycodes "(unnamed)" {
	minimum = 8;
	maximum = 708;
	 <TLDE>               = 49;
	 <AE01>               = 10;
	 <AE02>               = 11;
	 <AD01>               = 24;
	 <AD02>               = 25;
	 <AD03>               = 26;
	 <AC01>               = 38;
	 <AC02>               = 39;
	 <AB01>               = 52;
	 <SPCE>               = 65;
	 <LFSH>               = 50;
	 <RALT>               = 108;
};

xkb_types "(unnamed)" {
	virtual_modifiers LevelThree;
	type "FOUR_LEVEL" {
		modifiers= Shift+LevelThree;
		map[Shift]= Level2;
		level_name[Level1]= "Base";
	};
};

xkb_compatibility "(unnamed)" {
	interpret.useModMapMods= AnyLevel;
};

xkb_symbols "(unnamed)" {
	name[Group1]="French (AZERTY)";
	key <AD01>  {	[ a, A, ae, AE ] };
	key <AD02>  {	[ z, Z, acircumflex, Acircumflex ] };
	key <AD03>  {
		type= "FOUR_LEVEL",
		symbols[Group1]= [ e, E, EuroSign, cent ]
	};
	key <AC01>  {	[ q, Q, adiaeresis, Adiaeresis ] };
	key <AC02>  {	[ s, S, ssharp, U1E9E ] };
	key <AB01>  {	[ w, W, guillemotleft, less ] };
	key <AE02>  {	[ eacute, 2, asciitilde, Eacute ] };
	key <AE01>  {	[ ampersand, 1, dead_acute, exclamdown ] };
	key <TLDE>  {	[ twosuperior, asciitilde, notsign, NoSymbol ] };
	key <SPCE>  {	[ space, space, nobreakspace, U202F ] };
	key <LFSH>  {	[ Shift_L ] };
	key <RALT>  {	[ ISO_Level3_Shift ] };
};
};

]]

--- Loads the adapter with a table built from the fixture.
--- @return table adapter
local function loaded()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local built = layout.build(AZERTY_DUMP)
	layout._set_table_for_test(built)
	return layout
end

--- Drives real capture, refresh and planning over a controlled native protocol.
--- @param body function
local function cohort_fixture(body)
	local capture = helpers.load_module("adapters.xkb_capture")
	local state = { rows = {} }
	local backend = {
		create = function() return { identity = "owned-cohort-map", group = 0, groups = 2 } end,
		destroy = function() end,
		key_sym = function() return nil end,
		key_utf8 = function() return nil end,
		compose_feed = function() end,
		compose_status = function() return "nothing" end,
		update_key = function(session, code, direction)
			if code == 107 and direction == 1 then session.group = 1 - session.group end
		end,
		capture_group = function(session)
			if state.on_group then state.on_group() end
			return session.group
		end,
		caps_locked = function()
			if state.on_caps then state.on_caps() end
			return state.caps == true
		end,
	}
	backend.inverse = function(session, group)
		local rows = {}
		for code = 32, 126 do rows[string.char(code)] = { keycode = code, level = 1, mods = {} } end
		rows.z = { keycode = group == 1 and 21 or 44, level = 1, mods = {} }
		rows.Z = { keycode = group == 1 and 21 or 44, level = 2, mods = { "shift" } }
		state.rows = rows
		if state.on_inverse then state.on_inverse() end
		return rows
	end
	capture._set_backend(backend)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write("owned-cohort-map")
	file:close()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local ok, err = pcall(function()
		helpers.assert_true(layout.refresh(path))
		body(capture, layout, state, backend, path)
	end)
	layout._set_table_for_test(nil)
	capture._reset_backend()
	os.remove(path)
	if not ok then error(err, 0) end
end

--- Runs automatic X11 refresh through its actual existing command adapter.
--- @param layout table
--- @param backend table
--- @param state table
--- @param body function
local function desktop_cohort(layout, backend, state, body)
	local display = require("infra.display_server")
	local shell = require("adapters.shell_runner")
	local old_exec = shell.exec
	display._set_for_test("x11")
	shell.exec = function() return "xkb_keymap { controlled desktop source }" end
	state.native_generation, state.acknowledged = 7, true
	backend.source_group = function(session)
		if state.on_source then state.on_source() end
		if not state.acknowledged then return nil, "native-keymap-unacknowledged" end
		local group, generation = session.group, state.native_generation
		return group, generation, function()
			return state.acknowledged == true and state.native_generation == generation and session.group == group
		end
	end
	local ok, err = pcall(function()
		helpers.assert_true(layout.refresh())
		body()
	end)
	shell.exec = old_exec
	display._set_for_test(nil)
	if not ok then error(err, 0) end
end

return {
	helpers = helpers,
	AZERTY_DUMP = AZERTY_DUMP,
	loaded = loaded,
	cohort_fixture = cohort_fixture,
	desktop_cohort = desktop_cohort,
}
