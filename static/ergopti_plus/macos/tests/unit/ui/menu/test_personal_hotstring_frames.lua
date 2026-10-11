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

--- Restores the exact private declaration independently of scenario failure.
--- @param frame table Genuine existing provider fixture.
--- @param scenario function Receives the retained original leaf declaration.
local function with_default_choice_declaration(frame, scenario)
	local key = "hotstring_personal_default_choice"
	local original = rawget(frame.root, key)
	assert(type(original) == "table", "the genuine generated choice declaration exists")
	local native_index
	for index, row in ipairs(original) do
		for _, platform in ipairs(row.platforms or {}) do
			if platform == "hs" then
				assert(native_index == nil, "the original leaf has one actual native-visible owner")
				native_index = index
			end
		end
	end
	assert(native_index ~= nil, "the original leaf has its actual native-visible owner")
	local ok, result = xpcall(function() return scenario(key, original, native_index) end, function(err) return err end)
	rawset(frame.root, key, original)
	if not ok then error(result, 0) end
	return result
end

helpers.describe("shared personal default-category leaf policy", function()
	for _, kind in ipairs({ "missing", "kind", "caption" }) do
		helpers.it("refuses actual provider with " .. kind .. " leaf source and repairs exactly", function()
			with_personal_frame(function(f)
				with_default_choice_declaration(f, function(key, original, native_index)
					assert(type(f.build()) == "table")
					local changed = {}
					if kind ~= "missing" then
						for index, row in ipairs(original) do changed[index] = row end
						local row = {}
						for field, value in pairs(original[native_index]) do row[field] = value end
						if kind == "kind" then row.type = "label"
						else row.caption_getter = "unavailable_default_caption" end
						changed[native_index] = row
					end
					rawset(f.root, key, changed)
					helpers.assert_eq(f.build(), nil, "a refused dynamic leaf cannot publish a partial default frame")
					helpers.assert_eq(f.context.state.custom_default_section, "beta")
					helpers.assert_eq(f.calls.defaults, 0); helpers.assert_eq(f.calls.saves, 0)
					helpers.assert_eq(f.calls.updates, 0)
					rawset(f.root, key, original)
					local repaired = assert(f.build())
					local parent = assert(find(repaired.submenu, f.corpus.default_parent_labels.hs[f.locale]))
					for index, caption in ipairs(f.corpus.default_choices.hs_duplicate_and_placeholder) do
						if caption == "none" then caption = f.corpus.none_captions.hs[f.locale] end
						if caption == "separator" then caption = "-" end
						helpers.assert_eq(parent.menu[index].title, caption)
						helpers.assert_eq(parent.menu[index].checked == true, f.corpus.default_checks.hs[index])
					end
				end)
			end)
		end)
	end
	helpers.it("retained actual choice refuses missing source and dispatches after exact repair", function()
		with_personal_frame(function(f)
			with_default_choice_declaration(f, function(key, original)
				local rows = assert(f.build()).submenu
				local parent = assert(find(rows, f.corpus.default_parent_labels.hs[f.locale]))
				local choice = assert(parent.menu[3])
				helpers.assert_eq(choice.title, f.corpus.default_choices.hs_duplicate_and_placeholder[3])
				rawset(f.root, key, {})
				helpers.assert_eq(choice.fn(), false)
				helpers.assert_eq(f.context.state.custom_default_section, "beta")
				helpers.assert_eq(f.calls.defaults, 0); helpers.assert_eq(f.calls.saves, 0)
				helpers.assert_eq(f.calls.updates, 0)
				rawset(f.root, key, original)
				choice.fn()
				helpers.assert_eq(f.context.state.custom_default_section, "alpha")
				helpers.assert_eq(f.calls.defaults, 1); helpers.assert_eq(f.calls.saves, 1)
				helpers.assert_eq(f.calls.updates, 1)
				-- Existing context ports record callback effects; this is not a durable native preference ACK.
			end)
		end)
	end)
end)

--- Runs the actual registry and file-scope admission on one owned physical source.
--- Native Hammerspoon stat primitives use real lfs observations; the existing
--- frame's preference/notification ports record delivery, not durable Mac IO.
--- @param frame table Existing genuine personal-provider fixture.
--- @param scenario function Actual native registered-section observations.
--- @param posture string|nil ready, paused or group_off.
local function with_registered_personal_sections(frame, scenario, posture)
	local failed, primary
	local cleanup = {}; frame.section_fixture_cleanup = cleanup
	local scoped, scope_error = pcall(helpers.with_stub_scope, {
		"modules.keymap", "modules.keymap.init", "modules.keymap.state",
		"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
		"modules.keymap.utils", "modules.keymap.expander", "modules.keymap.llm_bridge",
		"modules.keymap.terminator_replay", "infra.personal_hotstrings", "infra.personal_file_controls",
	}, function()
		local lfs = require("lfs")
		local paths = require("infra.config_paths")
		local original_get = paths.get
		local original_attributes, original_symlink_attributes = hs.fs.attributes, hs.fs.symlinkAttributes
		local root, path, state_module, original_new, native_keymap
		local ok, result = xpcall(function()
			root = assert(os.tmpname()); assert(os.remove(root)); assert(lfs.mkdir(root))
			path = root .. "/section.toml"
			local source = '[[alpha]]\n"alf" = { output = "Alpha", is_case_sensitive = true, is_case_sensitive_strict = true }\n[[beta]]\n"bet" = { output = "Beta", is_case_sensitive = true, is_case_sensitive_strict = true }\n'
			local function with_source_stream(mode, operation)
				local file = assert(io.open(path, mode))
				local completed, value = xpcall(function() return operation(file) end, function(err) return err end)
				local closed, close_result, close_error = pcall(file.close, file)
				-- A failed read/write keeps its exact primary after the owned close attempt.
				if not completed then error(value, 0) end
				if not closed then error(close_result, 0) end
				assert(close_result, close_error)
				return value
			end
			local function write_source()
				with_source_stream("wb", function(file) return assert(file:write(source)) end)
			end
			local function read_source()
				return with_source_stream("rb", function(file) return assert(file:read("*a")) end)
			end
			write_source()
			hs.fs.attributes, hs.fs.symlinkAttributes = lfs.attributes, lfs.symlinkattributes
			paths.get = function(key)
				if key == "PersonalHotstringsDir" then return root end
				return original_get(key)
			end
			local registry = require("modules.keymap.registry")
			state_module = require("modules.keymap.state")
			original_new = state_module.new
			local state, received_defaults, received_delays
			-- Observe the genuine first boot allocation; never construct a competing state.
			state_module.new = function(defaults, delays, ...)
				local actual = original_new(defaults, delays, ...)
				assert(state == nil, "one genuine Keymap CoreState allocation")
				state, received_defaults, received_delays = actual, defaults, delays
				return actual
			end
			local loaded, value = pcall(require, "modules.keymap")
			state_module.new = original_new
			if not loaded then error(value, 0) end
			native_keymap = value
			assert(type(state) == "table" and rawequal(received_defaults, native_keymap.DEFAULT_STATE)
				and rawequal(received_delays, native_keymap.DELAYS_DEFAULT), "actual boot state and canonical defaults")
			assert(rawequal(rawget(package.loaded, "modules.keymap.registry"), registry), "actual retained registry cohort")
			local name = "personal_ext_section"
			local descriptor = require("hotstrings.personal_files").describe({ "section.toml" })
			assert(registry.load_toml(name, path, nil, descriptor) == true)
			assert(registry.disable_section(name, "beta") == true)
			if posture == "group_off" then assert(registry.disable_group(name) == true) end
			local record = { name = name, path = path, personal_source = descriptor }
			frame.context.keymap, frame.context.hotfiles = registry, { name }
			frame.context.personal_root, frame.context.personal_files = root, { record }
			frame.context.hotfile_paths = { [name] = path }
			frame.context.state.hotstrings[name] = posture ~= "group_off"
			frame.context.paused = posture == "paused"
			local notices = 0
			frame.context.notify_feature = function() notices = notices + 1 end
			local current = require("infra.personal_file_scope").bind(frame.context, record)
			assert(current() == true, "the genuine registered descriptor and actual physical source admit this section owner")
			scenario({ frame = frame, registry = registry, state = state, name = name, path = path,
				current = current, read = read_source, repair = write_source, source = source,
				notices = function() return notices end })
		end, function(err) return err end)
		if state_module and original_new then state_module.new = original_new end
		cleanup.state_new_restored = state_module ~= nil and rawequal(state_module.new, original_new)
		local keymap_released, keymap_error = pcall(function()
			if native_keymap then assert(native_keymap.stop(true) == true, "genuine Keymap teardown commits") end
		end)
		cleanup.keymap_stopped = native_keymap ~= nil and keymap_released
		cleanup.native_keymap_loaded = native_keymap ~= nil
		paths.get = original_get
		hs.fs.attributes, hs.fs.symlinkAttributes = original_attributes, original_symlink_attributes
		local file_released, file_error = pcall(function()
			if path and lfs.symlinkattributes(path) ~= nil then assert(os.remove(path)) end
		end)
		local root_released, root_error = pcall(function()
			if root then assert(lfs.rmdir(root)) end
		end)
		cleanup.file_released, cleanup.root_released = file_released, root_released
		-- Keep the raw primary inside the scope so both traceback wrappers restore
		-- their actual owners before it is raised outside them.
		if not ok then failed, primary = true, result
		elseif not keymap_released then failed, primary = true, keymap_error
		elseif not file_released then failed, primary = true, file_error
		elseif not root_released then failed, primary = true, root_error end
	end)
	cleanup.scope_restored = scoped
	if not scoped and not failed then failed, primary = true, scope_error end
	-- Receiver consumes every real cleanup port independently of expected-red
	-- assertion names/counts. Missing or false records cannot qualify a phase.
	local reported, report_error = pcall(print, string.format(
		"ERGOPTI_PERSONAL_SECTION_CLEANUP native_keymap_loaded=%s state_new_restored=%s scope_restored=%s keymap_stopped=%s file_released=%s root_released=%s",
		tostring(cleanup.native_keymap_loaded == true), tostring(cleanup.state_new_restored == true),
		tostring(cleanup.scope_restored == true), tostring(cleanup.keymap_stopped == true),
		tostring(cleanup.file_released == true), tostring(cleanup.root_released == true)))
	if not reported and not failed then failed, primary = true, report_error end
	if failed then error(primary, 0) end
end

--- Restores this genuine Mac-only declaration after every scenario.
--- @param frame table Existing shared renderer fixture.
--- @param scenario function Receives the unchanged original source.
local function with_personal_section_declaration(frame, scenario)
	local key = "hotstring_personal_section_choice"
	local original = rawget(frame.root, key)
	assert(type(original) == "table" and #original == 1, "one genuine generated native section declaration")
	assert(original[1].platforms[1] == "hs" and #original[1].platforms == 1)
	local ok, result = xpcall(function() return scenario(key, original) end, function(err) return err end)
	rawset(frame.root, key, original)
	if not ok then error(result, 0) end
	return result
end

--- Finds actual rendered section commands below the real extension file.
--- @param frame table Existing actual provider fixture.
--- @return table alpha
--- @return table beta
local function registered_section_rows(frame)
	local file = find(assert(frame.build()).submenu, "section (1)")
	helpers.assert_eq(#file.menu, 6, "the original actual file frame retains every control and both section leaves")
	helpers.assert_eq(file.menu[1].title, frame.translate("menu.hotstrings.scope_enable_all"))
	helpers.assert_eq(file.menu[2].title, frame.translate("menu.hotstrings.scope_disable_all"))
	helpers.assert_eq(file.menu[3].title, frame.translate("menu.hotstrings.open_file"))
	helpers.assert_eq(file.menu[4].title, "-")
	helpers.assert_eq(file.menu[5].title, "alpha (1)"); helpers.assert_eq(file.menu[6].title, "beta (1)")
	return file.menu[5], file.menu[6]
end

helpers.describe("shared personal section leaf policy", function()
	for _, kind in ipairs({ "missing", "kind", "caption" }) do
		helpers.it("refuses the actual registered section provider with " .. kind .. " source and repairs exactly", function()
			with_personal_frame(function(frame)
				with_registered_personal_sections(frame, function(f)
					with_personal_section_declaration(frame, function(key, original)
						registered_section_rows(frame)
						local changed = {}
						if kind ~= "missing" then
							local row = {}; for field, value in pairs(original[1]) do row[field] = value end
							if kind == "kind" then row.type = "label"
							else row.caption_getter = "unavailable_personal_section_caption" end
							changed[1] = row
						end
						rawset(frame.root, key, changed)
						helpers.assert_nil(frame.build(), "a refused section leaf cannot publish a partial real personal file")
						helpers.assert_eq(f.read(), f.source)
						helpers.assert_eq({ frame.calls.saves, frame.calls.updates, f.notices() }, { 0, 0, 0 })
						helpers.assert_true(f.registry.is_section_enabled(f.name, "alpha"))
						helpers.assert_eq(f.registry.is_section_enabled(f.name, "beta"), false)
						rawset(frame.root, key, original)
						local alpha, beta = registered_section_rows(frame)
						helpers.assert_eq(alpha.checked, true); helpers.assert_nil(beta.checked)
						helpers.assert_type(alpha.fn, "function"); helpers.assert_type(beta.fn, "function")
					end)
				end)
			end)
		end)
	end
	for _, posture in ipairs({ "ready", "paused", "group_off" }) do
		helpers.it("preserves actual registered section captions checks and nil transport while " .. posture, function()
			with_personal_frame(function(frame)
				with_registered_personal_sections(frame, function(f)
					local alpha, beta = registered_section_rows(frame)
					helpers.assert_eq(alpha.checked, true); helpers.assert_nil(beta.checked)
					for _, row in ipairs({ alpha, beta }) do
						helpers.assert_nil(row.menu, "section leaves remain commands rather than submenus")
						if posture == "ready" then
							helpers.assert_nil(row.disabled); helpers.assert_type(row.fn, "function")
						else
							helpers.assert_eq(row.disabled, true); helpers.assert_nil(row.fn)
						end
					end
					helpers.assert_eq(f.read(), f.source)
					helpers.assert_eq({ frame.calls.saves, frame.calls.updates, f.notices() }, { 0, 0, 0 },
						"pure closure acquisition does not deliver the business delegate")
				end, posture)
			end)
		end)
	end
	helpers.it("held actual section refuses missing declaration and delivers its native delegate after repair", function()
		with_personal_frame(function(frame)
			with_registered_personal_sections(frame, function(f)
				with_personal_section_declaration(frame, function(key, original)
					local alpha = registered_section_rows(frame)
					local mapping = assert(f.state.mappings[1])
					rawset(frame.root, key, {})
					helpers.assert_eq(alpha.fn(), false)
					helpers.assert_true(f.registry.is_section_enabled(f.name, "alpha"))
					helpers.assert_true(rawequal(f.state.mappings[1], mapping))
					helpers.assert_eq({ frame.calls.saves, frame.calls.updates, f.notices() }, { 0, 0, 0 })
					rawset(frame.root, key, original)
					helpers.assert_nil(alpha.fn(), "the original section delegate retains its void success return")
					helpers.assert_eq(f.registry.is_section_enabled(f.name, "alpha"), false)
					helpers.assert_eq(#f.state.mappings, 0)
					helpers.assert_eq({ frame.calls.saves, frame.calls.updates, f.notices() }, { 1, 1, 1 })
					helpers.assert_eq(f.read(), f.source, "section publication never rewrites the user's rules file")
				end)
			end)
		end)
	end)
		helpers.it("held genuine descriptor admission refuses a missing physical source and retries after repair", function()
		with_personal_frame(function(frame)
			with_registered_personal_sections(frame, function(f)
				local alpha = registered_section_rows(frame)
				assert(os.remove(f.path)); helpers.assert_eq(f.current(), false)
				helpers.assert_eq(alpha.fn(), false)
				helpers.assert_true(f.registry.is_section_enabled(f.name, "alpha"))
				helpers.assert_eq({ frame.calls.saves, frame.calls.updates, f.notices() }, { 0, 0, 0 })
				f.repair(); helpers.assert_eq(f.current(), true)
				helpers.assert_nil(alpha.fn())
				helpers.assert_eq(f.registry.is_section_enabled(f.name, "alpha"), false)
				helpers.assert_eq({ frame.calls.saves, frame.calls.updates, f.notices() }, { 1, 1, 1 })
				helpers.assert_eq(f.read(), f.source)
			end)
		end)
	end)
		helpers.it("restores actual section fixture paths stat ports and module owners after a scenario raises", function()
		with_personal_frame(function(frame)
			local paths = require("infra.config_paths")
			local before_get, before_attributes, before_links = paths.get, hs.fs.attributes, hs.fs.symlinkAttributes
			local before_registry = rawget(package.loaded, "modules.keymap.registry")
			local path, primary = nil, { message = "personal section scenario sentinel" }
			local ok, detail = pcall(with_registered_personal_sections, frame, function(f)
				path = f.path; registered_section_rows(frame); error(primary, 0)
			end)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(detail, primary))
			local cleanup = assert(frame.section_fixture_cleanup)
			helpers.assert_true(cleanup.state_new_restored and cleanup.scope_restored)
			helpers.assert_true(cleanup.keymap_stopped and cleanup.file_released and cleanup.root_released)
			helpers.assert_true(rawequal(paths.get, before_get))
			helpers.assert_true(rawequal(hs.fs.attributes, before_attributes))
			helpers.assert_true(rawequal(hs.fs.symlinkAttributes, before_links))
			helpers.assert_true(rawequal(rawget(package.loaded, "modules.keymap.registry"), before_registry))
			helpers.assert_nil(require("lfs").symlinkattributes(path))
		end)
	end)
end)
