--- modules/hotstrings/magic_key_source.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (Linux)
--- DESCRIPTION:
--- Owns the physical key that types the magic key on this driver: the
--- `hotstrings.magic_key_source` value, its evdev code, and the decision the
--- keyboard hook's consumption callback takes for each press. With the
--- automatic value nothing is remapped and the XKB layout types the magic key
--- itself, as it always did (the Ergopti+ symbols put ★ on <AB03>, KeyC).
---
--- FEATURES & RATIONALE:
--- 1. The shared rules (_shared/lua/keymap/magic_key_source.lua) decide which
---    values are keys and which evdev code a value names, from the manifest
---    entry and the physical-key registry; the value is one canonical
---    config.toml leaf (infra/hotstring_preferences.lua), sparse against the
---    automatic default like the magic key character itself.
--- 2. Consumed, then typed, then read. The grabbed press never reaches the
---    application; the magic key is injected in its place and then handed to
---    the character path, so the buffer, the metrics and a ★-triggered
---    expansion see exactly what the application shows — the order a
---    re-emitted key follows (adapters/keyboard_hook.lua).
--- 3. Fail safe. A paused driver, the replace section off, a modifier held or
---    an injection that did not happen lets the key through untouched, so it is
---    typed exactly once, as its own character.
--- 4. Key presses only. The magic key is typed only when the XKB layout types
---    it with key presses (injector.type_directly): on a stock layout without ★
---    the key stays its own character and a choice is refused aloud, where
---    every press used to go through a clipboard paste — tools spawned in the
---    hook, the clipboard history filled — and a failed paste stopped the grab.
--- 5. Chosen by pressing it. A capture takes the next grabbed key-down, which
---    reaches no application, and identifies it by evdev code, so the character
---    the layout gives it does not matter. It needs the grab: without it the
---    key would already have been typed.
--- ==============================================================================

local M = {}

local Logger      = require("logger.shim")
local Preferences = require("infra.hotstring_preferences")
local Manifest    = require("infra.manifest_reader")
local Paths       = require("infra.paths")
local FileSystem  = require("adapters.file_system")
local Json        = require("json")
local EvdevCodes  = require("infra.evdev_codes")
local Timings     = require("infra.timings")
local InputEvent  = require("infra.input_event")
local Shared      = require("keymap.magic_key_source")

local LOG = "magic_key_source"

-- The canonical configuration path of the setting, and its automatic value.
M.PATH = "hotstrings.magic_key_source"
local AUTOMATIC = Manifest.default_for(M.PATH)

-- How long a capture waits for a key (shared with macOS and Windows).
local CAPTURE_TIMEOUT_MS = Timings.ms("ui", "magic_key_capture_timeout_ms")

-- Built on first use: the registry is 37 KB of JSON nobody needs while the
-- automatic value is in effect and no menu asks for the candidates.
local _resolver = nil
local _registry = nil
local _editor_signature = nil
local _editor_generation = 0

local function registry()
	if _registry then return _registry end
	local path = Paths.shared("data/keycodes/physical_keys.json")
	local text = path and FileSystem.read(path)
	if type(text) ~= "string" then error("the physical-key registry is unreadable: " .. tostring(path)) end
	local decoded = Json.decode(text)
	assert(type(decoded) == "table" and type(decoded.keys) == "table", "the physical-key registry is malformed")
	_registry = decoded
	return decoded
end

-- The evdev code in effect and the preference generation it was derived from.
local _code = nil
local _code_generation = nil

-- The daemon's collaborators, set once by M.init.
local _deps = nil

-- The capture waiting for a key, nil when none: { handlers }.
local _capture = nil

-- The magic key character last reported as untypable on the session layout.
local _untypable_reported = nil





-- ================================
-- ================================
-- ======= 1/ Value and key =======
-- ================================
-- ================================

--- The shared resolver for evdev codes, built once.
--- @return table resolver
function M.resolver()
	if _resolver then return _resolver end
	_resolver = Shared.new({
		entry    = Manifest.find_entry_by_path(M.PATH),
		registry = registry(),
		field    = "evdev",
	})
	return _resolver
end

--- The value in effect: the stored key, or the automatic value. An outdated
--- stored value was already reported and reads as absent (the preferences).
--- @return string
function M.get()
	return Preferences.get(M.PATH)
end

--- The evdev code remapped to the magic key, nil while automatic. Asked on
--- every grabbed key-down, so it is derived once per preference document
--- (infra/hotstring_preferences.lua generation): a write, a refresh or a
--- scope's adoption derives it again, a keystroke only compares two numbers.
--- The automatic value answers before the registry is ever read.
--- @return number|nil
function M.evdev_code()
	local generation = Preferences.generation()
	if generation == _code_generation then return _code end
	local value = M.get()
	_code = value ~= AUTOMATIC and M.resolver().native(value) or nil
	-- Read after the value: the first read of the document is itself a change.
	_code_generation = Preferences.generation()
	return _code
end

--- The refusal reason for a source reserved by a configured tap assignment.
--- @param value string Candidate or automatic value.
--- @return string|nil reason_key
function M.choice_reason(value)
	local resolver = M.resolver()
	if value == resolver.automatic then return nil end
	if not resolver.is_candidate(value) then return "dialog.magic_key_source.not_a_candidate" end
	local TapKeys = require("modules.shortcuts.tap_keys")
	if Shared.tap_conflict(resolver, value, TapKeys.keys(), "linux", TapKeys.get_action) then
		return Shared.TAP_CONFLICT_REASON
	end
	return nil
end

--- Stores a new value; the next press follows it, nothing is re-registered.
--- A key is refused while the layout cannot type the magic key with key
--- presses: it would keep typing its own character, and say nothing.
--- @param value string A candidate code or the automatic value.
--- @return boolean ok
--- @return string|nil reason_key The i18n key of a refusal.
function M.set(value)
	if _deps == nil then error("magic_key_source.set needs M.init first", 2) end
	local resolver = M.resolver()
	if value ~= resolver.automatic and not resolver.is_candidate(value) then
		Logger.warn(LOG, "Refused physical magic key '%s': no candidate key has that code.", tostring(value))
		return false, "dialog.magic_key_source.not_a_candidate"
	end
	local conflict = M.choice_reason(value)
	if conflict ~= nil then
		Logger.warn(LOG, "Refused physical magic key '%s': a configured tap action owns its key.", tostring(value))
		return false, conflict
	end
	if value ~= resolver.automatic and _deps.can_type(_deps.magic_key()) ~= true then
		Logger.warn(LOG, "Refused physical magic key '%s': the layout cannot type the magic key '%s' with key presses.",
			tostring(value), tostring(_deps.magic_key()))
		return false, "dialog.magic_key_source.untypable"
	end
	if not Preferences.set(M.PATH, value) then
		Logger.error(LOG, "Could not persist the physical magic key — the change would be lost at restart.")
		return false, "dialog.magic_key.error_persist"
	end
	Logger.info(LOG, "Physical magic key set to %s.", value)
	return true, nil
end

--- What the XKB layout types on a candidate key, nil when it cannot tell.
--- @param code string Candidate code.
--- @return string|nil
function M.key_text(code)
	if _deps == nil then return nil end
	return _deps.key_text(M.resolver().native(code))
end

--- Registry identities admitted by the shared conditional shortcut policy.
--- @return table known_codes KeyboardEvent.code -> true.
function M.known_codes()
	local known = {}
	for code in pairs(registry().keys) do known[code] = true end
	return known
end

--- Proves actual plain sources without selecting one or discarding ambiguity.
--- @return table source Epoch, status and detached native candidates.
function M.editor_source()
	local Capture = require("adapters.xkb_capture")
	local xkb_generation, why = Capture.source_generation()
	local magic = _deps and _deps.magic_key() or require("modules.hotstrings.magic_key").get()
	local value, candidates, native_codes, codes, seen = M.get(), {}, {}, {}, {}
	for code, record in pairs(registry().keys) do
		if type(record.evdev) == "number" then
			if not codes[record.evdev] or code < codes[record.evdev] then codes[record.evdev] = code end
			if not seen[record.evdev] then native_codes[#native_codes + 1] = record.evdev; seen[record.evdev] = true end
		end
	end
	table.sort(native_codes)
	local origin = _deps and _deps.input_source_receipt and _deps.input_source_receipt() or nil
	local rows = xkb_generation and (origin == nil or origin.ready == true) and Capture.direct_sources(native_codes) or nil
	local configured = M.evdev_code()
	local plan = _deps and _deps.typing_plan and _deps.typing_plan(magic) or nil
	local typable = false
	-- Qualify the injector's actual plan against the current native group.
	-- Its cached inverse table alone cannot prove a remap after a group switch.
	for _, row in ipairs(rows or {}) do
		if type(plan) == "table" and row.code == plan.keycode and row.text == magic and not row.dead
			and type(plan.mods) == "table" and type(row.mods) == "table" and #plan.mods == #row.mods then
			local same = true
			for index, mod in ipairs(plan.mods) do if row.mods[index] ~= mod then same = false end end
			if same then typable = true end
		end
	end
	local remapped = configured ~= nil and _deps ~= nil and _deps.is_active() == true
		and _deps.can_capture() == true and _deps.replace_on() == true and _deps.can_type(magic) == true and typable
	if rows then
		for _, row in ipairs(rows) do
			-- A proven chosen replacement owns the effective source. Automatic or
			-- ineffective settings retain every actual native candidate instead.
			if not remapped or row.code == configured then
				local mapped = remapped and row.code == configured and row.plain == true
				local admitted = _deps == nil or _deps.direct_source_admitted == nil
					or _deps.direct_source_admitted(row.code, remapped and row.code == configured) == true
				candidates[#candidates + 1] = { code = codes[row.code], native_code = row.code,
					identity = "evdev:" .. row.code, text = mapped and magic or row.text, native_text = row.text,
					direct = admitted and (mapped or row.direct == true),
					dead = not mapped and row.dead == true }
			end
		end
	end
	-- A single epoch covers source preferences, native group and remap/tap proof.
	local signature = Json.encode({ preference = Preferences.generation(), native = xkb_generation,
		value = value, trigger = magic, remapped = remapped, origin = origin, candidates = candidates })
	if signature ~= _editor_signature then
		_editor_signature = signature
		_editor_generation = _editor_generation + 1
	end
	return { generation = _editor_generation, status = rows and "ready" or "unavailable",
		reason = rows and nil or (origin and origin.ready ~= true and "physical-origin-unqualified") or why or "direct-source-unavailable", candidates = candidates }
end





-- =========================================
-- =========================================
-- ======= 2/ Keyboard hook decision =======
-- =========================================
-- =========================================

--- Wires the daemon's collaborators, once.
--- @param deps table {
---   is_active     fn() -> boolean  The driver runs and is not paused.
---   replace_on    fn() -> boolean  The magic key's replace section is on.
---   magic_key     fn() -> string   The magic key character.
---   can_type      fn(text) -> boolean  The layout types text with key presses.
---   type_text     fn(text) -> boolean  Types text with key presses only, never
---                                  the clipboard (injector.type_directly).
---   dispatch_char fn(char, code)   The character path a typed key takes.
---   end_selection fn()             The typed magic key replaced any selection:
---                                  wrap-on-type's selection window ends, as it
---                                  does for every key that reaches it.
---   can_capture   fn() -> boolean  The hook owns the keyboard (grab), so a
---                                  captured key never reaches an application.
---   key_text      fn(evdev) -> string|nil  What the XKB layout types there.
---   defer         fn(fn, delay_ms) -> boolean  Runs work after the hook returns.
---   input_source_receipt fn() -> { generation, ready } Optional native evdev
---                                  origin acknowledgement.
---   typing_plan   fn(text) -> { keycode, mods }|nil Optional injector plan
---                                  qualified against the actual native group.
---   direct_source_admitted fn(evdev, remapped) -> boolean Optional native
---                                  tap-hold/remap ownership admission. }
function M.init(deps)
	if _deps ~= nil then error("magic_key_source: already initialized", 2) end
	if type(deps) ~= "table" then error("magic_key_source.init needs its collaborators", 2) end
	for _, name in ipairs({ "is_active", "replace_on", "magic_key", "can_type", "type_text", "dispatch_char",
		"end_selection", "can_capture", "key_text", "defer" }) do
		if type(deps[name]) ~= "function" then error("magic_key_source.init needs " .. name, 2) end
	end
	if deps.input_source_receipt ~= nil and type(deps.input_source_receipt) ~= "function" then
		error("magic_key_source.init needs a callable input source receipt", 2)
	end
	if deps.typing_plan ~= nil and type(deps.typing_plan) ~= "function" then
		error("magic_key_source.init needs a callable typing plan", 2)
	end
	if deps.direct_source_admitted ~= nil and type(deps.direct_source_admitted) ~= "function" then
		error("magic_key_source.init needs a callable direct source admission", 2)
	end
	Logger.start(LOG, "Initializing…")
	_deps = deps
	Logger.success(LOG, "Initialized (physical magic key %s).", M.get())
end

--- Whether a key can be captured now: the daemon owns the keyboard and is not
--- paused, as macOS greys the row while paused — a paused driver takes no key.
--- @return boolean
function M.can_capture()
	return _deps ~= nil and _deps.can_capture() == true and _deps.is_active() == true
end

--- Captures the next grabbed key-down as the physical magic key. Escape or the
--- shared timeout (timings [ui] magic_key_capture_timeout_ms) ends it with
--- nothing changed. The decision runs after the hook returns: persisting it is
--- file work the keystroke path must not wait for.
--- @param handlers table { on_chosen = fn(value), on_refused = fn(reason_key) }.
--- @return boolean started
function M.capture(handlers)
	if type(handlers) ~= "table" or type(handlers.on_chosen) ~= "function"
		or type(handlers.on_refused) ~= "function" then
		error("magic_key_source.capture needs on_chosen and on_refused", 2)
	end
	if _capture ~= nil or not M.can_capture() then return false end
	local live = { handlers = handlers }
	_capture = live
	local armed = _deps.defer(function()
		if _capture ~= live then return end
		_capture = nil
		Logger.info(LOG, "Physical magic key capture timed out: nothing changed.")
	end, CAPTURE_TIMEOUT_MS)
	if armed ~= true then
		_capture = nil
		Logger.error(LOG, "The capture timeout could not be armed — no key is captured.")
		return false
	end
	Logger.info(LOG, "Waiting for the physical magic key…")
	return true
end

--- Settles a capture with the key pressed, after the hook returned.
--- @param live table The capture.
--- @param evdev number The pressed key.
local function settle(live, evdev)
	if evdev == EvdevCodes.KEY_ESC then
		Logger.info(LOG, "Physical magic key capture cancelled: nothing changed.")
		return
	end
	local value = M.resolver().code_for(evdev)
	if value == nil then
		Logger.warn(LOG, "evdev key %s cannot type the magic key.", tostring(evdev))
		live.handlers.on_refused("dialog.magic_key_source.not_a_candidate")
		return
	end
	local ok, reason = M.set(value)
	if not ok then
		live.handlers.on_refused(reason)
		return
	end
	live.handlers.on_chosen(value)
end

--- Retains an acknowledged magic press without rescanning the native device origin.
--- @param detail table Native physical key and published origin generation.
--- @param code number Chosen native key.
--- @param magic string Character already typed and dispatched.
--- @return function|nil callback Only qualified presses may own repeats.
local function repeat_callback_for(detail, code, magic)
	if detail.physical ~= true or detail.value ~= InputEvent.VALUE_DOWN
		or type(detail.origin_generation) ~= "number" or detail.origin_generation <= 0
		or detail.origin_generation % 1 ~= 0 then return nil end
	local Capture = require("adapters.xkb_capture")
	local source_generation = Capture.source_generation()
	if type(source_generation) ~= "number" or source_generation <= 0 or source_generation % 1 ~= 0 then return nil end
	local preference_generation, origin_generation = Preferences.generation(), detail.origin_generation
	return function(repeat_detail)
		if type(repeat_detail) ~= "table" or repeat_detail.value ~= InputEvent.VALUE_REPEAT
			or repeat_detail.physical ~= true or repeat_detail.code ~= code
			or repeat_detail.origin_generation ~= origin_generation
			or type(repeat_detail.mods) ~= "table" or not Shared.unmodified(repeat_detail.mods) or _capture ~= nil
			or Preferences.generation() ~= preference_generation or M.evdev_code() ~= code
			or _deps.magic_key() ~= magic or _deps.is_active() ~= true or _deps.replace_on() ~= true
			or Capture.source_generation() ~= source_generation or _deps.can_type(magic) ~= true
			or (_deps.direct_source_admitted and _deps.direct_source_admitted(code, true) ~= true) then return false end
		local called, typed = pcall(_deps.type_text, magic)
		if not called or typed ~= true then
			Logger.error(LOG, "The repeated magic key was not typed — the held press remains suppressed.")
			return false
		end
		_deps.end_selection()
		_deps.dispatch_char(magic, code)
		return true
	end
end

--- Decides one grabbed key press from the keyboard hook's consumption callback.
--- @param detail table { code, mods, char } as the hook reports a key-down.
--- @return boolean consumed True when the key was captured or the magic key
---   was typed in its place.
--- @return function|nil repeat_callback Optional owner of this acknowledged physical press.
function M.on_key(detail)
	if _deps == nil or type(detail) ~= "table" then return false end
	if _capture ~= nil then
		-- The answer of a capture reaches no application, whatever it is.
		local live, evdev = _capture, detail.code
		_capture = nil
		if _deps.defer(function() settle(live, evdev) end, 0) ~= true then
			Logger.error(LOG, "The captured key could not be settled — nothing changed.")
		end
		return true
	end
	local code = M.evdev_code()
	if code == nil or detail.code ~= code then return false end
	if not Shared.unmodified(detail.mods) then return false end
	if _deps.is_active() ~= true or _deps.replace_on() ~= true then return false end
	if _deps.direct_source_admitted and _deps.direct_source_admitted(code, true) ~= true then return false end
	local magic = _deps.magic_key()
	if type(magic) ~= "string" or magic == "" then return false end
	if _deps.can_type(magic) ~= true then
		-- Once per character: the key may be pressed or held again and again.
		if _untypable_reported ~= magic then
			_untypable_reported = magic
			Logger.warn(LOG, "The layout cannot type the magic key '%s' with key presses — "
				.. "the physical magic key types its own character.", magic)
		end
		return false
	end
	_untypable_reported = nil
	-- Acquire optional repeat provenance before typing: a broken owner must not
	-- turn already-typed text into an unconsumed physical press.
	local repeat_callback = repeat_callback_for(detail, code, magic)
	local called, typed = pcall(_deps.type_text, magic)
	if not called or typed ~= true then
		Logger.error(LOG, "The magic key could not be typed (%s) — the key types its own character.",
			tostring(called and "injection refused" or typed))
		return false
	end
	_deps.end_selection()
	_deps.dispatch_char(magic, detail.code)
	return true, repeat_callback
end

--- Forgets the collaborators, the resolver and any capture (test seam).
function M._reset_for_test()
	_deps = nil
	_resolver = nil
	_registry = nil
	_editor_signature = nil
	_editor_generation = _editor_generation + 1
	_capture = nil
	_code, _code_generation = nil, nil
	_untypable_reported = nil
end

return M
