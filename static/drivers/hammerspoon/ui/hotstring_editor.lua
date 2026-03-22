-- ui/hotstring_editor.lua
-- Personal hotstring editor.
--
-- Public API:
--   M.init(toml_path, keymap_mod, update_menu_fn)
--   M.open(open_mode)             "shortcut" | "menu"
--   M.close()
--   M.is_open() → boolean
--   M.is_editor_focused() → boolean
--   M.set_on_focus_change(fn)     fn(focused:bool) — called on window focus/blur
--   M.set_shortcut(mods, key) / M.clear_shortcut()
--   M.set_trigger_char(char)
--   M.set_update_menu(fn)
--   M.set_update_pref(fn)
--   M.set_ui_prefs(prefs)
--   M.set_default_section(section_name)   nil = show main view
--   M.set_close_on_add(bool)              close after adding (shortcut mode only)

local M = {}

local toml_reader = require("lib.toml_reader")
local toml_writer = require("lib.toml_writer")

local CUSTOM_GROUP_NAME = "custom"
local STAR_CANONICAL    = "★"

local _toml_path       = nil
local _keymap          = nil
local _update_menu     = nil
local _update_pref     = nil
local _on_focus_change = nil
local _trigger_char    = STAR_CANONICAL
local _webview         = nil
local _usercontent     = nil
local _hotkey          = nil

local _compact_view    = false
local _auto_close      = false
local _default_section = nil
local _is_focused      = false

-- ============================================================================
-- 1. DATA LAYER
-- ============================================================================

local function empty_toml_data()
    return { meta = { description = "Hotstrings personnels" },
             sections_order = {}, sections = {} }
end

local function ensure_file()
    if not _toml_path then return end
    local fh = io.open(_toml_path, "r")
    if fh then fh:close(); return end
    toml_writer.write(_toml_path, empty_toml_data())
end

local function normalise_output(s)
    if not s then return "" end
    s = s:gsub("\r\n","{Enter}"):gsub("\r","{Enter}"):gsub("\n","{Enter}")
    local aliases = {
        esc="Escape", escape="Escape",
        bs="BackSpace", backspace="BackSpace",
        del="Delete",  delete="Delete",
        ["return"]="Enter", enter="Enter",
        left="Left", right="Right", up="Up", down="Down",
        home="Home", ["end"]="End", tab="Tab",
    }
    s = s:gsub("{([^}]+)}", function(name)
        local c = aliases[name:lower()]
        return "{" .. (c or (name:sub(1,1):upper() .. name:sub(2))) .. "}"
    end)
    return s
end

local function load_js_data(open_mode)
    ensure_file()
    local raw = {}
    if _toml_path then
        local ok, parsed = pcall(toml_reader.parse, _toml_path)
        if ok and parsed then raw = parsed end
    end
    local sections = {}
    for _, name in ipairs(raw.sections_order or {}) do
        if name ~= "-" and raw.sections and raw.sections[name] then
            local sec = raw.sections[name]
            local entries = {}
            for _, e in ipairs(sec.entries or {}) do
                table.insert(entries, {
                    trigger           = e.trigger,
                    output            = normalise_output(e.output),
                    is_word           = e.is_word            or false,
                    auto_expand       = e.auto_expand        or false,
                    is_case_sensitive = e.is_case_sensitive  or false,
                    final_result      = e.final_result       or false,
                })
            end
            table.insert(sections, {
                name = name, description = sec.description or name, entries = entries,
            })
        end
    end
    return {
        sections        = sections,
        trigger_char    = _trigger_char,
        star            = STAR_CANONICAL,
        compact_view    = _compact_view,
        auto_close      = _auto_close,
        default_section = _default_section,
        open_mode       = open_mode or "menu",
    }
end

local function js_to_toml(save_data)
    local data = { meta = { description = "Hotstrings personnels" },
                   sections_order = save_data.sections_order or {},
                   sections = {} }
    for _, name in ipairs(data.sections_order) do
        local s = save_data.sections and save_data.sections[name]
        if s then
            data.sections[name] = {
                description = s.description or name,
                entries = s.entries or {},
            }
        end
    end
    return data
end

-- ============================================================================
-- 2. MESSAGE HANDLER
-- ============================================================================

local function handle_message(msg)
    if type(msg) ~= "table" then return end
    local action, data = msg.action, msg.data

    if action == "ready" then
        if not _webview then return end
        local js_data  = load_js_data(msg.open_mode or "menu")
        local ok, json = pcall(hs.json.encode, js_data)
        if ok and json then
            _webview:evaluateJavaScript("window.initData(" .. json .. ")")
        end
        return
    end

    if action == "save" then
        if not _toml_path then return end
        local toml_data = js_to_toml(data)
        local ok, err   = toml_writer.write(_toml_path, toml_data)
        if ok then
            if _keymap then
                _keymap.disable_group(CUSTOM_GROUP_NAME)
                _keymap.load_toml(CUSTOM_GROUP_NAME, _toml_path)
                _keymap.enable_group(CUSTOM_GROUP_NAME)
                _keymap.sort_mappings()
            end
            if _update_menu then hs.timer.doAfter(0, _update_menu) end
        else
            pcall(function()
                hs.notify.new({ title = "Erreur de sauvegarde",
                    informativeText = tostring(err) }):send()
            end)
        end
        return
    end

    if action == "save_pref" then
        if type(data) == "table" then
            if data.key == "compact_view"    then _compact_view    = data.value == true end
            if data.key == "auto_close"      then _auto_close      = data.value == true end
            if data.key == "default_section" then _default_section = data.value         end
        end
        if _update_pref then _update_pref(data) end
        return
    end

    if action == "window_focus" then
        local now_focused = (data and data.focused == true)
        _is_focused = now_focused
        if _on_focus_change then
            _on_focus_change(_is_focused)
        end
        return
    end

    if action == "close" then M.close() end
end

-- ============================================================================
-- 3. HTML / CSS / JS
-- ============================================================================

local HTML = [[<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Hotstrings Personnels</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;overflow:hidden}
:root{
  --bg:#f2f2f7;--surface:#fff;--border:#d1d1d6;
  --text:#1d1d1f;--sub:#6e6e73;--hint:#8e8e93;
  --accent:#007aff;--accent2:#5856d6;
  --danger:#ff3b30;--row-sep:#f2f2f7;--shadow:0 1px 3px rgba(0,0,0,.09);
  --tag-bg:#f2f2f7;--tag-on:#ddeeff;--tag-on-c:#007aff;
  --chip-bg:#ddeeff;--chip-c:#1a4bbf;--chip-bd:rgba(26,75,191,.22);
  --row-hover:#f5f8ff;
  --warning:#ff9500;--warning-bg:#fff8ee;
}
@media(prefers-color-scheme:dark){:root{
  --bg:#1c1c1e;--surface:#2c2c2e;--border:#3a3a3c;
  --text:#fff;--sub:rgba(235,235,245,.6);--hint:#636366;
  --accent:#0a84ff;--accent2:#bf5af2;
  --danger:#ff453a;--row-sep:#3a3a3c;--shadow:none;
  --tag-bg:#3a3a3c;--tag-on:#0a3a6e;--tag-on-c:#64b5f6;
  --chip-bg:#183060;--chip-c:#93b8f8;--chip-bd:rgba(147,184,248,.28);
  --row-hover:#333335;
  --warning:#ff9f0a;--warning-bg:#2a2000;
}}
body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;font-size:13px;line-height:1.5;color:var(--text);background:var(--bg);}
#app{display:flex;flex-direction:column;height:100vh}
#hdr{display:flex;align-items:center;gap:8px;padding:10px 16px;background:var(--surface);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:20;-webkit-app-region:drag;}
#hdr *{-webkit-app-region:no-drag}
#hdr h1{font-size:14px;font-weight:600;flex:1}
#content{flex:1;overflow-y:auto;padding:14px 16px}
.sec-card{background:var(--surface);border-radius:10px;margin-bottom:12px;box-shadow:var(--shadow);overflow:hidden;transition:box-shadow .15s;}
.sec-card.drag-over{box-shadow:0 0 0 2.5px var(--accent);}
.sec-card.dragging{opacity:.3;}
.sec-head{display:flex;align-items:center;gap:4px;padding:7px 10px 7px 12px;border-bottom:1px solid transparent;user-select:none;}
.sec-head.open{border-bottom-color:var(--row-sep)}
.drag-handle{color:var(--hint);font-size:14px;cursor:grab;padding:2px 4px;flex-shrink:0;line-height:1;}
.drag-handle:active{cursor:grabbing;}
.caret{font-size:9px;color:var(--sub);transition:transform .18s;cursor:pointer;flex-shrink:0;}
.caret.open{transform:rotate(90deg)}
.sec-title{font-weight:600;font-size:13px;flex:1;cursor:text;padding:1px 4px;border-radius:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;user-select:text;}
.sec-title:hover{background:var(--row-hover);}
.sec-cnt{font-size:11px;color:var(--sub);flex-shrink:0;}
.sec-del{padding:3px 7px;background:none;border:none;border-radius:5px;cursor:pointer;color:var(--sub);font-size:13px;line-height:1;transition:background .1s,color .1s;}
.sec-del:hover{background:#ffe5e3;color:var(--danger);}
@media(prefers-color-scheme:dark){.sec-del:hover{background:#4a1c1a;color:var(--danger)}}
.entry-row{display:flex;align-items:stretch;border-bottom:1px solid var(--row-sep);cursor:pointer;transition:background .1s;}
.entry-row:last-of-type{border-bottom:none}
.entry-row:hover{background:var(--row-hover);}
/* ── Checkboxes ── */
.entry-cb-wrap{padding:6px 0 6px 12px;display:flex;align-items:center;flex-shrink:0;}
.entry-cb{width:14px;height:14px;cursor:pointer;accent-color:var(--accent);}
.e-trig{padding:6px 6px 6px 8px;min-width:90px;max-width:140px;flex-shrink:0;display:flex;align-items:center;}
.trig-lbl{
  display:inline-block;
  font-family:"SF Mono",Menlo,monospace;font-size:12px;font-weight:500;
  color:var(--text);background:var(--tag-bg);border:1px solid var(--border);
  border-radius:5px;padding:2px 6px;
  user-select:text;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
}
@media(prefers-color-scheme:dark){
  .trig-lbl { background:#2c2c2e; border-color:#48484a; }
}
.trig-star{
  display:inline;
  color:var(--accent);
  font-weight:800;
  font-size:14px;
}
.e-arrow{color:var(--sub);font-size:11px;padding:0 5px;flex-shrink:0;display:flex;align-items:center;}
.e-out-cell{flex:1;min-width:0;display:flex;align-items:center;padding:5px 6px;}
.compact .e-out{white-space:nowrap;overflow:hidden;max-width:100%;}
.expanded .e-out{white-space:pre-wrap;word-break:break-word;}
.e-out{font-size:12px;user-select:text;width:100%;}
.tc{display:inline-block;background:var(--chip-bg);color:var(--chip-c);border:1px solid var(--chip-bd);border-radius:3px;padding:0 2px;margin:0 1px;font-family:"SF Mono",Menlo,monospace;font-size:10.5px;}
.e-tags{display:flex;gap:3px;align-items:center;padding:0 5px;flex-shrink:0;}
.tag{font-size:10px;padding:1px 5px;border-radius:4px;background:var(--tag-bg);color:var(--sub);}
.tag.on{background:var(--tag-on);color:var(--tag-on-c)}
.e-del{width:30px;flex-shrink:0;display:flex;align-items:center;justify-content:center;color:var(--sub);font-size:13px;cursor:pointer;padding:4px;}
.e-del:hover{color:var(--danger);}
/* ── Add hotstring button ── */
.btn-add{
  display:flex;align-items:center;justify-content:center;gap:5px;
  width:calc(100% - 24px);margin:8px 12px;padding:7px 13px;
  background:var(--tag-on);border:none;border-radius:7px;
  color:var(--accent);font-size:13px;font-weight:500;cursor:pointer;
  transition:filter .1s;
}
.btn-add:hover{filter:brightness(.93);}
.empty{text-align:center;color:var(--sub);padding:52px 16px;font-size:13px;line-height:2.2}
.btn{padding:5px 12px;border:none;border-radius:7px;font-size:12px;font-weight:500;cursor:pointer;transition:filter .1s;}
.btn:hover{filter:brightness(.9)}
.btn-p{background:var(--accent);color:#fff}
.btn-s{background:var(--tag-bg);color:var(--text)}
.btn-sm{padding:4px 10px;font-size:11.5px;}
/* ── Overlays ── */
.overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.42);z-index:100;align-items:flex-start;justify-content:center;padding-top:36px;overflow-y:auto;}
.overlay.on{display:flex}
#msg-modal,#confirm-modal{z-index:150;}
.modal{background:var(--surface);border-radius:13px;padding:20px;width:560px;max-width:96vw;box-shadow:0 10px 36px rgba(0,0,0,.24);margin-bottom:40px;}
.modal h2{font-size:14px;font-weight:600;margin-bottom:14px}
.fg{margin-bottom:10px}
.fg>label{display:flex;align-items:center;justify-content:space-between;font-size:11px;font-weight:500;color:var(--sub);margin-bottom:3px;}
.fg .hint{font-size:10px;color:var(--hint);font-weight:400;}
.fg input[type="text"]{width:100%;padding:7px 10px;border:1.5px solid var(--border);border-radius:7px;font-size:13px;outline:none;background:var(--surface);color:var(--text);font-family:inherit;transition:border-color .15s,box-shadow .15s;}
.fg input[type="text"]:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(0,122,255,.16);}
@media(prefers-color-scheme:dark){.fg input[type="text"]{background:#3a3a3c;border-color:#5a5a5c}}
.trig-row{display:flex;gap:6px;align-items:center;}
/* ── Trigger editor ── */
.trig-editor{
  flex:1;min-width:0;
  padding:5px 10px;border:1.5px solid var(--border);border-radius:7px;
  font-size:13px;line-height:1.4;outline:none;
  background:var(--surface);color:var(--text);font-family:inherit;
  cursor:text;white-space:nowrap;overflow:hidden;max-height:2.2em;
  transition:border-color .15s,box-shadow .15s;
}
.trig-editor:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(0,122,255,.16);}
.trig-editor:empty::before{content:attr(data-placeholder);color:var(--hint);pointer-events:none;}
@media(prefers-color-scheme:dark){.trig-editor{background:#3a3a3c;border-color:#5a5a5c}}
/* ── Magic key button ── */
.magic-btn{
  width:32px; justify-content:center; padding:0;
  padding-left:2px; padding-bottom:2px;
  border:1px solid var(--border); border-radius:7px;
  background:var(--tag-bg);color:var(--text);font-size:20px;font-weight:600;
  cursor:pointer;font-family:"SF Mono",Menlo,monospace;
  transition:filter .1s, border-color .15s;white-space:nowrap;line-height:1;
  display:flex;align-items:center;align-self:stretch;
}
.magic-btn:hover{filter:brightness(.93);border-color:var(--hint);}
/* ── Output contenteditable ── */
.output-editor{
  min-height:56px;max-height:200px;overflow-y:auto;
  padding:8px 10px;border:1.5px solid var(--border);border-radius:7px;
  font-size:13px;line-height:1.4;outline:none;
  background:var(--surface);color:var(--text);font-family:inherit;
  cursor:text;word-break:break-word;
  transition:border-color .15s,box-shadow .15s;
}
.output-editor:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(0,122,255,.16);}
@media(prefers-color-scheme:dark){.output-editor{background:#3a3a3c;border-color:#5a5a5c}}

/* ── Field validation errors ── */
@keyframes shake{
  0%,100%{transform:translateX(0)}
  20%,60%{transform:translateX(-4px)}
  40%,80%{transform:translateX(4px)}
}
.field-error {
  border-color: var(--danger) !important;
  box-shadow: 0 0 0 3px rgba(255,59,48,.18) !important;
  animation: shake .28s ease;
}
.field-error-msg {
  font-size: 11px;
  color: var(--danger);
  margin-top: 4px;
  display: none;
  align-items: center;
  gap: 4px;
}
.field-error-msg.on { display: flex; }
.field-error-msg::before { content: "⚠"; font-size: 11px; }

/* ── Warning banner (non-blocking) ── */
.field-warning-msg {
  font-size: 11px;
  color: var(--warning);
  background: var(--warning-bg);
  border: 1px solid rgba(255,149,0,.25);
  border-radius: 6px;
  padding: 5px 8px;
  margin-top: 4px;
  display: none;
  align-items: center;
  gap: 5px;
}
.field-warning-msg.on { display: flex; }
.field-warning-msg::before { content: "⚠️"; font-size: 11px; }

/* ── Fake Placeholder ── */
.editor-wrap { position: relative; }
.ph-overlay {
  position: absolute; top: 9px; left: 11px; right: 11px; pointer-events: none;
  color: var(--hint); font-size: 13px; display: none; user-select: none; line-height: 1.4;
}
.tc-ph {
  display:inline-block; background:rgba(142,142,147,.12); color:var(--hint);
  border:1px solid rgba(142,142,147,.2); border-radius:3px;
  padding:0 3px; font-family:"SF Mono",Menlo,monospace; font-size:10.5px;
  margin:0 1px; vertical-align: baseline; line-height:1.2;
}

/* ── Chips ── */
.token-chip{
  display:inline-block;
  background:var(--chip-bg);color:var(--chip-c);
  border:1px solid var(--chip-bd);border-radius:4px;
  padding:0 3px; margin:0 1px;
  font-family:"SF Mono",Menlo,monospace;font-size:11.5px;
  cursor:default;user-select:all;white-space:nowrap;vertical-align:baseline;
}
/* ── Autocomplete ── */
#ac-popup{display:none;position:fixed;background:var(--surface);border:1px solid var(--border);border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.18);z-index:999;padding:4px 0;min-width:140px;}
#ac-popup.on{display:block}
.ac-item{padding:5px 12px;cursor:pointer;font-family:"SF Mono",Menlo,monospace;font-size:12px;color:var(--chip-c);}
.ac-item.active,.ac-item:hover{background:var(--tag-on);color:var(--accent);}
/* ── Command grid ── */
details.cmd-help{background:var(--tag-bg);border-radius:7px;padding:7px 10px;margin-bottom:10px;}
details.cmd-help summary{cursor:pointer;font-weight:500;color:var(--text);font-size:11.5px;list-style:none;display:flex;align-items:center;gap:4px;}
details.cmd-help summary::-webkit-details-marker{display:none;}
details.cmd-help summary::before{content:"›";transition:transform .15s;}
details.cmd-help[open] summary::before{transform:rotate(90deg);}
.cmd-block{margin-top:8px;display:grid;grid-template-columns:repeat(4,1fr);gap:5px 6px;}
.cmd-sep{grid-column:1/-1;border:none;border-top:1px solid var(--border);margin:7px 0 3px;}
.cmd-grp-lbl{grid-column:1/-1;font-size:10px;color:var(--hint);text-transform:uppercase;letter-spacing:.06em;padding:2px 0;}
.cmd-ref{display:flex;flex-direction:column;align-items:center;gap:2px;cursor:pointer;padding:6px 3px;border-radius:5px;border:1px solid var(--border);background:var(--surface);color:var(--chip-c);transition:background .1s,filter .1s;user-select:none;}
.cmd-ref:hover{filter:brightness(.93);background:var(--chip-bg);}
.cmd-ref .cmd-sym{font-family:system-ui,-apple-system,"Helvetica Neue",sans-serif;font-size:18px;line-height:1.1;}
.cmd-ref .cmd-lbl{font-size:9px;color:var(--hint);text-align:center;line-height:1.2;}
/* ── Checkboxes ── */
.cbs{display:grid;grid-template-columns:1fr 1fr;gap:8px 16px;margin-bottom:13px}
.cb-item{display:flex;flex-direction:column;gap:2px;cursor:pointer;}
.cb-row{display:flex;align-items:center;gap:6px;}
.cb-row input{width:14px;height:14px;cursor:pointer;accent-color:var(--accent);flex-shrink:0;}
.cb-row input:focus{outline:2px solid var(--accent);outline-offset:1px;}
.cb-label{font-size:12px;font-weight:500;}
.cb-desc{font-size:10px;color:var(--hint);padding-left:20px;line-height:1.35;}
/* ── Modal footer ── */
.modal-foot{display:flex;justify-content:space-between;align-items:center;margin-top:15px;}
.foot-btns{display:flex;gap:8px;align-items:center;}
.foot-kbd{font-size:10.5px;color:var(--hint);line-height:2;}
.foot-kbd kbd{display:inline-block;background:var(--tag-bg);border:1px solid var(--border);border-radius:3px;padding:1px 5px;font-family:"SF Mono",Menlo,monospace;font-size:10px;color:var(--sub);}
#msg-modal .modal,#confirm-modal .modal{max-width:340px;}
#msg-modal p,#confirm-modal p{font-size:13px;line-height:1.5;margin-bottom:16px;color:var(--text);}
.star-badge{
  display:inline-block;
  background:var(--tag-bg);
  color:var(--text);
  border-radius:4px;
  padding:1px 3px 1px 5px;
  font-family:"SF Mono",Menlo,monospace;
  font-size:11px;
  font-weight:500;
  margin-left:2px;
  vertical-align:baseline;
}
#loading{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;gap:12px;color:var(--sub);font-size:13px;}
.spinner{width:24px;height:24px;border:2.5px solid var(--border);border-top-color:var(--accent);border-radius:50%;animation:spin .7s linear infinite;}
@keyframes spin{to{transform:rotate(360deg)}}
#save-toast{position:fixed;bottom:14px;left:50%;transform:translateX(-50%);background:#1c1c1e;color:#fff;border-radius:8px;padding:6px 14px;font-size:12px;pointer-events:none;opacity:0;transition:opacity .2s;z-index:200;}
#save-toast.show{opacity:1}
/* ── Bulk Bar ── */
#bulk-bar {
  display:none; position:fixed; bottom:20px; left:50%; transform:translateX(-50%);
  background:var(--surface); box-shadow:0 4px 20px rgba(0,0,0,0.15);
  padding:8px 12px; border-radius:12px; z-index:100; align-items:center; gap:12px;
  border:1px solid var(--border);
}
.bulk-cnt { font-weight:600; font-size:13px; color:var(--accent); white-space:nowrap; }
.bulk-sep { width:1px; height:18px; background:var(--border); }
</style>
</head>
<body>
<div id="loading"><div class="spinner"></div><span>Chargement…</span></div>

<div id="app" style="display:none">
  <div id="hdr">
    <h1>✏︎ Hotstrings Personnels</h1>
    <button id="compact-btn" class="btn btn-sm btn-s" onclick="toggleCompact()"></button>
    <button class="btn btn-sm btn-p" onclick="showAddSec()">＋ Section</button>
  </div>
  <div id="content">
    <div id="secs-container"></div>
    <div id="empty" class="empty" style="display:none">
      Aucun hotstring défini.<br>Cliquez sur <strong>+ Section</strong> pour commencer.<br>
      <small>☰ glisser pour réordonner — cliquer sur le titre pour renommer</small>
    </div>
  </div>
</div>

<div id="bulk-bar">
  <span id="bulk-cnt" class="bulk-cnt"></span>
  <div class="bulk-sep"></div>
  <select id="bulk-sec-sel" class="btn btn-s" style="margin:0; outline:none; font-weight:normal;" onchange="if(this.value!=='') bulkMove()">
     <option value="">Déplacer vers…</option>
  </select>
  <button class="btn btn-sm" style="background:#ffe5e3; color:var(--danger);" onclick="bulkDel()">Supprimer</button>
  <div class="bulk-sep"></div>
  <button class="btn btn-sm btn-s" style="background:transparent; padding:4px 8px;" onclick="clearBulk()">Annuler</button>
</div>

<div id="save-toast">Enregistré ✓</div>
<div id="ac-popup"></div>

<div class="overlay" id="msg-modal">
  <div class="modal"><p id="msg-text"></p>
    <div class="modal-foot" style="justify-content:flex-end">
      <button class="btn btn-p" onclick="closeModal('msg-modal')">OK</button></div></div>
</div>
<div class="overlay" id="confirm-modal">
  <div class="modal"><div id="confirm-text"></div>
    <div class="modal-foot">
      <button class="btn btn-s" id="confirm-cancel">Annuler</button>
      <button class="btn btn-p" id="confirm-ok">OK</button>
    </div></div>
</div>
<div class="overlay" id="sec-modal">
  <div class="modal">
    <h2 id="sec-modal-title">Nouvelle section</h2>
    <div class="fg">
      <label>Identifiant <span class="hint">(uniquement minuscules, chiffres et underscores)</span></label>
      <input id="sec-id" type="text" placeholder="ex : mes_abrev" autocomplete="off" spellcheck="false"/>
      <div class="field-error-msg" id="sec-id-err"></div>
    </div>
    <div class="fg">
      <label>Description <span class="hint">(affichée dans le menu)</span></label>
      <input id="sec-desc" type="text" placeholder="ex : Mes abréviations"/>
    </div>
    <div class="modal-foot"><span></span>
      <div class="foot-btns">
        <button class="btn btn-s" onclick="closeModal('sec-modal')">Annuler</button>
        <button class="btn btn-p" onclick="saveSec()">Enregistrer</button>
      </div>
    </div>
  </div>
</div>
<div class="overlay" id="entry-modal">
  <div class="modal">
    <h2 id="entry-modal-title">Nouveau hotstring</h2>
    <div class="fg">
      <label>Déclencheur <span class="hint" id="trig-hint"></span></label>
      <div class="trig-row">
        <div id="e-trig" class="trig-editor" contenteditable="true" spellcheck="false"
          data-placeholder="ex : btw"></div>
        <button class="magic-btn" id="magic-btn" onclick="insertMagicKey()"></button>
      </div>
      <div class="field-error-msg" id="trig-err"></div>
    </div>
    <div class="fg">
      <label>Remplacement</label>
      <div class="editor-wrap">
        <div id="e-out-ph" class="ph-overlay">ex : Bonjour,<span class="tc-ph">Enter</span>J’espère que vous allez bien.<span class="tc-ph">Enter</span><span class="tc-ph">Up</span><span class="tc-ph">End</span> — curseur après la virgule</div>
        <div id="e-out" class="output-editor" contenteditable="true" spellcheck="false"></div>
      </div>
      <div class="field-error-msg" id="out-err"></div>
    </div>
    <details class="cmd-help" id="cmd-help">
      <summary>Commandes spéciales — cliquer pour insérer</summary>
      <div class="cmd-block" id="cmd-block"></div>
    </details>
    <div class="cbs">
      <label class="cb-item">
        <div class="cb-row"><input type="checkbox" id="cb-word" onchange="updateCbDescs()"/><span class="cb-label">Mot complet</span></div>
        <span class="cb-desc" id="desc-word"></span>
      </label>
      <label class="cb-item">
        <div class="cb-row"><input type="checkbox" id="cb-auto" onchange="updateCbDescs()"/><span class="cb-label">Expansion auto</span></div>
        <span class="cb-desc" id="desc-auto"></span>
      </label>
      <label class="cb-item">
        <div class="cb-row"><input type="checkbox" id="cb-case" onchange="updateCbDescs()"/><span class="cb-label">Sensible à la casse</span></div>
        <span class="cb-desc" id="desc-case"></span>
      </label>
      <label class="cb-item">
        <div class="cb-row"><input type="checkbox" id="cb-final" onchange="updateCbDescs()"/><span class="cb-label">Résultat final</span></div>
        <span class="cb-desc" id="desc-final"></span>
      </label>
    </div>
    <div class="modal-foot">
      <span class="foot-kbd">
        <kbd>↩</kbd> = saut de ligne
        <br>
        <kbd>⌘</kbd> + <kbd>↩</kbd> = enregistrer
        <br>
        <kbd>⇧</kbd> + <kbd>⌘</kbd> + <kbd>↩</kbd> = enregistrer + nouveau hotstring
      </span>
      <div class="foot-btns">
        <button class="btn btn-s" onclick="closeModal('entry-modal')">Annuler</button>
        <button class="btn btn-p" onclick="saveEntry(false)">Enregistrer</button>
      </div>
    </div>
  </div>
</div>

<script>
window.addEventListener('focus', function(e){ if(e.target===window || e.target===document) toLua('window_focus',{focused:true}); }, true);
window.addEventListener('blur',  function(e){ if(e.target===window || e.target===document) toLua('window_focus',{focused:false}); }, true);

// ── Globals ───────────────────────────────────────────────────────────────────
var D=null, TRIGGER_CHAR='★', STAR='★';
var edSec=null, edEntry=null, dragSrcIdx=null;
var compactView=false, autoClose=false, defaultSec=null, openMode='menu';

// ── Token definitions ─────────────────────────────────────────────────────────
var TOKEN_NORM = {
  esc:'Escape',escape:'Escape',
  bs:'BackSpace',backspace:'BackSpace',
  del:'Delete',delete:'Delete',
  'return':'Enter',enter:'Enter',
  left:'Left',right:'Right',up:'Up',down:'Down',
  home:'Home',end:'End',tab:'Tab'
};
var TOKEN_NAMES=['Left','Right','Up','Down','Home','End','Tab','BackSpace','Delete','Escape','Enter'];

var CMD_GROUPS=[
  {lbl:'Flèches',cmds:[
    {token:'Left', sym:'←',desc:'gauche'},
    {token:'Right',sym:'→',desc:'droite'},
    {token:'Up',   sym:'↑',desc:'haut'},
    {token:'Down', sym:'↓',desc:'bas'},
  ]},
  {lbl:'Navigation',cmds:[
    {token:'Home',  sym:'Home',desc:'début ligne'},
    {token:'End',   sym:'End', desc:'fin ligne'},
    {token:'Tab',   sym:'⇥',  desc:'tabulation'},
    {token:'Escape',sym:'Esc', desc:'Échap'},
  ]},
  {lbl:'Édition',cmds:[
    {token:'BackSpace',sym:'⌫',desc:'effacer ←'},
    {token:'Delete',   sym:'⌦',desc:'effacer →'},
    {token:'Enter',    sym:'↩',desc:'saut de ligne'},
  ]},
];

function normToken(name){
  var c=TOKEN_NORM[name.toLowerCase()];
  if(c) return c;
  return name.charAt(0).toUpperCase()+name.slice(1);
}

// ── Lua bridge ────────────────────────────────────────────────────────────────
function toLua(action,data){
  try{window.webkit.messageHandlers.hsEditor.postMessage({action:action,data:data||{}});}
  catch(e){console.error('[hsEditor]',e);}
}

// ── Dynamic Descriptions ──────────────────────────────────────────────────────
function updateCbDescs() {
    var w = document.getElementById('cb-word').checked;
    var a = document.getElementById('cb-auto').checked;
    var c = document.getElementById('cb-case').checked;
    var f = document.getElementById('cb-final').checked;

    document.getElementById('desc-word').innerHTML = w
        ? "Ne se déclenche que si c’est un mot complet.<br>Ex : <em>tel</em>→téléphone mais pas <em>hôtel</em>"
        : "S’active partout, même comme sous-chaîne.<br>Ex : s’activera à l’intérieur de <em>hôtel</em>";

    document.getElementById('desc-auto').innerHTML = a
        ? "S’expand immédiatement (idéal pour les déclencheurs finissant par "+esc(TRIGGER_CHAR)+")."
        : "Nécessite de taper Espace/Entrée (conseillé pour l’autocorrection).";

    document.getElementById('desc-case').innerHTML = c
        ? "Différencie strictement majuscules/minuscules.<br>Ex : <em>Btw</em> ≠ <em>btw</em>"
        : "Le moteur générera les versions minuscule, Titlecase et MAJUSCULE.";

    document.getElementById('desc-final').innerHTML = f
        ? "Le résultat ne sera pas re-analysé comme déclencheur."
        : "Le résultat pourra déclencher d’autres hotstrings en cascade.";
}

// ── Field validation helpers ──────────────────────────────────────────────────
function setFieldError(fieldId, errId, msg) {
  var field = document.getElementById(fieldId);
  var err   = document.getElementById(errId);
  if (field) {
    field.classList.remove('field-error'); 
    void field.offsetWidth;                
    field.classList.add('field-error');
  }
  if (err && msg) {
    err.textContent = msg;
    err.classList.add('on');
  }
}
function clearFieldError(fieldId, errId) {
  var field = document.getElementById(fieldId);
  var err   = document.getElementById(errId);
  if (field) field.classList.remove('field-error');
  if (err)   { err.textContent = ''; err.classList.remove('on'); }
}
function clearEntryErrors() {
  clearFieldError('e-trig', 'trig-err');
  clearFieldError('e-out',  'out-err');
}
function clearSecErrors() {
  clearFieldError('sec-id', 'sec-id-err');
}

// ── Dialogs ───────────────────────────────────────────────────────────────────
function showAlert(msg){document.getElementById('msg-text').textContent=msg;openModal('msg-modal');}

var _confirmCb=null;
function showConfirm(msg,fn,opts){
  opts=opts||{};
  var titleHtml = '';
  if(opts.isWarning) {
    titleHtml = '<div style="display:flex;align-items:center;gap:8px;color:var(--warning);font-weight:600;font-size:15px;margin-bottom:10px;"><span style="font-size:20px;">⚠️</span> Attention</div>';
  }
  document.getElementById('confirm-text').innerHTML = titleHtml + '<div style="font-size:13px;line-height:1.5;margin-bottom:16px;color:var(--text);">' + msg + '</div>';
  var okBtn=document.getElementById('confirm-ok');
  okBtn.textContent=opts.okLabel||'Supprimer';
  okBtn.style.background=opts.okColor||'var(--danger)';
  _confirmCb=fn;
  openModal('confirm-modal');
}
document.getElementById('confirm-ok').addEventListener('click',function(){
  closeModal('confirm-modal');if(_confirmCb){var f=_confirmCb;_confirmCb=null;f();}
});
document.getElementById('confirm-cancel').addEventListener('click',function(){
  _confirmCb=null;closeModal('confirm-modal');
});

// ── Init ──────────────────────────────────────────────────────────────────────
window.initData=function(d){
  D=d;TRIGGER_CHAR=d.trigger_char||'★';STAR=d.star||'★';
  compactView=!!d.compact_view;autoClose=!!d.auto_close;
  defaultSec=d.default_section||null;openMode=d.open_mode||'menu';
  buildCmdGrid();updateHints();updateCompactBtn();
  document.getElementById('loading').style.display='none';
  document.getElementById('app').style.display='flex';
  render();
  if(openMode==='shortcut'&&defaultSec){
    var si=D.sections.findIndex(function(s){return s.name===defaultSec;});
    if(si>=0) setTimeout(function(){showAddEntry(si);},300);
  }
};
window.updateData=function(d){
  if(D&&D.sections&&d&&d.sections){
    var m={};D.sections.forEach(function(s){m[s.name]=s._exp;});
    d.sections.forEach(function(s){if(m[s.name]!==undefined)s._exp=m[s.name];});
  }
  D=d;TRIGGER_CHAR=d.trigger_char||TRIGGER_CHAR;
  compactView=!!d.compact_view;autoClose=!!d.auto_close;
  defaultSec=d.default_section||null;
  updateHints();render();
};

function buildCmdGrid(){
  var b=document.getElementById('cmd-block');b.innerHTML='';
  CMD_GROUPS.forEach(function(g,gi){
    if(gi>0){var s=document.createElement('hr');s.className='cmd-sep';b.appendChild(s);}
    var l=document.createElement('div');l.className='cmd-grp-lbl';l.textContent=g.lbl;b.appendChild(l);
    g.cmds.forEach(function(c){
      var el=document.createElement('div');
      el.className='cmd-ref';el.title='{'+c.token+'} — '+c.desc;
      el.innerHTML='<span class="cmd-sym">'+esc(c.sym)+'</span><span class="cmd-lbl">'+esc(c.desc)+'</span>';
      el.addEventListener('mousedown',function(e){e.preventDefault();});
      el.addEventListener('click',function(){insertChipAtCursor(c.token);});
      b.appendChild(el);
    });
  });
}

function updateHints(){
  var hint=document.getElementById('trig-hint');
  if(hint){
    if(TRIGGER_CHAR!==STAR)
      hint.innerHTML='<span class="star-badge">'+esc(TRIGGER_CHAR)+'</span> affiché, stocké en <span class="star-badge">'+esc(STAR)+'</span>';
    else hint.textContent='';
  }
  var mb=document.getElementById('magic-btn');if(mb)mb.textContent=TRIGGER_CHAR;
}
function updateCompactBtn(){
  var b=document.getElementById('compact-btn');
  if(b) b.textContent=compactView?'Vue développée':'Vue compacte';
}
function toggleCompact(){
  compactView=!compactView;updateCompactBtn();render();
  toLua('save_pref',{key:'compact_view',value:compactView});
}

// ── ★ normalization ───────────────────────────────────────────────────────────
function toDisplay(s){
  if(!s||TRIGGER_CHAR===STAR) return s||'';
  return String(s).split(STAR).join(TRIGGER_CHAR);
}
function toCanonical(s){
  if(!s||TRIGGER_CHAR===STAR) return s||'';
  return String(s).replace(new RegExp(TRIGGER_CHAR.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'g'),STAR);
}

// ── Output chip factory ───────────────────────────────────────────────────────
function makeChip(name){
  var s=document.createElement('span');
  s.className='token-chip';s.contentEditable='false';
  s.dataset.token=name;s.textContent=name;
  return s;
}

// ── Trig chip factory ─────────────────────────────────────────────────────────
function makeTrigChip(){
  var s=document.createElement('span');
  s.className='token-chip';s.contentEditable='false';
  s.dataset.trigChar='true';s.textContent=TRIGGER_CHAR;
  return s;
}
function setTrigContent(el,text){
  el.innerHTML='';
  if(!text) return;
  var display=toDisplay(text);
  var parts=display.split(TRIGGER_CHAR);
  parts.forEach(function(part,i){
    if(part) el.appendChild(document.createTextNode(part));
    if(i<parts.length-1) el.appendChild(makeTrigChip());
  });
}
function serializeTrigEditor(el){
  var s='';
  el.childNodes.forEach(function(n){
    if(n.nodeType===3) s+=toCanonical(n.textContent);
    else if(n.nodeType===1&&n.dataset&&n.dataset.trigChar) s+=STAR;
    else s+=toCanonical(n.textContent||'');
  });
  return s.trim();
}

// ── Fake Placeholder ─────────────────────────────────────────────────────────
function checkPh(){
  var ed = document.getElementById('e-out');
  var ph = document.getElementById('e-out-ph');
  ph.style.display = (ed.textContent.length === 0 && ed.innerHTML.indexOf('<span') === -1) ? 'block' : 'none';
}

// ── Parse canonical output string → DOM nodes ─────────────────────────────────
function parseToNodes(text){
  if(!text) return [document.createTextNode('')];
  text=toDisplay(text);
  var nodes=[],re=/\{([^}]+)\}/g,last=0,m;
  while((m=re.exec(text))!==null){
    if(m.index>last) nodes.push(document.createTextNode(text.slice(last,m.index)));
    var tname=normToken(m[1]);
    if(tname==='Enter') nodes.push(document.createElement('br'));
    else nodes.push(makeChip(tname));
    last=re.lastIndex;
  }
  if(last<text.length) nodes.push(document.createTextNode(text.slice(last)));
  return nodes;
}

// ── Serialize output editor DOM → canonical string ────────────────────────────
function serializeEditor(el){
  var nodes=Array.from(el.childNodes);
  while(nodes.length>0){
    var last=nodes[nodes.length-1];
    if(last.nodeType===1&&last.tagName==='BR'&&!last.classList.contains('token-chip'))
      nodes.pop();else break;
  }
  var s='';
  nodes.forEach(function(n){
    if(n.nodeType===3)                                                       s+=toCanonical(n.textContent);
    else if(n.nodeType===1&&n.classList.contains('token-chip')) s+='{'+n.dataset.token+'}';
    else if(n.nodeType===1&&n.tagName==='BR')                   s+='{Enter}';
    else                                                         s+=toCanonical(n.textContent||'');
  });
  return s;
}

function setEditorContent(el,text){
  el.innerHTML='';
  parseToNodes(text||'').forEach(function(n){el.appendChild(n);});
  checkPh();
}

// ── Insert helpers (output editor) ────────────────────────────────────────────
function insertBrAtCursor(){
  var ed=document.getElementById('e-out');ed.focus();
  var sel=window.getSelection();var br=document.createElement('br');
  if(sel&&sel.rangeCount){
    var r=sel.getRangeAt(0);
    if(ed.contains(r.commonAncestorContainer)){
      r.deleteContents();r.insertNode(br);
      if(!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
      var nr=document.createRange();nr.setStartAfter(br);nr.collapse(true);
      sel.removeAllRanges();sel.addRange(nr);
      checkPh();return;
    }
  }
  ed.appendChild(br);ed.appendChild(document.createTextNode(''));
  checkPh();
}

function insertChipAtCursor(name){
  if(name==='Enter'){insertBrAtCursor();return;}
  var ed=document.getElementById('e-out');ed.focus();
  var chip=makeChip(normToken(name));
  var sel=window.getSelection();
  if(sel&&sel.rangeCount){
    var r=sel.getRangeAt(0);
    if(ed.contains(r.commonAncestorContainer)){
      r.deleteContents();r.insertNode(chip);
      var nr=document.createRange();nr.setStartAfter(chip);nr.collapse(true);
      sel.removeAllRanges();sel.addRange(nr);
      checkPh();return;
    }
  }
  ed.appendChild(chip);
  var nr=document.createRange();nr.setStartAfter(chip);nr.collapse(true);
  sel=window.getSelection();if(sel){sel.removeAllRanges();sel.addRange(nr);}
  checkPh();
}

// ── Insert magic key into trig editor ────────────────────────────────────────
function insertMagicKey(){
  var te=document.getElementById('e-trig');te.focus();
  var chip=makeTrigChip();
  var sel=window.getSelection();
  if(sel&&sel.rangeCount){
    var r=sel.getRangeAt(0);
    if(te.contains(r.commonAncestorContainer)){
      r.deleteContents();r.insertNode(chip);
      var nr=document.createRange();nr.setStartAfter(chip);nr.collapse(true);
      sel.removeAllRanges();sel.addRange(nr);return;
    }
  }
  te.appendChild(chip);
  var nr=document.createRange();nr.setStartAfter(chip);nr.collapse(true);
  sel=window.getSelection();if(sel){sel.removeAllRanges();sel.addRange(nr);}
}

// ── Auto-convert {token} in output editor when } is typed ─────────────────────
function tryConvertToken(editor){
  var sel=window.getSelection();
  if(!sel||!sel.rangeCount) return;
  var range=sel.getRangeAt(0);if(!range.collapsed) return;
  var node=range.startContainer;if(node.nodeType!==3) return;
  var offset=range.startOffset;
  var before=node.textContent.slice(0,offset);
  var m=before.match(/\{(\w+)\}$/);if(!m) return;
  var tokenName=normToken(m[1]);
  if(TOKEN_NAMES.indexOf(tokenName)<0) return;
  var matchStart=offset-m[0].length;
  var r=document.createRange();
  r.setStart(node,matchStart);r.setEnd(node,offset);r.deleteContents();
  if(tokenName==='Enter'){
    var anch=sel.getRangeAt(0);var br=document.createElement('br');anch.insertNode(br);
    if(!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
    var nr=document.createRange();nr.setStartAfter(br);nr.collapse(true);
    sel.removeAllRanges();sel.addRange(nr);
    checkPh();return;
  }
  var chip=makeChip(tokenName);
  var anch=sel.getRangeAt(0);anch.insertNode(chip);
  var nr=document.createRange();nr.setStartAfter(chip);nr.collapse(true);
  sel.removeAllRanges();sel.addRange(nr);
  checkPh();
}

// ── Cursor ejector ────────────────────────────────────────────────────────────
var _ejecting=false;
function ejectFromChip(){
  if(_ejecting) return;
  var sel=window.getSelection();
  if(!sel||!sel.rangeCount||!sel.isCollapsed) return;
  var range=sel.getRangeAt(0);
  var node=range.startContainer;
  var el=(node.nodeType===3)?node.parentElement:node;
  if(el&&el.classList&&el.classList.contains('token-chip')){
    _ejecting=true;
    var nr=document.createRange();nr.setStartAfter(el);nr.collapse(true);
    sel.removeAllRanges();sel.addRange(nr);
    _ejecting=false;
  }
}
document.addEventListener('selectionchange',ejectFromChip);

// ── Autocomplete ──────────────────────────────────────────────────────────────
var acItems=[],acIdx=0;
function getAcCtx(){
  var sel=window.getSelection();if(!sel||!sel.rangeCount) return null;
  var r=sel.getRangeAt(0);if(!r.collapsed) return null;
  var n=r.startContainer;if(n.nodeType!==3) return null;
  var text=n.textContent.slice(0,r.startOffset);
  var m=text.match(/\{(\w*)$/);if(!m) return null;
  return{partial:m[1].toLowerCase(),start:r.startOffset-m[0].length,node:n};
}
function showAc(matches){
  var popup=document.getElementById('ac-popup');
  acItems=matches;acIdx=0;popup.innerHTML='';
  var sel=window.getSelection();if(!sel||!sel.rangeCount){hideAc();return;}
  var rect=sel.getRangeAt(0).getBoundingClientRect();
  matches.forEach(function(name,i){
    var d=document.createElement('div');d.className='ac-item'+(i===0?' active':'');
    d.textContent=name;
    d.addEventListener('mousedown',function(e){e.preventDefault();applyAc(name);});
    popup.appendChild(d);
  });
  popup.style.left=rect.left+'px';popup.style.top=(rect.bottom+4)+'px';
  popup.classList.add('on');
}
function hideAc(){document.getElementById('ac-popup').classList.remove('on');acItems=[];}
function updateAcSel(){document.querySelectorAll('.ac-item').forEach(function(el,i){el.classList.toggle('active',i===acIdx);});}
function applyAc(name){
  hideAc();
  var ctx=getAcCtx();
  if(!ctx){insertChipAtCursor(name);return;}
  var r=document.createRange();
  r.setStart(ctx.node,ctx.start);r.setEnd(ctx.node,ctx.start+ctx.partial.length+1);
  r.deleteContents();
  if(normToken(name)==='Enter'){
    var sel2=window.getSelection();var anch=sel2.getRangeAt(0);var br=document.createElement('br');
    anch.insertNode(br);
    if(!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
    var nr=document.createRange();nr.setStartAfter(br);nr.collapse(true);
    sel2.removeAllRanges();sel2.addRange(nr);
    checkPh();return;
  }
  var chip=makeChip(normToken(name));
  var sel3=window.getSelection();var anch2=sel3.getRangeAt(0);anch2.insertNode(chip);
  var nr2=document.createRange();nr2.setStartAfter(chip);nr2.collapse(true);
  sel3.removeAllRanges();sel3.addRange(nr2);
  checkPh();
}
function checkAc(){
  var ctx=getAcCtx();if(!ctx){hideAc();return;}
  var matches=TOKEN_NAMES.filter(function(n){return n.toLowerCase().startsWith(ctx.partial);});
  if(matches.length===0){hideAc();return;}
  showAc(matches);
}
document.addEventListener('click',function(e){
  if(!document.getElementById('ac-popup').contains(e.target)) hideAc();
});

// ── Output editor event wiring ────────────────────────────────────────────────
(function(){
  var ed=document.getElementById('e-out');

  ed.addEventListener('input', function() { clearFieldError('e-out','out-err'); });

  ed.addEventListener('keydown',function(e){
    if(acItems.length>0){
      if(e.key==='Tab'){e.preventDefault();applyAc(acItems[acIdx]);return;}
      if(e.key==='ArrowDown'||e.key==='ArrowRight'){e.preventDefault();acIdx=(acIdx+1)%acItems.length;updateAcSel();return;}
      if(e.key==='ArrowUp'||e.key==='ArrowLeft'){e.preventDefault();acIdx=(acIdx-1+acItems.length)%acItems.length;updateAcSel();return;}
      if(e.key==='Enter'&&!(e.metaKey||e.ctrlKey)){e.preventDefault();applyAc(acItems[acIdx]);return;}
      if(e.key==='Escape'){e.preventDefault();hideAc();return;}
    }

    if(e.key==='Enter'&&e.shiftKey&&(e.metaKey||e.ctrlKey)){e.preventDefault();saveEntry(true);return;}
    if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)){e.preventDefault();saveEntry(false);return;}
    if(e.key==='Enter'){e.preventDefault();insertBrAtCursor();return;}

    if(e.key==='Backspace'){
      var sel=window.getSelection();
      if(!sel||!sel.rangeCount) return;
      var range=sel.getRangeAt(0);if(!range.collapsed) return;
      var node=range.startContainer,offset=range.startOffset;
      var chip=null;
      if(node===ed&&offset>0){
        var p=ed.childNodes[offset-1];
        if(p&&p.nodeType===1&&p.classList.contains('token-chip')) chip=p;
      } else if(node.nodeType===3&&offset===0&&node.previousSibling){
        var p=node.previousSibling;
        if(p&&p.nodeType===1&&p.classList.contains('token-chip')) chip=p;
      }
      if(chip){e.preventDefault();chip.parentNode.removeChild(chip); checkPh(); return;}
    }

    if((e.key==='ArrowRight'||e.key==='ArrowLeft')&&!e.shiftKey){
      var sel=window.getSelection();
      if(!sel||!sel.rangeCount||!sel.isCollapsed) return;
      var range=sel.getRangeAt(0);
      var node=range.startContainer,offset=range.startOffset;
      if(e.key==='ArrowRight'){
        var next=null;
        if(node.nodeType===3&&offset===node.length) next=node.nextSibling;
        else if(node.nodeType===1&&offset<node.childNodes.length) next=node.childNodes[offset];
        if(next&&next.nodeType===1&&next.classList.contains('token-chip')){
          e.preventDefault();
          var nr=document.createRange();nr.setStartAfter(next);nr.collapse(true);
          sel.removeAllRanges();sel.addRange(nr);
        }
      } else {
        var prev=null;
        if(node.nodeType===3&&offset===0) prev=node.previousSibling;
        else if(node.nodeType===1&&offset>0) prev=node.childNodes[offset-1];
        if(prev&&prev.nodeType===1&&prev.classList.contains('token-chip')){
          e.preventDefault();
          var nr=document.createRange();nr.setStartBefore(prev);nr.collapse(true);
          sel.removeAllRanges();sel.addRange(nr);
        }
      }
    }
  });

  ed.addEventListener('input',function(){tryConvertToken(ed);checkAc();checkPh();});
  ed.addEventListener('keyup',function(e){
    if(acItems.length>0&&['Tab','ArrowDown','ArrowUp','ArrowLeft','ArrowRight','Escape','Enter'].indexOf(e.key)>=0) return;
    if(e.key==='}') tryConvertToken(ed);
    checkAc();
    checkPh();
  });
  ed.addEventListener('blur',hideAc);

  ed.addEventListener('paste',function(e){
    e.preventDefault();
    var text=(e.clipboardData||window.clipboardData).getData('text/plain');
    if(!text) return;
    var sel=window.getSelection();
    if(!sel||!sel.rangeCount){ed.appendChild(document.createTextNode(text)); checkPh(); return;}
    var r=sel.getRangeAt(0);r.deleteContents();
    var frag=document.createDocumentFragment();
    parseToNodes(text).forEach(function(n){frag.appendChild(n);});
    r.insertNode(frag);r.collapse(false);sel.removeAllRanges();sel.addRange(r);
    checkPh();
  });
})();

// ── Trig editor event wiring ──────────────────────────────────────────────────
(function(){
  var te=document.getElementById('e-trig');

  te.addEventListener('input', function() { clearFieldError('e-trig','trig-err'); });

  te.addEventListener('keydown',function(e){
    if(e.key==='Enter'){e.preventDefault();document.getElementById('e-out').focus();return;}
    if(e.key==='Tab'){e.preventDefault();document.getElementById('e-out').focus();return;}

    if(e.key==='Backspace'){
      var sel=window.getSelection();if(!sel||!sel.rangeCount) return;
      var range=sel.getRangeAt(0);if(!range.collapsed) return;
      var node=range.startContainer,offset=range.startOffset;
      var chip=null;
      if(node===te&&offset>0){
        var p=te.childNodes[offset-1];
        if(p&&p.nodeType===1&&p.classList.contains('token-chip')) chip=p;
      } else if(node.nodeType===3&&offset===0&&node.previousSibling){
        var p=node.previousSibling;
        if(p&&p.nodeType===1&&p.classList.contains('token-chip')) chip=p;
      }
      if(chip){e.preventDefault();chip.parentNode.removeChild(chip);return;}
    }

    if((e.key==='ArrowRight'||e.key==='ArrowLeft')&&!e.shiftKey){
      var sel=window.getSelection();if(!sel||!sel.rangeCount||!sel.isCollapsed) return;
      var range=sel.getRangeAt(0);
      var node=range.startContainer,offset=range.startOffset;
      if(e.key==='ArrowRight'){
        var next=null;
        if(node.nodeType===3&&offset===node.length) next=node.nextSibling;
        else if(node.nodeType===1&&offset<node.childNodes.length) next=node.childNodes[offset];
        if(next&&next.nodeType===1&&next.classList.contains('token-chip')){
          e.preventDefault();
          var nr=document.createRange();nr.setStartAfter(next);nr.collapse(true);
          sel.removeAllRanges();sel.addRange(nr);
        }
      } else {
        var prev=null;
        if(node.nodeType===3&&offset===0) prev=node.previousSibling;
        else if(node.nodeType===1&&offset>0) prev=node.childNodes[offset-1];
        if(prev&&prev.nodeType===1&&prev.classList.contains('token-chip')){
          e.preventDefault();
          var nr=document.createRange();nr.setStartBefore(prev);nr.collapse(true);
          sel.removeAllRanges();sel.addRange(nr);
        }
      }
    }
  });

  te.addEventListener('input',function(){
    var sel=window.getSelection();if(!sel||!sel.rangeCount) return;
    var range=sel.getRangeAt(0);if(!range.collapsed) return;
    var node=range.startContainer;if(node.nodeType!==3) return;
    var text=node.textContent;
    var idx=text.indexOf(TRIGGER_CHAR);if(idx<0) return;
    var before=text.slice(0,idx);
    var after=text.slice(idx+TRIGGER_CHAR.length);
    node.textContent=before;
    var chip=makeTrigChip();
    var afterNode=document.createTextNode(after);
    var refNode=node.nextSibling;
    if(refNode){node.parentNode.insertBefore(chip,refNode);node.parentNode.insertBefore(afterNode,chip.nextSibling);}
    else{node.parentNode.appendChild(chip);node.parentNode.appendChild(afterNode);}
    var nr=document.createRange();nr.setStart(afterNode,0);nr.collapse(true);
    sel.removeAllRanges();sel.addRange(nr);
  });

  te.addEventListener('paste',function(e){
    e.preventDefault();
    var text=(e.clipboardData||window.clipboardData).getData('text/plain');
    if(!text) return;
    var sel=window.getSelection();
    if(!sel||!sel.rangeCount){te.appendChild(document.createTextNode(text));return;}
    var r=sel.getRangeAt(0);r.deleteContents();
    var frag=document.createDocumentFragment();
    var parts=text.split(TRIGGER_CHAR);
    parts.forEach(function(part,i){
      if(part) frag.appendChild(document.createTextNode(part));
      if(i<parts.length-1) frag.appendChild(makeTrigChip());
    });
    r.insertNode(frag);r.collapse(false);sel.removeAllRanges();sel.addRange(r);
  });
})();

// ── Bulk actions ──────────────────────────────────────────────────────────────
window.updateBulk = function() {
  var cbs = document.querySelectorAll('.entry-cb:checked');
  var bar = document.getElementById('bulk-bar');
  if (cbs.length > 0) {
    var cnt = cbs.length;
    document.getElementById('bulk-cnt').textContent = cnt + " sélectionné" + (cnt > 1 ? "s" : "");
    var sel = document.getElementById('bulk-sec-sel');
    sel.innerHTML = '<option value="">Déplacer vers…</option>';
    D.sections.forEach(function(s, idx) {
       sel.innerHTML += '<option value="'+idx+'">' + esc(s.description||s.name) + '</option>';
    });
    bar.style.display = 'flex';
  } else {
    bar.style.display = 'none';
  }
};
window.clearBulk = function() {
  document.querySelectorAll('.entry-cb').forEach(function(cb) { cb.checked = false; });
  updateBulk();
};
window.bulkDel = function() {
   var cnt = document.querySelectorAll('.entry-cb:checked').length;
   showConfirm('Supprimer les ' + cnt + ' élément' + (cnt > 1 ? 's' : '') + ' sélectionné' + (cnt > 1 ? 's' : '') + ' ?', function() {
       var cbs = Array.from(document.querySelectorAll('.entry-cb:checked'));
       var toDel = cbs.map(function(cb) { return {si: parseInt(cb.dataset.si), ei: parseInt(cb.dataset.ei)}; });
       toDel.sort(function(a, b) { return a.si !== b.si ? b.si - a.si : b.ei - a.ei; });
       toDel.forEach(function(item) { D.sections[item.si].entries.splice(item.ei, 1); });
       clearBulk(); persist();
   });
};
window.bulkMove = function() {
   var sel = document.getElementById('bulk-sec-sel');
   var destSi = parseInt(sel.value);
   if (isNaN(destSi)) return;
   var cbs = Array.from(document.querySelectorAll('.entry-cb:checked'));
   var toMove = cbs.map(function(cb) { return {si: parseInt(cb.dataset.si), ei: parseInt(cb.dataset.ei)}; });
   toMove.sort(function(a, b) { return a.si !== b.si ? b.si - a.si : b.ei - a.ei; });
   toMove.forEach(function(item) {
       var entry = D.sections[item.si].entries.splice(item.ei, 1)[0];
       D.sections[destSi].entries.push(entry);
   });
   D.sections[destSi].entries.sort(function(a,b){
     var ta=(a.trigger||'').toLowerCase().replace(/[^\w]/g,'');
     var tb=(b.trigger||'').toLowerCase().replace(/[^\w]/g,'');
     return ta<tb?-1:ta>tb?1:0;
   });
   sel.value = ""; clearBulk(); persist();
};

// ── Render ────────────────────────────────────────────────────────────────────
function esc(s){return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

function dispTrig(s){
  if(!s) return '';
  var d=esc(toDisplay(s));
  return d.split(esc(TRIGGER_CHAR)).join('<span class="trig-star">'+esc(TRIGGER_CHAR)+'</span>');
}

function dispOutput(s){
  if(!s) return '';
  var out=esc(toDisplay(s));
  out=out.replace(/\{([^}]+)\}/g,function(_,name){
    var canon=normToken(name);
    return '<span class="tc" data-tok="'+esc(canon)+'">'+esc(canon)+'</span>';
  });
  if(!compactView){
    out=out.replace(/<span class="tc" data-tok="Enter">Enter<\/span>/g,'<br>');
  }
  return out;
}

var _rowMouseDownX=0,_rowMouseDownY=0;
function onRowMouseDown(e){_rowMouseDownX=e.clientX;_rowMouseDownY=e.clientY;}

function handleSecTitleClick(e,si){
  var dx=e.clientX-_rowMouseDownX,dy=e.clientY-_rowMouseDownY;
  if(Math.sqrt(dx*dx+dy*dy)>4) return;
  var sel=window.getSelection();if(sel&&sel.toString().length>0) return;
  showEditSec(si);
}

function render(){
  var cont=document.getElementById('secs-container');
  var empty=document.getElementById('empty');
  if(!D||!D.sections||!D.sections.length){cont.innerHTML='';empty.style.display='block';return;}
  empty.style.display='none';
  var html='';
  D.sections.forEach(function(s,si){
    var cnt=s.entries?s.entries.length:0;
    var exp=s._exp!==false;
    html+='<div class="sec-card" id="sc-'+si+'">';
    html+='<div class="sec-head'+(exp?' open':'')+'">'; 
    html+='<span class="drag-handle" id="dh-'+si+'" title="Glisser">☰</span>';
    html+='<span class="caret'+(exp?' open':'')+'" onclick="togSec('+si+')">▶</span>';
    html+='<span class="sec-title" onmousedown="onRowMouseDown(event)" onclick="handleSecTitleClick(event,'+si+')">'+esc(s.description||s.name)+'</span>';
    html+='<span class="sec-cnt">('+cnt+')</span>';
    html+='<button class="sec-del" onclick="delSec('+si+')" onmousedown="event.stopPropagation()">✕</button>';
    html+='</div>';
    if(exp){
      html+='<div class="'+(compactView?'compact':'expanded')+'">';
      (s.entries||[]).forEach(function(e,ei){
        html+='<div class="entry-row" onmousedown="onRowMouseDown(event)" onclick="handleRowClick(event,'+si+','+ei+')">';
        html+='<div class="entry-cb-wrap"><input type="checkbox" class="entry-cb" data-si="'+si+'" data-ei="'+ei+'" onclick="event.stopPropagation(); updateBulk()" onmousedown="event.stopPropagation()"></div>';
        html+='<div class="e-trig"><span class="trig-lbl" data-f="trig" title="Clic pour modifier">'+dispTrig(e.trigger)+'</span></div>';
        html+='<span class="e-arrow">→</span>';
        html+='<div class="e-out-cell"><div class="e-out" data-f="out" title="Clic pour modifier">'+dispOutput(e.output)+'</div></div>';
        html+='<div class="e-tags">';
        if(e.is_word)           html+='<span class="tag on" data-f="cb-word">Mot</span>';
        if(e.auto_expand)       html+='<span class="tag on" data-f="cb-auto">Auto</span>';
        if(e.is_case_sensitive) html+='<span class="tag on" data-f="cb-case">Casse</span>';
        if(e.final_result)      html+='<span class="tag on" data-f="cb-final">Final</span>';
        html+='</div>';
        html+='<span class="e-del" onclick="delEntryStop(event,'+si+','+ei+')">✕</span>';
        html+='</div>';
      });
      html+='<button class="btn-add" onclick="showAddEntry('+si+')">＋ Ajouter un hotstring</button>';
      html+='</div>';
    }
    html+='</div>';
  });
  cont.innerHTML=html;

  D.sections.forEach(function(_,si){
    var handle=document.getElementById('dh-'+si);
    var card=document.getElementById('sc-'+si);
    if(!handle||!card) return;
    handle.addEventListener('mousedown',function(){card.draggable=true;});
    card.addEventListener('dragstart',function(e){onDragStart(e,si);});
    card.addEventListener('dragover', function(e){onDragOver(e,si);});
    card.addEventListener('drop',     function(e){onDrop(e,si);});
    card.addEventListener('dragend',  function(){onDragEnd();});
  });
}

function handleRowClick(e,si,ei){
  var dx=e.clientX-_rowMouseDownX,dy=e.clientY-_rowMouseDownY;
  if(Math.sqrt(dx*dx+dy*dy)>4) return;
  var sel=window.getSelection();if(sel&&sel.toString().length>0) return;
  var target=e.target,field=null;
  while(target&&target!==e.currentTarget){
    if(target.dataset&&target.dataset.f){field=target.dataset.f;break;}
    target=target.parentElement;
  }
  showEditEntry(si,ei,field);
}

// ── Drag & drop ───────────────────────────────────────────────────────────────
function onDragStart(e,si){
  dragSrcIdx=si;e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',String(si));
  setTimeout(function(){var c=document.getElementById('sc-'+si);if(c)c.classList.add('dragging');},0);
}
function onDragOver(e,si){
  e.preventDefault();e.dataTransfer.dropEffect='move';
  document.querySelectorAll('.sec-card').forEach(function(c,i){c.classList.toggle('drag-over',i===si&&i!==dragSrcIdx);});
}
function onDrop(e,si){
  e.preventDefault();
  var c=document.getElementById('sc-'+si);if(c)c.draggable=false;
  if(dragSrcIdx===null||dragSrcIdx===si){cleanDrag();return;}
  var moved=D.sections.splice(dragSrcIdx,1)[0];
  D.sections.splice(si,0,moved);dragSrcIdx=null;persist();
}
function onDragEnd(){document.querySelectorAll('.sec-card').forEach(function(c){c.draggable=false;});cleanDrag();}
function cleanDrag(){dragSrcIdx=null;document.querySelectorAll('.sec-card').forEach(function(c){c.classList.remove('drag-over','dragging');});}
function togSec(si){if(D.sections[si]){D.sections[si]._exp=(D.sections[si]._exp===false);render();}}

// ── Section CRUD ──────────────────────────────────────────────────────────────
function showAddSec(){
  edSec=null;
  document.getElementById('sec-modal-title').textContent='Nouvelle section';
  var idEl=document.getElementById('sec-id');idEl.value='';idEl.disabled=false;
  document.getElementById('sec-desc').value='';
  clearSecErrors();
  openModal('sec-modal');setTimeout(function(){idEl.focus();},80);
}
function showEditSec(si){
  edSec=si;var s=D.sections[si];
  document.getElementById('sec-modal-title').textContent='Renommer la section';
  var idEl=document.getElementById('sec-id');idEl.value=s.name;idEl.disabled=true;
  document.getElementById('sec-desc').value=s.description||'';
  clearSecErrors();
  openModal('sec-modal');setTimeout(function(){document.getElementById('sec-desc').focus();},80);
}
document.getElementById('sec-id').addEventListener('input',function(){
  clearFieldError('sec-id','sec-id-err');
  var p=this.selectionStart;
  var c=this.value.toLowerCase().replace(/[^a-z0-9_]/g,'');
  if(c!==this.value){this.value=c;this.setSelectionRange(Math.max(0,p-1),Math.max(0,p-1));}
});
document.getElementById('sec-id').addEventListener('keydown',function(e){
  if(['Backspace','Delete','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End','Tab','Enter','Escape'].indexOf(e.key)>=0) return;
  if(e.metaKey||e.ctrlKey) return;
  if(!/^[a-z0-9_]$/i.test(e.key)) e.preventDefault();
});
function saveSec(){
  var id=document.getElementById('sec-id').value.trim();
  var desc=document.getElementById('sec-desc').value.trim();
  clearSecErrors();
  if(edSec===null){
    if(!id){
      setFieldError('sec-id','sec-id-err',"L’identifiant est requis.");
      document.getElementById('sec-id').focus();
      return;
    }
    if(!/^[a-z0-9_]+$/.test(id)){
      setFieldError('sec-id','sec-id-err','Identifiant invalide : uniquement minuscules, chiffres et underscores.');
      document.getElementById('sec-id').focus();
      return;
    }
    if(D.sections.some(function(s){return s.name===id;})){
      setFieldError('sec-id','sec-id-err','\u00ab '+id+' \u00bb existe déjà.');
      document.getElementById('sec-id').focus();
      return;
    }
    D.sections.push({name:id,description:desc||id,entries:[],_exp:true});
  } else {
    D.sections[edSec].description=desc||D.sections[edSec].name;
  }
  closeModal('sec-modal');persist();
}
function delSec(si){
  var s=D.sections[si];
  showConfirm('Supprimer \u00ab '+(s.description||s.name)+' \u00bb et tous ses hotstrings ?',function(){D.sections.splice(si,1);persist();});
}

// ── Entry CRUD ────────────────────────────────────────────────────────────────
function resetEntryForm(){
  document.getElementById('e-trig').innerHTML='';
  setEditorContent(document.getElementById('e-out'),'');
  document.getElementById('cb-word').checked=true;
  document.getElementById('cb-auto').checked=true;
  document.getElementById('cb-case').checked=false;
  document.getElementById('cb-final').checked=false;
  clearEntryErrors();
  updateHints();
  updateCbDescs();
  checkPh();
}
function showAddEntry(si){
  edEntry={si:si,ei:null};
  var secName = D.sections[si].description || D.sections[si].name;
  document.getElementById('entry-modal-title').textContent = 'Création d’un hotstring — Section «\xA0' + secName + '\xA0»';
  resetEntryForm();
  openModal('entry-modal');
  setTimeout(function(){document.getElementById('e-trig').focus();},80);
}
function showEditEntry(si,ei,focusField){
  edEntry={si:si,ei:ei};
  var e=D.sections[si].entries[ei];
  var secName = D.sections[si].description || D.sections[si].name;
  document.getElementById('entry-modal-title').textContent = 'Modification d’un hotstring — Section «\xA0' + secName + '\xA0»';
  setTrigContent(document.getElementById('e-trig'),e.trigger||'');
  setEditorContent(document.getElementById('e-out'),e.output||'');
  document.getElementById('cb-word').checked=!!e.is_word;
  document.getElementById('cb-auto').checked=!!e.auto_expand;
  document.getElementById('cb-case').checked=!!e.is_case_sensitive;
  document.getElementById('cb-final').checked=!!e.final_result;
  clearEntryErrors();
  updateHints();
  updateCbDescs();
  checkPh();
  openModal('entry-modal');
  
  setTimeout(function(){
    var el = null;
    if (focusField === 'out') {
        el = document.getElementById('e-out');
    } else if (focusField === 'trig') {
        el = document.getElementById('e-trig');
    } else if (focusField && focusField.indexOf('cb-') === 0) {
        el = document.getElementById(focusField);
    } else {
        el = document.getElementById('e-trig');
    }
    
    if (el) {
        el.focus();
        if (el.isContentEditable && typeof window.getSelection !== "undefined" && typeof document.createRange !== "undefined") {
            var range = document.createRange();
            range.selectNodeContents(el);
            range.collapse(false);
            var sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
        }
    }
  }, 80);
}

function saveEntry(andNew){
  clearEntryErrors();
  var trig=serializeTrigEditor(document.getElementById('e-trig'));
  var out=serializeEditor(document.getElementById('e-out'));

  // Blocking: empty trigger
  if(!trig){
    setFieldError('e-trig','trig-err','Le déclencheur est requis.');
    setTimeout(function(){document.getElementById('e-trig').focus();},0);
    return;
  }
  // Blocking: empty output
  if(!out.trim()){
    setFieldError('e-out','out-err','Le remplacement est requis.');
    setTimeout(function(){document.getElementById('e-out').focus();},0);
    return;
  }

  // Non-blocking: duplicate trigger warning (uses confirm dialog)
  var dupSection=null;
  D.sections.forEach(function(s,si2){
    (s.entries||[]).forEach(function(e2,ei2){
      if(dupSection) return;
      if(edEntry.ei!==null&&edEntry.si===si2&&ei2===edEntry.ei) return;
      if(e2.trigger===trig) dupSection=s.description||s.name;
    });
  });

  function doSave(){
    var entry={
      trigger:trig,output:out,
      is_word:document.getElementById('cb-word').checked,
      auto_expand:document.getElementById('cb-auto').checked,
      is_case_sensitive:document.getElementById('cb-case').checked,
      final_result:document.getElementById('cb-final').checked,
    };
    var si=edEntry.si;
    if(edEntry.ei===null) D.sections[si].entries.push(entry);
    else D.sections[si].entries[edEntry.ei]=entry;
    D.sections[si].entries.sort(function(a,b){
      var ta=(a.trigger||'').toLowerCase().replace(/[^\w]/g,'');
      var tb=(b.trigger||'').toLowerCase().replace(/[^\w]/g,'');
      return ta<tb?-1:ta>tb?1:0;
    });
    persist();
    if(andNew){
      edEntry={si:si,ei:null};
      var secName = D.sections[si].description || D.sections[si].name;
      document.getElementById('entry-modal-title').textContent = 'Création d’un hotstring — Section «\xA0' + secName + '\xA0»';
      resetEntryForm();
      setTimeout(function(){document.getElementById('e-trig').focus();},50);
      return;
    }
    // Auto-close only when opened via shortcut
    if(openMode==='shortcut'&&autoClose){
      closeModal('entry-modal');toLua('close',{});return;
    }
    closeModal('entry-modal');
  }

  if(dupSection){
    showConfirm(
      'Le déclencheur <strong>' + esc(toDisplay(trig)) + '</strong> existe déjà dans <em>' + esc(dupSection) + '</em>.<br><br>Voulez-vous vraiment le redéfinir ?',
      doSave,
      {okLabel:'Redéfinir', okColor:'#ff9500', isWarning:true}
    );
  } else {
    doSave();
  }
}

function delEntryStop(e,si,ei){e.stopPropagation();delEntry(si,ei);}
function delEntry(si,ei){
  var trig=toDisplay(D.sections[si].entries[ei].trigger);
  showConfirm('Supprimer \u00ab '+trig+' \u00bb ?',function(){D.sections[si].entries.splice(ei,1);persist();});
}

// ── Persist ───────────────────────────────────────────────────────────────────
function persist(){
  var payload={sections_order:[],sections:{}};
  D.sections.forEach(function(s){
    payload.sections_order.push(s.name);
    payload.sections[s.name]={
      description:s.description,
      entries:(s.entries||[]).map(function(e){
        return{trigger:e.trigger,output:e.output,
          is_word:!!e.is_word,auto_expand:!!e.auto_expand,
          is_case_sensitive:!!e.is_case_sensitive,final_result:!!e.final_result};
      }),
    };
  });
  toLua('save',payload);render();
  var t=document.getElementById('save-toast');t.classList.add('show');
  setTimeout(function(){t.classList.remove('show');},1400);
}

// ── Modal helpers ─────────────────────────────────────────────────────────────
function openModal(id){document.getElementById(id).classList.add('on');}
function closeModal(id){
  document.getElementById(id).classList.remove('on');
  if(id==='entry-modal') clearEntryErrors();
  if(id==='sec-modal')   clearSecErrors();
}
document.querySelectorAll('.overlay').forEach(function(el){
  el.addEventListener('click',function(e){if(e.target===el)closeModal(el.id);});
});
document.getElementById('msg-modal').addEventListener('keydown',function(e){if(e.key==='Enter'||e.key==='Escape')closeModal('msg-modal');});
document.getElementById('confirm-modal').addEventListener('keydown',function(e){if(e.key==='Escape'){_confirmCb=null;closeModal('confirm-modal');}});
document.getElementById('sec-modal').addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();saveSec();}if(e.key==='Escape')closeModal('sec-modal');});
document.getElementById('entry-modal').addEventListener('keydown',function(e){
  if(e.key==='Escape'){closeModal('entry-modal');return;}
});

document.addEventListener('DOMContentLoaded',function(){toLua('ready',{});});
</script>
</body>
</html>
]]

-- ============================================================================
-- 4. WEBVIEW MANAGEMENT
-- ============================================================================

function M.init(toml_path, keymap_mod, update_menu_fn)
    _toml_path   = toml_path
    _keymap      = keymap_mod
    _update_menu = update_menu_fn
    ensure_file()
end

function M.set_update_menu(fn)     _update_menu = fn     end
function M.set_update_pref(fn)     _update_pref = fn     end
function M.set_on_focus_change(fn) _on_focus_change = fn end

function M.set_trigger_char(char)
    _trigger_char = char or STAR_CANONICAL
    if _webview then
        local js_data  = load_js_data()
        local ok, json = pcall(hs.json.encode, js_data)
        if ok and json then _webview:evaluateJavaScript("window.updateData("..json..")") end
    end
end

-- Set which section (by name) is jumped to directly when opened via shortcut.
-- Pass nil to show the main view instead.
function M.set_default_section(section_name)
    _default_section = section_name or nil
    if _webview then
        local js_data  = load_js_data()
        local ok, json = pcall(hs.json.encode, js_data)
        if ok and json then _webview:evaluateJavaScript("window.updateData("..json..")") end
    end
end

-- When true, the editor closes automatically after an entry is added,
-- but ONLY when it was opened via the shortcut (not via the menu button).
function M.set_close_on_add(bool)
    _auto_close = (bool == true)
    if _webview then
        local js_data  = load_js_data()
        local ok, json = pcall(hs.json.encode, js_data)
        if ok and json then _webview:evaluateJavaScript("window.updateData("..json..")") end
    end
end

function M.set_ui_prefs(prefs)
    if type(prefs) ~= "table" then return end
    if prefs.compact_view    ~= nil then _compact_view    = prefs.compact_view    end
    if prefs.auto_close      ~= nil then _auto_close      = prefs.auto_close      end
    if prefs.default_section ~= nil then _default_section = prefs.default_section end
end

local _pending_open_mode = "menu"

function M.open(open_mode)
    _pending_open_mode = open_mode or "menu"

    if _webview then
        if open_mode == "shortcut" and _default_section and _default_section ~= "" then
            local ds = _default_section
            _webview:evaluateJavaScript(
                'openMode="shortcut";'
                .. '(function(){'
                .. 'if(!D)return;'
                .. 'var si=D.sections.findIndex(function(s){return s.name=='
                .. string.format("%q", ds) .. ';});'
                .. 'if(si>=0)setTimeout(function(){showAddEntry(si);},80);'
                .. '})()'
            )
        else
            _webview:evaluateJavaScript('openMode="menu";')
        end
        _webview:show()
        local win = _webview:hswindow()
        if win then
            win:focus()
            _is_focused = true
        end
        return
    end

    _usercontent = hs.webview.usercontent.new("hsEditor")
    _usercontent:setCallback(function(message)
        if message and message.body then
            local body = message.body
            if type(body) == "table" and body.action == "ready" then
                body.open_mode = _pending_open_mode
            end
            handle_message(body)
        end
    end)

    local sf    = hs.screen.mainScreen():frame()
    local w, h  = 760, 640
    local frame = {
        x = math.floor(sf.x + (sf.w - w) / 2),
        y = math.floor(sf.y + (sf.h - h) / 2),
        w = w, h = h,
    }

    _webview = hs.webview.new(frame, { developerExtrasEnabled = false }, _usercontent)
    _webview:windowTitle("Hotstrings Personnels")
    local masks = hs.webview.windowMasks
    _webview:windowStyle(
        (masks["titled"]         or 1) + (masks["closable"]       or 2)
      + (masks["resizable"]      or 8) + (masks["miniaturizable"] or 4))
    _webview:allowTextEntry(true)
    _webview:level(hs.drawing.windowLevels.normal)

    _webview:windowCallback(function(action)
        if action == "closing" or action == "closed" then
            _is_focused = false
            if _on_focus_change then _on_focus_change(false) end
            _webview     = nil
            _usercontent = nil
        end
    end)

    _webview:html(HTML)
    _webview:show()
    hs.timer.doAfter(0.12, function()
        if _webview then
            _webview:show()
            local win = _webview:hswindow()
            if win then
                win:focus()
                _is_focused = true
            end
        end
    end)
end

function M.close()
    if _webview then
        -- Restart keymap before destroying the window
        _webview:delete()
        _webview     = nil
        _usercontent = nil
        _is_focused  = false
        if _on_focus_change then _on_focus_change(false) end
    end
end

function M.is_open() return _webview ~= nil end

-- Returns true only when the editor window is currently the frontmost window.
function M.is_editor_focused()
    return _is_focused
end

-- ============================================================================
-- 5. GLOBAL SHORTCUT
-- ============================================================================

function M.set_shortcut(mods, key)
    if _hotkey then _hotkey:delete(); _hotkey = nil end
    if mods and key and key ~= "" then
        local ok
        ok, _hotkey = pcall(hs.hotkey.new, mods, key, function() M.open("shortcut") end)
        if ok and _hotkey then _hotkey:enable() else _hotkey = nil end
    end
end

function M.clear_shortcut()
    if _hotkey then _hotkey:delete(); _hotkey = nil end
end

return M
