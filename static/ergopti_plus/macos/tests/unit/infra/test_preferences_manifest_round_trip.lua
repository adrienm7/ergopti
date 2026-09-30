--- tests/unit/infra/test_preferences_manifest_round_trip.lua

--- ==============================================================================
--- MODULE: Every manifest setting survives config.toml load and save
--- DESCRIPTION:
--- Each setting used to be tested alone, so two owners sharing one TOML table
--- were never exercised together: [shortcuts.script_control] holds the
--- `enabled` scalar and the key-slot map, the flag was read back as a slot,
--- and the menu logged "both keyname and action must be strings" at every
--- start while the saved flag was lost. This test writes EVERY macOS setting
--- the manifest declares with a non-default value into one config.toml, then
--- requires that the loaded state holds each value at its owner, that no
--- nested map carries a key another owner claims, and that a save writes every
--- value back unchanged (preferences-manifest-round-trip).
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec")

--- Reports whether a manifest entry applies to the macOS driver.
--- @param entry table Manifest feature entry.
--- @return boolean
local function on_macos(entry)
	if type(entry.platforms) ~= "table" then return true end
	for _, platform in ipairs(entry.platforms) do
		if platform == "hs" then return true end
	end
	return false
end

--- Returns a value that differs from the default, or nil when none is known.
--- @param manifest table The manifest reader.
--- @param entry table Manifest feature entry.
--- @return any
local function changed_value(manifest, entry)
	local default = manifest.default_for(entry.path)
	if type(default) == "boolean" then return not default end
	local ok, recommended = pcall(manifest.recommended_for, entry.path)
	if ok and recommended ~= nil and type(recommended) == type(default)
		and type(recommended) ~= "table" and recommended ~= default then
		return recommended
	end
	return nil
end

--- Reads the value at a dotted path, or nil.
--- @param root table
--- @param path string
--- @return any
local function get_path(root, path)
	local node = root
	for part in path:gmatch("[^%.]+") do
		if type(node) ~= "table" then return nil end
		node = node[part]
	end
	return node
end

--- Splits a path into its parent path and last segment.
--- @param path string
--- @return string parent, string leaf
local function split_leaf(path)
	return path:match("^(.*)%.([^%.]+)$")
end

--- Renders the cases as the writer lays config.toml out: one [table] header
--- per parent path, then its scalar keys.
--- @param cases table Array of { path, value }.
--- @return string
local function as_sections(cases)
	local by_parent, order = {}, {}
	for _, case in ipairs(cases) do
		local parent, leaf = split_leaf(case.path)
		if not by_parent[parent] then
			by_parent[parent] = {}
			order[#order + 1] = parent
		end
		local value = case.value
		local literal = type(value) == "string" and string.format("%q", value) or tostring(value)
		by_parent[parent][#by_parent[parent] + 1] = leaf .. " = " .. literal
	end
	table.sort(order)
	local lines = {}
	for _, parent in ipairs(order) do
		lines[#lines + 1] = "[" .. parent .. "]"
		for _, line in ipairs(by_parent[parent]) do lines[#lines + 1] = line end
		lines[#lines + 1] = ""
	end
	return table.concat(lines, "\n")
end

helpers.describe("every manifest setting survives config.toml load and save (preferences-manifest-round-trip)", function()
	helpers.it("loads each value at its owner and saves it back unchanged", function()
		helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system" }, function()
			local manifest = require("infra.manifest_reader")
			local prefs_probe = helpers.load_with_stubs("infra.preferences")

			-- Every macOS setting with a scalar owner or inside an owned nested map
			local cases = {}
			for _, entry in ipairs(manifest.features()) do
				local value = on_macos(entry) and type(entry.path) == "string" and changed_value(manifest, entry)
				if value ~= nil then
					local scalar_key = prefs_probe.flat_key_for(entry.path)
					local parent, leaf = split_leaf(entry.path)
					local nested_key = parent and prefs_probe.flat_key_for(parent)
					if scalar_key or nested_key then
						cases[#cases + 1] = { path = entry.path, value = value, scalar = scalar_key,
							nested = not scalar_key and nested_key or nil, leaf = leaf }
					end
				end
			end
			helpers.assert_true(#cases >= 50, "the round trip must cover the manifest, got " .. #cases)
			local covered = {}
			for _, case in ipairs(cases) do covered[case.path] = case end
			helpers.assert_true(covered["shortcuts.script_control.chords_enabled"] ~= nil
				and covered["shortcuts.script_control.chords_enabled"].scalar ~= nil,
				"the shared script-control table must be part of the round trip")

			local source = as_sections(cases)
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return source, "ok" end,
				write = function() error("unguarded publication") end,
				write_if_unchanged = function(_, content)
					source = content
					return true
				end,
			}
			package.loaded["infra.preferences"] = nil
			local prefs = helpers.load_with_stubs("infra.preferences")
			local state, status = prefs.load("/round-trip/config.toml")
			helpers.assert_eq(status, "ok")

			for _, case in ipairs(cases) do
				if case.scalar then
					helpers.assert_eq(state[case.scalar], prefs.state_value_for(case.path, case.value),
						case.path .. " must load into " .. case.scalar)
				else
					helpers.assert_eq(type(state[case.nested]), "table", case.path .. ": owner map")
					helpers.assert_eq(state[case.nested][case.leaf], case.value, case.path .. " must load into its map")
				end
			end

			-- No nested map may hold a key that a scalar owns
			for _, case in ipairs(cases) do
				if case.scalar then
					local parent, leaf = split_leaf(case.path)
					local nested_key = parent and prefs.flat_key_for(parent)
					if nested_key and nested_key ~= case.scalar and type(state[nested_key]) == "table" then
						helpers.assert_nil(state[nested_key][leaf],
							case.path .. " is a scalar and must not appear inside " .. nested_key)
					end
				end
			end

			-- The runtime owners report back what they were configured with, as
			-- the real modules do once the menu has applied the loaded state.
			local modules = {
				keymap = { is_repeat_feature_enabled = function() return state.repeat_key_enabled end },
				gestures = {
					get_all_actions = function() return state.gesture_actions or {} end,
					get_all_modes = function() return state.gesture_modes or {} end,
					get_all_sensitivities = function() return state.gesture_sensitivities or {} end,
					get_all_action_parameters = function() return state.gesture_action_parameters or {} end,
				},
				shortcuts_mod = {
					list_shortcuts = function()
						local list = {}
						for id, enabled in pairs(state.shortcut_keys or {}) do
							list[#list + 1] = { id = id, enabled = enabled }
						end
						return list
					end,
				},
			}
			helpers.assert_eq(prefs.save("/round-trip/config.toml", state, {}, modules), true)
			local saved = codec.decode(source)
			local lost = {}
			for _, case in ipairs(cases) do
				if get_path(saved, case.path) ~= case.value then
					lost[#lost + 1] = case.path .. "=" .. tostring(get_path(saved, case.path))
				end
			end
			helpers.assert_eq(table.concat(lost, ", "), "", "every value must be saved back")
		end)
	end)
end)
