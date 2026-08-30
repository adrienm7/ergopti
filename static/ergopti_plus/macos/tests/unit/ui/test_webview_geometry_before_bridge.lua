--- tests/unit/ui/test_webview_geometry_before_bridge.lua
--- HS-081 regression coverage.

--- ==============================================================================
--- MODULE: Webview Geometry-Before-Bridge Regression Tests
--- DESCRIPTION:
--- Drives the real hotstring editor hosts and proves a native usercontent
--- controller is acquired only after geometry validation. A webview factory
--- refusal must also release the exact callback before a later retry.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================
-- =====================================
-- ======= 1/ Behavioral Harness =======
-- =====================================
-- =====================================

local COMMON_STUBS = {
	["infra.logger"] = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function() end,
	},
	["infra.i18n"] = { get = function(key) return key end },
	["infra.paths"] = { shared = function() return "/controlled/assets" end },
	["infra.toml.reader"] = {},
	["infra.toml.writer"] = {},
	["infra.notifications"] = {},
	["chord"] = {},
	["adapters.hotkey_registrar"] = {},
	["adapters.file_system"] = {},
	["infra.deferred_work"] = {},
	["modules.hotstrings.hotstrings_config"] = {},
	["modules.hotstrings.hotstrings_config_schema"] = {},
	["infra.toml.record_editor"] = {},
}

local SUBJECTS = {
	{
		label = "hotstring editor",
		module_name = "ui.hotstring_editor",
		geometry_name = "hotstring_editor",
		bridge_name = "hsEditor",
		open = function(subject) subject.open("menu") end,
	},
	{
		label = "hotstrings config window",
		module_name = "ui.hotstrings_config_window",
		geometry_name = "hotstrings_config_window",
		bridge_name = "hotstrings_config_bridge",
		open = function(subject) subject.open() end,
	},
}

--- Runs one subject against observable native boundaries.
--- @param spec table Subject description.
--- @param callback function Test body receiving subject, state and controls.
local function with_subject(spec, callback)
	local module_names = { spec.module_name, "ui.ui_builder", "hs", "tests.stubs.hs" }
	for module_name in pairs(COMMON_STUBS) do module_names[#module_names + 1] = module_name end
	table.sort(module_names)
	helpers.with_fresh_modules(module_names, function()
		local saved_hs = _G.hs
		local state = {
			bridges = {},
			callbacks = 0,
			releases = 0,
			geometry_calls = 0,
			show_calls = 0,
			focus_calls = 0,
			deletes = 0,
		}
		local controls = {
			delete_throws = false,
			fire_on_close_during_delete = false,
			geometry = nil,
			show = true,
		}
		for module_name, stub in pairs(COMMON_STUBS) do package.loaded[module_name] = stub end
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function(name)
				helpers.assert_eq(name, spec.geometry_name,
					"the host must request its own manifest geometry")
				state.geometry_calls = state.geometry_calls + 1
				return controls.geometry
			end,
			get_centered_frame = function(width, height)
				return { w = width, h = height }
			end,
			show_webview = function(opts)
				state.show_calls = state.show_calls + 1
				state.last_opts = opts
				if controls.show ~= true then return nil end
				local view = {
					deleted = false,
					delete = function(self)
						state.deletes = state.deletes + 1
						if controls.fire_on_close_during_delete then opts.on_close() end
						if controls.delete_throws then error("synthetic editor delete refusal") end
						self.deleted = true
					end,
					evaluateJavaScript = function() end,
				}
				state.last_view = view
				return view
			end,
			force_focus = function() state.focus_calls = state.focus_calls + 1 end,
		}

		local ok, err = xpcall(function()
			package.loaded["tests.stubs.hs"] = nil
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			hs_stub.webview.windowMasks = {
				titled = 1,
				closable = 2,
				resizable = 8,
				miniaturizable = 4,
			}
			hs_stub.webview.usercontent.new = function(name)
				helpers.assert_eq(name, spec.bridge_name,
					"the host must acquire its canonical bridge")
				local bridge = {}
				function bridge:setCallback(installed)
					if installed == nil then
						state.releases = state.releases + 1
					else
						state.callbacks = state.callbacks + 1
					end
				end
				state.bridges[#state.bridges + 1] = bridge
				return bridge
			end
			_G.hs = hs_stub
			package.loaded.hs = hs_stub
			local subject = require(spec.module_name)
			callback(subject, state, controls)
		end, debug.traceback)
		_G.hs = saved_hs
		if not ok then error(err, 0) end
	end)
end





-- ==========================================
-- ==========================================
-- ======= 2/ Fail-Fast Geometry Gate =======
-- ==========================================
-- ==========================================

helpers.describe("webview hosts validate geometry before bridge acquisition", function()
	for _, spec in ipairs(SUBJECTS) do
		helpers.it(spec.label .. " allocates nothing across failed geometry retries", function()
			with_subject(spec, function(subject, state, controls)
				spec.open(subject)
				spec.open(subject)

				helpers.assert_eq(state.geometry_calls, 2,
					"each retry must revalidate the manifest geometry")
				helpers.assert_eq(#state.bridges, 0,
					"invalid geometry must not allocate a native controller")
				helpers.assert_eq(state.callbacks, 0,
					"invalid geometry must not register a message callback")
				helpers.assert_eq(state.show_calls, 0,
					"invalid geometry must not reach the webview factory")

				controls.geometry = { width = 720, height = 540 }
				spec.open(subject)
				helpers.assert_eq(#state.bridges, 1,
					"the first valid retry must allocate one fresh controller")
				helpers.assert_eq(state.callbacks, 1,
					"the valid controller must receive one callback")
				helpers.assert_eq(state.show_calls, 1,
					"the valid retry must create one webview")
				helpers.assert_true(state.last_opts.usercontent == state.bridges[1],
					"the webview must receive the exact staged controller")

				spec.open(subject)
				helpers.assert_eq(#state.bridges, 1,
					"the singleton retry must not allocate a second controller")
				helpers.assert_eq(state.focus_calls, 1,
					"the singleton retry must focus the committed webview")

				state.last_opts.on_close()
				helpers.assert_eq(state.releases, 1,
					"a native window close must release the committed callback")
				spec.open(subject)
				helpers.assert_eq(#state.bridges, 2,
					"opening after a native close must attach one fresh controller")
				subject.close()
				helpers.assert_eq(state.releases, 2,
					"explicit close must release the replacement controller callback")
			end)
		end)
	end
end)





-- ==============================================
-- ==============================================
-- ======= 4/ Hotstring Close Transaction =======
-- ==============================================
-- ==============================================

helpers.describe("hotstring editor retains refused native closes", function()
	helpers.it("keeps the exact webview and bridge retryable", function()
		with_subject(SUBJECTS[1], function(subject, state, controls)
			controls.geometry = {width = 720, height = 540}
			SUBJECTS[1].open(subject)
			local owned = state.last_view
			controls.fire_on_close_during_delete = true
			controls.delete_throws = true

			helpers.assert_eq(subject.close(), false,
				"a throwing native delete must refuse the logical close")
			helpers.assert_true(subject.is_open(),
				"the exact editor must remain owned after native refusal")
			helpers.assert_eq(state.releases, 0,
				"a synchronous on_close must not release the live bridge before commitment")
			SUBJECTS[1].open(subject)
			helpers.assert_eq(state.show_calls, 1,
				"a refused close must not create a second editor")
			helpers.assert_eq(state.focus_calls, 1,
				"the retained editor must remain the singleton focus target")

			controls.delete_throws = false
			helpers.assert_true(subject.close(),
				"the exact retained editor must remain retryable")
			helpers.assert_true(owned.deleted)
			helpers.assert_eq(state.releases, 1,
				"the bridge must release only after native deletion commits")
			helpers.assert_eq(subject.is_open(), false)
		end)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 3/ Factory Refusal Cleanup ========
-- ===========================================
-- ===========================================

helpers.describe("webview hosts release staged bridges after factory refusal", function()
	for _, spec in ipairs(SUBJECTS) do
		helpers.it(spec.label .. " retries only after releasing the exact callback", function()
			with_subject(spec, function(subject, state, controls)
				controls.geometry = { width = 720, height = 540 }
				controls.show = false
				spec.open(subject)
				spec.open(subject)

				helpers.assert_eq(#state.bridges, 2,
					"each refused factory attempt must stage one fresh controller")
				helpers.assert_eq(state.callbacks, 2,
					"each staged controller must be wired once")
				helpers.assert_eq(state.releases, 2,
					"each refused controller callback must be released immediately")

				controls.show = true
				spec.open(subject)
				helpers.assert_eq(#state.bridges, 3,
					"a later success must attach only a fresh controller")
				helpers.assert_true(state.last_opts.usercontent == state.bridges[3],
					"the successful webview must not reuse a refused controller")
				subject.close()
				helpers.assert_eq(state.releases, 3,
					"the committed controller must release on close")
			end)
		end)
	end
end)
