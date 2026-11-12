--- _shared/layouts/engine/composer/keylayout_emulation.lua

--- ==============================================================================
--- MODULE: Keylayout Emulation (Shared)
--- DESCRIPTION:
--- Types a .keylayout on top of whatever system layout is installed: the Lua
--- twin of the Windows emulation (windows/modules/keymap/keylayout/
--- keylayout_emulation.ahk and keylayout_parser.ahk). A driver hands it each
--- physical key press, named by its KeyboardEvent.code, with the modifiers
--- held; it answers what to do with the press: leave it to the OS, type a text
--- in its place, or replace the key of a shortcut chord by the layout's
--- character. macOS and Linux run it; Windows runs the AutoHotkey twin, and the
--- three replay the same keystroke corpus
--- (_shared/tests/corpus/layouts/keylayout_vectors.json), so one physical key
--- types the same thing on every OS.
---
--- FEATURES & RATIONALE:
--- 1. PURE Lua: no driver import, no io, no clock. The caller reads the files
---    and decodes the JSON; the keystroke path is table lookups only.
--- 2. One source per layout: the canonical parse (layouts/engine/composer/keylayout.lua) of the
---    .keylayout is the only description read. Levels come from the layout's
---    own modifierMap (Shift, CapsLock, AltGr = Option, the shortcut chords =
---    Command), dead keys and chained dead keys from its actions, as macOS
---    types them.
--- 3. Same decisions as Windows: the base/Shift and AltGr layers each behind
---    their own switch, the four row switches (layout_rows_policy), the
---    number-row ordering and its edge keys (number_row_policy), a pending dead
---    key completed by a key the emulation leaves to the OS, the dead-key reset
---    keys and the physical magic key, which keeps its unshifted press.
--- 4. Fail fast: an unknown convention, a key code the layout's sets cannot
---    reach or an undefined action raise at compile time, never on a key.
--- ==============================================================================

local RowsPolicy = require("layouts.engine.layout.rows_policy")
local NumberRowPolicy = require("layouts.engine.layout.number_row_policy")

local M = {}

--- The dead-key state of a layout at rest (Apple TN2056).
M.NEUTRAL = "none"

--- What a press decides (M.decide's first result).
M.PASS = "pass"           -- the OS types the key itself
M.TYPE = "type"           -- the press is consumed and the text (maybe "") typed
M.TYPE_PASS = "type_pass" -- the text is typed, then the key itself reaches the OS
M.SHORTCUT = "shortcut"   -- the chord keeps its modifiers on the key typing the text

-- Longest baseMapSet chain followed, as the Windows parser.
local MAX_BASE_DEPTH = 8

-- Keys that end a pending dead key without typing through the layout: the
-- sequence is dropped the way a native dead key drops it (KLE_DEAD_RESET_KEYS).
M.DEAD_RESET_KEYS = {
	Backspace = true, Escape = true, Enter = true, Tab = true, Delete = true,
	ArrowLeft = true, ArrowRight = true, ArrowUp = true, ArrowDown = true,
	Home = true, End = true, PageUp = true, PageDown = true,
}

-- The space bar's chords stay native: every layout's Command level types a
-- space there, and Cmd/Win/Ctrl+Space are system shortcuts (KLE_NATIVE_CHORD_KEYS).
M.NATIVE_CHORD_KEYS = { Space = true }

-- The ten digit keys, 1 to 0, and the three edge keys of the number row.
M.DIGIT_KEYS = { "Digit1", "Digit2", "Digit3", "Digit4", "Digit5",
	"Digit6", "Digit7", "Digit8", "Digit9", "Digit0" }
M.EDGE_KEYS = { "Backquote", "Minus", "Equal" }

-- The eight Shift/CapsLock/Option combinations, in the order levels are keyed.
local COMBOS = {}
for _, shift in ipairs({ false, true }) do
	for _, caps in ipairs({ false, true }) do
		for _, option in ipairs({ false, true }) do
			COMBOS[#COMBOS + 1] = { shift = shift, caps = caps, option = option }
		end
	end
end

--- The level key of a combination: "s", "c" and "o" for each modifier held.
local function combo_key(shift, caps, option)
	return (shift and "s" or "") .. (caps and "c" or "") .. (option and "o" or "")
end
M.combo_key = combo_key





-- ====================================
-- ====================================
-- ======= 1/ Text Helpers ============
-- ====================================
-- ====================================

--- Whether a text types something visible: not empty and free of C0 and C1
--- control characters (Kalamine marks unused keys with U+0010), as
--- Keylayout_IsPrintable.
--- @param text string|nil
--- @return boolean
function M.printable(text)
	if type(text) ~= "string" or text == "" then return false end
	if text:find("[%z\1-\31\127]") then return false end
	-- U+0080 to U+009F are encoded C2 80 to C2 9F.
	if text:find("\194[\128-\159]") then return false end
	return true
end
local printable = M.printable





-- ====================================
-- ====================================
-- ======= 2/ Compilation =============
-- ====================================
-- ====================================

--- The keyMap index the layout selects when exactly `pressed` modifiers are down.
--- @param model table A compiled model.
--- @param pressed table Set of modifier tokens (shift, caps, option, command, control).
--- @return integer
function M.key_map_index(model, pressed)
	for _, select in ipairs(model.selects) do
		for _, modifier in ipairs(select.modifiers) do
			local matches = true
			for name in pairs(modifier.required) do
				if not pressed[name] then matches = false; break end
			end
			if matches then
				for name in pairs(pressed) do
					if not modifier.required[name] and not modifier.optional[name] then matches = false; break end
				end
			end
			if matches then return select.index end
		end
	end
	return model.default_index
end

--- The <key> element of `code` in keyMap `index`, following baseMapSet.
--- @return table|nil entry { output } or { action }
local function key_entry(model, index, code)
	local set = model.map_set
	for _ = 1, MAX_BASE_DEPTH do
		local maps = model.sets[set]
		if maps == nil then error("The .keylayout keyMapSet '" .. tostring(set) .. "' is not defined.") end
		local keys = maps[index]
		local entry = keys and keys[code]
		if entry ~= nil then return entry end
		local bases = model.bases[set]
		local base = bases and bases[index]
		if base == nil then return nil end
		set, index = base.set, base.index
	end
	error("The .keylayout keyMap base chain is too deep.")
end

--- What `code` types in keyMap `index` from the neutral state.
--- @param model table
--- @param index integer
--- @param code integer macOS key code.
--- @return table resolved { kind = "none"|"text"|"dead", text, state, action }
function M.resolve(model, index, code)
	local entry = key_entry(model, index, code)
	if entry == nil then return { kind = "none", text = "", state = "", action = "" } end
	if entry.output ~= nil then
		if printable(entry.output) then return { kind = "text", text = entry.output, state = "", action = "" } end
		return { kind = "none", text = "", state = "", action = "" }
	end
	local action = model.actions[entry.action]
	if action == nil then error("A .keylayout key uses the undefined action '" .. tostring(entry.action) .. "'.") end
	local when = action[M.NEUTRAL]
	if when == nil then return { kind = "none", text = "", state = "", action = entry.action } end
	if when.next ~= nil and when.next ~= "" then
		local alone = model.terminators[when.next]
		return { kind = "dead", text = (alone ~= nil and alone ~= "") and alone or entry.action,
			state = when.next, action = entry.action }
	end
	if printable(when.output) then return { kind = "text", text = when.output, state = "", action = entry.action } end
	return { kind = "none", text = "", state = "", action = entry.action }
end

--- One keystroke of the dead-key state machine, as macOS runs it
--- (Keylayout_Step): from the neutral state a key types its output or enters a
--- dead state; inside state S an action with a <when state="S"> types that
--- output and/or moves on, any other key first types S's terminator.
--- @param model table
--- @param state string Current state (M.NEUTRAL at rest).
--- @param index integer keyMap index of the modifiers held.
--- @param code integer macOS key code.
--- @return string output Text to type ("" while a dead key is pending).
--- @return string next State after the key.
function M.step(model, state, index, code)
	local pending = ""
	if state ~= M.NEUTRAL then
		local entry = key_entry(model, index, code)
		if entry ~= nil and entry.action ~= nil then
			local action = model.actions[entry.action]
			local when = action and action[state]
			if when ~= nil then
				local output = printable(when.output) and when.output or ""
				local next_state = (when.next ~= nil and when.next ~= "") and when.next or M.NEUTRAL
				return output, next_state
			end
		end
		local terminator = model.terminators[state]
		pending = printable(terminator) and terminator or ""
	end
	local resolved = M.resolve(model, index, code)
	if resolved.kind == "dead" then return pending, resolved.state end
	return pending .. resolved.text, M.NEUTRAL
end

--- Native base characters address the layout's actions by their neutral
--- output, never by the physical position (_KLE_BuildCompositions): a key the
--- emulation leaves to the OS still completes a pending dead key.
local function build_compositions(model)
	local result = {}
	for id, action in pairs(model.actions) do
		local neutral = action[M.NEUTRAL]
		if neutral ~= nil and (neutral.next == nil or neutral.next == "") and printable(neutral.output) then
			local text = neutral.output
			for state, step in pairs(action) do
				if state ~= M.NEUTRAL then
					result[state] = result[state] or {}
					local previous = result[state][text]
					if previous ~= nil and (previous.output ~= step.output or previous.next ~= step.next) then
						error("The layout has an ambiguous native composition of '" .. text .. "' in state "
							.. state .. " (action " .. id .. ").")
					end
					result[state][text] = { output = step.output, next = step.next }
				end
			end
		end
	end
	return result
end

--- The macOS key code each physical key has under a layout's keycode convention.
--- @param keycodes table Decoded _shared/layouts/data/mac_keycodes.json.
--- @param convention string "iso" or "ansi".
--- @return table KeyboardEvent.code -> macOS key code.
function M.mac_codes(keycodes, convention)
	if type(keycodes) ~= "table" or type(keycodes.conventions) ~= "table" or type(keycodes.keys) ~= "table" then
		error("The emulation needs the shared macOS keycode table.")
	end
	local known = false
	for _, name in ipairs(keycodes.conventions) do known = known or name == convention end
	if not known then error("Unknown keycode convention '" .. tostring(convention) .. "'.") end
	local codes = {}
	for _, key in ipairs(keycodes.keys) do
		local mac = key.mac
		if type(mac) == "table" then mac = mac[convention] end
		if type(key.code) ~= "string" or type(mac) ~= "number" then
			error("The macOS keycode table holds a malformed key.")
		end
		codes[key.code] = mac
	end
	return codes
end

--- Compiles a canonical .keylayout into the lookup model the keystroke path walks.
--- @param canonical table layouts.keylayout.parse(text).
--- @param keycodes table Decoded mac_keycodes.json.
--- @param convention string The layout's keycode_convention.
--- @param opts table|nil { composer = boolean } composer: the layout the
---   composer built, whose Ctrl and Alt chords read their own keyMap.
--- @return table model
function M.compile(canonical, keycodes, convention, opts)
	if type(canonical) ~= "table" or canonical.schema ~= 1 then
		error("The emulation needs a canonical .keylayout (schema 1).")
	end
	local model = {
		name = canonical.name, map_set = canonical.map_set, default_index = canonical.default_index,
		selects = {}, sets = {}, bases = {}, actions = {}, terminators = {}, levels = {},
	}
	for _, select in ipairs(canonical.selects) do
		local modifiers = {}
		for _, modifier in ipairs(select.modifiers) do
			local required, optional = {}, {}
			for _, token in ipairs(modifier.required) do required[token] = true end
			for _, token in ipairs(modifier.optional) do optional[token] = true end
			modifiers[#modifiers + 1] = { required = required, optional = optional }
		end
		model.selects[#model.selects + 1] = { index = select.index, modifiers = modifiers }
	end
	for _, set in ipairs(canonical.key_map_sets) do
		local maps = {}
		model.sets[set.id] = maps
		for _, key_map in ipairs(set.key_maps) do
			local keys = {}
			maps[key_map.index] = keys
			for _, key in ipairs(key_map.keys) do
				keys[key.code] = key.output ~= nil and { output = key.output } or { action = key.action }
			end
			if key_map.base ~= nil then
				model.bases[set.id] = model.bases[set.id] or {}
				model.bases[set.id][key_map.index] = { set = key_map.base.set, index = key_map.base.index }
			end
		end
	end
	for _, action in ipairs(canonical.actions) do
		local states = {}
		model.actions[action.id] = states
		for _, when in ipairs(action.whens) do
			states[when.state] = { output = when.output or "", next = when.next or "" }
		end
	end
	for _, terminator in ipairs(canonical.terminators) do
		model.terminators[terminator.state] = terminator.output
	end
	model.mac_codes = M.mac_codes(keycodes, convention)
	for _, combo in ipairs(COMBOS) do
		local pressed = {}
		if combo.shift then pressed.shift = true end
		if combo.caps then pressed.caps = true end
		if combo.option then pressed.option = true end
		model.levels[combo_key(combo.shift, combo.caps, combo.option)] = M.key_map_index(model, pressed)
	end
	model.levels.command = M.key_map_index(model, { command = true })
	-- A registry layout types every chord from its Command level; the composed
	-- layout selects a keyMap of its own for Ctrl and Alt (_KLE_ShortcutLevels).
	model.levels.win, model.levels.ctrl, model.levels.alt = model.levels.command, model.levels.command, model.levels.command
	if type(opts) == "table" and opts.composer == true then
		local ctrl = M.key_map_index(model, { control = true })
		if ctrl ~= model.default_index then model.levels.ctrl = ctrl end
		local alt = M.key_map_index(model, { option = true, command = true })
		if alt ~= model.default_index then model.levels.alt = alt end
	end
	-- Resolve every key of every level once: a broken action or chain raises
	-- here, at load, never inside a key callback.
	for _, index in pairs(model.levels) do
		for _, code in pairs(model.mac_codes) do M.resolve(model, index, code) end
	end
	model.compositions = build_compositions(model)
	return model
end

--- Parses and compiles a .keylayout text in one call.
--- @param text string The .keylayout.
--- @param keycodes table Decoded mac_keycodes.json.
--- @param convention string The layout's keycode_convention.
--- @param opts table|nil See M.compile.
--- @return table model
function M.load(text, keycodes, convention, opts)
	local canonical, err = require("layouts.engine.composer.keylayout").parse(text)
	if canonical == nil then error("The .keylayout cannot be read: " .. tostring(err)) end
	return M.compile(canonical, keycodes, convention, opts)
end

--- The character a shortcut chord sends for a physical key: the layout's
--- Command level, or the held modifier's own for the composed layout
--- (KeylayoutEmulation_ShortcutChar).
--- @param model table
--- @param code string KeyboardEvent.code.
--- @param modifier string "ctrl", "alt" or "win".
--- @return string One character, or "" when the layout types none or a dead key there.
function M.shortcut_char(model, code, modifier)
	local mac = model.mac_codes[code]
	local index = model.levels[modifier]
	if mac == nil or index == nil then return "" end
	local resolved = M.resolve(model, index, mac)
	if resolved.kind ~= "text" then return "" end
	local text = resolved.text
	local first = text:match("^[%z\1-\127\194-\244][\128-\191]*")
	return first == text and text or ""
end





-- ====================================
-- ====================================
-- ======= 3/ Session =================
-- ====================================
-- ====================================

--- The row of every physical key of the four emulated rows.
--- @param registry table Decoded _shared/layouts/data/keycodes/physical_keys.json.
--- @param is_null function The JSON decoder's null test (required, see layout_rows_policy.keys).
--- @return table KeyboardEvent.code -> row id.
function M.row_map(registry, is_null)
	local rows = {}
	for row, codes in pairs(RowsPolicy.keys(registry, is_null)) do
		for _, code in ipairs(codes) do rows[code] = row end
	end
	return rows
end

--- The policy descriptor of what a key types on one level (number_row_policy).
local function descriptor(model, index, mac)
	local resolved = M.resolve(model, index, mac)
	if resolved.kind == "text" then return { Kind = "text", Text = resolved.text } end
	if resolved.kind == "dead" then
		return { Kind = "dead", Action = resolved.action, State = resolved.state, Text = resolved.text }
	end
	return { Kind = "none", Text = "" }
end

--- Which keys exchange their base and Shift levels under the number-row
--- options, for one CapsLock state: the ten digit keys while the stored
--- ordering applies to this layout, the three edge keys too when they can join.
--- @param model table
--- @param mode string layout.direct_access_digits.
--- @param edges boolean layout.number_row_reorder_edges.
--- @param caps boolean
--- @return table swaps KeyboardEvent.code -> true.
--- @return table effective { mode, reason } as number_row_policy.effective.
function M.number_row_swaps(model, mode, edges, caps)
	local plain, shifted = model.levels[combo_key(false, caps, false)], model.levels[combo_key(true, caps, false)]
	local function levels(codes)
		local out = {}
		for position, code in ipairs(codes) do
			local mac = model.mac_codes[code]
			out[position] = { plain = descriptor(model, plain, mac), shift = descriptor(model, shifted, mac) }
		end
		return out
	end
	local effective = NumberRowPolicy.effective(mode, NumberRowPolicy.availability(levels(M.DIGIT_KEYS)))
	local swaps = {}
	if effective.mode == "native" then return swaps, effective end
	for _, code in ipairs(M.DIGIT_KEYS) do swaps[code] = true end
	if edges == true and NumberRowPolicy.edges_availability(levels(M.EDGE_KEYS), effective.mode) == "" then
		for _, code in ipairs(M.EDGE_KEYS) do swaps[code] = true end
	end
	return swaps, effective
end

--- Starts typing a compiled layout.
--- @param model table M.compile's model.
--- @param rows table M.row_map's map.
--- @return table session
function M.new_session(model, rows)
	if type(model) ~= "table" or type(model.levels) ~= "table" then error("A session needs a compiled layout.") end
	if type(rows) ~= "table" then error("A session needs the physical row map.") end
	return { model = model, rows = rows, state = M.NEUTRAL, config = nil }
end

--- Applies the [layout] settings the session decides with. Called off the key
--- path, at start and on every change of these settings.
--- @param session table
--- @param settings table { base, alt_gr, layout = the [layout] table holding the
---   emulate_<row> switches, number_row = direct_access_digits,
---   edges = number_row_reorder_edges, magic_code = KeyboardEvent.code|nil }
--- @return table effective { [false] = {mode, reason}, [true] = {mode, reason} }
function M.configure(session, settings)
	if type(settings) ~= "table" or type(settings.base) ~= "boolean" or type(settings.alt_gr) ~= "boolean" then
		error("The emulation settings need the base and AltGr switches.")
	end
	local row_on = {}
	for _, row in ipairs(RowsPolicy.IDS) do row_on[row] = RowsPolicy.emulates(settings.layout, row) end
	local swaps, effective = {}, {}
	for _, caps in ipairs({ false, true }) do
		local found, applied = {}, { mode = "native", reason = "" }
		if row_on.number_row and settings.base then
			found, applied = M.number_row_swaps(session.model, settings.number_row, settings.edges == true, caps)
		end
		swaps[caps], effective[caps] = found, applied
	end
	session.config = { base = settings.base, alt_gr = settings.alt_gr, row_on = row_on,
		swaps = swaps, magic_code = settings.magic_code }
	session.state = M.NEUTRAL
	return effective
end

--- Drops a pending dead key.
--- @param session table
function M.reset(session)
	session.state = M.NEUTRAL
end

--- Ends a pending dead key before a text typed outside the layout (the layout
--- source emulation's), as a key typing outside every dead key does: the dead
--- key's terminator, then the text.
--- @param session table
--- @return string terminator The printable terminator, "" when none was pending.
function M.flush(session)
	local state = session.state
	session.state = M.NEUTRAL
	if state == M.NEUTRAL then return "" end
	local terminator = session.model.terminators[state]
	return printable(terminator) and terminator or ""
end

--- Whether a dead key is pending.
--- @param session table
--- @return boolean
function M.pending(session)
	return session.state ~= M.NEUTRAL
end

--- Whether the row switches leave key `code` to the emulation.
local function row_emulated(session, code)
	local row = session.rows[code]
	return row == nil or session.config.row_on[row] == true
end

--- The character a Ctrl, Alt or Win chord on a key sends while the emulation
--- runs, without changing the session: a keyboard shortcut slot matches it, as
--- Windows registers a slot on the key that types its letter (ILX-001). nil
--- when the chord keeps the system layout's key.
--- @param session table
--- @param code string KeyboardEvent.code.
--- @param ctrl boolean
--- @param alt boolean
--- @param win boolean
--- @return string|nil char
--- @return boolean emulated Whether the emulation owns this key's chords.
function M.chord_char(session, code, ctrl, alt, win)
	local config = session.config
	if config == nil then error("The emulation session is not configured.") end
	if not (ctrl or alt or win) or session.model.mac_codes[code] == nil then return nil, false end
	if M.NATIVE_CHORD_KEYS[code] or not config.base or not row_emulated(session, code) then return nil, false end
	local char = M.shortcut_char(session.model, code, ctrl and "ctrl" or (alt and "alt" or "win"))
	if char == "" then return nil, true end
	return char, true
end

--- What the emulation types unshifted on a key from the neutral state, for a
--- legend: a dead key shows its terminator, a key the emulation leaves to the
--- OS layout (base off, row switched off, unmapped) shows nothing. The digit
--- row follows the configured number-row ordering, as typing does. Reads the
--- session without changing its dead-key state.
--- @param session table A configured session.
--- @param code string The key's KeyboardEvent.code.
--- @return string text "" when the OS layout types that key.
function M.legend(session, code)
	local config = session.config
	if config == nil then error("The emulation session is not configured.") end
	local mac = session.model.mac_codes[code]
	if mac == nil or not config.base or not row_emulated(session, code) then return "" end
	local shift = config.swaps[false][code] == true
	local resolved = M.resolve(session.model, session.model.levels[combo_key(shift, false, false)], mac)
	return resolved.kind == "none" and "" or resolved.text
end

--- Types one layout level and advances the state machine.
local function step_level(session, mac, shift, caps, option)
	local model = session.model
	local output, next_state = M.step(model, session.state, model.levels[combo_key(shift, caps, option)], mac)
	session.state = next_state
	return M.TYPE, output
end

--- Completes a pending dead key with what the OS layout types (PressNative).
local function compose_native(session, native)
	local model = session.model
	local transitions = model.compositions[session.state]
	local step = (native ~= nil and native ~= "" and transitions) and transitions[native] or nil
	if step ~= nil then
		session.state = step.next ~= "" and step.next or M.NEUTRAL
		return M.TYPE, printable(step.output) and step.output or ""
	end
	local prefix = model.terminators[session.state]
	if not printable(prefix) then prefix = "" end
	session.state = M.NEUTRAL
	if native ~= nil and native ~= "" then return M.TYPE, prefix .. native end
	return M.TYPE_PASS, prefix
end

--- Decides one physical key press.
--- @param session table A configured session.
--- @param code string The key's KeyboardEvent.code.
--- @param shift boolean Shift held.
--- @param caps boolean CapsLock on.
--- @param option boolean AltGr (macOS Option) held.
--- @param ctrl boolean Ctrl held.
--- @param alt boolean Alt held (not AltGr; never on macOS, where Option is the level).
--- @param win boolean Win/Super/Cmd held.
--- @param native string|nil What the OS layout types for this press, used only
---   to complete a pending dead key on a key the emulation leaves to the OS.
--- @return string decision M.PASS, M.TYPE, M.TYPE_PASS or M.SHORTCUT.
--- @return string|nil text The text to type, or the chord's character.
function M.decide(session, code, shift, caps, option, ctrl, alt, win, native)
	local config = session.config
	if config == nil then error("The emulation session is not configured.") end
	if M.DEAD_RESET_KEYS[code] then
		session.state = M.NEUTRAL
		return M.PASS, nil
	end
	local mac = session.model.mac_codes[code]
	if mac == nil then return M.PASS, nil end
	if ctrl or alt or win then
		local char, emulated = M.chord_char(session, code, ctrl, alt, win)
		-- An emulated key's chord ends a pending dead key, whatever it sends.
		if emulated then session.state = M.NEUTRAL end
		if char == nil then return M.PASS, nil end
		return M.SHORTCUT, char
	end
	local emulated = row_emulated(session, code)
	if option then
		if config.alt_gr and emulated then return step_level(session, mac, shift, caps, true) end
		return M.PASS, nil
	end
	local pending = session.state ~= M.NEUTRAL
	if not pending and not shift and config.magic_code == code then return M.PASS, nil end
	if config.base and emulated then
		if config.swaps[caps == true][code] then shift = not shift end
		return step_level(session, mac, shift, caps, false)
	end
	if pending then return compose_native(session, native) end
	return M.PASS, nil
end

return M
