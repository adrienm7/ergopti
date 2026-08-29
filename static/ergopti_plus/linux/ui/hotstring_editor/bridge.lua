--- ui/hotstring_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Hotstring Editor
--- DESCRIPTION:
--- Hosts _shared/ui/hotstring_editor/ — the window where a user writes their own
--- hotstrings. Bridge name: "hsEditor".
---
--- WHY THIS FILE WAS REWRITTEN RATHER THAN EXTENDED:
--- The window is ONE shared HTML/JS application; both Lua drivers host the same
--- files. Everything a user sees is therefore identical by construction, and the
--- only thing that can differ is the bridge. This one differed completely.
---
--- It answered `ready` with `{hotstrings, groups, config_dir}`. The shared script
--- reads `{sections, trigger_char, star, compact_view, auto_close,
--- default_section, default_priority, open_mode}` and not one of the three keys
--- it was sent — `window.initData` assigns the payload to `D` and `render()` walks
--- `D.sections`, which was nil. **The editor opened empty on Linux, every time.**
--- It also called `state.config.get_all_hotstrings()`, a function that does not
--- exist on this driver, through a `:` on a module of flat functions.
---
--- It had no branch for `save_pref` or `window_focus`, so the compact-view toggle
--- and the focus tracking silently did nothing. And it dispatched on `refresh`,
--- `delete`, `test` and `duplicate` — four actions the shared UI never sends. The
--- `delete` branch persisted to disk and could not be reached, which is exactly
--- the kind of thing that answers "does Linux support deleting a hotstring?" with
--- a yes it has not earned.
---
--- The contract below is macOS's, because macOS is the driver whose editor works.
---
--- FEATURES & RATIONALE:
--- 1. One file, one group. Personal hotstrings live in `personal.toml` inside the
---    hotstrings config directory, which the loader turns into the `personal`
---    category the menu already shows. Writing them anywhere else would produce a
---    category the rest of the driver does not know about.
--- 2. Whole-file writes. The UI sends its entire model on every save — that is
---    what `persist()` in the shared script builds — so the file is replaced, not
---    merged. Merging would resurrect entries the user just deleted.
--- 3. Preferences persist. `compact_view` and the rest come back to a window that
---    reopens the way it was left; a preference that resets is a preference the
---    user sets once and then works around.
--- ==============================================================================

local M = {}
M.bridge_name = "hsEditor"

local Logger = require("logger.shim")
local Storage = require("adapters.storage")
local MagicKey = require("modules.hotstrings.magic_key")

local LOG = "bridge.hsEditor"

-- The file personal hotstrings live in, inside the hotstrings config directory.
-- The stem IS the category id: the loader groups by file stem, so this name is
-- what makes these entries the "personal" category the menu renders.
local PERSONAL_FILE = "personal.toml"

-- The category the shared priority table scores personal hotstrings under, used
-- for the placeholder the priority field shows when an entry inherits.
local PERSONAL_CATEGORY = "personal"

-- Preferences the editor asks us to remember, and their defaults. Declared as a
-- set so an unknown key from the UI is refused rather than written: the bridge is
-- a storage boundary and the page is the least trusted thing on the other side.
local PREF_DEFAULTS = {
	compact_view    = false,
	auto_close      = false,
	default_section = "",
}

-- Where preferences live. Namespaced so they cannot collide with the hotstring
-- category toggles, which share the same storage.
local PREF_PREFIX = "hotstring_editor."

-- The app name this bridge's page lives under in _shared/ui/. Named once: it is
-- both the directory the HTML is read from and the key eval_js pushes to, and a
-- second spelling of it is what made the settings window open on an error page.
local APP_NAME = "hotstring_editor"

-- How the window was opened, decided by whoever opened it. The shared page sends
-- `ready` with an empty data object, so it cannot tell the host anything here —
-- reading the mode off the message meant "shortcut" was unreachable and the
-- quick-add flow the page gates on it could never run.
local _pending_mode = "menu"

-- Lazily-loaded codecs. Required at call time rather than at load so a driver
-- missing the codec still boots and reports the failure when the window opens.
local _writer, _reader = nil, nil

--- @return table|nil
local function get_writer()
	if _writer then return _writer end
	local ok, mod = pcall(require, "toml_codec.writer")
	if ok and type(mod) == "table" and type(mod.write) == "function" then _writer = mod end
	return _writer
end

--- @return table|nil
local function get_reader()
	if _reader then return _reader end
	local ok, mod = pcall(require, "toml_codec.reader")
	if ok and type(mod) == "table" and type(mod.parse) == "function" then _reader = mod end
	return _reader
end





-- =========================================
-- =========================================
-- ======= 1/ Where the file lives =========
-- =========================================
-- =========================================

--- The absolute path of the personal hotstrings file.
---
--- Through the config module rather than rebuilding the path here: it is the
--- module that decides where a user's hotstrings live, and a second opinion about
--- that is a second place for them to end up.
--- @param state table Daemon state.
--- @return string|nil
local function personal_path(state)
	local config = state and state.config
	if type(config) ~= "table" or type(config.get_config_dir) ~= "function" then
		Logger.error(LOG, "No hotstrings config module in the daemon state — the editor cannot save.")
		return nil
	end
	-- A DOT, not a colon. These are flat module functions; calling them with `:`
	-- passes the module as the first argument, which is the bug that made every
	-- category read as enabled in the settings-window bridge.
	local dir = config.get_config_dir()
	if type(dir) ~= "string" or dir == "" then
		Logger.error(LOG, "The hotstrings config directory is unset — the editor cannot save.")
		return nil
	end
	return dir .. "/" .. PERSONAL_FILE
end

--- Reads a stored preference, falling back to its declared default.
--- @param key string
--- @return boolean|string
local function pref(key)
	local stored = Storage.get(PREF_PREFIX .. key, nil)
	if stored == nil then return PREF_DEFAULTS[key] end
	return stored
end

--- Reads one editor preference.
---
--- Published so the tray menu reads the same store the page does. Both drivers
--- expose these two preferences as menu rows; on this one they were readable
--- only from inside the page, which sends `save_pref` for the compact-view
--- toggle alone — so "default section" and "close after adding" were frozen at
--- their declared defaults with no way to reach them.
--- @param key string One of the PREF_DEFAULTS keys.
--- @return boolean|string|nil
function M.get_pref(key)
	if PREF_DEFAULTS[key] == nil then
		Logger.error(LOG, "get_pref(): '%s' is not an editor preference.", tostring(key))
		return nil
	end
	return pref(key)
end

--- Writes one editor preference.
--- @param key string
--- @param value boolean|string
--- @return boolean
function M.set_pref(key, value)
	if PREF_DEFAULTS[key] == nil then
		Logger.error(LOG, "set_pref(): '%s' is not an editor preference.", tostring(key))
		return false
	end
	-- Typed against the declared default rather than accepted as-is: a string
	-- where a boolean belongs is truthy in Lua, so "false" would read as on.
	if type(value) ~= type(PREF_DEFAULTS[key]) then
		Logger.error(LOG, "set_pref(): '%s' expects a %s, got %s.",
			key, type(PREF_DEFAULTS[key]), type(value))
		return false
	end
	local ok = Storage.set(PREF_PREFIX .. key, value)
	Logger.debug(LOG, "Editor preference %s: %s.", key, tostring(value))
	return ok
end





-- =========================================
-- =========================================
-- ======= 2/ Reading, for the UI ==========
-- =========================================
-- =========================================

--- Builds the payload `window.initData` reads.
---
--- Every key here is one the shared script destructures. That is the whole
--- correctness condition, and the reason the previous payload — three keys, none
--- of them read — produced an empty window while every branch of this file looked
--- like it worked.
--- @param state table Daemon state.
--- @param open_mode string|nil "menu" or "shortcut".
--- @return table
local function build_payload(state, open_mode)
	local sections = {}

	local path = personal_path(state)
	local reader = get_reader()
	if path and reader then
		local ok, parsed = pcall(reader.parse, path)
		if ok and type(parsed) == "table" and type(parsed.sections_order) == "table" then
			for _, name in ipairs(parsed.sections_order) do
				-- "-" is the menu's separator marker in a sections_order list. It is
				-- not a section, and rendering it would put an unnamed empty group in
				-- the editor.
				local sec = name ~= "-" and type(parsed.sections) == "table" and parsed.sections[name] or nil
				if type(sec) == "table" then
					local entries = {}
					for _, e in ipairs(type(sec.entries) == "table" and sec.entries or {}) do
						entries[#entries + 1] = {
							trigger           = type(e.trigger) == "string" and e.trigger or "",
							output            = type(e.output) == "string" and e.output or "",
							is_word           = e.is_word == true,
							auto_expand       = e.auto_expand == true,
							is_case_sensitive = e.is_case_sensitive == true,
							final_result      = e.final_result == true,
							is_case_sensitive_strict = e.is_case_sensitive_strict == true,
							-- Omitted rather than defaulted when absent: nil means "inherit
							-- the source default", and writing a number here would silently
							-- pin every entry to whatever that default happened to be.
							priority          = type(e.priority) == "number" and e.priority or nil,
						}
					end
					sections[#sections + 1] = {
						name        = name,
						description = type(sec.description) == "string" and sec.description or name,
						entries     = entries,
					}
				end
			end
		end
	end

	-- The placeholder the priority field shows for an entry that inherits. From
	-- the shared table, never a literal: the number lives in
	-- _shared/modules/hotstrings/priority.json and a copy here would be a second
	-- answer to a question with one.
	local default_priority = nil
	local ok_prio, Priority = pcall(require, "hotstring_priority")
	if ok_prio and type(Priority.source_priority) == "function" then
		local ok_value, value = pcall(Priority.source_priority, PERSONAL_CATEGORY)
		if ok_value and type(value) == "number" then default_priority = value end
	end

	local star = MagicKey.default()
	return {
		sections         = sections,
		-- The key in effect, which is the user's if they chose one. `star` stays
		-- the shipped character: the UI uses it for the literal it inserts from its
		-- symbol palette, and that must not drift when someone rebinds the trigger.
		trigger_char     = MagicKey.get(),
		star             = star,
		compact_view     = pref("compact_view") == true,
		auto_close       = pref("auto_close") == true,
		default_section  = pref("default_section"),
		default_priority = default_priority,
		open_mode        = open_mode or "menu",
	}
end





-- =========================================
-- =========================================
-- ======= 3/ Writing, from the UI =========
-- =========================================
-- =========================================

--- Persists the editor's whole model.
---
--- The shared script's `persist()` sends its ENTIRE state on every save, so this
--- replaces the file rather than merging into it. Merging would bring back every
--- entry the user had just deleted, and the deletion would appear to work until
--- the next restart.
--- @param state table Daemon state.
--- @param data table { sections_order, sections }.
--- @return boolean
local function save_all(state, data)
	local path = personal_path(state)
	local writer = get_writer()
	if not path or not writer then return false end
	if type(data) ~= "table" or type(data.sections) ~= "table" then
		Logger.error(LOG, "Save rejected: the payload carries no sections.")
		return false
	end

	local order = type(data.sections_order) == "table" and data.sections_order or {}
	local toml = {
		meta           = { description = "Personal" },
		sections_order = {},
		sections       = {},
	}

	for _, name in ipairs(order) do
		local sec = data.sections[name]
		if type(sec) == "table" then
			local entries = {}
			for _, e in ipairs(type(sec.entries) == "table" and sec.entries or {}) do
				if type(e.trigger) == "string" and e.trigger ~= "" then
					entries[#entries + 1] = {
						trigger           = e.trigger,
						output            = type(e.output) == "string" and e.output or "",
						is_word           = e.is_word == true,
						auto_expand       = e.auto_expand == true,
						is_case_sensitive = e.is_case_sensitive == true,
						final_result      = e.final_result == true,
						is_case_sensitive_strict = e.is_case_sensitive_strict == true,
						priority          = type(e.priority) == "number" and e.priority or nil,
					}
				end
			end
			toml.sections_order[#toml.sections_order + 1] = name
			toml.sections[name] = {
				description = type(sec.description) == "string" and sec.description or name,
				entries     = entries,
			}
		end
	end

	local ok, err = writer.write(path, toml)
	if not ok then
		Logger.error(LOG, "Could not write '%s': %s.", path, tostring(err))
		return false
	end

	local count = 0
	for _, sec in pairs(toml.sections) do count = count + #sec.entries end
	Logger.success(LOG, "Personal hotstrings saved (%d section(s), %d entrie(s)).",
		#toml.sections_order, count)

	-- Reload so the engine matches what the user just wrote. Without this the
	-- window says "saved", the file says so too, and typing the trigger does
	-- nothing until the daemon is restarted.
	local config = state and state.config
	if type(config) == "table" and type(config.reload) == "function" then
		local ok_reload = pcall(config.reload)
		if not ok_reload then
			Logger.warn(LOG, "Saved, but the reload failed — the new hotstrings need a restart.")
		end
	end
	return true
end





-- =========================================
-- =========================================
-- ======= 4/ Pushing the payload ==========
-- =========================================
-- =========================================

--- Records how the next window opening should be presented to the page.
---
--- Called by whoever opens the editor. "shortcut" makes the page jump straight
--- to the default section's add-entry field; "menu" opens it normally.
--- @param mode string "menu" or "shortcut".
function M.set_pending_mode(mode)
	if mode ~= "menu" and mode ~= "shortcut" then
		Logger.error(LOG, "set_pending_mode(): '%s' is not an open mode.", tostring(mode))
		return
	end
	_pending_mode = mode
	Logger.debug(LOG, "Editor open mode: %s.", mode)
end

--- Translates a key, falling back to the key itself.
--- @param key string
--- @return string
local function i18n_label(key)
	local ok, i18n = pcall(require, "infra.i18n")
	if not ok or type(i18n.get) ~= "function" then return key end
	local value = i18n.get(key)
	return (type(value) == "string" and value ~= "") and value or key
end

--- Shows a message inside the editor window.
---
--- The page defines showAlert (script.js:183) and that is the only channel this
--- driver has into it — there is no native notification path here, and a failure
--- that reaches only the log is a failure the user never learns about.
--- @param message string Already translated.
--- @return boolean
function M.show_alert(message)
	local ok_json, json_mod = pcall(require, "json")
	local ok_mgr, Manager = pcall(require, "ui.webview_manager")
	if not ok_json or not ok_mgr or type(Manager.eval_js) ~= "function" then
		Logger.error(LOG, "%s", tostring(message))
		return false
	end
	local ok_enc, encoded = pcall(json_mod.encode, tostring(message))
	if not ok_enc then
		Logger.error(LOG, "%s", tostring(message))
		return false
	end
	return Manager.eval_js(APP_NAME, "if(window.showAlert)showAlert(" .. encoded .. ")")
end

--- Pushes the payload into the page by calling its own entry point.
---
--- The page reveals `#app` from inside window.initData and nowhere else, so this
--- is not one way of delivering the data — it is the only one.
--- @param state table Daemon state.
--- @return boolean True when the push reached a live webview.
function M.push_init(state)
	local ok_json, json_mod = pcall(require, "json")
	if not ok_json or type(json_mod.encode) ~= "function" then
		Logger.error(LOG, "Cannot push initData(): the shared json module is unavailable — the editor stays on its loading screen.")
		return false
	end

	local ok_payload, encoded = pcall(function()
		return json_mod.encode(build_payload(state, _pending_mode))
	end)
	if not ok_payload or type(encoded) ~= "string" then
		Logger.error(LOG, "Cannot push initData(): payload encoding failed (%s).", tostring(encoded))
		return false
	end

	local ok_mgr, Manager = pcall(require, "ui.webview_manager")
	if not ok_mgr or type(Manager.eval_js) ~= "function" then
		Logger.error(LOG, "Cannot push initData(): webview_manager.eval_js is unavailable.")
		return false
	end

	-- Guarded on the page side too, exactly as macOS guards it: a push that
	-- arrives before the function is defined would throw inside the webview,
	-- where nothing on this side would ever see it.
	local pushed = Manager.eval_js(APP_NAME, "if(window.initData) window.initData(" .. encoded .. ")")
	if pushed then
		Logger.success(LOG, "Hotstring editor initialised (%d byte(s), mode '%s').", #encoded, _pending_mode)
	else
		Logger.warn(LOG, "The editor reported ready but its window is gone — initData() not pushed.")
	end

	-- One shortcut opening must not make every later menu opening behave like a
	-- shortcut one.
	_pending_mode = "menu"
	return pushed
end




-- =========================================
-- =========================================
-- ======= 5/ Dispatch =====================
-- =========================================
-- =========================================

--- Handles an incoming JS message.
--- @param payload any String or table from host_bridge.js.
--- @param state table Daemon state.
--- @return any|nil Response to send back to JS.
function M.on_message(payload, state)
	-- The shared script sends { action, data }. A bare string reaches here only
	-- from the host shim's own lifecycle messages.
	local action, data
	if type(payload) == "string" then
		action, data = payload, {}
	elseif type(payload) == "table" then
		action = payload.action
		data = type(payload.data) == "table" and payload.data or {}
	else
		return nil
	end

	if action == "ready" then
		Logger.info(LOG, "Hotstring editor ready — sending the personal set.")
		-- PUSHED, not returned. The page has no reader for a bridge response: it
		-- reveals `#app` (display:none in the markup) only from inside
		-- `window.initData`, at script.js:1376, the way macOS calls it. Returning
		-- the payload left the editor on "Chargement…" for ever — every entry, every
		-- section and the Add button all behind a div nothing ever unhid.
		--
		-- The mode is the host's to decide, not the page's: script.js sends
		-- `ready` with an empty data object, so `data.open_mode` was always nil and
		-- "shortcut" could never be reached. Whoever opens the window sets it.
		M.push_init(state)
		return nil
	end

	if action == "save" then
		local saved = save_all(state, data)
		if not saved then
			-- The page flashes its "saved" toast whatever this returns — it does not
			-- read bridge responses — so a failed write was visible only as a log
			-- line the user never sees, and their edits vanished at the next restart
			-- with a confirmation on screen saying otherwise. macOS raises a native
			-- notification here; this driver's channel into the page is the alert
			-- the shared script already defines.
			M.show_alert(i18n_label("editor.hotstrings.save_error"))
		end
		return { saved = saved }
	end

	if action == "save_pref" then
		local key = data.key
		if PREF_DEFAULTS[key] == nil then
			-- Refused rather than stored. The page is the least trusted input the
			-- daemon has, and an unbounded key/value write into the same storage the
			-- category toggles use is how a UI bug becomes a corrupted config.
			Logger.warn(LOG, "Refusing unknown editor preference '%s'.", tostring(key))
			return { saved = false }
		end
		Storage.set(PREF_PREFIX .. key, data.value)
		Logger.debug(LOG, "Editor preference '%s' = %s.", tostring(key), tostring(data.value))
		return { saved = true }
	end

	if action == "window_focus" then
		-- The editor asks the daemon to stop expanding while the user types INTO
		-- it. Without this, writing a hotstring whose trigger already exists fires
		-- that hotstring inside the editor's own text field.
		local focused = data.focused ~= false
		if type(state) == "table" then state.editor_focused = focused end
		Logger.debug(LOG, "Editor focus: %s.", tostring(focused))
		return { ok = true }
	end

	if action == "close" then
		Logger.info(LOG, "Hotstring editor closed.")
		return nil
	end

	Logger.debug(LOG, "Unhandled editor action: %s.", tostring(action))
	return nil
end

return M
