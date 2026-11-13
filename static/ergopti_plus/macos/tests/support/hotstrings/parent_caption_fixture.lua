--- tests/support/hotstrings/parent_caption_fixture.lua

--- ==============================================================================
--- MODULE: Hotstrings Parent Caption Fixture
--- DESCRIPTION:
--- Supplies the actual English Hotstrings parent caption to explicitly enrolled
--- positive tray fixtures. Other independently authored labels remain unchanged;
--- the real native binding captures the completed fixture translator first.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}

--- Supplies the file-backed caption before native renderer and builder import.
--- @param translator table Exact positive fixture translator.
--- @return table renderer Actual native binding over the canonical manifest.
function M.install(translator)
	assert(type(translator) == "table" and type(translator.get) == "function"
		and type(translator.section) == "function", "positive caption fixture needs its actual translator")
	local file = assert(io.open(helpers.shared("core/i18n/data/locales/en.json"), "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	local source = assert(require("core.fs.adapters.json_codec").decode(bytes))
	assert(source["_meta.locale"] == "en", "actual English catalogue unavailable")
	local caption = source["menu.hotstrings.title"]
	assert(type(caption) == "string" and caption ~= "" and caption ~= "menu.hotstrings.title",
		"actual Hotstrings parent caption unavailable")
	local previous_get = translator.get
	translator.get = function(key, ...)
		if key == "menu.hotstrings.title" then return caption end
		return previous_get(key, ...)
	end
	assert(package.loaded["core.i18n.engine.i18n"] == translator, "caption fixture translator was not published")
	package.loaded["menu.engine.manifest_menu"] = nil
	return require("menu.engine.manifest_menu")
end

--- Retains exact predecessor modules around the complete positive assertion body.
--- @param callback function Original suite or subject.
--- @return function scoped Callback under the existing exact fixture scope.
function M.scoped(callback)
	return require("tests.support.layouts.legacy_caption_fixture").scoped(callback)
end

return M
