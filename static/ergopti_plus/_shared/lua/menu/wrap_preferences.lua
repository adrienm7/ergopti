-- _shared/lua/menu/wrap_preferences.lua

--- Pure Wrap preference projection and source-preserving publication rows.
local M = {}
local Codec = require("toml_codec.codec")
local LeafRows = require("toml_codec.leaf_rows")
local Utf8 = require("compat.utf8")

M.locations = {
	wrap_symbol_states = { sec = "shortcuts", key = "wrap_symbols.states" },
	custom_wrap_symbols = { sec = "shortcuts", key = "wrap_symbols.custom" },
}

local function dictionary(value, shapes)
	return type(value) == "table" and not shapes.arrays[value]
end

local function symbol(value)
	return type(value) == "string" and Utf8.len(value) == 1
end

local function custom_array(value, shapes)
	if type(value) ~= "table" or not shapes.arrays[value] then return false end
	for _, pair in ipairs(value) do
		if type(pair) ~= "table" or shapes.arrays[pair]
			or not symbol(pair.left) or not symbol(pair.right) then return false end
	end
	return true
end

local function source_wrap(document, shapes)
	assert(type(shapes) == "table" and shapes.document == document, "Wrap preferences need their exact source receipt")
	local shortcuts = document.shortcuts
	if shortcuts == nil then return nil, true end
	if not dictionary(shortcuts, shapes) then return nil, false end
	local wrap = shortcuts.wrap_symbols
	if wrap == nil then return nil, true end
	return wrap, dictionary(wrap, shapes)
end

--- Projects only typed owned values; callbacks retain independent source paths.
--- Invalid entries stay on disk and remain eligible for explicit cleanup.
function M.project(document, shapes, take, outdated)
	take, outdated = take or function() end, outdated or function() end
	local wrap, ready = source_wrap(document, shapes)
	if not ready then
		outdated({ "shortcuts", "wrap_symbols" }, "Wrap preferences require a dictionary")
		return {}
	end
	if wrap == nil then return {} end
	for key in pairs(wrap) do
		if key ~= "states" and key ~= "custom" then
			outdated({ "shortcuts", "wrap_symbols", key }, "No Wrap preference of this build declares this field")
		end
	end
	local flat = {}
	if wrap.states ~= nil then
		if dictionary(wrap.states, shapes) then
			flat.wrap_symbol_states = {}
			for symbol, enabled in pairs(wrap.states) do
				if type(symbol) == "string" and symbol ~= "" and type(enabled) == "boolean" then
					flat.wrap_symbol_states[symbol] = enabled
					take("shortcuts", "wrap_symbols", "states", symbol)
				else
					outdated({ "shortcuts", "wrap_symbols", "states", symbol }, "Wrap symbol choices require strict booleans")
				end
			end
			if next(wrap.states) == nil then take("shortcuts", "wrap_symbols", "states") end
		else outdated({ "shortcuts", "wrap_symbols", "states" }, "Wrap symbol choices require a dictionary") end
	end
	if wrap.custom ~= nil then
		if custom_array(wrap.custom, shapes) then
			flat.custom_wrap_symbols = LeafRows.clone_value(wrap.custom)
			take("shortcuts", "wrap_symbols", "custom")
		else outdated({ "shortcuts", "wrap_symbols", "custom" }, "Custom Wrap symbols require an ordered pair array") end
	end
	return flat
end

local function desired_states(value)
	if value == nil then return nil end
	assert(type(value) == "table", "Wrap symbol choices must be a dictionary")
	for symbol, enabled in pairs(value) do
		assert(type(symbol) == "string" and symbol ~= "" and type(enabled) == "boolean", "Wrap symbol choices need strict booleans")
	end
	return value
end

local function desired_custom(value)
	if value == nil then return nil end
	assert(type(value) == "table", "Custom Wrap symbols must be an ordered array")
	local count = 0
	for index, pair in pairs(value) do
		count = count + 1
		assert(type(index) == "number" and index >= 1 and index % 1 == 0
			and type(pair) == "table" and symbol(pair.left) and symbol(pair.right), "Custom Wrap symbols require ordered Unicode scalar pairs")
	end
	for index = 1, count do assert(value[index] ~= nil, "Custom Wrap symbols require dense slots") end
	return value
end

--- Plans only the Wrap fields present in the complete native snapshot.
--- Empty defaults cannot replace obsolete source containers; actual new choices
--- refuse those collisions. Typed source leaves are removed only by an explicit
--- changed desired projection, preserving unknown neighbors and pair metadata.
function M.prepare(content, flat)
	local document, shapes = LeafRows.decode_source(content)
	assert(type(document) == "table", "Wrap preference source must decode")
	local states, custom = desired_states(flat.wrap_symbol_states), desired_custom(flat.custom_wrap_symbols)
	if states == nil and custom == nil then return {} end
	local wrap, ready = source_wrap(document, shapes)
	if not ready then
		assert((states == nil or next(states) == nil) and (custom == nil or next(custom) == nil), "Wrap source container is obsolete; explicit cleanup is required")
		return {}
	end
	wrap = wrap or {}
	local operations = {}
	if states ~= nil then
		if wrap.states ~= nil and not dictionary(wrap.states, shapes) then
			assert(next(states) == nil, "Wrap state container is obsolete; explicit cleanup is required")
		else
			for symbol, enabled in pairs(states) do
				local prior = wrap.states and wrap.states[symbol]
				assert(prior == nil or type(prior) == "boolean", "Wrap state leaf is obsolete; explicit cleanup is required")
				operations[#operations + 1] = { path = { "shortcuts", "wrap_symbols", "states", symbol }, value = enabled }
			end
			for symbol, enabled in pairs(wrap.states or {}) do
				if type(enabled) == "boolean" and states[symbol] == nil then
					operations[#operations + 1] = { path = { "shortcuts", "wrap_symbols", "states", symbol }, delete = true }
				end
			end
		end
	end
	if custom ~= nil then
		if wrap.custom ~= nil and not custom_array(wrap.custom, shapes) then
			assert(next(custom) == nil, "Custom Wrap source is obsolete; explicit cleanup is required")
		elseif next(custom) ~= nil then
			local desired, used = {}, {}
			for _, pair in ipairs(custom) do
				local origin = LeafRows.source_origin(pair)
				local selected
				if origin and origin.path[1] == "shortcuts" and origin.path[2] == "wrap_symbols"
					and origin.path[3] == "custom" and type(origin.path[4]) == "number" then
					if origin.source ~= content then
						local previous, previous_shapes = LeafRows.decode_source(origin.source)
						local prior_wrap, admitted = source_wrap(previous, previous_shapes)
						assert(admitted and prior_wrap and custom_array(prior_wrap.custom, previous_shapes)
							and wrap.custom and #prior_wrap.custom == #wrap.custom, "Custom Wrap source changed; reload before retrying")
						for index, prior in ipairs(prior_wrap.custom) do
							assert(prior.left == wrap.custom[index].left and prior.right == wrap.custom[index].right,
								"Custom Wrap source identities changed; reload before retrying")
						end
					end
					selected = origin.path[4]
					assert(wrap.custom and wrap.custom[selected] and wrap.custom[selected].left == pair.left
						and wrap.custom[selected].right == pair.right and not used[selected], "Custom Wrap source identity is no longer owned")
				else
					for index, prior in ipairs(wrap.custom or {}) do
						if prior.left == pair.left and prior.right == pair.right and not used[index] then
							assert(selected == nil, "Custom Wrap pair has ambiguous source ownership")
							selected = index
						end
					end
				end
				if selected then
					used[selected] = true
					-- Future fields belong to the admitted physical source, including
					-- [] versus {} changes invisible to ordinary Lua deep equality.
					desired[#desired + 1] = LeafRows.clone_value(wrap.custom[selected])
				else desired[#desired + 1] = LeafRows.clone_value(pair) end
			end
			if wrap.custom == nil or LeafRows.value_literal(desired) ~= LeafRows.value_literal(wrap.custom) then
				operations[#operations + 1] = { path = { "shortcuts", "wrap_symbols", "custom" }, value = desired }
			end
		elseif wrap.custom ~= nil then
			operations[#operations + 1] = { path = { "shortcuts", "wrap_symbols", "custom" }, delete = true }
		end
	end
	return LeafRows.prepare(content, operations)
end

return M
