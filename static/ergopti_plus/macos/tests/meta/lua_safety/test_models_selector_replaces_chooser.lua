--- tests/meta/lua_safety/test_models_selector_replaces_chooser.lua

--- ==============================================================================
--- MODULE: Models selector replaces its chooser (meta)
--- DESCRIPTION:
--- models_selector.lua must delete the stale chooser before creating a new one.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("models selector replaces its chooser", function()

	-- =====================================================================
	-- ===== 4) Chooser leak — stale instance deleted before new creation
	-- =====================================================================

	helpers.it("models_selector.lua must delete old chooser before creating a new one", function()
		local src = read_source("\"Failed to create usercontent bridge for custom model dialog.\"") -- ui/menu/menu_llm/models_selector.lua
		assert(src, "models_selector.lua must be readable")
		-- The bug: _model_browser_chooser is overwritten without calling :delete(),
		-- leaking the previous C-backed hs.chooser object into process memory.
		-- The fix: explicitly delete the stale instance before reassigning.
		assert(
			src:find("stale:delete()", 1, true) or src:find("_model_browser_chooser.*:delete", 1, false),
			"models_selector.lua: must call :delete() on the old chooser before " ..
			"creating a new one to prevent native object leaks"
		)
	end)

end)
