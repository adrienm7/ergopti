--- tests/unit/ui/test_program_provider_picker.lua

--- Session and cleanup receipts for the production shared helper and Linux bridge.
local helpers = require("tests.helpers")
local SCALAR = '{"version":1,"executable":"/private/tool","arguments":["two words",""]}'

local function isolated(body)
	local saved = {}
	for key, value in pairs(package.loaded) do saved[key] = value end
	local ok, failure = xpcall(body, debug.traceback)
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	if not ok then error(failure, 0) end
end

local function shared(body)
	isolated(function()
		package.loaded.program_provider_picker = nil
		body(require("program_provider_picker"))
	end)
end

local function owner(options)
	options = options or {}
	local state = { discoveries = 0, resolutions = 0, invalidations = 0, retired = false }
	state.discover = function()
		state.discoveries = state.discoveries + 1
		if options.discover then return options.discover(state) end
		return { choices = { { key = "opaque-choice", label = "Reviewed provider" } } }
	end
	state.resolve = function(key, arguments)
		state.resolutions = state.resolutions + 1
		if options.resolve then return options.resolve(state, key, arguments) end
		if state.retired or key ~= "opaque-choice" then return nil end
		return SCALAR
	end
	state.invalidate = function()
		state.invalidations = state.invalidations + 1
		if options.invalidate then return options.invalidate(state) end
		state.retired = true
		return true
	end
	return state
end

helpers.describe("Program provider picker shared ownership", function()
	for _, mode in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("retains refused retirement until exact acknowledgement: " .. mode, function()
			shared(function(Picker)
				local released, creates = false, 0
				local first = owner({ invalidate = function(state)
					if released then state.retired = true; return true end
					if mode == "throw" then error("PRIVATE cleanup exception") end
					if mode == "nil" then return nil end
					return mode == "truthy" and 1 or false
				end })
				local adapter = { create = function() creates = creates + 1; return creates == 1 and first or owner() end }
				local initial = Picker.capture(adapter)
				Picker.close(initial)
				helpers.assert_eq(Picker.confirm(initial, "run_program", { providerKey = "opaque-choice" }), false)
				local blocked = Picker.capture(adapter)
				helpers.assert_eq(blocked.packet.unavailable, true)
				helpers.assert_eq(creates, 1, "cleanup debt must precede successor construction")
				local manual, value = Picker.confirm(blocked, "run_program", { parameter = SCALAR })
				helpers.assert_true(manual)
				helpers.assert_eq(value, SCALAR, "unavailable discovery retains the manual path")
				released = true
				local retry = Picker.capture(adapter)
				helpers.assert_eq(creates, 2)
				helpers.assert_true(first.retired)
				helpers.assert_eq(retry.packet.choices[1].key, "opaque-choice")
				Picker.close(retry)
			end)
		end)
	end
	for _, mode in ipairs({ "throw", "nil" }) do
		helpers.it("keeps failed-discovery cleanup debt before another factory: " .. mode, function()
			shared(function(Picker)
				local released, creates = false, 0
				local first = owner({ discover = function()
					if mode == "throw" then error("PRIVATE enumeration exception") end
					return nil
				end, invalidate = function() return released end })
				local adapter = { create = function() creates = creates + 1; return creates == 1 and first or owner() end }
				helpers.assert_eq(Picker.capture(adapter).packet.unavailable, true)
				helpers.assert_eq(Picker.capture(adapter).packet.unavailable, true)
				helpers.assert_eq(creates, 1)
				released = true
				local next_owner = Picker.capture(adapter)
				helpers.assert_eq(creates, 2)
				Picker.close(next_owner)
			end)
		end)
	end
	helpers.it("refuses an owner without its mandatory retirement port before discovery", function()
		shared(function(Picker)
			local broken = owner(); broken.invalidate = nil
			helpers.assert_eq(Picker.capture({ create = function() return broken end }).packet.unavailable, true)
			helpers.assert_eq(broken.discoveries, 0)
		end)
	end)
	for _, boundary in ipairs({ "factory", "discovery" }) do
		helpers.it("cannot construct an overlapping discovery owner during " .. boundary, function()
			shared(function(Picker)
				local nested, extra = nil, 0
				local function reenter()
					nested = Picker.capture({ create = function() extra = extra + 1; return owner() end })
				end
				local first = owner({ discover = function()
					if boundary == "discovery" then reenter() end
					return { choices = {} }
				end })
				local state = Picker.capture({ create = function()
					if boundary == "factory" then reenter() end
					return first
				end })
				helpers.assert_eq(extra, 0)
				helpers.assert_eq(nested.packet.unavailable, true)
				helpers.assert_eq(state.owner, first)
				Picker.close(state)
			end)
		end)
	end
	helpers.it("publishes retirement debt and revokes choices before native invalidation can reenter", function()
		shared(function(Picker)
			local state, nested, extra, old_admitted
			extra = 0
			local first = owner({ invalidate = function()
				old_admitted = Picker.confirm(state, "run_program", { providerKey = "opaque-choice" })
				nested = Picker.capture({ create = function() extra = extra + 1; return owner() end })
				return false
			end })
			state = Picker.capture({ create = function() return first end })
			helpers.assert_eq(Picker.close(state), false)
			helpers.assert_eq(old_admitted, false)
			helpers.assert_eq(extra, 0)
			helpers.assert_eq(nested.packet.unavailable, true)
			first.invalidate = function() return true end
			local recovered = Picker.capture({ create = function() extra = extra + 1; return owner() end })
			helpers.assert_eq(extra, 1)
			Picker.close(recovered)
		end)
	end)
end)

local function bridge_fixture(body)
	isolated(function()
		local f = { owners = {}, calls = {}, scripts = {}, visible = false, hide_refused = false }
		package.loaded.program_provider_picker = nil
		package.loaded["ui.action_picker.bridge"] = nil
		package.loaded["logger.shim"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["adapters.program_providers"] = { create = function()
			local state = owner(); f.owners[#f.owners + 1] = state; return state
		end }
		package.loaded["ui.webview_manager"] = {
			show = function() f.visible = true; return true end,
			hide = function() if f.hide_refused then return false end; f.visible = false; return true end,
			is_visible = function() return f.visible end,
			eval_js = function(_, script) f.scripts[#f.scripts + 1] = script; return true end,
		}
		f.bridge = require("ui.action_picker.bridge")
		function f.open(callback)
			return f.bridge.open({ items = {} }, callback or function(id, _, parameter)
				f.calls[#f.calls + 1] = { id, parameter }; return true
			end)
		end
		function f.confirm(extra)
			local message = extra or { action = "confirm", id = "run_program", providerKey = "opaque-choice", programArguments = {} }
			return f.bridge.on_message(message, {})
		end
		body(f)
	end)
end

helpers.describe("Production Linux program provider picker sessions", function()
	helpers.it("delivers the resolved scalar to the existing confirmation path then invalidates", function()
		bridge_fixture(function(f)
			helpers.assert_true(f.open())
			helpers.assert_eq(f.bridge.build_init_payload({ items = {} }).programProviders.choices[1].key, "opaque-choice")
			f.confirm()
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
			helpers.assert_true(f.owners[1].retired)
			helpers.assert_eq(f.bridge.is_open(), false)
		end)
	end)
	helpers.it("cannot deliver an old binding after resolver-driven picker replacement", function()
		bridge_fixture(function(f)
			local old, replacement = 0, 0
			helpers.assert_true(f.open(function() old = old + 1; return true end))
			f.owners[1].resolve = function()
				helpers.assert_true(f.open(function() replacement = replacement + 1; return true end))
				return SCALAR
			end
			f.confirm()
			helpers.assert_eq(old, 0)
			helpers.assert_eq(replacement, 0)
			helpers.assert_true(f.bridge.is_open())
			f.confirm()
			helpers.assert_eq(replacement, 1)
		end)
	end)
	helpers.it("contains recursive provider confirmation before durable callback delivery", function()
		bridge_fixture(function(f)
			helpers.assert_true(f.open())
			local resolutions = 0
			f.owners[1].resolve = function()
				resolutions = resolutions + 1
				if resolutions == 1 then f.confirm() end
				return SCALAR
			end
			f.confirm()
			helpers.assert_eq(resolutions, 1)
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	helpers.it("keeps the exact provider alive when native hide refuses", function()
		bridge_fixture(function(f)
			helpers.assert_true(f.open(function() return false end))
			f.hide_refused = true
			f.bridge.on_message({ action = "cancel" }, {})
			helpers.assert_eq(f.owners[1].invalidations, 0)
			helpers.assert_eq(f.open(), false)
			helpers.assert_eq(#f.owners, 1)
			f.hide_refused = false
			f.bridge.on_message({ action = "cancel" }, {})
			helpers.assert_true(f.owners[1].retired)
		end)
	end)
	for _, invalid in ipairs({ true, 0, "", "foreign-choice" }) do
		helpers.it("refuses malformed or foreign opaque choices without callback: " .. tostring(invalid), function()
			bridge_fixture(function(f)
				helpers.assert_true(f.open())
				f.confirm({ action = "confirm", id = "run_program", providerKey = invalid })
				helpers.assert_eq(#f.calls, 0)
				helpers.assert_true(f.bridge.is_open())
				helpers.assert_eq(f.scripts[#f.scripts], "programProviderRefused()")
			end)
		end)
	end
	helpers.it("keeps manual confirmation working when discovery is unavailable", function()
		bridge_fixture(function(f)
			package.loaded["adapters.program_providers"] = { create = function() return nil end }
			helpers.assert_true(f.open())
			f.confirm({ action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
		end)
	end)
end)

-- Actual Manager/bridge subjects below use faithful Gtk/WebKit boundary ports.
-- They prove Source receiving behavior in unit execution, not live desktop GTK.
local function contextual_native_fixture(body)
	isolated(function()
		for _, name in ipairs({ "ui.webview_manager", "ui.action_picker.bridge", "ui.webkit_host",
			"infra.i18n", "infra.locale", "locale.core", "window_titles", "webview.presentation",
			"program_provider_picker" }) do package.loaded[name] = nil end
		package.loaded["logger.shim"] = helpers.make_logger_stub()
		package.loaded["adapters.program_providers"] = {}
		package.loaded["adapters.event_loop"] = { add_idle_handler = function() end }
		local state = { creates = 0, windows = {}, scripts = {}, signals = {}, confirmations = 0 }
		local window_type = setmetatable({}, { __call = function(_, properties)
			state.creates = state.creates + 1
			local window = { properties = properties }
			function window:set_size_request() end
			function window:show_all() end
			function window:present() end
			function window:add() end
			function window:destroy() if self.on_destroy then self.on_destroy() end end
			state.windows[#state.windows + 1] = window
			return window
		end })
		package.loaded.lgi = {
			Gtk = { Window = window_type, WindowType = { TOPLEVEL = 1 }, WindowPosition = { CENTER = 1 } },
			GLib = {},
			GObject = {
				signal_handler_disconnect = function(_, id) state.signals[id] = nil end,
				signal_handler_is_connected = function(_, id) return state.signals[id] ~= nil end,
			},
			WebKit2 = {
				LoadEvent = { FINISHED = 1 },
				UserContentManager = function()
					local content = {}
					content.on_script_message_received = { connect = function(_, callback)
						local id = #state.signals + 1; state.signals[id] = callback; return id
					end }
					function content:register_script_message_handler(name)
						helpers.assert_eq(name, "action_picker_bridge"); return true
					end
					function content:unregister_script_message_handler(name)
						helpers.assert_eq(name, "action_picker_bridge")
					end
					return content
				end,
				WebView = function()
					local view = {}
					function view:load_html() end
					function view:run_javascript(script) state.scripts[#state.scripts + 1] = script end
					function view:destroy() if self.on_destroy then self.on_destroy() end end
					return view
				end,
			},
		}
		local locale = require("infra.locale")
		local i18n = require("infra.i18n")
		local core = require("locale.core")
		local original_get = core.get
		core.get = function(key)
			if state.translate_hook then state.translate_hook(key) end
			return original_get(key)
		end
		local manager = require("ui.webview_manager")
		manager.build_page_html = function()
			if state.html_hook then state.html_hook() end
			return "<html>inert boundary fixture</html>"
		end
		local picker = require("ui.action_picker.bridge")
		local titles = require("window_titles")
		function state.open(suffix, id)
			return picker.open({ presentation_id = id or "tap_hold_action", presentation_suffix = suffix,
				items = {}, current = "__native__", allow_native = true, native_label = "original native label" }, function()
				state.confirmations = state.confirmations + 1; return true
			end)
		end
		local ok, failure = xpcall(function() body(state, manager, picker, locale, titles, i18n) end, debug.traceback)
		state.translate_hook, state.html_hook = nil, nil
		local clean_ok, clean = pcall(manager.shutdown)
		if not ok then error(failure, 0) end
		helpers.assert_eq(clean_ok and clean == true, true, "Exact fixture native lifecycle cleanup acknowledged")
	end)
end

local contextual_file = assert(io.open(helpers.driver_root() .. "/../macos/tests/fixtures/contextual_picker_original_prefixes.json", "rb"))
local contextual_original = assert(require("json").decode(contextual_file:read("*a")))
contextual_file:close()
helpers.describe("declared Linux tap action page-title receiving", function()
	for code, expected in pairs(contextual_original.locales) do
		for _, suffix in ipairs(contextual_original.suffix_cases) do
			helpers.it("keeps original page prefix and generic native caption in " .. code .. ": " .. suffix, function()
				contextual_native_fixture(function(state, _, picker, locale)
					locale.set_locale(code)
					helpers.assert_true(state.open(suffix))
					helpers.assert_eq(state.creates, 1)
					helpers.assert_eq(state.windows[1].properties.title, expected.linux_native_caption)
					local page = picker.build_init_payload(picker.pending_opts)
					helpers.assert_eq(page.title, expected.linux_prefix .. suffix)
					helpers.assert_eq(page.label, expected.picker_label)
					helpers.assert_eq(page.current, "__native__")
					helpers.assert_eq(page.allowNative, true)
					helpers.assert_eq(page.nativeLabel, "original native label")
					helpers.assert_eq(state.confirmations, 0, "Title receipt grants no action or Writer effect")
					picker.on_message({ action = "ready" }, {})
					helpers.assert_eq(#state.scripts, 1)
					local pushed = assert(require("json").decode(state.scripts[1]:match("^init%((.*)%)$")))
					helpers.assert_eq(pushed.title, expected.linux_prefix .. suffix)
				end)
			end)
		end
	end
	for _, suffix in ipairs({ "", "bad\nline", "bad\tline", string.rep("x", 1025), true, {}, 1 }) do
		helpers.it("refuses invalid Linux title suffix before allocation: " .. type(suffix) .. tostring(suffix), function()
			contextual_native_fixture(function(state)
				helpers.assert_eq(state.open(suffix), false); helpers.assert_eq(state.creates, 0)
				helpers.assert_true(state.open("K1")); helpers.assert_eq(state.creates, 1)
			end)
		end)
	end
	helpers.it("refuses the Mac context and forged native receiving receipt then repairs", function()
		contextual_native_fixture(function(state, manager)
			helpers.assert_eq(state.open("K1", "keyboard_slot_action"), false)
			helpers.assert_eq(manager.show("action_picker", nil, {}), false)
			helpers.assert_eq(state.creates, 0)
			helpers.assert_true(state.open("K1")); helpers.assert_eq(state.creates, 1)
		end)
	end)
	for _, boundary in ipairs({ "page HTML", "generic native caption" }) do
		helpers.it("retains title declaration custody across " .. boundary .. " then exact repair", function()
			contextual_native_fixture(function(state, _, _, _, titles)
				local original, observed = titles.presentation_for_app, 0
				local function withdraw()
					titles.presentation_for_app = function() observed = observed + 1; return nil end
				end
				if boundary == "page HTML" then state.html_hook = withdraw else
					state.translate_hook = function(key) if key == "dialog.action_picker.label" then withdraw() end end
				end
				local ok, failure = pcall(function()
					helpers.assert_eq(state.open("K1"), false)
					helpers.assert_eq(state.creates, 0); helpers.assert_eq(observed, 0)
				end)
				state.html_hook, state.translate_hook = nil, nil; titles.presentation_for_app = original
				if not ok then error(failure, 0) end
				helpers.assert_true(state.open("K1")); helpers.assert_eq(state.creates, 1)
			end)
		end)
	end
	helpers.it("withdraws held page-title dependency before init without foreign lookup or page push", function()
		contextual_native_fixture(function(state, _, picker, _, titles)
			helpers.assert_true(state.open("K1"))
			local original, observed = titles.presentation_for_app, 0
			titles.presentation_for_app = function() observed = observed + 1; return nil end
			local ok, failure = pcall(function()
				helpers.assert_eq(picker.on_message({ action = "ready" }, {}), nil)
				helpers.assert_eq(#state.scripts, 0); helpers.assert_eq(observed, 0)
			end)
			titles.presentation_for_app = original
			if not ok then error(failure, 0) end
			picker.on_message({ action = "ready" }, {})
			helpers.assert_eq(#state.scripts, 1)
		end)
	end)
end)
