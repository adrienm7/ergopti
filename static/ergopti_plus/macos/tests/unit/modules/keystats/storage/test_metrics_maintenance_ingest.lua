--- tests/unit/modules/keystats/storage/test_metrics_maintenance_ingest.lua

--- The dashboard's Export and Purge complete only through the ingest: a Purge
--- once its tombstone committed and purged the rows before it, never before,
--- and an Export once the ingest settled and a VACUUM INTO copy exists. Runs the real log_manager ingest against a
--- real SQLite through the Python bridge.
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
 for _, name in ipairs({ 'schema.sql', 'media_schema.sql', 'purge_schema.sql' }) do
  local f = assert(io.open(shared .. '/data/db/' .. name, 'rb')); local schema = assert(f:read('*a')); assert(f:close())
  assert(db:exec(schema) == sqlite.OK)
 end
 local helpers = require('tests.helpers'); local logger = helpers.make_logger_stub()
 package.loaded['infra.logger'] = logger
 package.loaded['modules.keystats.text_cipher'] = { encrypt = function(_, _, value) return value end }
 local writer = helpers.load_with_stubs('modules.keystats.sqlite_writer', { sqlite3 = sqlite, json = json })
 writer.init({ paths = { sqlite_path = path }, device_obj = { device_id = 'device' }, device_id = 'device' })
 for i = 1, math.huge do local name = debug.getupvalue(writer.get_db, i); assert(name)
  if name == '_db' then debug.setupvalue(writer.get_db, i, db); break end end
 package.loaded['modules.keystats.sqlite_writer'] = writer
 package.loaded['modules.keystats.export'] = { get_native_app_category = function() return nil end,
  sync_foreign_data_sql = function() return {} end }
 local aggregator = helpers.load_with_stubs('modules.keystats.aggregator', { sqlite3 = sqlite, json = json })
 aggregator.init({ device_id = 'device' }); package.loaded['modules.keystats.aggregator'] = aggregator
 local typing = { type = 'typing', timestamp = '2026-11-06 09:00:00.000', app = 'Editor', text = 'a', events = { { 'a', 100, {} } } }
 -- The tombstone's UTC instant is its local time's, as metrics_maintenance renders it (KMD-1).
 local tombstone = { type = 'system_event', action = 'metrics_purge', timestamp = '2026-11-06 10:00:00.000',
  utc = (require('keystats.local_time').from_local('2026-11-06 10:00:00.000')) }
 local batches, offset = { { { entry = typing } }, { { entry = tombstone } } }, 0
 package.loaded['modules.keystats.rotation'] = { get_date = function() return '2026-11-06' end,
  get_offset = function() return offset end, set_offset = function(n) offset = n end,
  read_new_entries = function()
   local batch = table.remove(batches, 1)
   if batch then return batch, offset + 100, 'eof' end
   return {}, offset, 'eof'
  end }
 local manager = helpers.load_with_stubs('modules.keystats.log_manager', { sqlite3 = sqlite, json = json })
 local advance
 for i = 1, math.huge do local name, value = debug.getupvalue(manager.ingest_once, i)
  if name == nil then break end
  if name == '_flush_local_data_sql_outbox' then debug.setupvalue(manager.ingest_once, i, function() return true end) end
  if name == '_advance_maintenance' then advance = value end
 end
 assert(type(advance) == 'function', 'the ingest must settle the dashboard request')
 local function own(request)
  for i = 1, math.huge do local name = debug.getupvalue(advance, i); assert(name)
   if name == '_maintenance_request' then debug.setupvalue(advance, i, request); return end end
 end
 local replies = {}
 local function count(sql) local n; for row in db:nrows(sql) do n = row.n end; return n end
 own({ kind = 'purge', tombstone = { ts = tombstone.timestamp }, complete = function(ok, p) replies[#replies + 1] = { ok, p } end })
 manager.ingest_once()
 local typing_before = count('SELECT COUNT(*) AS n FROM events_typing')
 local replies_after_typing = #replies
 manager.ingest_once()
 local replies_after_tombstone = #replies
 manager.ingest_once()
 local purge_reply = replies[1]
 local typing_after = count('SELECT COUNT(*) AS n FROM events_typing')
 local derived_after = count("SELECT COUNT(*) AS n FROM agg_app_day WHERE date <= '2026-11-06'")
 own({ kind = 'export', complete = function(ok, p) replies[#replies + 1] = { ok, p } end })
 manager.ingest_once()
 local export_reply = replies[2]
 local copied = export_reply and export_reply[2] and io.open(export_reply[2], 'rb')
 if copied then copied:close() end
 assert(writer.close_db())
 print(json.encode({ kind = 'done', typing_before = typing_before, replies_after_typing = replies_after_typing,
  replies_after_tombstone = replies_after_tombstone, purge_ok = purge_reply and purge_reply[1],
  typing_after = typing_after, derived_after = derived_after, export_ok = export_reply and export_reply[1],
  export_path = export_reply and export_reply[2], copied = copied ~= nil }))
end
if arg and arg[0] and arg[0]:match('test_metrics_maintenance_ingest%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('text_utils').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('dashboard export and purge through the macOS ingest', function()
 helpers.it('metrics-maintenance-ingest: purge answers once its tombstone commits, export once the copy exists', function()
  local script = [=[
import importlib.util,os,sys,tempfile,re
from pathlib import Path
root=Path(sys.argv[1]).resolve()
path=root/'static/ergopti_plus/macos/tests/support/keystats/rebuild_sqlite_bridge.py'
spec=importlib.util.spec_from_file_location('rebuild_bridge',path)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
with tempfile.TemporaryDirectory(prefix='ergopti-maintenance-') as tmp:
 downloads=Path(tmp)/'Downloads';downloads.mkdir()
 os.environ['XDG_DOWNLOAD_DIR']=str(downloads)
 result=bridge.run_fixture(sys.argv[2],Path(sys.argv[3]).resolve(),root,tmp)
 assert result['typing_before']==1 and result['replies_after_typing']==0,result
 assert result['replies_after_tombstone']==1,('a purge answers once its tombstone committed',result)
 assert result['purge_ok'] is True and result['typing_after']==0 and result['derived_after']==0,result
 assert result['export_ok'] is True and result['copied'] is True,result
 assert re.search(r'/ergopti-metrics-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.sqlite$',result['export_path']),result
print('PASS: maintenance settles through the ingest')
]=]
  local lua = os.getenv('LUA') or arg[-1]
  local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua)
   .. ' ' .. quote(source) .. ' 2>&1'
  local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
  helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: maintenance settles through the ingest\n')
 end)
end)
