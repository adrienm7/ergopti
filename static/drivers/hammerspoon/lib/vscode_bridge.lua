-- lib/vscode_bridge.lua
-- Expose la position exacte du caret VSCode via une extension auto-générée
-- et un serveur HTTP local. Intégration dans getBestUIAnchor() de hotstrings.lua.

local M = {}

local PORT          = 7878
local EXT_ID        = "hs-caret-bridge"
local EXT_VERSION   = "0.0.3"          -- bump = réinstallation auto
local EXT_DIR       = os.getenv("HOME") .. "/.vscode/extensions/" .. EXT_ID .. "-" .. EXT_VERSION

-- ── Constantes de rendu VSCode (ajustables) ─────────────────────────────────
M.LINE_HEIGHT  = 19    -- px, fonte 14pt par défaut
M.CHAR_WIDTH   = 7.65  -- px, Menlo/Consolas 14pt
M.GUTTER_WIDTH = 62    -- px, numéros de ligne (approximatif)

-- ── Fichiers de l'extension (embarqués comme strings Lua) ───────────────────

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

-- L'extension :
--   • écoute onDidChangeTextEditorSelection / VisibleRanges / ActiveEditor
--   • debounce 40 ms pour ne pas saturer le serveur
--   • envoie {line, character, visibleStartLine, lineCount, tabSize, active}
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

-- ── Installation ─────────────────────────────────────────────────────────────

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content); f:close()
    return true
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    return c
end

function M.install_extension()
    os.execute('mkdir -p "' .. EXT_DIR .. '"')

    local pkg_path = EXT_DIR .. "/package.json"
    local ext_path = EXT_DIR .. "/extension.js"

    local already_ok = (read_file(pkg_path) == PACKAGE_JSON)
                    and (read_file(ext_path) == EXTENSION_JS)

    if already_ok then
        print("[vscode_bridge] Extension déjà à jour (" .. EXT_VERSION .. ")")
        return false   -- pas réinstallée
    end

    write_file(pkg_path, PACKAGE_JSON)
    write_file(ext_path, EXTENSION_JS)
    print("[vscode_bridge] Extension installée → " .. EXT_DIR)
    print("[vscode_bridge] Rechargez VSCode : Cmd+Shift+P > Reload Window")
    return true    -- réinstallée, rechargement VSCode nécessaire
end

-- ── Serveur HTTP ─────────────────────────────────────────────────────────────

local _caret  = nil
local _server = nil

function M.start_server()
    if _server then _server:stop() end
    _server = hs.httpserver.new(false, false)
    _server:setPort(PORT)
    _server:setCallback(function(method, path, _headers, body)
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
    print("[vscode_bridge] Serveur HTTP démarré sur le port " .. PORT)
end

function M.stop_server()
    if _server then _server:stop(); _server = nil end
end

-- Retourne les dernières données caret si elles ont moins de max_age secondes
function M.get_caret(max_age)
    if not _caret then return nil end
    if hs.timer.secondsSinceEpoch() - _caret._ts > (max_age or 5) then
        return nil
    end
    return _caret
end

-- ── Détection VSCode ─────────────────────────────────────────────────────────

function M.is_vscode()
    local app = hs.application.frontmostApplication()
    return app ~= nil and app:bundleID() == "com.microsoft.VSCode"
end

-- ── Frame AX de l'éditeur actif ─────────────────────────────────────────────
-- Renvoie le frame de l'élément AX focalisé (textarea de l'éditeur VSCode).
-- Fiable même sous Electron : on obtient la zone de texte, pas le caret.

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

-- ── Estimation de la position pixel ─────────────────────────────────────────
-- Combine données de l'extension (line/character) + frame AX de l'éditeur.
-- Précision : ±1-2 lignes selon le thème / zoom VSCode.

function M.estimate_position()
    if not M.is_vscode() then return nil end

    local caret = M.get_caret(5)
    if not caret or not caret.active then return nil end

    local editor_frame = get_editor_ax_frame()
    if not editor_frame then return nil end

    local relative_line = caret.line - caret.visibleStartLine
    if relative_line < 0 then return nil end

    local x = editor_frame.x + M.GUTTER_WIDTH
              + (caret.character * M.CHAR_WIDTH)
    local y = editor_frame.y + (relative_line * M.LINE_HEIGHT)

    -- Garde la bulle dans les limites de l'éditeur
    if y > editor_frame.y + editor_frame.h - M.LINE_HEIGHT then return nil end
    if x > editor_frame.x + editor_frame.w - 20 then
        x = editor_frame.x + editor_frame.w - 20
    end

    return { x = x, y = y, h = M.LINE_HEIGHT, type = "vscode_caret" }
end

-- ── Init (appelé depuis init.lua ou hotstrings.lua) ─────────────────────────

function M.setup()
    M.install_extension()
    M.start_server()
end

return M
