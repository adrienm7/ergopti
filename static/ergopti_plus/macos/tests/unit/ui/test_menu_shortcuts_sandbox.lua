--- tests/unit/ui/test_menu_shortcuts_sandbox.lua

--- ==============================================================================
--- MODULE: Extension Shortcut Menu Sandbox Regression
--- DESCRIPTION:
--- Executes the real extension-list provider under Lua 5.4. Extension chunks
--- must receive their sandbox through loadfile's environment argument, retain
--- access to standard builtins, and never publish globals into the host.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==========================================
-- ==========================================
-- ======= 1/ Lua 5.4 Sandbox Loading =======
-- ==========================================
-- ==========================================

helpers.describe("menu_shortcuts: extension sandbox uses the Lua 5.4 load contract", function()
	helpers.it("collects extension rows without setfenv or host-global pollution", function()
		local saved_hs = rawget(_G, "hs")
		local saved_loadfile = rawget(_G, "loadfile")
		local saved_pollution = rawget(_G, "hs152_extension_pollution")
		local load_calls = {}
		local ok, err = xpcall(function()
			helpers.with_fresh_modules({
				"ui.menu.menu_shortcuts",
				"infra.logger",
				"infra.deferred_work",
				"infra.fs_dir",
				"infra.dialog_util",
				"modules.shortcuts",
				"modules.shortcuts.actions.text",
				"infra.i18n",
				"ui.menu.menu_utils",
				"infra.manifest_menu",
				"ui.menu.shortcut_utils",
				"ui.menu.menu_keyboard_slots",
				"infra.manifest_reader",
				"hs",
				"tests.stubs.hs",
			}, function()
				local hs_stub = require("tests.stubs.hs")
				hs_stub.__reset()
				hs_stub.fs.attributes = function(path)
					if path:match("/extensions/$") then return { mode = "directory" } end
					if path:match("/extensions/demo$") then return { mode = "directory" } end
					if path:match("/extensions/demo/shortcuts/menu%.lua$") then
						return { mode = "file" }
					end
					return nil
				end
				_G.hs = hs_stub
				package.loaded["hs"] = hs_stub
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["infra.deferred_work"] = {
					after = function() return true end,
				}
				package.loaded["infra.fs_dir"] = {
					entries = function() return { "demo" } end,
				}
				package.loaded["infra.dialog_util"] = {}
				package.loaded["modules.shortcuts"] = {
					DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
				}
				package.loaded["modules.shortcuts.actions.text"] = {
					WRAP_GROUPS = {},
					build_active_wrap_pairs = function() return {} end,
				}
				package.loaded["infra.i18n"] = {
					get = function(key) return key end,
					section = function(key) return key end,
					decorate_section = function(value) return value end,
				}
				package.loaded["ui.menu.menu_utils"] = {
					as_provider_row = function(item)
						return { label = item.title, items = item.menu }
					end,
				}
				package.loaded["infra.manifest_menu"] = {
					build = function(_, _, _, _, _, providers)
						return providers.extensions_shortcuts()
					end,
				}
				package.loaded["ui.menu.shortcut_utils"] = {}
				package.loaded["ui.menu.menu_keyboard_slots"] = {
					provide_rows = function() return {} end,
				}
				package.loaded["infra.manifest_reader"] = {
					default_for = function() return "star" end,
				}

				_G.hs152_extension_pollution = nil
				_G.loadfile = function(path, mode, environment)
					load_calls[#load_calls + 1] = {
						path = path,
						mode = mode,
						environment = environment,
					}
					return load([[
						_G.hs152_extension_pollution = "sandbox-only"
						add_item({
							label = string.upper(ext_name),
							proof = table.concat({ tostring(1), tostring(2) }, ":"),
						})
					]], "@fixture-extension-menu", mode, environment)
				end

				local MenuShortcuts = require("ui.menu.menu_shortcuts")
				local item = MenuShortcuts.build({
					base_dir = "/fixture/driver/",
					shortcuts = {
						list_shortcuts = function() return {} end,
						resume_bindings = function() return true end,
						pause_bindings = function() return true end,
					},
					state = {
						shortcuts = true,
						chatgpt_url = "https://example.test",
						wrap_symbol_states = {},
						custom_wrap_symbols = {},
					},
					paused = false,
					applyTriggerChar = function(value) return value end,
					save_prefs = function() return true end,
					notify_feature = function() end,
					updateMenu = function() end,
					commands = {},
					state_getters = {},
				})

				helpers.assert_eq(#load_calls, 1)
				helpers.assert_true(load_calls[1].path:match("/extensions/demo/shortcuts/menu%.lua$") ~= nil)
				helpers.assert_eq(load_calls[1].mode, "t")
				helpers.assert_type(load_calls[1].environment, "table")
				helpers.assert_eq(#item.submenu, 3)
				helpers.assert_eq(item.submenu[3].label, "demo")
				helpers.assert_eq(item.submenu[3].items[1].label, "DEMO")
				helpers.assert_eq(item.submenu[3].items[1].proof, "1:2")
				helpers.assert_eq(_G.hs152_extension_pollution, nil,
					"the extension chunk must not publish globals into the host")
			end)
		end, debug.traceback)
		_G.hs = saved_hs
		_G.loadfile = saved_loadfile
		_G.hs152_extension_pollution = saved_pollution
		if not ok then error(err, 0) end
	end)
end)
