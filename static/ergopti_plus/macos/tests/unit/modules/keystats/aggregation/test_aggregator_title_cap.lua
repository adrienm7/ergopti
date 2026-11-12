--- tests/unit/modules/keystats/aggregation/test_aggregator_title_cap.lua

--- Title cap is enforced after all new window durations are credited.
local function child()
 local root, temporary = assert(arg[3]), assert(arg[2])
 local driver, shared = root .. '/static/ergopti_plus/macos', root .. '/static/ergopti_plus/_shared'
 package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. shared .. '/?.lua;' .. shared .. '/?/init.lua;' .. package.path
 local json = require('core.text.engine.json')
 local function request(message)
  message.kind = 'request'; assert(io.stdout:write(json.encode(message) .. '\n')); assert(io.stdout:flush())
  local result = assert(json.decode_lossless(assert(io.stdin:read('*l')))); assert(result.ok, result.error); return result.value
 end
 local closed = 0
 local sqlite = { OK = 0 }
 function sqlite.open(path)
  local id = request({ op = 'open', path = path }); local db = {}
  function db:exec(sql) return request({ op = 'exec', connection = id, sql = sql }) end
  function db:close() closed = closed + 1; return request({ op = 'close', connection = id }) end
  function db:nrows(sql)
   local rows = request({ op = 'rows', connection = id, sql = sql })
   for _, row in ipairs(rows) do for key, value in pairs(row) do if json.is_null(value) then row[key] = nil end end end
   local i = 0; return function() i = i + 1; return rows[i] end
  end
  return db
 end
 local path = temporary .. '/db.sqlite'; local db = sqlite.open(path)
 for _, name in ipairs({ 'schema.sql', 'media_schema.sql' }) do
  local f = assert(io.open(shared .. '/metrics/data/db/' .. name, 'rb')); local schema = assert(f:read('*a')); assert(f:close()); assert(db:exec(schema) == sqlite.OK)
 end
 local helpers = require('tests.helpers'); local logger = helpers.make_logger_stub()
 package.loaded['infra.logger'] = logger
 package.loaded['modules.keystats.sqlite_writer'] = { get_db = function() return db end }
 package.loaded['modules.keystats.export'] = { get_native_app_category = function() return nil end }
 local aggregator = helpers.load_with_stubs('modules.keystats.aggregator', { sqlite3 = sqlite })
 aggregator.init({ device_id = 'device' }); aggregator.reset_batch()
 assert(db:exec([[WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100)
  INSERT INTO agg_app_day_titles(device_id,date,app,title,c,ms)
  SELECT 'device','2026-10-17','Editor','old-' || x,0,x FROM n;]]) == sqlite.OK)
 local fail = os.getenv('ERGOPTI_TITLE_CASE') == 'rollback'
 if fail then assert(db:exec("CREATE TRIGGER refuse_prune BEFORE DELETE ON agg_app_day_titles BEGIN SELECT RAISE(ABORT,'prune refused'); END;") == sqlite.OK) end
 aggregator.walk_window_switch({ timestamp = '2026-10-17 12:00:00', app = 'Editor', prev_title = 'new-high', duration_ms = 1000 })
 assert(db:exec('BEGIN TRANSACTION') == sqlite.OK)
 local invoked, accepted = pcall(aggregator.flush)
 if fail then
  assert((not invoked or accepted == false) and aggregator.has_pending_batch() == true)
  assert(db:exec('ROLLBACK') == sqlite.OK)
  local before
  for r in db:nrows("SELECT COUNT(*) AS n, SUM(title='new-high') AS high FROM agg_app_day_titles") do before = r end
  assert(before.n == 100 and before.high == 0)
  assert(db:exec('DROP TRIGGER refuse_prune') == sqlite.OK)
  assert(db:exec('BEGIN TRANSACTION') == sqlite.OK)
  assert(aggregator.flush() == true)
 else
  assert(invoked and accepted == true)
 end
 assert(db:exec('COMMIT') == sqlite.OK)
 local row
 for r in db:nrows("SELECT COUNT(*) AS n, SUM(title='new-high') AS high, SUM(title='old-1') AS low FROM agg_app_day_titles") do row = r end
 assert(db:close() == sqlite.OK)
 print(json.encode({ kind = 'done', row = row }))
end
if arg and arg[0] and arg[0]:match('test_aggregator_title_cap%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('title cap after aggregation', function()
 for _, case in ipairs({ 'normal', 'rollback' }) do
 helpers.it('keeps the 100 most used titles after ' .. case, function()
  local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'tools/diagnostics/hs274_persistence_test.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ['ERGOPTI_PHYSICAL_SOURCE_ROOT']=str(root)
os.environ['ERGOPTI_TITLE_CASE']=sys.argv[4]
with tempfile.TemporaryDirectory(prefix='ergopti-title-cap-') as tmp:
 result=bridge.run_fixture(sys.argv[2],tmp,Path(sys.argv[3]).resolve())
 assert result['row']=={'n':100,'high':1,'low':0},result
print('PASS: title cap follows insertion')
]]
  local lua = os.getenv('LUA') or arg[-1]
  local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' ' .. quote(case) .. ' 2>&1'
  local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
  helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: title cap follows insertion\n')
 end)
 end
end)
