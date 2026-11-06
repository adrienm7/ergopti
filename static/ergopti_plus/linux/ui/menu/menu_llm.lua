--- ui/menu/menu_llm.lua

--- ==============================================================================
--- MODULE: Linux Menu AI Submenu
--- DESCRIPTION:
--- Builds the tray's AI (LLM) submenu through the shared AI parent: backends,
--- models, prediction, profiles, triggers, display and navigation settings with
--- their prompts and dialogs.
--- ==============================================================================

local M = {}

local SaveFailure = require("config_save_failure")
local Logger = require("logger.shim")
local TextPrompt = require("ui.text_prompt")
local PrivacyPolicy = require("llm.trigger_policy")
local LlmBackendRows = require("ui.menu.llm_backend_rows")
local COMMAND = require("config_keys").COMMAND
local KeyNames = require("keycodes.key_names")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local _fill = require("ui.menu.menu_dialogs")._fill
local succeeded = require("ui.menu.menu_dialogs").succeeded
local prompt_text = require("ui.menu.menu_dialogs").prompt_text
local show_error = require("ui.menu.menu_dialogs").show_error
local show_info = require("ui.menu.menu_dialogs").show_info
local plain_markup = require("ui.menu.menu_dialogs").plain_markup
local ask_yes_no = require("ui.menu.menu_dialogs").ask_yes_no

local LOG = "ui.menu.menu_llm"

--- Captures the displayed value and publication authority from one exact read.
--- The caller passes its menu refresh, not the native menu context: the AI
--- parent keeps that context closed to the owners it reviews.
--- @param refresh function|nil Menu refresh run after an accepted save.
--- @param owner table Original settings owner.
--- @param module_name string Settings module identity.
--- @param name string Setting key.
--- @param path string Canonical preference path.
--- @return any value, function|nil save
local function numeric_setting_request(refresh, owner, module_name, name, path)
	-- Not named Preferences: that local belongs to _build_llm's toggle admission.
	local Prefs = require("infra.llm_preferences")
	local Paths = require("infra.config_paths")
	local set, get_many, generation = owner.set, Prefs.get_many, Prefs.generation
	local classified, retained = owner.set_with_reason, owner.set_with_source_notice
	local revision_current, publish, config = Prefs.is_current_revision, Prefs.set_many, Paths.config
	if type(set) ~= "function" or type(get_many) ~= "function" or type(generation) ~= "function"
		or type(revision_current) ~= "function" or type(publish) ~= "function" or type(config) ~= "function" then return nil end
	local function ports_current()
		return package.loaded[module_name] == owner and owner.set == set and owner.set_with_reason == classified
			and owner.set_with_source_notice == retained
			and package.loaded["infra.llm_preferences"] == Prefs and Prefs.get_many == get_many
			and Prefs.generation == generation and Prefs.is_current_revision == revision_current
			and Prefs.set_many == publish and package.loaded["infra.config_paths"] == Paths and Paths.config == config
	end
	local root_ok, root = pcall(config, "config.toml")
	if not root_ok or type(root) ~= "string" or not ports_current() then return nil end
	local called, values, source, revision = pcall(get_many, { path })
	if not called or type(values) ~= "table" or type(values[path]) ~= "number" or type(source) ~= "table"
		or type(revision) ~= "number" or revision < 0 or revision % 1 ~= 0 then return nil end
	local function owner_current()
		if not ports_current() then return false end
		local read, selected = pcall(config, "config.toml")
		return read and selected == root and ports_current()
	end
	local function current()
		return owner_current() and revision_current(revision) == true and ports_current()
	end
	local function refused(page_current, invalid)
		Logger.error(LOG, "Numeric setting '%s' refused: its opening configuration is no longer current.", name)
		if page_current and page_current() ~= true then return false end
		local okay, notifier = pcall(require, "adapters.notifier")
		if okay and type(notifier.send) == "function" and (not page_current or page_current() == true) then
			local message = i18n_safe(invalid and "menu.llm.word_limits_incompatible" or "dialog.personal_info.save_failed_title")
			if not page_current or page_current() == true then pcall(notifier.send, message, { level = "error" }) end
		end
		return false
	end
	if not current() then refused(); return nil end
	return values[path], function(value, page_current)
		if page_current and page_current() ~= true then return false end
		if not current() then return refused(page_current) end
		local checked, actual = pcall(generation)
		if not checked or actual ~= revision or not current() then return refused(page_current) end
		local noticed = false
		local receipt = { admit = page_current, acknowledge = function() noticed = true end }
		local saved, accepted, reason = pcall(classified or retained or set, name, value, source, current, receipt, owner_current)
		if not saved then
			Logger.error(LOG, "Numeric setting callback raised (error type: %s).", type(accepted))
			return false
		end
		if accepted ~= true then
			if noticed then return false end
			local reread, _, observed = pcall(get_many, { path })
			if not reread or type(observed) ~= "table" or observed.status ~= source.status
				or observed.content ~= source.content then return false end
			return refused(page_current, reason == "invalid")
		end
		if not owner_current() or (page_current and page_current() ~= true) then return false end
		if type(refresh) == "function" then refresh() end
		return true
	end
end

--- Commits a preset only when its persistent owner acknowledges the write.
--- @param owner table Settings owner.
--- @param name string Setting name.
--- @param value any Selected value.
--- @param refresh function|nil Menu refresh callback.
--- @param classified boolean|nil Whether the owner exposes a closed refusal reason.
--- @return boolean committed
--- Captures the configuration owner at menu projection time.
local function choice_origin()
	local Paths = require("infra.config_paths")
	local config = Paths.config
	if type(config) ~= "function" then return nil end
	local okay, path = pcall(config, "config.toml")
	if not okay or type(path) ~= "string" or Paths.config ~= config then return nil end
	return { paths = Paths, config = config, path = path }
end

--- Stores an admitted menu choice and reports only an unconfirmed write.
--- @return boolean committed
local function commit_choice(owner, name, value, source, prefix, expected, origin, classified)
	local setter = classified and owner.set_with_reason or owner.set_with_reason_notice
	if type(setter) ~= "function" then return false end
	local Prefs, Paths = require("infra.llm_preferences"), require("infra.config_paths")
	local read, config, current_revision = Prefs.get_many, Paths.config, Prefs.is_current_revision
	local publish = Prefs.set_many_with_notice
	local module_names = { ["llm.trigger."] = "modules.llm.trigger_settings", ["llm.display."] = "modules.llm.display_settings", ["llm.generation."] = "modules.llm.settings", ["llm.profiles."] = "modules.llm.profile_settings" }
	local module_name = module_names[prefix]
	if not module_name then return false end
	if type(origin) ~= "table" or origin.paths ~= Paths or origin.config ~= config
		or type(read) ~= "function" or type(config) ~= "function" or type(current_revision) ~= "function"
		or type(publish) ~= "function" then return false end
	local root_ok, root = pcall(config, "config.toml")
	local read_ok, values, observed, revision = pcall(read, { prefix .. name })
	if not root_ok or type(root) ~= "string" or root ~= origin.path or not read_ok or type(values) ~= "table" or type(observed) ~= "table"
		or (expected ~= nil and values[prefix .. name] ~= expected)
		or type(revision) ~= "number" or (source and (source.status ~= observed.status or source.content ~= observed.content)) then return false end
	local function owner_current()
		if package.loaded["infra.llm_preferences"] ~= Prefs or package.loaded["infra.config_paths"] ~= Paths
			or package.loaded[module_name] ~= owner or Prefs.set_many_with_notice ~= publish
			or Prefs.get_many ~= read or Prefs.is_current_revision ~= current_revision or Paths.config ~= config
			or (classified and owner.set_with_reason or owner.set_with_reason_notice) ~= setter then return false end
		local okay, selected = pcall(config, "config.toml")
		if not okay or selected ~= root then return false end
		return true
	end
	local function current()
		if not owner_current() then return false end
		local checked, unchanged = pcall(current_revision, revision)
		return checked and unchanged == true and package.loaded["infra.llm_preferences"] == Prefs
			and package.loaded[module_name] == owner and Prefs.set_many_with_notice == publish
			and package.loaded["infra.config_paths"] == Paths and Prefs.get_many == read
			and Prefs.is_current_revision == current_revision and Paths.config == config
			and (classified and owner.set_with_reason or owner.set_with_reason_notice) == setter
	end
	if not current() then return false end
	local committed, reason, noticed
	if classified then
		local reported = false
		committed, reason = setter(name, value, observed, current, { admit = current, acknowledge = function() reported = true end }, owner_current)
		noticed = reported
	else
		committed, reason, noticed = setter(name, value, observed, current, owner_current)
	end
	if committed == true then return owner_current() end
	if (reason == "unconfirmed" or reason == "persistence" or reason == "invalid") and noticed ~= true then
		if not current() then return false end
		local reread, _, after = pcall(read, { prefix .. name })
		if not reread or type(after) ~= "table" or after.status ~= observed.status or after.content ~= observed.content
			or not current() then return false end
		local okay, notifier = pcall(require, "adapters.notifier")
		if okay and type(notifier.send) == "function" and current() then
			local send = notifier.send
			local message = i18n_safe(reason == "invalid" and "menu.llm.word_limits_incompatible" or "dialog.personal_info.save_failed_title")
			if current() and package.loaded["adapters.notifier"] == notifier and notifier.send == send then
				pcall(send, message, { level = "error" })
			end
		end
	end
	return false
end

local function commit_preset(owner, name, value, refresh, classified, prefix, origin)
	if not commit_choice(owner, name, value, nil, prefix, nil, origin, classified) then return false end
	if type(refresh) == "function" then refresh() end
	return true
end

--- Builds the AI / LLM submenu.
local function _build_llm(ctx)
	local NativeParent = require("ui.menu.ai_parent")
	local parent = NativeParent.begin(ManifestMenu, "llm", ctx)
	if not parent then return nil end
	local llm = ctx.llm
	if not llm then
		local status_rows = ManifestMenu and ManifestMenu.template_rows("linux_llm_absent_rows", {}, {}, {})
		if not status_rows then return {} end
		return NativeParent.finish(parent, ManifestMenu.render_rows(status_rows, "linux_llm_absent_rows"))
	end

	local items = {}
	local enabled = parent.enabled

	-- The master gate is the manifest's first row and the shared renderer draws
	-- it, from the command and the getter registered below. It also gets its OWN
	-- two labels back — « Activer / Désactiver les suggestions IA », translated in
	-- twenty-one locales and read by nobody — instead of a generic « Activé » with
	-- a " ✓" glued on, a mark that belongs to the tray rather than to the string.

	-- The model, profile and generation rows are declared `list` rows: their
	-- labels carry live values, so each provider below returns row DATA and the
	-- shared renderer draws it at the declared place. No row here is native.
	local providers = {}
	local group_builders = {}

	-- Inactivity and privacy controls. Unlike the model and generation lists,
	-- this is one labelled submenu, so the manifest keeps its cross-driver
	-- declared group and this driver supplies only the runtime child contents.
	group_builders["llm_trigger"] = function()
		local origin = choice_origin()
		local ok_settings, TriggerSettings = pcall(require, "modules.llm.trigger_settings")
		if not ok_settings then
			Logger.error(LOG, "LLM trigger settings unavailable; trigger menu omitted.")
			return
		end
		local rows = {}
		--- Builds one delay row: the numeric setting's presets, an optional "Never"
		--- (the shared sentinel, as on macOS) and the free numeric entry.
		--- @param name string Trigger setting name.
		--- @param label_key string i18n key of the row label (one %s: the current value).
		--- @param offers_never boolean Whether "Never" is a choice of this setting.
		--- @return table row
		local function delay_row(name, label_key, offers_never)
			local current = TriggerSettings.get(name)
			local delay_choices = {}
			local function choose(value)
				return function()
					return commit_preset(TriggerSettings, name, value, ctx.on_menu_changed, false, "llm.trigger.", origin)
				end
			end
			for _, value in ipairs(TriggerSettings.presets(name)) do
				delay_choices[#delay_choices + 1] = { label = tostring(value) .. " ms", checked = current == value, action = choose(value) }
			end
			local never = offers_never and TriggerSettings.is_never(name, current)
			if offers_never then
				for _, row in ipairs(ManifestMenu.template_rows("llm_debounce_never_row", {
					[require("config_keys").COMMAND.LLM_DEBOUNCE_NEVER] = choose(TriggerSettings.NEVER_MS),
				}, {
					["llm_debounce_is_never"] = function() return never end,
				}) or {}) do delay_choices[#delay_choices + 1] = row end
			end
			local bounds = TriggerSettings.bounds(name)
			local custom_rows = ManifestMenu.template_rows("llm_numeric_custom_rows", {
				[require("config_keys").COMMAND.LLM_NUMERIC_CUSTOM_VALUE] = function()
					local ok_prompt, Prompt = pcall(require, "ui.numeric_prompt.bridge")
					if not ok_prompt then
						Logger.error(LOG, "No numeric prompt; %s can only take a preset.", name)
						return
					end
					-- The prompt is headed by the declared caption of the group that opens it.
					local title_key
					for _, entry in ipairs(ManifestMenu.get_array("llm_menu")) do
						if entry.id == "llm_trigger" then title_key = entry.i18n end
					end
					if type(title_key) ~= "string" or title_key == "" then
						Logger.error(LOG, "The AI trigger group declares no caption; %s prompt refused.", name)
						return
					end
					local value, save = numeric_setting_request(ctx.on_menu_changed, TriggerSettings,
						"modules.llm.trigger_settings", name, "llm.trigger." .. name)
					if not save then return false end
					Prompt.ask({
						title = i18n_safe(title_key),
						hint = string.format("%d – %d ms", bounds.min, bounds.max),
						value = value,
						min = bounds.min,
						max = bounds.max,
						on_save = function(number, page_current) return save(math.floor(number), page_current) end,
					}, ctx.webview)
				end,
			})
			for _, row in ipairs(custom_rows or {}) do delay_choices[#delay_choices + 1] = row end
			return {
				label = string.format(i18n_safe(label_key),
					never and i18n_safe("menu.settings.never") or (tostring(current) .. " ms")),
				items = delay_choices,
			}
		end
		rows[#rows + 1] = delay_row(require("config_keys").LEAF.DEBOUNCE_MS, "menu.llm.debounce_label", true)
		-- The one minimum time between two automatic requests (shortcuts are never held).
		rows[#rows + 1] = delay_row(require("config_keys").LEAF.MIN_REQUEST_INTERVAL_MS, "menu.llm.min_interval_label", false)
		local boundary_rows = ManifestMenu.template_rows("llm_trigger_provider_boundary", {}, {}, {})
		if not boundary_rows then return end
		for _, row in ipairs(boundary_rows) do rows[#rows + 1] = row end
		local leading_rows = rows
		rows = {}
		local Preferences = require("infra.llm_preferences")
		local function privacy_snapshot(name)
			local snapshot = {owner = TriggerSettings, generation = 0,
				value = TriggerSettings.get(name), enabled = llm.is_enabled(),
				paused = true, blocked = true}
			local ok, detail = xpcall(function()
				local path = "llm.trigger." .. name
				local values, source = Preferences.get_many({require("config_keys").KEY.LLM_ENABLED, require("config_keys").KEY.LLM_MODELS_SELECTED, path})
				snapshot.source = source
				snapshot.preferences_generation = Preferences.generation()
				if type(llm.streaming_revision) ~= "function" then error("Native admission revision is unavailable") end
				snapshot.generation = llm.streaming_revision()
				local revision = snapshot.preferences_generation
				if type(revision) ~= "number" or revision ~= revision or revision == math.huge
					or revision < 0 or revision % 1 ~= 0 then error("Invalid preference revision") end
				snapshot.backend = llm.get_backend()
				snapshot.paused = ctx.paused == true or ctx.is_paused()
				snapshot.blocked = Preferences.admit() ~= true
					or values[require("config_keys").KEY.LLM_ENABLED] ~= snapshot.enabled
					or values[require("config_keys").KEY.LLM_MODELS_SELECTED] ~= snapshot.backend or values[path] ~= snapshot.value
			end, debug.traceback)
			if not ok then
				Logger.warn(LOG, "Privacy row source is unavailable: %s.", tostring(detail))
				snapshot.blocked = true
			end
			return snapshot
		end
		local url_source = privacy_snapshot(require("config_keys").LEAF.URL_BAR_FILTER_ENABLED)
		local secure_source = privacy_snapshot(require("config_keys").LEAF.SECURE_FILTER_ENABLED)
		local function privacy_command(expected, name)
			local current = privacy_snapshot(name)
			local decision = PrivacyPolicy.intent(expected, current)
			if expected.preferences_generation ~= current.preferences_generation
				or decision.admitted ~= true or type(expected.source) ~= "table" or type(current.source) ~= "table"
				or expected.source.status ~= current.source.status
				or expected.source.content ~= current.source.content then return false end
			if not commit_choice(TriggerSettings, name, decision.value, expected.source, "llm.trigger.", nil, origin) then return false end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return true
		end
		local function ready()
			return llm.is_enabled() == true and ctx.paused ~= true
				and not (type(ctx.is_paused) == "function" and ctx.is_paused() == true)
		end
		local function toggle(name)
			if not ready() then return false end
			local current = TriggerSettings.get(name)
			if type(current) ~= "boolean" or not commit_choice(TriggerSettings, name, not current, nil, "llm.trigger.", current, origin) then return false end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return true
		end
		local trigger_ctx = {
			commands = {
				[require("config_keys").COMMAND.LLM_URL_BAR_FILTER] = function() return privacy_command(url_source, require("config_keys").LEAF.URL_BAR_FILTER_ENABLED) end,
				[require("config_keys").COMMAND.LLM_SECURE_FIELD_FILTER] = function() return privacy_command(secure_source, require("config_keys").LEAF.SECURE_FILTER_ENABLED) end,
				[require("config_keys").COMMAND.LLM_INSTANT_ON_WORD_END] = function() return toggle(require("config_keys").LEAF.INSTANT_ON_WORD_END) end,
				[require("config_keys").COMMAND.LLM_AFTER_HOTSTRING] = function() return toggle(require("config_keys").LEAF.AFTER_HOTSTRING) end,
				[require("config_keys").COMMAND.LLM_INLINE_AUTOTYPE] = function() return toggle(require("config_keys").LEAF.INLINE_AUTOTYPE) end,
				[require("config_keys").COMMAND.LLM_WHILE_HOTSTRING_TOOLTIP] = function(value)
					local leaf = require("config_keys").LEAF.WHILE_HOTSTRING_TOOLTIP
					local current = TriggerSettings.get(leaf)
					if not ready() or current == value then return false end
					if not commit_choice(TriggerSettings, leaf, value, nil, "llm.trigger.", current, origin) then return false end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
			},
			state_getters = {
				["llm_url_bar_filter_enabled"] = function() return TriggerSettings.get(require("config_keys").LEAF.URL_BAR_FILTER_ENABLED) end,
				["llm_secure_field_filter_enabled"] = function() return TriggerSettings.get(require("config_keys").LEAF.SECURE_FILTER_ENABLED) end,
				["llm_url_bar_filter_ready"] = function() return PrivacyPolicy.ready(url_source) end,
				["llm_secure_field_filter_ready"] = function() return PrivacyPolicy.ready(secure_source) end,
				["llm_instant_on_word_end_enabled"] = function() return TriggerSettings.get(require("config_keys").LEAF.INSTANT_ON_WORD_END) end,
				["llm_after_hotstring_enabled"] = function() return TriggerSettings.get(require("config_keys").LEAF.AFTER_HOTSTRING) end,
				["llm_inline_autotype_enabled"] = function() return TriggerSettings.get(require("config_keys").LEAF.INLINE_AUTOTYPE) end,
				[require("config_keys").KEY.LLM_TRIGGER_WHILE_HOTSTRING_TOOLTIP] = function()
					return TriggerSettings.get(require("config_keys").LEAF.WHILE_HOTSTRING_TOOLTIP)
				end,
				["llm_trigger_ready"] = ready,
			},
		}
		-- The applications the trigger never runs in: the submenu the other two drivers draw.
		local AppRows = require("ui.menu.app_exclusion_rows")
		local exclusion_title = i18n_safe("menu.llm.exclude_from_ai")
		rows[#rows + 1] = {
			label = AppRows.caption(#TriggerSettings.disabled_apps(),
				{ none = "menu.llm.exclude_from_ai", counted = "menu.llm.disabled_in_label" }),
			disabled = not ready() or nil,
			items = AppRows.rows({
				get = TriggerSettings.disabled_apps,
				set = function(list) return ready() and TriggerSettings.set_disabled_apps(list) end,
				current = type(llm.get_agent_last_app) == "function" and llm.get_agent_last_app or function() return nil end,
				prompt = function(title, text, initial, hidden, choices)
					return TextPrompt.ask(title, plain_markup(text), initial, hidden, choices)
				end,
				title = exclusion_title,
				changed = function()
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			}),
		}
		rows = ManifestMenu.build("llm_trigger_menu", "LLM", nil, nil, trigger_ctx, {
			["llm_trigger_leading"] = function() return leading_rows end,
			["llm_trigger_remaining"] = function() return rows end,
		})
		local child_rows = ManifestMenu.native_child_rows(rows)
		if child_rows == nil then return nil end
		return { items = child_rows, disabled = not enabled or nil }
	end

	providers["llm_profile"] = function()
		local ok_profiles, ProfileSettings = pcall(require, "modules.llm.profile_settings")
		if not ok_profiles then return {} end
		local save_edit, edit_current, select_edit, delete_edit = require("ui.menu.profile_editor_request").capture(ProfileSettings)
		-- The model predictions actually use: an API entry's when the API answers.
		local current_model = llm.get_prediction_model and llm.get_prediction_model() or nil
		local effective = ProfileSettings.effective_profile(current_model)
		local count = ProfileSettings.get(require("config_keys").LEAF.NUM_PREDICTIONS) or 1
		local function refresh()
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end
		local function select_profile(profile_id)
			if type(profile_id) ~= "string" or profile_id == "" then return false end
			if type(edit_current) ~= "function" or edit_current() ~= true then
				Logger.error(LOG, "Profile selection refused: its originating configuration is no longer current.")
				return false
			end
			if type(llm.get_live) ~= "function" or type(llm.set_live) ~= "function" then
				Logger.error(LOG, "Manual profile selection refused: its live override owner is unavailable.")
				return false
			end
			local observed, live = xpcall(llm.get_live, debug.traceback)
			if not observed then return false end
			if live ~= nil then
				local stopped, accepted = xpcall(llm.set_live, debug.traceback, nil)
				local checked, current = xpcall(llm.get_live, debug.traceback)
				if stopped ~= true or accepted ~= true or checked ~= true or current ~= nil then
					Logger.error(LOG, "Manual profile selection refused: its temporary override did not retire.")
					return false
				end
			end
			local saved = select_edit and select_edit(profile_id, current_model) == true
			if not saved then Logger.error(LOG, "Profile selection was not committed.") end
			if saved then refresh() end
			return saved
		end
		local function save_profile(profile, activate, expected_existing)
			local saved = save_edit and save_edit(profile, activate, expected_existing) == true
			if saved then refresh() end
			return saved
		end
		local function create_ready()
			if ctx.paused == true or type(ctx.is_paused) ~= "function" then return false end
			local ok, current = pcall(ctx.is_paused)
			return ok and current == false
		end
		local function open_editor(existing, activate, opts, create)
			if type(edit_current) ~= "function" or edit_current() ~= true then
				Logger.error(LOG, "Profile editor refused: its originating configuration is no longer current.")
				return false
			end
			if create and not create_ready() then return false end
			local ok_editor, Editor = pcall(require, "ui.prompt_editor.bridge")
			if not ok_editor or type(Editor.open) ~= "function" then
				Logger.error(LOG, "Prompt editor is unavailable.")
				return false
			end
			local expected_existing = type(existing) == "table"
				and not (type(opts) == "table" and opts.as_new == true)
			if not expected_existing then
				local editor_opts = {}
				for key, value in pairs(type(opts) == "table" and opts or {}) do
					editor_opts[key] = value
				end
				editor_opts.profile_id = ProfileSettings.next_user_profile_id()
				opts = editor_opts
			end
			if create and not create_ready() then return false end
			return Editor.open(existing, function(profile)
				if create and not create_ready() then return false end
				return save_profile(profile, activate, expected_existing)
			end, opts)
		end
		local effective_label = effective
		local active_builtin, user_profiles, seed
		local function auto_profile()
			if not create_ready() then return false end
			local current = ProfileSettings.get(require("config_keys").LEAF.AUTO_PROFILE_FOR_MODEL)
			if type(current) ~= "boolean" or not create_ready() then return false end
			local saved = ProfileSettings.set(require("config_keys").LEAF.AUTO_PROFILE_FOR_MODEL, not current, current_model)
			if saved ~= true then return false end
			refresh()
			return true
		end
		local function builtin_rows()
			local rows = {}
			for _, profile in ipairs(ProfileSettings.list_built_in()) do
				local profile_id = profile.id
				-- The same label the action picker lists the profile under. _fill
				-- appended the count to every label without {n}: "Basic — … 3 s".
				local label = ProfileSettings.menu_label(profile, count)
				if effective == profile_id then
					effective_label = label
					active_builtin = profile
				end
				rows[#rows + 1] = {
					label = label,
					checked = effective == profile_id,
					action = function()
						select_profile(profile_id)
					end,
				}
			end
			return rows
		end
		local function custom_present()
			user_profiles = ProfileSettings.list_user()
			return #user_profiles > 0
		end
		local function custom_rows()
			local rows = {}
			for _, profile in ipairs(user_profiles) do
				local owned_profile = profile
				local profile_id = profile.id
				local label = profile.label
				if effective == profile_id then effective_label = label end
				local function child_ready()
					if type(ProfileSettings.list_user) ~= "function" then return false end
					local ok, current = pcall(ProfileSettings.list_user)
					if not ok or type(current) ~= "table" then return false end
					local matches = 0
					for _, entry in ipairs(current) do
						if entry.id == profile_id then matches = matches + 1 end
					end
					return matches == 1
				end
				rows[#rows + 1] = {
					label = label,
					items = ManifestMenu.template_rows("llm_custom_profile_controls", {
						[require("config_keys").COMMAND.LLM_PROFILE_USE] = function() return select_profile(profile_id) end,
						[require("config_keys").COMMAND.LLM_PROFILE_EDIT] = function() return open_editor(owned_profile, false) end,
						[require("config_keys").COMMAND.LLM_PROFILE_DELETE] = function()
								if type(edit_current) ~= "function" or edit_current() ~= true then
									Logger.error(LOG, "Profile deletion refused: its originating configuration is no longer current.")
									return false
								end
								local title = string.format(
									i18n_safe("menu.profiles.delete_confirm_title"), label)
								local confirmed
								if type(ctx.confirm_profile_delete) == "function" then
									confirmed = ctx.confirm_profile_delete(profile_id, label)
								else
									confirmed = ask_yes_no(
										title,
										i18n_safe("menu.profiles.delete_confirm_body"),
										i18n_safe("button.delete"),
										i18n_safe("button.cancel"))
								end
								if confirmed ~= true then return false end
								local deleted = delete_edit and delete_edit(profile_id) == true
								if not deleted then Logger.error(LOG, "Profile deletion was not committed.") end
								if deleted then refresh() end
								return deleted
							end,
					}, {
						["llm_custom_profile_active"] = function()
							return ProfileSettings.effective_profile(current_model) == profile_id
						end,
						["llm_custom_profile_ready"] = child_ready,
					}, {}) or {},
				}
			end
			return rows
		end
		local function clone_present()
			if not active_builtin then return false end
			seed = {
				label = effective_label .. " " .. i18n_safe("menu.profiles.copy_suffix"),
				system_single = active_builtin.system_single,
				system_multi_template = active_builtin.system_multi_template,
				batch = active_builtin.batch == true,
			}
			return true
		end
		--- The per-application overrides: map the application last typed in to the profile
		--- in force, and one row per mapping that clears it. The same rows as Windows.
		local function app_override_rows()
			local AppOverrides = require("llm.app_profile_overrides")
			local mapped = AppOverrides.rows(ProfileSettings.app_overrides())
			local last = type(llm.get_agent_last_app) == "function" and llm.get_agent_last_app() or nil
			local clear_rows = {}
			for _, entry in ipairs(mapped) do
				local app, profile_id = entry.app, entry.profile
				local profile = ProfileSettings.resolve_id(profile_id)
				clear_rows[#clear_rows + 1] = {
					label = app .. "  →  " .. (profile and ProfileSettings.menu_label(profile, count) or profile_id),
					action = function()
						if not create_ready() then return false end
						if ProfileSettings.clear_app_override(app) ~= true then return false end
						refresh()
						return true
					end,
				}
			end
			return ManifestMenu.template_rows("llm_profile_app_override_frame", {
				[COMMAND.LLM_PROFILE_OVERRIDE_ACTIVE_APP] = function()
					if not create_ready() or AppOverrides.normalize_app(last) == nil then return false end
					if ProfileSettings.set_app_override(last, effective) ~= true then return false end
					refresh()
					return true
				end,
			}, {
				["llm_profile_overrides_present"] = function() return #clear_rows > 0 end,
			}, {
				["llm_profile_override_rows"] = function() return clear_rows end,
			}) or {}
		end
		local rows = ManifestMenu.template_rows("llm_profile_lua_frame", {
			[require("config_keys").COMMAND.LLM_PROFILE_AUTO_DETECT] = auto_profile,
			[require("config_keys").COMMAND.LLM_PROFILE_CLONE] = function() return open_editor(seed, true, { as_new = true }, true) end,
			[require("config_keys").COMMAND.LLM_PROFILE_CREATE] = function() return open_editor(nil, true, nil, true) end,
		}, {
			["llm_profile_auto_detect_checked"] = function() return ProfileSettings.get(require("config_keys").LEAF.AUTO_PROFILE_FOR_MODEL) == true end,
			["llm_profile_custom_present"] = custom_present,
			["llm_profile_clone_present"] = clone_present,
			["llm_profile_create_ready"] = create_ready,
			["llm_profile_clone_ready"] = create_ready,
		}, {
			["llm_profile_builtin_rows"] = builtin_rows,
			["llm_profile_custom_rows"] = custom_rows,
		})
		if not rows then return {} end
		-- The per-application overrides end the submenu, as on Windows.
		local override_rows = ManifestMenu.template_rows("llm_profile_lua_app_overrides", {}, {}, {
			["llm_profile_app_overrides"] = app_override_rows,
		})
		if not override_rows then return {} end
		for _, row in ipairs(override_rows) do rows[#rows + 1] = row end
		-- The profile parent writes config.toml: it names the same cause as the
		-- switch, and its retained rows recheck it at click time.
		local ConfigGuard = require("ui.menu.llm_config_guard")
		local blocked = ConfigGuard.reason()
		ConfigGuard.protect(rows)
		return { {
			label = string.format(i18n_safe("menu.profiles.profile_label_prefix"), effective_label),
			items = rows,
			disabled = not enabled or blocked ~= nil or nil,
			disabled_reason_key = enabled and blocked or nil,
		} }
	end

	group_builders["llm_display"] = function()
		local origin = choice_origin()
		local ok_display, DisplaySettings = pcall(require, "modules.llm.display_settings")
		if not ok_display then return end
		local DisplayPolicy = require("llm.display_policy")
		local ProfileSettings = require("modules.llm.profile_settings")
		local function show_all_ready()
			return DisplayPolicy.ready(ProfileSettings.get(require("config_keys").LEAF.NUM_PREDICTIONS),
				ctx.paused == true or (type(ctx.is_paused) == "function" and ctx.is_paused() == true)
				or type(llm.is_enabled) ~= "function" or llm.is_enabled() ~= true)
		end
		local Preferences = require("infra.llm_preferences")
		local function streaming_snapshot()
			local paused
			if type(ctx.is_paused) == "function" then paused = ctx.is_paused() end
			local values, source = Preferences.get_many({ require("config_keys").KEY.LLM_ENABLED, require("config_keys").KEY.LLM_DISPLAY_STREAMING, require("config_keys").KEY.LLM_DISPLAY_STREAMING_MULTI })
			local revision = type(llm.streaming_revision) == "function" and llm.streaming_revision() or nil
			local enabled = type(llm.is_enabled) == "function" and llm.is_enabled() or nil
			local streaming, progressive = DisplaySettings.get("streaming"), DisplaySettings.get(require("config_keys").LEAF.STREAMING_MULTI)
			return {
				owner = Preferences, source = source,
				generation = type(revision) == "number" and Preferences.generation() + revision or nil,
				platform = "linux",
				backend = type(llm.get_backend) == "function" and llm.get_backend() or nil,
				enabled = enabled, paused = paused,
				blocked = Preferences.admit() ~= true or enabled ~= values[require("config_keys").KEY.LLM_ENABLED]
					or streaming ~= values[require("config_keys").KEY.LLM_DISPLAY_STREAMING] or progressive ~= values[require("config_keys").KEY.LLM_DISPLAY_STREAMING_MULTI],
				progressive = progressive, streaming = streaming,
			}
		end
		local streaming_source = streaming_snapshot()
		local rows = {}
		local function indentation_snapshot()
			local snapshot = streaming_snapshot()
			local values, source = Preferences.get_many({ require("config_keys").KEY.LLM_PROFILES_NUM_PREDICTIONS, require("config_keys").KEY.LLM_DISPLAY_PRED_INDENT })
			snapshot.count = ProfileSettings.get(require("config_keys").LEAF.NUM_PREDICTIONS)
			snapshot.indentation = DisplaySettings.get(require("config_keys").LEAF.PRED_INDENT)
			snapshot.blocked = snapshot.blocked or snapshot.count ~= values[require("config_keys").KEY.LLM_PROFILES_NUM_PREDICTIONS]
				or snapshot.indentation ~= values[require("config_keys").KEY.LLM_DISPLAY_PRED_INDENT]
			-- Re-reading the canonical owner advances its revision for every source
			-- change, including unrelated fields and away/back transitions.
			snapshot.source = source
			local revision = type(llm.streaming_revision) == "function" and llm.streaming_revision() or nil
			local generation = type(revision) == "number" and Preferences.generation() + revision or nil
			snapshot.blocked = snapshot.blocked or snapshot.generation ~= generation
			snapshot.generation = generation
			return snapshot
		end
		local indentation_source = indentation_snapshot()
		local function info_bar_snapshot()
			local values, source = Preferences.get_many({ require("config_keys").KEY.LLM_ENABLED, require("config_keys").KEY.LLM_DISPLAY_SHOW_INFO_BAR })
			local revision = type(llm.streaming_revision) == "function" and llm.streaming_revision() or nil
			local enabled = type(llm.is_enabled) == "function" and llm.is_enabled() or nil
			local selected = DisplaySettings.get(require("config_keys").LEAF.SHOW_INFO_BAR)
			local paused
			if type(ctx.is_paused) == "function" then paused = ctx.is_paused() end
			return {
				owner = Preferences, source = source,
				generation = type(revision) == "number" and Preferences.generation() + revision or nil,
				backend = type(llm.get_backend) == "function" and llm.get_backend() or nil,
				info_bar = selected, enabled = enabled, paused = paused,
				blocked = Preferences.admit() ~= true or enabled ~= values[require("config_keys").KEY.LLM_ENABLED]
					or selected ~= values[require("config_keys").KEY.LLM_DISPLAY_SHOW_INFO_BAR],
			}
		end
		local info_bar_source = info_bar_snapshot()
		local display_ctx = {
			commands = {
				[require("config_keys").COMMAND.LLM_INDENTATION] = function(value)
					local current = indentation_snapshot()
					local decision = DisplayPolicy.indentation_intent(indentation_source, current, value, DisplaySettings.indent_values())
					if decision.admitted ~= true then return false end
					if not commit_choice(DisplaySettings, require("config_keys").LEAF.PRED_INDENT, decision.value, current.source, "llm.display.", nil, origin) then return false end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
				[require("config_keys").COMMAND.LLM_SHOW_ALL] = function()
					if not show_all_ready() then return false end
					local current = DisplaySettings.get(require("config_keys").LEAF.STREAMING_MULTI)
					if type(current) ~= "boolean" or not commit_choice(DisplaySettings, require("config_keys").LEAF.STREAMING_MULTI, not current, nil, "llm.display.", current, origin) then return false end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
				[require("config_keys").COMMAND.LLM_TOKEN_STREAMING] = function()
					local current = streaming_snapshot()
					local decision = DisplayPolicy.streaming_intent(streaming_source, current)
					if decision.admitted ~= true then return false end
					if not commit_choice(DisplaySettings, "streaming", decision.value, current.source, "llm.display.", nil, origin) then return false end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
				[require("config_keys").COMMAND.LLM_INFO_BAR] = function()
					local current = info_bar_snapshot()
					local decision = DisplayPolicy.info_bar_intent(info_bar_source, current)
					if decision.admitted ~= true then return false end
					if not commit_choice(DisplaySettings, require("config_keys").LEAF.SHOW_INFO_BAR, decision.value, current.source, "llm.display.", nil, origin) then return false end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
			},
			state_getters = {
				[require("config_keys").KEY.LLM_DISPLAY_PRED_INDENT] = function() return indentation_source.indentation end,
				["llm_indentation_ready"] = function() return DisplayPolicy.indentation_ready(indentation_source) end,
				["llm_show_all_enabled"] = function() return DisplayPolicy.show_all(DisplaySettings.get(require("config_keys").LEAF.STREAMING_MULTI)) end,
				["llm_show_all_ready"] = show_all_ready,
				["llm_token_streaming_enabled"] = function()
					return DisplayPolicy.streaming_capable(streaming_source.platform, streaming_source.backend)
						and streaming_source.streaming == true
				end,
				["llm_token_streaming_ready"] = function() return DisplayPolicy.streaming_ready(streaming_source) end,
				["llm_info_bar_enabled"] = function() return info_bar_source.info_bar end,
				["llm_info_bar_ready"] = function() return DisplayPolicy.info_bar_ready(info_bar_source) end,
			},
		}
		local display_rows = ManifestMenu.build("llm_display_menu", "LLM", nil, nil, display_ctx, {
			["llm_display_leading"] = function() return {} end,
			["llm_display_remaining"] = function() return {} end,
			["llm_display_trailing"] = function() return rows end,
		})
		local child_rows = ManifestMenu.native_child_rows(display_rows)
		if child_rows == nil then return nil end
		return { items = child_rows, disabled = not enabled or nil }
	end

	group_builders["llm_navigation"] = function()
		local ok_navigation, NavigationSettings = pcall(require, "modules.llm.navigation_settings")
		if not ok_navigation then return end
		-- One choice list per chord: the navigation modifiers held with Up and
		-- Down, and the validation modifiers held with a digit. A chord reads as
		-- the shared key name table names its modifiers (« Ctrl + Maj »), never
		-- as its stored ids (« ctrl+shift »).
		local function chord_label(modifiers, bare_label)
			return #modifiers > 0 and KeyNames.modifiers_label(modifiers, "linux", i18n_safe) or bare_label
		end
		local function chord_rows(current, bare_label, set)
			local rows = {}
			for _, option in ipairs(NavigationSettings.options()) do
				local label = chord_label(option, bare_label)
				local checked = #option == #current
				for index, modifier in ipairs(option) do checked = checked and current[index] == modifier end
				rows[#rows + 1] = {
					label = label,
					checked = checked,
					action = function()
						local called, committed = pcall(set, option)
						if not called or committed ~= true then
							Logger.error(LOG, "Prediction modifier choice was not durably acknowledged.")
							SaveFailure.present(i18n_safe, show_error)
							return false
						end
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						return true
					end,
				}
			end
			return rows
		end
		local arrows_only = i18n_safe("menu.llm.arrows_only")
		local no_modifier = i18n_safe("menu.settings.no_modifier")
		local navigation = NavigationSettings.get_navigation()
		local validation = NavigationSettings.get()
		local definitions = {}
		for _, definition in ipairs(ManifestMenu.get_array("llm_navigation_rows")) do
			if type(definition) == "table" and definition.type == "list"
				and type(definition.i18n) == "string" and definition.i18n ~= ""
				and (definition.id == "llm_nav_modifiers" or definition.id == "llm_val_modifiers") then
				definitions[definition.id] = definition
			end
		end
		local navigation_providers = {
			["llm_nav_modifiers"] = function()
				local definition = definitions.llm_nav_modifiers
				if not definition then return {} end
				return { {
					label = i18n_safe(definition.i18n) .. " — "
						.. chord_label(navigation, arrows_only),
					items = chord_rows(navigation, arrows_only, NavigationSettings.set_navigation),
				} }
			end,
			["llm_val_modifiers"] = function()
				local definition = definitions.llm_val_modifiers
				if not definition then return {} end
				return { {
					label = string.format(i18n_safe(definition.i18n),
						chord_label(validation, no_modifier)),
					items = chord_rows(validation, no_modifier, NavigationSettings.set),
				} }
			end,
		}
		local rows = ManifestMenu.build("llm_navigation_rows", "LLM navigation", nil, nil, ctx, navigation_providers)
		local child_rows = ManifestMenu.native_child_rows(rows)
		if child_rows == nil then return nil end
		return { items = child_rows, disabled = not enabled or nil }
	end

	-- The dialogs the model selector page's transactions open: the menu owns
	-- them, so they never fight the keyboard grab (ui/modal.lua).
	local page_dialogs = {
		prompt = function(title, text, initial, hidden, choices)
			return prompt_text(title, plain_markup(text), initial, hidden, choices)
		end,
		error = function(message, title)
			return show_error(plain_markup(message), title, "Model selector error dialog unavailable.")
		end,
		info = function(title, message)
			return show_info(title, plain_markup(message), "Model selector information dialog unavailable.")
		end,
		confirm = function(title, text)
			return ask_yes_no(title, plain_markup(text), i18n_safe("button.delete"), i18n_safe("button.cancel"))
		end,
	}
	--- Tells the user how a model removal ended: it runs after the page acted.
	--- @param succeeded boolean
	--- @param tag string
	--- @param reason string|nil
	local function deletion_notice(succeeded, tag, reason)
		local Notifier = require("adapters.application_notifier")
		-- A notification caption, not a menu row: it never reaches the renderer.
		local delivered
		if succeeded then
			local caption = i18n_safe("ollama.deleted_title")
			delivered = Notifier.send(string.format(i18n_safe("ollama.model_deleted"), tag),
				{ title = caption, level = "success" })
		else
			local caption = i18n_safe("ollama.delete_fail_title")
			delivered = Notifier.send(string.format(i18n_safe("ollama.delete_error"), tag, tostring(reason)),
				{ title = caption, level = "error" })
		end
		if delivered ~= true then Logger.warn(LOG, "The model-deletion notice for '%s' was not delivered.", tag) end
	end
	--- Removes one installed model after the same confirmation Windows and macOS ask.
	--- @param model string Ollama-native tag.
	--- @param page_current function|nil Exact page projection owner.
	--- @return boolean dispatched
	local function delete_model(model, page_current)
		local function admitted()
			if ctx.paused == true then return false end
			if type(ctx.is_paused) == "function" then
				local ok, paused = pcall(ctx.is_paused)
				if not ok or paused ~= false then return false end
			end
			if page_current == nil then return true end
			local ok, current = pcall(page_current)
			return ok and current == true
		end
		if not admitted() then return false end
		if type(llm.delete_model) ~= "function" then
			Logger.error(LOG, "The AI engine cannot delete models — '%s' was kept.", model)
			return false
		end
		local confirmed = ask_yes_no(i18n_safe("menu.llm.delete_model_title"),
			plain_markup(string.format(i18n_safe("menu.llm.delete_model_body"), model)),
			i18n_safe("button.delete"), i18n_safe("button.cancel"))
		if confirmed ~= true or not admitted() then return false end
		return llm.delete_model(model, function(succeeded, tag, reason)
			deletion_notice(succeeded, tag, reason)
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end) == true
	end
	-- One button opens the model selector page, where the backend and the model
	-- are chosen together (maintainer, 2026-10-27): the backend's emoji, then
	-- the model. The menu lists no model and no API entry. Drawing the button
	-- binds the page to this build's engine, dialogs and refresh.
	providers["llm_model"] = function()
		LlmBackendRows.bind_page(llm, {
			dialogs = page_dialogs, on_changed = ctx.on_menu_changed, delete_model = delete_model,
			context = { paused = ctx.paused, is_paused = ctx.is_paused },
		})
		local row = ManifestMenu.command_row("llm_model_selector_commands", COMMAND.LLM_MODEL_SELECTOR, {
			[COMMAND.LLM_MODEL_SELECTOR] = function() return ctx.webview.show("model_browser") == true end,
		}, {
			["llm_model_selector_caption"] = function() return LlmBackendRows.caption(llm) end,
			["llm_model_selector_ready"] = function()
				return type(ctx.webview) == "table" and type(ctx.webview.show) == "function"
			end,
		})
		if not row then return {} end
		-- The button stays enabled when config.toml refuses writes: the page it
		-- opens greys every backend with that cause, as on Windows and macOS.
		return { row }
	end

	--- The suggestion count row: a generation parameter, the first one on every
	--- driver, with one choice per count from 1 to 10.
	--- @return table|nil row Nil, with the failure logged, when the profile settings cannot load.
	local function suggestion_count_row(generation_origin)
		local ok_profiles, ProfileSettings = pcall(require, "modules.llm.profile_settings")
		if not ok_profiles then
			Logger.error(LOG, "LLM profile settings unavailable — the suggestion count row cannot be built: %s.",
				tostring(ProfileSettings))
			return nil
		end
		local current = ProfileSettings.get(require("config_keys").LEAF.NUM_PREDICTIONS)
		local choices = {}
		for value = 1, 10 do
			-- One key per plural form, the rows macOS and Windows draw.
			local count_key = value == 1 and "menu.llm.prediction_count_label_one"
				or "menu.llm.prediction_count_label_other"
			choices[#choices + 1] = {
				label = string.format(i18n_safe(count_key), value),
				checked = current == value,
				action = function()
					return commit_preset(ProfileSettings, require("config_keys").LEAF.NUM_PREDICTIONS, value, ctx.on_menu_changed, false, "llm.profiles.", generation_origin)
				end,
			}
		end
		return {
			label = string.format(i18n_safe("menu.llm.num_predictions_label"), tostring(current)),
			items = choices,
			disabled = not enabled or nil,
		}
	end

	-- The suggestion count, temperature and context length. The manifest has
	-- declared the last two as features for as long as it has existed and this
	-- driver read them from the canonical defaults with no way to change either —
	-- constants wearing the shape of settings.
	providers["llm_generation"] = function()
		local generation_origin = choice_origin()
		local ok_profiles, ProfileSettings = pcall(require, "modules.llm.profile_settings")
		if not ok_profiles then
			Logger.error(LOG, "LLM profile settings unavailable — generation controls cannot read their current count: %s.",
				tostring(ProfileSettings))
			return {}
		end
		local ok_settings, Settings = pcall(require, "modules.llm.settings")
		if not ok_settings then
			Logger.error(LOG, "LLM settings unavailable — the generation rows cannot be built.")
			return {}
		end
		--- One numeric setting's row with its presets and free entry.
		--- @param setting table { name, key, formatted? }
		--- @return table row
		local function numeric_row(setting)
			local current = Settings.get(setting.name)
			local choices = {}
			for _, value in ipairs(Settings.presets(setting.name)) do
				choices[#choices + 1] = {
					label = tostring(value),
					checked = current == value,
					action = function()
						return commit_preset(Settings, setting.name, value, ctx.on_menu_changed, true, "llm.generation.", generation_origin)
					end,
				}
			end
			-- Free entry beside the presets, so this driver can express any value
			-- macOS's numeric dialog can. Closing the gap the other way — taking
			-- the dialog off macOS and leaving only presets — would have removed a
			-- capability, which is convergence downwards.
			local bounds = Settings.bounds(setting.name)
			if bounds then
				local custom_rows = ManifestMenu.template_rows("llm_numeric_custom_rows", {
					[require("config_keys").COMMAND.LLM_NUMERIC_CUSTOM_VALUE] = function()
						local ok_prompt, Prompt = pcall(require, "ui.numeric_prompt.bridge")
						if not ok_prompt then
							Logger.error(LOG, "No numeric prompt — '%s' can only take a preset.", setting.name)
							return
						end
						local value, save = numeric_setting_request(ctx.on_menu_changed, Settings,
							"modules.llm.settings", setting.name, "llm.generation." .. setting.name)
						if not save then return false end
						Prompt.ask({
							title = i18n_safe(setting.key),
							hint = string.format("%s – %s", tostring(bounds.min), tostring(bounds.max)),
							value = value,
							min = bounds.min,
							max = bounds.max,
							on_save = save,
						}, ctx.webview)
					end,
				})
				for _, row in ipairs(custom_rows or {}) do choices[#choices + 1] = row end
			end

			return {
				label = setting.formatted and string.format(i18n_safe(setting.key), current)
					or (i18n_safe(setting.key) .. " — " .. tostring(current)),
				items = choices,
			}
		end
		local rows = {}
		rows[#rows + 1] = suggestion_count_row(generation_origin)
		for _, setting in ipairs({
			{ name = "min_words", key = "menu.llm.min_words_label", formatted = true },
			{ name = "max_words", key = "menu.llm.max_words_label", formatted = true },
			{ name = "temperature", key = "menu.llm.generation.temperature" },
		}) do
			rows[#rows + 1] = numeric_row(setting)
		end
		local context_rows = { numeric_row({ name = "context_length", key = "menu.llm.generation.context_length" }) }
		--- Reads current group, pause and prediction-count facts before delivery.
		--- @return boolean ready
		local function ready()
			local count = ProfileSettings.get(require("config_keys").LEAF.NUM_PREDICTIONS)
			return ctx.paused ~= true and type(llm.is_enabled) == "function" and llm.is_enabled() == true
				and type(count) == "number" and count >= 2
		end
		local generation_ctx = {
			commands = {
				[require("config_keys").COMMAND.LLM_AUTO_RAISE_TEMPERATURE] = function()
					if not ready() then return false end
					if Settings.set(require("config_keys").LEAF.AUTO_RAISE_TEMP, not Settings.get(require("config_keys").LEAF.AUTO_RAISE_TEMP)) ~= true then return false end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
			},
			state_getters = {
				["llm_auto_raise_enabled"] = function() return Settings.get(require("config_keys").LEAF.AUTO_RAISE_TEMP) end,
				["llm_auto_raise_ready"] = ready,
			},
		}
		local generation_rows = ManifestMenu.build("llm_generation_menu", "LLM", nil, nil, generation_ctx, {
			["llm_generation_values"] = function() return rows end,
			["llm_generation_context_values"] = function() return context_rows end,
		})
		-- Whether a navigation or Escape clears the AI's typing context, the row
		-- Windows and macOS show in the same submenu.
		local function generation_ready()
			return ctx.paused ~= true and type(llm.is_enabled) == "function" and llm.is_enabled() == true
		end
		local RESET_ON_NAV = require("config_keys").LEAF.RESET_ON_NAV
		local reset_rows = ManifestMenu.build("llm_generation_reset_navigation", "LLM", nil, nil, {
			commands = {
				[COMMAND.LLM_RESET_ON_NAV] = function()
					if not generation_ready() then return false end
					if Settings.set(RESET_ON_NAV, not Settings.get(RESET_ON_NAV)) ~= true then return false end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
			},
			state_getters = {
				["llm_reset_on_nav_checked"] = function() return Settings.get(RESET_ON_NAV) end,
				["llm_generation_ready"] = generation_ready,
			},
		}, {})
		-- Both declared blocks are rendered by their own manifest keys; they go
		-- back to the llm_menu renderer as DATA, with their callbacks kept.
		local built = {}
		for _, row in ipairs(generation_rows) do built[#built + 1] = row end
		for _, row in ipairs(reset_rows) do built[#built + 1] = row end
		local data = ManifestMenu.native_child_rows(built)
		if data == nil then
			Logger.error(LOG, "LLM generation rows could not be handed back as row data — rows omitted.")
			return {}
		end
		return data
	end

	-- The category switch, the submenu's first row: appindicator binds item.fn
	-- only on a row with no submenu, so the parent cannot carry it.
	local llm_ctx = {}
	for key, value in pairs(ctx) do llm_ctx[key] = value end
	llm_ctx.commands = {}
	for key, value in pairs(ctx.commands or {}) do llm_ctx.commands[key] = value end
	local Preferences = require("infra.llm_preferences")
	local function toggle_ready()
		return type(llm.toggle) == "function" and ctx.paused ~= true and Preferences.admit() == true
	end
	-- The AI rows that write config.toml: greyed, and their retained clicks
	-- refused, while paused or while the configuration refuses writes.
	local function scope_ready()
		return Preferences.admit() == true and ctx.paused ~= true
	end
	-- A configuration saved by a newer version names its own cause on those rows.
	local function newer_schema()
		return require("config_migrate").read_only_status(require("infra.config_paths").config("config.toml")) == "newer"
	end
	-- So does one too old for this build to migrate.
	local function older_schema()
		return require("config_migrate").read_only_status(require("infra.config_paths").config("config.toml")) == "unsupported"
	end
	-- The restore alone: the AI menu's clear row was retired.
	llm_ctx.commands[require("config_keys").COMMAND.SCOPE_RESTORE] = function()
		-- A retained row rechecks what greyed it when it was built.
		if not scope_ready() then
			Logger.warn(LOG, "AI settings restore refused: %s.", ctx.paused == true and "the script is paused"
				or "the configuration is protected from writes")
			return false
		end
		local committed = require("infra.llm_scope").apply("recommended", ctx.paused)
		if committed and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return committed
	end
	llm_ctx.commands[require("config_keys").COMMAND.LLM_TEST_PREDICTION] = function()
		return llm.test_prediction()
	end
	llm_ctx.commands[require("config_keys").COMMAND.LLM_TOGGLE] = function()
		if not toggle_ready() then return false end
		if llm.toggle then llm.toggle(ctx.on_menu_changed) end
		if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
	end
	llm_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do llm_ctx.state_getters[key] = value end
	llm_ctx.state_getters["llm_enabled"] = function() return enabled end
	-- The same source/scope admission greys the row and fences retained clicks.
	llm_ctx.state_getters["llm_toggle_ready"] = toggle_ready
	llm_ctx.state_getters["llm_scope_ready"] = scope_ready
	llm_ctx.state_getters["config_newer_schema"] = newer_schema
	llm_ctx.state_getters["config_older_schema"] = older_schema

	local rendered = ManifestMenu
		and ManifestMenu.build("llm_menu", "LLM", nil, group_builders, llm_ctx, providers)
		or {}
	for _, row in ipairs(rendered) do items[#items + 1] = row end

	-- The parent carries the same tick as the switch inside, for a user scanning
	-- the top level; it cannot be clicked, which is why the switch is a row.
	return NativeParent.finish(parent, items)
end

M.build = _build_llm

return M
