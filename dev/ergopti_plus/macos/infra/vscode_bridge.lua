--- infra/vscode_bridge.lua

--- ==============================================================================
--- MODULE: VSCode Bridge
--- DESCRIPTION:
--- Exposes the exact pixel position of the VSCode caret via an auto-generated
--- extension and a local HTTP server.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n   = require("infra.i18n")
local LOG    = "vscode_bridge"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local PORT          = 7878
local EXT_ID        = "hs-caret-bridge"
local EXT_VERSION   = "0.0.3"
-- HOME is always set on macOS, but this concatenation runs at MODULE LOAD, so a
-- nil there does not degrade the feature — it raises before a single function is
-- defined and takes down whatever required the module. Defaulting keeps the
-- failure inside the feature that needs the path.
local HOME          = os.getenv("HOME") or ""
local EXT_DIR       = HOME .. "/.vscode/extensions/" .. EXT_ID .. "-" .. EXT_VERSION

-- AX frame cache: the accessibility call can block for up to 100 ms on a
-- busy VSCode instance. Cache the result for FRAME_CACHE_TTL_S so that rapid
-- consecutive calls to estimate_position() (one per streaming token) do not
-- each stall the Hammerspoon main thread (vscode-bridge-blocking-ax-call).
local _ax_frame_cache  = nil
local _ax_frame_ts     = 0
-- Validity is tracked separately from the cached VALUE because nil is a
-- legitimate result (no focused element, or an editor frame too small to use).
-- Keying freshness on `_ax_frame_cache ~= nil` therefore never cached a negative
-- lookup, so the expensive round trip re-ran on every single call — exactly the
-- case the cache exists to absorb.
local _ax_frame_valid  = false
local FRAME_CACHE_TTL_S = 0.2

-- VSCode rendering constants for pixel math.
M.LINE_HEIGHT  = 19
M.CHAR_WIDTH   = 7.65
M.GUTTER_WIDTH = 62





-- ====================================
-- ====================================
-- ======= 2/ Extension Scripts =======
-- ====================================
-- ====================================

local PACKAGE_JSON = string.format([[{
  "name": "%s",
  "displayName": "Hammerspoon Caret Bridge",
  "description": "Sends caret pixel-position data to Hammerspoon",
  "version": "%s",
  "publisher": "local",
  "engines": { "vscode": "^1.60.0" },
  "activationEvents": ["onStartupFinished"],
  "main": "./extension.js",
  "contributes": {}
}]], EXT_ID, EXT_VERSION)

local EXTENSION_JS = [[
'use strict';
const vscode = require('vscode');
const http   = require('http');

let _timer = null;

function post(payload) {
    const body = JSON.stringify(payload);
    const req  = http.request({
        hostname: '127.0.0.1',
        port:     7878,
        path:     '/caret',
        method:   'POST',
        headers:  {
            'Content-Type':   'application/json',
            'Content-Length': Buffer.byteLength(body)
        }
    }, res => { res.resume(); });
    req.on('error', () => {});
    req.write(body);
    req.end();
}

function send() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) { post({ active: false }); return; }

    const pos = editor.selection.active;
    const vr  = editor.visibleRanges[0];

    post({
        active:           true,
        line:             pos.line,
        character:        pos.character,
        visibleStartLine: vr ? vr.start.line : 0,
        visibleEndLine:   vr ? vr.end.line   : 0,
        lineCount:        editor.document.lineCount,
        tabSize:          (typeof editor.options.tabSize === 'number')
                              ? editor.options.tabSize : 4,
    });
}

function debouncedSend() {
    clearTimeout(_timer);
    _timer = setTimeout(send, 40);
}

function activate(ctx) {
    ctx.subscriptions.push(
        vscode.window.onDidChangeTextEditorSelection(debouncedSend),
        vscode.window.onDidChangeActiveTextEditor(debouncedSend),
        vscode.window.onDidChangeTextEditorVisibleRanges(debouncedSend)
    );
    send();
}

function deactivate() {}
module.exports = { activate, deactivate };
]]





-- =========================================
-- =========================================
-- ======= 3/ Extension Installation =======
-- =========================================
-- =========================================

--- Writes string content to a file safely.
--- @param path string Target file path.
--- @param content string File content.
--- @return boolean True if successful.
local function write_file(path, content)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(content)
	f:close()
	return true
end

--- Reads string content from a file safely.
--- @param path string Target file path.
--- @return string|nil The file content or nil.
local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local c = f:read("*a")
	f:close()
	return c
end

--- Installs or updates the VSCode extension files locally.
--- @return boolean True if installation occurred and VSCode reload is required.
function M.install_extension()
	Logger.debug(LOG, "Verifying VSCode extension installation…")
	os.execute("mkdir -p " .. text_utils.shell_quote(EXT_DIR))

	local pkg_path = EXT_DIR .. "/package.json"
	local ext_path = EXT_DIR .. "/extension.js"

	local already_ok = (read_file(pkg_path) == PACKAGE_JSON) and (read_file(ext_path) == EXTENSION_JS)

	if already_ok then
		Logger.info(LOG, string.format("Extension already up to date (v%s).", EXT_VERSION))
		return false
	end

	local ok_pkg = write_file(pkg_path, PACKAGE_JSON)
	local ok_ext = write_file(ext_path, EXTENSION_JS)
	if not ok_pkg or not ok_ext then
		Logger.error(LOG, "Extension install failed — could not write to '%s'.", EXT_DIR)
		return false
	end
	Logger.info(LOG, string.format("Extension installed in %s.", EXT_DIR))
	-- A transient toast, through the layer that actually provides one.
	-- dialog_util.alert forwards to hs.dialog.alert, whose leading parameters are
	-- coordinates and a callback — passing it (message, duration) raised, and the
	-- throw travelled out of install_extension and aborted setup() before
	-- start_server() had run. The notice is cosmetic; it is also pcall'd, so it can
	-- no longer take anything with it.
	local ok_notify, notifications = pcall(require, "infra.notifications")
	if ok_notify and type(notifications.notify) == "function" then
		local ok_toast, err = pcall(notifications.notify, i18n.get("vscode.reload_required"), nil, "info")
		if not ok_toast then
			Logger.warn(LOG, "Reload notice could not be shown: %s.", tostring(err))
		end
	end
	return true
end





--- ==================================
--- ==================================
--- ======= 4/ HTTP Server API =======
--- ==================================
--- ==================================

local _caret  = nil
local _server = nil
local _server_cleanup = nil

--- Handles one request from the local VS Code extension.
--- @param method string HTTP method.
--- @param path string Request path.
--- @param _headers table Request headers.
--- @param body string Request body.
--- @return string body Response body.
--- @return number status HTTP status.
--- @return table headers Response headers.
local function handle_server_request(method, path, _headers, body)
	if path == "/caret" and method == "POST" then
		local ok, data = pcall(hs.json.decode, body)
		if ok and data then
			data._ts = hs.timer.secondsSinceEpoch()
			_caret = data
		end
	end
	return "{}", 200, { ["Content-Type"] = "application/json" }
end

--- Stops the exact committed server or uncommitted cleanup candidate.
--- Ownership is released only after the native result and listening port both
--- prove settlement, so a throw, refusal, or still-live socket remains retryable.
--- @param context string Lifecycle context for diagnostics.
--- @return boolean stopped Exact settlement result.
local function stop_owned_server(context)
	if _server and _server_cleanup and _server ~= _server_cleanup then
		Logger.error(LOG, "HTTP server %s found conflicting native owners.", context)
		return false
	end
	local owned = _server_cleanup or _server
	if not owned then return true end

	local stopped, stop_result = xpcall(function() return owned:stop() end, debug.traceback)
	if not stopped or stop_result ~= owned then
		Logger.error(LOG, "HTTP server %s did not stop transactionally: %s.",
			context, tostring(stop_result))
		return false
	end
	local port_ok, listening_port = xpcall(function() return owned:getPort() end, debug.traceback)
	if not port_ok or listening_port ~= 0 then
		Logger.error(LOG, "HTTP server %s remained live after stop (reported=%s).",
			context, tostring(listening_port))
		return false
	end

	if _server == owned then _server = nil end
	if _server_cleanup == owned then _server_cleanup = nil end
	return true
end

--- Rejects one uncommitted candidate and attempts exact rollback.
--- @param stage string Failed lifecycle stage.
--- @param detail any Native result or traceback.
--- @return boolean Always false.
local function reject_server_candidate(stage, detail)
	Logger.error(LOG, "HTTP server %s failed on port %d: %s.",
		stage, PORT, tostring(detail))
	if _server_cleanup and stop_owned_server("startup rollback") ~= true then
		Logger.error(LOG, "HTTP server cleanup remains pending after %s failure.", stage)
	end
	return false
end

--- Starts the HTTP server listening for caret payloads.
--- @return boolean started Exact commitment result.
function M.start_server()
	if _server or _server_cleanup then
		if M.stop_server() ~= true then return false end
	end
	Logger.debug(LOG, "Starting HTTP server on port %d…", PORT)

	local constructed, candidate = xpcall(function()
		return hs.httpserver.new(false, false)
	end, debug.traceback)
	if not constructed or candidate == nil or candidate == false then
		Logger.error(LOG, "HTTP server construction failed on port %d: %s.",
			PORT, tostring(candidate))
		return false
	end
	-- Publish cleanup ownership before the first native configuration call;
	-- `_server` itself remains unpublished until the socket proves its bind
	_server_cleanup = candidate

	local port_set, port_result = xpcall(function()
		return candidate:setPort(PORT)
	end, debug.traceback)
	if not port_set or port_result ~= candidate then
		return reject_server_candidate("port configuration", port_result)
	end
	local callback_set, callback_result = xpcall(function()
		return candidate:setCallback(handle_server_request)
	end, debug.traceback)
	if not callback_set or callback_result ~= candidate then
		return reject_server_candidate("callback configuration", callback_result)
	end

	local started, start_result = xpcall(function() return candidate:start() end, debug.traceback)
	if not started or start_result ~= candidate then
		return reject_server_candidate("activation", start_result)
	end
	local port_ok, bound_port = xpcall(function() return candidate:getPort() end, debug.traceback)
	if not port_ok or bound_port ~= PORT then
		return reject_server_candidate("bind verification", bound_port)
	end

	_server = candidate
	_server_cleanup = nil
	Logger.info(LOG, "HTTP server started successfully.")
	return true
end

--- Stops the HTTP server.
--- @return boolean stopped Exact settlement result.
function M.stop_server()
	if not _server and not _server_cleanup then return true end
	Logger.debug(LOG, "Stopping HTTP server…")
	if stop_owned_server("shutdown") ~= true then return false end
	Logger.info(LOG, "HTTP server stopped.")
	return true
end

--- Returns the latest caret data if it is fresh enough.
--- @param max_age number Maximum allowed age in seconds.
--- @return table|nil The caret data table.
function M.get_caret(max_age)
	if not _caret then return nil end
	if hs.timer.secondsSinceEpoch() - _caret._ts > (max_age or 5) then
		return nil
	end
	return _caret
end





-- =========================================
-- =========================================
-- ======= 5/ VSCode Window Tracking =======
-- =========================================
-- =========================================

--- Evaluates if VSCode is the currently active window.
--- @return boolean True if VSCode is active.
function M.is_vscode()
	local app = hs.application.frontmostApplication()
	return app ~= nil and app:bundleID() == "com.microsoft.VSCode"
end

--- Extracts the accessibility frame of the active editor, with a short-lived cache.
--- The raw AX call can block the Hammerspoon main thread for up to 100 ms on a
--- busy VSCode instance. Caching for FRAME_CACHE_TTL_S ensures that rapid calls
--- (e.g. one per streaming token) pay the AX cost at most once per 200 ms
--- (vscode-bridge-blocking-ax-call).
--- @return table|nil The bounds frame table, or nil on error / empty editor.
local function get_editor_ax_frame()
	local now = hs.timer.secondsSinceEpoch()
	-- Gate on the validity flag, not on the cached value: a negative lookup is a
	-- real result worth caching for the TTL just like a successful one.
	if _ax_frame_valid and (now - _ax_frame_ts) < FRAME_CACHE_TTL_S then
		return _ax_frame_cache
	end
	local ok, frame = pcall(function()
		local ax      = require("hs.axuielement")
		local focused = ax.systemWideElement():attributeValue("AXFocusedUIElement")
		if not focused then return nil end
		local f = focused:attributeValue("AXFrame")
		if f and f.x and f.y and f.w and f.h and f.w > 100 and f.h > 50 then
			return f
		end
		return nil
	end)
	local result = ok and frame or nil
	_ax_frame_cache = result
	_ax_frame_ts    = now
	-- The lookup completed, so the cache is authoritative for the next TTL window
	-- whether the outcome was a frame or nil.
	_ax_frame_valid = true
	return result
end





-- =======================================
-- =======================================
-- ======= 6/ Position Estimation ========
-- =======================================
-- =======================================

--- Calculates the estimated pixel position based on API telemetry and AX bounds.
--- @return table|nil The estimated coordinates.
function M.estimate_position()
	if not M.is_vscode() then return nil end

	local caret = M.get_caret(5)
	if not caret or not caret.active then return nil end

	-- Guard required numeric fields: a POST body like {"active":true} without
	-- line/visibleStartLine/character would throw on the arithmetic below.
	if type(caret.line) ~= "number"
		or type(caret.visibleStartLine) ~= "number"
		or type(caret.character) ~= "number" then
		return nil
	end

	local editor_frame = get_editor_ax_frame()
	if not editor_frame then return nil end

	local relative_line = caret.line - caret.visibleStartLine
	if relative_line < 0 then return nil end

	local x = editor_frame.x + M.GUTTER_WIDTH + (caret.character * M.CHAR_WIDTH)
	local y = editor_frame.y + (relative_line * M.LINE_HEIGHT)

	if y > editor_frame.y + editor_frame.h - M.LINE_HEIGHT then return nil end
	if x > editor_frame.x + editor_frame.w - 20 then
		x = editor_frame.x + editor_frame.w - 20
	end

	return { x = x, y = y, h = M.LINE_HEIGHT, type = "vscode_caret" }
end

--- Initializes the bridge: starts the HTTP server, then installs the VS Code
--- extension. Called explicitly from init.lua after the tooltip subsystem is ready.
---
--- The server goes FIRST and the install is isolated. These two used to be chained
--- in the other order with nothing between them, so any throw inside the install —
--- including from the purely cosmetic "reload VS Code" notice at its very last
--- line — aborted setup() before the server existed. That happened on exactly the
--- boot that installed or updated the extension, and init.lua's call site pcalls
--- setup(), so the log said the bridge had failed and nothing said the server had
--- never been reached.
--- @return boolean started True when the caret server owns port 7878.
function M.setup()
	if M.start_server() ~= true then return false end
	local ok, err = pcall(M.install_extension)
	if not ok then
		Logger.error(LOG, "Extension install failed: %s — the caret server is up regardless.",
			tostring(err))
	end
	return true
end

return M
