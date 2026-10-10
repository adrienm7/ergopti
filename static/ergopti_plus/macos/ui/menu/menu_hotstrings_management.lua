--- ui/menu/menu_hotstrings_management.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings — Management sub-menu
--- DESCRIPTION:
--- Builds the Paramètres sub-menu for the hotstrings tray menu: preview bubbles
--- (magic key, autocorrection, AI, coloured tooltips), word expanders (built-in
--- and custom terminators with add/delete), per-category delay configuration,
--- magic key character editor, and the repeat key toggle.
--- Sub-module of ui.menu.menu_hotstrings — merged at load time via
--- `for k, v in pairs(sub) do M[k] = v end`.
--- ==============================================================================

local M = {}
local hs                = hs
local Logger            = require("infra.logger")
local dialog            = require("infra.dialog_util")
local notifications     = require("infra.notifications")
local i18n              = require("infra.i18n")
local hotstrings_config = require("modules.hotstrings.hotstrings_config")
local ManifestReader = require("infra.manifest_reader")
local ManifestMenu   = require("infra.manifest_menu")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local Terminators     = require("keymap.terminators")
local LOG               = "menu_hotstrings"





-- =============================
-- =============================
-- ======= 1/ Management =======
-- =============================
-- =============================

--- Reads only the complete canonical quick-delay caption policy.
--- @return table|nil Captions; invalid declarations refuse the parameter rows.
local function delay_captions()
	local root = ManifestMenu.get_root()
	local captions = type(root) == "table" and rawget(root, "hotstrings_delay_captions") or nil
	local keys = { default = true, magic_key = true, autocorrection = true,
		ai_acceptance = true, autocompletion = true }
	if type(captions) ~= "table" or getmetatable(captions) ~= nil then return nil end
	local count = 0
	for key, value in next, captions do
		if keys[key] ~= true or type(value) ~= "string" or value == "" then return nil end
		count = count + 1
	end
	if count ~= 5 then return nil end
	return captions
end

--- Builds the management sub-menu.
--- @param ctx table Context.
--- @return table

-- Captures the actual declared frame before native value readers can reenter it.
local function magic_frame_snapshot(renderer, key, expected)
	key, expected = key or "hotstrings_magic_trigger_frame", expected or 3
	local root = renderer.get_root()
	local frame = type(root) == "table" and rawget(root, key)
	if type(frame) ~= "table" or getmetatable(frame) ~= nil or #frame ~= expected then return nil end
	local slots = 0
	for index in next, frame do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > expected then return nil end
		slots = slots + 1
	end
	if slots ~= expected then return nil end
	local snapshot = {}
	for index, row in ipairs(frame) do
		if type(row) ~= "table" or getmetatable(row) ~= nil then return nil end
		local fields = {}
		for key, value in next, row do
			if type(value) == "table" then
				if getmetatable(value) ~= nil then return nil end
				local entries = {}
				for field, item in next, value do
					if type(item) == "table" or type(item) == "function" then return nil end
					entries[field] = item
				end
				fields[key] = { identity = value, entries = entries }
			elseif type(value) == "function" then return nil
			else fields[key] = value end
		end
		snapshot[index] = { identity = row, fields = fields }
	end
	return { root = root, frame = frame, rows = snapshot, key = key }
end

-- Publication is withheld when any captured declaration identity or field changed.
local function magic_frame_current(renderer, snapshot)
	if not snapshot or not rawequal(renderer.get_root(), snapshot.root)
		or not rawequal(rawget(snapshot.root, snapshot.key), snapshot.frame)
		or getmetatable(snapshot.frame) ~= nil or #snapshot.frame ~= #snapshot.rows then return false end
	local slots = 0
	for index in next, snapshot.frame do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #snapshot.rows then return false end
		slots = slots + 1
	end
	if slots ~= #snapshot.rows then return false end
	for index, saved in ipairs(snapshot.rows) do
		local row = rawget(snapshot.frame, index)
		if not rawequal(row, saved.identity) or getmetatable(row) ~= nil then return false end
		local count, expected = 0, 0
		for key, value in next, row do
			count = count + 1
			local prior = saved.fields[key]
			if type(prior) == "table" then
				if not rawequal(value, prior.identity) or getmetatable(value) ~= nil then return false end
				local entries, wanted = 0, 0
				for field, item in next, value do
					entries = entries + 1
					if not rawequal(item, prior.entries[field]) then return false end
				end
				for _ in next, prior.entries do wanted = wanted + 1 end
				if entries ~= wanted then return false end
			elseif not rawequal(value, prior) then return false end
		end
		for _ in next, saved.fields do expected = expected + 1 end
		if count ~= expected then return false end
	end
	return true
end

function M.build_management(ctx)
	local state  = ctx.state
	local paused = ctx.paused
	local bubble_item = nil
	local exp_item = nil
	local delays_item = nil
	local captions = delay_captions()
	local boundaries = ManifestMenu.template_rows("hotstrings_parameter_boundary", {}, {}, {})
	if not captions or not boundaries then return nil end

	local bubble_sub = {}

	local magic_row = ManifestMenu.check_row("preview_magic_control", "preview_star_enabled", {
		["preview_star_enabled"] = function()
			if type(ctx.commit_preview) ~= "function" or ctx.commit_preview("preview_star_enabled") ~= true then
				return false
			end
			ctx.notify_feature(i18n.get("menu.hotstrings.notify_bubble_star"), state.preview_star_enabled)
			ctx.updateMenu()
			return true
		end,
	}, {
		["hotstrings.preview_star_enabled"] = function() return state.preview_star_enabled == true end,
		["preview_magic_ready"] = function() return not ctx.paused end,
	})
	if magic_row then table.insert(bubble_sub, magic_row) end

	local preview_magic_rows = bubble_sub
	bubble_sub = {}
	local presence_commands = {}
	local presence_getters = { preview_presence_ready = function() return not ctx.paused end }
	for key, notify_key in pairs({
		preview_autocorrect_enabled = "menu.hotstrings.notify_bubble_autocorrect",
		preview_ai_enabled = "menu.hotstrings.notify_bubble_ai",
	}) do
		presence_commands[key] = function()
			if type(ctx.commit_preview) ~= "function" or ctx.commit_preview(key) ~= true then return false end
			ctx.notify_feature(i18n.get(notify_key), state[key])
			ctx.updateMenu()
			return true
		end
		presence_getters["hotstrings." .. key] = function() return state[key] == true end
	end
	for _, declaration in ipairs(ManifestMenu.get_array("preview_presence_controls")) do
		local row = ManifestMenu.check_row("preview_presence_controls", declaration.id, presence_commands, presence_getters)
		if row then table.insert(bubble_sub, row) end
	end

	local preview_presence_rows = bubble_sub
	bubble_sub = {}

	local colored_row = ManifestMenu.check_row("preview_colored_control", "preview_colored_tooltips", {
		["preview_colored_tooltips"] = function()
			if type(ctx.commit_preview) ~= "function" or ctx.commit_preview("preview_colored_tooltips") ~= true then
				return false
			end
			ctx.notify_feature(i18n.get("menu.hotstrings.notify_bubble_colored"), state.preview_colored_tooltips)
			ctx.updateMenu()
			return true
		end,
	}, {
		["hotstrings.preview_colored_tooltips"] = function() return state.preview_colored_tooltips == true end,
		["preview_colored_ready"] = function() return not ctx.paused end,
	})
	if colored_row then table.insert(bubble_sub, colored_row) end

	local preview_rows = ManifestMenu.template_rows("hotstrings_preview_frame", {}, {}, {
		["parameter_preview_magic"] = function() return preview_magic_rows end,
		["parameter_preview_presence"] = function() return preview_presence_rows end,
		["parameter_preview_colored"] = function() return bubble_sub end,
	})
	if not preview_rows then return nil end
	local preview_parent = ManifestMenu.template_rows("hotstrings_preview_parent", {},
		{ ["parameter_parent_ready"] = function() return not paused end },
		{ ["parameter_preview_children"] = preview_rows })
	if not preview_parent then return nil end
	bubble_item = preview_parent[1]

	local defs    = ctx.keymap and type(ctx.keymap.get_terminator_defs) == "function" and ctx.keymap.get_terminator_defs() or {}
	local exp_sub = {}

	-- Bulk actions — mirror the Windows word-expanders submenu so both drivers
	-- expose the same set: enable all / disable all / reset the built-in
	-- terminators to their catalogue defaults. Custom terminators are managed
	-- individually below and are left untouched here.
	local function commit_terminator_changes(changes, reason)
		local keymap = ctx.keymap
		local committed = KeymapLifecycle.commit_mutation(ctx, reason, function()
			if not keymap or type(keymap.set_terminators_enabled) ~= "function" then return false end
			return keymap.set_terminators_enabled(changes)
		end)
		if not committed then return false end
		for key, enabled in pairs(changes) do state.terminator_states[key] = enabled end
		if ctx.save_prefs() ~= true then return false end
		ctx.updateMenu()
		return true
	end

	local function word_expanders_ready() return ctx.paused ~= true end

	local function bulk_set_terminators(enabled)
		if not word_expanders_ready() then return false end
		local changes = {}
		for _, d in ipairs(defs) do
			if type(d) == "table" and not d.custom and d.key then
				changes[d.key] = enabled
			end
		end
		return commit_terminator_changes(changes, "bulk word-expander toggle")
	end
	local function reset_terminators()
		if not word_expanders_ready() then return false end
		local changes = {}
		for _, d in ipairs(defs) do
			if type(d) == "table" and not d.custom and d.key then
				-- default_enabled is true unless the catalogue marks it false (slash/backslash)
				changes[d.key] = (d.default_enabled ~= false)
			end
		end
		return commit_terminator_changes(changes, "reset word expanders")
	end

	-- Built-in terminators (non-custom), with consume indicator. The shared
	-- catalogue order IS the menu order; { type = "separator" } entries become
	-- "-" dividers so the groups (whitespace, punctuation, apostrophes, closing
	-- delimiters, slashes, magic key) are separated — single source = the spec.
	for _, def in ipairs(defs) do
		if type(def) == "table" and not def.custom then
			if def.type == "separator" then
				for _, boundary in ipairs(boundaries) do exp_sub[#exp_sub + 1] = boundary end
			elseif def.key then
				local enabled_t = ctx.keymap and type(ctx.keymap.is_terminator_enabled) == "function" and ctx.keymap.is_terminator_enabled(def.key) or false

				local lbl = def.label or ""
				lbl = lbl:gsub("Guillemets fermants", "Guillemet fermant")
				lbl = lbl:gsub("tiret bas", "underscore")
				lbl = lbl:gsub("Tiret bas", "Underscore")
				if def.consume then lbl = lbl .. " " .. i18n.get("menu.hotstrings.consumed_suffix") end

				exp_sub[#exp_sub + 1] = {
					label    = ctx.applyTriggerChar(lbl),
					checked  = enabled_t or nil,
					disabled = paused or nil,
					action       = not paused and (function(k, l) return function()
						local nv = true
						if ctx.keymap and type(ctx.keymap.is_terminator_enabled) == "function" then
							nv = not ctx.keymap.is_terminator_enabled(k)
						end
						local committed = KeymapLifecycle.commit_mutation(ctx,
							"toggle word expander", function()
								if not ctx.keymap or type(ctx.keymap.set_terminator_enabled) ~= "function" then
									return false
								end
								return ctx.keymap.set_terminator_enabled(k, nv)
							end)
						if not committed then return false end
						state.terminator_states[k] = nv
						if ctx.save_prefs() ~= true then return false end
						ctx.notify_feature(string.format(i18n.get("notify.word_expander_prefix"), ctx.applyTriggerChar(l)), nv)
						ctx.updateMenu()
						return true
					end end)(def.key, lbl) or nil,
				}
			end
		end
	end

	-- Custom terminators + add button, grouped together at the bottom
	local catalogue_rows = exp_sub
	exp_sub = {}

	for _, ct in ipairs(type(state.custom_terminators) == "table" and state.custom_terminators or {}) do
		if type(ct) ~= "table" or type(ct.char) ~= "string" or ct.char == "" then goto continue_ct end
		local enabled_t = ctx.keymap and type(ctx.keymap.is_terminator_enabled) == "function" and ctx.keymap.is_terminator_enabled(ct.key) or false
		local consume_sfx = ct.consume and (" (" .. i18n.get("menu.hotstrings.consumed") .. ")") or ""
		local ct_lbl = ct.char .. " : " .. i18n.get("menu.hotstrings.custom_label") .. consume_sfx

		local delete_row = ManifestMenu.command_row("word_expander_custom_menu", "word_expander_delete", {
			["word_expander_delete"] = (function(k) return function()
					local res = dialog.block_alert(
						i18n.get("dialog.hotstrings.delete_title"),
						i18n.get("dialog.hotstrings.delete_body"),
						i18n.get("button.delete"), i18n.get("button.cancel")
					)
					if res ~= i18n.get("button.delete") then return end
					local committed = KeymapLifecycle.commit_mutation(ctx,
						"remove custom word expander", function()
							if not ctx.keymap
								or type(ctx.keymap.remove_custom_terminator) ~= "function" then
								return false
							end
							return ctx.keymap.remove_custom_terminator(k)
						end)
					if not committed then return false end
					if type(state.custom_terminators) == "table" then
						for i, ct_e in ipairs(state.custom_terminators) do
							if ct_e.key == k then table.remove(state.custom_terminators, i); break end
						end
					end
					if type(state.terminator_states) == "table" then state.terminator_states[k] = nil end
					if ctx.save_prefs() ~= true then return false end
					ctx.updateMenu()
					return true
				end end)(ct.key),
		}, { ["word_expanders_ready"] = word_expanders_ready })
		local ct_sub = delete_row and { delete_row } or {}

		exp_sub[#exp_sub + 1] = {
			label    = ct_lbl,
			checked  = enabled_t or nil,
			items     = ct_sub,
			disabled = paused or nil,
		}
		::continue_ct::
	end

	local add_row = ManifestMenu.command_row("word_expander_custom_menu", "word_expander_add", {
		["word_expander_add"] = function()
			local existing_keys = {}
			for _, d in ipairs(defs) do
				if d.key then existing_keys[d.key] = true end
			end
			local idx = 1
			local key = "custom_" .. idx
			while existing_keys[key] do idx = idx + 1; key = "custom_" .. idx end

			-- 1. Ask for the trigger character (loop until exactly one character is entered)
			local char
			while true do
				if not word_expanders_ready() then return false end
				local accept_label, cancel_label = i18n.get("button.ok"), i18n.get("button.cancel")
				local ok_p, btn, char_raw = pcall(dialog.text_prompt,
					i18n.get("dialog.hotstrings.new_title"),
					i18n.get("dialog.hotstrings.new_prompt"),
					"", accept_label, cancel_label
				)
				if not word_expanders_ready() then return false end
				if not ok_p or btn ~= accept_label or type(char_raw) ~= "string" then return false end
				local valid, reason = Terminators.validate_custom_terminator(
					key, char_raw, char_raw, false)
				if valid then
					char = char_raw
					break
				end
				local body = i18n.get("dialog.hotstrings.invalid_body")
				if reason == "character_collision" or reason == "key_collision" then
					body = string.format(i18n.get("editor.hotstrings.err_id_exists"), char_raw)
				end
				dialog.block_alert(i18n.get("dialog.hotstrings.invalid_title"), body,
					i18n.get("button.retry"))
			end

			-- 2. Ask consume behaviour (default: non consommé)
			local consume_no_label = i18n.get("dialog.hotstrings.consume_no")
			local consume_yes_label = i18n.get("dialog.hotstrings.consume_yes")
			local consume_res = dialog.block_alert(
				i18n.get("dialog.hotstrings.consume_title"),
				i18n.get("dialog.hotstrings.consume_body"),
				consume_no_label, consume_yes_label, i18n.get("button.cancel")
			)
			if not word_expanders_ready() then return false end
			if consume_res ~= consume_no_label
				and consume_res ~= consume_yes_label then return false end
			local consume = (consume_res == consume_yes_label)

			local label = char .. " : " .. (consume and i18n.get("hotstrings.custom_terminator_consumed") or i18n.get("hotstrings.custom_terminator"))

			-- 4. Register in the live engine
			local committed = KeymapLifecycle.commit_mutation(ctx,
				"add custom word expander", function()
					if not ctx.keymap
						or type(ctx.keymap.add_custom_terminator) ~= "function" then
						return false
					end
					return ctx.keymap.add_custom_terminator(key, char, label, consume)
				end)
			if not committed then return false end

			-- 5. Persist in state
			if type(state.custom_terminators) ~= "table" then state.custom_terminators = {} end
			table.insert(state.custom_terminators, { key = key, char = char, label = label, consume = consume })
			if type(state.terminator_states) ~= "table" then state.terminator_states = {} end
			state.terminator_states[key] = true
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
			return true
		end,
	}, { ["word_expanders_ready"] = word_expanders_ready })
	if add_row then exp_sub[#exp_sub + 1] = add_row end

	local exp_ctx = {
		commands = {
			["word_expanders_enable_all"] = function() return bulk_set_terminators(true) end,
			["word_expanders_disable_all"] = function() return bulk_set_terminators(false) end,
			["word_expanders_restore"] = reset_terminators,
		},
		state_getters = { ["word_expanders_ready"] = word_expanders_ready },
	}
	local entry_rows = ManifestMenu.template_rows("hotstrings_word_expander_frame", {}, {}, {
		["parameter_catalogue_entries"] = function() return catalogue_rows end,
		["parameter_custom_entries"] = function() return exp_sub end,
	})
	if not entry_rows then return nil end
	local rendered_expanders = ManifestMenu.build("word_expanders_menu", "HotstringsParams", nil, nil,
		exp_ctx, { ["word_expander_entries"] = function() return entry_rows end })
	local expander_submenu_rows = ManifestMenu.native_child_rows(rendered_expanders)
	if not expander_submenu_rows then return nil end
	local expander_parent = ManifestMenu.template_rows("hotstrings_word_expander_parent", {},
		{ ["parameter_parent_ready"] = function() return not paused end },
		{ ["parameter_word_expander_children"] = expander_submenu_rows })
	if not expander_parent then return nil end
	exp_item = expander_parent[1]

	local delay_menu = {}
	local function make_delay_item(title, key, default_val, is_base)
		if type(default_val) ~= "number" then
			Logger.error(LOG, "make_delay_item(): default_val nil for '%s' — keymap.DELAYS_DEFAULT may be outdated.", title)
			return { label = title .. " : " .. i18n.get("menu.hotstrings.missing_value"), disabled = true }
		end
		-- Coerce + fail closed to default_val: state.expansion_delay (and per-key
		-- delays) come straight from config.toml and can be a string (hand edit /
		-- AHK migration). The engine apply is already type-guarded (menu_state.lua),
		-- but this arithmetic (cur_val * 1000) would crash the delay submenu build —
		-- swallowed by the builder pcall, dropping the whole Paramètres submenu (F-L13).
		local cur_val = tonumber(is_base and state.expansion_delay or (state.delays[key] or default_val)) or default_val
		local cur_ms = math.floor(cur_val * 1000 + 0.5)
		local def_ms = math.floor(default_val * 1000 + 0.5)
		local display_ms = (cur_ms == 0) and i18n.get("menu.hotstrings.infinite") or (cur_ms .. " ms")

		return {
			-- menu.settings.default_indicator (" (default)") is the surviving shared
			-- key — its value already carries the leading space, so we don't add one.
			label    = title .. " : " .. display_ms .. (cur_ms == def_ms and i18n.get("menu.settings.default_indicator") or ""),
			disabled = paused or nil,
			action       = not paused and function()
				local ok_p, btn, raw = pcall(dialog.text_prompt,
					title,
					i18n.get("menu.hotstrings.delay_prompt"),
					tostring(cur_ms), "OK", i18n.get("common.cancel")
				)
				if not ok_p or btn ~= "OK" then return end

				local val = tonumber(raw)
				if not val or val < 0 or val ~= math.floor(val) then
					pcall(notifications.notify, i18n.get("menu.hotstrings.delay_invalid_title"), i18n.get("menu.hotstrings.delay_invalid_body"), "error")
					return
				end

				local new_sec = val / 1000
				if is_base then
					if type(ctx.commit_base_delay) ~= "function" or ctx.commit_base_delay(new_sec) ~= true then
						return false
					end
				else
					state.delays[key] = new_sec
					if ctx.keymap and type(ctx.keymap.set_delay) == "function" then pcall(ctx.keymap.set_delay, key, new_sec) end
				end
				if not is_base and ctx.save_prefs() ~= true then return false end
				ctx.updateMenu()
				if is_base then return true end
			end or nil,
		}
	end

	-- Builds a quick-access delay item for a TOML-backed category (magic key,
	-- autocorrection). Unlike make_delay_item — which owns its value in
	-- state.delays — this reads the EFFECTIVE delay via hotstrings_config.resolve
	-- (so the row shows the same number as the config window) and writes through
	-- set_override (the one persistent source both UIs share), then pushes the new
	-- value into the live CoreState.DELAYS via set_delay so it applies at once.
	local function make_category_delay_item(title, key, category)
		local resolved = hotstrings_config.resolve(category, nil)
		local cur_val  = (type(resolved) == "table" and type(resolved.delay) == "number") and resolved.delay or nil
		if type(cur_val) ~= "number" then
			Logger.error(LOG, "make_category_delay_item(): no resolvable delay for category '%s'.", category)
			return { label = title .. " : " .. i18n.get("menu.hotstrings.missing_value"), disabled = true }
		end
		local cur_ms     = math.floor(cur_val * 1000 + 0.5)
		local has_over   = (type(resolved) == "table" and resolved.has_override) or false
		local display_ms = (cur_ms == 0) and i18n.get("menu.hotstrings.infinite") or (cur_ms .. " ms")

		return {
			-- menu.settings.default_indicator (" (default)") carries its own leading
			-- space; show it while the user has set no override for this category.
			label    = title .. " : " .. display_ms .. ((not has_over) and i18n.get("menu.settings.default_indicator") or ""),
			disabled = paused or nil,
			action       = not paused and function()
				local ok_p, btn, raw = pcall(dialog.text_prompt,
					title,
					i18n.get("menu.hotstrings.delay_prompt"),
					tostring(cur_ms), "OK", i18n.get("common.cancel")
				)
				if not ok_p or btn ~= "OK" then return end

				local val = tonumber(raw)
				if not val or val < 0 or val ~= math.floor(val) then
					pcall(notifications.notify, i18n.get("menu.hotstrings.delay_invalid_title"), i18n.get("menu.hotstrings.delay_invalid_body"), "error")
					return
				end

				-- Persist through hotstrings_config (same store + file the config
				-- window writes to, so the two UIs never desync) then apply to the
				-- running engine so the new delay takes effect without a restart.
				local new_sec = val / 1000
				if hotstrings_config.set_override(category, nil, "delay", new_sec) ~= true then
					return false
				end
				if ctx.keymap and type(ctx.keymap.set_delay) == "function" then pcall(ctx.keymap.set_delay, key, new_sec) end
				ctx.updateMenu()
			end or nil,
		}
	end

	-- expansion_delay lives in keymap.DEFAULT_STATE; BASE_DELAY_SEC_DEFAULT is a legacy alias
	local def_base = ctx.keymap and (
		ctx.keymap.BASE_DELAY_SEC_DEFAULT
		or (type(ctx.keymap.DEFAULT_STATE) == "table" and ctx.keymap.DEFAULT_STATE.expansion_delay)
	)
	if not def_base then
		Logger.warn(LOG, "keymap.DEFAULT_STATE.expansion_delay missing — base delay undefined.")
	end
	local def_delays = ctx.keymap and type(ctx.keymap.DELAYS_DEFAULT) == "table" and ctx.keymap.DELAYS_DEFAULT
	if not def_delays then
		Logger.warn(LOG, "keymap.DELAYS_DEFAULT missing — individual delays undefined.")
	end

	-- The per-group delays for TOML-backed categories (rolls, autocorrection,
	-- magickey, sfbsreduction, distancesreduction, personal) live in the
	-- dedicated configuration window where colors can also be tuned. Categories
	-- that do not have a TOML counterpart (llm_prediction, dynamichotstrings)
	-- and the global baseline keep their per-prompt menu items as quick access.
	local settings_row = ManifestMenu.command_row("hotstrings_delays_menu", "hotstrings_config_window", {
		hotstrings_config_window = function()
			local ok, win = pcall(require, "ui.hotstrings_config_window")
			if not ok or not win or type(win.open) ~= "function" then return end
			-- make_category_delay_item bakes the resolved delay and the
			-- "(default)" indicator into its title at BUILD time, so an override
			-- edited in the window leaves those rows showing pre-edit values and a
			-- false default tag until something else rebuilds the menu. Hand the
			-- window an explicit refresh channel so the two UIs cannot desync.
			win._on_config_changed = function()
				if ctx.save_prefs() ~= true then return false end
				ctx.updateMenu()
			end
			pcall(win.open)
		end,
	}, { hotstrings_config_ready = function() return not paused end })
	local delay_providers = {
		["parameter_delay_config"] = function() return settings_row and { settings_row } or {} end,
		["parameter_delay_ai_acceptance"] = function()
			return def_delays and { make_delay_item(i18n.get(captions.ai_acceptance), "llm_prediction", def_delays.llm_prediction, false) } or {}
		end,
		["parameter_delay_autocompletion"] = function()
			return def_delays and { make_delay_item(i18n.get(captions.autocompletion), "dynamichotstrings", def_delays.dynamichotstrings, false) } or {}
		end,
		["parameter_delay_default"] = function()
			return def_base and { make_delay_item(i18n.get(captions.default), nil, def_base, true) } or {}
		end,
		["parameter_delay_category_boundary"] = function() return def_delays and boundaries or {} end,
		["parameter_delay_magic_key"] = function()
			return def_delays and { make_category_delay_item(i18n.get(captions.magic_key), "STAR_TRIGGER", "magickey") } or {}
		end,
		["parameter_delay_autocorrection"] = function()
			return def_delays and { make_category_delay_item(i18n.get(captions.autocorrection), "autocorrection", "autocorrection") } or {}
		end,
	}
	delay_menu = ManifestMenu.template_rows("hotstrings_delays_frame", {}, {}, delay_providers)
	if not delay_menu then return nil end
	local delay_parent = ManifestMenu.template_rows("hotstrings_delays_parent", {},
		{ ["parameter_parent_ready"] = function() return not paused end }, { ["parameter_delays_children"] = delay_menu })
	if not delay_parent then return nil end
	delays_item = delay_parent[1]

	local hs_state  = ctx and ctx.state
	local hs_paused = ctx and ctx.paused
	local magic_key_value = (hs_state and hs_state.trigger_char or ManifestReader.default_for("hotstrings.trigger_char"))
	local magic_key_action = function()
			if not hs_state then return end
			local ok_p, btn, raw = pcall(dialog.text_prompt,
				i18n.get("menu.hotstrings.magic_key_title"),
				i18n.get("menu.hotstrings.magic_key_prompt"),
				hs_state.trigger_char, "OK", i18n.get("common.cancel")
			)
			if ok_p and btn == "OK" and type(raw) == "string" then
				if Terminators.validate_character(raw) ~= true then
					dialog.block_alert(i18n.get("dialog.hotstrings.invalid_title"),
						i18n.get("dialog.hotstrings.invalid_body"), i18n.get("button.retry"))
					return false
				end
				if raw ~= hs_state.trigger_char then
					local committed = KeymapLifecycle.commit_mutation(ctx,
						"change magic key", function()
							if not ctx.keymap
								or type(ctx.keymap.set_trigger_char) ~= "function" then
								return false
							end
							return ctx.keymap.set_trigger_char(raw)
						end)
					if not committed then return false end
					hs_state.trigger_char = raw
					if ctx.hotstring_editor and type(ctx.hotstring_editor.set_trigger_char) == "function" then
						pcall(ctx.hotstring_editor.set_trigger_char, raw)
					end
					if ctx.save_prefs() ~= true then return false end
					ctx.do_reload("menu")
					return true
				end
			end
		end
	local repeat_enabled = ctx and ctx.keymap
		and type(ctx.keymap.is_repeat_feature_enabled) == "function"
		and ctx.keymap.is_repeat_feature_enabled()
	-- `repeat_key` is a `check` row since 2026-08-07: the renderer draws it from
	-- the declaration, and this driver supplies only the toggle and the state
	-- behind the tick. It was three copies of one checkbox before that, one per
	-- driver, from a declaration that named only the slot.
	local params_ctx = {}
	for key, value in pairs(ctx) do params_ctx[key] = value end
	params_ctx.commands = {}
	for key, value in pairs(ctx.commands or {}) do params_ctx.commands[key] = value end
	params_ctx.commands["repeat_key"] = function()
		if not ctx.keymap or type(ctx.keymap.set_repeat_feature_enabled) ~= "function" then return false end
		local wanted = not repeat_enabled
		local ok, committed = pcall(ctx.keymap.set_repeat_feature_enabled, wanted)
		if not ok or committed ~= true then
			Logger.error(LOG, "Magic-key repeat toggle was refused: %s.", tostring(committed))
			return false
		end
		ctx.state.repeat_key_enabled = wanted
		if ctx.save_prefs() ~= true then return false end
		return ctx.do_reload("menu")
	end
	params_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do params_ctx.state_getters[key] = value end
	params_ctx.state_getters["hotstrings_repeat_enabled"] = function() return repeat_enabled end

	-- The manifest's rows for this group, dispatched by id, and then the two rows
	-- it does not describe.
	--
	-- The three ids below were declared for this driver and handled nowhere — not
	-- because the rows were missing, but because they were assembled by hand right
	-- here and the ids were never written down. That is the state the handler
	-- bijection ratchet counts, and it is worth being precise about how it misled:
	-- a first pass read "no driver names magic_key_config" as "no Lua driver can
	-- edit the magic key" and nearly restricted this very row out of the menu it
	-- has always been in.
	-- Named rows, not menu: a local called `menu` puts a bare `menu =` three lines
	-- above the separator below, which is the context token the rows-outside-the-
	-- renderer scan keys on — so the assignment alone made a separator read as a
	-- hand-built row. The name is better this way regardless.
	local rows = ManifestMenu.build("hotstrings_params_group", "HotstringsParams", {

	}, nil, params_ctx, {
		-- word_expanders is `type = "list"` in the manifest now, so the shared
		-- renderer materialises every row of the submenu from this data instead of
		-- this driver assembling the hs.menubar shape itself. Same provider shape
		-- as the other two drivers answer with.
		["word_expanders"] = function()
			if not exp_item then return {} end
			return { exp_item }
		end,
		-- `list` since 2026-08-07, for the same reason word_expanders became one:
		-- both Lua drivers built this identical tree of four switches themselves
		-- because `dynamic` handed the id straight back. The renderer materialises
		-- it from the data now.
		["preview_bubbles"] = function()
			if not bubble_item then return {} end
			return { bubble_item }
		end,
		-- `list` since 2026-08-07, with the same reasoning: the magic-key row and
		-- its reset were built three times from a declaration that named the slot.
		["magic_key_config"] = function()
			local source = magic_frame_snapshot(ManifestMenu)
			if not source then return {} end
			local items = ManifestMenu.template_rows("hotstrings_magic_trigger_frame", { magic_key_change = magic_key_action },
				{ magic_key_value = function() return magic_key_value end, magic_key_ready = function() return not hs_paused end }, {})
			if not items or not magic_frame_current(ManifestMenu, source) then return {} end
			if hs_paused then for _, item in ipairs(items) do item.action = nil end end
			return items
		end,
		-- `list` since 2026-08-07, the last row of this group to move.
		["delays_colors"] = function()
			if not delays_item then return {} end
			return { delays_item }
		end,
	})

	-- The caller renders the declared hotstrings_params parent around these native children.
	return { menu = rows }
end

return M
