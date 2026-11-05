--- tests/unit/modules/keystats/storage/test_rebuild_day_settlement.lua

--- Verifies day-boundary settlement in a staged real SQLite rebuild.
local function child()
 local root, temporary = assert(arg[3]), assert(arg[2])
 local driver, shared = root .. '/static/ergopti_plus/macos', root .. '/static/ergopti_plus/_shared'
 package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. shared .. '/lua/?.lua;' .. shared .. '/lua/?/init.lua;' .. package.path
 local json = require('json')
 local function request(message)
  message.kind = 'request'
  assert(io.stdout:write(json.encode(message) .. '\n')); assert(io.stdout:flush())
  return assert(json.decode(assert(io.stdin:read('*l'))))
 end
 local sqlite = require('tests.support.keystats.rebuild_sqlite_bridge').new(request)
 local path = temporary .. '/db.sqlite'; local db = sqlite.open(path)
 for _, name in ipairs({ 'schema.sql', 'media_schema.sql' }) do
  local f = assert(io.open(shared .. '/data/db/' .. name, 'rb')); local schema = assert(f:read('*a')); assert(f:close()); assert(db:exec(schema) == sqlite.OK)
 end
 local helpers = require('tests.helpers'); local logger = helpers.make_logger_stub()
 package.loaded['infra.logger'] = logger
 local case = assert(os.getenv('ERGOPTI_REBUILD_CASE'))
 local writer = { get_db = function() return db end, acquire_backup_source = function(owner) return owner == db end,
  release_backup_source = function() return true end, quarantine_db = function() return true end }
 package.loaded['modules.keystats.sqlite_writer'] = writer
 package.loaded['modules.keystats.export'] = { get_native_app_category = function() return nil end }
 package.loaded['modules.keystats.text_cipher'] = { decrypt = function(value) return value end }
 local aggregator = helpers.load_with_stubs('modules.keystats.aggregator', { sqlite3 = sqlite })
 aggregator.init({ device_id = 'device' })
 package.loaded['modules.keystats.aggregator'] = aggregator
 local manager = helpers.load_with_stubs('modules.keystats.log_manager', { sqlite3 = sqlite })
 local function upvalue(fn, name, replacement)
  for i = 1, math.huge do
   local found, value = debug.getupvalue(fn, i); assert(found, 'missing ' .. name)
   if found == name then if replacement ~= nil then debug.setupvalue(fn, i, replacement) end; return value end
  end
 end
 local publish = upvalue(manager.ingest_once, '_publish_rebuilt_partitions')
 local rebuild = upvalue(publish, '_rebuild_aggregates_from_raw')
 upvalue(rebuild, '_typing_replay_cutoffs', function() return { case == 'boundary_500' and 500 or 1 } end)
 upvalue(rebuild, '_device_id', 'device')
 local events = '[["h",100,{}],["i",100,{}]]'
 if case == 'boundary_500' then
  for id = 1, 499 do
   assert(db:exec("INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES ('device'," .. id .. ",'2026-10-17 23:59:58','2026-10-17','Editor',0,0,0,0,0,'','[]');") == sqlite.OK)
  end
 end
 local final_id = case == 'boundary_500' and 500 or 1
 assert(db:exec("INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES ('device'," .. final_id .. ",'2026-10-17 23:59:59','2026-10-17','Editor',0,0,0,0,0,'hi','" .. events .. "');") == sqlite.OK)
 local settlement_entered = false
 local native_settle = aggregator.settle_contexts
 if native_settle then
  aggregator.settle_contexts = function(...)
   local result = table.pack(native_settle(...))
   settlement_entered = true
   return table.unpack(result, 1, result.n)
  end
 end
 local snapshot_port = upvalue(publish, 'RebuildSnapshot')
 local native_open, fail_commit = snapshot_port.open, case == 'retry'
 snapshot_port.open = function(...)
  local snapshot, detail, poisoned = native_open(...)
  if snapshot then
   local native_exec = snapshot.db.exec
   snapshot.db.exec = function(self, sql)
    if fail_commit and settlement_entered and sql == 'COMMIT;' then fail_commit = false; return sqlite.BUSY end
    return native_exec(self, sql)
   end
  end
  return snapshot, detail, poisoned
 end
 local first = publish(db, { 'device' })
 local function rows()
  local result = {}
  for row in db:nrows("SELECT date,app,token,c FROM ngram_words WHERE device_id='device' ORDER BY date,app,token") do result[#result+1] = row end
  return result
 end
 local before = rows()
 local second = case == 'retry' and publish(db, { 'device' }) or nil
 local final = rows()
 assert(db:close() == sqlite.OK)
 print(json.encode({ kind = 'done', first = first, second = second, before = before, final = final }))
end
if arg and arg[0] and arg[0]:match('test_rebuild_day_settlement%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('text_utils').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('durable day settlement during real SQLite rebuild', function()
 for _, case in ipairs({ 'boundary', 'boundary_500', 'retry' }) do
  helpers.it('credits the previous day exactly once with ' .. case, function()
   local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
path=root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py'
spec=importlib.util.spec_from_file_location('rebuild_bridge',path)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
os.environ['ERGOPTI_REBUILD_CASE']=sys.argv[4]
with tempfile.TemporaryDirectory(prefix='ergopti-day-settle-') as tmp:
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 if sys.argv[4]=='retry':
  assert result['first'] is False and not result['before'] and result['second'] is True,result
 else: assert result['first'] is True,result
 assert len(result['final'])==1,result
 row=result['final'][0]
 assert row['date']=='2026-10-17' and row['app']=='Editor' and row['c']==1,result
print('PASS: replay settled one prior-day word')
]]
   local lua = os.getenv('LUA') or arg[-1]
   local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' ' .. quote(case) .. ' 2>&1'
   local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
   helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: replay settled one prior-day word\n')
  end)
 end
end)
