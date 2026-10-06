--- ui/menu/menu_keyboard_layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Menu
--- DESCRIPTION:
--- Provides the "Disposition clavier" submenu in the Hammerspoon menu bar.
--- Lets the user install the bundled Ergopti keyboard layout (user or system),
--- open the macOS input-source preferences, pick the menubar icon variant,
--- and inspect / activate any of the input sources currently enabled in macOS.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth for bundle discovery: the highest version found
---    in static/ergopti/macos/bundles/ wins, so no hardcoded version string.
--- 2. Idempotent install detection: items become disabled with an
---    "Ergopti (<scope>) installé ✅" label when the bundle already lives at
---    the target path, so the user can tell at a glance where it landed.
--- 3. Resilient input-source listing: parsing macOS preferences plist is fragile,
---    so failure paths fall back to opening the Keyboard preferences panel and
---    are logged explicitly — no silent failures.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local Manifest      = require("infra.manifest_reader")
local DeferredWork  = require("infra.deferred_work")
local Timings       = require("infra.timings")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local MagicKeySourceMenu = require("ui.menu.magic_key_source_menu")
local LayoutManagerWindow = require("ui.layout_manager")
local install       = require("modules.keymap.layout_install")
local input_sources = require("modules.keymap.input_sources")
local NumberRowPolicy = require("layout.number_row_policy")
local LOG           = "menu.keyboard_layout"

M.DEFAULT_STATE = {
	layout_number_row_mode       = Manifest.default_for("layout.direct_access_digits"),
	layout_pause_switch_enabled = Manifest.default_for("layout.pause_switch_enabled"),
	layout_on_pause             = Manifest.default_for("layout.on_pause"),
	layout_on_resume            = Manifest.default_for("layout.on_resume"),
	-- config.toml [ui] menubar_icon; its values and default are the manifest's.
	menubar_icon                = Manifest.default_for("ui.menubar_icon"),
}





-- ===================================
-- ===================================
-- ======= 1/ Module Constants =======
-- ===================================
-- ===================================

-- Path of the bundles directory relative to the Hammerspoon driver root.
-- Resolved at runtime against base_dir (which already ends with "/")
local BUNDLES_RELDIR = "../../ergopti/macos/bundles/"

-- macOS URL that opens System Settings → Keyboard → Input Sources directly
local KEYBOARD_PREFS_URL = "x-apple.systempreferences:com.apple.preference.keyboard?InputSources"

-- Delay before rebuilding the menu after a bundle install. macOS reloads the
-- input-source list asynchronously; calling hs.keycodes too quickly during
-- that window has been observed to crash Hammerspoon. 1.5 s is a safe margin.
-- Shared cross-driver value ([ui] post_install_refresh_ms).
local POST_INSTALL_REFRESH_DELAY = Timings.sec("ui", "post_install_refresh_ms")

-- Delay before firing a TIS (Text Input Sources) call from a menu-click
-- handler. macOS posts kTISNotifyEnabledKeyboardInputSourcesChanged /
-- kTISNotifySelectedKeyboardInputSourceChanged synchronously when those
-- functions run, and Hammerspoon's hs.keycodes observers can re-enter Lua
-- state mid-handler. Bouncing through hs.timer guarantees the menu click
-- has fully unwound before the TIS call mutates input-source state.
-- Shared cross-driver value ([ui] tis_call_delay_ms).
local TIS_CALL_DELAY = Timings.sec("ui", "tis_call_delay_ms")



-- =================================================
-- =================================================
-- ======= 2/ Extracted-helper aliases =============
-- =================================================
-- =================================================

-- The bundle-install and input-source layers moved to modules/keymap/{layout_install,
-- input_sources}.lua (audit F4). Bind their public functions to locals so the
-- submenu builder below reads exactly as it did pre-split, and re-export the
-- unit-test seams the suite pins on M.

local parse_version        = install.parse_version
local version_gt           = install.version_gt
local version_str          = install.version_str
local highest_installed    = install.highest_installed
local install_user         = install.install_user
local install_system       = install.install_system
local pick_latest_bundle   = install.pick_latest_bundle
local invalidate_bundle_caches = install.invalidate_bundle_caches
local USER_LAYOUTS_DIR     = install.USER_LAYOUTS_DIR
local SYSTEM_LAYOUTS_DIR   = install.SYSTEM_LAYOUTS_DIR

local extract_ergopti_version       = input_sources.extract_ergopti_version
local format_ergopti_display        = input_sources.format_ergopti_display
local parse_active_layouts          = input_sources.parse_active_layouts
local compute_active_layouts_fast   = input_sources.compute_active_layouts_fast
local refresh_active_layouts_async  = input_sources.refresh_active_layouts_async
local list_active_keyboard_layouts  = input_sources.list_active_keyboard_layouts
local set_input_source_async        = input_sources.set_input_source_async
local enable_keylayout_source_async = input_sources.enable_keylayout_source_async
local is_legacy_ergopti_id          = input_sources.is_legacy_ergopti_id
local migrate_legacy_id             = input_sources.migrate_legacy_id
local upgrade_active_list_async     = input_sources.upgrade_active_list_async
local clean_layout_name             = input_sources.clean_layout_name
local resolve_installed_ergopti_version = input_sources.resolve_installed_ergopti_version
local ergopti_in_active_layouts     = input_sources.ergopti_in_active_layouts
local build_kl_name_to_tis_id       = input_sources.build_kl_name_to_tis_id

-- Public re-export + section-2 test seams (originally wired just after §2).
M.pick_latest_bundle = pick_latest_bundle
M._parse_version     = parse_version
M._version_gt        = version_gt





--- ==================================
--- ==================================
--- ======= 5/ Submenu Builder =======
--- ==================================
--- ==================================

--- Builds the complete "Disposition clavier" submenu item.
--- @param ctx table Global UI context. Must contain ctx.base_dir and ctx.updateMenu.
--- @return table A single hs.menubar item with a populated submenu.
--- Schedules a deferred menu rebuild. macOS reloads its input-source list
--- asynchronously after a bundle is added or removed, and calling hs.keycodes
--- in the middle of that window has been observed to crash Hammerspoon — so
--- we wait POST_INSTALL_REFRESH_DELAY seconds before refreshing.
--- @param update_menu function|nil Callback that rebuilds the menu structure.
local function schedule_menu_refresh(update_menu)
	if type(update_menu) ~= "function" then return false end
	return DeferredWork.after(POST_INSTALL_REFRESH_DELAY,
		function() pcall(update_menu) end,
		"menu_keyboard_layout.refresh")
end

--- Defers `fn` so it runs AFTER the current menu-click handler has unwound.
--- TIS (Text Input Sources) calls — TISEnableInputSource, TISSelectInputSource,
--- TISDisableInputSource — synchronously trigger macOS input-source change
--- notifications that hs.keycodes observes. Running them inside the menu
--- callback frame has been observed to re-enter Lua state and crash
--- Hammerspoon. A short retained deferral gives the click handler a chance
--- to return before the TIS mutation is dispatched.
--- @param fn function The TIS-touching callback to defer.
local function defer_tis_call(fn)
	if type(fn) ~= "function" then return false end
	return DeferredWork.after(TIS_CALL_DELAY,
		function() pcall(fn) end,
		"menu_keyboard_layout.tis_call")
end

--- Wraps an install action so that, on success, every legacy Ergopti entry
--- still sitting in the user's enabled-list is replaced by its stable-id
--- counterpart, and the menu is rebuilt after a small delay.
--- @param install_fn function The actual install callback (returns true on success).
--- @param legacy_active table Legacy entries in the active input-source list.
--- @param update_menu function|nil Menu rebuild callback.
local function run_install_and_chain(install_fn, legacy_active, update_menu)
	local ok = false
	pcall(function() ok = install_fn() end)
	if ok and type(legacy_active) == "table" and #legacy_active > 0 then
		Logger.info(LOG, "Install succeeded — auto-upgrading %d legacy entry(ies) in the active list.", #legacy_active)
		upgrade_active_list_async(legacy_active, function()
			schedule_menu_refresh(update_menu)
		end)
		return
	end
	schedule_menu_refresh(update_menu)
end

--- Display label of a layout an installed bundle declares: its KeyboardLayout
--- Name without the version its row already shows (Ergopti_v2_2_2_plus is
--- "Ergopti+"), or the name itself for a layout that is not Ergopti.
--- @param name string KeyboardLayout Name from the bundle's Info.plist.
--- @return string
local function variant_label(name)
	local unversioned = (name:gsub("_v%d+[_.]%d+[_.]%d+", ""))
	return format_ergopti_display(unversioned) or name
end

--- The custom layout picker: the registry layouts the layout manager
--- installed, the one of the current input source checked; choosing one
--- makes it the current input source.
--- @param update_menu function|nil Menu rebuild callback.
--- @return table Rows for the `custom_layouts` provider.
local function custom_layout_rows(update_menu)
	local rows = {}
	local ok, LayoutRegistry = pcall(require, "modules.keymap.layout_registry")
	local picked_ok, picker = false, nil
	if ok then picked_ok, picker = pcall(LayoutRegistry.picker) end
	if not picked_ok or type(picker) ~= "table" then
		Logger.error(LOG, "The installed layouts could not be listed: %s.", tostring(picker))
		picker = { layouts = {}, active = "" }
	end
	for _, entry in ipairs(picker.layouts) do
		local id = entry.id
		rows[#rows + 1] = {
			label   = type(entry.name) == "string" and entry.name or id,
			checked = picker.active == id or nil,
			action  = function()
				defer_tis_call(function()
					LayoutRegistry.select(id, function(selected)
						if not selected then
							pcall(notifications.notify, i18n.get("layout_manager.failure_other"), nil, "error")
						end
						schedule_menu_refresh(update_menu)
					end)
				end)
			end,
		}
	end
	if #rows == 0 then
		rows[1] = { label = i18n.get("menu.layout.none_installed"), disabled = true }
	end
	return rows
end

--- Builds an install/update menu item for one scope (user or system).
--- The label and click handler are derived from the relationship between the
--- highest installed version and the latest available bundle:
---   - latest already installed → greyed out with a success label
---   - older version installed  → "Mettre à jour (vOLD → vLATEST)"
---   - nothing installed        → "Installer (vLATEST)"
--- @param scope_label string Short scope tag for the menu label ("utilisateur"|"système").
--- @param emoji_install string Emoji prefix shown for the fresh-install label.
--- @param installed table|nil { name, version } from highest_installed(target_dir).
--- @param latest_name string Basename of the latest bundle.
--- @param latest_ver table Numeric components of the latest version.
--- @param do_install function Callback invoked when the user clicks install/update.
--- @return table A single hs.menubar item.
local function build_install_item(scope_label, emoji_install, installed, latest_name, latest_ver, do_install)
	local latest_str = version_str(latest_ver)
	if installed and not version_gt(latest_ver, installed.version) then
		-- Latest already installed — nothing to do
		return {
			label    = string.format(i18n.get("menu.layout.installed_version"), scope_label, latest_str),
			disabled = true,
		}
	end
	if installed then
		-- An older version is on disk; offer an in-place upgrade
		local old_str = version_str(installed.version)
		return {
			label = string.format(i18n.get("menu.layout.update_version"), scope_label, old_str, latest_str),
			action    = do_install,
		}
	end
	return {
		label = string.format(i18n.get("menu.layout.install_version"), emoji_install, scope_label, latest_str),
		action    = do_install,
	}
end

function M.build(ctx)
	local update_menu  = ctx and ctx.updateMenu
	local refresh_icon = ctx and ctx.refresh_icon
	local base_dir     = ctx and ctx.base_dir or ""
	local bundles_dir  = base_dir .. BUNDLES_RELDIR

	-- The block this driver alone has — installing the .bundle layout macOS
	-- needs — is collected for the manifest slot that declares it rather than
	-- appended here. The menubar icon is the manifest's `choice` row: this
	-- driver supplies only its current value and what choosing one does.
	local bundle_rows    = {}
	-- Which layout to switch to when the driver pauses and when it resumes. Three
	-- more rows this driver alone has, for the same reason as the two above: they
	-- name macOS input sources.
	local switching_rows = {}

	-- Pull the live state once so the closures below capture stable values.
	-- list_active_keyboard_layouts() returns rich records {id, name, selected}
	-- filtered to actual keyboard layouts, so the menu never displays
	-- internal services (PressAndHold, CharacterPalette, …).
	local records    = list_active_keyboard_layouts()
	-- Build the active-Ergopti set directly from records — the same source used
	-- to display the i18n.get("menu.layout.active_layouts") list below. If an entry appears there
	-- it is truly active; no need to read HIToolbox separately.
	--
	-- records[i].id is the KeyboardLayout Name from HIToolbox (e.g. "Ergopti_v2_2_2_plus"),
	-- NOT a TIS ID. We map it to a stable TIS ID via the installed bundle's keylayout files.
	-- Records whose KeyboardLayout Name doesn't match any installed variant are orphan entries
	-- (old bundle, different version) — we flag them so the menu can offer an upgrade.
	local kl_name_to_tis = build_kl_name_to_tis_id() or {}
	local active_id_set_pre = {}
	local legacy_active     = {}
	for _, r in ipairs(records) do
		local kl_name = r.id or ""
		if kl_name:lower():find("ergopti", 1, true) then
			local stable_id = kl_name_to_tis[kl_name]
			if stable_id then
				-- Matches an installed variant → genuinely active
				active_id_set_pre[stable_id] = true
			else
				-- No match in the installed bundle → orphan/legacy entry
				legacy_active[#legacy_active + 1] = kl_name
			end
		end
	end
	local list_state = ergopti_in_active_layouts(records)

	local latest = M.pick_latest_bundle(bundles_dir)
	-- The list-upgrade only makes sense once the latest bundle is on disk —
	-- TIS can't enable an input source whose .bundle isn't installed.
	-- user_best and system_best are declared here so they remain in scope for the
	-- "Ajouter" submenu closures below (which live outside the `if latest then` block).
	local user_best   = highest_installed(USER_LAYOUTS_DIR)
	local system_best = highest_installed(SYSTEM_LAYOUTS_DIR)
	local latest_installed_anywhere = false
	if latest then
		local latest_ver  = parse_version(latest)
		latest_installed_anywhere =
			(user_best   and not version_gt(latest_ver, user_best.version))
			or (system_best and not version_gt(latest_ver, system_best.version))
			or false
		Logger.debug(LOG, "Install probe — latest=%s, user_best=%s, system_best=%s, latest_installed=%s.",
			latest, user_best and user_best.name or "none",
			system_best and system_best.name or "none",
			tostring(latest_installed_anywhere))

		-- System scope is listed first: it is the preferred install target
		-- because it makes the layout available for all users and avoids
		-- duplication between ~/Library and /Library. A system install also
		-- removes the user copy automatically, keeping a single canonical bundle.
		bundle_rows[#bundle_rows + 1] = build_install_item(
			i18n.get("menu.layout.scope_system"), "🔐", system_best, latest, latest_ver,
			function()
				run_install_and_chain(
					function() return install_system(bundles_dir, latest) end,
					legacy_active, update_menu
				)
			end
		)
		bundle_rows[#bundle_rows + 1] = build_install_item(
			i18n.get("menu.layout.scope_user"), "📥", user_best, latest, latest_ver,
			function()
				run_install_and_chain(
					function() return install_user(bundles_dir, latest) end,
					legacy_active, update_menu
				)
			end
		)
	else
		Logger.warn(LOG, "No Ergopti bundle found in %s.", bundles_dir)
		bundle_rows[#bundle_rows + 1] = {
			label    = i18n.get("menu.layout.no_bundle"),
			disabled = true,
		}
	end

	-- Add / upgrade Ergopti in the macOS input-source list.
	--
	-- Five possible states:
	--   1. ALL variants active in list     → greyed-out success label
	--   2. older active, bundle installed  → in-place TIS swap (programmatic)
	--   3. older active, latest NOT installed → greyed: install latest first
	--   4. some/no variants present, latest installed → submenu (added ones greyed)
	--   5. absent, latest NOT installed    → greyed: install latest first
	local latest_ver = latest and parse_version(latest) or nil
	local latest_str = latest_ver and version_str(latest_ver)
	-- The layouts the installed bundle declares in its Info.plist (system scope
	-- first, like the input-source map): the bundle says what it installs.
	local installed_dir, installed_name
	if system_best then
		installed_dir  = SYSTEM_LAYOUTS_DIR
		installed_name = system_best.name
	elseif user_best then
		installed_dir  = USER_LAYOUTS_DIR
		installed_name = user_best.name
	end
	local bundle_full_path = (installed_dir and installed_name) and
		(installed_dir:gsub("[/\\]$", "") .. "/" .. installed_name) or ""
	local variants = bundle_full_path ~= "" and install.bundle_variants(bundle_full_path) or {}
	local all_variants_active = #variants > 0
	local active_variant_count = 0
	for _, var in ipairs(variants) do
		if active_id_set_pre[var.tis_id] then
			active_variant_count = active_variant_count + 1
		else
			all_variants_active = false
		end
	end
	-- Installed bundle version: system preferred, then user. Used for the label in state 1.
	-- We derive this from the filesystem, not from TIS, which is unreliable on Sequoia.
	local installed_ver = (system_best and system_best.version) or (user_best and user_best.version)
	Logger.debug(LOG,
		"Active layout state — stable=%d/%d legacy=%d installed=%s latest_installed=%s.",
		active_variant_count, #variants, #legacy_active,
		installed_ver and version_str(installed_ver) or "none",
		tostring(latest_installed_anywhere))
	if all_variants_active and #legacy_active == 0 and installed_ver then
		-- 1. All variants already in list and up to date
		bundle_rows[#bundle_rows + 1] = {
			label    = string.format(i18n.get("menu.layout.in_list"), version_str(installed_ver)),
			disabled = true,
		}
	elseif #legacy_active > 0 and latest ~= nil and not latest_installed_anywhere then
		-- 3. Legacy entry active but latest bundle missing — block the upgrade
		bundle_rows[#bundle_rows + 1] = {
			label    = string.format(i18n.get("menu.layout.update_list_install_first"),
				latest_str, latest_str),
			disabled = true,
		}
	elseif #legacy_active > 0 and installed_ver then
		-- 2. Legacy entry active and a bundle installed — programmatic swap via TIS
		-- onto the INSTALLED bundle, so its version is the target. The legacy
		-- version comes from its name or, for an unversioned name, from the
		-- Info.plist of the bundle that still ships it; when neither exists the
		-- label drops it instead of printing a placeholder.
		local legacy_ver = install.layout_version(legacy_active[1])
		local target_str = version_str(installed_ver)
		local list_label = legacy_ver
			and string.format(i18n.get("menu.layout.update_list"), version_str(legacy_ver), target_str)
			or  string.format(i18n.get("menu.layout.update_list_to"), target_str)
		bundle_rows[#bundle_rows + 1] = {
			label = list_label,
			action    = function()
				defer_tis_call(function()
					upgrade_active_list_async(legacy_active, function(ok)
						if ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_ok"), nil, "success") end
						if not ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_fail"), nil, "error") end
						schedule_menu_refresh(update_menu)
					end)
				end)
			end,
		}
	elseif latest_installed_anywhere then
		-- 4. Some or no variants present, bundle installed — submenu listing each
		-- variant. Already-added variants are greyed individually with ✅.
		local active_id_set = active_id_set_pre

		local add_sub = {}
		for _, var in ipairs(variants) do
			local label         = variant_label(var.name)
			local already_added = active_id_set[var.tis_id] == true
			if already_added then
				add_sub[#add_sub + 1] = {
					label    = string.format(i18n.get("menu.layout.already_added"), label, latest_str),
					disabled = true,
				}
			else
				add_sub[#add_sub + 1] = {
					label = string.format("%s v%s", label, latest_str),
					action    = function()
						defer_tis_call(function()
							enable_keylayout_source_async(var.keylayout, label,
								function(ok)
									if ok then pcall(notifications.notify, string.format(i18n.get("menu.layout.add_ok"), label), nil, "success") end
									if not ok then pcall(notifications.notify, i18n.get("menu.layout.add_fail"), nil, "error") end
									schedule_menu_refresh(update_menu)
								end)
						end)
					end,
				}
			end
		end
		bundle_rows[#bundle_rows + 1] = {
			label = string.format(i18n.get("menu.layout.add_to_list"), latest_str),
			items  = add_sub,
		}
	else
		-- 5. Absent and bundle missing — greyed
		bundle_rows[#bundle_rows + 1] = {
			label    = i18n.get("menu.layout.install_first"),
			disabled = true,
		}
	end

	-- The separator that stood here is a `---` row in the manifest now.

	-- Active layouts list — one item per enabled keyboard layout, with a
	-- checkmark on the currently selected one. Clicking a row switches the
	-- active layout via TISSelectInputSource (the TIS bundle id is captured
	-- in each closure so we never have to round-trip through localised
	-- names, which can collide across languages). Ergopti entries get the
	-- bundle's actual installed version appended to their localised name
	-- so a stable-id row no longer shows up as a bare "Ergopti+".
	local resolved_ergopti_v = resolve_installed_ergopti_version()
	local function display_for_record(r)
		local id = r.id or ""
		if id:lower():find("ergopti", 1, true) then
			local pretty = format_ergopti_display(id)
			if pretty and not pretty:find("v%d") and resolved_ergopti_v then
				pretty = pretty .. " v" .. version_str(resolved_ergopti_v)
			end
			if pretty then return pretty end
		end
		-- Non-Ergopti rows: prefer the localised name macOS published; fall
		-- back to a prefix-stripped id when it isn't available.
		if type(r.name) == "string" and r.name ~= "" and r.name ~= id then
			return r.name
		end
		return clean_layout_name(id)
	end

	-- The layouts macOS reports as active. A `list`, because the rows are
	-- whatever the system has installed and no static entry can enumerate
	-- them, and because what this returns is provider DATA — `label`,
	-- `checked`, `action` — which only the `list` branch of the renderer knows
	-- how to materialise. It was declared `dynamic` until 2026-08-07 and passed
	-- here as a list provider, so the renderer looked for a dynamic handler,
	-- found none, and skipped the row: this menu showed no layouts at all, with
	-- one warning in the log to say so.
	local function active_layout_rows()
		local rows = {}
	if #records == 0 then
		rows[#rows + 1] = {
			label = i18n.get("menu.layout.open_prefs"),
			action    = function() pcall(hs.execute, "open '" .. KEYBOARD_PREFS_URL .. "'") end,
		}
	else
		for _, r in ipairs(records) do
			local row_label = display_for_record(r)
			-- Capture both the localised name (r.name, used by hs.keycodes.setLayout)
			-- and the raw KeyboardLayout Name (r.id, used to resolve the stable TIS ID
			-- for Ergopti variants). set_input_source_async tries them in order.
			local target_localised = r.name
			local target_kl_name   = r.id
			rows[#rows + 1] = {
				label   = row_label,
				checked = r.selected or nil,
				-- Greyed out when already selected — clicking the checked
				-- row would be a no-op TIS call and confuse macOS' input
				-- source watchers when the menu refreshes mid-frame.
				disabled = r.selected or nil,
				action       = function()
					-- Defer the TIS call out of the menu-click frame so the
					-- input-source change notification doesn't re-enter HS.
					defer_tis_call(function()
						set_input_source_async(target_localised, target_kl_name, function()
							schedule_menu_refresh(update_menu)
						end)
					end)
				end,
			}
		end
	end

		return rows
	end

	-- Pause / resume layout switching — two dropdowns that let the user pick which
	-- keyboard layout to activate automatically when the script is paused or resumed.
	-- Nil / "auto" means "do nothing" (default). Stored in state.layout_on_pause and
	-- state.layout_on_resume so they survive a reload via preferences.lua.
	local state      = ctx and ctx.state
	local save_prefs = ctx and ctx.save_prefs
	local hs_paused_pre = ctx and ctx.paused

	local function build_layout_picker_submenu(current_id, on_pick)
		local sub = {}
		-- false / nil / "" all mean "no automatic switch" (the default)
		local is_auto = (current_id == nil or current_id == false or current_id == "")
		sub[#sub + 1] = {
			label   = i18n.get("menu.layout.layout_auto"),
			checked = is_auto or nil,
			action      = function()
				on_pick(nil)
			end,
		}
		sub[#sub + 1] = { separator = true }
		for _, r in ipairs(records) do
			local display = display_for_record(r)
			local rid     = r.id
			sub[#sub + 1] = {
				label   = display,
				checked = (current_id == rid) or nil,
				action      = function()
					on_pick(rid)
				end,
			}
		end
		return sub
	end

	if state then
		local feature_on = state.layout_pause_switch_enabled and true or false

		-- The separator that stood here is a `---` row in the manifest now.
		switching_rows[#switching_rows + 1] = {
			label   = i18n.get("menu.layout.pause_layout_enabled"),
			checked = feature_on or nil,
			action      = function()
				state.layout_pause_switch_enabled = not feature_on
				if save_prefs and save_prefs() ~= true then return false end
				if update_menu then update_menu() end
			end,
		}

		local cur_pause  = state.layout_on_pause
		local cur_resume = state.layout_on_resume

		local pause_label = (cur_pause and cur_pause ~= false and cur_pause ~= "")
			and display_for_record({ id = cur_pause, name = cur_pause:gsub("_", " "):gsub("%s+v%d.*$", "") })
			or  i18n.get("menu.layout.layout_auto")
		switching_rows[#switching_rows + 1] = {
			label    = string.format("  ↳ %s : %s", i18n.get("menu.layout.layout_on_pause"), pause_label),
			-- Grayed out when the feature is disabled or the script is currently paused
			disabled = (not feature_on) or hs_paused_pre or nil,
			items     = build_layout_picker_submenu(cur_pause, function(id)
				state.layout_on_pause = id
				if save_prefs and save_prefs() ~= true then return false end
				if update_menu then update_menu() end
			end),
		}

		local resume_label = (cur_resume and cur_resume ~= false and cur_resume ~= "")
			and display_for_record({ id = cur_resume, name = cur_resume:gsub("_", " "):gsub("%s+v%d.*$", "") })
			or  i18n.get("menu.layout.layout_auto")
		switching_rows[#switching_rows + 1] = {
			label    = string.format("  ↳ %s : %s", i18n.get("menu.layout.layout_on_resume"), resume_label),
			disabled = (not feature_on) or hs_paused_pre or nil,
			items     = build_layout_picker_submenu(cur_resume, function(id)
				state.layout_on_resume = id
				if save_prefs and save_prefs() ~= true then return false end
				if update_menu then update_menu() end
			end),
		}
	end

	-- Rendered LAST, once every provider list is filled. The providers are read
	-- when the renderer reaches their row, so a build issued before the
	-- pause/resume pickers were collected drew an empty `layout_switching`.
	local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
	if not ok_mm or type(ManifestMenu.build) ~= "function" then
		-- Loud: the rows would simply be absent, and a layout list that
		-- silently disappears reads as "macOS has no layouts installed".
		Logger.error(LOG, "Manifest renderer unavailable — the layout list is not rendered.")
		return nil
	end
	-- Layout management and the menubar icon remain manifest commands; other
	-- commands of the context stay available to the renderer.
	local render_ctx = {}
	for key, value in pairs(type(ctx) == "table" and ctx or {}) do render_ctx[key] = value end
	render_ctx.commands = {}
	for key, value in pairs(type(ctx) == "table" and type(ctx.commands) == "table" and ctx.commands or {}) do
		render_ctx.commands[key] = value
	end
	render_ctx.state_getters = {}
	for key, value in pairs(type(ctx) == "table" and type(ctx.state_getters) == "table" and ctx.state_getters or {}) do
		render_ctx.state_getters[key] = value
	end
	render_ctx.state_getters["ui.menubar_icon"] = function() return state and state.menubar_icon end
	render_ctx.commands["menubar_icon"] = function(variant)
		if not state then return false end
		state.menubar_icon = variant
		if type(save_prefs) ~= "function" or save_prefs() ~= true then return false end
		Logger.info(LOG, "Menubar icon set to %s.", tostring(variant))
		-- refresh_icon comes from ui.menu.init through ctx: a require() round-trip
		-- could re-enter that module while it is still initialising.
		if type(refresh_icon) == "function" then pcall(refresh_icon) end
		if type(update_menu) == "function" then pcall(update_menu) end
		return true
	end
	render_ctx.commands["layout_manager"] = LayoutManagerWindow.menu_command()
	for command, mode in pairs({ scope_restore = "recommended", scope_clear = "clear" }) do
		render_ctx.commands[command] = function()
			if ctx.paused == true or type(ctx.apply_preference_scope) ~= "function" then return false end
			return ctx.apply_preference_scope("keyboard_layout", mode)
		end
	end
	-- Native-only status never acquires a preference or forced-input writer.
	render_ctx.commands["number_row_mode"] = function() return false end
	local custom_rows = custom_layout_rows(update_menu)
	local submenu = ManifestMenu.build("layout_menu", "Layout", nil, nil, render_ctx, {
		["number_row_policy"] = function() return NumberRowPolicy.native_rows(ManifestMenu, render_ctx.commands) end,
		["custom_layouts"]   = function() return custom_rows end,
		["active_layouts"]   = active_layout_rows,
		["layout_bundle"]    = function() return bundle_rows end,
		["layout_switching"] = function() return switching_rows end,
		-- The physical magic key, chosen by pressing it or from the candidates.
		["magic_key_source"] = function()
			return MagicKeySourceMenu.rows({
				state = state, save_prefs = save_prefs, keymap = ctx and ctx.keymap,
				update_menu = update_menu, paused = ctx and ctx.paused,
			})
		end,
	})

	-- `submenu`, not `items`: these rows are already materialised. The tray
	-- renders `items` as provider data, where every `title`/`fn` row is dropped,
	-- which left this submenu empty on the real menu bar.
	return {
		label   = i18n.get("menu.layout.title"),
		submenu = submenu,
	}
end

-- Late-bound test hooks: the helpers below are defined after section 2, so we
-- expose them here to keep section 2 self-contained.
M._version_str             = version_str
M._clean_layout_name       = clean_layout_name
M._extract_ergopti_version = extract_ergopti_version
M._format_ergopti_display  = format_ergopti_display
M._is_legacy_ergopti_id    = is_legacy_ergopti_id
M._migrate_legacy_id       = migrate_legacy_id

-- Latency / cache test hooks — let the suite assert the menu-open path stays
-- subprocess-free and that the async probe still parses HIToolbox output.
M._parse_active_layouts         = parse_active_layouts
M._compute_active_layouts_fast  = compute_active_layouts_fast
M._list_active_keyboard_layouts = list_active_keyboard_layouts
M._refresh_active_layouts_async = refresh_active_layouts_async
M._invalidate_bundle_caches     = invalidate_bundle_caches
M._set_active_layouts_cache     = input_sources.set_active_layouts_cache

--- Warms the discovery caches off the menu-open path so the first user click
--- renders instantly. Safe to call repeatedly. Invoked from ui.menu.init once
--- boot settles. See the discovery-cache notes near the top of this module.
--- @param ctx table|nil Menu context; ctx.base_dir locates the bundles directory.
function M.prime(ctx)
	local base_dir = (type(ctx) == "table" and type(ctx.base_dir) == "string") and ctx.base_dir or ""
	pcall(function() M.pick_latest_bundle(base_dir .. BUNDLES_RELDIR) end)
	pcall(highest_installed, USER_LAYOUTS_DIR)
	pcall(highest_installed, SYSTEM_LAYOUTS_DIR)
	refresh_active_layouts_async(nil)
end

--- Switches the active keyboard layout given a raw KeyboardLayout Name (as stored
--- in state.layout_on_pause / state.layout_on_resume). Resolves the localised name
--- from the live HIToolbox list so hs.keycodes.setLayout receives the correct form.
--- Falls back to the asynchronous TIS osascript path when setLayout fails.
--- @param kl_name string Raw KeyboardLayout Name from HIToolbox, e.g. "Ergopti_v2_2_2_plus".
--- @param on_done function|nil fn(ok, output, reason).
--- @return boolean accepted True for an immediate switch or committed fallback child.
function M.set_layout_by_kl_name_async(kl_name, on_done)
	if type(kl_name) ~= "string" or kl_name == "" then
		if type(on_done) == "function" then pcall(on_done, false, nil, "invalid_name") end
		return false
	end
	-- Resolve the localised display name from the live record list so
	-- hs.keycodes.setLayout gets the correct form (e.g. "French", "Ergopti+").
	local localised = kl_name
	local records   = list_active_keyboard_layouts()
	for _, r in ipairs(records) do
		if r.id == kl_name then
			localised = (type(r.name) == "string" and r.name ~= "") and r.name or kl_name
			break
		end
	end
	return set_input_source_async(localised, kl_name, on_done)
end

--- The layout a pause (or a resume) switches to, or nil when switching is off
--- or set to « no change ». Pause, resume and quit all read it here.
--- @param state table|nil Menu state (layout_pause_switch_enabled, layout_on_pause, layout_on_resume).
--- @param is_paused boolean True for the pause target, false for the resume one.
--- @return string|nil kl_name
local function switch_target(state, is_paused)
	if type(state) ~= "table" or not state.layout_pause_switch_enabled then return nil end
	local target = is_paused and state.layout_on_pause or state.layout_on_resume
	-- Nil / false / "auto" / "" all mean « do nothing » (the dropdowns default to false).
	if type(target) ~= "string" or target == "" then return nil end
	return target
end

--- Switches to the pause layout before ErgoptiPlus quits: quitting leaves the
--- keyboard on the input source a pause selects, and has no setting of its own.
--- @param state table|nil Menu state.
--- @param on_done function|nil fn(ok, output, reason), called exactly once when a
---   switch was started (set_input_source_async answers on every path).
--- @return string "none" when nothing is configured, "pending" once on_done is owed.
function M.apply_quit_layout(state, on_done)
	local target = switch_target(state, true)
	if target == nil then return "none" end
	Logger.info(LOG, "Quit: applying the pause keyboard layout.")
	-- Looked up on M at call time so a test stub on the module is honoured.
	M.set_layout_by_kl_name_async(target, on_done)
	return "pending"
end

local pending_switches = {}

--- Reports automatic input-source transitions without terminal acknowledgement.
--- @return boolean pending True until every scheduled/native transition settles.
function M.scope_pending() return next(pending_switches) ~= nil end

--- Captures the exact future automatic-switching policy.
--- @param state table Live menu state.
--- @return table|nil snapshot Detached policy, absent while native work is pending.
function M.capture_scope(state, source)
	if M.scope_pending() then return nil end
	-- The new read-only number-row status does not acquire a future or malformed
	-- personal leaf during a whole scope restoration. Observe only this leaf
	-- from the transaction's exact admitted source, before backup/publication.
	if source ~= nil then
		if type(source) ~= "table" or (source.status ~= "ok" and source.status ~= "absent") then return nil end
		if source.status == "ok" then
			if type(source.content) ~= "string" then return nil end
			local decoded, document = pcall(require("infra.toml.codec").decode, source.content)
			if not decoded or type(document) ~= "table" then return nil end
			local layout = document.layout
			if layout ~= nil and type(layout) ~= "table" then return nil end
			local value
			if type(layout) == "table" then value = layout.direct_access_digits end
			if value ~= nil and NumberRowPolicy.mode(value) == nil then return nil end
		end
	end
	local result = {}
	local Preferences = require("infra.preferences")
	for _, row in ipairs(Manifest.scope_operations("keyboard_layout", "clear")) do
		local key = assert(Preferences.flat_key_for(row.section .. "." .. row.key), "layout preference owner missing")
		result[#result + 1] = { key = key, value = state[key] }
	end
	return result
end

--- Applies a planned layout policy without changing the current manual selection.
--- @param state table Live menu state.
--- @param rows table Canonical scope operations.
--- @return boolean applied Terminal policy acknowledgement.
function M.apply_scope(state, rows)
	if M.scope_pending() then return false end
	local Preferences, values = require("infra.preferences"), {}
	local allowed = {}
	for _, row in ipairs(Manifest.scope_operations("keyboard_layout", "clear")) do
		allowed[row.section .. "." .. row.key] = true
	end
	for _, row in ipairs(rows) do
		local path = row.section .. "." .. row.key
		assert(allowed[path], "unexpected layout scope field: " .. path)
		local key = assert(Preferences.flat_key_for(path), "layout preference owner missing")
		local value = row.value
		if row.delete then value = Manifest.default_for(path) end
		values[#values + 1] = { key = key, value = value }
	end
	for _, item in ipairs(values) do state[item.key] = item.value end
	return true
end

--- Restores a captured policy after a refused publication.
--- @param state table Live menu state.
--- @param snapshot table Exact policy snapshot.
--- @return boolean restored Terminal policy acknowledgement.
function M.restore_scope(state, snapshot)
	if M.scope_pending() then return false end
	for _, item in ipairs(snapshot) do state[item.key] = item.value end
	return true
end

--- Schedules the pause / resume keyboard-layout switch on a DEFERRED run-loop
--- cycle instead of running it inline.
---
--- This remains deferred so synchronous hs.keycodes attempts cannot re-enter the
--- script-control eventtap. The subprocess fallback itself is asynchronous and
--- deadline-bounded; deferral only separates the in-process TIS notification.
--- @param is_paused boolean Current pause state (true just entered pause).
--- @param state table Menu state exposing layout_pause_switch_enabled / layout_on_pause / layout_on_resume.
--- @param schedule function|nil Injectable scheduler(fn) for tests.
--- @return string|nil The target layout that was scheduled, or nil when no switch is needed.
function M.schedule_pause_layout_switch(is_paused, state, schedule)
	local target = switch_target(state, is_paused)
	if target == nil then return nil end
	-- Resolve hs.timer lazily so the module stays loadable in the cross-platform
	-- test harness where hs is absent and the scheduler is injected.
	if type(schedule) ~= "function" then
		schedule = function(fn)
			return DeferredWork.after(0, fn, "menu_keyboard_layout.pause_switch")
		end
	end
	local token = { scheduling = true }
	pending_switches[token] = true
	local function dispatch()
		if not pending_switches[token] or token.dispatched then return end
		if token.scheduling then token.fired = true; return end
		token.dispatched = true
		local called, accepted = pcall(M.set_layout_by_kl_name_async, target, function(ok)
			if type(ok) == "boolean" then pending_switches[token] = nil end
		end)
		if not called or accepted ~= true then
			Logger.error(LOG, "Pause layout dispatch refused; terminal acknowledgement is required.")
		end
	end
	local called, scheduled = pcall(schedule, dispatch)
	token.scheduling = false
	if not called or scheduled ~= true then
		pending_switches[token] = nil
		Logger.error(LOG, "Pause layout switch could not be scheduled.")
		return nil
	end
	if token.fired then dispatch() end
	return target
end

return M
