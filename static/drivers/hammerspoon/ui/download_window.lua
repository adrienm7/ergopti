-- ui/download_window.lua
-- Fenêtre flottante de progression (hs.webview).
-- Communication JS→Lua via hs.webview.usercontent (WKScriptMessageHandler)

local M = {}

local _wv        = nil
local _on_cancel = nil
local _start_ts  = nil
local _ready     = false
local _queued    = {}   -- updates reçus avant que le DOM soit prêt

local _ucc = hs.webview.usercontent.new("dl_bridge")
_ucc:setCallback(function(msg)
    if msg.body == "cancel" then
        if _on_cancel then pcall(_on_cancel) end
    elseif msg.body == "terminal" then
        local model = M._current_model or ""
        local cmd   = "ollama pull " .. model
        hs.execute(string.format(
            'osascript -e \'tell application "Terminal" to do script "%s"\' -e \'tell application "Terminal" to activate\'',
            cmd:gsub("'", "'\\''")
        ))
    end
end)

local HTML = [[<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
body{
  font-family:-apple-system,"SF Pro Text","Helvetica Neue",sans-serif;
  background:#242426;color:#e8e8ea;
  padding:18px 20px;-webkit-app-region:drag;user-select:none;height:100vh
}
h2{font-size:14px;font-weight:600;color:#fff;margin-bottom:4px}
#model{font-size:11px;color:#999;margin-bottom:12px;font-family:"SF Mono",monospace;word-break:break-all}
#bar-bg{background:#3a3a3c;border-radius:4px;height:7px;overflow:hidden;margin-bottom:10px}
#bar-fill{background:linear-gradient(90deg,#30d158,#34c759);height:100%;width:0%;border-radius:4px;transition:width .35s ease}
#pct{font-size:30px;font-weight:700;color:#30d158;letter-spacing:-1px;margin-bottom:5px}
#stats{font-size:12px;color:#888;line-height:1.8;min-height:44px;margin-bottom:14px}
#stats b{color:#ccc;font-weight:500}
.btn-row{display:flex;gap:8px;-webkit-app-region:no-drag}
button{border-radius:8px;font-size:12px;font-weight:500;padding:6px 14px;cursor:pointer;border:1px solid}
#btn-cancel{background:rgba(255,59,48,.12);border-color:rgba(255,59,48,.45);color:#ff453a}
#btn-cancel:hover{background:rgba(255,59,48,.22)}
#btn-cancel:disabled{opacity:.35;cursor:default}
#btn-term{background:rgba(100,100,100,.15);border-color:rgba(150,150,150,.35);color:#aaa}
#btn-term:hover{background:rgba(100,100,100,.28)}
#done-msg{font-size:13px;font-weight:600;margin-top:10px;display:none}
#done-msg.ok{color:#30d158}#done-msg.error{color:#ff453a}
#log-area{display:none;margin-top:10px;background:#1a1a1c;border-radius:6px;padding:8px;
  font-family:"SF Mono",monospace;font-size:10px;color:#888;max-height:80px;overflow-y:auto;
  white-space:pre-wrap;word-break:break-all}
</style></head><body>
  <h2>📥 Téléchargement en cours</h2>
  <div id="model">—</div>
  <div id="bar-bg"><div id="bar-fill"></div></div>
  <div id="pct">0 %</div>
  <div id="stats">Démarrage…</div>
  <div class="btn-row">
    <button id="btn-cancel" onclick="doCancel()">🛑 Annuler</button>
    <button id="btn-term" onclick="doTerm()">🖥 Terminal</button>
  </div>
  <div id="done-msg"></div>
  <div id="log-area" id="log"></div>
<script>
var _logLines = [];
function doCancel(){
  document.getElementById('btn-cancel').disabled=true;
  document.getElementById('btn-cancel').textContent='Annulation…';
  if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge){
      window.webkit.messageHandlers.dl_bridge.postMessage('cancel');
  }
}
function doTerm(){
  if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge){
      window.webkit.messageHandlers.dl_bridge.postMessage('terminal');
  }
}
function setModel(n){document.getElementById('model').textContent=n}
function update(pct,dl,speed,eta){
  document.getElementById('bar-fill').style.width=pct+'%';
  document.getElementById('pct').textContent=pct+' %';
  var s='';
  if(dl)    s+='<b>'+dl+'</b><br>';
  if(speed) s+='Vitesse : <b>'+speed+'</b>';
  if(eta)   s+='  ·  Temps restant : <b>'+eta+'</b>';
  document.getElementById('stats').innerHTML=s||'Téléchargement en cours…';
}
function addLog(line){
  _logLines.push(line);
  if(_logLines.length>200) _logLines.shift();
  var el=document.getElementById('log-area');
  el.textContent=_logLines.join('\n');
  el.scrollTop=el.scrollHeight;
}
function showLog(){document.getElementById('log-area').style.display='block'}
function done(ok,msg){
  document.getElementById('btn-cancel').style.display='none';
  document.getElementById('bar-fill').style.width='100%';
  document.getElementById('pct').textContent=ok?'100 %':'—';
  var d=document.getElementById('done-msg');
  d.textContent=msg;d.className=ok?'ok':'error';d.style.display='block';
  document.getElementById('stats').textContent='';
}
</script></body></html>]]

-- ─────────────────────────────────────────────────────────
local function fmt_bytes(b)
    if not b or b <= 0 then return nil end
    if b > 1e9 then return string.format("%.1f Go", b/1e9) end
    if b > 1e6 then return string.format("%.0f Mo", b/1e6) end
    return string.format("%.0f Ko", b/1e3)
end
local function fmt_time(s)
    if not s or s <= 0 or s ~= s or s == math.huge then return nil end
    if s > 3600 then return string.format("%dh%02dm", math.floor(s/3600), math.floor((s%3600)/60)) end
    if s > 60   then return string.format("%dm%02ds", math.floor(s/60), math.floor(s%60)) end
    return string.format("%ds", math.floor(s))
end
local function js_str(s)
    if not s then return "null" end
    return '"' .. tostring(s):gsub('\\','\\\\'):gsub('"','\\"') .. '"'
end
local function eval(code)
    if _wv then pcall(function() _wv:evaluateJavaScript(code) end) end
end

-- ─────────────────────────────────────────────────────────
function M.hide()
    if _wv then pcall(function() _wv:delete() end); _wv=nil end
    _on_cancel=nil; _start_ts=nil; _ready=false; _queued={}
end

function M.show(model_name, on_cancel)
    M.hide()
    M._current_model = model_name
    _on_cancel = on_cancel
    _start_ts  = hs.timer.secondsSinceEpoch()
    _ready     = false
    _queued    = {}

    local screen = hs.screen.mainScreen():frame()
    local W, H   = 380, 240
    local x = screen.x + screen.w - W - 18
    local y = screen.y + screen.h - H - 50

    _wv = hs.webview.new({x=x, y=y, w=W, h=H}, {}, _ucc)
    _wv:windowStyle({"titled","closable","nonactivating"})
    _wv:windowTitle("Téléchargement du modèle")
    _wv:level(hs.drawing.windowLevels.floating)
    _wv:allowGestures(false)
    _wv:allowNewWindows(false)

    _wv:navigationCallback(function(action)
        if action == "didFinishNavigation" then
            _ready = true
            local safe = (model_name or ""):gsub("'", "\\'"):gsub('"', '\\"')
            eval("setModel('" .. safe .. "')")
            for _, q in ipairs(_queued) do eval(q) end
            _queued = {}
        end
        return true
    end)

    _wv:html(HTML)
    _wv:show()

    -- Fallback : si l'event ne se déclenche pas, on se déclare prêt après 1s
    hs.timer.doAfter(1.0, function()
        if _wv and not _ready then
            _ready = true
            local safe = (model_name or ""):gsub("'", "\'"):gsub('"', '\"')
            eval("setModel('" .. safe .. "')")
            for _, q in ipairs(_queued) do eval(q) end
            _queued = {}
        end
    end)
end

function M.update(pct_str, bytes_done, bytes_total, raw_line)
    if not _wv then return end
    local pct     = tonumber(pct_str) or 0
    local elapsed = hs.timer.secondsSinceEpoch() - (_start_ts or hs.timer.secondsSinceEpoch())

    local dl_str, speed_str, eta_str

    if bytes_total and bytes_total > 0 then
        local ds = fmt_bytes(bytes_done); local ts = fmt_bytes(bytes_total)
        if ds and ts then dl_str = ds .. " / " .. ts end
    elseif bytes_done and bytes_done > 0 then
        dl_str = fmt_bytes(bytes_done)
    end

    if bytes_done and bytes_done > 0 and elapsed > 2 then
        local speed = bytes_done / elapsed
        speed_str = fmt_bytes(speed) and (fmt_bytes(speed) .. "/s") or nil
        if bytes_total and bytes_total > bytes_done and speed > 0 then
            eta_str = fmt_time((bytes_total - bytes_done) / speed)
        end
    end

    local js = string.format("update(%d,%s,%s,%s)",
        math.floor(pct), js_str(dl_str), js_str(speed_str), js_str(eta_str))

    if _ready then
        eval(js)
        if raw_line and raw_line ~= "" then
            local safe = raw_line:gsub("\\","\\\\"):gsub('"','\\"'):gsub("\n","\\n"):gsub("\r","")
            eval('addLog("' .. safe .. '")')
        end
    else
        _queued[#_queued+1] = js
        if #_queued > 30 then table.remove(_queued, 1) end
    end
end

function M.complete(success, _model_name)
    if not _wv then return end
    local msg = success and "✅ Installation terminée !" or "❌ Échec du téléchargement"
    local js  = string.format("done(%s,%s); showLog()", success and "true" or "false", js_str(msg))
    if _ready then eval(js)
    else _queued[#_queued+1] = js end
    if success then hs.timer.doAfter(4, M.hide) end
end

return M
