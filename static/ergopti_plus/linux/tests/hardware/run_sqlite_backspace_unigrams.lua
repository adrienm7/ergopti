--- tests/hardware/run_sqlite_backspace_unigrams.lua

--- ==============================================================================
--- MODULE: Native Backspace Unigram Retention
--- DESCRIPTION:
--- Exercises real SQLite through public software collector events. Correction
--- markers retain canonical source counts without claiming physical input.
--- ==============================================================================

require('compat.utf8').install()
local uv=require('luv'); local Clock=require('infra.monotonic'); local J=require('json')
local profile=assert(uv.fs_mkdtemp('/tmp/ergopti-backspace-native-XXXXXX'))
for _,name in ipairs({'CONFIG','DATA','CACHE','STATE'}) do local dir=profile..'/'..name:lower(); assert(uv.fs_mkdir(dir,448)); assert(uv.os_setenv('XDG_'..name..'_HOME',dir)) end
assert(uv.fs_mkdir(profile..'/config/ergopti',448))
local cf=assert(io.open(profile..'/config/ergopti/config.toml','wb')); assert(cf:write('[metrics]\nenabled = true\n')); assert(cf:close())
local K=require('modules.keylogger.keylogger'); local W=require('modules.keylogger.sqlite_writer'); local R=require('modules.keylogger.sqlite_reader'); local db=profile..'/metrics.sqlite'
K.init({sqlite_path=db,log_dir=profile..'/logs'}); assert(K.is_enabled() and W.is_available())
local day=os.date('%Y-%m-%d'); local at=math.floor(Clock.now_ms()); K.on_keydown('x',at,'manual')
uv.sleep(40); local bs_at=math.floor(Clock.now_ms()); K.on_keydown('[BS]',bs_at,'manual'); local manual_delay=bs_at-at
K.record_hotstring('hotstring','zz','xy',math.floor(Clock.now_ms()),'static',2,false)
K.record_synthetic_output('llm','ab','llm',math.floor(Clock.now_ms()),1,1)
K.record_synthetic_output('literal','[BS]','other',math.floor(Clock.now_ms()),0,0)
local checks,failures=0,0
local function check(n,fn) checks=checks+1; local ok,e=xpcall(fn,debug.traceback); print((ok and 'PASS ' or 'FAIL ')..n..(ok and '' or ': '..e)); if not ok then failures=failures+1 end end
local function row(sql) local r=W.query_rows(sql); assert(type(r)=='table' and #r==1,'native SQL nonempty subject floor'); print('SQL '..r[1]); return r[1] end
local function bs_fields(payload)
 for app,expected in pairs({manual={1,0,0,0},hotstring={2,2,0,0},llm={1,0,1,0}}) do
  local b=assert(payload.today[app]).c['[BS]']; assert(b,'missing canonical BS unigram for '..app)
  assert(b.c==expected[1] and b.hs==expected[2] and b.llm==expected[3] and b.o==expected[4] and b.e==0,'BS count/source tuple changed for '..app)
 end
end
local function literal_fields(payload)
 local c=assert(payload.today.literal).c
 for _,ch in ipairs({'[','B','S',']'}) do assert(c[ch].c==1 and c[ch].o==1 and c[ch].hs==0 and c[ch].llm==0) end
 assert(c['[BS]']==nil,'literal text must stay four codepoints')
end
local before=K.get_range_payload(day,day,nil)
check('genuine clock and ordinary pending manual character positive floor',function() assert(Clock.has_hires() and manual_delay>=40 and manual_delay<1000 and before.today.manual.c.x.c==1) end)
check('pending manual backspace remains canonical count1',function() local b=assert(before.today.manual.c['[BS]']); assert(b.c==1 and b.hs==0 and b.llm==0 and b.o==0) end)
check('pending hotstring deletion count2 retains its synthetic source',function() local b=assert(before.today.hotstring.c['[BS]']); assert(b.c==2 and b.hs==2 and b.llm==0) end)
check('pending completion deletion count1 retains LLM source',function() local b=assert(before.today.llm.c['[BS]']); assert(b.c==1 and b.llm==1 and b.hs==0) end)
check('literal BS spelling is four separate software codepoints before flush',function() literal_fields(before) end)
check('public dashboard prefetch preserves markers without flushing raw output',function() bs_fields(K.get_dashboard_payload()._prefetch_data); assert(row('SELECT COUNT(*) FROM events_typing;')=='0') end)
K.flush(); assert(os.date('%Y-%m-%d')==day)
check('independent raw correction markers retain manual HS and LLM metadata',function()
 assert(row("SELECT COUNT(*),SUM(COALESCE(json_extract(e.value,'$[2].st'),'none')='none'),SUM(json_extract(e.value,'$[2].st')='hotstring'),SUM(json_extract(e.value,'$[2].st')='llm') FROM events_typing,json_each(events_json) e WHERE json_extract(e.value,'$[0]')='[BS]';")=='4|1|2|1')
end)
check('native stored BS unigram counts and sources survive accepted flush',function()
 assert(row("SELECT COALESCE(SUM(c),0),COALESCE(SUM(td),0),COALESCE(SUM(e),0),COALESCE(SUM(json_extract(esrc_json,'$.hotstring')),0),COALESCE(SUM(json_extract(esrc_json,'$.llm')),0) FROM ngram_chars WHERE token='[BS]';")=='4|'..manual_delay..'|0|2|1')
end)
local after=K.get_range_payload(day,day,nil)
check('postflush public range retains all accepted BS count and source tuples',function() bs_fields(after); assert(after.today.manual.c['[BS]'].t==manual_delay) end)
check('postflush dashboard retains BS without doubling pending contributions',function() bs_fields(K.get_dashboard_payload()._prefetch_data) end)
check('public Reader filtered manual BS carries genuine native delay',function() local p=R.read_ngrams(db,day,day,{'manual'}); local b=assert(p.c['[BS]']); assert(b.c==1 and b.t==manual_delay and b.e==0 and b.hs==0 and b.llm==0 and b.o==0); assert(p.c.x.c==1) end)
check('ordinary character and synthetic scalar counters remain unchanged',function()
 assert(row('SELECT SUM(chars),SUM(hs_chars),SUM(llm_chars),SUM(hs_input_chars),SUM(llm_input_chars) FROM agg_app_day;')=='1|2|2|2|1')
 local m,c=R.read_manifest(db); assert(c and m[day].manual.bs_total==1 and m[day].hotstring.bs_total==0 and m[day].llm.bs_total==0)
end)
check('literal software spelling stays four codepoints after flush and raw recording',function()
 literal_fields(after); assert(row("SELECT COUNT(*) FROM events_typing,json_each(events_json) e WHERE app='literal' AND json_extract(e.value,'$[0]') IN ('[','B','S',']');")=='4')
end)
check('second empty flush is idempotent for stored markers and raw event groups',function()
 K.flush(); assert(row("SELECT COALESCE(SUM(c),0) FROM ngram_chars WHERE token='[BS]';")=='4'); assert(row('SELECT COUNT(*),SUM(json_array_length(events_json)) FROM events_typing;')=='4|13')
end)
assert(W.exec_sql("VACUUM INTO '"..profile.."/readonly.sqlite';"))
local f=assert(io.open(profile..'/observation.json','wb')); assert(f:write(J.encode({day=day,manual_delay=manual_delay,before=before,after=after}))); assert(f:close())
W.close_db(); assert(checks==14,'mandatory14 native subjects'); print('PROFILE '..profile); print('RUNTIME '.._VERSION..'; '..tostring(jit and jit.version or 'stock')..'; luv '..uv.version_string()..'; Clock '..Clock.backend()); print(string.format('Native canonical backspace unigram retention: %d checks, %d failures',checks,failures)); os.exit(failures==0 and 0 or 1)
