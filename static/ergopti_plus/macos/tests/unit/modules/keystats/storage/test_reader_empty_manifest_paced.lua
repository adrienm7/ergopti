--- tests/unit/modules/keystats/storage/test_reader_empty_manifest_paced.lua

--- Empty databases must not schedule a calendar range of manifest queries.
local function child()
 local root, temporary = assert(arg[3]), assert(arg[2])
 local driver, shared = root .. '/static/ergopti_plus/macos', root .. '/static/ergopti_plus/_shared'
 package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. shared .. '/?.lua;' .. shared .. '/?/init.lua;' .. package.path
 local json = require('core.text.engine.json')
 local function request(message)
  message.kind = 'request'; assert(io.stdout:write(json.encode(message) .. '\n')); assert(io.stdout:flush())
  local result = assert(json.decode_lossless(assert(io.stdin:read('*l')))); assert(result.ok, result.error); return result.value
 end
 local closed, queries = 0, 0
 local case = assert(os.getenv("ERGOPTI_EMPTY_MANIFEST_CASE"))
 local sqlite = { OK = 0 }
 function sqlite.open(path)
  local id = request({ op = 'open', path = path }); local db = {}
  function db:exec(sql) return request({ op = 'exec', connection = id, sql = sql }) end
  function db:close() closed = closed + 1; return request({ op = 'close', connection = id }) end
  function db:nrows(sql)
   queries = queries + 1
   if case == "failed" and sql:find("MIN%(date%) FROM agg_app_day_burst") then error("injected read failure") end
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
 if case == "populated" then assert(db:exec("INSERT INTO agg_app_day(device_id,date,app,chars) VALUES ('d','2025-03-01','Editor',7)") == sqlite.OK) end
 assert(db:close() == sqlite.OK)
 local helpers = require('tests.helpers'); local logger = helpers.make_logger_stub(); local errors = {}
 logger.error = function(_, message, ...) errors[#errors+1] = string.format(message, ...) end
 package.loaded['infra.logger'] = logger
 local reader = helpers.load_with_stubs('modules.keystats.sqlite_reader', { sqlite3 = sqlite })
 local pacer = { pause = function() end }
 local ok, result, complete = pcall(reader.read_manifest, path, '2025-01-01', '2025-12-31', pacer)
 print(json.encode({kind = 'done', ok = ok, complete = complete, errors = #errors, closed = closed, empty = next(result) == nil, chars = result["2025-03-01"] and result["2025-03-01"].Editor.chars or nil, queries = queries }))
end
if arg and arg[0] and arg[0]:match('test_reader_empty_manifest_paced%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('paced empty manifest', function()
 for _,case in ipairs({ 'empty', 'failed', 'populated' }) do
 helpers.it('handles '..case..' manifest bounds', function()
  local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'tools/diagnostics/hs274_persistence_test.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ['ERGOPTI_PHYSICAL_SOURCE_ROOT']=str(root)
os.environ['ERGOPTI_EMPTY_MANIFEST_CASE']=sys.argv[4]
with tempfile.TemporaryDirectory(prefix='ergopti-empty-manifest-') as tmp:
 result=bridge.run_fixture(sys.argv[2],tmp,Path(sys.argv[3]).resolve())
 assert result['ok'] and result['closed']==2,result
 if sys.argv[4]=='empty':
  assert result['complete'] and result['empty'] and result['errors']==0 and result['queries']<=20,result
 elif sys.argv[4]=='failed':
  assert not result['complete'] and result['empty'] and result['errors']>0 and result['queries']<=20,result
 else:
  assert result['complete'] and result['chars']==7 and result['errors']==0,result
print('PASS: empty manifest is bounded')
]]
  local lua = os.getenv('LUA') or arg[-1]
  local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' ' .. quote(case) .. ' 2>&1'
  local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
  helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: empty manifest is bounded\n')
 end)
 end
end)
