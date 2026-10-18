--- tests/unit/ui/menu/hotstrings/test_magic_key_source_menu.lua

--- ==============================================================================
--- MODULE: Physical Magic Key Menu (macOS)
--- DESCRIPTION:
--- The keyboard-layout menu offers the physical key that types the magic key
--- on every OS: chosen by pressing it or from the candidates. macOS had no way
--- to choose it. These cases drive the real menu module over recording ports:
--- a choice is saved before it is applied and a refused save changes nothing,
--- and the capture tap takes one physical key-down, ignores Escape and the
--- timeout, refuses a key that cannot type the magic key and lets every later
--- key through.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYCODE_J = 38
local KEYCODE_SPACE = 49
local KEYCODE_ESCAPE = 53

local MODULES = {
	"ui.menu.magic_key_source_menu", "adapters.timer_scheduler", "infra.notifications",
	"modules.keymap.magic_key_source", "modules.shortcuts.tap_keys", "infra.manifest_menu",
	"adapters.keyboard_geometry", "adapters.event_provenance", "modules.shortcuts.script_control",
}

--- Runs body against the real menu module, its timers, notifications and
--- event tap recorded.
--- @param body function body(Menu, world)
local function with_menu(body, faults)
	helpers.with_fresh_modules(MODULES, function()
		local world = { timers = {}, notices = {}, taps = {}, faults = faults or {}, cancellations = {} }
		world.pause = { paused = false, pending = false, epoch = 0 }
		world.pause_owner = {
			is_paused = function()
				if world.pause.throw then error("Controlled pause observation refusal") end
				return world.pause.paused
			end,
			is_pause_transition_pending = function() return world.pause.pending end,
			get_pause_epoch = function() return world.pause.epoch end,
		}
		package.loaded["modules.shortcuts.script_control"] = world.pause_owner
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, fn)
				local handle = { delay = delay, fn = fn }
				local mode = delay == 0 and world.faults.answer or world.faults.deadline
				if mode == "throw" then error("Controlled timer construction refusal") end
				world.timers[#world.timers + 1] = handle
				if mode == "premature" then fn() end
				if delay == 0 and world.faults.answer_pause then world.pause.epoch = world.pause.epoch + 1 end
				return handle, mode ~= "refuse"
			end,
			cancel = function(handle)
				world.cancellations[#world.cancellations + 1] = handle
				if world.faults.cancel == "throw" then error("Controlled cancellation refusal") end
				if world.faults.cancel == "refuse" then return false end
				handle.cancelled = true
				return true
			end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind)
				world.notices[#world.notices + 1] = { title = title, body = body, kind = kind }
				return true
			end,
		}
		if world.faults.provenance then
			local original = require("adapters.event_provenance")
			local recording = {}
			for key, value in pairs(original) do recording[key] = value end
			recording.classify_with_fence = function(event, consumer)
				if world.faults.fence then return nil, nil, world.faults.fence end
				return original.classify_with_fence(event, consumer)
			end
			package.loaded["adapters.event_provenance"] = recording
		end

		local base = require("tests.stubs.hs").eventtap
		local eventtap = {}
		for key, value in pairs(base) do eventtap[key] = value end
		eventtap.new = function(types, callback)
			if world.faults.construct == "throw" then error("Controlled tap construction refusal") end
			local tap = { types = types, callback = callback, running = false, stops = 0 }
			function tap:start()
				self.running = world.faults.start ~= "inactive"
				if world.faults.start == "throw" then error("Controlled tap activation refusal") end
				if world.faults.start == "refuse" then return false end
				if world.faults.start_pause then world.pause.epoch = world.pause.epoch + 1 end
				return self
			end
			function tap:stop()
				self.stops = self.stops + 1
				if world.faults.stop == "throw" then error("Controlled tap stop refusal") end
				if world.faults.stop == "refuse" then return false end
				self.running = world.faults.stop == "active"
				if world.faults.stop_pause then world.pause.epoch = world.pause.epoch + 1 end
				return self
			end
			function tap:isEnabled()
				if world.faults.observation == "throw" then error("Controlled tap state refusal") end
				return self.running
			end
			world.taps[#world.taps + 1] = tap
			return tap
		end
		package.loaded["adapters.keyboard_geometry"] = require("tests.support.keyboard_geometry_ports").new(eventtap.event.properties)
		world.keycodes = { map = { [KEYCODE_J] = "j", [KEYCODE_SPACE] = "space" } }
		local Menu = helpers.load_with_stubs("ui.menu.magic_key_source_menu",
			{ eventtap = eventtap, keycodes = world.keycodes })
		body(Menu, world)
	end)
end

--- A menu context whose save and keymap are recorded.
--- @param save_ok boolean What save_prefs answers.
--- @return table ctx
local function context(save_ok)
	local ctx = { state = { magic_key_source = "auto" }, applied = {}, saves = 0, updates = 0 }
	ctx.save_prefs = function()
		ctx.saves = ctx.saves + 1
		return save_ok
	end
	ctx.keymap = { set_magic_key_source = function(value) ctx.applied[#ctx.applied + 1] = value return true end }
	ctx.update_menu = function() ctx.updates = ctx.updates + 1 end
	return ctx
end

--- A physical keyDown for the capture tap.
local function key_down(keycode, model)
	return {
		getProperty = function(_, property)
			if property == require("tests.stubs.hs").eventtap.event.properties.keyboardEventKeyboardType then return model end
			return 0
		end,
		getKeyCode = function() return keycode end,
	}
end

--- Runs every due zero-delay timer, as the next run-loop turn would.
local function run_deferred(world)
	for _, handle in ipairs(world.timers) do
		if handle.delay == 0 and not handle.ran then
			handle.ran = true
			handle.fn()
		end
	end
end

helpers.describe("magic key source menu: choosing a key", function()
	helpers.it("(magic-key-source) saves the choice, then applies it", function()
		with_menu(function(Menu)
			local ctx = context(true)
			helpers.assert_true(Menu.choose(ctx, "KeyJ"))
			helpers.assert_eq(ctx.state.magic_key_source, "KeyJ")
			helpers.assert_eq(ctx.saves, 1)
			helpers.assert_eq(ctx.applied, { "KeyJ" })
			helpers.assert_eq(ctx.updates, 1)
		end)
	end)

	helpers.it("(magic-key-source) a refused save changes neither the state nor the running key", function()
		with_menu(function(Menu)
			local ctx = context(false)
			helpers.assert_eq(Menu.choose(ctx, "KeyJ"), false)
			helpers.assert_eq(ctx.state.magic_key_source, "auto")
			helpers.assert_eq(#ctx.applied, 0)
		end)
	end)

	helpers.it("(magic-key-source) the rows label keys by the input source and grey capture while paused", function()
		with_menu(function(Menu)
			local rows = Menu.rows(context(true))
			local items = rows[1].items
			helpers.assert_type(items[1].action, "function", "the capture row presses a key")
			local found = false
			for _, item in ipairs(items) do
				if item.label == "j   (KeyJ)" then found = true end
			end
			helpers.assert_true(found, "KeyJ is labelled by what the input source types on it")
			local paused = context(true)
			paused.paused = true
			helpers.assert_true(Menu.rows(paused)[1].items[1].disabled, "no capture while Ergopti is paused")
		end)
	end)
end)

helpers.describe("magic key source menu: capturing a key", function()
	helpers.it("(magic-key-source) the next physical key-down becomes the physical magic key", function()
		with_menu(function(Menu, world)
			local ctx = context(true)
			helpers.assert_true(Menu.capture(ctx))
			helpers.assert_eq(Menu.capture(ctx), false, "one capture at a time")
			local tap = world.taps[1]
			helpers.assert_true(tap.running)
			helpers.assert_eq(world.notices[1].body, require("infra.i18n").get("dialog.magic_key_source.prompt"),
				"the user is asked for a key")
			helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), true, "the answering key never reaches an app")
			helpers.assert_eq(tap.callback(key_down(KEYCODE_SPACE)), false, "every later key passes through")
			helpers.assert_eq(#ctx.applied, 0, "nothing is saved inside the event tap")
			run_deferred(world)
			helpers.assert_eq(ctx.applied, { "KeyJ" })
			helpers.assert_eq(ctx.state.magic_key_source, "KeyJ")
			helpers.assert_eq(tap.running, false, "the tap stops with its answer")
			helpers.assert_eq(Menu.capturing(), false)
		end)
	end)

	helpers.it("(magic-key-source) Escape and the timeout end the capture with nothing changed", function()
		with_menu(function(Menu, world)
			local ctx = context(true)
			Menu.capture(ctx)
			world.taps[1].callback(key_down(KEYCODE_ESCAPE))
			run_deferred(world)
			helpers.assert_eq(#ctx.applied, 0)
			helpers.assert_eq(Menu.capturing(), false)

			Menu.capture(ctx)
			local timeout = world.timers[#world.timers]
			helpers.assert_true(timeout.delay > 0, "the capture carries the shared timeout")
			timeout.fn()
			helpers.assert_eq(#ctx.applied, 0)
			helpers.assert_eq(world.taps[2].running, false)
			helpers.assert_eq(Menu.capturing(), false)
		end)
	end)

	helpers.it("(magic-key-source) a key that cannot type the magic key is refused aloud", function()
		with_menu(function(Menu, world)
			local ctx = context(true)
			Menu.capture(ctx)
			world.taps[1].callback(key_down(KEYCODE_SPACE))
			run_deferred(world)
			helpers.assert_eq(#ctx.applied, 0)
			helpers.assert_eq(world.notices[#world.notices].body,
				require("infra.i18n").get("dialog.magic_key_source.not_a_candidate"))
			helpers.assert_eq(world.notices[#world.notices].kind, "warning")
		end)
	end)
end)

helpers.describe("magic key source menu: configured tap ownership", function()
	helpers.it("(magic-key-source) selection and capture refuse an assigned source before any save", function()
		with_menu(function(Menu, world)
			local Tap = require("modules.shortcuts.tap_keys")
			local actions = require("modules.gestures.actions")
			helpers.assert_true(Tap.apply_configuration({ shortcuts = { tap_keys = { number_row_left = "send_text" } } }, actions.is_assignable))
			local ctx = context(true)
			for _, code in ipairs({ "Backquote" }) do
				helpers.assert_eq(Menu.choose(ctx, code), false)
			end
			helpers.assert_eq(ctx.saves, 0)
			helpers.assert_eq(ctx.applied, {})
			helpers.assert_eq(ctx.state.magic_key_source, "auto")
			local reason = require("infra.i18n").get(require("keymap.magic_key_source").TAP_CONFLICT_REASON)
			helpers.assert_eq(world.notices[1].body, reason)
			local row = nil
			for _, candidate in ipairs(Menu.rows(ctx)[1].items) do
				if candidate.label and candidate.label:find("(Backquote)", 1, true) or candidate.label == "Backquote — " .. reason then row = candidate end
			end
			helpers.assert_true(row and row.disabled)
			helpers.assert_nil(row.action)
			helpers.assert_true(Menu.capture(ctx))
			helpers.assert_true(world.taps[1].callback(key_down(50, 7001)))
			run_deferred(world)
			helpers.assert_eq(ctx.saves, 0, "captured conflicts use the same pre-write refusal")
			helpers.assert_eq(Tap.get_action("number_row_left"), "send_text")
			helpers.assert_true(Menu.choose(ctx, "IntlBackslash"), "the ISO neighbor is a distinct physical assignment")
			helpers.assert_eq(ctx.applied, { "IntlBackslash" })
			helpers.assert_true(Menu.choose(ctx, "auto"), "automatic never takes a configured tap")
		end)
	end)
end)

helpers.describe("magic key source: the actual declared native menu", function()
	helpers.it("(magic-key-source) cold English and warm French use the real native renderer and retain capture and choice callbacks", function()
		helpers.with_stub_scope({ "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu", "ui.menu.magic_key_source_menu" }, function()
			with_menu(function(_, world)
				package.loaded["infra.i18n"], package.loaded["infra.locale"] = nil, nil
				local translations = require("infra.i18n")
				local locale = require("infra.locale")
				package.loaded["infra.manifest_menu"], package.loaded["ui.menu.magic_key_source_menu"] = nil, nil
				local Menu = require("ui.menu.magic_key_source_menu")
				local Source = require("modules.keymap.magic_key_source")
				Source.set("KeyJ")
				for _, language in ipairs({ "en", "fr" }) do
					locale.set_locale(language)
					local ctx = context(true)
					local rows = Menu.rows(ctx)
					helpers.assert_eq(#world.taps, 0, "construction cannot start native capture")
					helpers.assert_eq(ctx.saves, 0, "construction never persists")
					helpers.assert_eq(rows[1].label, translations.get("menu.layout.magic_key_source") .. " : j   (KeyJ)")
					helpers.assert_eq(rows[1].items[1].label, translations.get("menu.layout.magic_key_source.capture"))
					helpers.assert_eq(rows[1].items[3].label, translations.get("menu.layout.magic_key_source.auto"))
					helpers.assert_true(rows[1].items[2].separator)
					helpers.assert_true(rows[1].items[4].separator)
					rows[1].items[3].action()
					helpers.assert_eq(ctx.saves, 1, "the actual native chooser saves once")
					helpers.assert_eq(ctx.applied, { "auto" })
				end
				local renderer = require("infra.manifest_menu")
				local declaration = renderer.get_root()
				local saved = declaration.magic_key_source_children
				local retained = Menu.rows(context(true))[1].items[1].action
				local ok, err = pcall(function()
					declaration.magic_key_source_children = nil
					helpers.assert_nil(Menu.rows(context(true)), "withdrawal cannot resurrect native fixed rows")
					helpers.assert_eq(retained(), false)
					helpers.assert_eq(#world.taps, 0, "withdrawn capture never starts its actual event tap")
				end)
				declaration.magic_key_source_children = saved
				if not ok then error(err, 0) end
				local repaired = Menu.rows(context(true))
				repaired[1].items[1].action()
				helpers.assert_eq(#world.taps, 1, "restored declaration enters the genuine capture body")
				world.taps[1].callback(key_down(KEYCODE_ESCAPE)); run_deferred(world)
				helpers.assert_eq(Menu.capturing(), false)
			end)
		end)
	end)
end)


helpers.describe("magic key source menu: event-bound keyboard geometry", function()
	for _, row in ipairs({
		{ name = "ANSI Backquote", code = 50, model = 7001, expected = "Backquote" },
		{ name = "ANSI neighbor", code = 10, model = 7001, expected = "IntlBackslash" },
		{ name = "ISO Backquote", code = 10, model = 7002, expected = "Backquote" },
		{ name = "ISO neighbor", code = 50, model = 7002, expected = "IntlBackslash" },
	}) do
		helpers.it("captures " .. row.name .. " from the same event before deferred persistence", function()
			with_menu(function(Menu, world)
				local ctx = context(true)
				helpers.assert_true(Menu.capture(ctx))
				local event = key_down(row.code, row.model)
				helpers.assert_true(world.taps[1].callback(event))
				helpers.assert_eq(ctx.saves, 0)
				event.getProperty = function() error("The original event must not be reread after deferral") end
				run_deferred(world)
				helpers.assert_eq(ctx.state.magic_key_source, row.expected)
				helpers.assert_eq(ctx.applied, { row.expected })
				helpers.assert_eq(ctx.saves, 1)
				helpers.assert_eq(Menu.capturing(), false)
				helpers.assert_eq(world.taps[1].running, false)
			end)
		end)
	end
	helpers.it("leaves an unproved or JIS swapped position native without persisting a neighbor", function()
		for _, model in ipairs({ 7003, 7004, "7002", -1, 7002.5, 32768 }) do
			with_menu(function(Menu, world)
				local ctx = context(true)
				helpers.assert_true(Menu.capture(ctx))
				helpers.assert_eq(world.taps[1].callback(key_down(10, model)), false)
				run_deferred(world)
				helpers.assert_eq(ctx.saves, 0)
				helpers.assert_eq(ctx.applied, {})
				helpers.assert_eq(ctx.state.magic_key_source, "auto")
				helpers.assert_eq(Menu.capturing(), false)
			end)
		end
	end)
end)

helpers.describe("magic key source menu: physical labels without an event", function()
	helpers.it("does not label a swapped candidate using the opposite ANSI glyph", function()
		with_menu(function(Menu, world)
			world.keycodes.map[50], world.keycodes.map[10] = "@", "<"
			require("modules.keymap.magic_key_source").set("Backquote")
			local rows = Menu.rows(context(true))
			helpers.assert_eq(rows[1].label:sub(-#"Backquote"), "Backquote")
			local labels = {}
			for _, item in ipairs(rows[1].items) do
				if item.label then labels[item.label] = true end
			end
			helpers.assert_true(labels.Backquote)
			helpers.assert_true(labels.IntlBackslash)
			helpers.assert_nil(labels["@   (Backquote)"])
			helpers.assert_nil(labels["<   (IntlBackslash)"])
			helpers.assert_eq(#world.taps, 0)
			helpers.assert_eq(labels["j   (KeyJ)"], true, "a stable physical key retains its real input-source glyph")
		end)
	end)
end)

helpers.describe("magic key source menu: native capture admission", function()
	for _, spec in ipairs({
		{ field = "construct", mode = "throw" },
		{ field = "deadline", mode = "refuse" },
		{ field = "deadline", mode = "throw" },
		{ field = "deadline", mode = "premature" },
		{ field = "start", mode = "refuse" },
		{ field = "start", mode = "throw" },
		{ field = "start", mode = "inactive" },
		{ field = "observation", mode = "throw" },
	}) do
		helpers.it("refuses " .. spec.field .. " " .. spec.mode .. " without admitting capture or a choice", function()
			with_menu(function(Menu, world)
				local ctx = context(true)
				helpers.assert_eq(Menu.capture(ctx), false)
				helpers.assert_eq(ctx.saves, 0)
				helpers.assert_eq(ctx.applied, {})
				helpers.assert_eq(#world.notices, 0)
				if world.taps[1] then
					helpers.assert_eq(world.taps[1].callback(key_down(KEYCODE_J)), false)
				end
				world.faults[spec.field] = nil
				helpers.assert_true(Menu.capture(ctx), "an exact cleanup retry permits a new capture")
				local tap = world.taps[#world.taps]
				helpers.assert_true(tap:isEnabled())
				tap.callback(key_down(KEYCODE_ESCAPE)); run_deferred(world)
				helpers.assert_eq(Menu.capturing(), false)
			end, { [spec.field] = spec.mode })
		end)
	end
end)

helpers.describe("magic key source menu: deferred answer admission", function()
	for _, mode in ipairs({ "refuse", "throw", "premature" }) do
		helpers.it("lets the physical key through after answer timer " .. mode .. " and accepts a later retry", function()
			with_menu(function(Menu, world)
				local ctx = context(true)
				helpers.assert_true(Menu.capture(ctx))
				local tap = world.taps[1]
				helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), false)
				run_deferred(world)
				helpers.assert_eq(ctx.saves, 0)
				helpers.assert_eq(ctx.state.magic_key_source, "auto")
				helpers.assert_true(Menu.capturing())
				world.faults.answer = nil
				helpers.assert_true(tap.callback(key_down(KEYCODE_J)))
				run_deferred(world)
				helpers.assert_eq(ctx.saves, 1)
				helpers.assert_eq(ctx.applied, { "KeyJ" })
				helpers.assert_eq(Menu.capturing(), false)
			end, { answer = mode })
		end)
	end
end)

helpers.describe("magic key source menu: exact native retirement", function()
	for _, spec in ipairs({
		{ field = "stop", mode = "refuse" },
		{ field = "stop", mode = "throw" },
		{ field = "stop", mode = "active" },
		{ field = "cancel", mode = "refuse" },
		{ field = "cancel", mode = "throw" },
	}) do
		helpers.it("retains " .. spec.field .. " " .. spec.mode .. " debt before a successor or persistence", function()
			with_menu(function(Menu, world)
				local ctx = context(true)
				helpers.assert_true(Menu.capture(ctx))
				local tap = world.taps[1]
				helpers.assert_true(tap.callback(key_down(KEYCODE_J)))
				run_deferred(world)
				helpers.assert_eq(ctx.saves, 0)
				helpers.assert_eq(ctx.applied, {})
				helpers.assert_eq(ctx.state.magic_key_source, "auto")
				helpers.assert_true(Menu.capturing(), "cleanup debt retains its exact owner")
				helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), false, "retired generation cannot consume")
				helpers.assert_eq(Menu.capture(ctx), false)
				helpers.assert_eq(#world.taps, 1, "no replacement tap while retirement is unsettled")
				world.faults[spec.field] = nil
				helpers.assert_true(Menu.capture(ctx))
				helpers.assert_eq(#world.taps, 2)
				helpers.assert_eq(tap.running, false)
				helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), false)
				world.taps[2].callback(key_down(KEYCODE_ESCAPE)); run_deferred(world)
				helpers.assert_eq(Menu.capturing(), false)
				helpers.assert_eq(ctx.saves, 0, "a failed retirement never replays the discarded choice")
			end, { [spec.field] = spec.mode })
		end)
	end

	helpers.it("retains a rejected answer timer when its exact cancellation fails", function()
		with_menu(function(Menu, world)
			local ctx = context(true)
			helpers.assert_true(Menu.capture(ctx))
			local tap = world.taps[1]
			helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), false)
			local rejected = world.timers[#world.timers]
			helpers.assert_eq(Menu.capture(ctx), false)
			helpers.assert_eq(#world.taps, 1)
			helpers.assert_true(Menu.capturing())
			helpers.assert_nil(rejected.cancelled)
			rejected.fn()
			helpers.assert_eq(ctx.saves, 0)
			world.faults.answer, world.faults.cancel = nil, nil
			helpers.assert_true(Menu.capture(ctx))
			helpers.assert_true(rejected.cancelled, "the same rejected handle retires before replacement")
			helpers.assert_eq(#world.taps, 2)
			world.taps[2].callback(key_down(KEYCODE_ESCAPE)); run_deferred(world)
			helpers.assert_eq(Menu.capturing(), false)
		end, { answer = "refuse", cancel = "refuse" })
	end)
end)

helpers.describe("magic key source menu: retained event provenance fences", function()
	for _, retiring in ipairs({ false, true }) do
		helpers.it("preserves owned synthetic fences while " .. (retiring and "retiring" or "answered"), function()
			with_menu(function(Menu, world)
				local ctx = context(true)
				helpers.assert_true(Menu.capture(ctx))
				local tap = world.taps[1]
				helpers.assert_true(tap.callback(key_down(KEYCODE_J)))
				if retiring then
					world.faults.stop = "refuse"
					run_deferred(world)
				end
				local replacement = { key_down(KEYCODE_SPACE) }
				world.faults.fence = { consume_original = true, events = replacement }
				local consumed, events = tap.callback(key_down(KEYCODE_J))
				helpers.assert_true(consumed, "the original owned provenance fence remains authoritative")
				helpers.assert_true(events == replacement)
				world.faults.fence = { consume_original = false, events = replacement }
				consumed, events = tap.callback(key_down(KEYCODE_J))
				helpers.assert_eq(consumed, false)
				helpers.assert_true(events == replacement, "retired user capture still forwards fence events")
				world.faults.fence, world.faults.stop = nil, nil
				if retiring then
					helpers.assert_true(Menu.capture(ctx))
					world.taps[2].callback(key_down(KEYCODE_ESCAPE))
				end
				run_deferred(world)
				helpers.assert_eq(ctx.saves, retiring and 0 or 1)
				helpers.assert_eq(Menu.capturing(), false)
			end, { provenance = true })
		end)
	end
end)

helpers.describe("magic key source menu: live pause admission", function()
	for _, invalid in ipairs({ "missing", "paused", "pending", "unknown", "negative", "fractional", "throw" }) do
		helpers.it("refuses capture with " .. invalid .. " live pause state before acquisition", function()
			with_menu(function(Menu, world)
				local ctx = context(true)
				if invalid == "missing" then package.loaded["modules.shortcuts.script_control"] = nil end
				if invalid == "paused" then world.pause.paused = true end
				if invalid == "pending" then world.pause.pending = true end
				if invalid == "unknown" then world.pause.epoch = nil end
				if invalid == "negative" then world.pause.epoch = -1 end
				if invalid == "fractional" then world.pause.epoch = 0.5 end
				if invalid == "throw" then world.pause.throw = true end
				helpers.assert_eq(Menu.capture(ctx), false)
				helpers.assert_eq(#world.taps, 0)
				helpers.assert_eq(#world.timers, 0)
				helpers.assert_eq(ctx.saves, 0)
				world.pause = { paused = false, pending = false, epoch = 2 }
				package.loaded["modules.shortcuts.script_control"] = world.pause_owner
				helpers.assert_true(Menu.capture(ctx))
				world.taps[1].callback(key_down(KEYCODE_ESCAPE)); run_deferred(world)
				helpers.assert_eq(Menu.capturing(), false)
			end)
		end)
	end
end)

helpers.describe("magic key source menu: pause crossings retire captured choices", function()
	for _, stage in ipairs({ "before_press", "after_answer" }) do
		for _, crossing in ipairs({ "paused", "pending", "roundtrip", "replaced" }) do
			helpers.it("discards " .. crossing .. " boundary " .. stage .. " without saving", function()
				with_menu(function(Menu, world)
					local ctx = context(true)
					helpers.assert_true(Menu.capture(ctx))
					local tap = world.taps[1]
					if stage == "after_answer" then helpers.assert_true(tap.callback(key_down(KEYCODE_J))) end
					if crossing == "paused" then world.pause.paused = true end
					if crossing == "pending" then world.pause.pending = true end
					if crossing == "roundtrip" then world.pause.epoch = world.pause.epoch + 2 end
					if crossing == "replaced" then
						package.loaded["modules.shortcuts.script_control"] = {
							is_paused = world.pause_owner.is_paused,
							is_pause_transition_pending = world.pause_owner.is_pause_transition_pending,
							get_pause_epoch = world.pause_owner.get_pause_epoch,
						}
					end
					if stage == "before_press" then helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), false) end
					run_deferred(world)
					helpers.assert_eq(ctx.saves, 0)
					helpers.assert_eq(ctx.state.magic_key_source, "auto")
					helpers.assert_eq(ctx.applied, {})
					helpers.assert_eq(tap.running, false)
					helpers.assert_eq(Menu.capturing(), false)
				end)
			end)
		end
	end

	for _, boundary in ipairs({ "start_pause", "answer_pause" }) do
		helpers.it("refuses reentrant " .. boundary .. " before capture or key consumption", function()
			with_menu(function(Menu, world)
				local ctx = context(true)
				if boundary == "start_pause" then
					helpers.assert_eq(Menu.capture(ctx), false)
				else
					helpers.assert_true(Menu.capture(ctx))
					helpers.assert_eq(world.taps[1].callback(key_down(KEYCODE_J)), false)
				end
				run_deferred(world)
				helpers.assert_eq(ctx.saves, 0)
				helpers.assert_eq(Menu.capturing(), false)
				helpers.assert_eq(world.taps[1].running, false)
			end, { [boundary] = true })
		end)
	end

	helpers.it("keeps failed pause-boundary retirement owned until exact retry", function()
		with_menu(function(Menu, world)
			local ctx = context(true)
			helpers.assert_true(Menu.capture(ctx))
			local tap = world.taps[1]
			helpers.assert_true(tap.callback(key_down(KEYCODE_J)))
			world.pause.epoch = world.pause.epoch + 2
			world.faults.stop = "refuse"
			run_deferred(world)
			helpers.assert_eq(ctx.saves, 0)
			helpers.assert_true(Menu.capturing())
			helpers.assert_eq(Menu.capture(ctx), false)
			helpers.assert_eq(#world.taps, 1)
			helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), false)
			world.faults.stop = nil
			helpers.assert_true(Menu.capture(ctx))
			helpers.assert_eq(tap.running, false)
			world.taps[2].callback(key_down(KEYCODE_ESCAPE)); run_deferred(world)
			helpers.assert_eq(ctx.saves, 0)
			helpers.assert_eq(Menu.capturing(), false)
		end)
	end)

	helpers.it("honors the original synthetic provenance fence before paused user capture", function()
		with_menu(function(Menu, world)
			local ctx = context(true)
			helpers.assert_true(Menu.capture(ctx))
			local tap = world.taps[1]
			world.pause.paused = true
			local replacement = { key_down(KEYCODE_SPACE) }
			world.faults.fence = { consume_original = true, events = replacement }
			local consumed, events = tap.callback(key_down(KEYCODE_J))
			helpers.assert_true(consumed)
			helpers.assert_true(events == replacement)
			helpers.assert_eq(ctx.saves, 0)
			world.faults.fence = nil
			helpers.assert_eq(tap.callback(key_down(KEYCODE_J)), false)
			helpers.assert_eq(Menu.capturing(), false)
		end, { provenance = true })
	end)
end)

helpers.describe("magic key source menu: retirement preserves the pause boundary", function()
	helpers.it("revalidates the active epoch after native retirement before saving", function()
		with_menu(function(Menu, world)
			local ctx = context(true)
			helpers.assert_true(Menu.capture(ctx))
			helpers.assert_true(world.taps[1].callback(key_down(KEYCODE_J)))
			run_deferred(world)
			helpers.assert_eq(ctx.saves, 0)
			helpers.assert_eq(ctx.applied, {})
			helpers.assert_eq(ctx.state.magic_key_source, "auto")
			helpers.assert_eq(Menu.capturing(), false)
		end, { stop_pause = true })
	end)
end)
