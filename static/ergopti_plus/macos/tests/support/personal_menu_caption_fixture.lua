--- tests/support/personal_menu_caption_fixture.lua

--- ==============================================================================
--- MODULE: Personal Menu Caption Fixture
--- DESCRIPTION:
--- Supplies the two explicit Personal-frame captions from the real native
--- English catalogue while retaining the caller's identity labels elsewhere.
--- Captured renderer and builder readers are restored on success and failure.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local CAPTIONS = {
	["menu.hotstrings.default_category_prefix"] = true,
	["menu.hotstrings.shortcut_prefix"] = true,
}

local function english_captions()
	return helpers.with_fresh_modules({ "infra.i18n", "infra.locale", "locale.core", "infra.paths" }, function()
		local native = require("infra.i18n")
		local locale = require("infra.locale")
		local paths = require("infra.paths")
		local fh = assert(io.open(paths.shared("data/locales/en.json"), "r"), "actual English caption file unavailable")
		local raw = fh:read("*a")
		fh:close()
		local source = require("adapters.json_codec").decode(raw)
		assert(type(source) == "table" and source["_meta.locale"] == "en", "actual English caption file malformed")
		native.set_locale_injector(locale.set_locale)
		native.set_locale_no_reload("en")
		assert(native.get_locale() == "en" and locale.current_locale() == "en", "native English context was not initialized")
		local captions = {}
		for key in pairs(CAPTIONS) do
			local value = native.get(key)
			assert(type(value) == "string" and value ~= "" and value ~= key, "native English caption source unavailable: " .. key)
			assert(value == source[key], "native caption does not match the captured English source: " .. key)
			captions[key] = value
		end
		return captions
	end)
end

--- Initializes actual file-backed captions around the captured fixture owners.
--- @param custom table Actual Personal menu module.
--- @param callback function Owning fixture body.
--- @return ... Original callback results.
function M.with_captions(custom, callback)
	assert(type(custom) == "table" and type(custom.build_custom) == "function")
	assert(type(callback) == "function")
	local owners, seen_functions, seen_owners = {}, {}, {}
	local function inspect(fn)
		if seen_functions[fn] then return end
		seen_functions[fn] = true
		for index = 1, math.huge do
			local name, value = debug.getupvalue(fn, index)
			if name == nil then break end
			if name == "i18n" and type(value) == "table" and type(value.get) == "function" and not seen_owners[value] then
				seen_owners[value] = true
				owners[#owners + 1] = value
			elseif type(value) == "function" then
				inspect(value)
			elseif name == "ManifestMenu" and type(value) == "table" then
				for _, method in pairs(value) do
					if type(method) == "function" then inspect(method) end
				end
			end
		end
	end
	inspect(custom.build_custom)
	assert(#owners > 0, "actual Personal builder caption owners unavailable")
	local captions = english_captions()
	local saved = {}
	for index, owner in ipairs(owners) do
		local previous = owner.get
		saved[index] = previous
		owner.get = function(key, ...)
			if CAPTIONS[key] then return captions[key] end
			return previous(key, ...)
		end
	end
	local result = table.pack(xpcall(callback, debug.traceback))
	for index, owner in ipairs(owners) do owner.get = saved[index] end
	if not result[1] then error(result[2], 0) end
	return table.unpack(result, 2, result.n)
end

--- Builds the actual Personal provider with its required caption dependency.
--- @param custom table Actual Personal menu module.
--- @param ctx table Original native fixture context.
--- @param counts table Original group counts.
--- @return table|nil Original native provider result.
function M.build_custom(custom, ctx, counts)
	return M.with_captions(custom, function() return custom.build_custom(ctx, counts) end)
end

return M
