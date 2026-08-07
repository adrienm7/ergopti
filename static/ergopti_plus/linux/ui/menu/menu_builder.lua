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
local MagicKey = require("modules.hotstrings.magic_key")
local PreviewSettings = require("modules.hotstrings.preview_settings")
local RepeatKey = require("modules.hotstrings.repeat_key")
local LOG = "ui.menu.menu_builder"

-- Delays are stored in seconds and typed in milliseconds: seconds is what the
-- cascade and the TOMLs speak, milliseconds is what a person means by "wait a
-- bit longer". The conversion happens only at this boundary.
local MS_PER_SEC = 1000

-- The categories whose delay the other two drivers put directly in the delays
-- submenu rather than only in the settings window. They are the two a user
-- actually retunes — the magic key because it fires on a single character, and
-- autocorrection because it rewrites what was already typed — so both are one
-- click away here, exactly as on Windows and macOS.
local QUICK_DELAY_CATEGORIES = {
	{ category = "magickey",       label = "menu.hotstrings.delay_magic_key" },
	{ category = "autocorrection", label = "menu.hotstrings.delay_autocorrection" },
}

-- The category id of the user's own hotstrings — the stem of personal.toml, and
-- the same name the editor bridge writes under. Named here so the default-section
-- picker reads the sections of that pack rather than guessing at a spelling.
local PERSONAL_CATEGORY = "personal"

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

--- Asks the user for a line of text.
---
--- Declared here, above every closure that calls it: a `local` declared after a
--- closure that uses it is captured as a nil GLOBAL, and the call fails at click
--- time rather than at load time — which is the shape of three bugs already fixed
--- in this driver.
--- @param title string Window title.
--- @param prompt string The question.
--- @param initial string|nil Pre-filled value.
--- @return string|nil The entered text, or nil when the dialog was cancelled.
local function prompt_text(title, prompt, initial)
	local command = "zenity --entry --title=" .. shell_quote(title)
		.. " --text=" .. shell_quote(prompt)
		.. " --entry-text=" .. shell_quote(initial or "") .. " 2>/dev/null"
	local pipe = io.popen(command, "r")
	if not pipe then
		Logger.error(LOG, "Zenity is unavailable: cannot prompt for '%s'.", tostring(title))
		return nil
	end
	local value = pipe:read("*a") or ""
	-- A non-zero exit is Cancel or the window being closed. Distinguished from an
	-- empty entry, which exits zero: the first must change nothing, the second is
	-- a value the caller gets to refuse with its own message.
	local ok = pipe:close()
	if not ok then return nil end
	return (value:gsub("[\r\n]+$", ""))
end

--- Shows a message the user must acknowledge.
--- @param message string Already-localised text.
local function show_error(message)
	local command = "zenity --error --text=" .. shell_quote(message) .. " 2>/dev/null"
	if not os.execute(command) then
		-- Zenity absent: the refusal still has to reach someone, and a silent
		-- rejection reads as a menu row that does nothing when clicked.
		Logger.error(LOG, "%s", tostring(message))
	end
end

--- Asks a yes/no question.
---
--- Returns nil rather than false when the dialog could not be shown at all, so a
--- caller can tell "the user said no" from "there was nobody to ask" — the second
--- must not be recorded as a choice.
--- @param title string Already-translated.
--- @param text string Already-translated.
--- @param ok_label string Already-translated.
--- @param cancel_label string Already-translated.
--- @return boolean|nil
local function ask_yes_no(title, text, ok_label, cancel_label)
	local command = "zenity --question --title=" .. shell_quote(title)
		.. " --text=" .. shell_quote(text)
		.. " --ok-label=" .. shell_quote(ok_label)
		.. " --cancel-label=" .. shell_quote(cancel_label)
		.. " 2>/dev/null"
	-- os.execute returns a number on LuaJIT (5.1) and true on 5.2+.
	--- @param status any
	--- @return boolean
	local function succeeded(status)
		return status == true or status == 0
	end

	-- Probed rather than assumed, because the exit code alone cannot distinguish
	-- "the user pressed Cancel" from "no such binary" — both are non-zero, and
	-- treating the second as a No would silently record a choice nobody made.
	if not succeeded(os.execute("command -v zenity >/dev/null 2>&1")) then
		Logger.error(LOG, "Zenity is unavailable: cannot ask '%s'.", tostring(title))
		return nil
	end
	-- zenity exits 0 for the OK button and 1 for cancel.
	return succeeded(os.execute(command))
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
		-- A pack whose [_meta] description is a plain string, not a locale table —
		-- which is what the editor writes for personal.toml — used to fall straight
		-- through to the file stem, so the user's own hotstrings appeared as
		-- "personal (12)" while the other two drivers show "Hotstrings personnels".
		-- The category.* keys exist in all 21 locales for exactly this.
		if type(description) ~= "table" then
			local translated = i18n_safe("category." .. id)
			if translated ~= "category." .. id then return translated end
			return id
		end
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

	--- How many hotstrings a category is firing right now.
	---
	--- Asked of the config module, which owns the gate and section state; the
	--- fallback is only for a harness that supplies a partial config table, and it
	--- is the honest one — the total the file holds, which is what this row showed
	--- unconditionally before.
	--- @param id string
	--- @param category table|nil
	--- @return integer
	local function active_count(id, category)
		if type(config.active_count) == "function" then return config.active_count(id) end
		return (category and category.count) or 0
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
			label = i18n_safe(on and "menu.hotstrings.category_on" or "menu.hotstrings.category_off"),
			action    = function()
				if config.toggle_group then config.toggle_group(id) end
			end,
		}

		if category and category.path then
			sub[#sub + 1] = {
				label = i18n_safe("menu.hotstrings.open_file"),
				action    = function()
					if type(ctx.on_open_file) == "function" then ctx.on_open_file(category.path) end
				end,
			}
		end

		local sections = category and category.sections_order or {}
		if #sections > 0 then
			sub[#sub + 1] = { separator = true }
			-- enable_all / disable_all, the keys both other drivers use for these two
			-- rows. Linux said "Tout cocher / Tout décocher" where macOS and Windows
			-- say "Tout activer / Tout désactiver", in all 21 languages, for the same
			-- pair of controls.
			--
			-- No longer greyed while the category is off, either. Enabling now lifts
			-- the gate (config.set_all_sections does it), so this is one click from a
			-- switched-off category to a fully-on one — which is what the other two
			-- do. Greying it forced the user to find a second control first.
			sub[#sub + 1] = {
				label = i18n_safe("menu.hotstrings.enable_all"),
				action = function()
					if config.set_all_sections then config.set_all_sections(id, true) end
				end,
			}
			sub[#sub + 1] = {
				label = i18n_safe("menu.hotstrings.disable_all"),
				disabled = not on,
				action = function()
					if config.set_all_sections then config.set_all_sections(id, false) end
				end,
			}
			sub[#sub + 1] = { separator = true }

			for _, name in ipairs(sections) do
				local section = (category.sections or {})[name]
				-- CHECKED, not ENABLED. The two are different questions and answering
				-- both with the effective state made a switched-off category untick
				-- every section it holds — so the information "here is what comes back
				-- when you switch it on" disappeared, and it looked as though the
				-- per-section choices had been reset. They never were; only the screen
				-- said so.
				local section_checked = config.is_section_checked
					and config.is_section_checked(id, name)
					or (config.is_section_enabled and config.is_section_enabled(id, name))
				sub[#sub + 1] = {
					-- The count is the point of the row: a section with three entries
					-- and one with nine hundred are the same line without it.
					label    = string.format("%s (%d)", name, section and section.count or 0),
					checked  = section_checked and true or false,
					-- Greyed rather than hidden while the category is off: a row that
					-- disappears reads as a bug, and the user still needs to see what
					-- they will get back when they switch the category on.
					disabled = not on,
					action = function()
						if config.toggle_section then config.toggle_section(id, name) end
					end,
				}
			end
		end

		return {
			-- The ACTIVE count, not the file's total. A user reads this figure as
			-- "what is firing right now" and checks a disable by watching it fall;
			-- it never moved, so a fully disabled Autocorrection went on advertising
			-- every entry it would have had.
			label   = string.format("%s (%d)", category_label(id, category), active_count(id, category)),
			checked = on and true or false,
			items    = sub,
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
				label = i18n_safe("menu.hotstrings.no_group_loaded"), disabled = true,
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

	--- Flips everything on or off, in one write.
	---
	--- This looped `toggle_group` over each category until 2026-08-05, which was
	--- wrong twice. It never touched the SECTION keys, so a user who had unticked
	--- sections and then clicked "Tout activer" did not get them back and had to
	--- walk into every category by hand — the row silently did less than its label
	--- promised. And each `toggle_group` ends in a full `load_all()`, so one click
	--- re-parsed the whole catalogue — magickey.toml alone is 305 KB — once per
	--- category, inside a menu callback, with the tray rebuilt each time.
	---
	--- `enable_all` clears the whole `_disabled_groups` set, and that set holds the
	--- "category.section" keys in the same namespace as the bare category ids —
	--- which is exactly what makes it the correct answer for both halves.
	--- @param on boolean
	--- @return function
	local function set_all(on)
		return function()
			if on then
				if config.enable_all then config.enable_all() end
			else
				if config.disable_all then config.disable_all() end
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end
	end

	--- Renders a delay for a menu label: "750 ms", or the infinity sign for 0.
	---
	--- Zero does not mean "fire instantly" — it means the trigger never expires,
	--- so the category stays armed however long the user pauses. Printing "0 ms"
	--- would read as the exact opposite of what it does.
	--- @param seconds number
	--- @return string
	local function delay_display(seconds)
		local ms = math.floor(seconds * MS_PER_SEC + 0.5)
		if ms == 0 then return i18n_safe("menu.hotstrings.infinite") end
		return ms .. " ms"
	end

	--- Asks for a delay in milliseconds and returns it in seconds.
	--- @param title string Already-translated dialog title.
	--- @param current_sec number
	--- @return number|nil Seconds, or nil when cancelled or refused.
	local function prompt_delay(title, current_sec)
		local raw = prompt_text(
			title,
			i18n_safe("menu.hotstrings.delay_prompt"),
			tostring(math.floor(current_sec * MS_PER_SEC + 0.5)))
		if raw == nil then return nil end

		local value = tonumber((raw:gsub("%s", "")))
		-- Refused rather than clamped: a negative or fractional millisecond is a
		-- typo, and silently rounding it would store a number the user never chose
		-- and cannot see is different from what they typed.
		if not value or value < 0 or value ~= math.floor(value) then
			show_error(i18n_safe("menu.hotstrings.delay_invalid_body"))
			return nil
		end
		return value / MS_PER_SEC
	end

	--- The row for the global default delay — the one every category inherits
	--- when neither it nor its sections declare one.
	--- @return table
	local function global_delay_row()
		local current = config.get_global_delay and config.get_global_delay() or nil
		if type(current) ~= "number" then
			Logger.error(LOG, "hotstrings_config exposes no global delay — the row cannot show a value.")
			return {
				title    = i18n_safe("menu.hotstrings.tooltip_default") .. " : " .. i18n_safe("menu.hotstrings.missing_value"),
				disabled = true,
				fn       = function() end,
			}
		end

		local overridden = config.has_global_delay_override and config.has_global_delay_override() or false
		local title = i18n_safe("menu.hotstrings.tooltip_default")
		return {
			-- menu.settings.default_indicator carries its own leading space.
			title = title .. " : " .. delay_display(current)
				.. (overridden and "" or i18n_safe("menu.settings.default_indicator")),
			fn = function()
				local chosen = prompt_delay(title, current)
				if chosen == nil then return end
				if config.set_global_delay then config.set_global_delay(chosen) end
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			end,
		}
	end

	--- The row for one category's default delay.
	---
	--- Reads the EFFECTIVE value through resolve() so the number matches what the
	--- settings window shows and what the engine actually applies, and writes
	--- through set_override() so both UIs share one store.
	--- @param category string
	--- @param label_key string
	--- @return table
	local function category_delay_row(category, label_key)
		local title = i18n_safe(label_key)
		local ok, resolved = pcall(config.resolve, category, nil)
		local current = ok and type(resolved) == "table" and tonumber(resolved.delay) or nil
		if type(current) ~= "number" then
			Logger.error(LOG, "No resolvable delay for category '%s' — its row shows no value.", tostring(category))
			return {
				title    = title .. " : " .. i18n_safe("menu.hotstrings.missing_value"),
				disabled = true,
				fn       = function() end,
			}
		end

		local overridden = resolved.has_override == true
		return {
			title = title .. " : " .. delay_display(current)
				.. (overridden and "" or i18n_safe("menu.settings.default_indicator")),
			fn = function()
				local chosen = prompt_delay(title, current)
				if chosen == nil then return end
				if config.set_override then config.set_override(category, nil, "delay", chosen) end
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			end,
		}
	end

	local ok_term, Terminators = pcall(require, "keymap.terminators")
	if not ok_term then Terminators = nil end

	local params_handlers = {
		["word_expanders"] = function()
			if not Terminators then
				Logger.error(LOG, "keymap.terminators unavailable — the word-delimiter submenu is skipped.")
				return {}
			end

			--- The CATALOGUE delimiter keys — the user's own are excluded.
			---
			--- This used to include custom ones, and its comment said so as if it
			--- were a decision. Both reference drivers skip them deliberately: a
			--- delimiter the user added by hand must not be wiped by a bulk action
			--- aimed at the shipped set.
			--- @return table Array of key strings.
			local function all_keys()
				local keys = {}
				for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
					if def.key and not def.custom then keys[#keys + 1] = def.key end
				end
				return keys
			end

			--- Sets every catalogue delimiter at once.
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
			sub[#sub + 1] = { label = i18n_safe("menu.hotstrings.check_all"),   action = set_all(true) }
			sub[#sub + 1] = { label = i18n_safe("menu.hotstrings.uncheck_all"), action = set_all(false) }
			-- The way back. Both other drivers put it beside the two bulk rows, and
			-- without it a user who clicked "Tout décocher" had no route to the
			-- shipped set short of editing storage by hand — 15 of the 25 catalogue
			-- delimiters ship disabled, so "check all" is not that route either.
			sub[#sub + 1] = {
				label = i18n_safe("menu.global.reset_defaults"),
				action    = function()
					for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
						if def.key and not def.custom then
							Terminators.set_terminator_enabled(def.key, def.default_enabled ~= false)
						end
					end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			}
			sub[#sub + 1] = { separator = true }

			for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
				if def.type == "separator" then
					sub[#sub + 1] = { separator = true }
				elseif def.key then
					local key = def.key
					-- The live magic key, not the ★ the catalogue was written with.
					-- The label is shipped as a literal star; a user who changed the
					-- key saw the delimiter list still naming a character that is no
					-- longer their trigger, in every language.
					local label = (def.label or key):gsub("★", MagicKey.get())
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
						label   = label,
						checked = Terminators.is_terminator_enabled(key) and true or false,
						action      = function()
							Terminators.set_terminator_enabled(key, not Terminators.is_terminator_enabled(key))
							if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						end,
					}
					if def.custom then
						sub[#sub + 1] = {
							label = "    " .. i18n_safe("menu.hotstrings.delete_delimiter"),
							action    = function()
								Terminators.remove_custom_terminator(key)
								if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
							end,
						}
					end
				end
			end

			sub[#sub + 1] = { separator = true }
			sub[#sub + 1] = {
				label = i18n_safe("menu.hotstrings.add_delimiter"),
				-- Asked here, natively, rather than delegated to the settings window.
				-- The delegation was justified in the daemon by "this driver's only
				-- text field is the settings window" — but the window it opened did
				-- not exist, so no custom delimiter could ever be created and the
				-- "delete" sub-row below was unreachable by construction. The text
				-- field it claimed not to have is prompt_text, in this same file,
				-- and the magic-key row two handlers down already uses it.
				action = function()
					local char = prompt_text(
						i18n_safe("dialog.hotstrings.new_delimiter_title"),
						i18n_safe("dialog.hotstrings.new_delimiter_prompt"),
						"")
					if char == nil then return end

					-- Codepoints, not bytes: "…" is three bytes and one character, so
					-- a byte-length check would refuse most of what a user would pick.
					local codepoints = 0
					for _ in char:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
						codepoints = codepoints + 1
					end
					if codepoints ~= 1 then
						show_error(i18n_safe("dialog.magic_key.error_length"))
						return
					end

					local consume = ask_yes_no(
						i18n_safe("dialog.hotstrings.consume_title"),
						i18n_safe("dialog.hotstrings.consume_body"),
						i18n_safe("dialog.hotstrings.consume_yes"),
						i18n_safe("dialog.hotstrings.consume_no"))
					-- nil is "nobody could be asked", which must not be stored as a No.
					if consume == nil then return end

					Terminators.add_custom_terminator("custom_" .. char, char, char, consume)
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			}

			return { { label = i18n_safe("menu.hotstrings.word_expanders"), items = sub } }
		end,
		["magic_key_config"] = function(items)
			-- The row the manifest restricted to Windows and macOS until 2026-08-04,
			-- with a translated reason saying Linux had no way to change the key. That
			-- was true and is the reason it is written here rather than the reason to
			-- keep the row hidden: a declared gap closes by writing the feature.
			local current = MagicKey.get()
			items[#items + 1] = {
				title = i18n_safe("menu.hotstrings.magic_key") .. " : " .. current,
				fn    = function()
					local chosen = prompt_text(
						i18n_safe("dialog.magic_key.title"),
						i18n_safe("dialog.magic_key.prompt"),
						current)
					-- nil is a cancelled dialog, which must change nothing. An empty
					-- string is a user who cleared the box and pressed OK, and that is
					-- refused by validate() with its own message rather than silently
					-- treated as a cancel.
					if chosen == nil then return end
					local ok, reason = MagicKey.set(chosen)
					if not ok then
						show_error(i18n_safe(reason or "dialog.magic_key.error_empty"))
						return
					end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			}
			if MagicKey.is_customised() then
				items[#items + 1] = {
					title = "    " .. i18n_safe("menu.hotstrings.magic_key_reset"),
					fn    = function()
						MagicKey.reset()
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
			end
		end,
		["delays_colors"] = function(items)
			-- A submenu, not the single row this used to be. The old row opened the
			-- settings window and stopped there, justified by a comment saying "this
			-- driver has no per-category delays to prompt for" — which was false when
			-- it was written: hotstrings_config.resolve() walks the same five-rung
			-- cascade as macOS, set_override() persists to the same file, and
			-- ergopti_hotstrings.lua consumes the resolved delay on every keystroke.
			-- The values were all there; only the prompts were missing.
			local sub = {}

			sub[#sub + 1] = {
				title = i18n_safe("menu.hotstrings.config_item"),
				fn    = function()
					if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
						Logger.error(LOG, "No webview manager in the menu context — cannot open the hotstrings settings.")
						return
					end
					-- The directory name under _shared/ui/. "hotstrings_config" has a
					-- bridge but no page, so this row opened a window reading
					-- "Error: app 'hotstrings_config' not found" — the settings window
					-- this whole submenu points at had never once opened on Linux.
					ctx.webview.show("hotstrings_config_window")
				end,
			}
			sub[#sub + 1] = { title = "-" }
			sub[#sub + 1] = global_delay_row()

			for _, entry in ipairs(QUICK_DELAY_CATEGORIES) do
				sub[#sub + 1] = category_delay_row(entry.category, entry.label)
			end

			items[#items + 1] = { title = i18n_safe("menu.hotstrings.delays_colors"), menu = sub }
		end,
		["repeat_key"] = function(items)
			local enabled = RepeatKey.is_enabled()
			items[#items + 1] = {
				title   = i18n_safe("menu.hotstrings.repeat_key_toggle"),
				checked = enabled,
				fn      = function()
					RepeatKey.toggle()
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			}
		end,
		["preview_bubbles"] = function(items)
			-- The four toggles the manifest has declared for this driver all along
			-- and that nothing could reach: ui/tooltip/preview.lua honoured them on
			-- the hot path while its set_enabled() had no caller, so they were fixed
			-- at their load-time value. PreviewSettings owns them now; this menu is
			-- the way in.
			local sub = {}
			for index, toggle in ipairs(PreviewSettings.toggles()) do
				-- "colored" is a different kind of switch from the three above it —
				-- they choose WHICH previews appear, it chooses how they look — so it
				-- is separated, the same way macOS separates it.
				if index == #PreviewSettings.toggles() then sub[#sub + 1] = { title = "-" } end
				local name = toggle.name
				sub[#sub + 1] = {
					title   = i18n_safe(toggle.label),
					checked = PreviewSettings.get(name),
					fn      = function()
						PreviewSettings.toggle(name)
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
			end
			items[#items + 1] = { title = i18n_safe("menu.hotstrings.preview_bubbles"), menu = sub }
		end,
	}

	local providers = {
		["hotstring_categories_standard"] = function()
			local rows = {}
			append_class(rows, "standard")
			return rows
		end,
		["hotstring_categories_dynamic"] = function()
			local rows = {}
			-- Its own handler, not append_class. This driver's group list comes from
			-- TOML file stems and there is no dynamic-hotstrings TOML — the rules are
			-- registered in code — so append_class matched nothing and the row
			-- resolved to a greyed "(aucun groupe chargé)" while the engine was
			-- running and expanding dates and @-tags. A user could not see the
			-- category, count it, or switch it off.
			local dyn = ctx.dyn_hotstrings
			if type(dyn) ~= "table" or type(dyn.is_enabled) ~= "function" then
				Logger.error(LOG, "No dynamic-hotstrings manager in the menu context — its category is not shown.")
				return rows
			end

			local on = dyn.is_enabled()
			-- active_count, not get_rules_count: the latter counts the RULES the
			-- dynamic engine registered and knows nothing about the prefix
			-- expansions, which are mappings held by the ordinary matcher. The
			-- category would have advertised 3 while offering 13, and would not have
			-- moved when a family was switched off.
			local count = type(dyn.active_count) == "function" and dyn.active_count() or 0

			local sub = {
				{
					label = i18n_safe(on and "menu.hotstrings.category_on" or "menu.hotstrings.category_off"),
					action    = function()
						if type(dyn.set_enabled) == "function" then dyn.set_enabled(not on) end
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				},
			}

			-- One row per rule family, as Windows and macOS offer. The plan recorded
			-- this as blocked by the shared engine "registering the date rules as a
			-- batch with no identifier". That was wrong: add_rule has always carried
			-- a section, and match_buffer has always taken a predicate to filter on
			-- it. This driver simply passed nil for it.
			local families = type(dyn.rule_families) == "function" and dyn.rule_families() or {}
			if #families > 0 then
				-- The two bulk rows the other drivers put at the top of this submenu.
				-- They act on the families only; the category gate above is separate,
				-- and "tout désactiver" leaving the category on is the point — it is
				-- what lets the user switch families back on one at a time.
				sub[#sub + 1] = { separator = true }
				for _, bulk in ipairs({ { key = "enable_all", on = true }, { key = "disable_all", on = false } }) do
					sub[#sub + 1] = {
						label    = i18n_safe("menu.hotstrings." .. bulk.key),
						disabled = not on,
						action       = function()
							for _, family in ipairs(families) do
								if family.section then dyn.set_rule_enabled(family.section, bulk.on) end
							end
							if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						end,
					}
				end
				sub[#sub + 1] = { separator = true }

				for _, family in ipairs(families) do
					if family.separator then
						sub[#sub + 1] = { separator = true }
					else
						local section, enabled = family.section, family.enabled
						-- The count, on the families that have one. A prefix family with
						-- 0 behind it is a switch that can do nothing until the user
						-- fills in that field of personal_info.toml, and the count is
						-- the only thing on the row that says so.
						local family_label = family.count
							and string.format("%s (%d)", family.label, family.count)
							or family.label
						sub[#sub + 1] = {
							-- Resolved by the manager, which owns both the locale key
							-- and the engine that answers what "{date}" is today.
							label    = family_label,
							checked  = enabled,
							-- Greyed while the category itself is off, like a section
							-- row: the tick still says what comes back when it is
							-- switched on.
							disabled = not on,
							action       = function()
								dyn.set_rule_enabled(section, not enabled)
								-- A prefix family is matched by the ORDINARY engine, which
								-- knows nothing about dynamic families — so its switch has
								-- to add or remove mappings rather than filter them, and
								-- that means a reload. The date families need none of this;
								-- their guard is read at match time.
								if family.count and config and type(config.reload) == "function" then
									config.reload()
								end
								if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
							end,
						}
					end
				end
			end

			rows[#rows + 1] = {
				-- category.dynamic_hotstrings, which is the key the CATEGORY carries in
				-- all 21 locales. menu.hotstrings.dynamic is the manifest's SECTION
				-- description key and has no translation of its own, so it would have
				-- rendered as the raw string.
				label   = string.format("%s (%d)", i18n_safe("category.dynamic_hotstrings"), count),
				checked = on,
				items    = sub,
			}
			return rows
		end,
		["hotstring_categories_ergopti"]  = function()
			local rows = {}
			append_class(rows, "ergopti")
			return rows
		end,
		["hotstring_personal"] = function()
			local rows = {}
			-- The editor comes first, and until 2026-08-05 it was not here at all:
			-- `_shared/ui/hotstring_editor/` shipped with this driver, its bridge was
			-- complete and tested, and no code path anywhere opened it. A Linux user
			-- could not create, edit or delete a single personal hotstring — the row
			-- expanded to the same generic category submenu every pack gets.
			rows[#rows + 1] = {
				label = i18n_safe("menu.hotstrings.open_editor"),
				action    = function()
					if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
						Logger.error(LOG, "No webview manager in the menu context — cannot open the hotstring editor.")
						return
					end
					ctx.webview.show("hotstring_editor")
				end,
			}

			local ok_editor, Editor = pcall(require, "ui.hotstring_editor.bridge")
			if ok_editor and type(Editor.get_pref) == "function" then
				-- Which section a new entry lands in. Built from the personal pack's
				-- own section order so the list is what the user actually has, and
				-- "none" is offered because leaving it unset is a real choice.
				local current = Editor.get_pref("default_section")
				local personal = type(config.get_category) == "function"
					and config.get_category(PERSONAL_CATEGORY) or nil
				local sub = {}
				sub[#sub + 1] = {
					label   = i18n_safe("common.none"),
					checked = (current == nil or current == ""),
					action      = function()
						Editor.set_pref("default_section", "")
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
				for _, name in ipairs(personal and personal.sections_order or {}) do
					sub[#sub + 1] = {
						label   = name,
						checked = (current == name),
						action      = function()
							Editor.set_pref("default_section", name)
							if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						end,
					}
				end
				rows[#rows + 1] = {
					label = i18n_safe("menu.hotstrings.default_category_prefix")
						.. ((current ~= nil and current ~= "") and current or i18n_safe("common.none")),
					items  = sub,
				}

				local close_on_add = Editor.get_pref("auto_close") == true
				rows[#rows + 1] = {
					label   = i18n_safe("menu.hotstrings.close_on_add"),
					checked = close_on_add,
					action      = function()
						Editor.set_pref("auto_close", not close_on_add)
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
			else
				Logger.error(LOG, "The hotstring editor bridge is unavailable — its preferences cannot be shown.")
			end

			rows[#rows + 1] = { separator = true }

			local added = 0
			for _, name in ipairs(groups) do
				-- Extension packs are unclassified too, but they are not personal
				-- files: they belong to the extension that shipped them and get their
				-- own section below. Without this test they appeared here, under a
				-- heading that told the user they had written them.
				if not classified[name] and not Extensions.parse_category_key(name) then
					rows[#rows + 1] = group_row(name)
					added = added + 1
				end
			end
			if added == 0 then
				rows[#rows + 1] = {
					label = i18n_safe("menu.hotstrings.no_group_loaded"), action = function() end, disabled = true,
				}
			end
			return rows
		end,
		["hotstring_extensions"] = function()
			local rows = {}
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
				rows[#rows + 1] = {
					label    = i18n_safe("menu.extensions.none_installed"),
					action       = function() end,
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
					label = i18n_safe("menu.hotstrings.check_all"),
					action    = function()
						for _, name in ipairs(packs) do
							if config.is_group_enabled and not config.is_group_enabled(name)
								and config.toggle_group then config.toggle_group(name) end
						end
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
				sub[#sub + 1] = {
					label = i18n_safe("menu.hotstrings.uncheck_all"),
					action    = function()
						for _, name in ipairs(packs) do
							if config.is_group_enabled and config.is_group_enabled(name)
								and config.toggle_group then config.toggle_group(name) end
						end
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
				sub[#sub + 1] = { separator = true }

				for _, name in ipairs(packs) do
					sub[#sub + 1] = group_row(name)
				end

				rows[#rows + 1] = { label = extension_label(extension_id), items = sub }
			end
			return rows
		end,
	}

	-- word_expanders left params_handlers: its manifest row is `type = "list"`
	-- now, so the shared renderer materialises every row of the submenu from the
	-- data the provider returns rather than this driver assembling the menu.
	local params_providers = {
		["word_expanders"] = params_handlers["word_expanders"],
	}
	params_handlers["word_expanders"] = nil

	local group_builders = {
		["hotstrings_params"] = function(c)
			return ManifestMenu.build("hotstrings_params_group", "HotstringsParams",
				params_handlers, nil, c, params_providers)
		end,
	}

	-- The two bulk rows are `type = "command"` now: one declaration each, built
	-- by the shared renderer, so this driver supplies only the behaviour.
	local hs_ctx = {}
	for key, value in pairs(ctx) do hs_ctx[key] = value end
	hs_ctx.commands = {
		["hotstrings_enable_all"]  = set_all(true),
		["hotstrings_disable_all"] = set_all(false),
	}

	return ManifestMenu.build("hotstrings_menu", "Hotstrings", nil, group_builders, hs_ctx, providers)
end

--- Builds the hotstrings submenu: the manifest's rows, then this driver's own.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_hotstrings(ctx)
	local config = ctx.config

	if type(config) ~= "table" then
		return { title = i18n_safe("menu.hotstrings.title"), menu = {
			{ title = i18n_safe("menu.hotstrings.unavailable"), fn = function() end, disabled = true },
		}}
	end

	local items = _manifest_hotstring_rows(ctx, config)

	-- Row 1 of [[menu.hotstrings_menu]] is a `toggle`, and the shared renderer
	-- skips those by contract ("Category toggles rendered by caller") — so this
	-- caller has to build it, and did not. There was no single switch that turned
	-- hotstrings off on this driver and no indication of whether they were on.
	--
	-- Inside the submenu rather than on the parent, which is where Windows puts
	-- it: platform/tray/appindicator.lua binds item.fn only when the row has NO
	-- submenu (`if item.menu … elseif item.fn …`), so macOS's clickable parent is
	-- not representable on this backend. Prepended, because it is the manifest's
	-- first row and belongs at that position.
	local all_on = false
	if type(config.get_groups) == "function" and type(config.is_group_enabled) == "function" then
		local groups = config.get_groups() or {}
		all_on = #groups > 0
		for _, name in ipairs(groups) do
			if not config.is_group_enabled(name) then
				all_on = false
				break
			end
		end
	end
	table.insert(items, 1, {
		title = i18n_safe(all_on and "menu.hotstrings.on" or "menu.hotstrings.off"),
		fn    = function()
			-- The batched writers, not a loop of toggle_group: each toggle_group
			-- ends in a full load_all(), which re-parses every pack — magickey.toml
			-- alone is 305 KB — once per category, inside a menu callback.
			if all_on then
				if config.disable_all then config.disable_all() end
			else
				if config.enable_all then config.enable_all() end
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
	})

	-- Not a manifest row on any driver: reloading the catalogue from disk is this
	-- driver's own affordance, because it is the only one whose hotstrings can
	-- change under it without a restart.
	items[#items + 1] = { title = "-" }
	items[#items + 1] = {
		-- The generic reload label, not a hotstrings-specific one: this row sat on
		-- a hardcoded French string, which is a label in one of the twenty-one
		-- languages this menu is drawn in. Inside the Hotstrings submenu the
		-- context already says what is being reloaded.
		title = i18n_safe("menu.global.reload"),
		fn = function()
			if config.reload then config.reload() end
		end,
	}

	-- The grand total, which macOS and Windows both put on this entry and Linux
	-- did not. On a driver that re-scans its catalogue from disk it is the fastest
	-- confirmation that a reload found the packs at all.
	--
	-- Summed from the ACTIVE counts, not the files' totals: a grand total computed
	-- the naive way would contradict the per-category numbers directly beneath it
	-- the moment anything was switched off.
	local grand_total = 0
	if type(config.get_groups) == "function" and type(config.active_count) == "function" then
		for _, name in ipairs(config.get_groups() or {}) do
			grand_total = grand_total + (config.active_count(name) or 0)
		end
	end

	local title = i18n_safe("menu.hotstrings.title")
	if grand_total > 0 then title = string.format("%s (%d)", title, grand_total) end

	return { title = title, menu = items }
end

--- Builds the AI / LLM submenu.
local function _build_llm(ctx)
	local llm = ctx.llm
	if not llm then
		return { title = i18n_safe("menu.llm.title"), menu = {
			{ title = i18n_safe("menu.llm.unavailable"), fn = function() end, disabled = true },
			{ title = i18n_safe("menu.llm.ollama_start_hint"), fn = function() end, disabled = true },
		}}
	end

	local items = {}
	local enabled = llm.is_enabled and llm.is_enabled() or false

	-- The master toggle stays with the caller: the renderer skips `toggle` rows
	-- by contract, because whether a category is on is driver state rather than
	-- manifest data. Everything below it is the manifest's, in its order.
	items[#items + 1] = {
		title = i18n_safe("menu.common.enabled") .. (enabled and " ✓" or ""),
		fn = function()
			if llm.toggle then llm.toggle() end
		end,
	}

	local providers = {}

	-- The models this machine actually has. A `list`, because the rows are
	-- whatever Ollama reports and no static entry can enumerate them.
	providers["llm_models"] = function()
		if type(llm.get_models) ~= "function" then return {} end
		local models = llm.get_models()
		if type(models) ~= "table" then return {} end
		local current = llm.get_current_model and llm.get_current_model() or nil
		local rows = {}
		for _, model in ipairs(models) do
			rows[#rows + 1] = {
				label = model,
				-- `checked`, not a "✓" glued to the label: the tray draws its own
				-- mark, and the glued form puts one platform's convention inside a
				-- string twenty other languages also read.
				checked = model == current,
				action = function()
					if llm.set_model then llm.set_model(model) end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			}
		end
		return rows
	end

	-- Temperature and context length. The manifest has declared both as features
	-- for as long as it has existed and this driver read them from the canonical
	-- defaults with no way to change either — constants wearing the shape of
	-- settings.
	providers["llm_generation"] = function()
		local ok_settings, Settings = pcall(require, "modules.llm.settings")
		if not ok_settings then
			Logger.error(LOG, "LLM settings unavailable — the generation rows cannot be built.")
			return {}
		end
		local rows = {}
		for _, setting in ipairs({
			{ name = "temperature", key = "menu.llm.generation.temperature" },
			{ name = "context_length", key = "menu.llm.generation.context_length" },
		}) do
			local current = Settings.get(setting.name)
			local choices = {}
			for _, value in ipairs(Settings.presets(setting.name)) do
				choices[#choices + 1] = {
					label = tostring(value),
					checked = current == value,
					action = function()
						Settings.set(setting.name, value)
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}
			end
			-- Free entry beside the presets, so this driver can express any value
			-- macOS's numeric dialog can. Closing the gap the other way — taking
			-- the dialog off macOS and leaving only presets — would have removed a
			-- capability, which is convergence downwards.
			local bounds = Settings.bounds(setting.name)
			if bounds then
				choices[#choices + 1] = { separator = true }
				choices[#choices + 1] = {
					label = i18n_safe("menu.llm.generation.custom_value"),
					action = function()
						local ok_prompt, Prompt = pcall(require, "ui.numeric_prompt.bridge")
						if not ok_prompt then
							Logger.error(LOG, "No numeric prompt — '%s' can only take a preset.", setting.name)
							return
						end
						Prompt.ask({
							title = i18n_safe(setting.key),
							hint = string.format("%s – %s", tostring(bounds.min), tostring(bounds.max)),
							value = Settings.get(setting.name),
							min = bounds.min,
							max = bounds.max,
							on_save = function(value)
								Settings.set(setting.name, value)
								if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
							end,
						}, ctx.webview)
					end,
				}
			end

			rows[#rows + 1] = {
				label = i18n_safe(setting.key) .. " — " .. tostring(current),
				items = choices,
			}
		end
		return rows
	end

	local rendered = ManifestMenu
		and ManifestMenu.build("llm_menu", "LLM", nil, nil, ctx, providers)
		or {}
	for _, row in ipairs(rendered) do items[#items + 1] = row end

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
		return { title = i18n_safe("menu.metrics.migration_unavailable"), fn = function() end, disabled = true }
	end
	local progress = k.get_migration_progress()
	if not progress.running then
		return { title = i18n_safe("menu.metrics.migration_idle"), fn = function() end, disabled = true }
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
		-- The manifest gates the colour row on the widget being visible: choosing
		-- how to colour something that is not on screen is a control with no
		-- subject. Without this getter the resolver logs an error and falls back to
		-- the safe answer, so the row would be permanently greyed — right by
		-- accident, and wrong the moment the widget is shown.
		metrics_suppressed     = function()
			return type(k.is_suppressed) == "function" and k.is_suppressed() or false
		end,
		wpm_widget_visible     = function()
			local ok, widget = pcall(require, "ui.wpm.widget")
			return ok and widget.is_running() or false
		end,
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

	--- The floating WPM pill, loaded lazily so a driver whose GTK surface is
	--- missing still builds its menu — the row then reports the widget as off,
	--- which is what it is.
	--- @return table|nil
	local function wpm_widget()
		local ok, widget = pcall(require, "ui.wpm.widget")
		return ok and widget or nil
	end

	local handlers = {
		wpm_widget = function(items)
			local widget = wpm_widget()
			items[#items + 1] = row("wpm_widget", i18n_safe("menu.metrics.show_wpm_widget"),
				widget ~= nil and widget.is_running(),
				function()
					if not widget then
						Logger.error(LOG, "No WPM widget module — the row cannot toggle anything.")
						return
					end
					if widget.is_running() then widget.stop() else widget.start() end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end)
		end,
		widget_colors = function(items)
			local widget = wpm_widget()
			items[#items + 1] = row("widget_colors", i18n_safe("menu.metrics.colors_by_source"),
				widget ~= nil and widget.uses_source_colors(),
				function()
					if not widget then return end
					widget.set_use_source_colors(not widget.uses_source_colors())
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end)
		end,
		show_typing = function(items)
			items[#items + 1] = row("show_typing", i18n_safe("menu.metrics.show_typing"), false,
				open_window("metrics_typing"))
		end,
		show_apps = function(items)
			items[#items + 1] = row("show_apps", i18n_safe("menu.metrics.show_apps"), false,
				open_window("metrics_apps"))
		end,
		-- The three privacy filters are gone from this table on purpose: their
		-- manifest rows are `type = "check"` now, so the SHARED renderer builds
		-- them from the declaration and this driver supplies only the behaviour,
		-- through `ctx.commands` below. Three fewer rows built here, and the tick
		-- is the tray's own check item instead of a " ✓" glued to the title.
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

	-- The declarative rows read their state and their behaviour off the context:
	-- `state_getters` answers the manifest's checked_when / disabled_when keys,
	-- `commands` answers its `command` (defaulting to the row id). Passing them
	-- on a COPY of ctx keeps the caller's table untouched — the same ctx is
	-- handed to every other submenu builder in this file.
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.state_getters = getters
	-- Bracketed keys on purpose: the bijection gate resolves "does this driver
	-- handle the row" by looking for the quoted id, and a bare key is invisible
	-- to it — which would report three declared rows as unhandled while they work.
	render_ctx.commands = {
		["filter_private"] = toggle("private_filter_enabled", k.set_private_filter_enabled),
		["filter_secure"]  = toggle("secure_filter_enabled", k.set_secure_filter_enabled),
		["filter_sysauth"] = toggle("system_auth_filter_enabled", k.set_system_auth_filter_enabled),

		-- This driver answers these five in its log rather than in a window; the
		-- other two open a metrics WINDOW for the same figures. Declared rows
		-- since 2026-08-06, so the manifest can describe a driver-specific row
		-- rather than the driver keeping it to itself.
		["metrics_session_stats"] = function()
			if type(k.get_session_stats) ~= "function" then
				Logger.error(LOG, "Keylogger exposes no get_session_stats — the row reports nothing.")
				return
			end
			local stats = k.get_session_stats()
			Logger.info(LOG, "Session: %d keystrokes, ~%d words, %ds.",
				stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
		end,
		["metrics_current_wpm"] = function()
			if type(k.get_wpm) ~= "function" then
				Logger.error(LOG, "Keylogger exposes no get_wpm — the row reports nothing.")
				return
			end
			Logger.info(LOG, "WPM: %.1f", k.get_wpm())
		end,
		["metrics_per_app_stats"] = function()
			if type(k.get_app_stats) ~= "function" then
				Logger.error(LOG, "Keylogger exposes no get_app_stats — the row reports nothing.")
				return
			end
			for app, stats in pairs(k.get_app_stats()) do
				Logger.info(LOG, "  %s: %d keystrokes", app, stats.keystrokes)
			end
		end,
		["metrics_suspend"] = function()
			if type(k.is_suppressed) ~= "function" then
				Logger.error(LOG, "Keylogger exposes no is_suppressed — the row cannot toggle anything.")
				return
			end
			if k.is_suppressed() then k.unsuppress() else k.suppress() end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		["metrics_reset_session"] = function()
			if type(k.reset_session) ~= "function" then
				Logger.error(LOG, "Keylogger exposes no reset_session — the row does nothing.")
				return
			end
			k.reset_session()
			Logger.info(LOG, "Metrics session reset.")
		end,
	}

	return ManifestMenu.build("metrics_menu", "Metrics", handlers, nil, render_ctx)
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

	-- The collection master toggle stays hand-built: this menu's manifest
	-- `toggle` row is platforms = ["hs"], so it describes macOS's row and not
	-- this driver's. The migration status is pure runtime text with no stable id.
	items[#items + 1] = { title = "-" }
	items[#items + 1] = _privacy_toggle(k, "enabled", i18n_safe("menu.metrics.collection_enabled"), k.set_enabled)
	items[#items + 1] = _migration_status(k)

	return { title = i18n_safe("menu.metrics.title"), menu = items }
end

--- Builds the shortcuts submenu.
--- One menu row per installed extension that ships `shortcuts/menu.lua`.
---
--- The file is executed in a sandbox exposing exactly what the macOS host
--- exposes — `add_item`, `t` and `ext_name` — with the standard library reachable
--- through __index so an author can use `string` and `table` without either host
--- listing them. Anything the extension collects becomes a submenu under its own
--- name.
---
--- setfenv rather than a _ENV upvalue: this driver runs LuaJIT, which is 5.1, and
--- setfenv is the 5.1 spelling. The macOS host uses the same call.
--- @return table Array of menu rows, empty when nothing is installed.
local function _extension_shortcut_rows()
	local rows = {}

	local ok_paths, Paths = pcall(require, "infra.paths")
	local ok_loader, Loader = pcall(require, "modules.hotstrings.loader")
	if not ok_paths or not ok_loader or type(Paths.extension_roots) ~= "function" then return rows end

	-- The same io functions hotstrings_config.extension_packs() injects. The
	-- scanner takes them rather than reaching for the filesystem itself, which is
	-- what lets it be shared and tested; passing nil returns an empty list, so
	-- this is not optional.
	local ok_scan, packs = pcall(Extensions.scan, Paths.extension_roots(), {
		list_dirs  = Loader.list_subdirs,
		list_files = Loader.find_toml_files,
		read_file  = Loader.read_file,
	})
	if not ok_scan or type(packs) ~= "table" then return rows end

	-- One entry per extension: the scanner already collapses an id that appears
	-- under more than one root (bundled and user-installed).
	for _, pack in ipairs(packs) do
		local id, dir = pack.id, pack.dir
		if id and dir then
			local menu_path = dir .. "/shortcuts/menu.lua"
			local chunk = loadfile(menu_path)
			if chunk then
				local collected = {}
				local sandbox = {
					add_item = function(item)
						if type(item) == "table" then collected[#collected + 1] = item end
					end,
					t        = i18n_safe,
					ext_name = pack.name or id,
				}
				setmetatable(sandbox, { __index = _G })
				sandbox._G = sandbox

				if setfenv then setfenv(chunk, sandbox) end
				local ok_run, err = pcall(chunk)
				if not ok_run then
					-- Surfaced as a row, not only logged: an extension whose menu
					-- throws would otherwise be indistinguishable from one that
					-- declares nothing, and its author would have no way to tell.
					Logger.warn(LOG, "Extension '%s' shortcuts/menu.lua failed: %s", id, tostring(err))
					rows[#rows + 1] = {
						title = (pack.name or id) .. " — " .. i18n_safe("common.error_title"),
						fn = function() end, disabled = true,
					}
				elseif #collected > 0 then
					rows[#rows + 1] = { title = pack.name or id, menu = collected }
				end
			end
		end
	end

	return rows
end

--- Builds the shortcuts submenu: this driver's own rows, then the manifest's.
---
--- Hand-rolled until 2026-08-05, which is what kept `extensions_shortcuts`
--- restricted to Windows in the manifest even after both Lua drivers had
--- implemented it: a menu that dispatches nothing by id cannot be promised a row
--- by id, and the handler-bijection ratchet says so. It dispatches now, and the
--- restriction is gone.
---
--- The rows above the manifest section are this driver's own — CapsWord, the
--- selection transforms, the wrap pairs — and no manifest entry describes them
--- yet. macOS is in the same position with `at_hash` and `layer_scroll`, and
--- prepends them the same way.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_shortcuts(ctx)
	local sc = ctx.shortcuts
	if not sc then
		return { title = i18n_safe("menu.shortcuts.title"), menu = {
			{ title = i18n_safe("menu.shortcuts.unavailable"), fn = function() end, disabled = true },
		}}
	end

	local enabled = sc.is_enabled()
	local caps_active = sc.is_caps_word_active()
	local items = {}

	-- Row 1 of [[menu.shortcuts_menu]] is a `toggle`, which the shared renderer
	-- skips by contract ("Category toggles rendered by caller") — so this caller
	-- builds it, exactly as the hotstrings submenu does.
	items[#items + 1] = {
		title = i18n_safe(enabled and "menu.shortcuts.on" or "menu.shortcuts.off"),
		fn = function()
			sc.toggle()
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
	}
	items[#items + 1] = { title = "-" }

	-- CapsWord toggle.
	items[#items + 1] = {
		title   = i18n_safe("sg_actions.caps_word"),
		checked = caps_active,
		fn = function()
			sc.toggle_caps_word()
			Logger.info(LOG, "CapsWord toggled: %s", tostring(sc.is_caps_word_active()))
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
	}

	-- Text transforms (operate on current X11 selection).
	items[#items + 1] = { title = "-" }
	for _, transform in ipairs({
		{ key = "menu.shortcuts.to_uppercase", run = sc.transform_uppercase },
		{ key = "menu.shortcuts.to_lowercase", run = sc.transform_lowercase },
		{ key = "menu.shortcuts.to_titlecase", run = sc.transform_titlecase },
	}) do
		items[#items + 1] = { title = i18n_safe(transform.key), fn = function() transform.run() end }
	end

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
		title = i18n_safe("sg_actions.paste_plain"),
		fn = function() sc.paste_plain() end,
	}

	-- Wrap symbols submenu. Ordered, because `get_wrap_pairs` returns a map and
	-- `pairs` would give the user a different order on every rebuild.
	local wrap_items = {}
	local opening = {}
	for ch, pair in pairs(sc.get_wrap_pairs()) do
		-- Only the opening character: each pair is stored under both of its ends.
		if ch == pair.left then opening[#opening + 1] = { ch = ch, pair = pair } end
	end
	table.sort(opening, function(a, b) return a.ch < b.ch end)
	for _, entry in ipairs(opening) do
		local pair = entry.pair
		-- The pair around an ellipsis, and nothing else. This used to append a
		-- second illustration, "(«texte»)", whose only content was a French word —
		-- so the row was a translated label followed by an untranslated one, and
		-- the ellipsis had already said the same thing in every language.
		wrap_items[#wrap_items + 1] = {
			label  = string.format("%s … %s", entry.ch, pair.right),
			action = function() sc.wrap_selection(pair.left, pair.right) end,
		}
	end

	local handlers = {
		-- One submenu per installed extension that ships shortcuts/menu.lua.
		--
		-- An extension author writes that file and it appears under Raccourcis on
		-- macOS and, as menu.ahk, on Windows. On Linux nothing appeared, so every
		-- action an extension declared was unreachable — and the bundled demo
		-- extension carries the file, so this reproduced out of the box.
		["extensions_shortcuts"] = function(rows)
			for _, row in ipairs(_extension_shortcut_rows()) do rows[#rows + 1] = row end
		end,
	}

	-- The manifest's `keyboard_slots` row, which this driver could not answer
	-- until it had a chord capture and somewhere to store an assignment. One
	-- submenu per modifier group, each listing every key in the shared catalogue
	-- with whatever the user has bound to it — the same shape the gesture slots
	-- use, for the same reason: the slot space is fixed and the assignment is the
	-- user's, so a static entry cannot enumerate the rows.
	local providers = {}
	providers["keyboard_slots"] = function()
		local ok_kbd, Keyboard = pcall(require, "modules.shortcuts.keyboard_shortcuts")
		local ok_gestures, Gestures = pcall(require, "modules.gestures.manager")
		if not ok_kbd or not ok_gestures then
			Logger.error(LOG, "Keyboard slots unavailable — the shortcuts submenu loses its bindings.")
			return {}
		end

		-- The action catalogue is the gestures manager's, and the labels with it.
		-- A second list here would drift from the one the gestures draw, and the
		-- user would see the same action named two ways in one menu.
		local action_names = Gestures.get_action_names and Gestures.get_action_names() or { "none" }

		local out = {}
		for _, group in ipairs(Keyboard.SLOT_GROUPS) do
			local rows = {}
			for _, slot in ipairs(Keyboard.available_slots(group.prefix)) do
				local bound = Keyboard.get_action(slot)
				local choices = {}
				for _, option in ipairs(action_names) do
					choices[#choices + 1] = {
						label   = Gestures.get_action_label(option),
						-- `checked` rather than a "✓" glued to the label: the tray draws
						-- its own mark, and the glued form puts one platform's
						-- convention inside a string twenty other languages also read.
						checked = option == bound,
						action  = function()
							Keyboard.set_action(slot, option)
							if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						end,
					}
				end
				rows[#rows + 1] = {
					label = Keyboard.get_slot_label(slot)
						.. " → " .. Gestures.get_action_label(bound),
					items = choices,
				}
			end
			out[#out + 1] = { label = i18n_safe(group.group_key), items = rows }
		end
		return out
	end

	-- The wrap-symbol picker. The manifest called it Windows-only until
	-- 2026-08-06 while this driver had been drawing it all along; it is a shared
	-- `list` row now, in the same position on all three drivers.
	providers["wrap_symbols_menu"] = function()
		return { { label = i18n_safe("menu.shortcuts.wrap_symbols"), items = wrap_items } }
	end

	local manifest_rows = ManifestMenu
		and ManifestMenu.build("shortcuts_menu", "Shortcuts", handlers, nil, ctx, providers)
		or {}
	if #manifest_rows > 0 then
		items[#items + 1] = { title = "-" }
		for _, row in ipairs(manifest_rows) do items[#items + 1] = row end
	end

	return { title = i18n_safe("menu.shortcuts.title"), menu = items }
end

--- Builds the Kanata submenu (Linux's Karabiner equivalent).
--- Actions delegate to the kanata manager module passed via ctx.kanata.
--- Builds the kanata submenu — the first block of this file the shared renderer
--- materialises rather than this driver.
---
--- The rows are DATA here: the provider returns `{ label, action, checked }` and
--- `manifest_menu` turns each into a menu item. That distinction is the whole of
--- M3.3. Routing a menu through `ManifestMenu.build` while its handlers still
--- append rows moves nothing — the manifest then describes the slot and the
--- driver still builds the row, which is what the bypass ratchet measures and
--- why four of this driver's menus already call the renderer without having
--- moved a single row out of it.
--- Display name of a tap-hold key, from the shared vocabulary.
---
--- `tap_hold.group.*` is the catalogue Windows already labels its tap-hold menu
--- with, translated in every locale. Reaching for it rather than spelling the
--- seven key names out here is the difference between this driver agreeing with
--- the other two and merely resembling them.
--- @param key_id string Key id from the tap-hold configuration, e.g. "caps_lock".
--- @return string.
local function _tap_hold_key_label(key_id)
	local label = i18n_safe("tap_hold.group." .. key_id)
	-- i18n_safe hands back the key when nothing is registered; an unlabelled key
	-- is better shown by its id than by a dotted path the user cannot read.
	if label == "tap_hold.group." .. key_id then return key_id end
	return label
end

--- Display name of a tap action. Falls back through the shared action catalogue
--- before giving up and showing the raw value, because a tap action is a key
--- name in some entries and an `sg_actions.*` id in others.
--- @param action string|nil Value of `tap_action`.
--- @return string.
local function _tap_hold_action_label(action)
	if type(action) ~= "string" or action == "" then
		return i18n_safe("tap_hold.tap.none")
	end
	for _, prefix in ipairs({ "sg_actions.", "tap_hold.group." }) do
		local label = i18n_safe(prefix .. action)
		if label ~= prefix .. action then return label end
	end
	return action
end

--- Display name of a hold modifier, from the shared `tap_hold.hold.*` catalogue.
--- @param modifier string|nil Value of `hold_modifier`.
--- @return string.
local function _tap_hold_hold_label(modifier)
	if type(modifier) ~= "string" or modifier == "" then
		return i18n_safe("tap_hold.hold.none")
	end
	local label = i18n_safe("tap_hold.hold." .. modifier)
	if label == "tap_hold.hold." .. modifier then return modifier end
	return label
end

--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_kanata(ctx)
	local km = ctx.kanata

	-- Fallback: try direct require if not passed via context.
	if not km then
		local ok_km, km_mod = pcall(require, "platform.remap.manager")
		if ok_km then km = km_mod end
	end

	--- Wraps a manager call so a row is clickable even before the manager loads.
	--- @param name string The manager function to call.
	--- @return function
	local function call(name)
		return function()
			if not km then
				Logger.error(LOG, "Kanata manager not loaded — '%s' did nothing.", name)
				return
			end
			local ok, result = pcall(km[name])
			if not ok then
				Logger.error(LOG, "kanata.%s() raised: %s.", name, tostring(result))
			elseif name == "write_kbd" then
				-- The only one with a meaningful return: it says whether the file
				-- was written, and a silent failure here leaves kanata running the
				-- previous layout with no sign that the new one never landed.
				if result then
					Logger.info(LOG, "Kanata .kbd generated.")
				else
					Logger.error(LOG, "Kanata .kbd generation failed.")
				end
			end
		end
	end

	local providers = {
		["kanata_actions"] = function()
			-- Taken from the context, not probed here. Answering truthfully now
			-- means asking the system whether ANY kanata is running, which is a
			-- subprocess — and building a menu must not spawn one. The daemon
			-- computes it when it decides to rebuild; `owns_process` is the
			-- cheap fallback when nobody supplied it, and it can only
			-- under-report, which greys a row rather than inventing a state.
			local running = ctx.kanata_running
			if running == nil then
				running = km and km.owns_process() or false
			end
			return {
				{ label = i18n_safe("menu.kanata.generate_kbd"), action = call("write_kbd") },
				{ label = i18n_safe("menu.kanata.start"),   action = call("start"),   checked = running },
				{ label = i18n_safe("menu.kanata.stop"),     action = call("stop") },
				{ label = i18n_safe("menu.kanata.restart"),  action = call("restart") },
			}
		end,

		-- One row per configured tap-hold key, read from the same loader that
		-- feeds kanata's defalias block. Ordered, because the loader returns a map
		-- and `pairs` would reshuffle the user's keys on every menu build.
		["kanata_tap_holds"] = function()
			if not km or type(km.tap_hold_keys) ~= "function" then
				Logger.error(LOG, "Kanata manager not loaded — the tap-holds cannot be read.")
				return {}
			end
			local ok, keys = pcall(km.tap_hold_keys)
			if not ok or type(keys) ~= "table" then
				Logger.error(LOG, "Tap-hold configuration unreadable — no row to show.")
				return {}
			end

			local ids = {}
			for id in pairs(keys) do ids[#ids + 1] = id end
			table.sort(ids)

			local rows = {}
			for _, id in ipairs(ids) do
				local entry = keys[id] or {}
				local seconds = tonumber(entry.time_activation_seconds)
				local ms = seconds and math.floor(seconds * 1000 + 0.5) or nil
				rows[#rows + 1] = {
					label = _tap_hold_key_label(id),
					-- A read-out, not a control: this driver reads the tap-hold file
					-- and has no writer for it, so every row below is disabled. A
					-- clickable row that cannot change anything is worse than a
					-- greyed one — it looks like the setting simply did not take.
					items = {
						{ label = string.format(i18n_safe("tap_hold.picker.tap"),
							_tap_hold_action_label(entry.tap_action)), disabled = true },
						{ label = string.format(i18n_safe("tap_hold.picker.hold"),
							_tap_hold_hold_label(entry.hold_modifier)), disabled = true },
						{ label = ms and string.format(i18n_safe("menu.kanata.tap_hold_delay"), tostring(ms))
							or i18n_safe("menu.kanata.tap_hold_delay"), disabled = true },
					},
				}
			end
			return rows
		end,
	}

	-- Commands reach the renderer through the context, not as an argument: the
	-- `command` branch reads ctx.commands[id]. Registering them on a local table
	-- and passing it positionally would land in `list_providers` and the row
	-- would render as an unanswered command.
	ctx.commands = ctx.commands or {}
	-- Opens the file the loader reads, resolved BY the loader. This driver can
	-- read a user tap_hold.toml and cannot write one, so "configure" means
	-- "open the file" until it can.
	ctx.commands["kanata_edit_tap_holds"] = function()
			if not km or type(km.tap_hold_config_path) ~= "function" then
				Logger.error(LOG, "Kanata manager not loaded — no tap-hold file to open.")
				return
			end
			local ok, path = pcall(km.tap_hold_config_path)
			if not ok or type(path) ~= "string" or path == "" then
				Logger.error(LOG, "Tap-hold file path unresolved — nothing opened.")
				return
			end
			-- xdg-open on a missing file fails silently, and a user who has never
			-- written an override is the common case — say so rather than letting
			-- the row look dead.
			local probe = io.open(path, "r")
			if probe then
				probe:close()
			else
				Logger.warn(LOG, "'%s' does not exist yet — the driver is running the shared defaults.", path)
			end
			pcall(function() os.execute("xdg-open " .. shell_quote(path) .. " 2>/dev/null &") end)
	end

	local rows = ManifestMenu
		and ManifestMenu.build("kanata_menu", "Kanata", nil, nil, ctx, providers)
		or {}
	return { title = i18n_safe("menu.kanata.title"), menu = rows }
end

--- Builds the gestures submenu.
local function _build_gestures(ctx)
	local ge = ctx.gestures
	if not ge then
		return { title = i18n_safe("menu.gestures.title"), menu = {
			{ title = i18n_safe("menu.gestures.unavailable"), fn = function() end, disabled = true },
		}}
	end

	local enabled = ge.is_enabled()

	-- Keyed by the manifest's own row ids. Each handler appends to the table the
	-- renderer HANDS IT, never to one closed over from here: the renderer builds
	-- its own result and passes it in, so a handler writing to an outer table
	-- would emit its rows into a menu the renderer never returns — every gesture
	-- row silently missing, with nothing failing.
	local gesture_rows = {
		["restore_defaults"] = function(out)
			out[#out + 1] = {
				title = i18n_safe("menu.gestures.restore_defaults"),
				fn = function() ge.reset_defaults() end,
			}
		end,
		["disable_all"] = function(out)
			out[#out + 1] = {
				title = i18n_safe("menu.gestures.disable_all"),
				fn = function() if ge.disable_all_actions then ge.disable_all_actions() end end,
			}
		end,
	}

	-- The master toggle, built here because the renderer skips `toggle` rows by
	-- contract: a category gate is driver state, not manifest data.
	local master_toggle = {
		title = i18n_safe("menu.common.enabled") .. (enabled and " ✓" or ""),
		fn = function() ge.toggle() end,
	}

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
	local providers = {}
	providers["gesture_slots_linux"] = function()
		local out = {}
		-- Every known slot is configurable here. A partial quick list made
		-- parameterized actions unreachable for the omitted gesture bindings.
		local slots = {}
		for slot in pairs(ge.DEFAULT_GESTURES or {}) do slots[#slots + 1] = slot end
		table.sort(slots)

		-- What this machine's touchpad can physically express. The kernel only
		-- advertises BTN_TOOL_QUADTAP at four slots and QUINTTAP at five, so a pad
		-- that stops at three — which the Precision Touchpad spec permits — can
		-- never fire twenty of these rows. Offering them anyway is the dead-line
		-- delivery the manifest's reason mechanism exists to avoid.
		--
		-- nil when no touchpad was found or its capability could not be read, and
		-- slot_is_reachable answers TRUE for everything in that case: a probe that
		-- could not read the hardware must never take a working gesture away.
		local touchpad = type(ge.touchpad) == "function" and ge.touchpad() or nil
		local max_fingers = touchpad and touchpad.max_fingers or nil
		local ok_finder, Finder = pcall(require, "modules.gestures.touchpad_finder")

		for _, slot in ipairs(slots) do
			local reachable = true
			if ok_finder and type(Finder.slot_is_reachable) == "function" then
				reachable = Finder.slot_is_reachable(slot, max_fingers)
			end
			if not reachable then
				-- Greyed with its reason rather than hidden: a row that vanishes
				-- reads as a bug, and the user cannot tell "this hardware cannot"
				-- from "this driver forgot".
				out[#out + 1] = {
					label    = gesture_slot_label(slot) .. " — "
						.. i18n_safe("platform_reason.touchpad_cannot_count_that_many"),
					disabled = true,
				}
				goto continue
			end

			local action = ge.get_action(slot) or "none"
			local label = ge.get_action_display_label and ge.get_action_display_label(slot)
				or ge.get_action_label(action)
			local choices = {}
			for _, option in ipairs(ge.get_action_names and ge.get_action_names() or { "none" }) do
				choices[#choices + 1] = {
					label   = ge.get_action_label(option),
					-- `checked`, not a "✓" glued to the label: the tray draws its own
					-- mark, and the glued form put one platform's convention inside a
					-- string that twenty other languages also read.
					checked = option == action,
					action  = function() assign_action(slot, option) end,
				}
			end
			out[#out + 1] = {
				label = gesture_slot_label(slot) .. " → " .. label,
				items = choices,
			}
			::continue::
		end
		return out
	end

	-- Declared in the manifest since 2026-08-04. Linux reads gestures from
	-- libinput, which macOS gets from the OS and Windows does not have at all, so
	-- the reader is startable here and has no counterpart elsewhere. Its label was
	-- a hardcoded French string, which every non-French user read in French — and
	-- being in no manifest, no gate could see either that or the row itself.
	providers["gesture_reading_linux"] = function()
		return {
			{
				label  = i18n_safe(ge.is_reading() and "menu.gestures.reading_on" or "menu.gestures.reading_off"),
				action = function()
					if ge.is_reading() then ge.stop_reading() else ge.start_reading() end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			},
		}
	end

	-- The master toggle stays with the caller: the renderer skips `toggle` rows by
	-- contract, because the category gate is driver state rather than manifest
	-- data. Everything below it is the manifest's, in the manifest's order.
	local rendered = ManifestMenu.build("gestures_menu", "Gestures", gesture_rows, nil, ctx, providers)
	local menu = { master_toggle }
	for _, row in ipairs(rendered or {}) do menu[#menu + 1] = row end

	return { title = i18n_safe("menu.gestures.title"), menu = menu }
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
	if not ManifestMenu then
		Logger.warn(LOG, "Manifest renderer unavailable — the global actions are not rendered.")
		return { title = i18n_safe("menu.global.title"), menu = {} }
	end

	--- Calls one of the context's optional callbacks, saying so when it is absent.
	--- @param name string
	--- @return function
	local function call_ctx(name)
		return function()
			if type(ctx[name]) ~= "function" then
				Logger.error(LOG, "Global actions: ctx.%s is absent — the row does nothing.", name)
				return
			end
			ctx[name]()
		end
	end

	-- The three rows are `type = "command"` in the manifest, and so is the
	-- separator before the reset: labels, order and spacing declared once, with
	-- this driver supplying only what each row does.
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {
		["enable_all"]     = call_ctx("on_enable_all"),
		["disable_all"]    = call_ctx("on_disable_all"),
		["reset_defaults"] = call_ctx("on_reset_defaults"),
	}

	return {
		title = i18n_safe("menu.global.title"),
		menu  = ManifestMenu.build("global_actions", "Global", nil, nil, render_ctx),
	}
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
			{ title = i18n_safe("menu.updates.unavailable"), fn = function() end, disabled = true },
		}}
	end

	--- The rows, as DATA. Every checkmark here is `checked`, not a "✓" glued onto
	--- a label: the tray draws its own, so the string form was one platform's
	--- convention leaking into text that twenty other languages also read.
	--- @return table
	local function rows()
		local channel  = up.get_channel()
		local interval = up.get_check_interval()
		local out = {}

		-- The version and channel the user is on, which is the question this
		-- submenu is opened to answer.
		out[#out + 1] = {
			label = string.format("v%s (%s)", up.current_version(), channel),
			disabled = true,
		}
		out[#out + 1] = { separator = true }

		out[#out + 1] = {
			label = up.get_menu_label(),
			action = function()
				if up.check_for_updates() then
					local rel = up.get_cached_release()
					if rel then Logger.info(LOG, "Update available: %s.", rel.tag) end
				else
					Logger.info(LOG, "No update available (current: %s).", up.current_version())
				end
			end,
		}

		-- Only once there is something to install: a permanently visible
		-- "download" row that does nothing is indistinguishable from a broken one.
		if up.get_state() == "available" then
			local rel = up.get_cached_release()
			if rel then
				out[#out + 1] = {
					label = _fill(i18n_safe("menu.updates.download_install"), "{tag}", rel.tag),
					action = function()
						local archive = up.download_update()
						if archive then up.install_update(archive) end
					end,
				}
			end
		end

		out[#out + 1] = { separator = true }

		for _, entry in ipairs({
			{ code = "stable", key = "menu.updates.channel_stable" },
			{ code = "dev",    key = "menu.updates.channel_dev" },
		}) do
			out[#out + 1] = {
				label   = i18n_safe(entry.key),
				checked = channel == entry.code,
				action  = function()
					up.set_channel(entry.code)
					Logger.info(LOG, "Update channel set to %s.", entry.code)
				end,
			}
		end

		out[#out + 1] = { separator = true }

		for _, preset in ipairs(up.INTERVAL_PRESETS) do
			out[#out + 1] = {
				label   = _fill(i18n_safe("menu.updates.check_every"), "{interval}", preset.code),
				checked = preset.seconds == interval,
				action  = function()
					up.set_check_interval(preset.seconds)
					up.stop_background_checks()
					up.start_background_checks()
				end,
			}
		end

		out[#out + 1] = { separator = true }

		out[#out + 1] = {
			label  = i18n_safe("menu.updates.open_releases"),
			action = function()
				local url = up.releases_page_url()
				Logger.info(LOG, "Opening releases page: %s", url)
				os.execute(string.format("xdg-open '%s' 2>/dev/null &", url:gsub("'", "'\\''")))
			end,
		}

		return out
	end

	local providers = { ["updates_actions"] = rows }
	local items = ManifestMenu
		and ManifestMenu.build("updates_menu", "Updates", nil, nil, ctx, providers)
		or {}
	return { title = i18n_safe("menu.updates.title"), menu = items }
end

--- Builds the about item.
local function _build_about(ctx)
	return {
		title = i18n_safe("menu.about.title"),
		-- Opens the release notes. It used to log one line to a file the user
		-- never sees and call that an About box — while ui/changelog/ was written,
		-- registered in webview_manager's bridge table and given a window title,
		-- with no caller anywhere. The page existed and nothing could reach it.
		fn = function()
			if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
				Logger.error(LOG, "No webview manager — the release notes cannot open.")
				return
			end
			ctx.webview.show("changelog")
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
--- The log levels the debug submenu offers, in increasing severity.
---
--- Not translated: DEBUG / INFO / WARNING / ERROR are the tokens the logger
--- itself prints and the user greps for, so a localised menu label would name
--- something that appears nowhere in the file it filters.
local DEBUG_LOG_LEVELS = { "DEBUG", "INFO", "WARNING", "ERROR" }

--- Builds the debug submenu from the shared manifest.
---
--- WHAT THIS REPLACED. Three rows written out by hand, while the manifest
--- declared five for this platform: `open_today_log` and `open_error_log` were
--- described in `debug_menu`, translated in all 21 locales, offered on Windows
--- and macOS, and simply absent here. Nothing reported it, because a driver that
--- does not read a manifest section cannot notice a row it does not build.
---
--- Windows and macOS each have their OWN reader for this same section
--- (`infra/menu_manifest.ahk`, `ui/menu/builder.lua`) and key on `id` alone, so
--- typing the rows costs them nothing and buys this driver the shared renderer.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_debug(ctx)
	if not ManifestMenu then
		Logger.warn(LOG, "Manifest renderer unavailable — the debug submenu loses its declared rows.")
		return { title = i18n_safe("menu.debug.title"), menu = {} }
	end

	--- Calls one of the context's optional callbacks, saying so when it is absent.
	--- @param name string The ctx field to invoke.
	--- @return function
	local function call_ctx(name)
		return function()
			if type(ctx[name]) ~= "function" then
				Logger.error(LOG, "Debug menu: ctx.%s is absent — the row does nothing.", name)
				return
			end
			ctx[name]()
		end
	end

	-- Bracketed key on purpose: it is what makes the id greppable, and the
	-- coverage gate that pairs every declared `list` with a provider resolves
	-- them by exactly that spelling.
	local providers = {
		["log_level"] = function()
			local rows = {}
			for _, level in ipairs(DEBUG_LOG_LEVELS) do
				rows[#rows + 1] = {
					label  = level,
					action = function()
						if type(ctx.on_set_log_level) == "function" then ctx.on_set_log_level(level) end
					end,
				}
			end
			return { { label = i18n_safe("menu.debug.log_level"), items = rows } }
		end,
	}

	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {
		["open_logs"]      = call_ctx("on_open_logs"),
		["open_today_log"] = call_ctx("on_open_today_log"),
		["open_error_log"] = call_ctx("on_open_error_log"),
		["healthcheck"]    = call_ctx("on_healthcheck"),
	}

	local rows = ManifestMenu.build("debug_menu", "Debug", nil, nil, render_ctx, providers)
	return { title = i18n_safe("menu.debug.title"), menu = rows }
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
