--- ui/model_browser/init.lua

--- ==============================================================================
--- MODULE: Model Browser Window
--- DESCRIPTION:
--- Floating webview that renders the curated LLM model catalogue as a sortable,
--- filterable table and lets the user pick a model. Replaces the old hs.chooser
--- list with the _shared/ui/model_browser/ HTML/CSS/JS frontend, so the macOS
--- (Hammerspoon) and Windows (AHK + WebView2) drivers share one model browser
--- instead of each maintaining its own (hs.chooser vs AHK ListView).
---
--- FEATURES & RATIONALE:
--- 1. Native data proxy: the Lua backend builds the normalised model list from the
---    shared catalogue + the per-backend install scan and injects it via
---    evaluateJavaScript("injectModels(…)"), so the page never reads files itself.
--- 2. Singleton window: a second M.open() while visible brings the window to front
---    and refreshes the catalogue instead of stacking duplicates.
--- 3. Thin bridge: only two messages cross the boundary — "select_model" (activate)
---    and "open_url" (open the model's source page) — mirroring the changelog window.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local DeferredWork = require("infra.deferred_work")
local Paths      = require("infra.paths")
local ui_builder = require("ui.ui_builder")
local i18n       = require("infra.i18n")

local LOG = "model_browser"

-- Window geometry is resolved at open time from the shared manifest
-- (ui_builder.get_app_geometry → _shared/ui/apps.manifest.json, SSoT). No local
-- width/height constant: hardcoding here is what caused the cross-driver drift.

local _wv        = nil
local _wv_committed = false
local _ucc       = nil
local _ready     = false
local _queued    = {}
local _on_select = nil   -- callback(name) invoked when the user picks a model
local _ctx       = nil   -- last-opened context, kept for catalogue refresh
local _selection_owner = nil

-- The shared UI assets live in …/ergopti_plus/_shared/ui/model_browser/. Resolved
-- through the single shared-tree resolver (Paths.shared); the trailing slash is
-- preserved because ui_builder concatenates asset filenames directly onto this
-- directory.
local ASSETS_DIR = (Paths.shared("ui/model_browser") or "") .. "/"





-- ====================================
-- ====================================
-- ======= 1/ Javascript Bridge =======
-- ====================================
-- ====================================

--- Safely runs JS in the webview, queuing it when the page is not ready yet.
--- @param code string Raw JavaScript to evaluate.
local function eval(code)
	if not _wv then return end
	if _ready and type(_wv.evaluateJavaScript) == "function" then
		pcall(function() _wv:evaluateJavaScript(code) end)
	else
		table.insert(_queued, code)
		if #_queued > 50 then table.remove(_queued, 1) end
	end
end




-- =========================================
--- ==========================================
-- ======= 2/ Catalogue Construction =========
--- ==========================================
-- =========================================

--- Parses a parameter-count string ("8.03B", "750M") into billions as a number.
--- @param s string|number
--- @return number Billions of parameters (0 when unparseable).
local function parse_billions(s)
	if type(s) == "number" then return s end
	if type(s) ~= "string" then return 0 end
	local num = tonumber(s:match("([%d%.]+)")) or 0
	if s:upper():find("M") and not s:upper():find("B") then num = num / 1000 end
	return num
end

--- Builds the normalised catalogue payload the page expects.
--- @param ctx table { presets, active_backend, active_model, models_mgr }.
--- @return table { backend, active, models = { … } }.
local function build_catalogue(ctx)
	local models  = {}
	local backend = ctx.active_backend or "mlx"
	for _, provider in ipairs(ctx.presets or {}) do
		for _, family in ipairs(provider.families or {}) do
			for _, m in ipairs(family.models or {}) do
				local m_name = m.name or m.repo
				local src    = m.urls and m.urls[backend]
				-- Only list models installable on the active backend (the catalogue
				-- mixes MLX-only and Ollama-only entries).
				if m_name and type(src) == "string" and src ~= "" then
					local params   = m.parameters or {}
					local total_b  = parse_billions(params.total)
					local active_b = parse_billions(params.active)
					if active_b <= 0 then active_b = total_b end
					local hw   = (m.hardware_requirements or {})[backend] or {}
					local caps = m.capabilities or {}
					local installed = false
					if ctx.models_mgr and type(ctx.models_mgr.is_model_installed) == "function" then
						local ok, r = pcall(ctx.models_mgr.is_model_installed, m_name)
						installed = ok and r == true
					end
					table.insert(models, {
						name        = m_name,
						family      = family.label or "",
						provider    = provider.label or "",
						params_b    = total_b,
						active_b    = active_b,
						is_moe      = (active_b > 0 and active_b < total_b),
						ram_gb      = tonumber(hw.ram_gb) or 0,
						speed_tok_s = tonumber(caps.speed_tok_s) or 0,
						type        = m.type or "chat",
						installed   = installed,
						url         = (m.urls and (m.urls.hf or src)) or src,
					})
				end
			end
		end
	end
	return { backend = backend, active = ctx.active_model or "", models = models }
end

--- Encodes and injects the catalogue into the page.
--- @param ctx table The open context.
local function inject_catalogue(ctx)
	local payload     = build_catalogue(ctx)
	local ok, json    = pcall(hs.json.encode, payload)
	if not ok or not json then
		Logger.warn(LOG, "Failed to encode the model catalogue as JSON.")
		return
	end
	Logger.done(LOG, "Injecting %d model(s) (backend=%s).", #payload.models, tostring(payload.backend))
	eval("injectModels(" .. json .. ")")
end





-- ===========================================
-- ===========================================
-- ======= 3/ Window Lifecycle Helpers =======
-- ===========================================
-- ===========================================

--- Flushes the queued JS calls now that the page is ready.
local function flush_queue()
	_ready = true
	local q = _queued
	_queued = {}
	for _, code in ipairs(q) do
		pcall(function() _wv:evaluateJavaScript(code) end)
	end
end

--- Creates the usercontent controller (JS → Lua bridge) if not already done.
local function ensure_ucc()
	if _ucc then return end
	_ucc = hs.webview.usercontent.new("model_browser_bridge")
	_ucc:setCallback(function(msg)
		if type(msg) ~= "table" then return end
		local body = msg.body
		if type(body) == "string" and body == "ready" then
			flush_queue()
			if _ctx then inject_catalogue(_ctx) end
			return
		end

		-- host_bridge.js's makeHostBridge() posts non-string payloads RAW (no
		-- JSON.stringify) on WKWebView — WebKit itself converts the JS object into
		-- a native Lua table, so `body` already IS that table here. Passing it
		-- through hs.json.decode (which expects a JSON *string*) always threw,
		-- and the bare pcall around it swallowed the error with zero logging —
		-- matching the convention already used by action_picker / hotstring_editor
		-- / hotstrings_config_window / metrics_apps, read the table directly.
		if type(body) ~= "table" then return end
		if _wv_committed ~= true then return end

		if body.action == "select_model" and type(body.name) == "string" and body.name ~= "" then
			if _selection_owner ~= nil then return end
			Logger.info(LOG, "Model selected via browser: %s.", body.name)
			local selection = { context = _ctx, callback = _on_select }
			_selection_owner = selection
			local callback_ok, callback_result = Logger.callback(
				LOG, "Model browser selection", selection.callback, body.name)
			if _selection_owner ~= selection then return end
			_selection_owner = nil
			if not callback_ok then return end
			if callback_result == false then
				Logger.warn(LOG, "Model browser selection was refused; keeping the browser open.")
				return
			end
			if _ctx == selection.context and _on_select == selection.callback then M.close() end
		elseif body.action == "open_url" and type(body.url) == "string" then
			if ui_builder.open_http_url(body.url) then
				Logger.info(LOG, "Opened model source URL.")
			end
		end
	end)
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Opens (or brings to front) the model browser window.
--- @param ctx table { presets, active_backend, active_model, models_mgr, on_select }.
---   An explicit false from on_select refuses settlement and keeps the browser open.
--- @return boolean opened True only when a browser window is available.
function M.open(ctx)
	if type(ctx) ~= "table" then
		Logger.error(LOG, "M.open() requires a context table.")
		return false
	end
	_ctx       = ctx
	_on_select = type(ctx.on_select) == "function" and ctx.on_select or nil

	-- Singleton: reuse the existing window and just refresh the catalogue.
	if _wv then
		if _wv_committed ~= true then
			if M.close() ~= true then return false end
		else
			Logger.info(LOG, "Model browser already open — bringing to front and refreshing.")
			ui_builder.force_focus(_wv, false)
			inject_catalogue(ctx)
			return true
		end
	end

	Logger.start(LOG, "Opening model browser (backend=%s)…", tostring(ctx.active_backend))

	ensure_ucc()
	_ready  = false
	_queued = {}

	local final_html = ui_builder.build_injected_html(ASSETS_DIR)

	local geo = ui_builder.get_app_geometry("model_browser")
	if not geo then return false end
	local candidate = nil
	local closed = false
	local function candidate_is_owned()
		return closed ~= true and candidate ~= nil and _wv == candidate
	end
	local function candidate_is_active()
		return candidate_is_owned() and _wv_committed == true
	end
	local show_ok, webview_or_err = xpcall(function()
		return ui_builder.show_webview({
			frame             = ui_builder.get_centered_frame(geo.width, geo.height),
			title             = i18n.get("model_browser.window_title"),
			style_masks       = { "titled", "closable", "miniaturizable", "resizable" },
			level             = hs.drawing.windowLevels.floating,
			allow_text_entry  = true,
			allow_new_windows = false,
			usercontent       = _ucc,
			html_string       = final_html,
				on_navigation     = function(action)
					if action == "didFinishNavigation" then
						DeferredWork.after(0.15, function()
							if not candidate_is_active() then return end
							if not _ready then flush_queue() end
							if not candidate_is_active() then return end
							if _ctx then inject_catalogue(_ctx) end
					end, "model_browser.navigation")
				end
				return true
			end,
			on_close          = function()
				closed = true
				if _wv ~= candidate then return end
				_wv = nil
				_wv_committed = false
				_ready = false
				_queued = {}
				_selection_owner = nil
			end,
			on_webview_created = function(owned)
				if _wv ~= nil then return false end
				candidate = owned
				_wv = owned
				_wv_committed = false
				return true
			end,
				is_current = function()
					return candidate_is_owned()
				end,
		})
	end, debug.traceback)
	local webview = show_ok and webview_or_err or nil
	if webview == nil or webview ~= candidate or closed then
		if candidate ~= nil and _wv == candidate and M.close() ~= true then
			Logger.error(LOG, "Model browser construction rollback remains pending.")
		end
		Logger.error(LOG, "Model browser WebView creation failed.")
		return false
	end
	_wv_committed = true

	-- Safety: flush after 1.5 s if the ready handshake never arrives.
	DeferredWork.after(1.5, function()
		if candidate_is_active() and not _ready then flush_queue() end
	end, "model_browser.ready_fallback")

	Logger.success(LOG, "Model browser created.")
	return true
end

--- Closes the model browser window if open.
function M.close()
	if not _wv then return true end
	local owned = _wv
	-- Fence bridge work before crossing the native boundary. A thrown delete is
	-- ambiguous: the exact object remains cleanup-only until a retry settles it.
	_wv_committed = false
	local deleted, delete_err = xpcall(function() return owned:delete() end, debug.traceback)
	if not deleted then
		-- The native boundary is uncertain after a throw. Keep the exact object so
		-- a later close can retry instead of creating a second singleton window.
		if _wv == nil then
			_wv = owned
		end
		Logger.error(LOG, "Model browser close did not commit; exact WebView retained: %s.",
			tostring(delete_err))
		return false
	end
	if _wv == owned then
		_wv = nil
		_wv_committed = false
		_ready = false
		_queued = {}
		_selection_owner = nil
	end
	Logger.info(LOG, "Model browser closed.")
	return true
end

-- Exposed for unit tests only — pure catalogue-normalisation helpers with no
-- window/webview dependency, so the data shape the page consumes is locked down.
M._parse_billions  = parse_billions
M._build_catalogue = build_catalogue

return M
