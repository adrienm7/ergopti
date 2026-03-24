-- ===========================================================================
-- ui/prompt_editor.lua
-- ===========================================================================

local M = {}

local hs = hs

local _webview = nil
local _usercontent = nil

local HTML = [=[
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#f2f2f7;--surface:#fff;--border:#d1d1d6;
  --text:#1d1d1f;--sub:#6e6e73;--hint:#8e8e93;
  --accent:#007aff;--danger:#ff3b30;
  --chip-bg:#ddeeff;--chip-c:#1a4bbf;--chip-bd:rgba(26,75,191,.22);
}
@media(prefers-color-scheme:dark){:root{
  --bg:#1c1c1e;--surface:#2c2c2e;--border:#3a3a3c;
  --text:#fff;--sub:rgba(235,235,245,.6);--hint:#636366;
  --accent:#0a84ff;--danger:#ff453a;
  --chip-bg:#183060;--chip-c:#93b8f8;--chip-bd:rgba(147,184,248,.28);
}}
body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;font-size:13px;line-height:1.5;color:var(--text);background:var(--bg);height:100vh;display:flex;flex-direction:column;padding:20px;-webkit-app-region:drag;}
h2{font-size:15px;font-weight:600;margin-bottom:16px;}
.fg{margin-bottom:14px;display:flex;flex-direction:column;}
.fg-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:5px;}
label{font-size:12px;font-weight:500;color:var(--sub);}
input, select {
  width:100%;padding:8px 10px;border:1.5px solid var(--border);border-radius:7px;
  font-size:13px;outline:none;background:var(--surface);color:var(--text);font-family:inherit;
  transition:border-color .15s,box-shadow .15s;-webkit-app-region:no-drag;
}
input:focus, select:focus {border-color:var(--accent);box-shadow:0 0 0 3px rgba(0,122,255,.16);}

/* ── ContentEditable Editor ── */
.editor-wrap { position: relative; flex-grow: 1; display:flex; flex-direction:column; -webkit-app-region:no-drag; }
.output-editor {
  flex-grow: 1; min-height:120px; padding:10px; border:1.5px solid var(--border); border-radius:7px;
  font-size:13px; line-height:1.5; outline:none; background:var(--surface); color:var(--text); font-family:inherit;
  cursor:text; word-break:break-word; overflow-y:auto; transition:border-color .15s,box-shadow .15s;
}
.output-editor:focus { border-color:var(--accent); box-shadow:0 0 0 3px rgba(0,122,255,.16); }

/* ── Chips (Pilules) ── */
.token-chip {
  display:inline-block; background:var(--chip-bg); color:var(--chip-c);
  border:1px solid var(--chip-bd); border-radius:5px;
  padding:1px 5px; margin:0 2px; font-family:"SF Mono",Menlo,monospace; font-size:11.5px;
  cursor:default; user-select:all; white-space:nowrap; vertical-align:baseline;
}

/* ── Fake Placeholder ── */
.ph-overlay {
  position:absolute; top:11px; left:12px; right:12px; pointer-events:none;
  color:var(--hint); font-size:13px; display:none; user-select:none; line-height:1.5;
}
.tc-ph {
  display:inline-block; background:rgba(142,142,147,.12); color:var(--hint);
  border:1px solid rgba(142,142,147,.2); border-radius:5px;
  padding:1px 5px; font-family:"SF Mono",Menlo,monospace; font-size:11.5px;
  margin:0 2px; vertical-align:baseline;
}

/* ── Buttons ── */
.btn-row{display:flex;gap:8px;justify-content:flex-end;margin-top:auto;padding-top:10px;-webkit-app-region:no-drag;}
.btn{padding:7px 14px;border:none;border-radius:7px;font-size:13px;font-weight:500;cursor:pointer;transition:filter .1s;}
.btn:hover{filter:brightness(.9)}
.btn-p{background:var(--accent);color:#fff}
.btn-s{background:var(--surface);color:var(--text);border:1px solid var(--border);}
.btn-sm{padding:3px 8px;font-size:11px;}
.help{font-size:11px;color:var(--hint);margin-top:6px;}
</style>
</head>
<body>
  <h2 id="title">Nouveau profil</h2>
  <div class="fg">
    <div class="fg-header"><label>Nom du profil</label></div>
    <input type="text" id="p-name" autocomplete="off" spellcheck="false">
  </div>
  <div class="fg">
    <div class="fg-header"><label>Mode de requête</label></div>
    <select id="p-mode">
      <option value="parallel">Parallèle</option>
      <option value="batch">Groupée (Batch)</option>
    </select>
  </div>
  <div class="fg" style="flex-grow:1; display:flex;">
    <div class="fg-header">
        <label>Prompt système</label>
        <button class="btn btn-sm btn-s" onclick="insertChipAtCursor('context')" title="Insérer le bloc {context}">＋ {context}</button>
    </div>
    <div class="editor-wrap">
      <div id="e-out-ph" class="ph-overlay">Voici un texte, continue-le : <span class="tc-ph">{context}</span></div>
      <div id="e-out" class="output-editor" contenteditable="true" spellcheck="false"></div>
    </div>
    <div class="help">Le bloc {context} sera remplacé par le texte sélectionné par l'utilisateur.</div>
  </div>
  <div class="btn-row">
    <button class="btn btn-s" onclick="doCancel()">Annuler</button>
    <button class="btn btn-p" onclick="doSave()">Enregistrer</button>
  </div>

<script>
// ── Chips Engine ──────────────────────────────────────────────────
function makeChip(name){
  var s = document.createElement('span');
  s.className = 'token-chip'; s.contentEditable = 'false';
  s.dataset.token = name; s.textContent = '{' + name + '}';
  return s;
}

function parseToNodes(text) {
  if(!text) return [document.createTextNode('')];
  var nodes = [];
  var normalized = text.replace(/\n/g, '{Enter}');
  var re = /\{([^}]+)\}/gi, last = 0, m;
  while((m = re.exec(normalized)) !== null) {
    if(m.index > last) nodes.push(document.createTextNode(normalized.slice(last, m.index)));
    var tname = m[1].toLowerCase();
    if(tname === 'enter') {
      nodes.push(document.createElement('br'));
    } else if (tname === 'context') {
      nodes.push(makeChip('context'));
    } else {
      nodes.push(document.createTextNode(m[0]));
    }
    last = re.lastIndex;
  }
  if(last < normalized.length) nodes.push(document.createTextNode(normalized.slice(last)));
  return nodes;
}

function serializeEditor(el) {
  var nodes = Array.from(el.childNodes);
  while(nodes.length > 0) {
    var last = nodes[nodes.length-1];
    if(last.nodeType === 1 && last.tagName === 'BR' && !last.classList.contains('token-chip')) nodes.pop();
    else break;
  }
  var s = '';
  nodes.forEach(n => {
    if(n.nodeType === 3) s += n.textContent;
    else if(n.nodeType === 1 && n.classList.contains('token-chip')) s += '{' + n.dataset.token + '}';
    else if(n.nodeType === 1 && n.tagName === 'BR') s += '\n';
    else s += n.textContent || '';
  });
  return s;
}

function checkPh() {
  var ed = document.getElementById('e-out');
  var ph = document.getElementById('e-out-ph');
  ph.style.display = (ed.textContent.length === 0 && ed.innerHTML.indexOf('<span') === -1) ? 'block' : 'none';
}

function insertBrAtCursor() {
  var ed = document.getElementById('e-out'); ed.focus();
  var sel = window.getSelection(); var br = document.createElement('br');
  if(sel && sel.rangeCount) {
    var r = sel.getRangeAt(0);
    if(ed.contains(r.commonAncestorContainer)) {
      r.deleteContents(); r.insertNode(br);
      if(!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
      var nr = document.createRange(); nr.setStartAfter(br); nr.collapse(true);
      sel.removeAllRanges(); sel.addRange(nr);
      checkPh(); return;
    }
  }
  ed.appendChild(br); ed.appendChild(document.createTextNode(''));
  checkPh();
}

function insertChipAtCursor(name) {
  var ed = document.getElementById('e-out'); ed.focus();
  var chip = makeChip(name);
  var sel = window.getSelection();
  if(sel && sel.rangeCount) {
    var r = sel.getRangeAt(0);
    if(ed.contains(r.commonAncestorContainer)) {
      r.deleteContents(); r.insertNode(chip);
      var nr = document.createRange(); nr.setStartAfter(chip); nr.collapse(true);
      sel.removeAllRanges(); sel.addRange(nr);
      checkPh(); return;
    }
  }
  ed.appendChild(chip);
  var nr = document.createRange(); nr.setStartAfter(chip); nr.collapse(true);
  sel = window.getSelection(); if(sel){ sel.removeAllRanges(); sel.addRange(nr); }
  checkPh();
}

function tryConvertToken(editor) {
  var sel = window.getSelection();
  if(!sel || !sel.rangeCount) return;
  var range = sel.getRangeAt(0); if(!range.collapsed) return;
  var node = range.startContainer; if(node.nodeType !== 3) return;
  var offset = range.startOffset;
  var before = node.textContent.slice(0, offset);
  var m = before.match(/\{context\}$/i);
  if(!m) return;
  
  var matchStart = offset - m[0].length;
  var r = document.createRange();
  r.setStart(node, matchStart); r.setEnd(node, offset); r.deleteContents();
  
  var chip = makeChip('context');
  var anch = sel.getRangeAt(0); anch.insertNode(chip);
  var nr = document.createRange(); nr.setStartAfter(chip); nr.collapse(true);
  sel.removeAllRanges(); sel.addRange(nr);
  checkPh();
}

// ── Events Wiring ─────────────────────────────────────────────────
var ed = document.getElementById('e-out');
ed.addEventListener('input', function() { tryConvertToken(ed); checkPh(); });
ed.addEventListener('keyup', function(e) { if(e.key === '}') tryConvertToken(ed); checkPh(); });
ed.addEventListener('keydown', function(e) {
  if(e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); doSave(); return; }
  if(e.key === 'Enter') { e.preventDefault(); insertBrAtCursor(); return; }
  if(e.key === 'Backspace') {
    var sel = window.getSelection(); if(!sel || !sel.rangeCount) return;
    var range = sel.getRangeAt(0); if(!range.collapsed) return;
    var node = range.startContainer, offset = range.startOffset;
    var chip = null;
    if(node === ed && offset > 0) {
      var p = ed.childNodes[offset-1];
      if(p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
    } else if(node.nodeType === 3 && offset === 0 && node.previousSibling) {
      var p = node.previousSibling;
      if(p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
    }
    if(chip) { e.preventDefault(); chip.parentNode.removeChild(chip); checkPh(); return; }
  }
});
ed.addEventListener('paste', function(e) {
  e.preventDefault();
  var text = (e.clipboardData || window.clipboardData).getData('text/plain');
  if(!text) return;
  var sel = window.getSelection();
  if(!sel || !sel.rangeCount) { ed.appendChild(document.createTextNode(text)); checkPh(); return; }
  var r = sel.getRangeAt(0); r.deleteContents();
  var frag = document.createDocumentFragment();
  parseToNodes(text).forEach(function(n) { frag.appendChild(n); });
  r.insertNode(frag); r.collapse(false); sel.removeAllRanges(); sel.addRange(r);
  checkPh();
});

// Cursor Ejector from non-editable chips
document.addEventListener('selectionchange', function() {
  var sel = window.getSelection();
  if(!sel || !sel.rangeCount || !sel.isCollapsed) return;
  var range = sel.getRangeAt(0); var node = range.startContainer;
  var el = (node.nodeType === 3) ? node.parentElement : node;
  if(el && el.classList && el.classList.contains('token-chip')) {
    var nr = document.createRange(); nr.setStartAfter(el); nr.collapse(true);
    sel.removeAllRanges(); sel.addRange(nr);
  }
});

// ── Main UI API ───────────────────────────────────────────────────
function init(data) {
  document.getElementById('title').textContent = data.title;
  document.getElementById('p-name').value = data.name;
  document.getElementById('p-mode').value = data.mode;
  
  var promptVal = data.prompt;
  ed.innerHTML = '';
  parseToNodes(promptVal).forEach(function(n) { ed.appendChild(n); });
  checkPh();
  
  setTimeout(function() { document.getElementById('p-name').focus(); }, 100);
}

function doCancel(){
  window.webkit.messageHandlers.prompt_bridge.postMessage({action: 'cancel'});
}

function doSave(){
  const name = document.getElementById('p-name').value.trim();
  const mode = document.getElementById('p-mode').value;
  const prompt = serializeEditor(ed).trim();
  
  if(!name || !prompt) return alert("Le nom et le prompt sont requis.");
  
  window.webkit.messageHandlers.prompt_bridge.postMessage({
      action: 'save', name: name, batch: (mode === 'batch'), prompt: prompt
  });
}

document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') doCancel();
});
</script>
</body>
</html>
]=]

function M.open(existing, on_save)
    if _webview then 
        pcall(function() _webview:delete() end)
        _webview = nil 
    end

    local default_name   = existing and existing.label  or ""
    local default_batch  = (existing == nil) or (existing.batch ~= false)
    
    -- Utilisation du nouveau prompt simplifié par défaut
    local default_prompt = existing and existing.raw_prompt or "Voici un texte, continue-le : {context}"

    _usercontent = hs.webview.usercontent.new("prompt_bridge")
    _usercontent:setCallback(function(msg)
        local body = msg.body
        if type(body) == "table" then
            if body.action == "cancel" then
                if _webview then _webview:delete(); _webview = nil end
            elseif body.action == "save" then
                local id = existing and existing.id or ("custom_"..tostring(os.time()).."_"..tostring(math.random(1000,9999)))
                on_save({
                    id         = id,
                    label      = body.name,
                    description= "Profil personnalisé",
                    batch      = body.batch,
                    raw_prompt = body.prompt,
                })
                if _webview then _webview:delete(); _webview = nil end
            end
        end
    end)

    local screen = hs.screen.mainScreen():frame()
    local W, H = 550, 480
    local x = screen.x + (screen.w - W) / 2
    local y = screen.y + (screen.h - H) / 2

    _webview = hs.webview.new({x=x, y=y, w=W, h=H}, { developerExtrasEnabled = false }, _usercontent)
    _webview:windowStyle({"titled", "closable", "utility"})
    _webview:windowTitle(existing and "Modifier le profil" or "Nouveau profil")
    _webview:level(hs.drawing.windowLevels.normal)
    _webview:allowTextEntry(true)

    _webview:navigationCallback(function(action)
        if action == "didFinishNavigation" then
            local js_data = hs.json.encode({
                title  = existing and "Modifier le profil" or "Nouveau profil",
                name   = default_name,
                mode   = default_batch and "batch" or "parallel",
                prompt = default_prompt
            })
            _webview:evaluateJavaScript("init(" .. js_data .. ")")
        end
    end)

    _webview:html(HTML)
    _webview:show()
    
    hs.focus()
    hs.timer.doAfter(0.1, function()
        if _webview then
            local win = _webview:hswindow()
            if win then win:focus() end
        end
    end)
end

return M
