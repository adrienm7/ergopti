--- ui/menu/menu_tap_holds.lua

--- ==============================================================================
--- MODULE: Tap-Holds Menu
--- DESCRIPTION:
--- Provides the "Tap-Holds" submenu in the Hammerspoon menu bar: the same row,
--- name and manifest declaration Windows uses for its tap-holds. The remap
--- engine behind it (Karabiner-Elements) is an implementation detail the user
--- never sees, so no label here names it.
---
--- FEATURES & RATIONALE:
--- 1. Tap/Hold section: each key shows "Label : tap / hold" inline, under the
---    header of its hand. Which keys, in which order and under which hand is
---    the shared key catalogue's ([tap_hold.catalog]). Items are grayed out
---    while the remap engine is not initialised.
--- 2. Key combinations: the modifier chords, grouped by key, are the
---    « Combinaisons de touches » group of the Shortcuts submenu, built here
---    (M.build_key_combinations) because this engine runs them. Their own
---    first-row switch is the persisted [mod_combos] enabled.
--- 3. Delay pickers: configure tap/hold and sticky modifier timeouts globally.
--- 4. Changes are saved immediately and applied by an exact regeneration.
--- 5. Restore recommended / clear run the remap engine's tap_holds scope: a
---    verified backup, then the exact terminal. Only the clear asks first,
---    with a default-No question; the restore applies at once.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local MenuUtils   = require("ui.menu.menu_utils")
local ManifestMenu = require("infra.manifest_menu")
local Paths       = require("infra.paths")
local KeyCatalog  = require("tap_hold.key_catalog")
local CombinationLabels = require("tap_hold.combination_labels")
local LOG         = "menu.tap_holds"
local i18n        = require("infra.i18n")
local text_utils  = require("infra.text_utils")
local WindowTitles = require("window_titles")




--- Builds the AppleScript for a numeric-input dialog.
---
--- Every interpolated label is i18n text from a 21-locale corpus, so it goes
--- through applescript_escape rather than Lua's %q. %q escapes for a LUA literal
--- and agrees with AppleScript only by coincidence — it diverges on control
--- characters and emits \ddd decimal escapes AppleScript cannot read. The four
--- call sites below used to carry four copies of this format string.
--- @param prompt string Dialog body text.
--- @param default_ms number Pre-filled numeric answer.
--- @param title string Window title.
--- @param btn_cancel string Cancel button label.
--- @param btn_ok string OK button label, also the default button.
--- @return string The AppleScript source.
local function delay_dialog_script(prompt, default_ms, title, btn_cancel, btn_ok)
	-- TOML numeric values may be fractional even though every setter persists an
	-- integer. Normalize at the format boundary so a hand-edited value cannot
	-- make Lua's %d conversion abort the menu callback before the dialog opens.
	local integral_default_ms = math.floor(default_ms)
	return text_utils.applescript_format(
		"display dialog \"%s\" default answer \"%d\" with title \"%s\" "
			.. "buttons {\"%s\", \"%s\"} default button \"%s\"",
		prompt, integral_default_ms, WindowTitles.compose(title), btn_cancel, btn_ok, btn_ok)
end

-- Label displayed when both tap and hold are "none"
local NONE_DISPLAY = "—"




-- =====================================
-- =====================================
-- ======= 1/ Helper Utilities =========
-- =====================================
-- =====================================

--- Requests an exact-lease regeneration without letting a menu callback throw.
--- @param karabiner table Remap facade.
--- @param source string User action label for diagnostics.
--- @return boolean accepted
local function request_regeneration(karabiner, source)
	local ok, requested_or_err = xpcall(function()
		return karabiner.regenerate()
	end, debug.traceback)
	if not ok or requested_or_err ~= true then
		Logger.error(LOG, "%s exact lease start request failed: %s.",
			tostring(source), tostring(requested_or_err))
		return false
	end
	return true
end

--- Commits one synchronous facade mutation before requesting regeneration.
--- A thrown, false, or nil setter result stops at the persistence boundary, so
--- a bulk-transaction gate cannot be bypassed by a stale menu closure.
--- @param karabiner table Remap facade.
--- @param source string User action label for diagnostics.
--- @param mutate function Synchronous mutation returning literal true on commit.
--- @param update_menu function|nil Menu refresh callback.
--- @return boolean accepted
local function commit_menu_setting(karabiner, source, mutate, update_menu)
	local call_ok, committed_or_err = xpcall(mutate, debug.traceback)
	if not call_ok or committed_or_err ~= true then
		Logger.error(LOG, "%s setting mutation failed: %s.",
			tostring(source), tostring(committed_or_err))
		return false
	end
	local accepted = request_regeneration(karabiner, source)
	if update_menu then
		local refresh_ok, refresh_err = pcall(update_menu)
		if not refresh_ok then
			Logger.error(LOG, "%s menu refresh failed: %s.",
				tostring(source), tostring(refresh_err))
		end
	end
	return accepted
end

-- The saved-edit notice for each guardian status Login Items can fix. The
-- guardian registers once per launch, so allowing an unregistered helper
-- changes nothing until ErgoptiPlus is reopened; only an approval applies at
-- once.
local SAVED_UNTIL_GUARDIAN_KEYS = {
	requires_approval = "menu.tapholds.saved_until_guardian",
	unavailable       = "menu.tapholds.saved_until_guardian_restart",
}
-- Every other wait (a failed or timed-out probe, a helper that could not be
-- launched) says nothing of the user's settings: sending them to a Login
-- Items pane where everything may already be allowed would mislead.
local SAVED_UNTIL_HELPER_KEY = "menu.tapholds.saved_until_helper"

--- Tells the user a Login Items pane did not open, as the guardian's own
--- notice does: one localized notice. A launch the system refused is already
--- logged as an error by the runner, and every error line raises a developer
--- notification of its own, so this side records the detail as a warning.
--- @param opened boolean Whether the pane opened.
--- @param detail any Opener failure detail.
local function report_login_items_opened(opened, detail)
	if opened == true then return end
	Logger.warn(LOG, "Login Items settings could not be opened: %s.", tostring(detail))
	local ok, sent_or_err = pcall(require("infra.notifications").notify,
		i18n.get("karabiner.guardian_settings_open_failed"), nil, "error")
	if not ok or sent_or_err ~= true then
		Logger.error(LOG, "Login Items failure notice was not delivered: %s.", tostring(sent_or_err))
	end
end

--- Tells the user a bulk edit is saved but waits for the remap guardian: the
--- menu shows the new settings, yet nothing applies them until the guardian
--- is ready, and the notice says what makes it ready. When Login Items can,
--- the click opens that pane.
--- @param karabiner table Remap facade.
--- @param method_name string Facade method name, for the log.
--- @param reason string `persisted-guardian-<status>` terminal detail.
local function announce_saved_until_guardian(karabiner, method_name, reason)
	Logger.info(LOG, "Karabiner bulk command '%s' saved; its rules deploy once the guardian is ready (%s).",
		method_name, tostring(reason))
	local key = SAVED_UNTIL_GUARDIAN_KEYS[reason:match("^persisted%-guardian%-(.+)$")]
	local on_click = nil
	if key == nil then
		key = SAVED_UNTIL_HELPER_KEY
	elseif type(karabiner.open_login_items) == "function" then
		on_click = function()
			return karabiner.open_login_items(report_login_items_opened) == true
		end
	end
	local ok, sent_or_err = pcall(require("infra.notifications").notify,
		i18n.get(key), nil, "info", on_click)
	if not ok or sent_or_err ~= true then
		Logger.error(LOG, "Saved-until-guardian notice was not delivered: %s.", tostring(sent_or_err))
	end
end

--- Runs one manifest bulk command and publishes success only after both exact
--- request acceptance and the transaction's terminal callback are true.
--- @param karabiner table Remap facade.
--- @param method_name string Facade method name.
--- @param start_message string START log message.
--- @param success_message string SUCCESS log format.
--- @param success_uses_count boolean Whether the format consumes change_count.
--- @param update_menu function|nil Menu refresh callback.
--- @param operation_arg string|nil Optional identifier passed before callback.
--- @return boolean accepted
local function run_bulk_menu_command(
	karabiner,
	method_name,
	start_message,
	success_message,
	success_uses_count,
	update_menu,
	operation_arg
)
	local operation = karabiner and karabiner[method_name]
	Logger.start(LOG, start_message)
	if type(operation) ~= "function" then
		Logger.error(LOG, "Karabiner bulk command '%s' is unavailable.", method_name)
		return false
	end

	local callback_seen = false
	local dispatching = true
	local pending_ok = false
	local pending_reason = nil
	local pending_count = 0
	local function finish(ok, reason, change_count)
		if callback_seen then
			Logger.warn(LOG, "Duplicate Karabiner bulk command '%s' callback ignored.", method_name)
			return
		end
		callback_seen = true
		if dispatching then
			pending_ok = ok == true
			pending_reason = reason
			pending_count = tonumber(change_count) or 0
			return
		end
		if ok == true then
			if success_uses_count then
				Logger.success(LOG, success_message, tonumber(change_count) or 0)
			else
				Logger.success(LOG, success_message)
			end
			if type(reason) == "string" and reason:find("^persisted%-guardian%-") then
				announce_saved_until_guardian(karabiner, method_name, reason)
			end
		else
			Logger.error(LOG, "Karabiner bulk command '%s' failed: %s.",
				method_name, tostring(reason))
		end
		if update_menu then
			local refresh_ok, refresh_err = pcall(update_menu)
			if not refresh_ok then
				Logger.error(LOG, "Karabiner menu refresh after '%s' failed: %s.",
					method_name, tostring(refresh_err))
			end
		end
	end

	local call_ok, accepted_or_err = xpcall(function()
		if operation_arg ~= nil then
			return operation(operation_arg, finish)
		end
		return operation(finish)
	end, debug.traceback)
	dispatching = false
	if not call_ok or accepted_or_err ~= true then
		-- A refusal names its cause (bulk-settings-busy, script-paused...)
		-- through the terminal it already fired; only a request that fired
		-- none falls back to the generic detail.
		local refusal = call_ok and callback_seen and pending_ok ~= true
			and pending_reason ~= nil and pending_reason or nil
		callback_seen = false
		finish(false, refusal or (call_ok and "request-refused" or accepted_or_err), 0)
		return false
	end
	if callback_seen then
		callback_seen = false
		finish(pending_ok, pending_reason, pending_count)
	end
	return true
end

-- Makes each scope backup path unique within the session.
local _scope_generation = 0

--- Applies one remap scope mode through the native transaction, at once for
--- both modes: the backup it writes first is the way back, so a clear asks no
--- question either (the maintainer's rule of 2026-09-30).
--- Each scope belongs to its native remap owner and leaves other groups alone.
--- @param karabiner table Remap facade.
--- @param mode string "recommended" or "clear".
--- @param update_menu function|nil Menu refresh callback.
--- @param scope string|nil "tap_holds" by default, or "key_combinations".
--- @return boolean accepted
local function run_scope(karabiner, mode, update_menu, scope)
	scope = scope or "tap_holds"
	_scope_generation = _scope_generation + 1
	local backup_path = require("infra.config_paths").get("KarabinerConfigPath") .. "." .. scope .. "-"
		.. tostring(hs.timer.absoluteTime()) .. "-" .. _scope_generation .. ".bak"
	return run_bulk_menu_command(
		karabiner,
		"apply_scope",
		"Applying the " .. scope .. " scope (" .. mode .. ")…",
		scope .. " scope " .. mode .. " applied.",
		false,
		update_menu,
		{ scope = scope, mode = mode, backup_path = backup_path }
	)
end

--- Builds an index of action id → action definition for fast lookup.
--- @param karabiner table The karabiner module.
--- @return table Map of id → action def.
local function build_action_index(karabiner)
	local index = {}
	for _, action in ipairs(karabiner.AVAILABLE_ACTIONS) do
		index[action.id] = action
	end
	return index
end

--- Returns the short_label (or label fallback) for an action id.
--- @param action_index table id → action def map.
--- @param action_id string The action id to look up.
--- @return string Short human-readable label.
local function short_action_label(action_index, action_id)
	local def = action_index[action_id]
	if not def then return "? " .. tostring(action_id) end
	return def.short_label or def.label
end

--- Formats a timeout value in ms as a human-readable string.
--- @param ms number Milliseconds.
--- @return string e.g. "500 ms" or "1 s" or "1,5 s".
local function fmt_delay(ms)
	if not ms then return "?" end
	if ms < 1000 then
		return tostring(ms) .. " ms"
	elseif ms % 1000 == 0 then
		return tostring(ms // 1000) .. " s"
	else
		return (string.format("%.1f s", ms / 1000):gsub("%.", ","))
	end
end




-- =========================================
-- =========================================
-- ======= 2/ Action Picker Submenu =========
-- =========================================
-- =========================================

--- Builds the list of action items for any picker submenu.
--- Uses full labels grouped by category. The active choice is checked.
---
--- Slot modes control which actions are shown:
---   "tap"  — excludes actions with tappable == false (modifiers, combos, layer-hold).
---   "hold" — shows only actions with holdable == true (modifiers, combos, layer-hold).
---
--- @param karabiner   table    The karabiner module.
--- @param set_fn      function Called with (action_id) when user picks.
--- @param current_id  string   Currently selected action id.
--- @param update_menu function Callback to refresh the menu bar.
--- @param slot        string   "tap", "hold", or "combo".
--- @return table List of hs.menubar menu item tables.
local function build_action_picker(karabiner, set_fn, current_id, update_menu, slot)
	-- Filter: exclude actions that don't match the slot mode
	local function slot_filter(action)
		if slot == "hold" and not action.holdable      then return false end
		if slot == "tap"  and action.tappable == false then return false end
		return true
	end

	-- "Spécial" items (none, CapsWord) are shown ungrouped at the top — skip the header
	local function special_filter(action)
		return action.category ~= "Spécial"
	end

	-- Collect Spécial actions first (ungrouped), then the rest via MenuUtils
	local items = {}
	local non_special = {}
	for _, action in ipairs(karabiner.AVAILABLE_ACTIONS) do
		if not slot_filter(action) then goto continue end
		if not special_filter(action) then
			-- Spécial: show directly without category header
			local aid = action.id
			items[#items + 1] = {
				label   = action.label,
				checked = (aid == current_id),
				action      = function()
					return commit_menu_setting(karabiner, "Action picker", function()
						return set_fn(aid)
					end, update_menu)
				end,
			}
		else
			table.insert(non_special, action)
		end
		::continue::
	end

	-- Now use MenuUtils for the grouped, non-Spécial actions
	if #non_special > 0 then
		if #items > 0 then items[#items + 1] = { separator = true } end
		local grouped = MenuUtils.build_action_picker(non_special, current_id, function(aid)
			return commit_menu_setting(karabiner, "Grouped action picker", function()
				return set_fn(aid)
			end, update_menu)
		end)
		for _, it in ipairs(grouped) do
			items[#items + 1] = it
		end
	end

	return items
end




-- =========================================
-- =========================================
-- ======= 3/ Tap/Hold Key Submenus =========
-- =========================================
-- =========================================

-- The macOS column of the shared key catalogue ([tap_hold.catalog] in
-- _shared/tap_hold/defaults.toml): which keys this submenu lists, in which
-- order, under which hand and with which label. Read once, on first use.
--
-- It replaces a reader of a `tap_hold_keys_catalog` menu-manifest key that
-- never existed, so its built-in fallback always won — and that fallback said
-- `action = true` where `fn = true` was meant, which listed Fn under the right
-- hand.
local _key_catalog = nil

--- Returns this driver's keys from the shared tap-hold key catalogue.
--- Raises when the catalogue is unreadable or malformed: the list providers
--- calling it are isolated by the renderer, which logs the failure.
--- @return table Array of { id, key, hand, label_key } in tray order.
local function key_catalog()
	if _key_catalog == nil then
		_key_catalog = KeyCatalog.load(Paths.shared("tap_hold/defaults.toml"), "hs")
	end
	return _key_catalog
end

--- Builds a single tap / hold menu item for one key definition.
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @param key_def     table    Entry from TAP_HOLD_KEYS.
--- @param key_label   string   Translated key name, from the shared catalogue.
--- @return table hs.menubar menu item.
local function build_one_tap_hold_item(karabiner, action_index, update_menu, enabled, key_def, key_label)
	local kid = key_def.id

	local ok_tap,  current_tap  = pcall(karabiner.get_tap_action,  kid)
	local ok_hold, current_hold = pcall(karabiner.get_hold_action, kid)

	if not ok_tap  then current_tap  = "none" end
	if not ok_hold then current_hold = "none" end

	local tap_slbl  = short_action_label(action_index, current_tap)
	local hold_slbl = short_action_label(action_index, current_hold)
	local is_active = (current_tap ~= "none" or current_hold ~= "none")

	-- Per-key tap/hold threshold: the effective value is the per-key override when
	-- set, otherwise the single global timeout (no duplicated literal when unset).
	local global_ms = karabiner.get_tap_hold_timeout() or karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS
	local ok_to, per_key_ms = pcall(karabiner.get_tap_timeout, kid)
	if not ok_to then per_key_ms = nil end
	local effective_ms = per_key_ms or global_ms

	-- Show "—" when nothing is configured on this key
	local combo_label = (current_tap == "none" and current_hold == "none")
		and NONE_DISPLAY
		or  (tap_slbl .. "  /  " .. hold_slbl)

	-- Native delay dialogs and persistence retain their existing mutation owners.
	local delay_rows = ManifestMenu.template_rows("tap_hold_key_delay_rows", {
		["tap_hold_key_delay_set"] = function()
			hs.focus()
			local prompt = string.format(
				i18n.get("menu.tapholds.key_tap_delay_dialog_prompt"), global_ms)
			local title_d    = i18n.get("menu.tapholds.key_tap_delay_dialog_title")
			local btn_ok     = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = delay_dialog_script(prompt, effective_ms, title_d, btn_cancel, btn_ok)
			local call_ok, ok, result = pcall(hs.osascript.applescript, script)
			if not call_ok or ok ~= true or type(result) ~= "table"
				or type(result["text returned"]) ~= "string" then return false end
			local ms = tonumber(result["text returned"])
			if not ms or ms ~= ms or ms == math.huge or ms <= 0 or math.floor(ms) <= 0 then
				Logger.warn(LOG, "Invalid per-key delay '%s' — ignored.", tostring(result["text returned"]))
				return false
			end
			return commit_menu_setting(karabiner, "Per-key tap/hold timeout", function()
				return karabiner.set_tap_timeout(kid, math.floor(ms))
			end, update_menu)
		end,
		["tap_hold_key_delay_use_global"] = function()
			return commit_menu_setting(karabiner, "Per-key timeout reset", function()
				return karabiner.set_tap_timeout(kid, nil)
			end, update_menu)
		end,
	}, {
		["tap_hold_key_global_delay_caption"] = function() return fmt_delay(global_ms) end,
		["tap_hold_key_delay_is_global"] = function() return per_key_ms == nil end,
		["tap_hold_key_delay_has_override"] = function() return per_key_ms ~= nil end,
	})
	if not delay_rows then return nil end

	local key_submenu = ManifestMenu.template_rows("tap_hold_key_rows", {
		["tap_hold_key_no_action"] = function()
			return run_bulk_menu_command(
				karabiner,
				"clear_tap_hold_binding",
				"Clearing one tap/hold binding…",
				"Tap/hold binding cleared.",
				false,
				update_menu,
				kid
			)
		end,
	}, {
		["tap_hold_key_configured"] = function() return is_active end,
		["tap_hold_key_tap_caption"] = function() return tap_slbl end,
		["tap_hold_key_hold_caption"] = function() return hold_slbl end,
		["tap_hold_key_delay_caption"] = function() return fmt_delay(effective_ms) end,
	}, {
		["tap_hold_key_delay"] = delay_rows,
		["tap_hold_key_tap_picker"] = build_action_picker(
			karabiner,
			function(action_id) return karabiner.set_tap_action(kid, action_id) end,
			current_tap,
			update_menu,
			"tap"
		),
		["tap_hold_key_hold_picker"] = build_action_picker(
			karabiner,
			function(action_id) return karabiner.set_hold_action(kid, action_id) end,
			current_hold,
			update_menu,
			"hold"
		),
	})
	if not key_submenu then return nil end

	return {
		label    = string.format("%s  :  %s", key_label, combo_label),
		checked  = is_active or nil,
		disabled = not enabled or nil,
		items     = enabled and key_submenu or nil,
	}
end

--- Builds the tap / hold rows of one hand, in catalogue order.
---
--- The manifest owns the two hand headers and the separator between the hands;
--- this returns only the key rows beneath one header. A key the remap engine
--- knows and the shared catalogue does not list gets no row, and
--- build_picker_trees reports it.
--- Items are grayed out when the integration is disabled.
---
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @param hand        string   "left" or "right".
--- @return table List of hs.menubar menu item tables.
local function build_hand_items(karabiner, action_index, update_menu, enabled, hand)
	local engine_keys = {}
	for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS or {}) do engine_keys[key_def.id] = key_def end
	local items = {}
	for _, entry in ipairs(KeyCatalog.of_hand(key_catalog(), hand)) do
		local key_def = engine_keys[entry.id]
		if key_def then
			items[#items + 1] = build_one_tap_hold_item(
				karabiner, action_index, update_menu, enabled, key_def, i18n.get(entry.label_key))
		end
	end
	return items
end

--- Reports every key the remap engine can bind that the shared catalogue does
--- not list: such a key would silently have no row in the submenu.
--- @param karabiner table The karabiner module.
local function report_uncatalogued_keys(karabiner)
	local listed = {}
	for _, entry in ipairs(key_catalog()) do listed[entry.id] = true end
	for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS or {}) do
		if not listed[key_def.id] then
			Logger.error(LOG, "Tap-hold key '%s' is missing from [tap_hold.catalog] — it has no menu row.",
				tostring(key_def.id))
		end
	end
end





-- ==========================================
-- ==========================================
-- ======= 4/ Raccourcis (Mod Combos) =======
-- ==========================================
-- ==========================================

--- Builds a single combo menu item with combo / tap / hold sub-pickers.
--- Shows "ComboLabel  /  TapLabel  /  HoldLabel" next to the combo label.
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @param combo_def   table    Entry from MOD_COMBOS.
--- @param pair_label  string   Canonical translated physical pair.
--- @return table hs.menubar menu item.
local function build_one_combo_item(karabiner, action_index, update_menu, enabled, combo_def, pair_label)
	local cid = combo_def.id

	local ok_tap,   current_tap   = pcall(karabiner.get_combo_tap_action,   cid)
	local ok_hold,  current_hold  = pcall(karabiner.get_combo_hold_action,  cid)
	local ok_combo, current_combo = pcall(karabiner.get_combo_combo_action, cid)
	if not ok_tap   then current_tap   = "none" end
	if not ok_hold  then current_hold  = "none" end
	if not ok_combo then current_combo = "none" end

	local tap_slbl   = short_action_label(action_index, current_tap)
	local hold_slbl  = short_action_label(action_index, current_hold)
	local combo_slbl = short_action_label(action_index, current_combo)
	local is_empty   = (current_tap == "none" and current_hold == "none" and current_combo == "none")
	local is_active  = not is_empty

	local combo_label = is_empty and NONE_DISPLAY
		or string.format("%s  /  %s  /  %s", combo_slbl, tap_slbl, hold_slbl)

	local slots = {
		{
			label = string.format(i18n.get("menu.shortcuts.key_combinations_chord"), combo_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) return karabiner.set_combo_combo_action(cid, action_id) end,
				current_combo,
				update_menu,
				"combo"
			),
		},
		{
			label = string.format(i18n.get("menu.shortcuts.key_combinations_hold_tap"), tap_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) return karabiner.set_combo_tap_action(cid, action_id) end,
				current_tap,
				update_menu,
				"tap"
			),
		},
		{
			label = string.format(i18n.get("menu.shortcuts.key_combinations_hold_hold"), hold_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) return karabiner.set_combo_hold_action(cid, action_id) end,
				current_hold,
				update_menu,
				"hold"
			),
		},
	}

	local render_ctx = {
		commands = {
			["key_combination_clear"] = function()
				return run_bulk_menu_command(karabiner, "clear_combo_binding",
					"Clearing one modifier combo…", "Modifier combo cleared.", false, update_menu, cid)
			end,
		},
		state_getters = { ["key_combination_pair_assigned"] = function() return is_active end },
	}
	local combo_submenu = ManifestMenu.build("key_combination_pair_menu", "KeyCombinations", nil, nil,
		render_ctx, { ["key_combination_slots"] = function() return slots end })

	return {
		label    = string.format("%s  :  %s", pair_label, combo_label),
		checked  = is_active or nil,
		disabled = not enabled or nil,
		-- This child has already passed through the shared renderer.
		submenu   = enabled and combo_submenu or nil,
	}
end

--- The hand a modifier combo is listed under: the hand of the key held first,
--- as the shared tap-hold catalogue assigns it.
--- @param combo_def table Entry from MOD_COMBOS.
--- @return string|nil "left" or "right"; nil when its first key is not catalogued.
local function combo_hand(combo_def)
	local from = type(combo_def.from) == "table" and combo_def.from.simultaneous
	local first = type(from) == "table" and from[1]
	local key_code = type(first) == "table" and first.key_code
	for _, entry in ipairs(key_catalog()) do
		if entry.id == key_code then return entry.hand end
	end
	return nil
end

--- Logs every modifier combo whose first key the catalogue does not list: it
--- belongs to no hand, so neither list of the group can show it.
--- @param karabiner table The karabiner module.
local function report_unplaced_combos(karabiner)
	for _, combo_def in ipairs(karabiner.MOD_COMBOS or {}) do
		if not combo_def.menu_hidden and combo_hand(combo_def) == nil then
			Logger.error(LOG, "Modifier combo '%s' begins on a key missing from [tap_hold.catalog] — it has no menu row.",
				tostring(combo_def.id))
		end
	end
end

--- Builds one hand's modifier combos, grouped by the first physical key.
--- Items are grayed out when the integration is disabled.
---
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @param hand        string   "left" or "right": the hand of the key held first.
--- @return table List of hs.menubar menu item tables.
local function build_raccourcis_items(karabiner, action_index, update_menu, enabled, hand)
	local items         = {}
	local current_group = nil
	local is_symmetric  = karabiner.get_combo_symmetric()
	local non_canonical = karabiner.NON_CANONICAL_COMBOS or {}

	for _, combo_def in ipairs(karabiner.MOD_COMBOS) do
		-- Skip combos handled elsewhere (e.g. script_control.lua shortcuts)
		if combo_def.menu_hidden then goto continue end
		-- In symmetric mode, non-canonical combos (reverse-order duplicates of a
		-- canonical entry) are hidden: the canonical half configures the chord for
		-- both press orders, so showing the reverse would confuse the user.
		if is_symmetric and non_canonical[combo_def.id] then goto continue end
		if combo_hand(combo_def) ~= hand then goto continue end

		local keys = combo_def.from.simultaneous
		local labels = CombinationLabels.resolve(key_catalog(), keys[1].key_code, keys[2].key_code, i18n.get)
		if labels.group_id ~= current_group then
			items[#items + 1] = MenuUtils.build_section_header(labels.group_label)
			current_group = labels.group_id
		end
		items[#items + 1] = build_one_combo_item(
			karabiner, action_index, update_menu, enabled, combo_def, labels.label)

		::continue::
	end

	return items
end





-- ====================================
-- ====================================
-- ======= 5/ Delay Input Items =======
-- ====================================
-- ====================================

--- Builds the tap / hold delay item. Clicking it opens an AppleScript input dialog
--- so the user can type any value freely, not limited to a preset list.
--- The value is set globally in complex_modifications.parameters and applies to
--- ALL tap / hold rules without per-manipulator overrides.
--- The default displayed in the dialog comes from the module — single source of truth.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return table hs.menubar menu item.
local function build_delay_item(karabiner, update_menu)
	local timeout_ms = karabiner.get_tap_hold_timeout()

	return {
		label = string.format(i18n.get("menu.tapholds.tap_hold_title"), fmt_delay(timeout_ms)),
		action    = function()
			-- Bring Hammerspoon to front so the dialog appears above other windows
			hs.focus()
			local prompt = string.format(i18n.get("menu.tapholds.tap_hold_dialog_prompt"), karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS)
			local title_d = i18n.get("menu.tapholds.tap_hold_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = delay_dialog_script(prompt,
				timeout_ms or karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS, title_d, btn_cancel, btn_ok)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Delay input dialog: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid delay input '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			commit_menu_setting(karabiner, "Tap/hold timeout", function()
				return karabiner.set_tap_hold_timeout(math.floor(ms))
			end, update_menu)
		end,
	}
end

--- Builds the sticky modifier timeout item. Clicking opens a free-text input dialog.
--- The default displayed in the dialog comes from the module — single source of truth.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return table hs.menubar menu item.
local function build_sticky_delay_item(karabiner, update_menu)
	local timeout_ms = karabiner.get_sticky_timeout()

	return {
		label = string.format(i18n.get("menu.tapholds.sticky_title"), fmt_delay(timeout_ms)),
		action    = function()
			hs.focus()
			local prompt = i18n.get("menu.tapholds.sticky_dialog_prompt")
			local title_d = i18n.get("menu.tapholds.sticky_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = delay_dialog_script(prompt,
				timeout_ms or karabiner.DEFAULT_STICKY_TIMEOUT_MS, title_d, btn_cancel, btn_ok)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Sticky delay input: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid sticky delay '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			commit_menu_setting(karabiner, "Sticky timeout", function()
				return karabiner.set_sticky_timeout(math.floor(ms))
			end, update_menu)
		end,
	}
end

--- Builds the combo activation window item. Clicking opens a free-text input dialog.
--- Controls `basic.simultaneous_threshold_milliseconds` — the maximum delay
--- between the two keys of a shortcut for KE to fire the combo (chord) slot.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return table hs.menubar menu item.
local function build_simultaneous_threshold_item(karabiner, update_menu)
	local threshold_ms = karabiner.get_simultaneous_threshold()

	return {
		label = string.format(i18n.get("menu.tapholds.simultaneous_title"), fmt_delay(threshold_ms)),
		action    = function()
			hs.focus()
			local prompt = string.format(i18n.get("menu.tapholds.simultaneous_dialog_prompt"), karabiner.DEFAULT_SIMULTANEOUS_THRESHOLD_MS)
			local title_d = i18n.get("menu.tapholds.simultaneous_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = delay_dialog_script(prompt,
				threshold_ms or karabiner.DEFAULT_SIMULTANEOUS_THRESHOLD_MS, title_d, btn_cancel, btn_ok)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Simultaneous threshold input: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid threshold '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			commit_menu_setting(karabiner, "Simultaneous threshold", function()
				return karabiner.set_simultaneous_threshold(math.floor(ms))
			end, update_menu)
		end,
	}
end

--- Toggles symmetric combinations: when on, "touche 1 + touche 2" and "touche 2
--- + touche 1" fire the same chord, and the reverse half of each pair is hidden
--- from the pair rows to avoid duplicates. The row is the manifest's `check`
--- combo_symmetric; this is only what a click does.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return boolean accepted
local function toggle_combo_symmetric(karabiner, update_menu)
	local is_symmetric = karabiner.get_combo_symmetric() == true
	return commit_menu_setting(karabiner, "Combo symmetry", function()
		return karabiner.set_combo_symmetric(not is_symmetric)
	end, update_menu)
end





-- ======================================
-- ======================================
-- ======= 6/ Top-Level Builder =========
-- ======================================
-- ======================================

-- Cached tap/hold + raccourcis picker trees. Building them is the dominant cost
-- of opening the menubar (~300-380 ms measured): 182 modifier combos × a 73-action
-- picker each is ~40k menu tables + closures, and the old code rebuilt the whole
-- lot on EVERY click. The trees depend only on the per-slot action bindings, the
-- symmetric-combo toggle and the enabled flag, so we memoise them under a
-- fingerprint of exactly those inputs and rebuild only when a binding actually
-- changes. A click that edits a binding changes the fingerprint, so the next open
-- rebuilds with fresh checkmarks. update_menu is a stable upvalue (set once in
-- ui.menu.init), so the cached closures stay valid across opens.
local _picker_cache = nil

--- Cheap fingerprint of every input that affects the picker trees. Reads in-memory
--- config accessors only (no I/O), so it is far cheaper than a rebuild.
--- @param karabiner table The karabiner module.
--- @param enabled boolean Whether the integration is active.
--- @return string
local function picker_fingerprint(karabiner, enabled)
	local parts = { enabled and "1" or "0", i18n.get_locale() }
	local ok_sym, sym = pcall(karabiner.get_combo_symmetric)
	parts[#parts + 1] = (ok_sym and sym) and "1" or "0"
	-- The global tap/hold timeout is rendered in every per-key delay submenu
	-- (the "use global (%s)" label and the effective value when no override), so a
	-- global change must invalidate the cached picker trees as well.
	local ok_g, g = pcall(karabiner.get_tap_hold_timeout)
	parts[#parts + 1] = (ok_g and g ~= nil) and tostring(g) or "none"
	local function add(getter, id)
		local ok, v = pcall(getter, id)
		parts[#parts + 1] = (ok and v ~= nil) and tostring(v) or "none"
	end
	for _, kd in ipairs(karabiner.TAP_HOLD_KEYS or {}) do
		add(karabiner.get_tap_action,  kd.id)
		add(karabiner.get_hold_action, kd.id)
		add(karabiner.get_tap_timeout, kd.id)  -- per-key delay shows in the submenu label
	end
	for _, cd in ipairs(karabiner.MOD_COMBOS or {}) do
		add(karabiner.get_combo_combo_action, cd.id)
		add(karabiner.get_combo_tap_action,   cd.id)
		add(karabiner.get_combo_hold_action,  cd.id)
	end
	return table.concat(parts, "|")
end

--- Returns the (memoised) tap/hold and raccourcis picker trees, rebuilding only
--- when the binding fingerprint changes. See _picker_cache rationale above.
--- @return table tap_hold { left, right } key rows per hand, table raccourcis
---         { left, right } combo rows per hand of the key held first
local function build_picker_trees(karabiner, update_menu, enabled)
	local fp = picker_fingerprint(karabiner, enabled)
	if _picker_cache and _picker_cache.fp == fp then
		Logger.debug(LOG, "Picker trees served from cache.")
		return _picker_cache.tap_hold, _picker_cache.raccourcis
	end
	Logger.debug(LOG, "Picker trees rebuilt (binding fingerprint changed).")
	report_uncatalogued_keys(karabiner)
	local action_index = build_action_index(karabiner)
	local tap_hold = {
		left  = build_hand_items(karabiner, action_index, update_menu, enabled, "left"),
		right = build_hand_items(karabiner, action_index, update_menu, enabled, "right"),
	}
	report_unplaced_combos(karabiner)
	local raccourcis = {
		left  = build_raccourcis_items(karabiner, action_index, update_menu, enabled, "left"),
		right = build_raccourcis_items(karabiner, action_index, update_menu, enabled, "right"),
	}
	_picker_cache = { fp = fp, tap_hold = tap_hold, raccourcis = raccourcis }
	return tap_hold, raccourcis
end

--- Leads a greyed group of rows with the reason they are unavailable.
--- @param rows table Cached rows, shared with later builds and never mutated.
--- @param enabled boolean « Ergopti uses Karabiner ».
--- @return table rows The cached rows when on, or a fresh list led by the hint.
local function with_karabiner_off_hint(rows, enabled)
	if enabled then return rows end
	local hinted = ManifestMenu.template_rows("tap_hold_karabiner_off_rows", {})
	if not hinted then return nil end
	for _, row in ipairs(rows) do hinted[#hinted + 1] = row end
	return hinted
end

--- Supplies the existing callback that reopens the Login Items steps.
--- @param karabiner table Remap facade.
--- @return function command
local function login_items_steps_command(karabiner)
	return function()
		Logger.info(LOG, "Showing the Login Items steps again from the Tap-Holds menu.")
		local ok, shown = xpcall(function()
			return require("ui.permission_dialog.login_items_guide").reopen(karabiner)
		end, debug.traceback)
		if not ok then
			Logger.error(LOG, "The Login Items steps could not be shown: %s.", tostring(shown))
			return false
		end
		return shown == true
	end
end

-- Native guardian states retain their original opener selection. Each provider
-- reads the corresponding shared presentation; the native owner admits actions.
local GUARDIAN_STATUS_ROWS = {
	requires_approval = {
		rows = function(karabiner)
			return ManifestMenu.template_rows("tap_hold_guardian_approval_rows", {
				["tap_hold_login_items_steps"] = login_items_steps_command(karabiner),
			})
		end,
		opener = "open_guardian_settings",
	},
	unavailable = {
		rows = function()
			return ManifestMenu.template_rows("tap_hold_guardian_unavailable_rows", {})
		end,
		opener = "open_login_items",
	},
}

--- The rows that say why switched-on tap-holds do nothing: the remap guardian
--- is not ready, so no rule deploys, and before these rows only the log said so.
--- @param karabiner table Remap facade.
--- @param tap_holds_on boolean Tap-Holds feature switch.
--- @return table rows Empty unless the rules wait on the guardian.
local function guardian_status_rows(karabiner, tap_holds_on)
	if not tap_holds_on or karabiner.get_enabled() ~= true
		or type(karabiner.guardian_state) ~= "function" then return {} end
	local ok, state = pcall(karabiner.guardian_state)
	local spec = ok and GUARDIAN_STATUS_ROWS[state] or nil
	if not spec then return {} end
	local opener = karabiner[spec.opener]
	local rows = spec.rows(karabiner)
	if not rows then return {} end
	if type(opener) == "function" then
		local open_rows = ManifestMenu.template_rows("tap_hold_login_items_open_rows", {
			["tap_hold_login_items_open"] = function()
				Logger.info(LOG, "Opening Login Items for the remap guardian (%s).", state)
				return opener(report_login_items_opened) == true
			end,
		})
		if not open_rows then return rows end
		for _, row in ipairs(open_rows) do rows[#rows + 1] = row end
	end
	return rows
end

--- The row that removes the rules an older ErgoptiPlus left in Karabiner,
--- shown only while they keep every setting from being applied. Its dialog is
--- the one the remap bridge offers by itself once per launch.
--- @param karabiner table Remap facade.
--- @return table rows Empty unless legacy rules are pending.
local function legacy_rules_rows(karabiner)
	if type(karabiner.legacy_rule_conflicts) ~= "function" then return {} end
	local ok, conflicts = pcall(karabiner.legacy_rule_conflicts)
	if not ok then
		Logger.error(LOG, "The pending legacy Karabiner rules could not be read: %s.", tostring(conflicts))
		return {}
	end
	if type(conflicts) ~= "table" then return {} end
	return ManifestMenu.template_rows("tap_hold_legacy_rules_rows", {
		["tap_hold_legacy_rules_cleanup"] = function()
			Logger.info(LOG, "Showing the legacy Karabiner rules cleanup from the Tap-Holds menu.")
			local shown_ok, shown = xpcall(function()
				return require("ui.legacy_rules_cleanup").open(karabiner)
			end, debug.traceback)
			if not shown_ok then
				Logger.error(LOG, "The legacy Karabiner rules cleanup could not be shown: %s.", tostring(shown))
				return false
			end
			return shown == true
		end,
	})
end

--- Builds the Tap-holds row and its submenu.
---
--- `tap_holds_menu` in the shared manifest owns the structural sequence, the
--- same declaration Windows renders: the bulk commands, then this engine's
--- timings and the per-key tap/hold bindings under one header per hand. The
--- modifier chords are M.build_key_combinations', under Shortcuts. This module
--- supplies only the provider rows and the command capabilities.
---
--- The manifest's `tapholds_toggle` row is the Tap-Holds feature switch. It
--- never touches the remap engine itself, which the driver keeps running on
--- its own: off only stops generating the per-key rules, like a pause.
--- @param ctx table Global UI context (must contain ctx.karabiner).
--- @return table|nil A provider row carrying the rendered submenu, or nil.
function M.build(ctx)
	local karabiner   = ctx and ctx.karabiner
	local update_menu = ctx and ctx.updateMenu

	if not karabiner then
		Logger.warn(LOG, "Remap module absent from context — tap-holds submenu skipped.")
		return nil
	end

	local enabled = karabiner.get_enabled()
	local tap_holds_on = type(karabiner.get_tap_holds_enabled) == "function"
		and karabiner.get_tap_holds_enabled() == true

	-- The key lists build their trees on demand, inside the renderer's isolated
	-- provider call: an unreadable key catalogue then costs the key rows and is
	-- logged, not the whole Tap-Holds submenu.
	local providers = {
		-- The first engine-specific rows: while rules an older release left in
		-- Karabiner block the deploy, or the guardian is not ready, they open
		-- with why nothing applies and the way to fix it.
		["tap_hold_timings"] = function()
			local rows = legacy_rules_rows(karabiner)
			for _, row in ipairs(guardian_status_rows(karabiner, tap_holds_on)) do rows[#rows + 1] = row end
			rows[#rows + 1] = build_delay_item(karabiner, update_menu)
			rows[#rows + 1] = build_sticky_delay_item(karabiner, update_menu)
			return rows
		end,
		-- With « Ergopti uses Karabiner » off the key rows are greyed: nothing
		-- can deploy them. Say why right above the first of them, at the top of
		-- the left hand; the chord rows, under Shortcuts, get the same hint
		-- (M.build_key_combinations). The cached trees are shared, so the hint
		-- goes into a fresh list.
		["tap_hold_keys_left"] = function()
			return with_karabiner_off_hint((build_picker_trees(karabiner, update_menu, enabled)).left, enabled)
		end,
		["tap_hold_keys_right"] = function()
			return (build_picker_trees(karabiner, update_menu, enabled)).right
		end,
	}

	-- The scope's restore and clear, the first group after the switch: the same
	-- rows and ids on every driver, this engine's implementation behind them.
	-- Like there, they leave the key combinations of the Shortcuts group alone.
	local commands = {
		["tapholds_toggle"] = function()
			return M.set_feature_enabled(karabiner, not tap_holds_on, update_menu)
		end,
		["scope_restore"] = function() return run_scope(karabiner, "recommended", update_menu) end,
		["scope_clear"] = function() return run_scope(karabiner, "clear", update_menu) end,
		-- Required on the click: the editor loads the layer data and its window
		-- stack, which a menu build has no use for.
		["edit_nav_layer"] = function()
			return require("ui.layer_editor").open({ karabiner = karabiner })
		end,
	}

	local render_ctx = {}
	for key, value in pairs(ctx or {}) do render_ctx[key] = value end
	render_ctx.commands = commands
	render_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do render_ctx.state_getters[key] = value end
	render_ctx.state_getters["tapholds_enabled"] = function() return tap_holds_on end

	-- `submenu`, not `items`: ManifestMenu.build returns rows it has ALREADY
	-- materialised. Handed over as `items`, the tray render dropped every one of
	-- them and the submenu opened empty on the real menu bar.
	return {
		label   = i18n.get("menu.tapholds.title"),
		checked = tap_holds_on or nil,
		submenu = ManifestMenu.build("tap_holds_menu", "TapHolds", nil, nil, render_ctx, providers),
	}
end

--- Switches the Tap-Holds feature, persists it, then redeploys the rules.
--- The switch is committed before deployment: without a live lease the next
--- provisioned generation is built from it, so a refused deploy is logged and
--- does not undo the user's choice.
--- @param karabiner table Remap module.
--- @param enabled boolean Desired switch state.
--- @param update_menu function|nil Menu refresh callback.
--- @return boolean committed
function M.set_feature_enabled(karabiner, enabled, update_menu)
	if type(karabiner) ~= "table" or type(karabiner.set_tap_holds_enabled) ~= "function" then
		Logger.error(LOG, "Tap-Holds switch is unavailable.")
		return false
	end
	if karabiner.set_tap_holds_enabled(enabled == true) ~= true then
		Logger.error(LOG, "Tap-Holds switch did not persist.")
		return false
	end
	_picker_cache = nil
	if type(karabiner.regenerate) == "function" then
		local ok_call, accepted = pcall(karabiner.regenerate, function(ok, reason)
			if ok ~= true then
				Logger.warn(LOG, "Tap-Holds rules not redeployed yet: %s.", tostring(reason))
			end
		end)
		if not ok_call then
			Logger.error(LOG, "Tap-Holds redeploy raised: %s.", tostring(accepted))
		end
	end
	if type(update_menu) == "function" then update_menu() end
	return true
end

--- Builds the « Combinaisons de touches » group of the Shortcuts submenu: the
--- rows `key_combinations_group` declares, answered by this engine's chords.
---
--- It opens with its own switch (persisted [mod_combos] enabled; on while the
--- user never set it, whatever the Tap-Holds switch says), then the symmetry
--- check, the chord delay, the tap → chord copy, and
--- one row per ordered pair of keys with its three slots, left hand then
--- right hand.
--- @param ctx table Global UI context (must contain ctx.karabiner).
--- @return table|nil The rendered rows of the group's submenu, or nil.
function M.build_key_combinations(ctx)
	local karabiner   = ctx and ctx.karabiner
	local update_menu = ctx and ctx.updateMenu

	if not karabiner then
		Logger.warn(LOG, "Remap module absent from context — key-combinations group skipped.")
		return nil
	end

	local enabled = karabiner.get_enabled()
	local providers = {
		["combo_timings"] = function()
			return { build_simultaneous_threshold_item(karabiner, update_menu) }
		end,
		-- Greyed with « Ergopti uses Karabiner » off, and led by the reason. One
		-- list per hand of the key held first; the manifest separates them.
		["key_combination_rows_left"] = function()
			local _, chords = build_picker_trees(karabiner, update_menu, enabled)
			return with_karabiner_off_hint(chords.left, enabled)
		end,
		["key_combination_rows_right"] = function()
			local _, chords = build_picker_trees(karabiner, update_menu, enabled)
			return with_karabiner_off_hint(chords.right, enabled)
		end,
	}

	local combos_on = karabiner.get_mod_combos_enabled() == true
	local commands = {
		["key_combinations_toggle"] = function()
			return M.set_key_combinations_enabled(karabiner, not combos_on, update_menu)
		end,
		["scope_restore"] = function()
			return run_scope(karabiner, "recommended", update_menu, "key_combinations")
		end,
		["scope_clear"] = function()
			return run_scope(karabiner, "clear", update_menu, "key_combinations")
		end,
		["combo_symmetric"] = function()
			return toggle_combo_symmetric(karabiner, update_menu)
		end,
		["copy_tap_to_combo"] = function()
			return run_bulk_menu_command(
				karabiner,
				"copy_tap_actions_to_combos",
				"Propagating tap → combo for all modifier combos…",
				"Tap → combo propagation done (%d combo(s) updated).",
				true,
				update_menu
			)
		end,
	}

	local render_ctx = {}
	for key, value in pairs(ctx or {}) do render_ctx[key] = value end
	render_ctx.commands = commands
	render_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do render_ctx.state_getters[key] = value end
	render_ctx.state_getters["key_combinations_enabled"] = function() return combos_on end
	render_ctx.state_getters["combo_symmetric"] = function() return karabiner.get_combo_symmetric() == true end

	-- The rows ManifestMenu.build returns are already rendered: the group row
	-- takes them as its finished submenu.
	return ManifestMenu.build("key_combinations_group", "KeyCombinations", nil, nil, render_ctx, providers)
end

--- Switches the key combinations, persists the choice, then redeploys the
--- rules. Like the Tap-Holds switch, a refused deploy is logged and does not
--- undo the user's choice.
--- @param karabiner table Remap module.
--- @param enabled boolean Desired switch state.
--- @param update_menu function|nil Menu refresh callback.
--- @return boolean committed
function M.set_key_combinations_enabled(karabiner, enabled, update_menu)
	if type(karabiner) ~= "table" or type(karabiner.set_mod_combos_enabled) ~= "function" then
		Logger.error(LOG, "Key-combinations switch is unavailable.")
		return false
	end
	Logger.start(LOG, "Switching the key combinations %s…", enabled and "on" or "off")
	if karabiner.set_mod_combos_enabled(enabled == true) ~= true then
		Logger.error(LOG, "Key-combinations switch did not persist.")
		return false
	end
	_picker_cache = nil
	local ok_call, accepted = pcall(karabiner.regenerate, function(ok, reason)
		if ok ~= true then
			Logger.warn(LOG, "Key-combination rules not redeployed yet: %s.", tostring(reason))
		end
	end)
	if not ok_call then
		Logger.error(LOG, "Key-combination redeploy raised: %s.", tostring(accepted))
	end
	if type(update_menu) == "function" then update_menu() end
	Logger.success(LOG, "Key combinations switched %s.", enabled and "on" or "off")
	return true
end

--- Warms the picker-tree cache off the menu-open path so the first click renders
--- instantly instead of paying the ~300-380 ms build. Called from ui.menu.init
--- once boot settles. Safe to call repeatedly.
--- @param ctx table Menu context (provides karabiner + updateMenu).
function M.prime(ctx)
	local karabiner = ctx and ctx.karabiner
	if not karabiner or type(karabiner.get_enabled) ~= "function" then return end
	local ok, enabled = pcall(karabiner.get_enabled)
	pcall(build_picker_trees, karabiner, ctx and ctx.updateMenu, ok and enabled or false)
end

-- Perf / cache test seams.
M._picker_fingerprint  = picker_fingerprint
M._build_picker_trees  = build_picker_trees
M._reset_picker_cache  = function() _picker_cache = nil end

return M
