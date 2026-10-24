--- _shared/lua/llm/app_identity.lua

--- ==============================================================================
--- MODULE: Application Identity For AI Settings (Shared Lua)
--- DESCRIPTION:
--- The one key an application is stored and compared under by the AI settings
--- that name applications: the per-application profile overrides
--- (llm.app_profile_overrides) and the applications the automatic trigger never
--- runs in (llm.trigger.disabled_apps). Windows applies the same rule in its
--- engine; macOS and Linux share this module (vectors in
--- _shared/tests/corpus/llm/app_profile_overrides_vectors.json, section normalize).
---
--- FEATURES & RATIONALE:
--- 1. The key is the lower-cased, trimmed identifier without a trailing ".exe",
---    so an entry typed as "Slack" matches the "slack.exe" Windows reports and a
---    desktop id typed in any case matches the one the session reports.
--- 2. Empty, over-long and control-character identifiers have no key: they are
---    refused rather than stored.
--- 3. PURE Lua (LuaJIT and 5.4): no driver imports, no io.
--- ==============================================================================

local M = {}

-- The longest identifier a setting may hold
M.MAX_CHARS = 256

--- The key an application is stored and looked up under.
--- @param app any The identifier a driver reports, or a user typed.
--- @return string|nil key Lower-cased, trimmed, without ".exe"; nil when unusable.
function M.normalize(app)
	if type(app) ~= "string" then return nil end
	local key = app:match("^%s*(.-)%s*$"):lower():gsub("%.exe$", "")
	if key == "" or #key > M.MAX_CHARS or key:find("%c") then return nil end
	return key
end

return M
