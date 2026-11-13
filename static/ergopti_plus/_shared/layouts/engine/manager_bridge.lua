--- _shared/layouts/engine/manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (Shared)
--- DESCRIPTION:
--- The part of hosting the layout manager page (_shared/ui/layout_manager)
--- that macOS and Linux do the same way: which messages the page may send,
--- what each one is allowed to touch, and the state pushed back after every
--- refresh and operation. The window itself (WKWebView, WebKitGTK) stays with
--- each driver; the Windows host applies the same rules in
--- windows/layouts/ui/layout_manager/init.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Allowlist: a page message is an action of M.ACTIONS or nothing. Install
---    and update name a layout of the catalogue the page was shown; uninstall
---    and select an installed one; open_homepage only opens the https homepage
---    the catalogue gives for that layout, never a URL the page sends.
--- 2. One state shape for the three drivers:
---    { platform, shortcut_menu_path, index, source, error, installed, provided,
---      builtin, active, busy, result, record_error }, so the page decides the
---    rows once.
--- 3. The unified layout editor mounted in the page opens and saves its files
---    through source_open and source_save (layouts/engine/composer/source_store.lua bounds
---    them); initData says whether this host offers them.
--- 4. The editor applies a source's navigation layer with nav_save {text}: the
---    host's apply_nav runs the navigation layer editor's own save (validation
---    on every OS, exact-byte publish, regeneration) and answers navResult.
--- 5. « Emulate without installing » (composer_emulate {source, keylayout
---    [, emulation]}): the registry stores the source for the layout emulation
---    alone, then the host's emulate port makes the composed layout the
---    emulated one and reloads the engine. Nothing is installed in the system.
--- 6. A menu row opens the window straight on the editor (controller.open_editor):
---    the page receives sourceData as if its « Editor » button had asked.
--- 7. PURE Lua: the driver injects the layout registry client, the push to the
---    page, the strings, the URL opener and the window close.
--- ==============================================================================

local M = {}

--- The only actions the page may send (the page declares the same list).
M.ACTIONS = {
	ready = true,
	refresh = true,
	install = true,
	update = true,
	uninstall = true,
	select = true,
	open_homepage = true,
	close = true,
	composer_open = true,
	composer_save = true,
	composer_remove = true,
	composer_emulate = true,
	source_open = true,
	source_save = true,
	source_pick = true,
	nav_save = true,
}

-- The extension file both Lua drivers load as a layout's shortcut menu; the
-- page counts it and never derives it from the platform.
M.SHORTCUT_MENU_PATH = "shortcuts/menu.lua"

-- A registry id: the rule of tools/build/build-layouts-index.cjs.
local ID_PATTERN = "^[a-z][a-z0-9_]*$"





-- ========================
-- ========================
-- ======= 1/ State =======
-- ========================
-- ========================

--- The entry of an id in a decoded index, or nil.
--- @param index table|nil
--- @param id string
--- @return table|nil
local function index_entry(index, id)
	for _, entry in ipairs(type(index) == "table" and type(index.layouts) == "table" and index.layouts or {}) do
		if type(entry) == "table" and entry.id == id then return entry end
	end
	return nil
end

--- The state the page renders.
--- @param snapshot table The registry client's snapshot.
--- @param result table|nil The last operation's result.
--- @return table
function M.page_state(snapshot, result)
	return {
		platform = snapshot.platform,
		shortcut_menu_path = M.SHORTCUT_MENU_PATH,
		index = snapshot.index,
		source = snapshot.source,
		error = snapshot.error,
		installed = snapshot.installed or {},
		provided = snapshot.provided or {},
		builtin = snapshot.builtin or {},
		active = snapshot.active or "",
		busy = snapshot.busy,
		result = result,
		record_error = snapshot.record_error,
	}
end





-- =============================
-- =============================
-- ======= 2/ Controller =======
-- =============================
-- =============================

--- Tells the host that a layout changed, so a changed emulated layout reloads.
--- @param deps table
--- @param id string The changed layout's id.
local function layout_changed(deps, id)
	if type(deps.layout_changed) ~= "function" then return end
	local ok, err = pcall(deps.layout_changed, id)
	if not ok then deps.log("error", "The layout change of '%s' could not reach the emulation: %s.", id, tostring(err)) end
end

--- Whether a layout ships a hotstring extension, from the catalogue or its
--- installed record (an uninstall reads the record before it goes).
--- @param snapshot table The registry snapshot taken before the operation.
--- @param id string
--- @return boolean
local function carries_extension(snapshot, id)
	local entry = index_entry(snapshot.index, id)
	local installed = (snapshot.installed or {})[id]
	return (type(entry) == "table" and entry.extension ~= nil)
		or (type(installed) == "table" and installed.extension ~= nil)
end

--- Asks the host to reload the driver after a layout's extension changed: the
--- extension catalogue is read once per boot, so only a reload loads or drops
--- its hotstrings, and the reload also restarts the emulation (LMH-004).
--- @param deps table
--- @param id string
local function reload_extensions(deps, id)
	if type(deps.reload_extensions) ~= "function" then
		deps.log("error", "The extension of '%s' changed but this host cannot reload the driver.", id)
		return
	end
	local ok, accepted = pcall(deps.reload_extensions, id)
	if not ok or accepted ~= true then
		deps.log("error", "The reload after the extension of '%s' changed was refused: %s.", id, tostring(accepted))
	end
end

--- Handles the three composer messages of the page.
--- @param deps table The controller's collaborators.
--- @param controller table
--- @param action string
--- @param payload table
--- @param push_state function
--- @return boolean handled
function M.handle_composer(deps, controller, action, payload, push_state)
	local registry = deps.registry
	local operation = registry[action]
	if type(operation) ~= "function" then
		deps.log("warn", "Refused a layout composer message: the registry has no '%s' operation.", action)
		return false
	end
	local function report(ok, code, detail, used, installed)
		-- A saved or removed composition changes the reserved `composed` layout.
		if ok == true and (action == "composer_save" or action == "composer_remove") then
			layout_changed(deps, "composed")
		end
		deps.push("composerResult", { action = action, ok = ok == true, code = code, detail = detail and tostring(detail),
			used = used == true,
			pending = type(installed) == "table" and installed.pending_activation == true,
			consent = type(installed) == "table" and installed.consent == true })
		push_state()
	end
	if action == "composer_open" then
		operation(function(data) deps.push("composerData", data) end)
		return true
	end
	if action == "composer_remove" then
		operation(report)
		return true
	end
	if action == "composer_emulate" then return M.handle_emulate(deps, payload, report) end
	-- A save carries a composition (declaration) or an Ergopti layout source, with its layout.
	local declaration = type(payload.declaration) == "string"
	local source = type(payload.source) == "string"
	if declaration == source or type(payload.keylayout) ~= "string" then
		deps.log("warn", "Refused a layout composer save without exactly one of a declaration or a source, and its layout.")
		return false
	end
	-- A source may come with the emulation table the shared compiler built from it.
	if payload.emulation ~= nil and (not source or type(payload.emulation) ~= "string") then
		deps.log("warn", "Refused a layout composer save whose emulation table is not text beside a source.")
		return false
	end
	operation({
		declaration = declaration and payload.declaration or nil,
		source = source and payload.source or nil,
		emulation = source and payload.emulation or nil,
		keylayout = payload.keylayout,
		use = payload.use == true,
	}, report)
	return true
end

--- Whether this host emulates a layout source without installing it.
--- @param deps table
--- @return boolean
local function offers_emulate(deps)
	return type(deps.emulate) == "function" and type(deps.registry.composer_emulate) == "function"
end

--- « Emulate without installing »: stores the source for the emulation alone,
--- then turns the emulation onto it. report(ok, code, detail, used).
--- @param deps table
--- @param payload table { source, keylayout [, emulation] }
--- @param report function
--- @return boolean handled
function M.handle_emulate(deps, payload, report)
	if not offers_emulate(deps) then
		deps.log("warn", "Refused a layout emulation without install: this host does not offer it.")
		return false
	end
	if type(payload.source) ~= "string" or type(payload.keylayout) ~= "string"
		or (payload.emulation ~= nil and type(payload.emulation) ~= "string") or payload.declaration ~= nil then
		deps.log("warn", "Refused a layout emulation without its source and compiled layout as text.")
		return false
	end
	deps.registry.composer_emulate({ source = payload.source, keylayout = payload.keylayout,
		emulation = payload.emulation }, function(ok, code, detail, id)
		if not ok then
			report(false, code, detail, false)
			return
		end
		deps.emulate(id, function(emulated, emulate_code, emulate_detail)
			if not emulated then
				report(false, emulate_code or "emulate_failed", emulate_detail, false)
				return
			end
			report(true, nil, nil, true)
		end)
	end)
	return true
end

--- Whether the registry offers the layout editor's file operations.
--- @param registry table
--- @return boolean
local function offers_source(registry)
	return type(registry.source_open) == "function" and type(registry.source_save) == "function"
end

--- Handles the layout editor's two file messages.
--- @param deps table The controller's collaborators.
--- @param action string "source_open" or "source_save".
--- @param payload table
--- @return boolean handled
function M.handle_source(deps, action, payload)
	local registry = deps.registry
	if not offers_source(registry) then
		deps.log("warn", "Refused a layout editor message: the registry has no source operations.")
		return false
	end
	if action == "source_open" then
		registry.source_open(function(data) deps.push("sourceData", data) end)
		return true
	end
	if type(payload.filename) ~= "string" or type(payload.text) ~= "string" then
		deps.log("warn", "Refused a layout editor save without its file name and text.")
		return false
	end
	registry.source_save({ filename = payload.filename, text = payload.text }, function(ok, code, detail, filename)
		deps.push("sourceResult", { ok = ok == true, code = code, detail = detail and tostring(detail),
			filename = filename })
	end)
	return true
end

--- Creates the controller of one page.
--- deps.registry: { refresh(on_done), snapshot(), install(id, on_done),
---   uninstall(id, on_done), select(id, on_done) }; on_done(ok, detail_or_code, detail).
--- deps.registry also offers the composer (docs/design/layout-composer.md) as
---   composer_open(on_done), composer_save(payload, on_done) and
---   composer_remove(on_done) (_shared/layouts/engine/composer/composer.lua); a registry
---   without them refuses the three composer messages.
--- deps.registry may offer the layout editor's source_open(on_done) and
---   source_save(payload, on_done) (_shared/layouts/engine/composer/source_store.lua); a
---   registry without them refuses source_open and source_save.
--- deps.pick_source(on_done) optionally opens a native file panel for the
---   layout editor and answers {filename, text} or {} when cancelled, or
---   {code, detail} on a refusal (macOS); without it source_pick is refused.
--- deps.apply_nav(text, on_done) optionally saves and applies a layers.toml the
---   layout editor built from its navigation layer, through the driver's
---   navigation layer editor save; on_done({saved, applied, errors}). Without it
---   nav_save is refused.
--- deps.emulate(id, on_done) optionally makes the composed layout id the emulated
---   layout and reloads the layout emulation; on_done(ok, code, detail). With
---   registry.composer_emulate it offers composer_emulate (« Emulate without
---   installing »); without them composer_emulate is refused.
--- deps.layout_changed(id) is told after a layout was installed, updated,
---   uninstalled, saved or removed, so the host reloads the emulation when that
---   layout is the emulated one and refreshes its menu (LMH-001, LMH-002). A
---   stored emulated layout stays chosen when it is uninstalled (maintainer
---   decision, 2026-11-12): the reload stops it, a reinstall resumes it.
--- deps.reload_extensions(id) reloads the driver after a layout that ships a
---   hotstring extension was installed, updated or uninstalled, in place of
---   deps.layout_changed (LMH-004); it returns true when the reload started.
--- deps.push(function_name, payload) evaluates window.<function_name>(payload).
--- deps.strings() returns the translated strings the page shows.
--- deps.open_url(url) opens an https URL; deps.close() closes the window.
--- deps.log(level, message, ...) logs through the driver's logger.
--- @param deps table
--- @return table controller { on_message(payload) -> handled, open_editor() -> boolean }
function M.new(deps)
	local controller = { result = nil }
	local page_ready, editor_wanted = false, false

	local function push_state()
		return deps.push("updateState", M.page_state(deps.registry.snapshot(), controller.result))
	end

	local function operation_done(id, action, extension)
		return function(ok, detail_or_code, detail)
			if ok then
				local warning = nil
				if type(detail_or_code) == "table" and detail_or_code.consent == true then
					-- macOS asks the user to allow a keyboard it has not seen before.
					warning = "macos_consent"
				elseif type(detail_or_code) == "table" and detail_or_code.enabled == false then
					-- macOS lists it and turns it on at the next login: not a missing step for the user.
					warning = detail_or_code.pending_activation == true and "pending_logout" or "not_enabled"
				end
				controller.result = { id = id, action = action, ok = true, warning = warning }
				if extension then
					reload_extensions(deps, id)
				elseif action ~= "select" then
					layout_changed(deps, id)
				end
			else
				controller.result = { id = id, action = action, ok = false, code = tostring(detail_or_code),
					detail = detail ~= nil and tostring(detail) or nil }
			end
			push_state()
		end
	end

	--- Handles one message from the page.
	--- @param payload any Decoded message.
	--- @return boolean handled False for anything outside the allowlist.
	function controller.on_message(payload)
		if type(payload) ~= "table" or type(payload.action) ~= "string" or not M.ACTIONS[payload.action] then
			deps.log("warn", "Refused a layout manager message outside the allowlist.")
			return false
		end
		local action, id = payload.action, payload.id
		if action == "ready" then
			controller.result = nil
			page_ready = true
			deps.push("initData", { strings = deps.strings(),
				state = M.page_state(deps.registry.snapshot(), nil),
				source_editor = offers_source(deps.registry),
				source_pick = type(deps.pick_source) == "function",
				nav_apply = type(deps.apply_nav) == "function",
				emulate = offers_emulate(deps) })
			deps.registry.refresh(function() push_state() end)
			if editor_wanted then
				editor_wanted = false
				M.handle_source(deps, "source_open", {})
			end
			return true
		end
		if action == "refresh" then
			deps.registry.refresh(function() push_state() end)
			return true
		end
		if action == "close" then
			deps.close()
			return true
		end
		if action == "composer_open" or action == "composer_save" or action == "composer_remove"
			or action == "composer_emulate" then
			return M.handle_composer(deps, controller, action, payload, push_state)
		end
		if action == "source_open" or action == "source_save" then
			return M.handle_source(deps, action, payload)
		end
		if action == "source_pick" then
			if type(deps.pick_source) ~= "function" then
				deps.log("warn", "Refused a layout editor file pick: this host lets the page pick files.")
				return false
			end
			deps.pick_source(function(data) deps.push("sourcePicked", data) end)
			return true
		end
		if action == "nav_save" then
			if type(deps.apply_nav) ~= "function" then
				deps.log("warn", "Refused a navigation layer save: this host does not apply it from the layout editor.")
				return false
			end
			if type(payload.text) ~= "string" then
				deps.log("warn", "Refused a navigation layer save without its layers.toml text.")
				return false
			end
			deps.apply_nav(payload.text, function(result)
				result = type(result) == "table" and result or {}
				deps.push("navResult", { saved = result.saved == true, applied = result.applied == true,
					errors = type(result.errors) == "table" and result.errors or {} })
			end)
			return true
		end
		if type(id) ~= "string" or not id:match(ID_PATTERN) then
			deps.log("warn", "Refused a layout manager '%s' without a valid layout id.", action)
			return false
		end
		local snapshot = deps.registry.snapshot()
		if action == "open_homepage" then
			local entry = index_entry(snapshot.index, id) or (snapshot.installed or {})[id]
			local homepage = type(entry) == "table" and entry.homepage or nil
			if type(homepage) ~= "string" or not homepage:match("^https://[^%s]+$") then
				deps.log("warn", "Refused to open the homepage of '%s': none is published over https.", id)
				return false
			end
			deps.open_url(homepage)
			return true
		end
		if action == "install" or action == "update" then
			if not index_entry(snapshot.index, id) then
				deps.log("warn", "Refused to %s '%s': the catalogue does not list it.", action, id)
				return false
			end
			deps.registry.install(id, operation_done(id, action, carries_extension(snapshot, id)))
			push_state()
			return true
		end
		if not (snapshot.installed or {})[id] then
			deps.log("warn", "Refused to %s '%s': it is not installed.", action, id)
			return false
		end
		if action == "uninstall" then
			deps.registry.uninstall(id, operation_done(id, action, carries_extension(snapshot, id)))
		else
			deps.registry.select(id, operation_done(id, action))
		end
		push_state()
		return true
	end

	--- Shows the editor, as the page's « Editor » button does: at once when the
	--- page is ready, else as soon as it says so. A host without the editor's
	--- file operations refuses.
	--- @return boolean accepted
	function controller.open_editor()
		if not offers_source(deps.registry) then
			deps.log("warn", "Refused to open the layout editor: this host has no source operations.")
			return false
		end
		if page_ready then return M.handle_source(deps, "source_open", {}) end
		editor_wanted = true
		return true
	end

	return controller
end

return M
