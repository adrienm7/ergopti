--- tests/unit/modules/keystats/storage/test_ingest_system_metadata_failure.lua

--- System events retain the metadata required by live aggregation and replay.
local function child()
 local root, temporary = assert(arg[3]), assert(arg[2])
 local driver, shared = root .. '/static/ergopti_plus/macos', root .. '/static/ergopti_plus/_shared'
 package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. shared .. '/?.lua;' .. shared .. '/?/init.lua;' .. package.path
 local json = require('core.text.engine.json')
 local function request(message)
  message.kind = 'request'
  assert(io.stdout:write(json.encode(message) .. '\n')); assert(io.stdout:flush())
  return assert(json.decode(assert(io.stdin:read('*l'))))
 end
 local sqlite = require('tests.support.keystats.rebuild_sqlite_bridge').new(request)
 local path = temporary .. '/db.sqlite'; local db = sqlite.open(path)
 for _, name in ipairs({ 'schema.sql', 'media_schema.sql' }) do
  local f = assert(io.open(shared .. '/metrics/data/db/' .. name, 'rb')); local schema = assert(f:read('*a')); assert(f:close()); assert(db:exec(schema) == sqlite.OK)
 end
 local helpers = require('tests.helpers'); local logger = helpers.make_logger_stub()
 package.loaded['core.logger.engine.logger'] = logger
 package.loaded['modules.keystats.text_cipher'] = { encrypt = function(_, _, value) return value end }
 local entry = { type='system_event', timestamp='2026-10-17 12:00:00', action='manifest_increment', app='Editor', stat='hs_suggested', amount=3 }
 local good = { type='typing', timestamp='2026-10-17 11:59:00', app='Editor', text='a', events={ {'a',100,{}} } }
 local fail = true
 local failure = assert(os.getenv('ERGOPTI_RAW_JSON_CASE'))
 local json_stub = { decode = json.decode, encode = function(value)
  if fail and type(value)=='table' and value.stat == 'hs_suggested' then
   if failure == 'throw' then error('injected encoding failure') end
   if failure == 'empty' then return '' end
   return nil
  end
  return json.encode(value)
 end }
 local writer = helpers.load_with_stubs('modules.keystats.sqlite_writer', {sqlite3=sqlite,json=json_stub})
 writer.init({ paths={sqlite_path=path}, device_obj={device_id='device'}, device_id='device' })
 for i=1,math.huge do local name=debug.getupvalue(writer.get_db,i); assert(name)
  if name=='_db' then debug.setupvalue(writer.get_db,i,db);break end end
 package.loaded['modules.keystats.sqlite_writer'] = writer
 package.loaded['modules.keystats.export'] = { get_native_app_category=function()return nil end, sync_foreign_data_sql=function()return {} end }
 local aggregator = helpers.load_with_stubs('modules.keystats.aggregator',{sqlite3=sqlite,json=json_stub})
 aggregator.init({device_id='device'}); package.loaded['modules.keystats.aggregator']=aggregator
 local offset=0
 package.loaded['modules.keystats.rotation'] = {get_date=function()return '2026-10-17' end,
  get_offset=function()return offset end,set_offset=function(n)offset=n end,
  read_new_entries=function() if offset==0 then return {{entry=good},{entry=entry}},100,'eof' end;return {},offset,'eof' end}
 local manager=helpers.load_with_stubs('modules.keystats.log_manager',{sqlite3=sqlite,json=json_stub})
 for i=1,math.huge do local name=debug.getupvalue(manager.ingest_once,i);assert(name)
  if name=='_flush_local_data_sql_outbox' then debug.setupvalue(manager.ingest_once,i,function()return true end);break end end
 local first_ok,first_result=pcall(manager.ingest_once)
 local first_offset,first_id=offset,writer.get_next_event_id()
 local first_rows;for row in db:nrows('SELECT COUNT(*) AS n FROM events_system')do first_rows=row.n end
 fail=false;local retry_ok=pcall(manager.ingest_once)
 local stored={};for row in db:nrows('SELECT id,action,metadata_json FROM events_system ORDER BY id')do stored[#stored+1]=row end
 local suggestions;for row in db:nrows("SELECT hs_suggested FROM agg_app_day WHERE app='Editor'")do suggestions=row.hs_suggested end
 local final_offset,final_id=offset,writer.get_next_event_id()
 assert(db:exec('DELETE FROM agg_app_day; BEGIN TRANSACTION;') == sqlite.OK)
 for row in db:nrows('SELECT ts,action,metadata_json FROM events_system') do
  local replay = assert(json.decode(row.metadata_json)); replay.timestamp, replay.action = row.ts, row.action
  aggregator.walk_system_event(replay)
 end
 assert(aggregator.flush() == true and db:exec('COMMIT;') == sqlite.OK)
 local replayed;for row in db:nrows("SELECT hs_suggested FROM agg_app_day WHERE app='Editor'")do replayed=row.hs_suggested end
 assert(writer.close_db())
 print(json.encode({kind='done',first_ok=first_ok,first_result=first_result,first_offset=first_offset,first_id=first_id,
  first_rows=first_rows,retry_ok=retry_ok,stored=stored,suggestions=suggestions,replayed=replayed,final_offset=final_offset,final_id=final_id}))
end
if arg and arg[0] and arg[0]:match('test_ingest_system_metadata_failure%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('system event metadata encoding failure', function()
 for _,case in ipairs({'throw','empty','nil'}) do
 helpers.it('retains replayable system metadata after encoder '..case, function()
  local script = [=[
import importlib.util,os,sys,tempfile,json
from pathlib import Path
root=Path(sys.argv[1]).resolve()
path=root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py'
spec=importlib.util.spec_from_file_location('rebuild_bridge',path)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
os.environ['ERGOPTI_RAW_JSON_CASE']=sys.argv[4]
with tempfile.TemporaryDirectory(prefix='ergopti-raw-json-') as tmp:
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 assert result['first_ok'] is True and result['first_offset']==0 and result['first_id']==1 and result['first_rows']==0,result
 assert result['retry_ok'] is True and result['final_offset']==100 and result['final_id']==3,result
 assert result['stored']==[{'id':2,'action':'manifest_increment','metadata_json':result['stored'][0]['metadata_json']}],result
 assert json.loads(result['stored'][0]['metadata_json'])=={'app':'Editor','stat':'hs_suggested','amount':3} and result['suggestions']==3 and result['replayed']==3,result
print('PASS: system metadata failure retains event')
]=]
  local lua=os.getenv('LUA') or arg[-1]
  local command='python3 -c '..quote(script)..' '..quote(helpers.driver_root()..'../../..')..' '..quote(lua)..' '..quote(source)..' '..quote(case)..' 2>&1'
  local pipe=assert(io.popen(command,'r'));local output=pipe:read('*a');local ok=pipe:close()
  helpers.assert_eq(ok,true,output);helpers.assert_eq(output,'PASS: system metadata failure retains event\n')
 end)
 end
end)
