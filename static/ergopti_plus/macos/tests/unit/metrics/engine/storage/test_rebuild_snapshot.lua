--- tests/unit/metrics/engine/storage/test_rebuild_snapshot.lua

--- Exercises source witnesses, native-owner cleanup and publication on real SQLite.
local function child()
 local root, temporary = assert(arg[3]), assert(arg[2])
 local driver = root .. '/static/ergopti_plus/macos'
 package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. root .. '/static/ergopti_plus/_shared/?.lua;' .. root .. '/static/ergopti_plus/_shared/?/init.lua;' .. package.path
 local json = require('core.text.engine.json')
 local function request(message)
  message.kind = 'request'; assert(io.stdout:write(json.encode(message) .. '\n')); assert(io.stdout:flush())
  return assert(json.decode(assert(io.stdin:read('*l'))))
 end
 local sqlite = require('tests.support.keystats.rebuild_sqlite_bridge').new(request)
 local Snapshot = require('metrics.engine.reader.rebuild_snapshot')
 local path = temporary .. '/owner.sqlite'; local owner = assert(sqlite.open(path)); local other = assert(sqlite.open(path))
 assert(owner:exec("CREATE TABLE d(device_id TEXT PRIMARY KEY,n INTEGER); INSERT INTO d VALUES('d',9);") == sqlite.OK)
 local case = assert(os.getenv('ERGOPTI_SNAPSHOT_CASE')); local current = owner
 local leases = 0; local lease = { acquire = function(db) if db ~= current or leases ~= 0 then return false end; leases = 1; return true end,
  release = function(db) if db ~= owner or leases ~= 1 then return false end; leases = 0; return true end }
 local clock_calls = 0
 local function clock() clock_calls = clock_calls + 1; return case == 'budget' and clock_calls > 1 and 300000001 or 0 end
 if case == 'quarantinelease' then
  local helpers = require('tests.helpers'); package.loaded['core.logger.engine.logger'] = helpers.make_logger_stub()
  local writer = helpers.load_with_stubs('metrics.engine.journal.sqlite_writer', { sqlite3 = sqlite })
  for i=1,math.huge do local name=debug.getupvalue(writer.get_db,i); assert(name)
   if name == '_db' then debug.setupvalue(writer.get_db,i,owner); break end end
  assert(request({ op='configure', backup_pages=300 }).ok)
  local invoked = false
  local result = Snapshot.open(owner, sqlite, {'d'}, writer.get_db, function()
   invoked = true; assert(writer.quarantine_db(owner) == false and writer.get_db() == nil)
   assert(writer.apply_typing_updates('d', {}) == false)
   local live; for row in owner:nrows("SELECT n FROM d WHERE device_id='d'") do live = row.n end
   assert(live == 9, 'source must remain open until backup finish')
  end, clock, nil, { acquire=writer.acquire_backup_source, release=writer.release_backup_source })
  assert(invoked and result == nil and writer.get_db() == nil)
  local value; for row in other:nrows("SELECT n FROM d WHERE device_id='d'") do value = row.n end
  assert(value == 9 and other:close() == sqlite.OK)
  print(json.encode({kind='done', leaseguard=true})); return
 end
 local function open(pace, register)
  return Snapshot.open(owner, sqlite, { 'd' }, function() return current end, pace or function() end, clock, register, lease)
 end
 if case == 'finish' then assert(request({ op='inject', operation='finish', codes={10} }).ok) end
 if case == 'cancel' then assert(request({ op='configure', backup_pages=300 }).ok) end
 local stage, refused
 refused = false
 if case == 'cancel' then
  local cleanup
  local co = coroutine.create(function() stage = open(function() coroutine.yield() end, function(fn) cleanup = fn end) end)
  assert(coroutine.resume(co) and coroutine.status(co) == 'suspended' and leases == 1)
  assert(type(cleanup) == 'function' and cleanup())
  refused = stage == nil and leases == 0
  stage = assert(open())
 else
  stage = open()
  if case == 'finish' then
   refused = stage == nil and leases == 0
   stage = assert(open())
  end
 end
 assert(stage and stage.db:exec("INSERT INTO temp.d VALUES('d',1);") == sqlite.OK)
 if case == 'targetfinish' then assert(request({ op='inject', operation='finish', codes={10} }).ok) end
 if case == 'budget' then assert(request({ op='configure', backup_pages=300 }).ok) end
 if case == 'same' then assert(owner:exec("INSERT INTO d VALUES('other',2);") == sqlite.OK) end
 if case == 'external' then assert(other:exec("INSERT INTO d VALUES('other',2);") == sqlite.OK) end
 if case == 'switched' then current = other end
 if case == 'commit' then
  local original = owner.exec; local injected = false
  function owner:exec(sql) if sql == 'COMMIT;' and not injected then injected = true; return 5 end; return original(self,sql) end
 end
 local accepted = Snapshot.publish(stage, "'d'")
 local old
 for row in owner:nrows("SELECT n FROM d WHERE device_id='d'") do old = row.n end
 assert(Snapshot.close(stage))
 local retry
 if case == 'targetfinish' or case == 'budget' then
  assert(request({ op='configure', backup_pages=1 }).ok)
  case = 'retry'; clock_calls = 0
  stage = assert(open()); assert(stage.db:exec("INSERT INTO temp.d VALUES('d',1);") == sqlite.OK)
  retry = Snapshot.publish(stage, "'d'"); assert(Snapshot.close(stage))
 end
 assert(other:close() == sqlite.OK); assert(owner:close() == sqlite.OK)
 print(json.encode({kind='done', accepted=accepted, value=old, refused=refused, leases=leases, retry=retry}))
end
if arg and arg[0] and arg[0]:match('test_rebuild_snapshot%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('SQLite rebuild snapshot', function()
 for _, case in ipairs({ 'normal', 'finish', 'cancel', 'same', 'external', 'switched', 'commit', 'targetfinish', 'budget', 'quarantinelease' }) do
  helpers.it('handles ' .. case .. ' without false publication', function()
   local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
path=root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py'
spec=importlib.util.spec_from_file_location('rebuild_bridge',path)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
os.environ['ERGOPTI_SNAPSHOT_CASE']=sys.argv[4]
with tempfile.TemporaryDirectory(prefix='ergopti-staged-snapshot-') as tmp:
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 if sys.argv[4]=='quarantinelease': assert result['leaseguard'] is True,result
 elif sys.argv[4] in ('normal','finish','cancel'):
  assert result['accepted'] is True and result['value']==1 and result['leases']==0,result
  if sys.argv[4]!='normal': assert result['refused'] is True,result
 else:
  assert result['accepted'] is False and result['value']==9 and result['leases']==0,result
  if sys.argv[4] in ('targetfinish','budget'): assert result['retry'] is True,result
print('PASS: snapshot ownership')
]]
   local lua = os.getenv('LUA') or arg[-1]
   local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' ' .. quote(case) .. ' 2>&1'
   local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
   helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: snapshot ownership\n')
  end)
 end
end)
