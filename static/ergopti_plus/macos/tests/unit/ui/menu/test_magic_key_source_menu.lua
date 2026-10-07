--- tests/unit/ui/menu/test_magic_key_source_menu.lua

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
}

--- Runs body against the real menu module, its timers, notifications and
--- event tap recorded.
--- @param body function body(Menu, world)
local function with_menu(body)
	helpers.with_fresh_modules(MODULES, function()
		local world = { timers = {}, notices = {}, taps = {} }
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, fn)
				local handle = { delay = delay, fn = fn }
				world.timers[#world.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle) handle.cancelled = true return true end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind)
				world.notices[#world.notices + 1] = { title = title, body = body, kind = kind }
				return true
			end,
		}
		local base = require("tests.stubs.hs").eventtap
		local eventtap = {}
		for key, value in pairs(base) do eventtap[key] = value end
		eventtap.new = function(types, callback)
			local tap = { types = types, callback = callback, running = false }
			function tap:start() self.running = true return self end
			function tap:stop() self.running = false return self end
			world.taps[#world.taps + 1] = tap
			return tap
		end
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
local function key_down(keycode)
	return {
		getProperty = function() return 0 end,
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
			for _, code in ipairs({ "Backquote", "IntlBackslash" }) do
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
			helpers.assert_true(world.taps[1].callback(key_down(50)))
			run_deferred(world)
			helpers.assert_eq(ctx.saves, 0, "captured conflicts use the same pre-write refusal")
			helpers.assert_eq(Tap.get_action("number_row_left"), "send_text")
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
