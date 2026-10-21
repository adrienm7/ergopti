--- tests/unit/modules/shortcuts/caps_word/test_caps_word_auto_off.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off — Unit Tests (Linux)
--- DESCRIPTION:
--- What ends the Linux CapsWord on its own: a checked delimiter typed or
--- pressed, the configured delay without a keystroke, a pointer event of a
--- checked kind. Before [shortcuts.caps_word] the manager's CapsWord never
--- switched off: it stayed on across every word until toggled by hand, and no
--- click, delay or delimiter choice reached it.
---
--- Covered: the settings owner (defaults, outdated values, sparse persistence,
--- the declared pointer kinds), the evdev code -> kind map, the manager's
--- session (delimiter, unchecked delimiter, no-break space, delay, pointer
--- kinds), the CapsLock every session locks and every ending unlocks (through
--- a fake hook: tests/support/caps_word_lock_hook_fake.lua) and the daemon and
--- hook wiring.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =================================================================
-- =================================================================
-- ======= 1/ Fixture ==============================================
-- =================================================================
-- =================================================================

--- Runs a body over an exclusive config file, a manual clock and a manual
--- event loop, with freshly loaded owners; restores every module after.
--- @param source string|nil Configuration bytes.
--- @param body function body(context)
local function with_caps_word(source, body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			local context = { now = 1000, deferred = {}, resolution = 0 }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["infra.monotonic"] = {
				now_ms = function() return context.now end,
				now_sec = function() return context.now / 1000 end,
				resolution_ms = function() return context.resolution end,
			}
			local EventLoop = require("adapters.event_loop")
			local original_defer = EventLoop.defer
			EventLoop.defer = function(fn, delay_ms)
				context.deferred[#context.deferred + 1] = { fn = fn, due = context.now + delay_ms }
				return true
			end
			--- Runs every queued callback that is due now (callbacks may queue more).
			function context.run_due()
				local pending = context.deferred
				context.deferred = {}
				for _, entry in ipairs(pending) do
					if entry.due <= context.now then entry.fn() else context.deferred[#context.deferred + 1] = entry end
				end
			end
			-- No keyboard is captured here: the session's CapsLock goes to a fake hook.
			context.hook = require("tests.support.caps_word_lock_hook_fake").new()
			package.loaded["adapters.keyboard_hook"] = context.hook
			package.loaded["modules.shortcuts.caps_word_auto_off"] = nil
			package.loaded["modules.shortcuts.manager"] = nil
			context.AutoOff = require("modules.shortcuts.caps_word_auto_off")
			context.manager = require("modules.shortcuts.manager")
			context.manager.init({ enabled = true })
			context.path = path
			local called, failure = pcall(body, context)
			EventLoop.defer = original_defer
			if not called then error(failure, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

local NBSP = "\194\160"





-- =================================================================
-- =================================================================
-- ======= 2/ The settings owner ===================================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: the settings", function()
	helpers.it("caps word auto-off, reads the manifest defaults from an empty configuration", function()
		with_caps_word(nil, function(c)
			local settings = c.AutoOff.settings()
			helpers.assert_eq(settings.idle_timeout_seconds, 10, "10 s by default (maintainer decision of 2026-10-20)")
			helpers.assert_eq(table.concat(settings.terminators, ","), "space,nbsp,nnbsp,tab,enter,comma,semicolon,period")
			for _, kind in ipairs(c.AutoOff.pointer_kinds()) do
				helpers.assert_eq(settings.pointer[kind], true, kind .. " ends CapsWord by default")
			end
		end)
	end)

	helpers.it("caps word auto-off, declares exactly the manifest's pointer kinds", function()
		with_caps_word(nil, function(c)
			local Manifest = require("infra.manifest_reader")
			local expected = {}
			for _, entry in ipairs(Manifest.features()) do
				if entry.section == "shortcuts.caps_word.pointer" then expected[#expected + 1] = entry.id end
			end
			helpers.assert_true(#expected > 0, "the manifest declares pointer kinds")
			helpers.assert_eq(table.concat(c.AutoOff.pointer_kinds(), ","), table.concat(expected, ","))
		end)
	end)

	helpers.it("caps word auto-off, reads stored values and drops what this build does not know", function()
		local source = '[shortcuts.caps_word]\nidle_timeout_seconds = 5\nterminators = ["nbsp", "hyphen", "comma", "comma"]\n'
			.. '\n[shortcuts.caps_word.pointer]\nleft_click = false\nwheel = true\n'
		with_caps_word(source, function(c)
			local settings = c.AutoOff.settings()
			helpers.assert_eq(settings.idle_timeout_seconds, 5)
			helpers.assert_eq(table.concat(settings.terminators, ","), "nbsp,comma",
				"an unknown key and a duplicate are dropped")
			helpers.assert_eq(settings.pointer.left_click, false)
			helpers.assert_eq(settings.pointer.wheel, nil, "an undeclared kind is never read")
		end)
	end)

	helpers.it("caps word auto-off, reads a malformed delay or list as its default", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = -2\nterminators = "space"\n', function(c)
			local settings = c.AutoOff.settings()
			helpers.assert_eq(settings.idle_timeout_seconds, 10)
			helpers.assert_eq(table.concat(settings.terminators, ","), "space,nbsp,nnbsp,tab,enter,comma,semicolon,period")
		end)
	end)

	helpers.it("caps word auto-off, persists a change sparsely and in catalogue order", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.AutoOff.set_terminator("minus", true))
			helpers.assert_true(c.AutoOff.set_terminator("period", false))
			helpers.assert_true(c.AutoOff.set_pointer("middle_click", false))
			helpers.assert_true(c.AutoOff.set_idle_timeout_seconds(3))
			local file = assert(io.open(c.path, "rb"))
			local text = file:read("*a")
			file:close()
			helpers.assert_contains(text, 'terminators = ["space", "nbsp", "nnbsp", "minus", "tab", "enter", "comma", "semicolon"]')
			helpers.assert_contains(text, "middle_click = false")
			helpers.assert_contains(text, "idle_timeout_seconds = 3")
			c.AutoOff.reset_for_tests()
			local reread = c.AutoOff.settings()
			helpers.assert_eq(table.concat(reread.terminators, ","), "space,nbsp,nnbsp,minus,tab,enter,comma,semicolon")
			helpers.assert_eq(c.AutoOff.set_terminator("hyphen", true), false, "an unknown delimiter is refused")
			helpers.assert_eq(c.AutoOff.set_pointer("wheel", true), false, "an undeclared kind is refused")
			helpers.assert_eq(c.AutoOff.set_idle_timeout_seconds(-1), false, "a negative delay is refused")
		end)
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 3/ The pointer kinds of native events ===================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: evdev pointer kinds", function()
	helpers.it("caps word auto-off, names the kind of every pointer press", function()
		with_caps_word(nil, function(c)
			local Codes = require("infra.evdev_codes")
			local kind = c.AutoOff.pointer_kind_of_button
			helpers.assert_eq(kind(Codes.BTN_LEFT), "left_click")
			helpers.assert_eq(kind(Codes.BTN_RIGHT), "right_click")
			helpers.assert_eq(kind(Codes.BTN_MIDDLE), "middle_click")
			helpers.assert_eq(kind(0x113), "other_buttons", "BTN_SIDE")
			helpers.assert_eq(kind(0x116), "other_buttons", "BTN_BACK")
			helpers.assert_eq(kind(0x14a), "gesture", "BTN_TOUCH")
			helpers.assert_eq(kind(0x14d), "gesture", "BTN_TOOL_DOUBLETAP")
			helpers.assert_eq(kind(30), nil, "a keyboard key is no pointer kind")
			helpers.assert_eq(c.AutoOff.pointer_kind_of_motion(), "pointer_motion")
		end)
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 4/ The CapsWord session =================================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: the manager session", function()
	helpers.it("caps word auto-off, a checked delimiter ends CapsWord", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text("a"), false)
			helpers.assert_true(c.manager.is_caps_word_active(), "a letter keeps CapsWord on")
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), true)
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "a space ends CapsWord by default")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text("\t"), true, "a bare Tab ends it by default")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_control("enter"), true, "a modified Enter ends it too")
		end)
	end)

	helpers.it("caps word auto-off, an unchecked delimiter keeps CapsWord on", function()
		with_caps_word('[shortcuts.caps_word]\nterminators = ["tab"]\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), false)
			helpers.assert_eq(c.manager.caps_word_observe_text(NBSP), false, "an unchecked no-break space")
			helpers.assert_eq(c.manager.caps_word_observe_control("enter"), false)
			helpers.assert_true(c.manager.is_caps_word_active())
		end)
	end)

	helpers.it("caps word auto-off, a checked no-break space ends CapsWord and a space does not", function()
		with_caps_word('[shortcuts.caps_word]\nterminators = ["nbsp"]\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), false)
			helpers.assert_eq(c.manager.caps_word_observe_text(NBSP), true)
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, the delay ends a silent CapsWord and a keystroke postpones it", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 3\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			c.now = 3500
			c.manager.caps_word_observe_text("a")
			c.now = 4100
			c.run_due()
			helpers.assert_true(c.manager.is_caps_word_active(), "3 s from the activation, but 0.6 s from the key")
			c.now = 6500
			c.run_due()
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "3 s after the last key, the timer ends it")
		end)
	end)

	helpers.it("caps word auto-off, a key after the delay ends CapsWord before it is read", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 1\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			c.now = 2500
			helpers.assert_eq(c.manager.caps_word_observe_text("a"), false)
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, a whole-second clock never reads two quick keys as a pause", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 1\n', function(c)
			c.resolution = 1000
			helpers.assert_true(c.manager.toggle_caps_word())
			c.now = 2000
			c.manager.caps_word_observe_text("a")
			helpers.assert_true(c.manager.is_caps_word_active(), "a second turnover is no pause")
			c.now = 3000
			c.run_due()
			helpers.assert_true(c.manager.is_caps_word_active(), "the timer waits for a provable pause")
			helpers.assert_true(#c.deferred == 1 and c.deferred[1].due > c.now, "and queues itself for later, not for the next tick")
			c.now = 4000
			c.run_due()
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, never times out at a delay of 0", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 0\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(#c.deferred, 0, "no idle check is queued for « never »")
			c.now = 1e9
			c.manager.caps_word_observe_text("a")
			helpers.assert_true(c.manager.is_caps_word_active())
		end)
	end)

	helpers.it("caps word auto-off, the shipped 10 s delay ends a silent CapsWord", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(#c.deferred, 1, "the default delay arms an idle check")
			c.now = 1000 + 9999
			c.run_due()
			helpers.assert_true(c.manager.is_caps_word_active(), "not before 10 s")
			c.now = 1000 + 10000
			c.run_due()
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "10 s without a key ends it")
		end)
	end)

	helpers.it("caps word auto-off, the shipped delimiters end CapsWord on typed punctuation and no-break spaces", function()
		for _, text in ipairs({ ".", ",", ";", NBSP, "\226\128\175", "\194\160:" }) do
			with_caps_word(nil, function(c)
				helpers.assert_true(c.manager.toggle_caps_word())
				helpers.assert_eq(c.manager.caps_word_observe_text(text), true, string.format("%q ends CapsWord", text))
			end)
		end
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text("-"), false, "a hyphen stays unchecked")
		end)
	end)

	helpers.it("caps word auto-off, a checked pointer kind ends CapsWord and an unchecked one keeps it", function()
		with_caps_word('[shortcuts.caps_word.pointer]\nright_click = false\npointer_motion = false\n', function(c)
			local Codes = require("infra.evdev_codes")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_pointer(c.AutoOff.pointer_kind_of_button(Codes.BTN_RIGHT)), false)
			helpers.assert_eq(c.manager.caps_word_observe_pointer(c.AutoOff.pointer_kind_of_motion()), false)
			helpers.assert_eq(c.manager.caps_word_observe_pointer(nil), false, "an event of no kind")
			helpers.assert_true(c.manager.is_caps_word_active())
			helpers.assert_eq(c.manager.caps_word_observe_pointer(c.AutoOff.pointer_kind_of_button(Codes.BTN_LEFT)), true)
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, a new CapsWord reads the settings stored since the last one", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_true(c.manager.toggle_caps_word())
			local file = assert(io.open(c.path, "wb"))
			file:write('[shortcuts.caps_word]\nterminators = ["comma"]\n')
			file:close()
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), false, "the hand edit unchecked Space")
			helpers.assert_eq(c.manager.caps_word_observe_text(","), true)
		end)
	end)

	helpers.it("caps word auto-off, a session locks CapsLock and every way it ends unlocks it", function()
		-- The tray CapsWord once changed only the buffer's copy of a character:
		-- with no CapsLock locked, no capital ever reached the application.
		for _, ending in ipairs({
			{ name = "toggle", run = function(c) helpers.assert_true(c.manager.toggle_caps_word()) end },
			{ name = "delimiter", run = function(c) helpers.assert_true(c.manager.caps_word_observe_text(" ")) end },
			{ name = "pointer", run = function(c) helpers.assert_true(c.manager.caps_word_observe_pointer("left_click")) end },
			{ name = "pause", run = function(c) c.manager.cancel_caps_word("script paused") end },
			{ name = "shortcuts off", run = function(c) helpers.assert_true(c.manager.disable()) end },
			{ name = "delay", run = function(c) c.now = c.now + 10000; c.run_due() end },
		}) do
			-- The delay is spelled out: this case is about the unlock, not the default.
			with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 10\n', function(c)
				helpers.assert_true(c.manager.toggle_caps_word())
				helpers.assert_eq(c.hook.locks, 1, ending.name .. ": the session locks CapsLock")
				helpers.assert_true(c.hook.held)
				ending.run(c)
				helpers.assert_eq(c.manager.is_caps_word_active(), false, ending.name .. " ends the session")
				helpers.assert_eq(c.hook.releases, 1, ending.name .. " unlocks CapsLock once")
				helpers.assert_eq(c.hook.held, false)
			end)
		end
	end)

	helpers.it("caps word auto-off, a CapsLock that cannot be locked refuses the session", function()
		with_caps_word(nil, function(c)
			c.hook.refuse = "the keymap's CapsLock key does not toggle Caps Lock"
			helpers.assert_eq(c.manager.toggle_caps_word(), false)
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "no session without capitals to give")
			helpers.assert_eq(#c.deferred, 0, "a refused session arms no idle check")
		end)
	end)

	helpers.it("caps word auto-off, a hold the hook ends ends the session without a second unlock", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			c.hook.lose("CapsLock pressed")
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
			helpers.assert_eq(c.hook.releases, 0, "the user's CapsLock press is never toggled back")
			helpers.assert_true(c.manager.toggle_caps_word(), "a new session can start at once")
			helpers.assert_eq(c.hook.locks, 2)
		end)
	end)

	helpers.it("caps word auto-off, the session presses the CapsLock key on the daemon's device", function()
		with_caps_word(nil, function(c)
			local Emitter = require("modules.gestures.combo_emitter")
			local original, pressed = Emitter.press_codes, nil
			Emitter.press_codes = function(mods, keys) pressed = { mods = mods, keys = keys }; return true end
			local called, result = pcall(function()
				helpers.assert_true(c.manager.toggle_caps_word())
				return c.hook.emit()
			end)
			Emitter.press_codes = original
			helpers.assert_true(called, tostring(result))
			helpers.assert_eq(result, true)
			helpers.assert_eq(pressed, { mods = {}, keys = { require("infra.evdev_codes").KEY_CAPSLOCK } })
		end)
	end)

	helpers.it("(linux-caps-word-unlock-debt) retains the native output outcome through the manager emitter", function()
		with_caps_word(nil, function(c)
			local Emitter = require("modules.gestures.combo_emitter")
			local original = Emitter.press_codes
			local called, failure = pcall(function()
				helpers.assert_true(c.manager.toggle_caps_word())
				for _, kind in ipairs({ "refused", "unavailable", "native_failed", "custody_unresolved" }) do
					local issued = { kind = kind }
					Emitter.press_codes = function() return false, issued end
					local emitted, outcome = c.hook.emit()
					helpers.assert_eq(emitted, false)
					helpers.assert_true(outcome == issued, "the hook needs the exact original native outcome: " .. kind)
				end
			end)
			Emitter.press_codes = original
			if not called then error(failure, 0) end
		end)
	end)

	helpers.it("caps word auto-off, a shortcut configuration transaction ends the session and unlocks", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			local owner = {}
			c.manager.init({ enabled = true, persist = true, config_path = c.path })
			helpers.assert_eq(c.hook.releases, 1, "a re-initialisation unlocks a running session")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_true(c.manager.acquire_configuration(owner))
			local snapshot = c.manager.configuration_snapshot(owner)
			helpers.assert_eq(snapshot.caps_word_active, true)
			helpers.assert_true(c.manager.apply_configuration(owner, { enabled = true, wrap = false, caps_word_active = false }))
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
			helpers.assert_eq(c.hook.releases, 2)
			helpers.assert_true(c.manager.apply_configuration(owner, snapshot), "restoring the snapshot is acknowledged")
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "a lock is never restored from a value")
			helpers.assert_eq(c.hook.locks, 2)
			helpers.assert_true(c.manager.release_configuration(owner))
		end)
	end)

	helpers.it("(linux-caps-word-trigger) the catalogue action toggles the tray's session", function()
		-- A key, a key combination, a tap-hold or a gesture bound to caps_word
		-- reaches this handler through the action executor.
		with_caps_word(nil, function(c)
			local handler = c.manager.action_handlers().caps_word
			helpers.assert_eq(type(handler), "function", "the shortcuts manager answers caps_word")
			helpers.assert_true(handler("combination__left_alt_then_caps_lock"))
			helpers.assert_true(c.manager.is_caps_word_active(), "the same session the tray row shows")
			helpers.assert_eq(c.hook.locks, 1)
			helpers.assert_true(handler("combination__left_alt_then_caps_lock"))
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
			helpers.assert_eq(c.hook.releases, 1)
		end)
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 5/ The Shared Corpus, Session Deep ======================
-- =================================================================
-- =================================================================

--- Renders a TOML array of quoted delimiter keys.
--- @param keys table Dense array of delimiter keys.
--- @return string
local function toml_list(keys)
	local quoted = {}
	for index, key in ipairs(keys) do quoted[index] = string.format("%q", key) end
	return "[" .. table.concat(quoted, ", ") .. "]"
end

--- Reads the shared vectors the policy contract replays on every driver.
--- @return table corpus
local function corpus()
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/caps_word/auto_off_vectors.json"
	local file = assert(io.open(path, "rb"), "the shared CapsWord corpus is readable")
	local text = file:read("*a")
	file:close()
	return require("json").decode(text)
end

-- The policy contract proves each vector's verdict on the policy alone; these
-- cases replay the same vectors through the Linux session, so a verdict also
-- ends the session and unlocks its CapsLock, and a refusal keeps both.
helpers.describe("caps word session: the shared corpus", function()
	--- Asserts a session ended by a vector unlocked CapsLock, or kept it.
	local function assert_outcome(c, ended, expected, label)
		helpers.assert_eq(ended, expected, label)
		helpers.assert_eq(c.manager.is_caps_word_active(), not expected, label .. ": session state")
		helpers.assert_eq(c.hook.held, not expected, label .. ": CapsLock held")
		helpers.assert_eq(c.hook.releases, expected and 1 or 0, label .. ": unlocks")
	end

	helpers.it("(linux-caps-word-lock) every typed-text vector ends the session and unlocks only on a checked delimiter", function()
		local vectors = corpus().text
		helpers.assert_true(#vectors > 0, "the corpus has text vectors")
		for index, vector in ipairs(vectors) do
			local config = "[shortcuts.caps_word]\nterminators = " .. toml_list(vector.terminators) .. "\n"
			with_caps_word(config, function(c)
				helpers.assert_true(c.manager.toggle_caps_word())
				assert_outcome(c, c.manager.caps_word_observe_text(vector.text), vector.expected,
					string.format("text vector %d (%q)", index, vector.text))
			end)
		end
	end)

	helpers.it("(linux-caps-word-lock) every native-key vector ends the session and unlocks only on a checked delimiter", function()
		local vectors = corpus().keys
		helpers.assert_true(#vectors > 0, "the corpus has key vectors")
		for index, vector in ipairs(vectors) do
			local config = "[shortcuts.caps_word]\nterminators = " .. toml_list(vector.terminators) .. "\n"
			with_caps_word(config, function(c)
				helpers.assert_true(c.manager.toggle_caps_word())
				assert_outcome(c, c.manager.caps_word_observe_control(vector.key), vector.expected,
					string.format("key vector %d (%s)", index, vector.key))
			end)
		end
	end)

	helpers.it("(linux-caps-word-lock) every pointer vector ends the session and unlocks only on a checked kind", function()
		local data = corpus()
		helpers.assert_true(#data.pointer > 0, "the corpus has pointer vectors")
		for index, vector in ipairs(data.pointer) do
			local lines = { "[shortcuts.caps_word.pointer]" }
			for _, kind in ipairs(data.pointer_kinds) do
				lines[#lines + 1] = kind .. " = " .. tostring(assert(data.pointer_sets[vector.pointer])[kind])
			end
			with_caps_word(table.concat(lines, "\n") .. "\n", function(c)
				helpers.assert_true(c.manager.toggle_caps_word())
				assert_outcome(c, c.manager.caps_word_observe_pointer(vector.kind), vector.expected,
					string.format("pointer vector %d (%s, %s)", index, vector.pointer, vector.kind))
			end)
		end
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 6/ Wiring ===============================================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: daemon and hook wiring", function()
	local function source(rel)
		local f = assert(io.open(helpers.driver_root() .. "/" .. rel, "rb"))
		local text = f:read("*a")
		f:close()
		return text
	end

	helpers.it("caps word auto-off, the daemon reports characters, controls, presses and motion", function()
		local daemon = source("ergopti_hotstrings.lua")
		helpers.assert_contains(daemon, "shortcuts.caps_word_observe_text(ch)")
		helpers.assert_contains(daemon, "shortcuts.caps_word_observe_control(key_name)")
		helpers.assert_contains(daemon, "shortcuts.caps_word_observe_pointer_event(kind_of_event, code)")
		helpers.assert_contains(daemon, "onPointerEvent = on_pointer_event")
		-- The bare Tab returns early; the delimiter check must come before it.
		local observe = daemon:find("shortcuts.caps_word_observe_text(ch)", 1, true)
		local tab = daemon:find('if ch == "\\t" then', 1, true)
		helpers.assert_true(observe ~= nil and tab ~= nil and observe < tab, "the delimiter check precedes the Tab return")
	end)

	helpers.it("caps word auto-off, the daemon types no capital of its own and a pause ends the session", function()
		local daemon = source("ergopti_hotstrings.lua")
		helpers.assert_eq(daemon:find("process_caps_word", 1, true), nil,
			"the capitals come from the locked CapsLock, never from rewriting the buffer's copy")
		helpers.assert_contains(daemon, 'if paused and shortcuts then shortcuts.cancel_caps_word("script paused") end')
	end)

	helpers.it("caps word auto-off, every typed character reaches the delimiter check, whatever produced it", function()
		-- Layout keys, number-row levels and dead-key results are resolved by the
		-- hook and handed to the character callback; tap-hold and layer outputs
		-- are dispatched again through the same path; injected text is reported
		-- by the injector (test_injector_output_observer).
		local hook = source("adapters/keyboard_hook.lua")
		helpers.assert_contains(hook, '_call_callback("character callback", _on_char, char, ev.code)')
		helpers.assert_contains(hook, '_call_callback("text-control callback", _on_char, text_char, ev.code)')
		helpers.assert_contains(hook, "else _dispatch_event(emitted_event, emitted_source) end")
		local daemon = source("ergopti_hotstrings.lua")
		helpers.assert_contains(daemon, "onChar  = on_char,")
		helpers.assert_contains(daemon, "injector.set_output_observer(function(text)")
	end)

	helpers.it("caps word auto-off, a delimiter in the daemon's own output ends CapsWord", function()
		with_caps_word(nil, function(c)
			local observed = assert(source("ergopti_hotstrings.lua"):match(
				"injector%.set_output_observer%(function%(text%)(.-)\n\tend%) then"), "the daemon's output observer is missing")
			local observer = assert((loadstring or load)(
				"return function(shortcuts) return function(text) " .. observed .. " end end"))()(c.manager)
			helpers.assert_true(c.manager.toggle_caps_word())
			observer("BONJOUR")
			helpers.assert_true(c.manager.is_caps_word_active(), "letters keep CapsWord")
			observer("c'est-à-dire,")
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "an expansion ending in a comma ends CapsWord")
		end)
	end)

	helpers.it("caps word auto-off, the hook hands every pointer press and EV_REL report to the callback", function()
		local hook = source("adapters/keyboard_hook.lua")
		helpers.assert_contains(hook, '_call_callback("pointer event callback", _on_pointer_event, "motion", ev.code)')
		helpers.assert_contains(hook, '_call_callback("pointer event callback", _on_pointer_event, "press", ev.code)')
		helpers.assert_contains(hook, "_on_pointer_event = options.onPointerEvent")
	end)

	helpers.it("caps word auto-off, the manager maps a native press and motion to their declared kinds", function()
		with_caps_word('[shortcuts.caps_word.pointer]\nmiddle_click = false\n', function(c)
			local Codes = require("infra.evdev_codes")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_pointer_event("press", Codes.BTN_MIDDLE), false,
				"an unchecked middle click keeps CapsWord on")
			helpers.assert_eq(c.manager.caps_word_observe_pointer_event("press", 30), false,
				"a keyboard code pressed on a pointer is no kind, never a motion")
			helpers.assert_true(c.manager.is_caps_word_active())
			helpers.assert_eq(c.manager.caps_word_observe_pointer_event("motion", 0x00), true)
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, the daemon's main() stays within LuaJIT's 60 upvalues", function()
		-- The pointer-kind table once captured by main() pushed it to 61: CI's
		-- LuaJIT refused to compile the daemon at all. test_parse_coverage owns
		-- the budget; this pins the CapsWord side of it.
		local daemon = source("ergopti_hotstrings.lua")
		helpers.assert_eq(daemon:find("CapsWordAutoOff", 1, true), nil,
			"main() reaches the pointer kinds through the manager")
	end)
end)

return true
