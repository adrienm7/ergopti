--- ui/menu/menu_builder.lua

--- ==============================================================================
--- MODULE: Menu Builder (Linux)
--- DESCRIPTION:
--- Builds the tray menu item list from the daemon's runtime state. Called by
--- ergopti_hotstrings.lua to populate the tray_menu adapter with dynamic items
--- reflecting the current hotstring groups, layouts, LLM models, and metrics.
---
--- The menu tree mirrors the macOS menubar (§9 of the parity plan):
---   Layout → Hotstrings → AI → Metrics → Shortcuts → Kanata → Gestures → Apps
---   → separator → Global Actions → Language → Config Folder → Setup Wizard
---   → About → Reload → Quit → Debug
---
--- Items that depend on features not yet implemented on Linux
--- are present as labelled stubs that log the action — they don't crash and
--- they show the intended final shape.
---
--- FEATURES & RATIONALE:
--- 1. Hierarchical items: items with a `menu` sub-table are rendered as
---    submenus, which the tray backend renders as real nested GtkMenus.
--- 2. All callbacks are closures over the daemon's state — zero global coupling.
--- 3. New sections (shortcuts, kanata, gestures, apps, global_actions, language,
---    config, debug) are added as documented stubs so the menu shape is correct.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Extensions = require("hotstrings.extensions")
local LOG = "ui.menu.menu_builder"

-- Single source of the driver version.
local Version = require("infra.version")

-- The shared manifest menu renderer, bound for this driver (infra/manifest_menu).
-- pcall for the same reason i18n_safe exists: the tray menu must still build when
-- the shared tree is not reachable, which is a real boot-order case on a partial
-- install rather than a hypothetical.
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

--- Substitutes a single placeholder in a translated template.
---
--- Plain indices rather than gsub: a release tag or an interval code is data,
--- and a "%" in it would be read as a capture reference in gsub's REPLACEMENT
--- string and raise "invalid use of '%'".
--- @param template string The translated string, containing `placeholder`.
--- @param placeholder string The literal token to replace, e.g. "{tag}".
--- @param value any The value to substitute.
--- @return string The filled template.
local function _fill(template, placeholder, value)
	local at = template:find(placeholder, 1, true)
	if not at then return template .. " " .. tostring(value) end
	return template:sub(1, at - 1) .. tostring(value) .. template:sub(at + #placeholder)
end

local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function gesture_slot_label(slot)
	local fingers, direction = tostring(slot):match("^swipe_(%d+)_(.+)$")
	if fingers and direction then
		local directions = {
			left = "gauche", right = "droite", up = "haut", down = "bas",
			up_left = "haut-gauche", up_right = "haut-droite",
			down_left = "bas-gauche", down_right = "bas-droite",
		}
		return "Balayage " .. fingers .. " doigts vers " .. (directions[direction] or direction)
	end
	local tap_fingers = tostring(slot):match("^tap_(%d+)$")
	if tap_fingers then return "Tap " .. tap_fingers .. " doigts" end
	return tostring(slot)
end


-- =========================================
-- =========================================
-- ======= 1/ Section Builders =============
-- =========================================
-- =========================================

--- Builds the top-level header with version.
--- Returns a single item (not an array) — callers insert it directly.
local function _build_header(ctx)
	local v = ctx._version or Version.VERSION
	return { title = "Ergopti — v" .. v, fn = function() end, disabled = true }
end

--- Builds the layout selection submenu.
local function _build_layouts(ctx)
	local current = ctx.layout or "qwerty"
	local on_change = ctx.on_layout_change
	return {
		title = i18n_safe("menu.layout.title"),
		menu = {
			{
				title = "qwerty " .. (current == "qwerty" and "✓" or ""),
				fn = function()
					if on_change then on_change("qwerty") end
				end,
			},
			{
				title = "azerty " .. (current == "azerty" and "✓" or ""),
				fn = function()
					if on_change then on_change("azerty") end
				end,
			},
		},
	}
end

--- Renders the rows of the hotstrings submenu that the manifest describes.
---
--- Defined BEFORE its caller: a `local function` is not hoisted
--- (project-lua-closure-before-local-nil-global).
---
--- THE GROUP CLASSIFICATION COMES FROM THE MANIFEST, and it spells the group ids
--- with underscores (`distances_reduction`) while the shared hotstring index
--- spells them without (`distancesreduction`). macOS reconciles the two by
--- comparing both forms; this does the same rather than inventing a third
--- answer. One vocabulary would be better and neither driver owns that decision.
--- @param ctx table Menu context; ctx.webview opens the settings window.
--- @param config table The hotstrings config module.
--- @return table Menu rows, empty when the renderer could not be bound.
local function _manifest_hotstring_rows(ctx, config)
	if not ManifestMenu then
		Logger.warn(LOG, "Manifest renderer unavailable — the hotstrings submenu loses its declared rows.")
		return {}
	end

	local root    = ManifestMenu.get_root() or {}
	local classes = type(root.hotstring_groups) == "table" and root.hotstring_groups or {}
	local groups  = type(config.get_groups) == "function" and (config.get_groups() or {}) or {}

	--- The group ids of one manifest class, in both spellings.
	--- @param class string "standard", "dynamic" or "ergopti".
	--- @return table Set of accepted ids.
	local function members_of(class)
		local set = {}
		for _, id in ipairs(classes[class] or {}) do
			set[id] = true
			local flattened = id:gsub("_", "")
			if flattened ~= id then set[flattened] = true end
		end
		return set
	end

	--- The name to show for a category, in the user's language.
	---
	--- The packs carry a description in 21 locales and the menu used to print the
	--- file stem, in every language: "distancesreduction" rather than "Réduction
	--- des distances". English is the fallback because it is the reference locale
	--- the others are checked against, and the stem is the last resort.
	--- @param id string Category id.
	--- @param category table|nil Category metadata from the loader.
	--- @return string
	local function category_label(id, category)
		local description = category and category.description or nil
		if type(description) ~= "table" then return id end
		local locale = "en"
		local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
		if ok_i18n and type(i18n_mod.get_locale) == "function" then
			local current = i18n_mod.get_locale()
			if type(current) == "string" and current ~= "" then locale = current end
		end
		return description[locale] or description.en or id
	end

	--- The display name of an installed extension.
	---
	--- The loader stapled the extension's manifest name onto every category it
	--- produced, so the name is read back from any one of its packs rather than by
	--- rescanning the disk from the menu — a menu build must not do file I/O, and
	--- the tray rebuilds this on every toggle.
	--- @param extension_id string The id parsed out of a namespaced category key.
	--- @return string
	local function extension_label(extension_id)
		for _, name in ipairs(groups) do
			local id = Extensions.parse_category_key(name)
			if id == extension_id then
				local category = type(config.get_category) == "function" and config.get_category(name) or nil
				local extension = category and category.extension or nil
				if type(extension) == "table" and type(extension.name) == "string" and extension.name ~= "" then
					return extension.name
				end
			end
		end
		return extension_id
	end

	--- One category, as a submenu rather than a single toggle.
	---
	--- This is where roughly four fifths of the rows the other two drivers show
	--- come from, and Linux had none of them: a category was one line reading its
	--- own file stem with a tick, and its sections, its counts and its file were
	--- unreachable. Everything below comes from the loader's catalogue, which is
	--- the same parse the engine already did.
	--- @param id string Category id.
	--- @return table
	local function category_submenu(id)
		local category = (type(config.get_category) == "function") and config.get_category(id) or nil
		local on = config.is_group_enabled and config.is_group_enabled(id)
		local count = category and category.count or 0

		local sub = {}

		-- The gate first, because everything under it is inert while it is off.
		sub[#sub + 1] = {
			title = i18n_safe(on and "menu.hotstrings.category_on" or "menu.hotstrings.category_off"),
			fn    = function()
				if config.toggle_group then config.toggle_group(id) end
			end,
		}

		if category and category.path then
			sub[#sub + 1] = {
				title = i18n_safe("menu.hotstrings.open_file"),
				fn    = function()
					if type(ctx.on_open_file) == "function" then ctx.on_open_file(category.path) end
				end,
			}
		end

		local sections = category and category.sections_order or {}
		if #sections > 0 then
			sub[#sub + 1] = { title = "-" }
			sub[#sub + 1] = {
				title = i18n_safe("menu.hotstrings.check_all"),
				disabled = not on,
				fn = function()
					if config.set_all_sections then config.set_all_sections(id, true) end
				end,
			}
			sub[#sub + 1] = {
				title = i18n_safe("menu.hotstrings.uncheck_all"),
				disabled = not on,
				fn = function()
					if config.set_all_sections then config.set_all_sections(id, false) end
				end,
			}
			sub[#sub + 1] = { title = "-" }

			for _, name in ipairs(sections) do
				local section = (category.sections or {})[name]
				local section_on = config.is_section_enabled and config.is_section_enabled(id, name)
				sub[#sub + 1] = {
					-- The count is the point of the row: a section with three entries
					-- and one with nine hundred are the same line without it.
					title    = string.format("%s (%d)", name, section and section.count or 0),
					checked  = section_on and true or false,
					-- Greyed rather than hidden while the category is off: a row that
					-- disappears reads as a bug, and the user still needs to see what
					-- they will get back when they switch the category on.
					disabled = not on,
					fn = function()
						if config.toggle_section then config.toggle_section(id, name) end
					end,
				}
			end
		end

		return {
			title   = string.format("%s (%d)", category_label(id, category), count),
			checked = on and true or false,
			menu    = sub,
		}
	end

	--- Kept as the name the callers below already use.
	--- @param name string Category id.
	--- @return table
	local function group_row(name)
		return category_submenu(name)
	end

	--- Appends every loaded group belonging to `class`.
	--- @param items table
	--- @param class string
	local function append_class(items, class)
		local want  = members_of(class)
		local added = 0
		for _, name in ipairs(groups) do
			if want[name] then
				items[#items + 1] = group_row(name)
				added = added + 1
			end
		end
		if added == 0 then
			items[#items + 1] = {
				title = i18n_safe("menu.hotstrings.no_group_loaded"), fn = function() end, disabled = true,
			}
		end
	end

	-- "Personal" is defined by exclusion: whatever the user loaded that the
	-- manifest does not classify. Listing it any other way would need a second
	-- classification to keep in step with the first.
	local classified = {}
	for _, class in ipairs({ "standard", "dynamic", "ergopti" }) do
		for id in pairs(members_of(class)) do classified[id] = true end
	end

	--- Flips every loaded group to `on`.
	--- @param on boolean
	--- @return function
	local function set_all(on)
		return function()
			for _, name in ipairs(groups) do
				local is_on = config.is_group_enabled and config.is_group_enabled(name)
				if is_on ~= on and config.toggle_group then config.toggle_group(name) end
			end
		end
	end

	local ok_term, Terminators = pcall(require, "keymap.terminators")
	if not ok_term then Terminators = nil end

	local params_handlers = {
		["word_expanders"] = function(items)
			if not Terminators then
				Logger.error(LOG, "keymap.terminators unavailable — the word-delimiter submenu is skipped.")
				return
			end

			--- Every delimiter key currently known, custom ones included.
			--- @return table Array of key strings.
			local function all_keys()
				local keys = {}
				for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
					if def.key then keys[#keys + 1] = def.key end
				end
				return keys
			end

			--- Sets every delimiter at once.
			--- @param on boolean
			--- @return function
			local function set_all(on)
				return function()
					for _, key in ipairs(all_keys()) do
						Terminators.set_terminator_enabled(key, on)
					end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end
			end

			local sub = {}

			-- The bulk rows first. A user turning delimiters off does it wholesale —
			-- the point of the feature is "expand only on the key I chose" — and
			-- clicking through twenty rows to get there is not an interface.
			sub[#sub + 1] = { title = i18n_safe("menu.hotstrings.check_all"),   fn = set_all(true) }
			sub[#sub + 1] = { title = i18n_safe("menu.hotstrings.uncheck_all"), fn = set_all(false) }
			sub[#sub + 1] = { title = "-" }

			for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
				if def.type == "separator" then
					sub[#sub + 1] = { title = "-" }
				elseif def.key then
					local key = def.key
					local label = def.label or key
					-- A consumed delimiter is swallowed by the expansion; an unconsumed
					-- one is typed after it. The difference is visible only in the
					-- output, so the row has to say which it is — a space that vanishes
					-- and a space that stays look like a bug either way round.
					local first_char = type(def.chars) == "table" and def.chars[1] or nil
					if first_char and Terminators.terminator_is_consumed
						and Terminators.terminator_is_consumed(first_char) then
						label = label .. " " .. i18n_safe("menu.hotstrings.consumed_suffix")
					end
					sub[#sub + 1] = {
						title   = label,
						checked = Terminators.is_terminator_enabled(key) and true or false,
						fn      = function()
							Terminators.set_terminator_enabled(key, not Terminators.is_terminator_enabled(key))
							if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						end,
					}
					if def.custom then
						sub[#sub + 1] = {
							title = "    " .. i18n_safe("menu.hotstrings.delete_delimiter"),
							fn    = function()
								Terminators.remove_custom_terminator(key)
								if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
							end,
						}
					end
				end
			end

			sub[#sub + 1] = { title = "-" }
			sub[#sub + 1] = {
				title = i18n_safe("menu.hotstrings.add_delimiter"),
				fn    = function()
					if type(ctx.on_add_delimiter) == "function" then ctx.on_add_delimiter() end
				end,
			}

			items[#items + 1] = { title = i18n_safe("menu.hotstrings.word_expanders"), menu = sub }
		end,
		["delays_colors"] = function(items)
			-- One row, not the Windows submenu: that one also carries per-category
			-- delay prompts, and this driver has no per-category delays to prompt
			-- for. What it does have is the settings window, which is what the row
			-- is for.
			items[#items + 1] = {
				title = i18n_safe("menu.hotstrings.delays_colors"),
				fn    = function()
					if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
						Logger.error(LOG, "No webview manager in the menu context — cannot open the hotstrings settings.")
						return
					end
					ctx.webview.show("hotstrings_config")
				end,
			}
		end,
	}

	local handlers = {
		["hotstring_bulk_actions"] = function(items)
			items[#items + 1] = { title = i18n_safe("menu.hotstrings.enable_all"),  fn = set_all(true) }
			items[#items + 1] = { title = i18n_safe("menu.hotstrings.disable_all"), fn = set_all(false) }
		end,
		["hotstring_categories_standard"] = function(items) append_class(items, "standard") end,
		["hotstring_categories_dynamic"]  = function(items) append_class(items, "dynamic") end,
		["hotstring_categories_ergopti"]  = function(items) append_class(items, "ergopti") end,
		["hotstring_personal"] = function(items)
			local added = 0
			for _, name in ipairs(groups) do
				-- Extension packs are unclassified too, but they are not personal
				-- files: they belong to the extension that shipped them and get their
				-- own section below. Without this test they appeared here, under a
				-- heading that told the user they had written them.
				if not classified[name] and not Extensions.parse_category_key(name) then
					items[#items + 1] = group_row(name)
					added = added + 1
				end
			end
			if added == 0 then
				items[#items + 1] = {
					title = i18n_safe("menu.hotstrings.no_group_loaded"), fn = function() end, disabled = true,
				}
			end
		end,
		["hotstring_extensions"] = function(items)
			-- One submenu per installed extension, holding its packs. Grouped by
			-- extension rather than listed flat because an extension is the unit the
			-- user installed and the unit they will want to turn off; its individual
			-- packs are an implementation detail of how its author organised them.
			local by_extension, order = {}, {}
			for _, name in ipairs(groups) do
				local extension_id = Extensions.parse_category_key(name)
				if extension_id then
					if not by_extension[extension_id] then
						by_extension[extension_id] = {}
						order[#order + 1] = extension_id
					end
					local list = by_extension[extension_id]
					list[#list + 1] = name
				end
			end

			if #order == 0 then
				items[#items + 1] = {
					title    = i18n_safe("menu.extensions.none_installed"),
					fn       = function() end,
					disabled = true,
				}
				return
			end

			for _, extension_id in ipairs(order) do
				local packs = by_extension[extension_id]
				local sub = {}

				-- Turning the extension off means turning off every pack it brought.
				-- Offered first because it is the action the extension as a unit
				-- affords; the per-pack rows below are for the user who wants half.
				sub[#sub + 1] = {
					title = i18n_safe("menu.hotstrings.check_all"),
					fn    = function()
						for _, name in ipairs(packs) do
							if config.is_group_enabled and not config.is_group_enabled(name)
								and config.toggle_group then config.toggle_group(name) end
						end
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
				sub[#sub + 1] = {
					title = i18n_safe("menu.hotstrings.uncheck_all"),
					fn    = function()
						for _, name in ipairs(packs) do
							if config.is_group_enabled and config.is_group_enabled(name)
								and config.toggle_group then config.toggle_group(name) end
						end
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
				sub[#sub + 1] = { title = "-" }

				for _, name in ipairs(packs) do
					sub[#sub + 1] = group_row(name)
				end

				items[#items + 1] = { title = extension_label(extension_id), menu = sub }
			end
		end,
	}

	local group_builders = {
		["hotstrings_params"] = function(c)
			return ManifestMenu.build("hotstrings_params_group", "HotstringsParams", params_handlers, nil, c)
		end,
	}

	return ManifestMenu.build("hotstrings_menu", "Hotstrings", handlers, group_builders, ctx)
end

--- Builds the hotstrings submenu: the manifest's rows, then this driver's own.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_hotstrings(ctx)
	local config = ctx.config

	if type(config) ~= "table" then
		return { title = i18n_safe("menu.hotstrings.title"), menu = {
			{ title = "(config non disponible)", fn = function() end, disabled = true },
		}}
	end

	local items = _manifest_hotstring_rows(ctx, config)

	-- Not a manifest row on any driver: reloading the catalogue from disk is this
	-- driver's own affordance, because it is the only one whose hotstrings can
	-- change under it without a restart.
	items[#items + 1] = { title = "-" }
	items[#items + 1] = {
		title = "Recharger les hotstrings",
		fn = function()
			if config.reload then config.reload() end
		end,
	}

	return { title = i18n_safe("menu.hotstrings.title"), menu = items }
end

--- Builds the AI / LLM submenu.
local function _build_llm(ctx)
	local llm = ctx.llm
	if not llm then
		return { title = i18n_safe("menu.llm.title"), menu = {
			{ title = "LLM non disponible", fn = function() end, disabled = true },
			{ title = i18n_safe("menu.llm.ollama_start_hint"), fn = function() end, disabled = true },
		}}
	end

	local items = {}
	local enabled = llm.is_enabled and llm:is_enabled() or false

	items[#items + 1] = {
		title = i18n_safe("menu.common.enabled") .. (enabled and " ✓" or ""),
		fn = function()
			if llm.toggle then llm:toggle() end
		end,
	}

	if type(llm.get_models) == "function" then
		local models = llm:get_models()
		if type(models) == "table" then
			for _, model in ipairs(models) do
				local is_current = (llm.get_current_model and llm:get_current_model() == model)
				items[#items + 1] = {
					title = model .. (is_current and " ✓" or ""),
					fn = function()
						if llm.set_model then llm:set_model(model) end
					end,
				}
			end
		end
	end

	return { title = i18n_safe("menu.llm.title"), menu = items }
end

--- Builds the metrics/keylogger submenu.
--- Builds one privacy-toggle entry for the metrics submenu.
--- Reads the live value from get_privacy_state() rather than a cached copy, so
--- the tick always reflects what the keylogger is actually doing.
--- @param k       table    The keylogger module.
--- @param key     string   Field of get_privacy_state() this entry reflects.
--- @param label   string   User-facing label (French, per the UI convention).
--- @param setter  function Setter to call on toggle.
--- @return table The menu entry.
local function _privacy_toggle(k, key, label, setter)
	local available = type(k.get_privacy_state) == "function" and type(setter) == "function"
	if not available then
		return { title = label .. " (indisponible)", fn = function() end, disabled = true }
	end
	local active = k.get_privacy_state()[key] == true
	return {
		title = label .. (active and " ✓" or ""),
		fn = function() setter(not k.get_privacy_state()[key]) end,
	}
end

--- Reports the at-rest migration and offers to stop it.
--- Converting a year of stored rows takes minutes, and without this entry the
--- user ticks menu.metrics.encrypt_at_rest and sees nothing happen at all.
--- @param k table The keylogger module.
--- @return table One menu entry.
local function _migration_status(k)
	if type(k.get_migration_progress) ~= "function" then
		return { title = "Migration du chiffrement (indisponible)", fn = function() end, disabled = true }
	end
	local progress = k.get_migration_progress()
	if not progress.running then
		return { title = "Migration du chiffrement : inactive", fn = function() end, disabled = true }
	end
	return {
		title = string.format(i18n_safe("menu.metrics.migration_progress"),
			progress.scanned, progress.total),
		fn = function()
			if type(k.cancel_migration) == "function" then k.cancel_migration() end
		end,
	}
end

--- Renders the rows of the metrics submenu that the manifest describes.
---
--- Defined BEFORE its caller: a `local function` is not hoisted, so calling it
--- above its definition would bind the nil global
--- (project-lua-closure-before-local-nil-global).
--- @param ctx table Menu context; ctx.webview opens the two metrics windows.
--- @param k table The keylogger module.
--- @return table Menu rows, empty when the renderer could not be bound.
local function _manifest_metrics_rows(ctx, k)
	if not ManifestMenu then
		Logger.warn(LOG, "Manifest renderer unavailable — the metrics submenu loses its declared rows.")
		return {}
	end

	--- Reads one flag out of the keylogger's privacy state.
	--- @param key string
	--- @return function
	local function privacy(key)
		return function()
			if type(k.get_privacy_state) ~= "function" then return false end
			return k.get_privacy_state()[key] == true
		end
	end

	-- The canonical state keys the manifest's disabled_when / checked_when arrays
	-- name. A key declared there with no getter here is an ERROR in the renderer,
	-- not a silent always-enabled row — which is the whole point of resolving them
	-- declaratively instead of re-deriving the condition at each call site.
	local getters = {
		keylogger_enabled      = function() return type(k.is_enabled) == "function" and k.is_enabled() end,
		metrics_filter_private = privacy("private_filter_enabled"),
		metrics_filter_secure  = privacy("secure_filter_enabled"),
		metrics_filter_sysauth = privacy("system_auth_filter_enabled"),
	}

	--- One manifest row, with its disabled state resolved from the manifest.
	--- @param id string Manifest item id.
	--- @param label string Translated label.
	--- @param checked boolean Whether to draw the checkmark.
	--- @param on_click function
	--- @return table
	local function row(id, label, checked, on_click)
		return {
			title    = label .. (checked and " ✓" or ""),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", id, getters) or nil,
			fn       = on_click,
		}
	end

	--- Opens one of the two metrics windows through the webview manager.
	--- @param app string Window id, e.g. "metrics_typing".
	--- @return function
	local function open_window(app)
		return function()
			if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
				Logger.error(LOG, "No webview manager in the menu context — cannot open '%s'.", app)
				return
			end
			ctx.webview.show(app)
		end
	end

	--- Flips one privacy flag.
	--- @param key string Privacy-state key.
	--- @param setter function|nil
	--- @return function
	local function toggle(key, setter)
		return function()
			if type(setter) ~= "function" then
				Logger.error(LOG, "No setter for privacy flag '%s' — the row does nothing.", key)
				return
			end
			setter(not privacy(key)())
		end
	end

	local handlers = {
		show_typing = function(items)
			items[#items + 1] = row("show_typing", i18n_safe("menu.metrics.show_typing"), false,
				open_window("metrics_typing"))
		end,
		show_apps = function(items)
			items[#items + 1] = row("show_apps", i18n_safe("menu.metrics.show_apps"), false,
				open_window("metrics_apps"))
		end,
		filter_private = function(items)
			items[#items + 1] = row("filter_private", i18n_safe("menu.metrics.filter_private"),
				ManifestMenu.resolve_checked_when("metrics_menu", "filter_private", getters),
				toggle("private_filter_enabled", k.set_private_filter_enabled))
		end,
		filter_secure = function(items)
			-- Was hardcoded French here, shown to every locale. The key exists in all
			-- 21 catalogues and always did; nothing was reading it.
			items[#items + 1] = row("filter_secure", i18n_safe("menu.metrics.filter_secure"),
				ManifestMenu.resolve_checked_when("metrics_menu", "filter_secure", getters),
				toggle("secure_filter_enabled", k.set_secure_filter_enabled))
		end,
		filter_sysauth = function(items)
			items[#items + 1] = row("filter_sysauth", i18n_safe("menu.metrics.filter_sysauth"),
				ManifestMenu.resolve_checked_when("metrics_menu", "filter_sysauth", getters),
				toggle("system_auth_filter_enabled", k.set_system_auth_filter_enabled))
		end,
		encryption = function(items)
			-- Read from state rather than resolved: unlike the three filters above,
			-- this manifest row declares no checked_when. Every driver therefore
			-- computes the checkmark itself, and that asymmetry is worth one comment
			-- rather than an invented predicate.
			items[#items + 1] = row("encryption", i18n_safe("menu.metrics.encrypt_at_rest"),
				privacy("encrypt")(),
				toggle("encrypt", k.set_encrypt_enabled))
		end,
	}

	return ManifestMenu.build("metrics_menu", "Metrics", handlers, nil, ctx)
end

--- Builds the metrics submenu, with the rows the manifest describes rendered by
--- the shared renderer and the rest appended after.
---
--- THE FIRST SUBMENU ON THIS DRIVER TO READ THE MANIFEST. Until 2026-08-04 Linux
--- opened `menu_manifest.json` nowhere at all — the top-level parity gate had to
--- parse this file's `_build_*` calls to compare the two, which is how `kanata`,
--- `updates` and `apps` were found built here and undescribed there.
---
--- Six rows now come from the manifest, with their `disabled_when` and
--- `checked_when` predicates resolved declaratively rather than re-derived here.
--- Seven others were removed from this driver's projection in the same pass,
--- because they configure features the FEATURE manifest already declares
--- elsewhere: the WPM widget (`ui/wpm` exists on macOS and Windows and not here),
--- the two metrics-window shortcuts, and the app-exclusion list, for which this
--- driver's keylogger exposes no setter. A row that cannot be rendered is a
--- promise the manifest makes on this driver's behalf and the driver breaks.
---
--- What stays hand-built below is what the manifest does not describe on any
--- driver: this driver's own session-stats, WPM and per-app readouts, the
--- encryption-migration status, and suspend/reset.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_metrics(ctx)
	local k = ctx.keylogger
	if type(k) ~= "table" then
		return { title = i18n_safe("menu.metrics.title"), menu = {
			{ title = i18n_safe("menu.metrics.unavailable"), fn = function() end, disabled = true },
		}}
	end

	local items = _manifest_metrics_rows(ctx, k)

	for _, row in ipairs({
		{
			title = "Statistiques de session",
			fn = function()
				if type(k.get_session_stats) ~= "function" then return end
				local s = k.get_session_stats()
				Logger.info(LOG, "Session: %d keystrokes, ~%d words, %ds.",
					s.keystrokes, s.words, math.floor(s.duration_ms / 1000))
			end,
		},
		{
			title = "WPM actuel",
			fn = function()
				if type(k.get_wpm) ~= "function" then return end
				Logger.info(LOG, "WPM: %.1f", k.get_wpm())
			end,
		},
		{
			title = "Stats par application",
			fn = function()
				if type(k.get_app_stats) ~= "function" then return end
				local apps = k.get_app_stats()
				for app, s in pairs(apps) do
					Logger.info(LOG, "  %s: %d keystrokes", app, s.keystrokes)
				end
			end,
		},
		{ title = "-" },
		-- The collection master toggle stays hand-built: this menu's manifest
		-- `toggle` row is platforms = ["hs"], so it describes macOS's row and not
		-- this driver's. The four filter and encryption toggles that used to sit
		-- beside it are gone from here — they are manifest rows now, rendered
		-- above with their checked_when and disabled_when resolved declaratively.
		_privacy_toggle(k, "enabled", i18n_safe("menu.metrics.collection_enabled"), k.set_enabled),
		_migration_status(k),
		{ title = "-" },
		{
			title = "Suspendre " .. (type(k.is_suppressed) == "function" and k.is_suppressed() and "✓" or ""),
			fn = function()
				if type(k.is_suppressed) ~= "function" then return end
				if k.is_suppressed() then k.unsuppress() else k.suppress() end
			end,
		},
		{
			title = i18n_safe("menu.metrics.reset_session"),
			fn = function()
				if type(k.reset_session) ~= "function" then return end
				k.reset_session()
				Logger.info(LOG, "Metrics session reset.")
			end,
		},
	}) do
		items[#items + 1] = row
	end

	return { title = i18n_safe("menu.metrics.title"), menu = items }
end

--- Builds the shortcuts submenu.
local function _build_shortcuts(ctx)
	local sc = ctx.shortcuts
	if not sc then
		return { title = i18n_safe("menu.shortcuts.title"), menu = {
			{ title = "(shortcuts non disponible)", fn = function() end, disabled = true },
		}}
	end

	local enabled = sc.is_enabled()
	local caps_active = sc.is_caps_word_active()
	local items = {}

	-- Master toggle.
	items[#items + 1] = {
		title = i18n_safe("menu.common.enabled") .. (enabled and " ✓" or ""),
		fn = function() sc.toggle() end,
	}
	items[#items + 1] = { title = "-" }

	-- CapsWord toggle.
	items[#items + 1] = {
		title = "CapsWord " .. (caps_active and "✓" or ""),
		fn = function()
			sc.toggle_caps_word()
			Logger.info(LOG, "CapsWord toggled: %s", tostring(sc.is_caps_word_active()))
		end,
	}

	-- Text transforms (operate on current X11 selection).
	items[#items + 1] = { title = "-" }
	items[#items + 1] = {
		title = "→ MAJUSCULES",
		fn = function() sc.transform_uppercase() end,
	}
	items[#items + 1] = {
		title = "→ minuscules",
		fn = function() sc.transform_lowercase() end,
	}
	items[#items + 1] = {
		title = "→ Title Case",
		fn = function() sc.transform_titlecase() end,
	}

	items[#items + 1] = { title = "-" }

	-- Selection helpers.
	items[#items + 1] = {
		title = i18n_safe("menu.shortcuts.select_word"),
		fn = function() sc.select_word() end,
	}
	items[#items + 1] = {
		title = i18n_safe("sg_actions.select_line"),
		fn = function() sc.select_line() end,
	}
	items[#items + 1] = {
		title = "Coller sans formatage",
		fn = function() sc.paste_plain() end,
	}

	-- Wrap symbols submenu.
	local wrap_items = {}
	local wrap_pairs = sc.get_wrap_pairs()
	for ch, pair in pairs(wrap_pairs) do
		-- Only include opening chars to avoid duplicates.
		if ch == pair.left then
			local cap = ch
			wrap_items[#wrap_items + 1] = {
				title = ch .. " … " .. pair.right .. "  (" .. ch .. "texte" .. pair.right .. ")",
				fn = function() sc.wrap_selection(pair.left, pair.right) end,
			}
		end
	end
	items[#items + 1] = { title = "Wrap symbols", menu = wrap_items }

	return { title = i18n_safe("menu.shortcuts.title"), menu = items }
end

--- Builds the Kanata submenu (Linux's Karabiner equivalent).
--- Actions delegate to the kanata manager module passed via ctx.kanata.
local function _build_kanata(ctx)
	local km = ctx.kanata

	-- Fallback: try direct require if not passed via context.
	if not km then
		local ok_km, km_mod = pcall(require, "platform.remap.manager")
		if ok_km then km = km_mod end
	end

	local running = km and km.is_running() or false

	return { title = i18n_safe("menu.kanata.title"), menu = {
		{
			title = i18n_safe("menu.kanata.generate_kbd"),
			fn = function()
				if km then
					if km.write_kbd() then
						Logger.info(LOG, "Kanata .kbd generated.")
					else
						Logger.error(LOG, "Kanata .kbd generation failed.")
					end
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
		{
			title = i18n_safe("menu.kanata.start") .. (running and " ✓" or ""),
			fn = function()
				if km then
					km.start()
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
		{
			title = i18n_safe("menu.kanata.stop"),
			fn = function()
				if km then
					km.stop()
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
		{
			title = i18n_safe("menu.kanata.restart"),
			fn = function()
				if km then
					km.restart()
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
	}}
end

--- Builds the gestures submenu.
local function _build_gestures(ctx)
	local ge = ctx.gestures
	if not ge then
		return { title = i18n_safe("menu.gestures.title"), menu = {
			{ title = "(gestures non disponible)", fn = function() end, disabled = true },
		}}
	end

	local enabled = ge.is_enabled()
	local items = {}

	-- Keyed by the manifest's own row ids rather than appended anonymously. The
	-- ids are what the action↔handler bijection gate matches on, and an anonymous
	-- row is a row the manifest can declare and no gate can find — which is how
	-- gestures came to be declared for two drivers while Linux built a third menu
	-- nobody had compared. It is also the shape ManifestMenu.build consumes, so
	-- this is the half of the migration that does not need the renderer.
	local gesture_rows = {
		["gestures_toggle"] = function()
			items[#items + 1] = {
				title = i18n_safe("menu.common.enabled") .. (enabled and " ✓" or ""),
				fn = function() ge.toggle() end,
			}
		end,
		["restore_defaults"] = function()
			items[#items + 1] = {
				title = i18n_safe("menu.gestures.restore_defaults"),
				fn = function() ge.reset_defaults() end,
			}
		end,
		["disable_all"] = function()
			items[#items + 1] = {
				title = i18n_safe("menu.gestures.disable_all"),
				fn = function() if ge.disable_all_actions then ge.disable_all_actions() end end,
			}
		end,
	}

	gesture_rows["gestures_toggle"]()
	items[#items + 1] = { title = "-" }
	gesture_rows["restore_defaults"]()
	gesture_rows["disable_all"]()
	items[#items + 1] = { title = "-" }

	local function prompt_parameter(slot, action, spec, prior)
		if type(ctx.prompt_action_parameter) == "function" then
			return ctx.prompt_action_parameter(slot, action, spec, prior)
		end
		local prompt = spec == "search_url"
			and i18n_safe("dialog.gestures.param_search_url")
			or i18n_safe("dialog.gestures.param_link")
		local command = "zenity --entry --title=" .. shell_quote("Configurer " .. (ge.get_action_label(action) or action))
			.. " --text=" .. shell_quote(prompt) .. " --entry-text=" .. shell_quote(prior or "") .. " 2>/dev/null"
		local pipe = io.popen(command, "r")
		if not pipe then
			Logger.error(LOG, "Zenity is unavailable: cannot configure %s for %s.", tostring(action), tostring(slot))
			return nil
		end
		local value = pipe:read("*a") or ""
		local ok = pipe:close()
		if not ok then return nil end
		return (value:gsub("%s+$", ""))
	end

	local function assign_action(slot, action)
		local spec = ge.get_action_parameter_spec and ge.get_action_parameter_spec(action) or nil
		if spec then
			local prior = ge.get_action_parameter and ge.get_action_parameter(slot, action) or ""
			local value = prompt_parameter(slot, action, spec, prior)
			if value == nil then return end
			if not ge.validate_action_parameter or not ge.validate_action_parameter(action, value) then
				Logger.warn(LOG, "Invalid parameter for gesture '%s' action '%s'.", tostring(slot), tostring(action))
				return
			end
			if not ge.set_action_parameter(slot, action, value) then return end
		end
		ge.set_action(slot, action)
	end

	-- The manifest's `gesture_slots_linux` row. One flat list rather than the
	-- per-finger-count groups macOS splits into (gesture_slots_2 … _5): the slots
	-- come from ge.DEFAULT_GESTURES, which is keyed by slot name and not by finger
	-- count, so grouping would mean parsing the names apart only to regroup them.
	gesture_rows["gesture_slots_linux"] = function()
		-- Every known slot is configurable here. A partial quick list made
		-- parameterized actions unreachable for the omitted gesture bindings.
		local slots = {}
		for slot in pairs(ge.DEFAULT_GESTURES or {}) do slots[#slots + 1] = slot end
		table.sort(slots)
		for _, slot in ipairs(slots) do
			local action = ge.get_action(slot) or "none"
			local label = ge.get_action_display_label and ge.get_action_display_label(slot)
				or ge.get_action_label(action)
			local choices = {}
			for _, option in ipairs(ge.get_action_names and ge.get_action_names() or { "none" }) do
				local selected = option == action
				choices[#choices + 1] = {
					title = ge.get_action_label(option) .. (selected and " ✓" or ""),
					fn = function() assign_action(slot, option) end,
				}
			end
			items[#items + 1] = {
				title = gesture_slot_label(slot) .. " → " .. label,
				menu = choices,
			}
		end
	end

	gesture_rows["gesture_slots_linux"]()

	items[#items + 1] = { title = "-" }

	-- Reading state.
	items[#items + 1] = {
		title = "Lecture libinput: " .. (ge.is_reading() and "active" or "inactive"),
		fn = function()
			if ge.is_reading() then
				ge.stop_reading()
			else
				ge.start_reading()
			end
		end,
	}

	return { title = i18n_safe("menu.gestures.title"), menu = items }
end

--- Builds the apps submenu (per-app configs via webview).
local function _build_apps(ctx)
	return { title = i18n_safe("menu.apps.title"), menu = {
		{
			title = i18n_safe("menu.apps.config_per_app"),
			fn = function()
				if ctx.webview then
					ctx.webview.show("hotstrings_config_window")
					Logger.info(LOG, "Opening hotstrings config window.")
				else
					Logger.info(LOG, "[stub] Webview manager not available — cannot open hotstrings config.")
				end
			end,
		},
		{ title = "-" },
		-- Was a hardcoded French string, so every non-French user read one French
		-- row in an otherwise translated menu. Found on 2026-08-03 while giving
		-- the manifest its Linux dimension; the key already existed and is the
		-- one the other two drivers use for the same row.
		{ title = i18n_safe("menu.global.config_folder"), fn = function()
			if ctx.on_open_config then ctx.on_open_config() end
		end },
	}}
end

--- Builds the global actions submenu.
local function _build_global_actions(ctx)
	return { title = i18n_safe("menu.global.title"), menu = {
		{
			title = i18n_safe("menu.global.enable_all"),
			fn = function()
				if ctx.on_enable_all then ctx.on_enable_all() end
			end,
		},
		{
			title = i18n_safe("menu.global.disable_all"),
			fn = function()
				if ctx.on_disable_all then ctx.on_disable_all() end
			end,
		},
		{ title = "-" },
		{
			title = i18n_safe("menu.global.reset_defaults"),
			fn = function()
				if ctx.on_reset_defaults then ctx.on_reset_defaults() end
			end,
		},
	}}
end

--- Builds the language selector submenu.
--- Lists all available locales, marks the active one with a checkmark.
--- Switching persists via i18n.set_locale() → storage adapter.
local function _build_language(_ctx)
	local items = {}

	-- Try to load i18n for real locale list + switching.
	local i18n = nil
	local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
	if ok_i18n then i18n = i18n_mod end

	if i18n then
		local active = i18n.get_locale()
		local locales = i18n.list_locales()
		for _, code in ipairs(locales) do
			local label = i18n.display_name(code) .. " (" .. code .. ")"
			if code == active then label = label .. " ✓" end
			local cap = code  -- capture for closure
			items[#items + 1] = {
				title = label,
				fn = function()
					i18n.set_locale(cap)
					Logger.info(LOG, "Language set to %s (persisted).", cap)
				end,
			}
		end
	else
		-- Fallback when i18n module is not loaded.
		items[#items + 1] = { title = "Français", fn = function()
			Logger.info(LOG, "[stub] Switch locale to fr.")
		end }
		items[#items + 1] = { title = "English", fn = function()
			Logger.info(LOG, "[stub] Switch locale to en.")
		end }
	end

	return { title = i18n_safe("menu.global.language"), menu = items }
end

--- Builds the config folder launcher.
local function _build_config_folder(ctx)
	return {
		title = i18n_safe("menu.global.config_folder"),
		fn = function()
			-- Through the resolver: this concatenated a possibly-nil HOME, which
			-- throws and takes the whole menu build with it.
			local ConfigPaths = require("infra.config_paths")
			local dir = ConfigPaths.config("hotstrings")
			Logger.info(LOG, "Opening config folder: %s", dir)
			if ctx.on_open_config then ctx.on_open_config(dir) end
		end,
	}
end

--- Builds the setup wizard launcher (opens the WebKitGTK onboarding window).
local function _build_setup_wizard(ctx)
	return {
		title = i18n_safe("menu.global.setup_wizard"),
		fn = function()
			if ctx.on_show_setup_wizard then ctx.on_show_setup_wizard() end
		end,
	}
end

--- Builds the updater submenu (GitHub releases, channel switching, download).
local function _build_updates(ctx)
	local up = ctx.updater
	if not up then
		return { title = i18n_safe("menu.updates.title"), menu = {
			{ title = "(updater non disponible)", fn = function() end, disabled = true },
		}}
	end

	local channel = up.get_channel()
	local version = up.current_version()
	local items = {}

	-- Header showing current version and channel.
	items[#items + 1] = {
		title = "v" .. version .. " (" .. channel .. ")",
		fn = function() end,
		disabled = true,
	}
	items[#items + 1] = { title = "-" }

	-- Check for updates now.
	items[#items + 1] = {
		title = up.get_menu_label(),
		fn = function()
			local available = up.check_for_updates()
			if available then
				local rel = up.get_cached_release()
				if rel then
					Logger.info(LOG, "Update available: %s.", rel.tag)
				end
			else
				Logger.info(LOG, "No update available (current: %s).", up.current_version())
			end
		end,
	}

	-- Download + install (only shown when an update is available).
	local state = up.get_state()
	if state == "available" then
		local rel = up.get_cached_release()
		if rel then
			items[#items + 1] = {
				title = _fill(i18n_safe("menu.updates.download_install"), "{tag}", rel.tag),
				fn = function()
					local archive = up.download_update()
					if archive then
						up.install_update(archive)
					end
				end,
			}
		end
	end

	items[#items + 1] = { title = "-" }

	-- Channel switching.
	items[#items + 1] = {
		title = "Canal stable" .. (channel == "stable" and " ✓" or ""),
		fn = function()
			up.set_channel("stable")
			Logger.info(LOG, "Update channel set to stable.")
		end,
	}
	items[#items + 1] = {
		title = i18n_safe("menu.updates.channel_dev") .. (channel == "dev" and " ✓" or ""),
		fn = function()
			up.set_channel("dev")
			Logger.info(LOG, "Update channel set to dev.")
		end,
	}

	items[#items + 1] = { title = "-" }

	-- Interval presets.
	local current_interval = up.get_check_interval()
	for _, preset in ipairs(up.INTERVAL_PRESETS) do
		local is_current = (preset.seconds == current_interval)
		items[#items + 1] = {
			title = _fill(i18n_safe("menu.updates.check_every"), "{interval}", preset.code)
				.. (is_current and " ✓" or ""),
			fn = function()
				up.set_check_interval(preset.seconds)
				up.stop_background_checks()
				up.start_background_checks()
			end,
		}
	end

	items[#items + 1] = { title = "-" }

	-- Open releases page.
	items[#items + 1] = {
		title = "Ouvrir la page des releases",
		fn = function()
			local url = up.releases_page_url()
			Logger.info(LOG, "Opening releases page: %s", url)
			os.execute(string.format("xdg-open '%s' 2>/dev/null &", url:gsub("'", "'\\''")))
		end,
	}

	return { title = i18n_safe("menu.updates.title"), menu = items }
end

--- Builds the about item.
local function _build_about(_ctx)
	return {
		title = i18n_safe("menu.about.title"),
		fn = function()
			Logger.info(LOG, "Ergopti — ergonomic keyboard optimizer.")
		end,
	}
end

--- Builds the reload item.
---
--- This used to run `kill -HUP $$` through os.execute. Two things were wrong
--- with that, and together they made the item a no-op that logged success:
--- `os.getpid` does not exist in Lua, so the expression always fell through to
--- the literal `"$$"`; and os.execute runs its string in a NEW /bin/sh, where
--- `$$` is that shell's own PID. The daemon therefore told a throwaway shell to
--- reload, and the shell obligingly killed itself.
---
--- The daemon owns the reload; the menu asks it to, exactly as the quit item
--- asks via on_quit. No signal, no subprocess, no PID to get wrong.
local function _build_reload(ctx)
	return {
		title = i18n_safe("menu.global.reload"),
		fn = function()
			if type(ctx.on_reload) ~= "function" then
				-- Loudly, not silently: a Reload item that cannot reload is the
				-- exact failure this replaced.
				Logger.error(LOG, "Reload requested but ctx.on_reload is absent — the menu cannot reload the daemon.")
				return
			end
			Logger.info(LOG, "Reload requested from the tray menu…")
			local ok, err = pcall(ctx.on_reload)
			if not ok then
				Logger.error(LOG, "Reload callback raised: %s.", tostring(err))
			end
		end,
	}
end

--- Builds the quit item.
local function _build_quit(ctx)
	return {
		title = i18n_safe("menu.global.quit"),
		fn = function()
			Logger.info(LOG, "Quit requested via tray menu.")
			if ctx.on_quit then ctx.on_quit() end
		end,
	}
end

--- Builds the debug submenu.
local function _build_debug(ctx)
	local log_levels = { "DEBUG", "INFO", "WARNING", "ERROR" }
	local level_items = {}
	for _, lvl in ipairs(log_levels) do
		level_items[#level_items + 1] = {
			title = lvl,
			fn = function()
				if ctx.on_set_log_level then ctx.on_set_log_level(lvl) end
			end,
		}
	end

	return { title = i18n_safe("menu.debug.title"), menu = {
		{
			title = i18n_safe("menu.debug.log_level"),
			menu = level_items,
		},
		{
			title = i18n_safe("menu.debug.open_logs"),
			fn = function()
				if ctx.on_open_logs then ctx.on_open_logs() end
			end,
		},
		{
			title = i18n_safe("menu.debug.healthcheck"),
			fn = function()
				if ctx.on_healthcheck then ctx.on_healthcheck() end
			end,
		},
	}}
end


-- =========================================
-- =========================================
-- ======= 2/ i18n Safe Fallback ===========
-- =========================================
-- =========================================

--- Returns the translated string, or the KEY when the i18n module cannot be
--- loaded at all. Separated so the menu builder works before the i18n wiring is
--- done — the pcall guards a real boot-order case, not a missing translation.
---
--- It used to take a French `fallback` second argument, supplied at all 30 call
--- sites. Every one of those keys exists in en.json and the locale-parity gate
--- keeps all 21 locales in step with it, so the fallback was unreachable — and
--- had it ever been reached, it would have shown French to a user of any of the
--- other 20 languages. A raw key on screen is ugly and diagnosable; a silently
--- wrong language is neither.
--- @param key string i18n key.
--- @return string The translation, or the key itself.
function i18n_safe(key)
	local ok, i18n = pcall(require, "infra.i18n")
	if ok and i18n and type(i18n.get) == "function" then
		local val = i18n.get(key)
		if val and val ~= key then return val end
	end
	return key
end


-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Builds the full tray menu item list from the daemon's current state.
--- @param ctx table {
---   _version       string   Driver version string.
---   config         table    Hotstrings_config module.
---   layout         string   Current keyboard layout.
---   on_layout_change function Called with new layout name.
---   keylogger      table    Keylogger module.
---   llm            table|nil LLM prediction engine state.
---   dry_run        boolean  Dry-run mode flag.
---   verbose        boolean  Verbose flag.
---   on_quit        function Called when Quit is selected.
---   on_open_config function Called to open config dir.
---   on_enable_all  function (optional) Global enable.
---   on_disable_all function (optional) Global disable.
---   on_reset_defaults function (optional) Reset.
---   on_set_log_level function (optional) Log level change.
---   on_open_logs   function (optional) Open logs dir.
---   on_healthcheck function (optional) Launch healthcheck.
---   on_show_setup_wizard function (optional) Launch setup wizard.
--- }
--- @return table Array of { title, menu?, fn?, checked?, disabled? } items.
function M.build(ctx)
	local ctx = type(ctx) == "table" and ctx or {}
	local items = {}

	-- Header (non-interactive).
	items[#items + 1] = _build_header(ctx)

	-- ── Feature sections (mirroring macOS order) ──
	items[#items + 1] = { title = "-" }

	items[#items + 1] = _build_layouts(ctx)
	items[#items + 1] = _build_hotstrings(ctx)
	items[#items + 1] = _build_llm(ctx)
	items[#items + 1] = _build_metrics(ctx)
	items[#items + 1] = _build_shortcuts(ctx)
	items[#items + 1] = _build_kanata(ctx)
	items[#items + 1] = _build_gestures(ctx)
	items[#items + 1] = _build_apps(ctx)
	items[#items + 1] = _build_updates(ctx)

	-- ── Separator before system-level actions ──
	items[#items + 1] = { title = "-" }

	items[#items + 1] = _build_global_actions(ctx)
	items[#items + 1] = _build_language(ctx)
	items[#items + 1] = _build_config_folder(ctx)
	items[#items + 1] = _build_setup_wizard(ctx)
	items[#items + 1] = _build_about(ctx)
	items[#items + 1] = _build_reload(ctx)

	items[#items + 1] = { title = "-" }
	items[#items + 1] = _build_debug(ctx)

	items[#items + 1] = { title = "-" }
	items[#items + 1] = _build_quit(ctx)

	return items
end

return M
