--- tests/unit/modules/keystats/aggregation/test_aggregator_json_failure.lua

--- A failed aggregate JSON encoding must roll back and retain its delta.
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
 local target = { ['5'] = 2 }; local fail = true
 local json_stub = { encode = function(value) if fail and value == target then error('encoder unavailable') end return json.encode(value) end, decode = json.decode }
 local aggregator = helpers.load_with_stubs('modules.keystats.aggregator', { sqlite3 = sqlite, json = json_stub })
 local state = require('modules.keystats.aggregator.state')
 aggregator.init({ device_id = 'device' }); aggregator.reset_batch()
 state.agg_batch.bursts['key'] = { date = '2026-10-17', app = 'Editor', count_total = 2, max_cpm = 10,
  max_chars = 5, length_buckets = target, inter_count = 0, inter_sum = 0, inter_sumsq = 0 }
 assert(db:exec('BEGIN TRANSACTION') == sqlite.OK)
 local ok, accepted = pcall(aggregator.flush)
 local retained = state.agg_batch.bursts.key ~= nil
 assert(db:exec('ROLLBACK') == sqlite.OK)
 local after_failure
 for row in db:nrows('SELECT count(*) AS n FROM agg_app_day_burst') do after_failure = row.n end
 fail = false
 assert(db:exec('BEGIN TRANSACTION') == sqlite.OK)
 local retry_ok, retry_accepted = pcall(aggregator.flush)
 assert(db:exec('COMMIT') == sqlite.OK)
 local stored
 for row in db:nrows('SELECT count_total, length_buckets_json FROM agg_app_day_burst') do stored = row end
 assert(db:close() == sqlite.OK)
 print(json.encode({ kind = 'done', refused = not ok or accepted == false, retained = retained,
  after_failure = after_failure, retry_ok = retry_ok and retry_accepted == true, stored = stored, closed = closed }))
end
if arg and arg[0] and arg[0]:match('test_aggregator_json_failure%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('aggregate JSON serialization failure', function()
 helpers.it('refuses the transaction and retains the histogram for retry', function()
  local script = [[
import importlib.util,os,sys,tempfile,json
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'tools/diagnostics/hs274_persistence_test.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ['ERGOPTI_PHYSICAL_SOURCE_ROOT']=str(root)
with tempfile.TemporaryDirectory(prefix='ergopti-json-failure-') as tmp:
 result=bridge.run_fixture(sys.argv[2],tmp,Path(sys.argv[3]).resolve())
 assert result['refused'] is True and result['retained'] is True and result['after_failure']==0,result
 assert result['retry_ok'] is True and result['stored']['count_total']==2 and json.loads(result['stored']['length_buckets_json'])=={'5':2},result
print('PASS: aggregate JSON failure is retried')
]]
  local lua = os.getenv('LUA') or arg[-1]
  local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' 2>&1'
  local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
  helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: aggregate JSON failure is retried\n')
 end)
end)
