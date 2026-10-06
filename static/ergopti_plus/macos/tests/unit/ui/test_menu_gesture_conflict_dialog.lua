--- tests/unit/ui/test_menu_gesture_conflict_dialog.lua

--- ==============================================================================
--- MODULE: Gesture Conflict Dialog Regression
--- DESCRIPTION:
--- Exercises both action-picker paths through the real menu and deferred dialog.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a picker callback with deterministic native boundaries.
--- @param parameter boolean Whether the action needs a parameter.
--- @param clicked string The dialog button selected by the user.
--- @param refusal string|nil Simulated assignment refusal.
--- @param picked string|nil Parameter collected by the picker editor.
--- @return table observed Native effects.
local function choose(parameter, clicked, refusal, picked)
	local names = {
		"ui.menu.menu_gestures", "modules.gestures", "ui.menu.menu_utils", "infra.dialog_util",
		"infra.i18n", "infra.manifest_menu", "ui.action_picker", "ui.menu.shortcut_utils",
		"infra.logger", "infra.deferred_work", "adapters.storage", "ui.gesture_conflict_notice",
		"menu.renderer", "json",
	}
	local saved, observed = {}, { queue = {}, opened = {}, dialogs = 0, refreshed = 0, settings = 0, prompts = 0 }
	local saved_shell = package.loaded["adapters.shell_runner"]
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local gestures = {
		DEFAULT_STATE = { gestures = true }, get_action = function() return "none" end,
		get_sg_names = function() return { "lookup" } end,
		get_action_label = function() return "Lookup" end,
		set_action = function(_, action)
			if action == "none" then return true end
			if refusal == "throw" then error("assignment refused") end
			if refusal == "nil" then return nil end
			return refusal ~= "false"
		end,
		on_action_changed = function() return { key = "tap_2", msg = "Conflict", url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension" } end,
		get_action_parameter_spec = function() return parameter and "link" or nil end,
		get_action_parameter = function() return "" end,
		parameter_prompt = function() return "URL" end,
		parameter_error = function() return "Invalid URL" end,
		validate_action_parameter = function() return true end,
		set_action_parameter = function(_, _, value) observed.parameter = value; return true end,
		system_gesture_conflicts = function() return { { label = "Two-finger secondary click" } } end,
		system_pinch_enabled = function() return true end,
		open_system_gestures = function() observed.settings = observed.settings + 1 end,
		refresh_system_gestures = function(done) observed.refreshed = observed.refreshed + 1; done(); return true end,
	}
	package.loaded["modules.gestures"] = gestures
	package.loaded["ui.menu.menu_utils"] = { section = function(label) return { label = label } end }
	package.loaded["infra.dialog_util"] = {
		text_prompt = function() observed.prompts = observed.prompts + 1; return "button.save", "https://example.com" end,
		block_alert = function() observed.dialogs = observed.dialogs + 1; return clicked end,
	}
	package.loaded["infra.i18n"] = { get = function(key)
		return key == "gestures.system.conflicts" and "{1} conflicts" or key
	end, section = function(key) return key end }
	local renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
		json_decode = require("json").decode,
		i18n = package.loaded["infra.i18n"], logger = helpers.make_logger_stub(),
	}))
	package.loaded["infra.manifest_menu"] = {
		template_rows = renderer.template_rows,
		get_root = function() return { gesture_slots = { ["2"] = { "tap_2" } } } end,
		build = function(_, _, _, _, _, providers)
			observed.status = providers.system_gesture_status()
			return providers.gesture_slots_2()
		end,
	}
	package.loaded["ui.action_picker"] = { open = function(_, callback) callback("lookup", picked) end }
	package.loaded["ui.menu.shortcut_utils"] = {
		action_parameter_title = function(label) return label end,
		picker_parameter_fields = function() return {} end,
		-- The kind-aware ask of the real module, reduced to its text prompt.
		ask_parameter_value = function(_, _, _, title, prior)
			local button, typed = package.loaded["infra.dialog_util"].text_prompt(title, "", prior)
			if button ~= "button.save" then return nil end
			return typed
		end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.storage"] = { get = function() return false end }
	package.loaded["infra.deferred_work"] = { after = function(_, callback) observed.queue[#observed.queue + 1] = callback; return true end }
	package.loaded["adapters.shell_runner"] = { open = function(url) observed.opened[#observed.opened + 1] = url; return true end }
	local ok, err = xpcall(function()
		local menu = require("ui.menu.menu_gestures").build({
			gestures = gestures, state = { gestures = true }, save_prefs = function() return true end,
			updateMenu = function() end,
		})
		menu.submenu[1].items[1].action()
		while #observed.queue > 0 do table.remove(observed.queue, 1)() end
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved_shell
	if not ok then error(err, 0) end
	return observed
end

helpers.describe("gesture conflict dialog buttons (gesture-conflicts)", function()
	helpers.it("keeps the picker parameter while showing the conflict notice", function()
		local value = "https://example.com/?q=[test]&part=50%"
		local observed = choose(true, "OK", nil, value)
		helpers.assert_eq(observed.parameter, value)
		helpers.assert_eq(observed.prompts, 0, "the existing picker editor must not prompt twice")
		helpers.assert_eq(observed.dialogs, 1)
	end)
	helpers.it("builds a cached status submenu with explicit Settings and refresh actions", function()
		local observed = choose(false, "OK", "false")
		helpers.assert_eq(observed.refreshed, 0, "building the menu cannot start a probe")
		helpers.assert_eq(observed.settings, 0, "building the menu cannot open Settings")
		helpers.assert_eq(observed.status[1].label, "1 conflicts")
		helpers.assert_eq(#observed.status[1].items, 3)
		observed.status[1].items[1].action()
		helpers.assert_eq(observed.settings, 1)
		observed.status[1].items[3].action()
		helpers.assert_eq(observed.refreshed, 1)
	end)
	for _, parameter in ipairs({ false, true }) do
		for _, refusal in ipairs({ "false", "nil", "throw" }) do
			helpers.it("does not warn for a refused " .. (parameter and "parameter" or "plain") .. " assignment: " .. refusal, function()
				local observed = choose(parameter, "menu.gestures.open_settings", refusal)
				helpers.assert_eq(observed.dialogs, 0)
				helpers.assert_eq(#observed.opened, 0)
			end)
		end
		helpers.it("opens Settings from the " .. (parameter and "parameter" or "plain") .. " picker", function()
			local observed = choose(parameter, "menu.gestures.open_settings")
			helpers.assert_eq(observed.dialogs, 1)
			helpers.assert_eq(observed.opened, { "x-apple.systempreferences:com.apple.Trackpad-Settings.extension" })
		end)
		helpers.it("dismisses the " .. (parameter and "parameter" or "plain") .. " warning without opening Settings", function()
			local observed = choose(parameter, "OK")
			helpers.assert_eq(observed.dialogs, 1)
			helpers.assert_eq(#observed.opened, 0)
		end)
	end
end)


-- Exercise the real status provider and renderer; status probes and platform
-- ports remain controlled so menu construction cannot hide native work.
local refresh_modules = {
	"json", "menu.renderer", "infra.manifest_menu", "infra.i18n", "infra.logger",
	"modules.gestures", "ui.menu.menu_utils", "infra.dialog_util", "ui.action_picker",
	"ui.menu.shortcut_utils", "infra.deferred_work", "ui.menu.menu_gestures",
}
local function refresh_json(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	file:close()
	return require("json").decode(bytes)
end
local function with_status_refresh(options, callback)
	return helpers.with_fresh_modules(refresh_modules, function()
		options = options or {}
		local corpus = refresh_json(helpers.shared("tests/corpus/menus/gesture_system_refresh.json"))
		local strings = refresh_json(helpers.shared("data/locales/" .. (options.locale or "en") .. ".json"))
		local i18n = { get = function(key) return strings[key] or key end,
			section = function(key) return strings[key] or key end }
		local renderer = assert(require("menu.renderer").new({
			platform = options.platform or "hs",
			manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
			json_decode = require("json").decode, i18n = i18n, logger = helpers.make_logger_stub(),
		}))
		local fixture = { corpus = corpus, strings = strings, renderer = renderer, root = renderer.get_root(),
			refreshes = 0, settings = 0, updates = 0, pinch = true,
			conflicts = { { label = "Existing native conflict" } }, done = nil }
		fixture.gestures = {
			DEFAULT_STATE = { gestures = true },
			system_gesture_conflicts = function() return fixture.conflicts end,
			system_pinch_enabled = function() return fixture.pinch end,
			open_system_gestures = function() fixture.settings = fixture.settings + 1; return true end,
			refresh_system_gestures = function(done)
				fixture.refreshes = fixture.refreshes + 1
				fixture.done = done
				if options.refresh then return options.refresh(fixture) end
				return true
			end,
		}
		package.loaded["modules.gestures"] = fixture.gestures
		package.loaded["infra.i18n"] = i18n
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.menu_utils"] = { section = function(title) return { title = title } end }
		package.loaded["infra.dialog_util"] = {}
		package.loaded["ui.action_picker"] = {}
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["infra.deferred_work"] = {}
		package.loaded["infra.manifest_menu"] = {
			template_rows = renderer.template_rows,
			build = function(_, _, _, _, _, providers)
				fixture.canonical = providers.system_gesture_status()
				return renderer.render_rows(fixture.canonical, "actual-system-gesture-status")
			end,
		}
		local owner = require("ui.menu.menu_gestures")
		function fixture.build()
			return owner.build({ gestures = fixture.gestures, state = { gestures = true },
				updateMenu = function() fixture.updates = fixture.updates + 1 end }).submenu
		end
		return callback(fixture)
	end)
end

helpers.describe("Gestures: declared cached-status refresh and actual native callback", function()
	helpers.it("pins independent shared command and existing platform capability", function()
		with_status_refresh({}, function(f)
			helpers.assert_eq(f.root[f.corpus.section], f.corpus.rows)
		end)
	end)
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("renders the existing Refresh caption and cached children: " .. locale, function()
			with_status_refresh({ locale = locale }, function(f)
				local group = f.build()[1]
				helpers.assert_eq(#group.menu, 3)
				helpers.assert_eq(group.menu[1].title, "Existing native conflict")
				helpers.assert_eq(group.menu[2].title, f.strings["gestures.system.pinch"] .. " : " .. f.strings["menu.common.enabled"])
				helpers.assert_eq(group.menu[3].title, f.corpus.captions[locale])
				helpers.assert_type(group.menu[3].fn, "function")
				helpers.assert_eq(f.refreshes, 0)
				helpers.assert_eq(f.settings, 0)
				helpers.assert_true(group.menu[3].fn())
				helpers.assert_eq(f.refreshes, 1)
				helpers.assert_eq(f.updates, 0, "native owner receives the exact update callback")
				f.done()
				helpers.assert_eq(f.updates, 1)
			end)
		end)
	end
	for _, platform in ipairs({ "ahk", "hs", "linux" }) do
		helpers.it("projects the declared capability without inventing Linux refresh: " .. platform, function()
			with_status_refresh({ platform = platform }, function(f)
				local calls = 0
				local rows = f.renderer.template_rows(f.corpus.section, {
					gesture_system_refresh = function() calls = calls + 1; return false end,
				})
				helpers.assert_eq(#rows, #f.corpus.platform_rows[platform])
				if #rows > 0 then
					helpers.assert_eq(false, rows[1].action())
					helpers.assert_eq(calls, 1)
				end
			end)
		end)
	end
	helpers.it("follows declared separator order and caption through the actual rendered provider", function()
		with_status_refresh({}, function(f)
			local rows = f.root[f.corpus.section]
			rows[1].i18n = "menu.gestures.open_settings"
			table.insert(rows, 1, { type = "---", platforms = { "hs" }, unavailable = "hide" })
			local children = f.build()[1].menu
			helpers.assert_eq(#children, 4)
			helpers.assert_eq(children[1].title, "Existing native conflict")
			helpers.assert_eq(children[3].title, "-")
			helpers.assert_eq(children[4].title, f.strings["menu.gestures.open_settings"])
			helpers.assert_true(children[4].fn())
			helpers.assert_eq(f.refreshes, 1)
		end)
	end)
	helpers.it("hides only the declared command while retaining existing cached native Settings rows", function()
		with_status_refresh({}, function(f)
			f.root[f.corpus.section][1].platforms = { "linux" }
			local children = f.build()[1].menu
			helpers.assert_eq(#children, 2)
			helpers.assert_true(children[1].fn())
			helpers.assert_true(children[2].fn())
			helpers.assert_eq(f.settings, 2)
			helpers.assert_eq(f.refreshes, 0)
		end)
	end)
	helpers.it("refuses an unknown declared command owner without publishing partial status", function()
		with_status_refresh({}, function(f)
			f.root[f.corpus.section][1].id = "unknown_native_refresh_owner"
			helpers.assert_eq(f.build(), {})
			helpers.assert_eq(f.refreshes, 0)
		end)
	end)
	helpers.it("retained callback delivers to the current native refresh method", function()
		with_status_refresh({}, function(f)
			local held = f.build()[1].menu[3].fn
			f.gestures.refresh_system_gestures = function(done)
				f.refreshes = f.refreshes + 2
				f.done = done
				return false
			end
			helpers.assert_eq(false, held())
			helpers.assert_eq(f.refreshes, 2)
			f.done()
			helpers.assert_eq(f.updates, 1)
		end)
	end)
	for _, refusal in ipairs({ { "false", function() return false end },
		{ "nil", function() return nil end }, { "truthy", function() return "native-receipt" end } }) do
		helpers.it("preserves the native refresh acknowledgement: " .. refusal[1], function()
			with_status_refresh({ refresh = refusal[2] }, function(f)
				helpers.assert_eq(refusal[2](), f.build()[1].menu[3].fn())
				helpers.assert_eq(f.refreshes, 1)
				helpers.assert_eq(f.updates, 0)
			end)
		end)
	end
	helpers.it("preserves a throwing native refresh receipt without manufacturing completion", function()
		with_status_refresh({ refresh = function() error("native-refresh-refused") end }, function(f)
			local ok, err = pcall(f.build()[1].menu[3].fn)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("native-refresh-refused", 1, true) ~= nil)
			helpers.assert_eq(f.refreshes, 1)
			helpers.assert_eq(f.updates, 0)
		end)
	end)
	for _, pinch in ipairs({ { "enabled", true, "menu.common.enabled" },
		{ "disabled", false, "common.disabled" }, { "unknown", nil, "gestures.system.unknown" } }) do
		helpers.it("retains native cached pinch presentation: " .. pinch[1], function()
			with_status_refresh({}, function(f)
				f.pinch = pinch[2]
				f.conflicts = {}
				local group = f.build()[1]
				helpers.assert_eq(group.title, f.strings["gestures.system.clear"])
				helpers.assert_eq(#group.menu, 2)
				helpers.assert_eq(group.menu[1].title, f.strings["gestures.system.pinch"] .. " : " .. f.strings[pinch[3]])
				helpers.assert_eq(group.menu[2].title, f.corpus.captions.en)
				helpers.assert_eq(f.refreshes, 0)
			end)
		end)
	end
end)
