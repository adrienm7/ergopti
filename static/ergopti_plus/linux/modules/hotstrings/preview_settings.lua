--- modules/hotstrings/preview_settings.lua

--- ==============================================================================
--- MODULE: Preview Bubble Settings
--- DESCRIPTION:
--- Owns the four toggles that decide which hotstring previews are shown and
--- whether they are tinted with their category's colour.
---
--- WHY THIS EXISTS:
--- `ui/tooltip/preview.lua` has had the four switches since it was written —
--- `M.set_enabled("star"|"autocorrect"|"ai"|"colored", …)`, read by `M.show` and
--- by `accent_for` — and nothing ever called it. The table was initialised to
--- four `true`s at load and stayed that way for the life of the process, so the
--- manifest declared the features for this driver, the renderer honoured them,
--- and the user had no way to reach them. A switch nobody can flip is the same
--- as no switch, except that it reads as one in the manifest.
---
--- That includes `colored`, which is the setting that decides whether previews
--- carry their category's colour at all — the single most visible thing in the
--- whole preview surface.
---
--- FEATURES & RATIONALE:
--- 1. One owner. The four values are read here and written here; the tooltip
---    module is told about changes rather than consulted for them, so there is
---    no second copy to drift.
--- 2. Defaults from the manifest, never re-typed. `hotstrings.preview_*` already
---    declares each default for this driver; repeating `true` here would be a
---    second source that silently wins the day a default changes.
--- 3. Persisted. These are preferences, and a preference that resets at every
---    restart teaches the user the setting does not work.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Storage = require("adapters.storage")
local ManifestReader = require("infra.manifest_reader")

local LOG = "hotstrings.preview_settings"

-- The four toggles, in the order the menu shows them, each mapped to the
-- manifest path its default comes from and the i18n key that labels it.
--
-- An array rather than a map because the menu needs a stable order and a map
-- has none; the lookups below index it once into `_by_name`.
local TOGGLES = {
	{ name = "star",        manifest = "hotstrings.preview_star_enabled",        label = "menu.hotstrings.tooltip_magic" },
	{ name = "autocorrect", manifest = "hotstrings.preview_autocorrect_enabled", label = "menu.hotstrings.tooltip_autocorrect" },
	{ name = "ai",          manifest = "hotstrings.preview_ai_enabled",          label = "menu.hotstrings.tooltip_ai" },
	{ name = "colored",     manifest = "hotstrings.preview_colored_tooltips",    label = "menu.hotstrings.tooltip_colored" },
}

-- The manifest path doubles as the storage key: the two name the same setting,
-- and keeping them equal removes a mapping that would otherwise have to be kept
-- right by hand.
local _by_name = nil
local _on_change = nil




-- =========================================
-- =========================================
-- ======= 1/ Reading ======================
-- =========================================
-- =========================================

--- Indexes TOGGLES by name, once.
--- @return table
local function by_name()
	if _by_name then return _by_name end
	_by_name = {}
	for _, toggle in ipairs(TOGGLES) do _by_name[toggle.name] = toggle end
	return _by_name
end

--- The toggles in menu order.
--- @return table Array of { name, manifest, label }.
function M.toggles()
	return TOGGLES
end

--- The default the manifest declares for one toggle.
---
--- No literal fallback: a missing key is a build problem, and answering `true`
--- here would hide it behind a setting that looks deliberate.
--- @param name string
--- @return boolean
function M.default(name)
	local toggle = by_name()[name]
	if not toggle then
		Logger.error(LOG, "default(): '%s' is not a preview toggle.", tostring(name))
		return false
	end
	local value = ManifestReader.default_for(toggle.manifest)
	if type(value) == "boolean" then return value end
	Logger.error(LOG, "The manifest declares no boolean default for '%s'.", toggle.manifest)
	return false
end

--- The value in effect: the user's choice, or the manifest default.
--- @param name string
--- @return boolean
function M.get(name)
	local toggle = by_name()[name]
	if not toggle then
		Logger.error(LOG, "get(): '%s' is not a preview toggle.", tostring(name))
		return false
	end
	local stored = Storage.get(toggle.manifest, nil)
	if type(stored) == "boolean" then return stored end
	return M.default(name)
end

--- Whether the user has chosen something other than the shipped value.
--- @param name string
--- @return boolean
function M.is_customised(name)
	local toggle = by_name()[name]
	if not toggle then return false end
	local stored = Storage.get(toggle.manifest, nil)
	return type(stored) == "boolean" and stored ~= M.default(name)
end




-- =========================================
-- =========================================
-- ======= 2/ Writing ======================
-- =========================================
-- =========================================

--- Stores one toggle and announces the change.
--- @param name string
--- @param value boolean
--- @return boolean
function M.set(name, value)
	local toggle = by_name()[name]
	if not toggle then
		Logger.error(LOG, "set(): '%s' is not a preview toggle.", tostring(name))
		return false
	end

	local wanted = value and true or false
	if not Storage.set(toggle.manifest, wanted) then
		Logger.error(LOG, "Could not persist '%s' — the change would be lost at restart.", toggle.manifest)
		return false
	end

	Logger.debug(LOG, "Preview toggle %s: %s.", name, tostring(wanted))
	if type(_on_change) == "function" then _on_change(name, wanted) end
	return true
end

--- Flips one toggle.
--- @param name string
--- @return boolean
function M.toggle(name)
	return M.set(name, not M.get(name))
end




-- =========================================
-- =========================================
-- ======= 3/ Lifecycle ====================
-- =========================================
-- =========================================

--- Pushes every current value into the preview module.
---
--- Called at boot and after each change, because `ui/tooltip/preview.lua` keeps
--- its own copy for the hot path — `M.show` runs on the keystroke that could
--- fire a hotstring, and reading storage there would put a file read in it.
--- @param preview table The ui.tooltip.preview module.
--- @return integer Number of toggles applied.
function M.apply(preview)
	if type(preview) ~= "table" or type(preview.set_enabled) ~= "function" then
		Logger.error(LOG, "apply(): the preview module has no set_enabled — toggles not applied.")
		return 0
	end
	local applied = 0
	for _, toggle in ipairs(TOGGLES) do
		preview.set_enabled(toggle.name, M.get(toggle.name))
		applied = applied + 1
	end
	Logger.debug(LOG, "Applied %d preview toggle(s).", applied)
	return applied
end

--- Registers the callback fired when a toggle changes.
--- @param on_change function|nil Called with (name, value).
function M.init(on_change)
	Logger.start(LOG, "Initializing…")
	if on_change ~= nil and type(on_change) ~= "function" then
		Logger.error(LOG, "M.init(): on_change must be a function — change notifications disabled.")
		on_change = nil
	end
	_on_change = on_change

	local customised = 0
	for _, toggle in ipairs(TOGGLES) do
		if M.is_customised(toggle.name) then customised = customised + 1 end
	end
	Logger.success(LOG, "Initialized (%d toggle(s), %d user-chosen).", #TOGGLES, customised)
end

return M
