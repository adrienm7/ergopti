--- tests/unit/meta/test_list_providers_cover_manifest.lua

--- ==============================================================================
--- MODULE: Every List The Manifest Promises Linux Has A Provider
--- DESCRIPTION:
--- A `list` row is the one manifest type whose contents the driver supplies:
--- the renderer draws it and asks the driver for the rows. A list declared for
--- this platform with no provider registered is SKIPPED with a warning, so the
--- submenu simply loses a section.
---
--- WHY THAT IS WORSE THAN A CRASH:
--- Nothing errors, the menu opens, and the missing section is visible only to
--- somebody comparing against another platform side by side. The renderer\'s own
--- comment says as much where it skips: "Silence here is a menu section that
--- vanishes."
---
--- THE DIRECTION THIS GUARDS:
--- Declaring a row for a platform is cheap and satisfying; wiring the provider
--- is the work. This makes the declaration fail until the work is done, which is
--- the only order that keeps the manifest a description rather than a wish.
--- ==============================================================================

local helpers = require("tests.helpers")

local Paths = helpers.load_module("infra.paths")

--- Every `list` id the built manifest declares for this platform.
--- @return table Array of { menu = string, id = string }.
local function declared_lists()
	local root = Paths.shared_root()
	helpers.assert_not_nil(root, "the shared tree must be findable")
	local handle = assert(io.open(root .. "/modules/menu/menu_manifest.json", "r"))
	local body = handle:read("*a")
	handle:close()

	local Json = require("json")
	local manifest = Json.decode(body)
	helpers.assert_eq(type(manifest), "table", "the built menu manifest must decode")

	local out = {}
	for menu_key, rows in pairs(manifest) do
		if type(rows) == "table" and #rows > 0 then
			for _, row in ipairs(rows) do
				if type(row) == "table" and row.type == "list" and type(row.id) == "string" then
					-- No `platforms` means every platform, which is how the renderer
					-- reads it too.
					local allowed = true
					if type(row.platforms) == "table" then
						allowed = false
						for _, name in ipairs(row.platforms) do
							if name == "linux" then allowed = true end
						end
					end
					if allowed then out[#out + 1] = { menu = menu_key, id = row.id } end
				end
			end
		end
	end
	return out
end

--- Follows the real native closure into the shared factory and canonical renderer.
--- A declaration alone never grants credit: its actual callable provider must run
--- inside a successful factory result reached through the native layout frame.
local function genuine_shared_providers(damage)
	local loaded, getenv = {}, os.getenv
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu",
		"ui.menu.menu_builder", "keymap.magic_key_source", "modules.hotstrings.magic_key_source",
		"infra.hotstring_preferences", "modules.shortcuts.tap_keys", "infra.config_paths",
		"adapters.storage", "modules.keymap.layout_registry", "modules.hotstrings.input_reader",
		"menu.renderer", "infra.paths", "json" }
	local directory, path, filesystem, directory_created
	local found, restore = {}, function() end
	local ok, result = xpcall(function()
		directory = os.tmpname()
		assert(os.remove(directory))
		filesystem = require("lfs")
		assert(filesystem.mkdir(directory)); directory_created = true
		path = directory .. "/config.toml"
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" or name == "XDG_DATA_HOME" or name == "XDG_STATE_HOME" then return directory end
			return getenv(name)
		end
		for _, name in ipairs(names) do package.loaded[name] = nil end
		local file = assert(io.open(path, "wb"))
		local written, write_error = file:write('[hotstrings]\nmagic_key_source = "auto"\n')
		local closed, close_error = file:close()
		assert(written, write_error); assert(closed, close_error)
		local native = require("infra.i18n"); native.init()
		local manifest = require("infra.manifest_menu")
		local shared = require("keymap.magic_key_source")
		local preferences = require("infra.hotstring_preferences")
		assert(preferences._set_file_for_test(path))
		local source = require("modules.hotstrings.magic_key_source")
		assert(source.get() == "auto")
		local builder = require("ui.menu.menu_builder")
		local layout, slot
		for index = 1, 100 do
			local name, value = debug.getupvalue(builder.build, index)
			if not name then break end
			if name == "_build_layouts" then layout, slot = value, index end
		end
		assert(type(layout) == "function" and slot ~= nil, "the native registered layout closure is required")
		local build, template, factory = manifest.build, manifest.template_rows, shared.menu_rows
		local root = manifest.get_root()
		local saved_children, saved_frame = root.magic_key_source_children, root.magic_key_source_menu
		local depth, receipt, reached = 0, {}, false
		restore = function()
			manifest.build, manifest.template_rows, shared.menu_rows = build, template, factory
			root.magic_key_source_children, root.magic_key_source_menu = saved_children, saved_frame
			debug.setupvalue(builder.build, slot, layout)
		end
		manifest.template_rows = function(key, commands, getters, providers)
			local invoked, delegated = {}, {}
			for id, provider in pairs(providers or {}) do
				delegated[id] = type(provider) == "function" and function(...)
					local rows = provider(...)
					if type(rows) == "table" then invoked[id] = true end
					return rows
				end or provider
			end
			local rows = template(key, commands, getters, delegated)
			if depth > 0 and type(rows) == "table" then
				for _, entry in ipairs(manifest.get_array(key)) do
					if entry.type == "list" and invoked[entry.id] == true then receipt[entry.id] = true end
				end
			end
			return rows
		end
		shared.menu_rows = function(...)
			depth, receipt = depth + 1, {}
			local rows = factory(...)
			depth = depth - 1
			if type(rows) == "table" and #rows > 0 then
				for id in pairs(receipt) do found[id] = true end
			end
			return rows
		end
		manifest.build = function(key, ...)
			if key == "layout_menu" then reached = true end
			return build(key, ...)
		end
		if damage then damage(builder, slot, shared, manifest, root) end
		local active_layout = select(2, debug.getupvalue(builder.build, slot))
		local rows = active_layout({ magic_key_source = source })
		if not reached or type(rows) ~= "table" or type(rows.submenu) ~= "table" or #rows.submenu == 0 then return {} end
		local current = assert(io.open(path, "rb")); local bytes = assert(current:read("*a")); assert(current:close())
		assert(bytes == '[hotstrings]\nmagic_key_source = "auto"\n', "menu capture cannot publish")
		return found
	end, debug.traceback)
	local cleaned, cleanup_error = pcall(restore)
	os.getenv = getenv
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	local file = path and io.open(path, "rb")
	if file then assert(file:close()); assert(os.remove(path)) end
	if directory_created then assert(filesystem.rmdir(directory)) end
	assert(rawequal(os.getenv, getenv))
	for name, value in pairs(loaded) do assert(rawequal(package.loaded[name], value), name) end
	for name in pairs(package.loaded) do assert(loaded[name] ~= nil, name) end
	if not cleaned then error(cleanup_error, 0) end
	if ok then return result, nil end
	return {}, result
end

--- Observes the real Hotstrings closure's conditional trigger provider. The
--- custom source makes the reset leaf reachable; an empty replacement cannot
--- receive the credit a genuine default-only source intentionally does not need.
local function genuine_trigger_providers(damage, default_source)
	local loaded, getenv = {}, os.getenv
	local original_i18n_safe = rawget(_G, "i18n_safe")
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu",
		"ui.menu.menu_builder", "modules.hotstrings.magic_key", "infra.manifest_reader",
		"infra.hotstring_preferences", "infra.config_paths", "adapters.storage",
		"menu.renderer", "infra.paths", "json" }
	local directory, path, filesystem, directory_created
	local restore, found = function() end, {}
	local observed = { provider_calls = 0, reset_rows = 0, effects = 0 }
	local bytes = '[hotstrings]\nmagic_key_source = "auto"\n'
	if not default_source then bytes = bytes .. 'trigger_char = "§"\n' end
	local ok, result = xpcall(function()
		directory = os.tmpname(); assert(os.remove(directory))
		filesystem = require("lfs")
		assert(filesystem.mkdir(directory)); directory_created = true
		path = directory .. "/config.toml"
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" or name == "XDG_DATA_HOME" or name == "XDG_STATE_HOME" then return directory end
			return getenv(name)
		end
		for _, name in ipairs(names) do package.loaded[name] = nil end
		local file = assert(io.open(path, "wb"))
		local written, write_error = file:write(bytes)
		local closed, close_error = file:close()
		assert(written, write_error); assert(closed, close_error)
		require("infra.i18n").init()
		local manifest = require("infra.manifest_menu")
		assert(require("infra.hotstring_preferences")._set_file_for_test(path))
		local magic = require("modules.hotstrings.magic_key")
		assert(magic.is_customised() == not default_source)
		if not default_source then assert(magic.get() == "§") end
		local builder = require("ui.menu.menu_builder")
		local function upvalue(owner, wanted)
			for index = 1, 100 do
				local name, value = debug.getupvalue(owner, index)
				if not name then break end
				if name == wanted then return value, index end
			end
		end
		local hotstrings, slot = upvalue(builder.build, "_build_hotstrings")
		assert(type(hotstrings) == "function" and slot, "actual registered Hotstrings closure is required")
		local body, body_slot = upvalue(hotstrings, "_manifest_hotstring_rows")
		assert(type(body) == "function" and body_slot, "actual Hotstrings manifest body is required")
		local build, template, root = manifest.build, manifest.template_rows, manifest.get_root()
		local frames = { "hotstrings_magic_trigger_frame", "hotstrings_magic_trigger_reset", "hotstrings_params_group" }
		local saved = {}; for _, key in ipairs(frames) do saved[key] = root[key] end
		local set, reset = magic.set, magic.reset
		restore = function()
			manifest.build, manifest.template_rows = build, template
			magic.set, magic.reset = set, reset
			for _, key in ipairs(frames) do root[key] = saved[key] end
			debug.setupvalue(builder.build, slot, hotstrings)
			debug.setupvalue(hotstrings, body_slot, body)
		end
		magic.set = function(...) observed.effects = observed.effects + 1; return set(...) end
		magic.reset = function(...) observed.effects = observed.effects + 1; return reset(...) end
		local depth, pending, consumed, reset_leaf = 0, {}, {}, nil
		local function contains(rows, wanted)
			if type(rows) ~= "table" then return false end
			for _, row in ipairs(rows) do
				if type(row) == "table" then
					if rawequal(row.action or row.fn, wanted) then return true end
					if contains(row.items or row.submenu or row.menu, wanted) then return true end
				end
			end
			return false
		end
		manifest.template_rows = function(key, commands, getters, providers)
			local invoked, delegated = {}, {}
			for id, provider in pairs(providers or {}) do
				delegated[id] = type(provider) == "function" and function(...)
					local supplied = provider(...)
					if key == "hotstrings_magic_trigger_frame" then
						observed.provider_calls = observed.provider_calls + 1
						if type(supplied) == "table" then observed.reset_rows = #supplied end
					end
					if type(supplied) == "table" and reset_leaf and contains(supplied, reset_leaf.action) then invoked[id] = true end
					return supplied
				end or provider
			end
			local rows = template(key, commands, getters, delegated)
			if key == "hotstrings_magic_trigger_reset" and type(rows) == "table" and #rows == 1
				and type(commands) == "table" and type(commands.magic_key_reset) == "function"
				and type(rows[1].action) == "function" then reset_leaf = rows[1] end
			if key == "hotstrings_magic_trigger_frame" and depth > 0 and reset_leaf and contains(rows, reset_leaf.action) then
				for _, entry in ipairs(manifest.get_array(key)) do
					if entry.type == "list" and invoked[entry.id] then pending[entry.id] = true end
				end
			end
			return rows
		end
		manifest.build = function(key, ...)
			if key ~= "hotstrings_params_group" then return build(key, ...) end
			depth = depth + 1
			local rows = build(key, ...)
			depth = depth - 1
			if reset_leaf and contains(rows, reset_leaf.action) then
				for id in pairs(pending) do consumed[id] = true end
			end
			return rows
		end
		if damage then damage(builder, slot, hotstrings, body_slot, manifest, root) end
		local active = select(2, debug.getupvalue(builder.build, slot))
		local active_body = select(2, debug.getupvalue(hotstrings, body_slot))
		if rawequal(active, hotstrings) and rawequal(active_body, body) then
			local config = { any_enabled = function() return false end,
				get_categories = function() return {} end, get_groups = function() return {} end }
			local rows = active({ config = config, state = {}, paused = false,
				on_menu_changed = function() observed.effects = observed.effects + 1 end })
			if reset_leaf and type(rows) == "table" and contains(rows.submenu, reset_leaf.action) then
				for id in pairs(consumed) do found[id] = true end
			end
		end
		local current = assert(io.open(path, "rb"))
		local actual = assert(current:read("*a")); assert(current:close())
		assert(actual == bytes, "provider evidence cannot publish preferences")
		assert(observed.effects == 0, "provider evidence cannot invoke callbacks")
		return found
	end, debug.traceback)
	local cleaned, cleanup_error = pcall(restore)
	rawset(_G, "i18n_safe", original_i18n_safe)
	os.getenv = getenv
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	local file = path and io.open(path, "rb")
	if file then assert(file:close()); assert(os.remove(path)) end
	if directory_created then assert(filesystem.rmdir(directory)) end
	assert(rawequal(os.getenv, getenv))
	assert(rawequal(rawget(_G, "i18n_safe"), original_i18n_safe))
	for name, value in pairs(loaded) do assert(rawequal(package.loaded[name], value), name) end
	for name in pairs(package.loaded) do assert(loaded[name] ~= nil, name) end
	if not cleaned then error(cleanup_error, 0) end
	if ok then return result, nil, observed end
	return {}, result, observed
end

--- Observes the actual gesture closure, native status producer and typed list.
--- Credit remains pending until the same cached leaf callback survives the
--- successfully returned registered native closure and rendered status subtree.
local function genuine_gesture_providers(damage)
	local loaded, getenv = {}, os.getenv
	local original_i18n_safe = rawget(_G, "i18n_safe")
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu",
		"ui.menu.menu_builder", "ui.gesture_conflicts", "modules.gestures.manager",
		"adapters.storage", "infra.paths", "json", "menu.renderer" }
	local directory, filesystem, created
	local restore = function() end
	local observed = { calls = 0, effects = 0, status_calls = 0 }
	local ok, result = xpcall(function()
		directory = os.tmpname(); assert(os.remove(directory))
		filesystem = require("lfs"); assert(filesystem.mkdir(directory)); created = true
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" or name == "XDG_DATA_HOME" or name == "XDG_STATE_HOME" then return directory end
			if name == "XDG_CURRENT_DESKTOP" or name == "DESKTOP_SESSION" then return "" end
			return getenv(name)
		end
		for _, name in ipairs(names) do package.loaded[name] = nil end
		require("infra.i18n").init()
		local manifest = require("infra.manifest_menu")
		local native = require("modules.gestures.manager")
		local producer = require("ui.gesture_conflicts")
		local builder = require("ui.menu.menu_builder")
		local closure, slot
		for index = 1, 100 do
			local name, value = debug.getupvalue(builder.build, index)
			if name == nil then break end
			if name == "_build_gestures" then closure, slot = value, index break end
		end
		assert(type(closure) == "function" and slot ~= nil, "the registered native gesture closure is required")
		local selected
		for name in pairs(native.DEFAULT_GESTURES) do
			if name:match("^(%a+_%d+)") and (selected == nil or name < selected) then selected = name end
		end
		assert(type(selected) == "string", "the genuine native gesture catalogue contains a grouped slot")
		local gestures = { DEFAULT_GESTURES = native.DEFAULT_GESTURES,
			is_enabled = function() return true end, is_reading = function() return false end,
			get_action = function(name) return name == selected and "copy" or "none" end,
			get_action_label = native.get_action_label,
			toggle = function() observed.effects = observed.effects + 1 end,
			set_action = function() observed.effects = observed.effects + 1 end }
		local build, template, rows_owner, settings = manifest.build, manifest.template_rows, producer.rows, producer.open_settings
		local root = manifest.get_root()
		local frames = { "gesture_system_slot_linux_frame", "gesture_system_linux_children", "gesture_system_status_linux_frame" }
		local saved = {}; for _, key in ipairs(frames) do saved[key] = root[key] end
		local leaf, consumed, successful_status, reached = nil, false, false, false
		local pending = {}
		local function contains(rows, callback)
			if type(rows) ~= "table" or type(callback) ~= "function" then return false end
			for _, row in ipairs(rows) do
				if type(row) == "table" then
					if rawequal(row.action or row.fn, callback) then return true end
					if contains(row.items or row.submenu or row.menu, callback) then return true end
				end
			end
			return false
		end
		restore = function()
			manifest.build, manifest.template_rows, producer.rows, producer.open_settings = build, template, rows_owner, settings
			for _, key in ipairs(frames) do root[key] = saved[key] end
			debug.setupvalue(builder.build, slot, closure)
		end
		producer.open_settings = function() observed.effects = observed.effects + 1; return false end
		manifest.template_rows = function(key, commands, getters, providers)
			local delegated, invoked = {}, false
			for id, provider in pairs(providers or {}) do
				delegated[id] = type(provider) == "function" and function(...)
					local supplied = provider(...)
					if key == "gesture_system_linux_children" and id == "gesture_system_cached_overlap" then
						observed.calls = observed.calls + 1
						invoked = leaf ~= nil and contains(supplied, leaf)
					end
					return supplied
				end or provider
			end
			local rows = template(key, commands, getters, delegated)
			if key == "gesture_system_slot_linux_frame" and type(rows) == "table" and #rows == 1
				and type(commands) == "table" and type(commands.gesture_system_open_unknown_slot) == "function"
				and type(rows[1].action) == "function" then leaf = rows[1].action end
			if key == "gesture_system_linux_children" and invoked and contains(rows, leaf) then
				consumed = true
				for _, entry in ipairs(manifest.get_array(key)) do
					if entry.type == "list" and entry.id == "gesture_system_cached_overlap" then pending[entry.id] = true end
				end
			end
			if key == "gesture_system_status_linux_frame" then
				observed.status_calls = observed.status_calls + 1
				successful_status = consumed and type(rows) == "table" and #rows == 1 and contains(rows, leaf)
			end
			return rows
		end
		local witnessed_rows = function(...)
			local rows = rows_owner(...)
			if not contains(rows, leaf) then successful_status = false end
			return rows
		end
		producer.rows = witnessed_rows
		manifest.build = function(key, ...)
			local rows = build(key, ...)
			if key == "gestures_menu" then reached = contains(rows, leaf) end
			return rows
		end
		if damage then damage(builder, slot, producer, manifest, root) end
		local active = select(2, debug.getupvalue(builder.build, slot))
		local result_rows = active({ gestures = gestures, paused = false,
			on_menu_changed = function() observed.effects = observed.effects + 1 end })
		local current = rawequal(active, closure) and rawequal(producer.rows, witnessed_rows)
			and rawequal(package.loaded["ui.gesture_conflicts"], producer)
		for _, key in ipairs(frames) do current = current and rawequal(root[key], saved[key]) end
		assert(observed.effects == 0, "coverage evidence cannot open settings or publish")
		if current and consumed and successful_status and reached and type(result_rows) == "table"
			and contains(result_rows.submenu, leaf) then return pending end
		return {}
	end, debug.traceback)
	local cleaned, cleanup_error = pcall(restore)
	os.getenv = getenv; rawset(_G, "i18n_safe", original_i18n_safe)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if created then assert(filesystem.rmdir(directory)) end
	assert(rawequal(os.getenv, getenv) and rawequal(rawget(_G, "i18n_safe"), original_i18n_safe))
	for name, value in pairs(loaded) do assert(rawequal(package.loaded[name], value), name) end
	for name in pairs(package.loaded) do assert(loaded[name] ~= nil, name) end
	if not cleaned then error(cleanup_error, 0) end
	if ok then return result, nil, observed end
	return {}, result, observed
end

--- Follows the registered Hotstrings closure through its actual language producer
--- and canonical list renderer. A provider name alone grants no coverage: both
--- declared lists must yield native callbacks consumed by the returned language
--- parent and by the successful native Hotstrings result.
local function genuine_language_providers(damage, exercise)
	local loaded, getenv, original_safe = {}, os.getenv, rawget(_G, "i18n_safe")
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu",
		"ui.menu.menu_builder", "infra.paths", "json", "menu.renderer",
		"infra.hotstring_preferences", "infra.config_paths", "adapters.storage",
		"modules.hotstrings.magic_key", "modules.hotstrings.magic_key_source" }
	local directory, path, filesystem, created
	local restore = function() end
	local observed = { switch_calls = 0, category_calls = 0, effects = 0,
		audit_events = {}, audit_notifications = 0, publication_calls = 0 }
	local bytes = '[hotstrings]\nmagic_key_source = "auto"\n'
	local ok, result = xpcall(function()
		directory = os.tmpname(); assert(os.remove(directory))
		filesystem = require("lfs"); assert(filesystem.mkdir(directory)); created = true
		path = directory .. "/config.toml"
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" or name == "XDG_DATA_HOME" or name == "XDG_STATE_HOME" then return directory end
			return getenv(name)
		end
		for _, name in ipairs(names) do package.loaded[name] = nil end
		local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
		require("infra.i18n").init()
		assert(require("infra.hotstring_preferences")._set_file_for_test(path))
		local manifest, builder = require("infra.manifest_menu"), require("ui.menu.menu_builder")
		local function upvalue(owner, wanted)
			if type(owner) ~= "function" then return nil end
			for index = 1, 100 do
				local name, value = debug.getupvalue(owner, index)
				if not name then break end
				if name == wanted then return value, index end
			end
		end
		local closure, slot = upvalue(builder.build, "_build_hotstrings")
		assert(type(closure) == "function" and slot, "the registered native Hotstrings closure is required")
		local body, body_slot = upvalue(closure, "_manifest_hotstring_rows")
		assert(type(body) == "function" and body_slot, "the actual native Hotstrings body is required")
		local root, build, template, check, render = manifest.get_root(), manifest.build,
			manifest.template_rows, manifest.check_row, manifest.render_rows
		local frames = { "hotstring_language_frame", "hotstring_language_parent_lua", "hotstring_scope_checkbox", "hotstrings_menu", "top_level" }
		local saved = {}; for _, key in ipairs(frames) do saved[key] = root[key] end
		local notification, notification_slot = upvalue(body, "show_error")
		assert(type(notification) == "function" and notification_slot, "the actual refusal notification port is required")
		restore = function()
			manifest.build, manifest.template_rows, manifest.check_row = build, template, check
			manifest.render_rows = render
			for _, key in ipairs(frames) do root[key] = saved[key] end
			debug.setupvalue(builder.build, slot, closure)
			debug.setupvalue(closure, body_slot, body)
			debug.setupvalue(body, notification_slot, notification)
		end
		-- Use the actual declared Hotstrings row unchanged, through the genuine
		-- public registration and final renderer. Other tray owners are outside
		-- this bounded input, so their declarations are not exercised here.
		local declared
		for _, row in ipairs(manifest.get_array("top_level")) do
			if row.id == "hotstrings" then declared = row end
		end
		assert(type(declared) == "table", "the actual top-level Hotstrings declaration is required")
		root.top_level = { declared }
		-- Independently authored catalogue input; all menu/list/callback producers
		-- remain the genuine production functions. These callbacks record targets,
		-- not native storage publication or runtime admission.
		local categories = {
			french_magickey = { id = "french_magickey", count = 7,
				sections = { beta = { count = 7 } }, sections_order = { "beta" } },
			french_autocorrection = { id = "french_autocorrection", count = 3,
				sections = { alpha = { count = 3 } }, sections_order = { "alpha" } },
		}
		local audit, acknowledgement = false, true
		local config = {
			get_groups = function() return { "french_magickey", "french_autocorrection" } end,
			get_categories = function() return categories end,
			get_category = function(id) return categories[id] end,
			is_group_enabled = function() return true end,
			is_section_enabled = function() return true end,
			language_packs = function()
				return { { id = "french", locale = "fr", categories = { "magickey", "absent", "autocorrection" } } }
			end,
			set_categories_sections = function(ids, enabled)
				if audit then
					observed.audit_events[#observed.audit_events + 1] = {
						kind = "scope", selected = table.concat(ids, ","), enabled = enabled }
					return acknowledgement
				end
				observed.effects = observed.effects + 1
				observed.selected, observed.enabled = table.concat(ids, ","), enabled
				return true
			end,
			toggle_section = function(id, section)
				if audit then
					observed.audit_events[#observed.audit_events + 1] = { kind = "section", category = id, section = section }
					return acknowledgement
				end
				observed.effects = observed.effects + 1
				observed.category, observed.section = id, section
				return true
			end,
			set_category_scope_enabled = function(ids, enabled)
				assert(audit, "category scope is exercised only in the explicit target audit")
				observed.audit_events[#observed.audit_events + 1] = {
					kind = "category_scope", selected = table.concat(ids, ","), enabled = enabled }
				return acknowledgement
			end,
			resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
			get_global_delay = function() return 0.75 end,
			has_global_delay_override = function() return false end,
		}
		local function contains(rows, callback)
			if type(rows) ~= "table" or type(callback) ~= "function" then return false end
			for _, row in ipairs(rows) do
				if type(row) == "table" then
					if rawequal(row.action or row.fn, callback) then return true end
					if contains(row.items or row.submenu or row.menu, callback) then return true end
				end
			end
			return false
		end
		local function native_callback(callback)
			return type(callback) == "function" and rawequal(upvalue(callback, "config"), config)
				and debug.getinfo(callback, "S").source == debug.getinfo(body, "S").source
		end
		local native_switches = {}
		manifest.check_row = function(key, id, commands, getters)
			local row = check(key, id, commands, getters)
			local owner = type(commands) == "table" and commands.hotstring_scope_all_sections or nil
			if key == "hotstring_scope_checkbox" and id == "hotstring_scope_all_sections"
				and native_callback(owner) and type(row) == "table" and type(row.action) == "function" then
				-- The canonical checkbox deliberately wraps the native action with
				-- its retained readiness check. Preserve and prove that exact wrapper.
				native_switches[row.action] = owner
			end
			return row
		end
		local switch, category_callbacks, category_actions, rendered_frame, parent, pending = nil, nil, nil, nil, nil, {}
		local category_owners = {}
		manifest.template_rows = function(key, commands, getters, providers)
			local delegated, supplied = {}, {}
			for id, provider in pairs(providers or {}) do
				delegated[id] = type(provider) == "function" and function(...)
					local rows = provider(...)
					if key == "hotstring_language_frame" then
						if id == "hotstring_language_switch" then observed.switch_calls = observed.switch_calls + 1 end
						if id == "hotstring_language_categories" then observed.category_calls = observed.category_calls + 1 end
						supplied[id] = rows
					end
					return rows
				end or provider
			end
			local rows = template(key, commands, getters, delegated)
			if key == "hotstring_language_frame" then
				local switches, sections = supplied.hotstring_language_switch, supplied.hotstring_language_categories
				if type(switches) == "table" and #switches == 1 and type(sections) == "table" and #sections == 2 then
					local action = switches[1].action or switches[1].fn
					local owner = native_switches[action]
					local ids = upvalue(owner, "ids")
					local valid = native_callback(owner) and type(ids) == "table"
						and table.concat(ids, ",") == "french_magickey,french_absent,french_autocorrection"
						and contains(rows, action)
					local callbacks, actions = {}, {}
					for index, expected in ipairs({ { "french_magickey", "beta" }, { "french_autocorrection", "alpha" } }) do
						local row = sections[index]
						local children = type(row) == "table" and (row.submenu or row.menu or row.items) or nil
						local leaf, enable, disable, actionable = nil, nil, nil, 0
						for _, child in ipairs(children or {}) do
							local callback = child.action or child.fn
							if type(callback) == "function" then actionable = actionable + 1 end
							if native_callback(callback) and upvalue(callback, "id") == expected[1]
								and upvalue(callback, "name") == expected[2] then leaf = callback end
							local owner = category_owners[callback]
							if owner and owner.id == expected[1] then
								if owner.enabled == true then enable = callback else disable = callback end
							end
						end
						callbacks[index] = leaf
						actions[index] = { leaf, enable, disable }
						valid = valid and actionable == 3 and leaf ~= nil and enable ~= nil and disable ~= nil
							and contains(rows, leaf) and contains(rows, enable) and contains(rows, disable)
					end
					if valid and type(root.hotstring_language_frame) == "table" then
						switch, category_callbacks, category_actions, rendered_frame = action, callbacks, actions, rows
						for _, entry in ipairs(manifest.get_array(key)) do
							if entry.type == "list" and supplied[entry.id]
								and (entry.id == "hotstring_language_switch" or entry.id == "hotstring_language_categories") then
								pending[entry.id] = true
							end
						end
					end
				end
			elseif key == "hotstring_language_parent_lua" and rendered_frame and switch
				and type(root.hotstring_language_frame) == "table" and type(root.hotstring_language_parent_lua) == "table"
				and contains(rows, switch) and contains(rows, category_callbacks[1]) and contains(rows, category_callbacks[2]) then
				parent = rows
			end
			return rows
		end
		local consumed, reached = false, false
		manifest.build = function(key, ...)
			local arguments = { ... }
			local commands = type(arguments[4]) == "table" and arguments[4].commands or nil
			local rows = build(key, ...)
			if key == "hotstring_category_menu" and type(commands) == "table" then
				for _, command in ipairs({ { "hotstring_category_enable_all", true }, { "hotstring_category_disable_all", false } }) do
					local callback = commands[command[1]]
					local owner = upvalue(callback, "commit_scope")
					local id = upvalue(owner, "id")
					if native_callback(owner) and categories[id] ~= nil and contains(rows, callback) then
						category_owners[callback] = { id = id, enabled = command[2] }
					end
				end
			end
			if key == "hotstrings_menu" then
				reached = true
				consumed = parent ~= nil and contains(rows, switch)
					and contains(rows, category_callbacks[1]) and contains(rows, category_callbacks[2])
			end
			return rows
		end
		local published
		manifest.render_rows = function(rows, key, ...)
			local result = render(rows, key, ...)
			if key == "top_level" then
				observed.publication_calls = observed.publication_calls + 1
				if consumed and contains(rows, switch) and contains(rows, category_callbacks[1])
					and contains(rows, category_callbacks[2]) and contains(result, switch)
					and contains(result, category_callbacks[1]) and contains(result, category_callbacks[2]) then
					published = result
				end
			end
			return result
		end
		if damage then damage(builder, slot, closure, body_slot, manifest, root) end
		local active, active_body = select(2, debug.getupvalue(builder.build, slot)), select(2, debug.getupvalue(closure, body_slot))
		local found = {}
		if type(active) == "function" then
			local rows = builder.build({ config = config, _version = "provider-evidence",
				on_menu_changed = function() observed.effects = observed.effects + 1 end })
			if rawequal(active, closure) and rawequal(active_body, body) and reached and consumed and published
				and type(root.hotstring_language_frame) == "table"
				and type(root.hotstring_language_parent_lua) == "table" and type(root.hotstrings_menu) == "table"
				and type(rows) == "table" and contains(rows, switch)
				and contains(rows, category_callbacks[1]) and contains(rows, category_callbacks[2]) then
				-- Invoke only callbacks retained in the actual public publication.
				-- Recorders prove target/acknowledgement behavior without claiming
				-- native storage effects. The notification port alone is recorded.
				local function retained(list, wanted)
					for _, row in ipairs(list or {}) do
						if rawequal(row.fn or row.action, wanted) then return row.fn or row.action end
						local callback = retained(row.menu or row.submenu or row.items, wanted)
						if callback then return callback end
					end
				end
				switch = assert(retained(rows, switch))
				for index, callback in ipairs(category_callbacks) do category_callbacks[index] = assert(retained(rows, callback)) end
				for _, callbacks in ipairs(category_actions) do
					for index, callback in ipairs(callbacks) do callbacks[index] = assert(retained(rows, callback)) end
				end
				audit = true
				debug.setupvalue(body, notification_slot, function() observed.audit_notifications = observed.audit_notifications + 1 end)
				local function scope_event(before)
					assert(#observed.audit_events == before + 1, "scope callback reaches exactly one target")
					local event = observed.audit_events[#observed.audit_events]
					assert(event.kind == "scope" and event.selected == "french_magickey,french_absent,french_autocorrection"
						and event.enabled == false, "retained scope callback dispatches exact independently authored targets")
				end
				local checkbox = root.hotstring_scope_checkbox
				assert(manifest.resolve_disabled_when("hotstring_scope_checkbox", "hotstring_scope_all_sections", {}) == false)
				root.hotstring_scope_checkbox = nil
				assert(manifest.resolve_disabled_when("hotstring_scope_checkbox", "hotstring_scope_all_sections", {}) == true)
				local before = #observed.audit_events
				assert(switch() == false, "retained canonical wrapper refuses withdrawn actual declaration")
				assert(#observed.audit_events == before, "canonical readiness refusal reaches no scope target")
				observed.readiness_refused = true
				root.hotstring_scope_checkbox = checkbox
				assert(manifest.resolve_disabled_when("hotstring_scope_checkbox", "hotstring_scope_all_sections", {}) == false)
				assert(switch() == true); scope_event(before)
				observed.readiness_recovered = true
				acknowledgement = false; before = #observed.audit_events
				assert(switch() == false, "scope refuses a non-acknowledged target result"); scope_event(before)
				for index, expected in ipairs({ { "french_magickey", "beta" }, { "french_autocorrection", "alpha" } }) do
					for action_index, callback in ipairs(category_actions[index]) do
						for _, accepted in ipairs({ true, false }) do
							acknowledgement = accepted; before = #observed.audit_events
							assert(callback() == accepted, "each retained category callback respects target acknowledgement")
							assert(#observed.audit_events == before + 1, "each category callback reaches exactly one target")
							local event = observed.audit_events[#observed.audit_events]
							if action_index == 1 then
								assert(event.kind == "section" and event.category == expected[1] and event.section == expected[2],
									"every actual retained section callback dispatches its independently authored exact target")
							else
								assert(event.kind == "category_scope" and event.selected == expected[1] and event.enabled == (action_index == 2),
									"every actual retained category scope callback dispatches its independently authored exact target")
							end
						end
					end
				end
				assert(observed.audit_notifications == 7, "only non-acknowledged target results reach the refusal notification port")
				acknowledgement, audit = true, false
				debug.setupvalue(body, notification_slot, notification)
				for id in pairs(pending) do found[id] = true end
			end
		end
		assert(observed.effects == 0, "building provider evidence cannot publish or invoke callbacks")
		if exercise and found.hotstring_language_switch and found.hotstring_language_categories then
			assert(switch() == true); assert(category_callbacks[1]() == true)
		end
		local current = assert(io.open(path, "rb")); local actual = assert(current:read("*a")); assert(current:close())
		assert(actual == bytes, "provider evidence cannot write native preferences")
		return found
	end, debug.traceback)
	local cleaned, cleanup_error = pcall(restore)
	os.getenv = getenv; rawset(_G, "i18n_safe", original_safe)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	local file = path and io.open(path, "rb")
	if file then assert(file:close()); assert(os.remove(path)) end
	if created then assert(filesystem.rmdir(directory)) end
	assert(rawequal(os.getenv, getenv) and rawequal(rawget(_G, "i18n_safe"), original_safe))
	for name, value in pairs(loaded) do assert(rawequal(package.loaded[name], value), name) end
	for name in pairs(package.loaded) do assert(loaded[name] ~= nil, name) end
	if not cleaned then error(cleanup_error, 0) end
	if ok then return result, nil, observed end
	return {}, result, observed
end

--- Every list id the menu builder registers a provider for.
--- @return table Set of ids.
local function registered_providers(omitted_delegate)
	local handle = assert(io.open(helpers.driver_root() .. "/ui/menu/menu_builder.lua", "r"))
	local source = handle:read("*a")
	handle:close()
	-- Providers may be owned by a directly required native menu module. Scan
	-- those actual delegates, rather than every source file in the tree.
	local sources, visited = { source }, { ["ui.menu.menu_builder"] = true }
	local index = 1
	while index <= #sources do
		for name in sources[index]:gmatch('require%("(ui%.menu%.[a-z0-9_%.]+)"%)') do
			if not visited[name] and name ~= omitted_delegate then
				visited[name] = true
				local delegate = assert(io.open(helpers.driver_root() .. "/" .. name:gsub("%.", "/") .. ".lua", "r"))
				sources[#sources + 1] = assert(delegate:read("*a")); assert(delegate:close())
			end
		end
		index = index + 1
	end
	local found = {}
	-- Deliberately broad: a bracketed string key assigned anything. The file
	-- registers providers three ways — inside a table literal, as
	-- `providers["id"] = function`, and as `["id"] = rows` pointing at a named
	-- local — and a pattern narrow enough to tell them apart reported a provider
	-- that exists as missing the first time this ran.
	--
	-- Breadth costs precision in one direction only: an id used as a key for
	-- something that is NOT a provider would satisfy it. That is intersected with
	-- the declared LIST ids below, so it would take a dynamic handler and a list
	-- sharing one id, which the manifest does not do.
	for _, registered_source in ipairs(sources) do
		for id in registered_source:gmatch('%["([a-z0-9_]+)"%]%s*=') do found[id] = true end
		for id in registered_source:gmatch('providers%.([a-z0-9_]+)%s*=') do found[id] = true end
	end
	if omitted_delegate ~= "keymap.magic_key_source" then
		for id in pairs(genuine_shared_providers()) do found[id] = true end
	end
	for id in pairs(genuine_trigger_providers()) do found[id] = true end
	-- Scoped language lists need executed native evidence even if a future
	-- spelling happens to match the broad lexical inventory above.
	local language = genuine_language_providers()
	for _, entry in ipairs(declared_lists()) do
		if entry.menu == "hotstring_language_frame" then
			found[entry.id] = language[entry.id] == true or nil
		end
	end
	if omitted_delegate ~= "ui.gesture_conflicts" then
		for id in pairs(genuine_gesture_providers()) do found[id] = true end
	end
	return found
end




-- =================================================================
-- =================================================================
-- ======= 1/ Coverage =============================================
-- =================================================================
-- =================================================================

helpers.describe("menu lists: what the manifest promises this platform", function()

	helpers.it("registers a provider for every list declared for linux", function()
		local lists = declared_lists()
		local providers = registered_providers()

		helpers.assert_true(#lists > 0,
			"no list rows were found for this platform — the manifest moved or the "
				.. "scan broke, and a scan that finds nothing agrees with any driver")

		local missing = {}
		for _, entry in ipairs(lists) do
			if not providers[entry.id] then
				missing[#missing + 1] = entry.menu .. "." .. entry.id
			end
		end
		table.sort(missing)
		helpers.assert_eq(#missing, 0,
			"declared for linux with no provider: " .. table.concat(missing, ", ")
				.. ". The renderer skips such a row with a warning, so the submenu "
				.. "loses a whole section and nothing errors — visible only to "
				.. "somebody comparing against another platform side by side.")
	end)

	helpers.it("includes the configurable keyboard slots", function()
		-- Named explicitly as well as covered by the sweep above, because this row
		-- was restricted away from linux for a year with an accurate reason, and
		-- the sweep alone would go quiet again the moment somebody restricted it
		-- back rather than fixing whatever broke.
		local found = false
		for _, entry in ipairs(declared_lists()) do
			if entry.id == "keyboard_slots" then found = true end
		end
		helpers.assert_true(found,
			"keyboard_slots is the row this driver could not answer until it had a "
				.. "chord capture and an assignment store; it has both now")
	end)

end)

helpers.describe("actual delegated ordered-pair list coverage", function()
	helpers.it("requires the actual production delegate for all three declared lists", function()
		local current, omitted = registered_providers(), registered_providers("ui.menu.key_combinations")
		for _, id in ipairs({"key_combination_slots", "key_combination_rows_left", "key_combination_rows_right"}) do
			helpers.assert_true(current[id] == true)
			helpers.assert_eq(omitted[id], nil, "a missing delegate cannot satisfy a declared list")
		end
	end)
end)

helpers.describe("actual shared list factory coverage", function()
	helpers.it("credits only successful genuine native/shared/template provider calls", function()
		local found, err = genuine_shared_providers()
		helpers.assert_nil(err)
		helpers.assert_true(found.magic_key_source_candidates == true)
		local omitted = registered_providers("keymap.magic_key_source")
		helpers.assert_nil(omitted.magic_key_source_candidates)
		local mutations = {
			function(builder, slot) debug.setupvalue(builder.build, slot, function() return {} end) end,
			function(_, _, shared) shared.menu_rows = function() return {} end end,
			function(_, _, _, manifest) manifest.template_rows = function() return {} end end,
			function(_, _, _, manifest) manifest.build = function() return {} end end,
			function(_, _, _, manifest)
				local previous = manifest.template_rows
				manifest.template_rows = function(key, commands, getters, providers)
					if providers then providers.magic_key_source_candidates = nil end
					return previous(key, commands, getters, providers)
				end
			end,
			function(_, _, _, _, root) root.magic_key_source_children = nil end,
			function(_, _, _, _, root) root.magic_key_source_menu = nil end,
		}
		local raised, raised_error = genuine_shared_providers(function() error("controlled native capture scenario") end)
		helpers.assert_nil(raised.magic_key_source_candidates)
		helpers.assert_true(type(raised_error) == "string" and raised_error:find("controlled native capture scenario", 1, true) ~= nil)
		for index, mutation in ipairs(mutations) do
			local refused = genuine_shared_providers(mutation)
			helpers.assert_nil(refused.magic_key_source_candidates, "withdrawal cannot grant shared provider credit: " .. index)
			local repaired, repair_error = genuine_shared_providers()
			helpers.assert_nil(repair_error)
			helpers.assert_true(repaired.magic_key_source_candidates == true)
		end
	end)
end)

helpers.describe("actual conditional Magic trigger list coverage", function()
	helpers.it("requires the native body, callable reset provider and consumed canonical leaf", function()
		local found, err, observed = genuine_trigger_providers()
		helpers.assert_nil(err)
		helpers.assert_true(found.magic_key_reset_if_custom == true)
		helpers.assert_eq(observed.provider_calls, 1)
		helpers.assert_eq(observed.reset_rows, 1)
		helpers.assert_eq(observed.effects, 0)
		local default, default_error, empty = genuine_trigger_providers(nil, true)
		helpers.assert_nil(default_error)
		helpers.assert_nil(default.magic_key_reset_if_custom)
		helpers.assert_eq(empty.provider_calls, 1)
		helpers.assert_eq(empty.reset_rows, 0, "a genuine default keeps the conditional reset empty")
		helpers.assert_eq(empty.effects, 0)
		local mutations = {
			function(builder, slot) debug.setupvalue(builder.build, slot, nil) end,
			function(builder, slot) debug.setupvalue(builder.build, slot, function() return {} end) end,
			function(_, _, native, slot) debug.setupvalue(native, slot, nil) end,
			function(_, _, native, slot) debug.setupvalue(native, slot, function() return {} end) end,
			function(_, _, _, _, manifest) manifest.template_rows = nil end,
			function(_, _, _, _, manifest) manifest.template_rows = function() return {} end end,
			function(_, _, _, _, manifest) manifest.build = function() return {} end end,
			function(_, _, _, _, _, root) root.hotstrings_magic_trigger_frame = nil end,
			function(_, _, _, _, _, root) root.hotstrings_magic_trigger_reset = nil end,
			function(_, _, _, _, _, root) root.hotstrings_params_group = nil end,
		}
		for _, value in ipairs({ false, "not callable", function() return {} end }) do
			local replacement = value
			mutations[#mutations + 1] = function(_, _, _, _, manifest)
				local previous = manifest.template_rows
				manifest.template_rows = function(key, commands, getters, providers)
					if key == "hotstrings_magic_trigger_frame" then
						providers.magic_key_reset_if_custom = replacement ~= false and replacement or nil
					end
					return previous(key, commands, getters, providers)
				end
			end
		end
		mutations[#mutations + 1] = function(_, _, _, _, manifest, root)
			local previous = manifest.template_rows
			manifest.template_rows = function(key, ...)
				local rows = previous(key, ...)
				if key == "hotstrings_magic_trigger_frame" then root.hotstrings_magic_trigger_frame = nil end
				return rows
			end
		end
		local raised, raised_error = genuine_trigger_providers(function() error("controlled trigger evidence scenario") end)
		helpers.assert_nil(raised.magic_key_reset_if_custom)
		helpers.assert_true(type(raised_error) == "string" and raised_error:find("controlled trigger evidence scenario", 1, true) ~= nil)
		for index, mutation in ipairs(mutations) do
			local refused, _, effects = genuine_trigger_providers(mutation)
			helpers.assert_nil(refused.magic_key_reset_if_custom, "withdrawal cannot grant trigger provider credit: " .. index)
			helpers.assert_eq(effects.effects, 0)
			local repaired, repair_error = genuine_trigger_providers()
			helpers.assert_nil(repair_error)
			helpers.assert_true(repaired.magic_key_reset_if_custom == true)
		end
	end)
end)

helpers.describe("Magic trigger evidence native global ownership", function()
	helpers.it("restores raw absent, false and object globals on success and raised scenarios", function()
		local original = rawget(_G, "i18n_safe")
		local ok, err = pcall(function()
			for _, prior in ipairs({ {}, { value = false }, { value = {} } }) do
				for _, raised in ipairs({ false, true }) do
					rawset(_G, "i18n_safe", prior.value)
					local damage = raised and function() error("controlled raw global scenario") end or nil
					local found, refusal = genuine_trigger_providers(damage)
					helpers.assert_true(rawequal(rawget(_G, "i18n_safe"), prior.value))
					if raised then
						helpers.assert_nil(found.magic_key_reset_if_custom)
						helpers.assert_true(type(refusal) == "string" and refusal:find("controlled raw global scenario", 1, true) ~= nil)
					else
						helpers.assert_nil(refusal)
						helpers.assert_true(found.magic_key_reset_if_custom == true)
					end
				end
			end
		end)
		rawset(_G, "i18n_safe", original)
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("Gesture status list evidence follows genuine native publication", function()
	helpers.it("credits the consumed cached overlap only after the actual returned status survives", function()
		local found, err, observed = genuine_gesture_providers()
		helpers.assert_nil(err)
		helpers.assert_true(found.gesture_system_cached_overlap == true)
		helpers.assert_eq(observed.calls, 1)
		helpers.assert_eq(observed.status_calls, 1)
		helpers.assert_eq(observed.effects, 0)
		local omitted = registered_providers("ui.gesture_conflicts")
		helpers.assert_nil(omitted.gesture_system_cached_overlap)
	end)
	local mutations = {
		{ name = "withdrawn registered native closure", apply = function(builder, slot)
			debug.setupvalue(builder.build, slot, function() return {} end)
		end },
		{ name = "outer native closure discards its genuine body", apply = function(builder, slot)
			local original = select(2, debug.getupvalue(builder.build, slot))
			debug.setupvalue(builder.build, slot, function(...) original(...); return {} end)
		end },
		{ name = "withdrawn native rows owner", apply = function(_, _, producer)
			producer.rows = function() return {} end
		end },
		{ name = "outer rows wrapper discards genuine returned status", apply = function(_, _, producer)
			local original = producer.rows
			producer.rows = function(...) original(...); return {} end
		end },
		{ name = "withdrawn actual template", apply = function(_, _, _, manifest)
			manifest.template_rows = function() return {} end
		end },
		{ name = "outer template discards genuine status", apply = function(_, _, _, manifest)
			local original = manifest.template_rows
			manifest.template_rows = function(key, ...)
				local rows = original(key, ...)
				if key == "gesture_system_status_linux_frame" then return {} end
				return rows
			end
		end },
		{ name = "withdrawn actual cached provider", apply = function(_, _, _, manifest)
			local original = manifest.template_rows
			manifest.template_rows = function(key, commands, getters, providers)
				if key == "gesture_system_linux_children" then providers.gesture_system_cached_overlap = nil end
				return original(key, commands, getters, providers)
			end
		end },
		{ name = "empty replacement cached provider", apply = function(_, _, _, manifest)
			local original = manifest.template_rows
			manifest.template_rows = function(key, commands, getters, providers)
				if key == "gesture_system_linux_children" then providers.gesture_system_cached_overlap = function() return {} end end
				return original(key, commands, getters, providers)
			end
		end },
		{ name = "withdrawn actual native menu build", apply = function(_, _, _, manifest)
			manifest.build = function() return {} end
		end },
		{ name = "outer native menu build discards genuine rows", apply = function(_, _, _, manifest)
			local original = manifest.build
			manifest.build = function(...) original(...); return {} end
		end },
		{ name = "withdrawn actual parent declaration", apply = function(_, _, _, _, root)
			root.gesture_system_status_linux_frame = nil
		end },
		{ name = "late withdrawal of actual parent declaration", apply = function(_, _, _, manifest, root)
			local original = manifest.template_rows
			manifest.template_rows = function(key, ...)
				local rows = original(key, ...)
				if key == "gesture_system_status_linux_frame" then root.gesture_system_status_linux_frame = nil end
				return rows
			end
		end },
	}
	for _, mutation in ipairs(mutations) do
		helpers.it("denies provider credit for " .. mutation.name, function()
			local refused, _, observed = genuine_gesture_providers(mutation.apply)
			helpers.assert_nil(refused.gesture_system_cached_overlap)
			helpers.assert_eq(observed.effects, 0)
			local repaired, repair_error = genuine_gesture_providers()
			helpers.assert_nil(repair_error)
			helpers.assert_true(repaired.gesture_system_cached_overlap == true)
		end)
	end
	helpers.it("restores complete module and raw global ownership after success and raised scenarios", function()
		local original = rawget(_G, "i18n_safe")
		local ok, err = pcall(function()
			for _, prior in ipairs({ {}, { value = false }, { value = {} } }) do
				for _, raised in ipairs({ false, true }) do
					rawset(_G, "i18n_safe", prior.value)
					local damage = raised and function() error("controlled native gesture evidence") end or nil
					local found, detail = genuine_gesture_providers(damage)
					helpers.assert_true(rawequal(rawget(_G, "i18n_safe"), prior.value))
					if raised then
						helpers.assert_nil(found.gesture_system_cached_overlap)
						helpers.assert_true(type(detail) == "string" and detail:find("controlled native gesture evidence", 1, true) ~= nil)
					else
						helpers.assert_nil(detail)
						helpers.assert_true(found.gesture_system_cached_overlap == true)
					end
				end
			end
		end)
		rawset(_G, "i18n_safe", original)
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("actual scoped Hotstrings language list coverage", function()
	helpers.it("requires both actual providers and consumed native switch/category callbacks", function()
		local found, err, observed = genuine_language_providers(nil, true)
		helpers.assert_nil(err)
		helpers.assert_true(found.hotstring_language_switch == true)
		helpers.assert_true(found.hotstring_language_categories == true)
		helpers.assert_eq(observed.switch_calls, 1)
		helpers.assert_eq(observed.category_calls, 1)
		helpers.assert_eq(observed.effects, 2, "only explicit callback exercise reaches the injected target recorders")
		helpers.assert_eq(observed.selected, "french_magickey,french_absent,french_autocorrection")
		helpers.assert_eq(observed.enabled, false)
		helpers.assert_eq(observed.category, "french_magickey")
		helpers.assert_eq(observed.section, "beta")
	end)
	local mutations = {
		{ name = "withdrawn registered Hotstrings closure", apply = function(builder, slot)
			debug.setupvalue(builder.build, slot, nil)
		end },
		{ name = "outer native closure discards genuine Hotstrings content", apply = function(builder, slot)
			local original = select(2, debug.getupvalue(builder.build, slot))
			debug.setupvalue(builder.build, slot, function(...) original(...); return {} end)
		end },
		{ name = "withdrawn native manifest body", apply = function(_, _, closure, slot)
			debug.setupvalue(closure, slot, nil)
		end },
		{ name = "native body discards genuine language content", apply = function(_, _, closure, slot)
			local original = select(2, debug.getupvalue(closure, slot))
			debug.setupvalue(closure, slot, function(...) original(...); return {} end)
		end },
		{ name = "withdrawn canonical template", apply = function(_, _, _, _, manifest)
			manifest.template_rows = nil
		end },
		{ name = "withdrawn canonical native build", apply = function(_, _, _, _, manifest)
			manifest.build = nil
		end },
		{ name = "withdrawn genuine checkbox wrapper", apply = function(_, _, _, _, manifest)
			manifest.check_row = nil
		end },
		{ name = "checkbox result replaced by a borrowed fake callback", apply = function(_, _, _, _, manifest)
			local original = manifest.check_row
			manifest.check_row = function(...)
				original(...)
				return { label = "borrowed fake switch", action = function() return true end }
			end
		end },
		{ name = "native build discards successfully rendered content", apply = function(_, _, _, _, manifest)
			local original = manifest.build
			manifest.build = function(...) original(...); return {} end
		end },
	}
	for _, key in ipairs({ "hotstring_language_frame", "hotstring_language_parent_lua", "hotstring_scope_checkbox", "hotstrings_menu" }) do
		local frame = key
		mutations[#mutations + 1] = { name = "withdrawn actual " .. frame, apply = function(_, _, _, _, _, root)
			root[frame] = nil
		end }
	end
	for _, key in ipairs({ "hotstring_language_frame", "hotstring_language_parent_lua" }) do
		local frame = key
		mutations[#mutations + 1] = { name = "template discards genuine " .. frame, apply = function(_, _, _, _, manifest)
			local original = manifest.template_rows
			manifest.template_rows = function(key, ...)
				local rows = original(key, ...)
				if key == frame then return {} end
				return rows
			end
		end }
		mutations[#mutations + 1] = { name = "late declaration withdrawal after genuine " .. frame, apply = function(_, _, _, _, manifest, root)
			local original = manifest.template_rows
			manifest.template_rows = function(key, ...)
				local rows = original(key, ...)
				if key == frame then root[frame] = nil end
				return rows
			end
		end }
	end
	for _, id in ipairs({ "hotstring_language_switch", "hotstring_language_categories" }) do
		for _, value in ipairs({ false, "not callable", function() return {} end,
			function() return { { label = "borrowed fake section", action = function() return true end } } end }) do
			local provider_id, replacement = id, value
			mutations[#mutations + 1] = { name = "withdrawn or fabricated callable " .. provider_id .. " " .. type(value),
				apply = function(_, _, _, _, manifest)
					local original = manifest.template_rows
					manifest.template_rows = function(key, commands, getters, providers)
						if key == "hotstring_language_frame" then providers[provider_id] = replacement ~= false and replacement or nil end
						return original(key, commands, getters, providers)
					end
				end }
		end
	end
	for index, mutation in ipairs(mutations) do
		helpers.it("denies scoped language provider credit: " .. index .. " " .. mutation.name, function()
			local found, _, observed = genuine_language_providers(mutation.apply)
			helpers.assert_nil(found.hotstring_language_switch)
			helpers.assert_nil(found.hotstring_language_categories)
			helpers.assert_eq(observed.effects, 0)
			local repaired, repair_error = genuine_language_providers()
			helpers.assert_nil(repair_error)
			helpers.assert_true(repaired.hotstring_language_switch == true)
			helpers.assert_true(repaired.hotstring_language_categories == true)
		end)
	end
	helpers.it("restores raw globals and all loaded module owners on success and raised evidence", function()
		local original = rawget(_G, "i18n_safe")
		local ok, err = pcall(function()
			for _, prior in ipairs({ {}, { value = false }, { value = {} } }) do
				for _, raised in ipairs({ false, true }) do
					rawset(_G, "i18n_safe", prior.value)
					local damage = raised and function() error("controlled language provider evidence") end or nil
					local found, refusal = genuine_language_providers(damage)
					helpers.assert_true(rawequal(rawget(_G, "i18n_safe"), prior.value))
					if raised then
						helpers.assert_nil(found.hotstring_language_switch)
						helpers.assert_nil(found.hotstring_language_categories)
						helpers.assert_true(type(refusal) == "string" and refusal:find("controlled language provider evidence", 1, true) ~= nil)
					else
						helpers.assert_nil(refusal)
						helpers.assert_true(found.hotstring_language_switch == true)
						helpers.assert_true(found.hotstring_language_categories == true)
					end
				end
			end
		end)
		rawset(_G, "i18n_safe", original)
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("actual public Hotstrings publication and retained callback audit", function()
	helpers.it("consumes the registered root and proves canonical readiness plus every category target", function()
		local found, err, observed = genuine_language_providers()
		helpers.assert_nil(err)
		helpers.assert_true(found.hotstring_language_switch == true)
		helpers.assert_true(found.hotstring_language_categories == true)
		helpers.assert_eq(observed.publication_calls, 1)
		helpers.assert_true(observed.readiness_refused == true)
		helpers.assert_true(observed.readiness_recovered == true)
		helpers.assert_eq(observed.effects, 0, "the original build counter excludes explicit recorder-only callback audit")
		helpers.assert_eq(observed.audit_notifications, 7)
		helpers.assert_eq(observed.audit_events, {
			{ kind = "scope", selected = "french_magickey,french_absent,french_autocorrection", enabled = false },
			{ kind = "scope", selected = "french_magickey,french_absent,french_autocorrection", enabled = false },
			{ kind = "section", category = "french_magickey", section = "beta" },
			{ kind = "section", category = "french_magickey", section = "beta" },
			{ kind = "category_scope", selected = "french_magickey", enabled = true },
			{ kind = "category_scope", selected = "french_magickey", enabled = true },
			{ kind = "category_scope", selected = "french_magickey", enabled = false },
			{ kind = "category_scope", selected = "french_magickey", enabled = false },
			{ kind = "section", category = "french_autocorrection", section = "alpha" },
			{ kind = "section", category = "french_autocorrection", section = "alpha" },
			{ kind = "category_scope", selected = "french_autocorrection", enabled = true },
			{ kind = "category_scope", selected = "french_autocorrection", enabled = true },
			{ kind = "category_scope", selected = "french_autocorrection", enabled = false },
			{ kind = "category_scope", selected = "french_autocorrection", enabled = false },
		})
	end)
	local mutations = {
		{ name = "withdrawn canonical root renderer", apply = function(_, _, _, _, manifest)
			manifest.render_rows = nil
		end },
		{ name = "canonical root wrapper discards genuine publication", apply = function(_, _, _, _, manifest)
			local original = manifest.render_rows
			manifest.render_rows = function(...) original(...); return {} end
		end },
		{ name = "withdrawn actual root registration declaration", apply = function(_, _, _, _, _, root)
			root.top_level = nil
		end },
		{ name = "raised canonical root publication", apply = function(_, _, _, _, manifest)
			manifest.render_rows = function() error("controlled root publication refusal") end
		end },
	}
	for _, mutation in ipairs(mutations) do
		helpers.it("denies public language coverage: " .. mutation.name, function()
			local found, _, observed = genuine_language_providers(mutation.apply)
			helpers.assert_nil(found.hotstring_language_switch)
			helpers.assert_nil(found.hotstring_language_categories)
			helpers.assert_eq(observed.effects, 0)
			local repaired, err = genuine_language_providers()
			helpers.assert_nil(err)
			helpers.assert_true(repaired.hotstring_language_switch == true)
			helpers.assert_true(repaired.hotstring_language_categories == true)
		end)
	end
end)
