--- tests/unit/metrics/engine/storage/test_reader_invalid_history_dates.lua

--- A malformed persisted n-gram date must not escape the paced dashboard read.
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
 local case = assert(os.getenv('ERGOPTI_INVALID_DATE_CASE'))
 local family, kind = case:match('^(%a+)_(%a+)$')
 local first = kind == 'max' and '9999-12-31' or '2026-02-30'
 local second = kind == 'lower' and '2026-03-02' or (kind == 'upper' and '2026-02-01' or first)
 if family == 'manifest' then
  assert(db:exec("INSERT INTO agg_app_day(device_id,date,app,chars) VALUES ('d','" .. first .. "','Editor',1),('d','" .. second .. "','Other',2);") == sqlite.OK)
 else
  assert(db:exec("INSERT INTO ngram_chars(device_id,date,app,token,c) VALUES ('d','" .. first .. "','Editor','bad',1),('d','" .. second .. "','Editor','other',1);") == sqlite.OK)
 end
 assert(db:close() == sqlite.OK)
 local helpers = require('tests.helpers'); local logger = helpers.make_logger_stub(); local errors = {}
 logger.error = function(_, message, ...) errors[#errors+1] = string.format(message, ...) end
 package.loaded['core.logger.engine.logger'] = logger
 local reader = helpers.load_with_stubs('metrics.engine.reader.sqlite_reader', { sqlite3 = sqlite })
 local pacer = { pause = function() end }
 local ok, result, complete
 if family == 'manifest' then ok, result, complete = pcall(reader.read_manifest, path, nil, nil, pacer)
 else ok, result, complete = pcall(reader.read_ngrams, path, nil, nil, nil, pacer) end
 local value = kind == 'max' and ok and (family == 'manifest' and result['9999-12-31'].Editor.chars or result.c.bad.c) or nil
 print(json.encode({kind = 'done', ok = ok, complete = complete, errors = #errors, closed = closed, value = value }))
end
if arg and arg[0] and arg[0]:match('test_reader_invalid_history_dates%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('invalid historical dates', function()
 for _, case in ipairs({ 'ngram_lower', 'ngram_upper', 'ngram_single', 'ngram_max', 'manifest_lower', 'manifest_upper', 'manifest_single', 'manifest_max' }) do
 helpers.it('handles ' .. case .. ' bounds and closes the SQLite connection', function()
  local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'tools/diagnostics/hs274_persistence_test.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ['ERGOPTI_PHYSICAL_SOURCE_ROOT']=str(root)
os.environ['ERGOPTI_INVALID_DATE_CASE']=sys.argv[4]
with tempfile.TemporaryDirectory(prefix='ergopti-invalid-date-') as tmp:
 result=bridge.run_fixture(sys.argv[2],tmp,Path(sys.argv[3]).resolve())
 if sys.argv[4].endswith('_max'):
  assert result['ok'] is True and result['complete'] is True and result['errors']==0 and result['closed']==2 and result['value']==1,result
 else:
  assert result['ok'] is True and result['complete'] is False and result['errors']>0 and result['closed']==2,result
print('PASS: malformed ngram dates are incomplete')
]]
  local lua = os.getenv('LUA') or arg[-1]
  local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' ' .. quote(case) .. ' 2>&1'
  local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
  helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: malformed ngram dates are incomplete\n')
 end)
 end
end)
