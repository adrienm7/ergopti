--- lib/vscode_bridge.lua

--- ==============================================================================
--- MODULE: VSCode Bridge
--- DESCRIPTION:
--- Exposes the exact pixel position of the VSCode caret via an auto-generated
--- extension and a local HTTP server.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "vscode_bridge"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local PORT          = 7878
local EXT_ID        = "hs-caret-bridge"
local EXT_VERSION   = "0.0.3"
local EXT_DIR       = os.getenv("HOME") .. "/.vscode/extensions/" .. EXT_ID .. "-" .. EXT_VERSION

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
	os.execute("mkdir -p \"" .. EXT_DIR .. "\"")

	local pkg_path = EXT_DIR .. "/package.json"
	local ext_path = EXT_DIR .. "/extension.js"

	local already_ok = (read_file(pkg_path) == PACKAGE_JSON) and (read_file(ext_path) == EXTENSION_JS)

	if already_ok then
		Logger.info(LOG, string.format("Extension already up to date (v%s).", EXT_VERSION))
		return false
	end

	write_file(pkg_path, PACKAGE_JSON)
	write_file(ext_path, EXTENSION_JS)
	Logger.info(LOG, string.format("Extension installed in %s.", EXT_DIR))
	hs.alert.show("Veuillez recharger VSCode (Cmd+Shift+P > Reload Window) pour activer l’extension de frappe", 4)
	return true
end





-- =================================
-- =================================
-- ======= 4/ HTTP Server API ======
-- =================================
-- =================================

local _caret  = nil
local _server = nil

--- Starts the HTTP server listening for caret payloads.
function M.start_server()
	if _server then _server:stop() end
	Logger.debug(LOG, string.format("Starting HTTP server on port %d…", PORT))
	
	_server = hs.httpserver.new(false, false)
	_server:setPort(PORT)
	_server:setCallback(function(method, path, _, body)
		if path == "/caret" and method == "POST" then
			local ok, data = pcall(hs.json.decode, body)
			if ok and data then
				data._ts = hs.timer.secondsSinceEpoch()
				_caret = data
			end
		end
		return "{}", 200, { ["Content-Type"] = "application/json" }
	end)
	_server:start()
	Logger.info(LOG, "HTTP server started successfully.")
end

--- Stops the HTTP server.
function M.stop_server()
	if _server then
		Logger.debug(LOG, "Stopping HTTP server…")
		_server:stop()
		_server = nil
		Logger.info(LOG, "HTTP server stopped.")
	end
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

--- Extracts the accessibility frame of the active editor to bound the calculation.
--- @return table|nil The bounds frame table.
local function get_editor_ax_frame()
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
	return ok and frame or nil
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

--- Initializes the bridge daemons on module load.
function M.setup()
	M.install_extension()
	M.start_server()
end

return M
