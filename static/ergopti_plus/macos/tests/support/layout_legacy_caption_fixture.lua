--- tests/support/layout_legacy_caption_fixture.lua

--- ==============================================================================
--- MODULE: Legacy Layout Caption Fixture Boundary
--- DESCRIPTION:
--- Supplies real formatted Layout catalogue inputs without replacing independent
--- legacy key-echo captions or the actual shared renderer and native producers.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}

--- Installs only genuine format strings missing from the fixture's existing catalogue.
--- Existing independently authored formatted captions retain their original values.
--- @param translator table Current fixture translator, captured by its genuine native producer.
--- @return table renderer Actual Hammerspoon binding over the canonical shared manifest.
function M.install(translator)
	local file = assert(io.open(helpers.shared("data/locales/en.json"), "rb"))
	local catalogue = assert(require("json").decode(file:read("*a")))
	assert(file:close())
	local original_get = translator.get
	translator.get = function(key)
		local original = original_get(key)
		local format = catalogue[key]
		if type(key) == "string" and key:sub(1, #"menu.layout.") == "menu.layout."
			and type(format) == "string" and format:find("%s", 1, true)
			and not (type(original) == "string" and original:find("%s", 1, true)) then return format end
		return original
	end
	-- The real binding must capture this fixture's dictionary, never a stale prior fixture.
	package.loaded["infra.manifest_menu"] = nil
	return require("infra.manifest_menu")
end

--- Scopes complete legacy subjects, including their caption assertions, to exact predecessor modules.
--- @param callback function Original suite or subject.
--- @return function scoped Same callback under raw package-cache and hs restoration.
function M.scoped(callback)
	return function(...)
		local predecessor = {}; for name, value in pairs(package.loaded) do predecessor[name] = value end
		local previous_hs = rawget(_G, "hs")
		local args = table.pack(...)
		local outcome = table.pack(xpcall(function() return callback(table.unpack(args, 1, args.n)) end, debug.traceback))
		_G.hs = previous_hs
		for name in pairs(package.loaded) do if rawget(predecessor, name) == nil then package.loaded[name] = nil end end
		for name, value in pairs(predecessor) do package.loaded[name] = value end
		if not outcome[1] then error(outcome[2], 0) end
		return table.unpack(outcome, 2, outcome.n)
	end
end

return M
