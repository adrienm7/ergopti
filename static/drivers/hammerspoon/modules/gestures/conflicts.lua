--- modules/gestures/conflicts.lua

--- ==============================================================================
--- MODULE: Gestures Conflicts
--- DESCRIPTION:
--- Manages macOS system gesture conflicts to prevent double-triggering.
--- Provides instructional alerts to guide the user in disabling native gestures.
--- ==============================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Each group maps a human-readable description to the slots that conflict with
-- a built-in macOS gesture, plus the exact path to toggle it in System Settings
local MACOS_GESTURE_GROUPS = {
    {
        key          = "tap_3_conflict",
        slots        = { "tap_3" },
        description  = "Tap 3 doigts — Recherche & détection de données",
        hint         = "Réglages Système › Trackpad › Pointer & cliquer\n→ Décocher « Recherche et détection de données »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_3_horiz_conflict",
        slots        = { "swipe_3_horiz" },
        description  = "Glisser 3 doigts gauche/droite — Pages / Passer d’un espace",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Faire défiler entre les pages » et « Passer d’un espace à l’autre »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_3_vert_conflict",
        slots        = { "swipe_3_up", "swipe_3_down" },
        description  = "Glisser 3 doigts haut/bas — Mission Control & App Exposé",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Mission Control » et « Exposé de l’app »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_4_horiz_conflict",
        slots        = { "swipe_4_horiz", "swipe_5_horiz" },
        description  = "Glisser 4/5 doigts gauche/droite — Passer d’un espace à l’autre",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Passer d’un espace à l’autre »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_4_vert_conflict",
        slots        = { "swipe_4_up", "swipe_4_down", "swipe_5_up", "swipe_5_down" },
        description  = "Glisser 4/5 doigts haut/bas — Mission Control & App Exposé",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Mission Control » et « Exposé de l’app »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
}

local SLOT_TO_GROUP = {}
for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
    for _, slot in ipairs(grp.slots) do
        SLOT_TO_GROUP[slot] = grp
    end
end





-- =================================
-- =================================
-- ======= 2/ Core Evaluator =======
-- =================================
-- =================================

--- Returns true when at least one slot in the group has an active configuration.
--- @param grp table The gesture group.
--- @param ga_table table The active gesture actions map.
--- @return boolean True if active.
local function group_has_active_slot(grp, ga_table)
    for _, slot in ipairs(grp.slots) do
        if (ga_table[slot] or "none") ~= "none" then return true end
    end
    return false
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Generates a warning structure if a new action triggers a system conflict.
--- @param slot string The gesture slot name.
--- @param new_action string The newly assigned action.
--- @return table|nil Warning data or nil if no conflict.
function M.on_action_changed(slot, new_action)
    if new_action == "none" then return nil end
    local grp = SLOT_TO_GROUP[slot]
    if not grp then return nil end
    
    -- A line of dashes forces the blockAlert dialog to be wide enough in UI
    local sep = string.rep("─", 26)
    return {
        msg = string.format(
            "%s\n"
            .. "Ce geste est peut-être géré par macOS :\n"
            .. "« %s »\n\n"
            .. "Si c’est le cas, macOS et Hammerspoon réagiront tous deux en même temps :\n"
            .. "les deux comportements seront envoyés simultanément.\n\n"
            .. "Si encore actif, désactivez-le ici :\n"
            .. "%s\n%s",
            sep, grp.description, grp.hint, sep),
        url = grp.settings_url,
    }
end

--- Logs active conflicts at startup (no automatic preference changes).
--- @param active_actions table The currently configured user actions.
function M.apply_all_overrides(active_actions)
    for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
        if group_has_active_slot(grp, active_actions) then
            print(string.format("[gestures] Conflict active: \"%s\" — user must disable in System Settings", grp.description))
        end
    end
end

--- No-op function (we never modify system prefs automatically).
function M.restore_all_overrides()
end

return M
