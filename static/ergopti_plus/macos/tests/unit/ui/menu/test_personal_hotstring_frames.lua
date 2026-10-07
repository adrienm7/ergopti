--- tests/unit/ui/menu/test_personal_hotstring_frames.lua

--- ==============================================================================
--- MODULE: Personal Hotstrings Complete Frames
--- DESCRIPTION:
--- Exercises native source order, literal captions, state and retained callbacks
--- through the genuine shared renderer. Canonical frame withdrawal cannot publish
--- a partial personal menu or mutate the source through its retained controls.
--- ==============================================================================

local helpers = require("tests.helpers")
local PersonalTranslator = require("infra.i18n")

--- Owns one genuine renderer and the native context supplied by the tray.
--- @param body function Receives the private frame and source observations.
--- @param options table|nil Source inventory and native presentation posture.
local function with_personal_frame(body, options)
	options = options or {}
	local previous, previous_hs, previous_getenv = {}, rawget(_G, "hs"), os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local scratch, native, owner, receipt, acquired, fresh_bridge
	local ok, result = xpcall(function()
		local driver = helpers.driver_root():gsub("/+$", "")
		local shared = assert(driver:match("^(.*)/[^/]+$")) .. "/_shared/lua"
		require("tests.support.module_isolation").purge(driver, shared)
		helpers.load_with_stubs("infra.logger")
		scratch = assert(os.tmpname()); assert(os.remove(scratch))
		assert(hs.fs.mkdir(scratch)); assert(hs.fs.mkdir(scratch .. "/metrics"))
		local ledger = assert(io.open(scratch .. "/metrics/karabiner_kc.log", "wb")); assert(ledger:close())
		local bootstrap = assert(io.open(scratch .. "/paths.toml", "wb"))
		assert(bootstrap:write('ConfigDirPath = "' .. scratch .. '/"\n')); assert(bootstrap:close())
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return scratch .. "/paths.toml" end
			return previous_getenv(name)
		end
		local paths = require("infra.config_paths"); assert(paths.init(scratch .. "/") == true)
		package.loaded["infra.i18n"] = nil
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner); assert(acquired == true)
		receipt = assert(native.scope_capture(owner))
		assert(native.scope_apply(owner, receipt, options.locale or PersonalTranslator.get_locale()) == true)
		local renderer = require("infra.manifest_menu")

		local corpus_file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/hotstring_personal_frames.json"), "rb"))
		local corpus = assert(require("json").decode(assert(corpus_file:read("*a")))); assert(corpus_file:close())
		local calls = { saves = 0, updates = 0, defaults = 0, closes = 0 }
		local sections = options.empty and {} or {
			{ name = "alpha", description = "Repeated", count = 2 },
			{ name = "-" },
			{ name = "module", description = "Placeholder", is_module_placeholder = true },
			{ name = "beta", description = "Repeated", count = 3 },
		}
		local context = {
			state = { hotstrings = {}, trigger_char = "★", custom_default_section = options.empty and false or "beta",
				custom_close_on_add = false, custom_editor_shortcut = options.legacy and { mods = { "ctrl" }, key = "j" } or nil },
			paused = options.paused == true, hotfiles = { "personal" }, hotfile_paths = {},
			get_group_name = function(value) return value end,
			applyTriggerChar = function(value) return value end,
			keymap = {
				get_sections = function(name) return name == "personal" and sections or {} end,
				is_group_enabled = function() return true end,
				is_section_enabled = function(_group, name) return name == "alpha" end,
			},
			script_control = { is_paused = function() return options.paused == true end },
			hotstring_editor = {
				open = function() end,
				set_default_section = function() calls.defaults = calls.defaults + 1 end,
				set_close_on_add = function() calls.closes = calls.closes + 1 end,
			},
			save_prefs = function() calls.saves = calls.saves + 1; return true end,
			updateMenu = function() calls.updates = calls.updates + 1 end,
		}
		if options.empty then context.state.custom_default_section = false end
		local menu_owner = require("ui.menu.menu_hotstrings_custom")
		fresh_bridge = package.loaded["modules.keylogger.kc_bridge"]
		return body({ build = function() return menu_owner.build_custom(context, { group_counts = { personal = 5 } }) end,
			root = renderer.get_root(), renderer = renderer, context = context, calls = calls,
			translate = native.get, corpus = corpus, locale = native.get_locale() })
	end, debug.traceback)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleaned, cleanup_error = pcall(function()
		fresh_bridge = fresh_bridge or package.loaded["modules.keylogger.kc_bridge"]
		if fresh_bridge and not rawequal(fresh_bridge, previous["modules.keylogger.kc_bridge"]) then fresh_bridge.stop() end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then
			assert(scheduler.cancelAll() == true); assert(scheduler.activeCount() == 0)
		end
		if scratch then
			os.remove(scratch .. "/metrics/karabiner_kc.log"); os.remove(scratch .. "/paths.toml")
			if hs.fs.attributes(scratch .. "/hammerspoon") then assert(hs.fs.rmdir(scratch .. "/hammerspoon")) end
			if hs.fs.attributes(scratch .. "/metrics") then assert(hs.fs.rmdir(scratch .. "/metrics")) end
			assert(hs.fs.rmdir(scratch))
		end
	end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs, os.getenv = previous_hs, previous_getenv
	for name, value in pairs(previous) do assert(rawequal(package.loaded[name], value), name) end
	assert(restored and released and forgotten, "native locale scope restores and releases")
	assert(cleaned, cleanup_error)
	if not ok then error(result, 0) end
	return result
end

--- Finds a native rendered leaf by its independent caption.
--- @param rows table Native child rows.
--- @param title string Literal current caption.
--- @return table row
local function find(rows, title)
	for _, row in ipairs(rows or {}) do if row.title == title then return row end end
	error("missing actual personal row: " .. title, 0)
end

helpers.describe("personal hotstrings complete shared frames", function()
	helpers.it("retains duplicate source choices and editor-dependent legacy order", function()
		with_personal_frame(function(f)
			local parent = assert(f.build())
			local rows = parent.submenu
			local default = find(rows, f.translate("menu.hotstrings.default_category_prefix") .. "Repeated")
			helpers.assert_eq(#default.menu, 4)
			helpers.assert_eq(default.menu[1].title, f.translate("menu.hotstrings.default_none"))
			helpers.assert_eq(default.menu[2].title, "-")
			helpers.assert_eq(default.menu[3].title, "Repeated")
			helpers.assert_eq(default.menu[4].title, "Repeated")
			helpers.assert_eq(default.menu[3].checked == true, false)
			helpers.assert_eq(default.menu[4].checked, true)
			local titles = {}
			for _, row in ipairs(rows) do titles[#titles + 1] = row.title end
			local legacy = f.translate("menu.hotstrings.shortcut_prefix") .. "ctrl + J"
			local legacy_index, default_index
			for index, title in ipairs(titles) do
				if title == legacy then legacy_index = index end
				if title == default.title then default_index = index end
			end
			helpers.assert_eq(default_index, legacy_index + 1)
			helpers.assert_type(find(rows, "Repeated (2)"), "table")
			helpers.assert_type(find(rows, "Repeated (3)"), "table")
			helpers.assert_eq(f.calls.saves, 0); helpers.assert_eq(f.calls.updates, 0)
			local editor = f.root.personal_hotstring_commands
			f.root.personal_hotstring_commands = {}
			local no_editor = assert(f.build()).submenu
			for index, row in ipairs(no_editor) do
				if row.title == default.title then
					helpers.assert_eq(no_editor[index + 1].title, legacy)
				end
			end
			f.root.personal_hotstring_commands = editor
		end, { legacy = true })
	end)
	helpers.it("preserves empty default choices and the acknowledged native callbacks", function()
		with_personal_frame(function(f)
			local rows = assert(f.build()).submenu
			local default = find(rows, f.translate("menu.hotstrings.default_category_prefix") .. f.translate("menu.hotstrings.default_none"))
			helpers.assert_eq(#default.menu, 1)
			helpers.assert_eq(default.menu[1].checked, true)
			default.menu[1].fn()
			helpers.assert_eq(f.context.state.custom_default_section, nil)
			helpers.assert_eq(f.calls.defaults, 1)
			find(rows, f.translate("menu.hotstrings.close_on_add")).fn()
			helpers.assert_eq(f.context.state.custom_close_on_add, true)
			helpers.assert_eq(f.calls.closes, 1)
			helpers.assert_eq(f.calls.saves, 2); helpers.assert_eq(f.calls.updates, 2)
		end, { empty = true })
	end)
	helpers.it("refuses withdrawn whole frames and retained declared controls before save", function()
		with_personal_frame(function(f)
			local rows = assert(f.build()).submenu
			local default = find(rows, f.translate("menu.hotstrings.default_category_prefix") .. "Repeated")
			local close = find(rows, f.translate("menu.hotstrings.close_on_add"))
			for _, key in ipairs({ "hotstring_personal_default_frame", "hotstring_personal_controls_frame", "hotstring_personal_content_frame", "hotstrings_parameter_boundary", "hotstring_personal_default_parent", "hotstring_personal_legacy_shortcut" }) do
				local original = f.root[key]; f.root[key] = nil
				helpers.assert_eq(f.build(), nil, "missing whole declaration refuses the personal provider")
				f.root[key] = original; helpers.assert_type(f.build(), "table")
			end
			local none = f.root.hotstring_personal_none; f.root.hotstring_personal_none = {}
			helpers.assert_eq(default.menu[1].fn(), false)
			f.root.hotstring_personal_none = none
			local closed = f.root.hotstring_personal_close; f.root.hotstring_personal_close = {}
			helpers.assert_eq(close.fn(), false)
			f.root.hotstring_personal_close = closed
			helpers.assert_eq(f.calls.saves, 0); helpers.assert_eq(f.calls.updates, 0)
			helpers.assert_eq(f.calls.defaults, 0); helpers.assert_eq(f.calls.closes, 0)
		end, { legacy = true })
	end)
	helpers.it("projects genuine French literal hand captions without source mutation", function()
		with_personal_frame(function(f)
			local rows = assert(f.build()).submenu
			local parent = find(rows, f.corpus.default_parent_labels.hs.fr)
			helpers.assert_eq(parent.menu[1].title, f.corpus.none_captions.hs.fr)
			helpers.assert_type(find(rows, f.corpus.close_caption.fr), "table")
			local expected = f.corpus.default_choices.hs_duplicate_and_placeholder
			helpers.assert_eq(#parent.menu, #expected)
			for index, caption in ipairs(expected) do
				if caption == "none" then caption = f.corpus.none_captions.hs.fr end
				if caption == "separator" then caption = "-" end
				helpers.assert_eq(parent.menu[index].title, caption)
			end
			helpers.assert_eq(f.calls.saves, 0); helpers.assert_eq(f.calls.updates, 0)
		end, { locale = "fr" })
	end)
	helpers.it("restores genuine source and caption owners after a scenario raises", function()
		local renderer, source = rawget(package.loaded, "infra.manifest_menu"), rawget(package.loaded, "infra.personal_hotstrings")
		local ok, detail = pcall(with_personal_frame, function() error("personal frame scenario sentinel") end)
		helpers.assert_eq(ok, false); helpers.assert_true(detail:find("personal frame scenario sentinel", 1, true) ~= nil)
		helpers.assert_true(rawequal(rawget(package.loaded, "infra.manifest_menu"), renderer))
		helpers.assert_true(rawequal(rawget(package.loaded, "infra.personal_hotstrings"), source))
	end)

end)
