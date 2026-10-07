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
