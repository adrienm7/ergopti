--- tests/unit/modules/keystats/storage/test_rebuild_encrypted_typing.lua

--- Recovery decrypts typing JSON and refuses unreadable encrypted rows.
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
 local current = db
 local writer
 if case == 'rollback' or case == 'fencerollback' then
  writer = helpers.load_with_stubs('modules.keystats.sqlite_writer', { sqlite3 = sqlite })
  for i = 1, math.huge do
   local name = debug.getupvalue(writer.get_db, i); assert(name)
   if name == '_db' then debug.setupvalue(writer.get_db, i, db); break end
  end
 else
  writer = { get_db = function() return current end, acquire_backup_source = function(owner) return owner == current end,
   release_backup_source = function() return true end, quarantine_db = function() current = nil; return true end }
 end
 package.loaded['modules.keystats.sqlite_writer'] = writer
 package.loaded['modules.keystats.export'] = { get_native_app_category = function() return nil end }
 local fail_decrypt, bad_json = case == 'unreadable', case == 'badjson'
 local bad_shape = case == 'object' and '{\"foo\":1}' or (case == 'malformedarray' and '[{\"foo\":1}]' or nil)
 local cipher = require('keystats.text_cipher').new({ logger = logger, log = 'test.cipher',
  sha256 = function() return string.rep('a', 64) end, derive_key = function() return string.rep('b', 64) end,
  ready = function() return true end,
  encrypt = function(_, _, text) return (text:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end,
  decrypt = function(_, _, data) if fail_decrypt then return nil end; if bad_json then return 'invalid-json' end; if bad_shape then return bad_shape end; return (data:gsub('..', function(c) return string.char(tonumber(c, 16)) end)) end })
 cipher.set_enabled(true)
 local envelope = assert(cipher.encrypt('device', '1j', '[["x",100,{}]]'))
 cipher.set_enabled(false) -- Old encrypted rows remain readable after disabling encryption.
 package.loaded['modules.keystats.text_cipher'] = cipher
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
 upvalue(rebuild, '_typing_replay_cutoffs', function() return {} end)
 upvalue(rebuild, '_device_id', 'device')
 local fixture = case == 'empty' and '{}' or (case == 'plaintext' and '[["x",100,{}]]' or envelope)
 assert(db:exec("INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES ('device',1,'2026-10-17 12:00:00','2026-10-17','Editor',0,0,0,0,0,'ciphertext','" .. fixture .. "');") == sqlite.OK)
 assert(db:exec("INSERT INTO ngram_chars(device_id,date,app,token,c) VALUES ('device','2026-10-17','Editor','sentinel',9); UPDATE meta SET value='6' WHERE key='aggregate_cache_revision';") == sqlite.OK)
 if case == 'partial' then
  assert(db:exec("INSERT INTO events_typing(device_id,id,ts,date,app,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES ('foreign',1,'2026-10-17 12:00:00','2026-10-17','Editor',0,0,0,0,0,'ciphertext','" .. fixture .. "');") == sqlite.OK)
  local snapshots = upvalue(publish, 'RebuildSnapshot')
  local original, calls = snapshots.publish, 0
  snapshots.publish = function(...)
   calls = calls + 1
   if calls == 2 then return false end
   return original(...)
  end
 end
 local other
 if case == 'concurrent' or case == 'switched' or case == 'same' then
  if case ~= 'same' then other = assert(sqlite.open(path)) end
  assert(request({ op = 'configure', backup_pages = 300 }).ok)
  local injected = false
  upvalue(publish, '_recovery_pace', function()
   if injected then return end
   injected = true
   if case == 'concurrent' then assert(other:exec("UPDATE meta SET value='changed' WHERE key='rev';") == sqlite.OK)
   elseif case == 'same' then assert(db:exec("UPDATE meta SET value='changed' WHERE key='rev';") == sqlite.OK)
   else current = other end
  end)
 end
 if case == 'flush' then
  local original, first = aggregator.flush, true
  aggregator.flush = function(...)
   local accepted = original(...)
   if first then first = false; return false end
   return accepted
  end
 end
 if case == 'rollback' or case == 'fencerollback' then other = assert(sqlite.open(path)) end
 if case == 'commit' or case == 'rollback' or case == 'fencerollback' then
  local original, transactions = db.exec, 0
  function db:exec(sql)
   if sql == 'BEGIN IMMEDIATE;' then transactions = transactions + 1 end
   if case == 'fencerollback' and sql == 'COMMIT;' and transactions == 1 then transactions = transactions + 1; return 5 end
   if case == 'fencerollback' and sql == 'ROLLBACK;' and transactions == 2 then transactions = transactions + 1; return 5 end
   if sql == 'COMMIT;' and transactions == 2 then transactions = transactions + 1; return 5 end
   if case == 'rollback' and sql == 'ROLLBACK;' and transactions == 3 then transactions = transactions + 1; return 5 end
   return original(self, sql)
  end
 end
 local devices = case == 'partial' and { 'foreign', 'device' } or { 'device' }
 local ok = publish(db, devices)
 current = db
 local read_db = (case == 'rollback' or case == 'fencerollback') and other or db
 if case == 'rollback' or case == 'fencerollback' then assert(writer.get_db() == nil and writer.apply_typing_updates('device', {}) == false) end
 local count = 0
 for r in read_db:nrows("SELECT c FROM ngram_chars WHERE device_id='device' AND token='x'") do count = r.c end
 local old = 0
 for r in read_db:nrows("SELECT c FROM ngram_chars WHERE device_id='device' AND token='sentinel'") do old = r.c end
 local revision
 for row in read_db:nrows("SELECT value FROM meta WHERE key='aggregate_cache_revision'") do revision = row.value end
 local foreign_count, source_rev
 for row in read_db:nrows("SELECT c FROM ngram_chars WHERE device_id='foreign' AND token='x'") do foreign_count = row.c end
 for row in read_db:nrows("SELECT value FROM meta WHERE key='rev'") do source_rev = tonumber(row.value) end
 local retry, retry_count, retry_revision
 if case ~= 'encrypted' and case ~= 'plaintext' and case ~= 'empty' and case ~= 'rollback' and case ~= 'fencerollback' then
  fail_decrypt, bad_json, bad_shape = false, false, nil
  retry = publish(db, devices)
  for row in db:nrows("SELECT c FROM ngram_chars WHERE device_id='device' AND token='x'") do retry_count = row.c end
  for row in db:nrows("SELECT value FROM meta WHERE key='aggregate_cache_revision'") do retry_revision = row.value end
 end
 if other then assert(other:close() == sqlite.OK) end
 if case ~= 'rollback' and case ~= 'fencerollback' then assert(db:close() == sqlite.OK) end
 print(json.encode({ kind = 'done', rebuilt = ok, count = count, old = old, revision = revision,
  retry = retry, retry_count = retry_count, retry_revision = retry_revision, foreign_count = foreign_count, source_rev = source_rev }))
end
if arg and arg[0] and arg[0]:match('test_rebuild_encrypted_typing%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('text_utils').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('atomic encrypted typing rebuild', function()
 for _, case in ipairs({ 'encrypted', 'plaintext', 'empty', 'unreadable', 'badjson', 'object', 'malformedarray', 'concurrent', 'same', 'switched', 'flush', 'commit', 'rollback', 'fencerollback', 'partial' }) do
  helpers.it('preserves source data during ' .. case, function()
   local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
path=root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py'
spec=importlib.util.spec_from_file_location('rebuild_bridge',path)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
os.environ['ERGOPTI_REBUILD_CASE']=sys.argv[4]
with tempfile.TemporaryDirectory(prefix='ergopti-staged-rebuild-') as tmp:
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 if sys.argv[4]=='empty': assert result['rebuilt'] is True and result['count']==0 and result['old']==0 and result['revision']=='6',result
 elif sys.argv[4] in ('encrypted','plaintext'): assert result['rebuilt'] is True and result['count']==1 and result['old']==0 and result['revision']=='6',result
 else:
  assert result['rebuilt'] is False and result['count']==0 and result['old']==9 and result['revision']==('6' if sys.argv[4]=='fencerollback' else '0'),result
  if sys.argv[4] == 'partial': assert result['foreign_count']==1 and result['source_rev']>=1,result
  if sys.argv[4] not in ('rollback','fencerollback'): assert result['retry'] is True and result['retry_count']==1,result
print('PASS: staged typing rebuild')
]]
   local lua = os.getenv('LUA') or arg[-1]
   local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' ' .. quote(case) .. ' 2>&1'
   local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
   helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: staged typing rebuild\n')
  end)
 end
end)
