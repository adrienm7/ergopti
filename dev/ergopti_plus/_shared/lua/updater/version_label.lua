--- _shared/lua/updater/version_label.lua

--- ==============================================================================
--- MODULE: About Version Row Label (shared)
--- DESCRIPTION:
--- Formats the first row of the About submenu: which build is running and the
--- commit it was built from, e.g. « Version 0.0.0-dev.144 (c3005e0b9) » for a
--- release and « Version locale (c3005e0b9) » for a run from a source checkout.
--- The macOS and Linux drivers call this module; the Windows driver's AHK port
--- is Updater_VersionRowLabel. All ports replay
--- _shared/modules/updater/version_label_vectors.json, which also pins the
--- locale keys below.
---
--- FEATURES & RATIONALE:
--- 1. Three kinds of build, each with its own sentence: a stamped release names
---    its version, a build that is not a stamped release says it is local (a
---    bare "local" read like a version number), and a package whose stamp holds
---    no usable version says the version is unknown.
--- 2. An unknown commit is spelled by its own key. The row never invents a
---    value; the commit owner has already logged why it could not tell.
--- 3. Named placeholders are substituted once, left to right, and the values
---    are used literally, so a "%" or a "{…}" in a value can neither be read as
---    a pattern nor be substituted a second time.
--- 4. Pure: the translator is injected, so the same code runs under
---    Hammerspoon, LuaJIT and the tests.
--- ==============================================================================

local M = {}





-- =====================================
-- =====================================
-- ======= 1/ Contract constants =======
-- =====================================
-- =====================================

-- The kinds of build a row can describe.
M.KIND_RELEASE = "release"
M.KIND_LOCAL = "local"
M.KIND_UNKNOWN = "unknown"

-- The locale key of each kind's sentence. Pinned to version_label_vectors.json.
M.KEYS = {
	[M.KIND_RELEASE] = "menu.about.version_release",
	[M.KIND_LOCAL] = "menu.about.version_local",
	[M.KIND_UNKNOWN] = "menu.about.version_unknown",
}

-- The locale key shown in place of a commit that cannot be determined.
M.UNKNOWN_COMMIT_KEY = "menu.about.commit_unknown"





-- =============================
-- =============================
-- ======= 2/ Formatting =======
-- =============================
-- =============================

--- Substitutes every `{name}` of a template in one pass. A function replacement
--- is used literally by gsub, so a value is never read as a capture reference.
--- @param template string Translated template.
--- @param values table Placeholder name to value.
--- @return string
local function fill(template, values)
	return (template:gsub("{([%w_]+)}", function(name)
		-- nil keeps the placeholder as written: a name this row does not own.
		return values[name]
	end))
end

--- Formats the version row.
--- @param kind string One of the M.KIND_* values.
--- @param version string|nil Release version; read only for a release.
--- @param commit string|nil Abbreviated commit id; nil or "" when unknown.
--- @param translate function Locale lookup: key → translated template.
--- @return string label
function M.format(kind, version, commit, translate)
	local key = M.KEYS[kind]
	if not key then error("unknown build kind '" .. tostring(kind) .. "'", 2) end
	if type(translate) ~= "function" then error("the version row needs a translator", 2) end
	if kind == M.KIND_RELEASE and (type(version) ~= "string" or version == "") then
		error("a release row needs its version", 2)
	end
	local shown_commit = commit
	if type(shown_commit) ~= "string" or shown_commit == "" then
		shown_commit = translate(M.UNKNOWN_COMMIT_KEY)
	end
	return fill(translate(key), { version = version or "", commit = shown_commit })
end

return M
