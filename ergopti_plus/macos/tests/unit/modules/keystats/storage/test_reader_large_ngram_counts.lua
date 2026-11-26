--- tests/unit/modules/keystats/storage/test_reader_large_ngram_counts.lua

--- Large valid device counters must aggregate without SQLite integer overflow.
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
 for _, tbl in ipairs({ 'ngram_shortcuts', 'ngram_shortcut_bigrams', 'ngram_keycodes' }) do
  local column, token = tbl == 'ngram_keycodes' and 'keycode' or 'token', tbl == 'ngram_keycodes' and '42' or "'x'"
  for _, day in ipairs({ '2026-10-17', '2026-10-18' }) do
   assert(db:exec("INSERT INTO " .. tbl .. "(device_id,date,app," .. column .. ",c) VALUES ('d1','" .. day .. "','Editor'," .. token .. ",6000000000000000000),('d2','" .. day .. "','Editor'," .. token .. ",6000000000000000000);") == sqlite.OK)
  end
 end
 assert(db:close() == sqlite.OK)
 local helpers = require('tests.helpers'); local logger = helpers.make_logger_stub(); local errors = {}
 logger.error = function(_, message, ...) errors[#errors+1] = string.format(message, ...) end
 package.loaded['core.logger.engine.logger'] = logger
 local reader = helpers.load_with_stubs('modules.keystats.sqlite_reader', { sqlite3 = sqlite })
 local pacer = { pause = function() end }
 local history, hc = reader.read_ngrams(path, '2026-10-17', '2026-10-17', nil, pacer)
 local today, tc = reader.read_today_split(path, nil, nil, nil, pacer, '2026-10-18')
 local function values(b) return { sc = b.sc.x and b.sc.x.c, sc_bg = b.sc_bg.x and b.sc_bg.x.c, kc = b.kc['42'] and b.kc['42'].c } end
 print(json.encode({kind = 'done', history_complete = hc, today_complete = tc, errors = #errors, closed = closed, history = values(history), today = today.Editor and values(today.Editor) }))
end
if arg and arg[0] and arg[0]:match('test_reader_large_ngram_counts%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('large cross-device ngram counts', function()
 helpers.it('aggregates integer counters beyond SQLite signed range in history and today', function()
  local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'tools/diagnostics/hs274_persistence_test.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ['ERGOPTI_PHYSICAL_SOURCE_ROOT']=str(root)
with tempfile.TemporaryDirectory(prefix='ergopti-large-count-') as tmp:
 result=bridge.run_fixture(sys.argv[2],tmp,Path(sys.argv[3]).resolve())
 assert result['history_complete'] is True and result['today_complete'] is True and result['errors']==0 and result['closed']==3,result
 assert result['history']==result['today']=={'sc':1.2e19,'sc_bg':1.2e19,'kc':1.2e19},result
print('PASS: large ngram totals')
]]
  local lua = os.getenv('LUA') or arg[-1]
  local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' 2>&1'
  local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
  helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: large ngram totals\n')
 end)
end)
