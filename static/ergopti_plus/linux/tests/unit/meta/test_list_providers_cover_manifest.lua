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
