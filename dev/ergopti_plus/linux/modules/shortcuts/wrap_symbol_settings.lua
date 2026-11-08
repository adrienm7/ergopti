--- modules/shortcuts/wrap_symbol_settings.lua

--- ==============================================================================
--- MODULE: Wrap Symbol Settings (Linux)
--- DESCRIPTION:
--- Owns the user's wrap-symbol choices in config.toml: which catalogue pairs
--- wrap a selection (`shortcuts.wrap_symbols.states`, keyed by the opening
--- symbol, false for a pair switched off) and the pairs the user added
--- (`shortcuts.wrap_symbols.custom`). macOS keeps the same section, through the
--- same shared projection and publication rows (_shared/lua/menu/wrap_preferences).
---
--- FEATURES & RATIONALE:
--- 1. Same store as macOS, so a config.toml carried between the two keeps its
---    choices; Windows keeps its own in wrap_symbols.toml.
--- 2. Source-preserving writes: the shared planner turns a candidate into rows
---    against the exact bytes read, and the writer publishes them only while the
---    file still holds those bytes. Unknown neighbours and pair metadata survive.
--- 3. An entry in another shape is outdated configuration: warned, left on disk
---    for the cleanup, never read as a choice.
--- 4. The active table is derived, never stored: catalogue pairs still switched
---    on, then the custom pairs, under every trigger form of each end.
--- ==============================================================================

local M = {}
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local WrapPreferences = require("menu.wrap_preferences")
local WrapPair = require("wrap_pair")
local ConfigOutdated = require("config_outdated")
local Logger = require("logger.shim")

local LOG = "modules.shortcuts.wrap_symbol_settings"

-- A candidate mutation that changed nothing it wants written.
M.CANCELLED = "wrap_mutation_cancelled"

--- Reads the choices and the exact source they came from.
--- @param path string config.toml.
--- @return table view { states = { [left] = boolean }, custom = { { left, right } } }
--- @return table source { status, content } for a conditional write.
function M.read(path)
	assert(type(path) == "string" and path ~= "", "wrap symbol settings need the configuration path")
	local bytes, status, detail = Writer.read_classified(path)
	assert(status == "ok" or status == "absent", "configuration is unreadable: " .. tostring(detail))
	local document, shapes = LeafRows.decode_source(bytes or "")
	assert(type(document) == "table", "configuration is malformed")
	local flat = WrapPreferences.project(document, shapes, nil, function(segments, reason)
		ConfigOutdated.report(segments, reason, Logger)
	end)
	return { states = flat.wrap_symbol_states or {}, custom = flat.custom_wrap_symbols or {} },
		{ status = status, content = bytes }
end

--- The active wrap lookup: catalogue pairs still on, then the custom pairs.
--- The choice is applied before the trigger keys are resolved, so a pair
--- switched off never takes a key a pair still on owns.
--- @param catalogue table Ordered catalogue pairs, each { left, right }.
--- @param view table As read() returns.
--- @return table { [trigger] = { left, right } }
function M.active_pairs(catalogue, view)
	local result = {}
	for _, pair in ipairs(catalogue) do
		if view.states[pair.left] ~= false then WrapPair.register(result, pair) end
	end
	for _, pair in ipairs(view.custom) do
		local entry = { left = pair.left, right = pair.right }
		result[pair.left] = entry
		if pair.right ~= pair.left then result[pair.right] = entry end
	end
	return result
end

--- Publishes one mutation of the choices.
--- @param path string config.toml.
--- @param mutate function mutate(candidate) -> boolean; candidate has
---   wrap_symbol_states and custom_wrap_symbols, the shared planner's shape.
--- @return boolean committed
--- @return string|nil reason M.CANCELLED, or why the write was refused.
function M.commit(path, mutate)
	assert(type(mutate) == "function", "a wrap symbol mutation needs its function")
	local called, committed, detail = pcall(function()
		local view, source = M.read(path)
		local states = {}
		for symbol, enabled in pairs(view.states) do states[symbol] = enabled end
		local custom = {}
		-- The projected pairs keep their source origin: the planner matches them
		-- back to the rows they came from, metadata included.
		for index, pair in ipairs(view.custom) do custom[index] = pair end
		local candidate = { wrap_symbol_states = states, custom_wrap_symbols = custom }
		if mutate(candidate) ~= true then return false, M.CANCELLED end
		local rows = WrapPreferences.prepare(source.content or "", candidate)
		if #rows == 0 then return true end
		local written, reason = Writer.batch_write(path, rows, nil, source)
		if written ~= true then return false, tostring(reason) end
		return true
	end)
	if not called then
		Logger.error(LOG, "Wrap symbol choices were not saved: %s.", tostring(committed))
		return false, tostring(committed)
	end
	if committed ~= true then
		if detail ~= M.CANCELLED then Logger.error(LOG, "Wrap symbol choices were not saved: %s.", tostring(detail)) end
		return false, detail
	end
	Logger.info(LOG, "Wrap symbol choices saved.")
	return true
end

return M
