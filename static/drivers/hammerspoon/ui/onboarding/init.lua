--- ui/onboarding/init.lua

--- ==============================================================================
--- MODULE: Onboarding Wizard
--- DESCRIPTION:
--- First-launch setup wizard guiding the user through the initial configuration
--- of Ergopti via a sequence of native Hammerspoon dialogs.
---
--- FEATURES & RATIONALE:
--- 1. Zero-dependency UI: Uses only hs.alert, hs.dialog, and hs.chooser — no
---    WebView, no external renderer. This keeps the wizard functional even
---    before the main UI stack is initialised.
--- 2. Sequential callbacks: Each step calls the next in its own callback, so
---    the main thread is never blocked.
--- 3. Locale-aware: The user picks their language in step 1 and all subsequent
---    steps immediately reflect that choice via i18n.set_locale().
--- 4. Atomic write: All collected answers are flushed to config.toml in a
---    single toml_writer.batch_write() call at the end, then hs.reload().
--- ==============================================================================

local M = {}

local i18n         = require("lib.i18n")
local toml_writer  = require("lib.toml_writer")
local notifications = require("lib.notifications")

local LOG = "onboarding"




-- ============================================================
-- ============================================================
-- ======= 1/ Constants and locale definitions =======
-- ============================================================
-- ============================================================

-- Ordered alphabetically by language code, shown in the chooser
local LOCALES_ORDERED = {
	{ code = "de", label = "🇩🇪  Deutsch"  },
	{ code = "en", label = "🇬🇧  English"  },
	{ code = "es", label = "🇪🇸  Español"  },
	{ code = "fr", label = "🇫🇷  Français" },
	{ code = "zh", label = "🇨🇳  中文"     },
}

local DEFAULT_LOCALE    = "en"
local DEFAULT_MAGIC_KEY = "★"

-- hs.settings key used to remember that the wizard has already run once
local SETTINGS_COMPLETED_KEY = "ergopti.onboarding.completed"




-- ============================================================
-- ============================================================
-- ======= 2/ Internal wizard state =======
-- ============================================================
-- ============================================================

-- Accumulated answers collected across wizard steps; written to disk at the end
local _answers = {
	locale      = DEFAULT_LOCALE,
	use_ergopti = true,
	magic_key   = DEFAULT_MAGIC_KEY,
	use_metrics = true,
	use_gestures = true,
}

-- Path to config.toml, set when M.run() or M.run_from_menu() is called
local _config_path = nil




-- ============================================================
-- ============================================================
-- ======= 3/ Helper utilities =======
-- ============================================================
-- ============================================================


--- Converts a boolean to the TOML-compatible string "true"/"false".
--- @param value boolean The boolean to convert.
--- @return string The lowercase string representation.
local function bool_to_str(value)
	return value and "true" or "false"
end


--- Builds the list of update records consumed by toml_writer.batch_write().
--- @return table[] Ordered list of {section, key, value} records.
local function build_updates()
	return {
		{ section = "Script",    key = "Locale",          value = _answers.locale                          },
		{ section = "Layout",    key = "ErgoptiBase",     value = bool_to_str(_answers.use_ergopti)        },
		{ section = "Layout",    key = "ErgoptiAltGr",    value = bool_to_str(_answers.use_ergopti)        },
		{ section = "Layout",    key = "ErgoptiPlus",     value = bool_to_str(_answers.use_ergopti)        },
		{ section = "Hotstrings", key = "MagicKey",       value = _answers.magic_key                       },
		{ section = "Metrics",   key = "metrics_enabled", value = bool_to_str(_answers.use_metrics)        },
		{ section = "Gestures",  key = "Enabled",         value = bool_to_str(_answers.use_gestures)       },
	}
end




-- ============================================================
-- ============================================================
-- ======= 4/ Wizard steps =======
-- ============================================================
-- ============================================================


--- Forward declaration so steps can reference each other via closures
local step1_language, step2_layout, step3_magic_key, step4_metrics, step5_gestures, step_finish


--- Step 5 — Gestures: asks the user whether to enable gesture support.
step5_gestures = function()
	local title = i18n.get("onboarding.gestures.title")
	local msg   = i18n.get("onboarding.gestures.desc")
	local yes   = i18n.get("onboarding.btn.yes")
	local no    = i18n.get("onboarding.btn.no")

	local answer = hs.dialog.blockAlert(title, msg, yes, no)
	_answers.use_gestures = (answer == yes)
	step_finish()
end


--- Step 4 — Metrics: asks the user whether to enable typing-metrics collection.
step4_metrics = function()
	local title = i18n.get("onboarding.metrics.title")
	local msg   = i18n.get("onboarding.metrics.desc")
	local yes   = i18n.get("onboarding.btn.yes")
	local no    = i18n.get("onboarding.btn.no")

	local answer = hs.dialog.blockAlert(title, msg, yes, no)
	_answers.use_metrics = (answer == yes)
	step5_gestures()
end


--- Step 3 — Magic key: lets the user pick the hotstring trigger character.
step3_magic_key = function()
	local title  = i18n.get("onboarding.magic_key.title")
	local msg    = i18n.get("onboarding.magic_key.desc")
	local ok_lbl = i18n.get("onboarding.btn.ok")
	local cancel = i18n.get("onboarding.btn.cancel")

	local result, text = hs.dialog.textPrompt(title, msg, DEFAULT_MAGIC_KEY, ok_lbl, cancel)
	if result == ok_lbl and text and text ~= "" then
		_answers.magic_key = text
	end
	-- Proceed even on cancel — keep the default value
	step4_metrics()
end


--- Step 2 — Layout: asks whether the user wants the Ergopti keyboard layout.
step2_layout = function()
	local title = i18n.get("onboarding.layout.title")
	local msg   = i18n.get("onboarding.layout.desc")
	local yes   = i18n.get("onboarding.btn.yes")
	local no    = i18n.get("onboarding.btn.no")

	local answer = hs.dialog.blockAlert(title, msg, yes, no)
	_answers.use_ergopti = (answer == yes)
	step3_magic_key()
end


--- Step 1 — Language: presents a chooser with the five supported locales.
--- Calls i18n.set_locale() immediately on selection so the rest of the wizard
--- uses the chosen language without requiring a reload.
step1_language = function()
	local chooser_items = {}
	for _, locale in ipairs(LOCALES_ORDERED) do
		table.insert(chooser_items, {
			text    = locale.label,
			subText = locale.code,
			code    = locale.code,
		})
	end

	local chooser = hs.chooser.new(function(selection)
		local code = (selection and selection.code) or DEFAULT_LOCALE
		_answers.locale = code
		-- Apply locale in-memory only — avoid reloading mid-wizard
		i18n.set_locale_no_reload(code)
		step2_layout()
	end)

	chooser:placeholderText(i18n.get("onboarding.language.placeholder"))
	chooser:choices(chooser_items)
	chooser:searchSubText(false)
	chooser:show()
end


--- Writes all collected answers to config.toml and reloads Hammerspoon.
step_finish = function()
	local ok, err = pcall(function()
		toml_writer.batch_write(_config_path, build_updates())
	end)

	if not ok then
		-- Surface the failure loudly — the wizard cannot complete silently
		hs.dialog.blockAlert(
			i18n.get("onboarding.error.title"),
			i18n.get("onboarding.error.write_failed") .. "\n\n" .. tostring(err),
			i18n.get("onboarding.btn.ok")
		)
		return
	end

	hs.settings.set(SETTINGS_COMPLETED_KEY, true)
	notifications.notify(i18n.get("onboarding.done.title"), i18n.get("onboarding.done.body"))

	-- Small delay so the notification is visible before the reload wipes the screen
	hs.timer.doAfter(1.5, function()
		hs.reload()
	end)
end




-- ============================================================
-- ============================================================
-- ======= 5/ Public API =======
-- ============================================================
-- ============================================================


--- Returns true when the onboarding wizard should run.
--- The wizard must run whenever config.toml does not yet exist on disk.
--- @param config_path string Absolute path to the user's config.toml.
--- @return boolean True if the wizard should be displayed.
function M.should_run(config_path)
	if type(config_path) ~= "string" or config_path == "" then
		return false
	end
	return not hs.fs.attributes(config_path)
end


--- Starts the onboarding wizard on first launch.
--- Resets all collected answers to their defaults before beginning so that
--- repeated calls from the same session always start from a clean slate.
--- @param config_path string Absolute path where config.toml should be written.
function M.run(config_path)
	if type(config_path) ~= "string" or config_path == "" then
		hs.dialog.blockAlert("Ergopti — Onboarding", "config_path is missing.", "OK")
		return
	end

	_config_path = config_path

	-- Reset answers so a re-run in the same session starts fresh
	_answers = {
		locale       = DEFAULT_LOCALE,
		use_ergopti  = true,
		magic_key    = DEFAULT_MAGIC_KEY,
		use_metrics  = true,
		use_gestures = true,
	}

	step1_language()
end


--- Starts the onboarding wizard regardless of whether config.toml exists.
--- Useful when the user triggers the wizard manually from a menu item.
--- @param config_path string Absolute path to the user's config.toml.
function M.run_from_menu(config_path)
	-- Identical behaviour to M.run() — the distinction exists at the call site
	-- (the caller decides when to invoke this rather than M.run())
	M.run(config_path)
end


return M
