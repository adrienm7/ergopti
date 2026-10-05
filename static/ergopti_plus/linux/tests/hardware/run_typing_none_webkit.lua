--- tests/hardware/run_typing_none_webkit.lua

--- ==============================================================================
--- MODULE: Typing NONE Selection In Real WebKit And SQLite
--- DESCRIPTION:
--- Opens the production typing page with a genuine keylogger and private SQLite
--- fixture, then applies the real application picker buttons. Explicit NONE
--- must exclude both historical n-grams and Unknown live data. Software output
--- and independent SQL counts provide healthy controls; no physical input is
--- injected. Run from the Linux driver with its normal LUA_PATH under Xvfb
--- and a 180-second outer timeout (the CI session has this same requirement).
---
--- Exit 0 = nine checks pass. 1 = a regression fails. 2 = native prerequisites
--- are unavailable. A private XDG profile keeps existing configuration intact;
--- its retained SQLite database and JSON receipt are printed for diagnosis.
--- ==============================================================================

if os.getenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS") then
	io.stderr:write("ENVIRONMENT: the WebKit sandbox must remain enabled.\n")
	os.exit(2)
end
if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then
	io.stderr:write("ENVIRONMENT: no display server; run under xvfb-run.\n")
	os.exit(2)
end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then
	io.stderr:write("ENVIRONMENT: lgi is not installed.\n")
	os.exit(2)
end
local ok_webkit, WK = pcall(lgi.require, "WebKit2", "4.1")
if not ok_webkit then
	io.stderr:write("ENVIRONMENT: WebKit2GTK 4.1 is unavailable.\n")
	os.exit(2)
end
local Gtk = lgi.require("Gtk", "3.0")
local uv = require("luv")
require("compat.utf8").install()
local profile = assert(uv.fs_mkdtemp("/tmp/ergopti-typing-none-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	local directory = profile .. "/" .. name:lower()
	assert(uv.fs_mkdir(directory, 448))
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", directory))
end
print("OWNED_PROFILE " .. profile)
local J=require('json'); local K=require('modules.keylogger.keylogger'); local W=require('modules.keylogger.sqlite_writer')
local root=assert(os.getenv('XDG_CONFIG_HOME')); assert(uv.fs_mkdir(root..'/ergopti',448))
local config=assert(io.open(root..'/ergopti/config.toml','w')); assert(config:write('[metrics]\nenabled = true\n') and config:close())
K.init({sqlite_path=root..'/metrics.sqlite',log_dir=root..'/logs'}); assert(K.is_enabled() and W.is_available())
K.record_synthetic_output('Editor','zz','llm',1000); K.flush()
assert(W.register_device('owned-webkit','owned-webkit','linux','',''))
assert(W.upsert_app_day('owned-webkit','2000-01-01','Editor',{chars=7,time_ms=700}))
assert(W.upsert_ngrams('owned-webkit','2000-01-01','Editor',{h={c=7,td=700,cd=7}},'ngram_chars'))
assert(W.upsert_app_day('owned-webkit',os.date('%Y-%m-%d'),'Unknown',{chars=3,time_ms=300}))
assert(W.upsert_ngrams('owned-webkit',os.date('%Y-%m-%d'),'Unknown',{u={c=3,td=300,cd=3}},'ngram_chars'))
local Manager=require('ui.webview_manager'); Manager.set_daemon_state({keylogger=K})
local checks,failed=0,0
local function check(name,fn) checks=checks+1; local ok,e=xpcall(fn,debug.traceback); print((ok and 'PASS ' or 'FAIL ')..name..(ok and '' or ': '..e)); if not ok then failed=failed+1 end end
print('ENGINE WebKit '..WK.get_major_version()..'.'..WK.get_minor_version()..'.'..WK.get_micro_version()..'; real SQLite; virtual X11; deadline180s; sandbox enabled')
check('independent SQL historical oracle',function() assert(W.query_rows("SELECT SUM(c),SUM(td) FROM ngram_chars WHERE date='2000-01-01' AND app='Editor';")[1]=='7|700') end)
check('independent SQL flushed software oracle',function() assert(W.query_rows("SELECT SUM(c),SUM(json_extract(esrc_json,'$.llm')) FROM ngram_chars WHERE token='z';")[1]=='2|2') end)
assert(Manager.show('metrics_typing','en')); local view=assert(Manager.webview_for('metrics_typing'))
local function pump() while Gtk.events_pending() do Gtk.main_iteration_do(false) end; uv.run('nowait'); uv.sleep(40) end
local function eval(code)
 local value,done; view:run_javascript(code,nil,function(_,result) local ok,x=pcall(function() return view:run_javascript_finish(result):get_js_value():to_string() end); value=ok and x or nil; done=true end,nil)
 local end_at=uv.hrtime()+10e9; repeat pump() until done or uv.hrtime()>end_at; assert(done and value,'real JS evaluation deadline/error'); return value
end
local function wait(code) local end_at=uv.hrtime()+15e9; repeat local v=eval(code); if v=='true' then return true end; pump() until uv.hrtime()>end_at; return false end
assert(wait("String(document.readyState==='complete' && !!window.metrics_manifest && app_state.available_apps.includes('Editor'))"),'actual ready/native manifest deadline')
print('ACTUAL_SOURCE_GUARD '..eval("typeof matches_typing_app_selection"))
check('actual page and canonical selection buttons loaded',function() assert(eval("String(window.__ergopti_host==='linux' && !!document.querySelector('[onclick=\"deselect_all_apps()\"]') && !!document.querySelector('[onclick=\"select_all_apps()\"]'))")=='true') end)
check('actual Unknown live inclusion in initial unfiltered native prefetch',function() assert(eval("String(app_state.data.c.u?.count===3)")=='true') end)
eval("document.getElementById('date_start').value='1999-12-31'; document.getElementById('date_end').value=get_local_date_string(); document.querySelector('[onclick=\"open_app_modal()\"]').click(); document.querySelector('[onclick=\"select_all_apps()\"]').click(); document.querySelector('[onclick=\"close_app_modal()\"]').click(); 'clicked'")
assert(wait("String(!app_state.loading_data && app_state.data.c.h?.count===7 && app_state.data.c.z?.count===2)"),'actual ALL range bridge deadline')
check('actual known historical and flushed software rendering',function() assert(eval("String(app_state.data.c.h.count===7 && app_state.data.c.z.count===2)")=='true') end)
-- BEGIN rendered-table positive control.
local all_h_row_visible = wait([[
String((() => {
	const body = document.getElementById('metrics_table_body');
	if (!body || app_state.current_tab !== 'c') return false;
	const row = Array.from(body.rows).find(r =>
		r.querySelector('.cell-seq .mono-space')?.textContent.trim() === 'h');
	if (!row || row.cells.length !== 8 || row.cells[1].textContent.trim() !== '7') return false;
	row.scrollIntoView({ block: 'center' });
	const rectangle = row.getBoundingClientRect();
	return row.offsetParent !== null && rectangle.height > 0 &&
		rectangle.bottom > 0 && rectangle.top < window.innerHeight;
})())
]])
print('ALL rendered owned h/count7 visible: '..tostring(all_h_row_visible))
-- END rendered-table positive control.
eval("document.querySelector('[onclick=\"open_app_modal()\"]').click(); document.querySelector('[onclick=\"deselect_all_apps()\"]').click(); document.querySelector('[onclick=\"close_app_modal()\"]').click(); 'clicked'"); assert(wait("String(app_state.app_selection_mode==='none' && !app_state.loading_data)"),'actual NONE range bridge deadline')
check('actual NONE empties historical live and Unknown dictionaries',function() local got=eval("JSON.stringify({mode:app_state.app_selection_mode,n:app_state.selected_apps.size,h:app_state.data.c.h?.count,u:app_state.data.c.u?.count,z:app_state.data.c.z?.count})"); print('NONE actual state '..got); assert(eval("String(Object.values(app_state.data).every(d=>Object.keys(d).length===0))")=='true','NONE must display zero tokens') end)
-- BEGIN rendered-table NONE regression.
check('actual rendered table clears owned rows and retains its no-data placeholder',function()
	assert(all_h_row_visible, 'mandatory ALL owned h/count7 visible-row control')
	local empty_render = wait([[
String((() => {
	const body = document.getElementById('metrics_table_body');
	if (!body || app_state.current_tab !== 'c') return false;
	const dataRows = Array.from(body.rows).filter(r => r.querySelector('.cell-seq'));
	const placeholder = body.querySelector('td[colspan="8"]');
	return dataRows.length === 0 && body.rows.length === 1 && !!placeholder &&
		placeholder.textContent.trim() === _t('ui_typing.no_data');
})())
]])
	print('NONE rendered actual table '..eval("document.getElementById('metrics_table_body').outerHTML"))
	assert(empty_render, 'NONE must clear rendered data rows and retain its translated no-data placeholder')
end)
-- END rendered-table NONE regression.
eval("document.querySelector('[onclick=\"open_app_modal()\"]').click(); document.querySelector('[onclick=\"select_all_apps()\"]').click(); document.querySelector('[onclick=\"close_app_modal()\"]').click(); 'clicked'"); assert(wait("String(app_state.app_selection_mode==='all' && !app_state.loading_data && app_state.data.c.h?.count===7)"),'ALL restore deadline')
check('actual ALL restore preserves literal counts',function() assert(eval("String(app_state.data.c.h.count===7 && app_state.data.c.u===undefined && app_state.data.c.z.count===2)")=='true') end)
check('actual retained query renders healthy counts',function() assert(eval("apply_local_filters(); apply_local_filters(); String(app_state.data.c.h.count===7 && app_state.data.c.u===undefined && typingFilterPerformance.hits>0)")=='true') end)
assert(checks==9,'renderer subject floor9'); W.close_db()
local file=assert(io.open(os.getenv('ERGOPTI_NATIVE_WEBVIEW_RECEIPT') or (profile .. '/receipt.json'),'w')); assert(file:write(J.encode({checks=checks,passed=checks-failed,failed=failed})) and file:close())
print(string.format('Native virtual WebKit: %d checks, %d failures',checks,failed)); os.exit(failed==0 and 0 or 1)
