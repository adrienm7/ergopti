--- ui/menu/menu_keyboard_layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Menu
--- DESCRIPTION:
--- Provides the "Disposition clavier" submenu in the Hammerspoon menu bar.
--- Lets the user install the bundled Ergopti keyboard layout (user or system),
--- open the macOS input-source preferences, switch the menubar logo variant,
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
local Timings       = require("infra.timings")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local install       = require("modules.keymap.layout_install")
local input_sources = require("modules.keymap.input_sources")
local LOG           = "menu.keyboard_layout"

M.DEFAULT_STATE = {
	layout_pause_switch_enabled = false,
	layout_on_pause             = false,
	layout_on_resume            = false,
}





-- ===================================
-- ===================================
-- ======= 1/ Module Constants =======
-- ===================================
-- ===================================

-- Path of the bundles directory relative to the Hammerspoon driver root.
-- Resolved at runtime against base_dir (which already ends with "/")
local BUNDLES_RELDIR = "../../ergopti/macos/bundles/"

-- Persisted preference key for the menubar logo variant
local LOGO_VARIANT_KEY     = "ergopti_menubar_logo_variant"
local LOGO_VARIANT_DEFAULT = "simple"

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

local ERGOPTI_VARIANTS              = input_sources.ERGOPTI_VARIANTS
local extract_ergopti_version       = input_sources.extract_ergopti_version
local format_ergopti_display        = input_sources.format_ergopti_display
local parse_active_layouts          = input_sources.parse_active_layouts
local compute_active_layouts_fast   = input_sources.compute_active_layouts_fast
local refresh_active_layouts_async  = input_sources.refresh_active_layouts_async
local list_active_keyboard_layouts  = input_sources.list_active_keyboard_layouts
local set_input_source              = input_sources.set_input_source
local enable_and_select_source      = input_sources.enable_and_select_source
local is_legacy_ergopti_id          = input_sources.is_legacy_ergopti_id
local migrate_legacy_id             = input_sources.migrate_legacy_id
local upgrade_active_list           = input_sources.upgrade_active_list
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
	if type(update_menu) ~= "function" then return end
	if hs.timer and type(hs.timer.doAfter) == "function" then
		hs.timer.doAfter(POST_INSTALL_REFRESH_DELAY, function() pcall(update_menu) end)
	else
		pcall(update_menu)
	end
end

--- Defers `fn` so it runs AFTER the current menu-click handler has unwound.
--- TIS (Text Input Sources) calls — TISEnableInputSource, TISSelectInputSource,
--- TISDisableInputSource — synchronously trigger macOS input-source change
--- notifications that hs.keycodes observes. Running them inside the menu
--- callback frame has been observed to re-enter Lua state and crash
--- Hammerspoon. A short hs.timer.doAfter() gives the click handler a chance
--- to return before the TIS mutation is dispatched.
--- @param fn function The TIS-touching callback to defer.
local function defer_tis_call(fn)
	if type(fn) ~= "function" then return end
	if hs.timer and type(hs.timer.doAfter) == "function" then
		hs.timer.doAfter(TIS_CALL_DELAY, function() pcall(fn) end)
	else
		pcall(fn)
	end
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
		pcall(upgrade_active_list, legacy_active)
	end
	schedule_menu_refresh(update_menu)
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

	local submenu = {}
	-- The two blocks this driver alone has — installing the .bundle layout macOS
	-- needs, and choosing the menubar logo — are collected for the manifest slots
	-- that declare them rather than appended here. They were eight and two rows
	-- of a shared menu that nothing described.
	local bundle_rows    = {}
	local logo_rows      = {}
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
	--   2. older active, latest installed  → in-place TIS swap (programmatic)
	--   3. older active, latest NOT installed → greyed: install latest first
	--   4. some/no variants present, latest installed → submenu (added ones greyed)
	--   5. absent, latest NOT installed    → greyed: install latest first
	local latest_ver = latest and parse_version(latest) or nil
	local latest_str = latest_ver and version_str(latest_ver) or "?"
	local all_variants_active = true
	for _, var in ipairs(ERGOPTI_VARIANTS) do
		if not active_id_set_pre[var.id] then all_variants_active = false; break end
	end
	-- Installed bundle version: system preferred, then user. Used for the label in state 1.
	-- We derive this from the filesystem, not from TIS, which is unreliable on Sequoia.
	local installed_ver = (system_best and system_best.version) or (user_best and user_best.version)
	if all_variants_active and installed_ver then
		-- 1. All variants already in list and up to date
		bundle_rows[#bundle_rows + 1] = {
			label    = string.format(i18n.get("menu.layout.in_list"), version_str(installed_ver)),
			disabled = true,
		}
	elseif #legacy_active > 0 and latest ~= nil and not latest_installed_anywhere then
		-- 3. Legacy entry active but latest bundle missing — block the upgrade
		-- Extract version from the first legacy KeyboardLayout Name (e.g. "Ergopti_v2_1_0" → "2.1.0")
		local _m = (legacy_active[1] or ""):match("_v(%d+_%d+_%d+)")
		local old_str = _m and _m:gsub("_", ".") or "?"
		bundle_rows[#bundle_rows + 1] = {
			label    = string.format(i18n.get("menu.layout.update_list_install_first"),
				latest_str, old_str),
			disabled = true,
		}
	elseif #legacy_active > 0 then
		-- 2. Legacy entry active and latest installed — programmatic swap via TIS
		local _m = (legacy_active[1] or ""):match("_v(%d+_%d+_%d+)")
		local old_str = _m and _m:gsub("_", ".") or "?"
		bundle_rows[#bundle_rows + 1] = {
			label = string.format(i18n.get("menu.layout.update_list"), old_str, latest_str),
			action    = function()
				defer_tis_call(function()
					local ok = upgrade_active_list(legacy_active)
					if ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_ok"), nil, "success") end
					if not ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_fail"), nil, "error") end
					schedule_menu_refresh(update_menu)
				end)
			end,
		}
	elseif latest_installed_anywhere then
		-- 4. Some or no variants present, bundle installed — submenu listing each
		-- variant. Already-added variants are greyed individually with ✅.
		local active_id_set = active_id_set_pre

		-- Resolve the installed bundle path (system preferred over user).
		-- The keylayout internal name base is the bundle basename without ".bundle",
		-- with dots replaced by underscores (e.g. "Ergopti_v2.2.2.bundle" → "Ergopti_v2_2_2").
		local installed_dir, installed_name
		if system_best then
			installed_dir  = SYSTEM_LAYOUTS_DIR
			installed_name = system_best.name
		elseif user_best then
			installed_dir  = USER_LAYOUTS_DIR
			installed_name = user_best.name
		end
		local bundle_base = installed_name and installed_name:gsub("%.bundle$", ""):gsub("%.", "_") or ""
		local bundle_full_path = (installed_dir and installed_name) and
			(installed_dir:gsub("[/\\]$", "") .. "/" .. installed_name) or ""

		local add_sub = {}
		for _, var in ipairs(ERGOPTI_VARIANTS) do
			local id            = var.id
			local suffix        = var.suffix or ""
			local internal_name = bundle_base .. suffix
			local already_added = active_id_set[id] == true
			if already_added then
				add_sub[#add_sub + 1] = {
					label    = string.format(i18n.get("menu.layout.already_added"), var.label, latest_str),
					disabled = true,
				}
			else
				add_sub[#add_sub + 1] = {
					label = string.format("%s v%s", var.label, latest_str),
					action    = function()
						defer_tis_call(function()
							local ok = enable_and_select_source(id, var.label, bundle_full_path, internal_name)
							if ok then pcall(notifications.notify, string.format(i18n.get("menu.layout.add_ok"), var.label), nil, "success") end
							if not ok then pcall(notifications.notify, i18n.get("menu.layout.add_fail"), nil, "error") end
							schedule_menu_refresh(update_menu)
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

	-- Logo variant toggle (persisted via hs.settings)
	local current_variant = (hs.settings and hs.settings.get(LOGO_VARIANT_KEY)) or LOGO_VARIANT_DEFAULT
	local function set_variant(v)
		if hs.settings and type(hs.settings.set) == "function" then
			pcall(hs.settings.set, LOGO_VARIANT_KEY, v)
		end
		Logger.debug(LOG, "Logo variant: %s.", tostring(v))
		-- Re-render the menubar icon and rebuild the submenu so the checkmarks
		-- reflect the new state. refresh_icon is provided directly by ui.menu.init
		-- via ctx, avoiding a require() round-trip that previously could re-enter
		-- a partially-initialized module
		if type(refresh_icon) == "function" then pcall(refresh_icon) end
		-- pcall guards a hard crash from any rebuild path
		if type(update_menu) == "function" then pcall(update_menu) end
	end
	logo_rows[#logo_rows + 1] = {
		label   = i18n.get("menu.layout.logo_default"),
		checked = current_variant == "simple",
		action      = function() set_variant("simple") end,
	}
	logo_rows[#logo_rows + 1] = {
		label   = i18n.get("menu.layout.logo_custom"),
		checked = current_variant == "complex",
		action      = function() set_variant("complex") end,
	}

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
			-- for Ergopti variants). set_input_source tries them in order.
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
						set_input_source(target_localised, target_kl_name)
						schedule_menu_refresh(update_menu)
					end)
				end,
			}
		end
	end

		return rows
	end

	-- The manifest's own rows for this menu, rendered here rather than repeated:
	-- the section header above the layout list, the separators around it, and the
	-- `active_layouts` slot this driver had never answered. Everything this file
	-- still appends by hand — the install/update block above and the pause/resume
	-- pickers below — is macOS's own and stays until it is declared too.
	do
		local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
		if ok_mm and type(ManifestMenu.build) == "function" then
			local rendered = ManifestMenu.build("layout_menu", "Layout", nil, nil, ctx, {
				["active_layouts"] = active_layout_rows,
				["layout_bundle"]  = function() return bundle_rows end,
				["layout_logo"]    = function() return logo_rows end,
				["layout_switching"] = function() return switching_rows end,
			})
			for _, row in ipairs(rendered or {}) do submenu[#submenu + 1] = row end
		else
			-- Loud: the rows would simply be absent, and a layout list that
			-- silently disappears reads as "macOS has no layouts installed".
			Logger.error(LOG, "Manifest renderer unavailable — the layout list is not rendered.")
		end
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

	-- J→★ remapping lives here because it configures the physical key, not hotstring behaviour.
	-- repeat_key_toggle remains in Hotstrings > Paramètres as it governs hotstring timing.
	local hs_paused = ctx and ctx.paused
	local replace_enabled = ctx and ctx.keymap
		and type(ctx.keymap.is_section_enabled) == "function"
		and ctx.keymap.is_section_enabled("magic_key", "replace")
	local replace_group_on = ctx and ctx.keymap
		and type(ctx.keymap.is_group_enabled) == "function"
		and ctx.keymap.is_group_enabled("magic_key")
	-- Resolve the section label from the TOML _meta.sections description (locale-aware)
	local replace_label = nil
	if ctx and ctx.keymap and type(ctx.keymap.get_sections) == "function" then
		local mk_secs = ctx.keymap.get_sections("magic_key")
		if type(mk_secs) == "table" then
			for _, sec in ipairs(mk_secs) do
				if type(sec) == "table" and sec.name == "replace" and sec.description then
					local desc = sec.description
					if type(desc) == "table" then
						local code = i18n.get_locale and i18n.get_locale() or "fr"
						replace_label = desc[code] or desc["fr"]
					elseif type(desc) == "string" then
						replace_label = desc
					end
					break
				end
			end
		end
	end
	if replace_label then
		submenu[#submenu + 1] = { separator = true }
		submenu[#submenu + 1] = {
			label    = replace_label,
			checked  = replace_enabled or nil,
			disabled = not replace_group_on or hs_paused or nil,
			action       = (replace_group_on and not hs_paused) and function()
				if ctx and ctx.keymap then
					if replace_enabled then
						if type(ctx.keymap.disable_section) == "function" then
							pcall(ctx.keymap.disable_section, "magic_key", "replace")
						end
					else
						if not KeymapLifecycle.ensure_started(ctx, "enable magic-key replacement") then
							return
						end
						if type(ctx.keymap.enable_section) == "function" then
							pcall(ctx.keymap.enable_section, "magic_key", "replace")
						end
					end
				end
				ctx.do_reload("menu")
			end or nil,
		}
	end

	return {
		label = i18n.get("menu.layout.title"),
		items  = submenu,
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
--- Falls back to the TIS osascript path when setLayout fails (Ergopti on Sequoia).
--- @param kl_name string Raw KeyboardLayout Name from HIToolbox, e.g. "Ergopti_v2_2_2_plus".
--- @return boolean true on success.
function M.set_layout_by_kl_name(kl_name)
	if type(kl_name) ~= "string" or kl_name == "" then return false end
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
	return set_input_source(localised, kl_name)
end

--- Schedules the pause / resume keyboard-layout switch on a DEFERRED run-loop
--- cycle instead of running it inline.
---
--- This MUST be deferred and never called synchronously from the pause-change
--- callback: that callback runs inside the script-control eventtap callback
--- (script_control.dispatch_action → _on_pause_change), and set_layout_by_kl_name
--- spawns BLOCKING /usr/bin/osascript subprocesses (run_osascript_isolated — one
--- to enumerate the TIS sources, one to select the target). Stalling the eventtap
--- callback for the hundreds of ms those take makes macOS disable the tap with
--- kCGEventTapDisabledByTimeout, after which AltGr+Enter stops toggling pause
--- entirely. Deferring lets the eventtap callback return immediately so the tap
--- stays alive.
--- @param is_paused boolean Current pause state (true just entered pause).
--- @param state table Menu state exposing layout_pause_switch_enabled / layout_on_pause / layout_on_resume.
--- @param schedule function|nil Injectable scheduler(fn) for tests; defaults to hs.timer.doAfter(0, fn).
--- @return string|nil The target layout that was scheduled, or nil when no switch is needed.
function M.schedule_pause_layout_switch(is_paused, state, schedule)
	if type(state) ~= "table" or not state.layout_pause_switch_enabled then return nil end
	local target = is_paused and state.layout_on_pause or state.layout_on_resume
	-- Nil / false / "auto" / "" all mean « do nothing » (the dropdowns default to false).
	if type(target) ~= "string" or target == "" then return nil end
	-- Resolve hs.timer lazily so the module stays loadable in the cross-platform
	-- test harness where hs is absent and the scheduler is injected.
	if type(schedule) ~= "function" then
		schedule = function(fn) hs.timer.doAfter(0, fn) end
	end
	schedule(function()
		-- Look the setter up on M at call time so a test stub on the module is honoured.
		if type(M.set_layout_by_kl_name) == "function" then
			pcall(M.set_layout_by_kl_name, target)
		end
	end)
	return target
end

return M
