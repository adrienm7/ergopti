--- tests/unit/modules/keystats/storage/test_ingest_llm_predictions_failure.lua

--- LLM prediction arrays must survive encoding failure and a retry.
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
 package.loaded['infra.logger'] = logger
 package.loaded['modules.keystats.text_cipher'] = { encrypt = function(_, _, value) return value end }
 local field = assert(os.getenv('ERGOPTI_LLM_FIELD'))
 local entry = { type='llm_generation', timestamp='2026-10-17 12:00:00', app='Editor' }
 entry[field] = {'prediction one', 'prediction two'}
 local good = { type='typing', timestamp='2026-10-17 11:59:00', app='Editor', text='a', events={ {'a',100,{}} } }
 local fail = true
 local failure = assert(os.getenv('ERGOPTI_RAW_JSON_CASE'))
 local json_stub = { decode = json.decode, encode = function(value)
  if fail and value == entry[field] then
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
 local first_rows;for row in db:nrows('SELECT COUNT(*) AS n FROM events_llm')do first_rows=row.n end
 fail=false;local retry_ok=pcall(manager.ingest_once)
 local stored={};for row in db:nrows('SELECT id,kind,predictions_json,all_predictions_json, predictions_json IS NULL AS predictions_null, all_predictions_json IS NULL AS all_predictions_null FROM events_llm ORDER BY id')do stored[#stored+1]=row end
 local final_offset,final_id=offset,writer.get_next_event_id()
 assert(writer.close_db())
 print(json.encode({kind='done',first_ok=first_ok,first_result=first_result,first_offset=first_offset,first_id=first_id,
  first_rows=first_rows,retry_ok=retry_ok,stored=stored,final_offset=final_offset,final_id=final_id}))
end
if arg and arg[0] and arg[0]:match('test_ingest_llm_predictions_failure%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('LLM predictions encoding failure', function()
 for _,field in ipairs({'predictions','all_predictions'}) do
 for _,case in ipairs({'throw','empty','nil'}) do
 helpers.it('retains '..field..' after encoder '..case, function()
  local script = [=[
import importlib.util,os,sys,tempfile,json
from pathlib import Path
root=Path(sys.argv[1]).resolve()
path=root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py'
spec=importlib.util.spec_from_file_location('rebuild_bridge',path)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
os.environ['ERGOPTI_RAW_JSON_CASE']=sys.argv[4]
os.environ['ERGOPTI_LLM_FIELD']=sys.argv[5]
with tempfile.TemporaryDirectory(prefix='ergopti-raw-json-') as tmp:
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 assert result['first_ok'] is True and result['first_offset']==0 and result['first_id']==1 and result['first_rows']==0,result
 assert result['retry_ok'] is True and result['final_offset']==100 and result['final_id']==3,result
 assert len(result['stored'])==1 and result['stored'][0]['id']==2 and result['stored'][0]['kind']=='generation',result
 row=result['stored'][0]; field=sys.argv[5]+'_json'
 assert json.loads(row[field])==['prediction one','prediction two'],result
 assert row['all_predictions_null' if field=='predictions_json' else 'predictions_null']==1,result
print('PASS: LLM prediction failure retains event')
]=]
  local lua=os.getenv('LUA') or arg[-1]
  local command='python3 -c '..quote(script)..' '..quote(helpers.driver_root()..'../../..')..' '..quote(lua)..' '..quote(source)..' '..quote(case)..' '..quote(field)..' 2>&1'
  local pipe=assert(io.popen(command,'r'));local output=pipe:read('*a');local ok=pipe:close()
  helpers.assert_eq(ok,true,output);helpers.assert_eq(output,'PASS: LLM prediction failure retains event\n')
 end)
 end
 end
end)
