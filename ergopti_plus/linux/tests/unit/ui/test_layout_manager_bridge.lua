--- tests/unit/ui/test_layout_manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (Linux)
--- DESCRIPTION:
--- The Linux host of the layout manager page wires the shared controller
--- (_shared/lua/layouts/manager_bridge.lua) to the WebKitGTK window, the Linux
--- registry client and xdg-open (layout-manager-bridge). These tests inject
--- each authority and pin the wiring: pushes reach the layout_manager window as
--- window.<function>(<json>), the strings are the ones strings.json declares,
--- a homepage opens through a quoted xdg-open, and close hides the window.
--- ==============================================================================

local helpers = require("tests.helpers")

local INDEX = { layouts = { { id = "ergol", name = "Ergo-L", homepage = "https://ergol.org" } } }

--- The bridge with every authority injected.
--- @return table bridge, table state, table daemon_state
local function bridge()
	local Bridge = helpers.load_module("ui.layout_manager.bridge")
	Bridge._reset()
	local state = { pushes = {}, hidden = {}, commands = {}, calls = {} }
	local daemon_state = {
		webview_manager = {
			eval_js = function(app, js) state.pushes[#state.pushes + 1] = { app = app, js = js }; return true end,
			hide = function(app) state.hidden[#state.hidden + 1] = app; return true end,
		},
		shell = {
			has_command = function(name) return name == "xdg-open" end,
			quote = function(value) return "'" .. value .. "'" end,
			run = function(command) state.commands[#state.commands + 1] = command; return true end,
		},
		i18n = { get = function(key) return "translated:" .. key end },
		layout_registry = {
			snapshot = function() return { platform = "linux", index = INDEX, installed = {}, source = "cache" } end,
			refresh = function(on_done) state.calls[#state.calls + 1] = "refresh"; on_done({}) end,
			install = function(id, on_done) state.calls[#state.calls + 1] = "install " .. id; on_done(true, {}) end,
			uninstall = function() end,
			select = function() end,
		},
	}
	return Bridge, state, daemon_state
end

helpers.describe("layout manager bridge (Linux)", function()
	helpers.it("pushes the page state into the layout_manager window (layout-manager-bridge)", function()
		local Bridge, state, daemon_state = bridge()
		helpers.assert_eq(Bridge.bridge_name, "layout_manager_bridge")
		local result = Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(result.handled)
		helpers.assert_eq(state.pushes[1].app, "layout_manager")
		helpers.assert_contains(state.pushes[1].js, "window.initData(")
		helpers.assert_contains(state.pushes[1].js, '"layout_manager.window_title":"translated:layout_manager.window_title"')
		helpers.assert_contains(state.pushes[1].js, '"platform":"linux"')
		helpers.assert_contains(state.pushes[2].js, "window.updateState(")
		helpers.assert_eq(state.calls[1], "refresh")
	end)

	helpers.it("opens the catalogue homepage through xdg-open and hides on close (layout-manager-bridge)", function()
		local Bridge, state, daemon_state = bridge()
		helpers.assert_true(Bridge.on_message({ action = "open_homepage", id = "ergol" }, daemon_state).handled)
		helpers.assert_eq(state.commands[1], "xdg-open 'https://ergol.org' >/dev/null 2>&1 &")
		helpers.assert_true(Bridge.on_message({ action = "close" }, daemon_state).handled)
		helpers.assert_eq(state.hidden[1], "layout_manager")
		helpers.assert_true(Bridge.on_message({ action = "shell", id = "ergol" }, daemon_state).handled == false,
			"an action outside the allowlist is refused")
	end)
end)

--- Captures actual provider data while forwarding its status and rendering to the real binding.
--- @param callback function Receives the native build, fixture state and binding.
local function with_empty_layout(callback)
	local names = { "ui.menu.menu_builder", "infra.manifest_menu", "infra.i18n", "modules.keymap.layout_registry" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local ok, err = xpcall(function()
		local state = { selections = 0, installed = false }
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function()
				return { installed = state.installed and { { id = "native", name = "Native layout" } } or {}, active = "native" }
			end,
			select = function() state.selections = state.selections + 1; return true end,
		}
		local binding = require("infra.manifest_menu")
		local module = helpers.load_module("ui.menu.menu_builder")
		local native_build = binding.build
		binding.build = function(key, title, dynamic, click, ctx, providers)
			if key == "layout_menu" then
				local provider = providers.custom_layouts
				providers.custom_layouts = function()
					state.data = provider()
					return state.data
				end
			end
			return native_build(key, title, dynamic, click, ctx, providers)
		end
		callback(function()
			local items = module.build({})
			for _, row in ipairs(items) do
				if row.title == require("infra.i18n").get("menu.layout.title") then
					helpers.assert_eq(type(row.menu), "table")
					return row.menu
				end
			end
			error("The actual layout submenu must reach the tray.")
		end, state, binding)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

-- Independent pre-migration captions; the generated status declaration is the subject.
local EmptyLayoutJson = require("json")
local function read_empty_layout_json(path)
	local file = assert(io.open(path, "rb"))
	local value = assert(EmptyLayoutJson.decode(file:read("*a")))
	file:close()
	return value
end

local EmptyLayoutCorpus = read_empty_layout_json(require("infra.paths").shared("tests/corpus/menu/layout_empty_status.json"))

local function empty_layout_owner(binding)
	for _, row in ipairs(binding.get_array(EmptyLayoutCorpus.section)) do
		if row.id == EmptyLayoutCorpus.provider then return row end
	end
	error("The actual custom-layout provider declaration must exist.")
end

local function count_empty_layout_caption(rows, title)
	local count = 0
	for _, row in ipairs(rows or {}) do
		if row.title == title then
			count = count + 1
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
		end
	end
	return count
end

helpers.describe("the shared empty native-layout status", function()
	helpers.it("(layout-empty-status) retains the independent inert declaration", function()
		with_empty_layout(function(_, state, binding)
			helpers.assert_eq(empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status], { EmptyLayoutCorpus.row })
			local count = 0
			for _ in pairs(EmptyLayoutCorpus.captions) do count = count + 1 end
			helpers.assert_eq(count, 21)
			helpers.assert_eq(state.selections, 0)
		end)
	end)

	for locale, expected in pairs(EmptyLayoutCorpus.captions) do
		helpers.it("(layout-empty-status) renders the real empty provider in " .. locale, function()
			with_empty_layout(function(build, state, binding)
				local catalogue = read_empty_layout_json(require("infra.paths").shared("data/locales/" .. locale .. ".json"))
				helpers.assert_eq(catalogue[EmptyLayoutCorpus.row.i18n], expected)
				require("infra.i18n").get = function(key) return catalogue[key] or key end
				local rows = build()
				helpers.assert_eq(state.data, { { label = expected, disabled = true } })
				helpers.assert_eq(count_empty_layout_caption(rows, expected), 1)
				helpers.assert_eq(state.selections, 0)
				local declaration = empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status][1]
				declaration.i18n = "menu.layout.manage"
				build()
				helpers.assert_eq(state.data, { { label = catalogue["menu.layout.manage"], disabled = true } },
					"The native provider consumes the live declaration, not a repeated native caption.")
			end)
		end)
	end

	for _, invalid in ipairs({ "missing", "empty", "command", "effectful_label" }) do
		helpers.it("(layout-empty-status) refuses the empty caption after " .. invalid, function()
			with_empty_layout(function(build, state, binding)
				local statuses = empty_layout_owner(binding).status_rows
				local baseline = build()
				local caption = require("infra.i18n").get(EmptyLayoutCorpus.row.i18n)
				helpers.assert_eq(count_empty_layout_caption(baseline, caption), 1)
				local bad = {
					empty = {}, command = { { type = "command", id = "layout_manager", i18n = "menu.layout.manage" } },
					effectful_label = { { type = "label", i18n = EmptyLayoutCorpus.row.i18n, action = "layout_manager" } },
				}
				statuses[EmptyLayoutCorpus.status] = bad[invalid]
				local rows = build()
				helpers.assert_eq(state.data, {})
				helpers.assert_eq(count_empty_layout_caption(rows, caption), 0)
				helpers.assert_eq(state.selections, 0)
			end)
		end)
	end

	helpers.it("(layout-empty-status) refuses an unavailable status-renderer port", function()
		with_empty_layout(function(build, state, binding)
			build()
			helpers.assert_eq(#state.data, 1)
			binding.status_rows = nil
			build()
			helpers.assert_eq(state.data, {})
			helpers.assert_eq(state.selections, 0)
		end)
	end)

	helpers.it("(layout-empty-status) leaves installed native layout data actionable", function()
		with_empty_layout(function(build, state, binding)
			state.installed = true
			empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status] = nil
			build()
			helpers.assert_eq(#state.data, 1)
			helpers.assert_eq(state.data[1].label, "Native layout")
			helpers.assert_eq(state.data[1].checked, true)
			helpers.assert_eq(type(state.data[1].action), "function")
			helpers.assert_true(state.data[1].disabled ~= true)
			helpers.assert_eq(state.selections, 0)
		end)
	end)
end)
