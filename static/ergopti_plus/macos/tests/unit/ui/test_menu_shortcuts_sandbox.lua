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
				"menu.renderer",
				"adapters.json_codec",
				"ui.menu.shortcut_utils",
				"ui.menu.menu_keyboard_slots",
				"ui.menu.menu_tap_keys",
				"infra.manifest_reader",
				"hs",
				"tests.stubs.hs",
			}, function()
				local hs_stub = require("tests.stubs.hs")
				hs_stub.__reset()
				hs_stub.fs.attributes = function(path)
					if path:match("/extensions/$") then return { mode = "directory" } end
					if path:match("/extensions/demo$") then return { mode = "directory" } end
					if path:match("/shortcuts/menu%.lua$") then
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
				local extension_renderer = assert(require("menu.renderer").new({
					platform = "hs",
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = require("adapters.json_codec").decode,
					i18n = package.loaded["infra.i18n"],
					logger = package.loaded["infra.logger"],
				}))
				package.loaded["infra.manifest_menu"] = {
					template_rows = extension_renderer.template_rows,
					build = function(_, _, _, _, _, providers)
						return providers.extensions_shortcuts()
					end,
				}
				package.loaded["ui.menu.shortcut_utils"] = {}
				package.loaded["ui.menu.menu_keyboard_slots"] = {
					provide_rows = function() return {} end,
				}
				package.loaded["ui.menu.menu_tap_keys"] = {
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
					-- The boot catalogue owns which extensions exist; the menu walks no folder.
					extension_packs = {
						{ id = "demo", name = "demo", dir = "/fixture/extensions/demo" },
						-- A layout installed through the manager: its generation is no
						-- child of the bundled folder the menu used to walk.
						{ id = "ergol", name = "Ergo-L", dir = "/config/layouts/extensions/ergol/0123/ergol" },
					},
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

				helpers.assert_eq(#load_calls, 2)
				helpers.assert_true(load_calls[1].path:match("/extensions/demo/shortcuts/menu%.lua$") ~= nil)
				helpers.assert_eq(load_calls[2].path, "/config/layouts/extensions/ergol/0123/ergol/shortcuts/menu.lua",
					"an installed layout's shortcuts come from its committed generation")
				helpers.assert_eq(load_calls[1].mode, "t")
				helpers.assert_type(load_calls[1].environment, "table")
				helpers.assert_eq(#item.submenu, 4)
				helpers.assert_eq(item.submenu[3].label, "demo")
				helpers.assert_eq(item.submenu[3].items[1].label, "DEMO")
				helpers.assert_eq(item.submenu[3].items[1].proof, "1:2")
				helpers.assert_eq(item.submenu[4].label, "Ergo-L", "the shared manifest name labels the row")
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


--- Isolates the actual extension allocator, locale cohort and shared renderer.
--- The build port selects the genuine provider; it never constructs its rows.
--- @param callback function Native provider and initialized owner assertions.
local function with_extension_boundary(callback)
	local names = {
		"ui.menu.menu_shortcuts", "infra.logger", "infra.deferred_work", "infra.fs_dir",
		"infra.dialog_util", "modules.shortcuts", "modules.shortcuts.actions.text",
		"infra.i18n", "infra.locale", "locale.core", "infra.paths", "adapters.json_codec",
		"adapters.storage", "adapters.timer_scheduler", "menu.renderer", "ui.menu.menu_utils",
		"infra.manifest_menu", "ui.menu.shortcut_utils", "ui.menu.menu_keyboard_slots",
		"ui.menu.menu_tap_keys", "infra.manifest_reader", "hs", "tests.stubs.hs",
	}
	local saved_hs, saved_pollution = rawget(_G, "hs"), rawget(_G, "extension_boundary_pollution")
	local root = os.tmpname()
	os.remove(root)
	local packs = {}
	local ok, detail = xpcall(function()
		helpers.with_fresh_modules(names, function()
			local native_hs = require("tests.stubs.hs")
			native_hs.__reset()
			_G.hs, package.loaded["hs"] = native_hs, native_hs
			native_hs.fs.mkdir(root)
			for _, id in ipairs({ "first", "second" }) do
				local dir = root .. "/" .. id
				native_hs.fs.mkdir(dir)
				native_hs.fs.mkdir(dir .. "/shortcuts")
				local file = assert(io.open(dir .. "/shortcuts/menu.lua", "w"))
				file:write([[
					_G.extension_boundary_pollution = "sandbox-only"
					hs.extension_boundary.loads = hs.extension_boundary.loads + 1
					add_item({ title = string.upper(ext_name), fn = function()
						hs.extension_boundary.actions[#hs.extension_boundary.actions + 1] = ext_name
						return hs.extension_boundary.accept
					end })
					add_item({ title = "-" })
					add_item({ title = t("button.cancel"), fn = function() return false end })
				]])
				file:close()
				packs[#packs + 1] = { id = id, name = id, dir = dir }
			end
			native_hs.extension_boundary = { loads = 0, actions = {}, accept = false }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.deferred_work"] = { after = function() return true end }
			package.loaded["infra.fs_dir"] = { entries = function() return {} end }
			package.loaded["infra.dialog_util"] = {}
			package.loaded["modules.shortcuts"] = { DEFAULT_STATE = { shortcuts = true, chatgpt_url = "https://example.test" } }
			package.loaded["modules.shortcuts.actions.text"] = { WRAP_GROUPS = {}, build_active_wrap_pairs = function() return {} end }
			package.loaded["ui.menu.shortcut_utils"] = {}
			package.loaded["ui.menu.menu_keyboard_slots"] = { provide_rows = function() return {} end }
			package.loaded["ui.menu.menu_tap_keys"] = { provide_rows = function() return {} end }
			package.loaded["infra.manifest_reader"] = { default_for = function() return "star" end }
			local native_i18n = require("infra.i18n")
			local locale = require("infra.locale")
			native_i18n.set_locale_injector(function(code) locale.set_locale(code) end)
			native_i18n.init()
			local locale_owner = { pending = function() return false end }
			assert(native_i18n.scope_acquire(locale_owner))
			local locale_receipt = assert(native_i18n.scope_capture(locale_owner))
			assert(native_i18n.scope_apply(locale_owner, locale_receipt, "en"))
			assert(native_i18n.scope_release(locale_owner))
			assert(native_i18n.scope_forget(locale_owner, locale_receipt))
			local renderer = require("infra.manifest_menu")
			local file = assert(io.open(helpers.shared("tests/corpus/menus/shortcut_extension_boundary.json"), "r"))
			local raw = file:read("*a"); file:close()
			local expected = assert(require("adapters.json_codec").decode(raw))
			package.loaded["infra.manifest_menu"] = {
				template_rows = renderer.template_rows,
				build = function(_, _, _, _, _, providers) return providers.extensions_shortcuts() end,
			}
			local native = require("ui.menu.menu_shortcuts")
			local state = { shortcuts = true, chatgpt_url = "https://example.test", wrap_symbol_states = {}, custom_wrap_symbols = {} }
			local context = {
				base_dir = helpers.driver_root(), extension_packs = packs,
				shortcuts = { list_shortcuts = function() return {} end,
					resume_bindings = function() return true end, pause_bindings = function() return true end },
				state = state, paused = false, applyTriggerChar = function(value) return value end,
				save_prefs = function() error("extension presentation must not persist configuration") end,
				notify_feature = function() error("extension presentation must not notify a state change") end,
				updateMenu = function() error("extension presentation must not request a rebuild") end,
				commands = {}, state_getters = {},
			}
			local function rows() return native.build(context).submenu end
			_G.extension_boundary_pollution = nil
			callback(rows, renderer, expected, context, native_hs.extension_boundary, native_i18n)
		end)
	end, debug.traceback)
	for _, pack in ipairs(packs) do
		os.remove(pack.dir .. "/shortcuts/menu.lua")
		os.remove(pack.dir .. "/shortcuts")
		os.remove(pack.dir)
	end
	os.remove(root)
	_G.hs, _G.extension_boundary_pollution = saved_hs, saved_pollution
	if not ok then error(detail, 0) end
end

helpers.describe("Shortcut extension presentation boundary", function()
	helpers.it("the actual nonempty allocator consumes its declaration and retains sandbox callbacks (extension-boundary)", function()
		with_extension_boundary(function(rows, renderer, expected, context, effects, native_i18n)
			local frame = renderer.get_array(expected.section)
			local original = frame[2]
			local ok, detail = xpcall(function()
				local actual = rows()
				helpers.assert_eq(#actual, 4)
				helpers.assert_eq(actual[1], expected.projections.hs[1])
				helpers.assert_eq(actual[2], expected.projections.hs[2])
				helpers.assert_nil(actual[2].action)
				helpers.assert_eq(actual[3].label, "first")
				helpers.assert_eq(actual[4].label, "second")
				helpers.assert_eq(actual[3].items[1].label, "FIRST")
				helpers.assert_eq(actual[3].items[2], { separator = true })
				helpers.assert_eq(actual[3].items[3].label, "Cancel")
				helpers.assert_eq(effects.loads, 2)
				helpers.assert_nil(_G.extension_boundary_pollution)
				helpers.assert_eq(actual[3].items[1].action(), false)
				helpers.assert_eq(effects.actions, { "first" })
				frame[2] = { type = "section_header", id = expected.heading_id,
					i18n = expected.published_marker_key, platforms = { "ahk", "hs" }, unavailable = "hide" }
				actual = rows()
				helpers.assert_eq(actual[2].label, expected.en_marker,
					"the existing native provider consumes the current shared heading")
				helpers.assert_eq(actual[2].disabled, true)
				helpers.assert_nil(actual[2].action)
				helpers.assert_eq(actual[4].items[1].action(), false)
				helpers.assert_eq(effects.actions, { "first", "second" })
				local locale_owner = { pending = function() return false end }
				assert(native_i18n.scope_acquire(locale_owner))
				local receipt = assert(native_i18n.scope_capture(locale_owner))
				assert(native_i18n.scope_apply(locale_owner, receipt, "fr"))
				assert(native_i18n.scope_release(locale_owner))
				assert(native_i18n.scope_forget(locale_owner, receipt))
				actual = rows()
				helpers.assert_eq(actual[2].label, expected.fr_marker)
				helpers.assert_eq(actual[3].items[3].label, "Annuler")
				helpers.assert_eq(actual[2].disabled, true)
				helpers.assert_nil(actual[2].action)
				helpers.assert_eq(context.state.shortcuts, true)
			end, debug.traceback)
			frame[2] = original
			if not ok then error(detail, 0) end
		end)
	end)

	helpers.it("missing and unbound boundaries refuse after sandbox loading without a native fallback (extension-boundary)", function()
		with_extension_boundary(function(rows, renderer, expected, context, effects)
			local root, frame = renderer.get_root(), renderer.get_array(expected.section)
			local ok, detail = xpcall(function()
				root[expected.section] = nil
				helpers.assert_eq(rows(), {})
				helpers.assert_eq(effects.loads, 2, "existing sandbox chunks run before presentation admission")
				helpers.assert_eq(effects.actions, {})
				root[expected.section] = { { type = "command", id = "unowned_extension_boundary", i18n = expected.caption_key } }
				helpers.assert_eq(rows(), {})
				helpers.assert_eq(effects.loads, 4)
				helpers.assert_eq(effects.actions, {})
				helpers.assert_eq(context.state.shortcuts, true)
			end, debug.traceback)
			root[expected.section] = frame
			if not ok then error(detail, 0) end
			helpers.assert_eq(rows()[2].label, "— Extensions —", "repair retains the same genuine owner")
			helpers.assert_eq(effects.loads, 6)
			helpers.assert_eq(effects.actions, {})
		end)
	end)

	helpers.it("the empty native provider and Linux boundary projection remain absent (extension-boundary)", function()
		with_extension_boundary(function(rows, renderer, expected, context, effects, native_i18n)
			context.extension_packs = {}
			helpers.assert_eq(rows(), expected.empty_rows)
			helpers.assert_eq(effects.loads, 0)
			helpers.assert_eq(effects.actions, {})
			local Renderer, Json = require("menu.renderer"), require("adapters.json_codec")
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local projected = assert(Renderer.new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = Json.decode, i18n = native_i18n, logger = require("infra.logger") }))
				helpers.assert_eq(projected.template_rows(expected.section, {}, {}, {}), expected.projections[platform])
			end
		end)
	end)

	helpers.it("the native locale and module owners restore exactly after success and construction failure (extension-boundary)", function()
		local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu", "ui.menu.menu_shortcuts", "menu.renderer" }
		local before = {}
		for index, name in ipairs(names) do before[index] = package.loaded[name] end
		local function assert_restored()
			for index, name in ipairs(names) do helpers.assert_true(rawequal(before[index], package.loaded[name]), name) end
		end
		with_extension_boundary(function() end)
		assert_restored()
		local ok, detail = pcall(with_extension_boundary, function() error("extension-boundary-scoped-failure", 0) end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(detail):find("extension%-boundary%-scoped%-failure") ~= nil)
		assert_restored()
	end)
end)
