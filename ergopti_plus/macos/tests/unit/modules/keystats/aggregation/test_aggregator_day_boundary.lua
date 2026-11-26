--- tests/unit/modules/keystats/aggregation/test_aggregator_day_boundary.lua

--- A clock date change alone must not fabricate a durable rollover.
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
	package.loaded['core.logger.engine.logger'] = logger
	package.loaded['modules.keystats.sqlite_writer'] = { get_db = function() return db end }
	package.loaded['modules.keystats.export'] = { get_native_app_category = function() return nil end }
	local aggregator = helpers.load_with_stubs('modules.keystats.aggregator', { sqlite3 = sqlite })
	aggregator.init({ device_id = 'device' }); aggregator.reset_batch()
	aggregator.walk_typing({ app = 'App', timestamp = '2026-10-17 23:59:59.000', events = { {'a', 100, {}}, {'b', 100, {}}, {'c', 100, {}} } })
	aggregator.walk_typing({ app = 'App', timestamp = '2026-10-18 00:00:01.000', events = { {'d', 100, {}} } })
	assert(db:exec('BEGIN TRANSACTION') == sqlite.OK)
	assert(aggregator.flush() == true)
	assert(db:exec('COMMIT') == sqlite.OK)
	local words, bigrams, sessions = {}, {}, {}
	for row in db:nrows('SELECT date, token, c FROM ngram_words ORDER BY date, token') do words[#words+1] = row end
	for row in db:nrows('SELECT date, token, c FROM ngram_bigrams ORDER BY date, token') do bigrams[#bigrams+1] = row end
	for row in db:nrows('SELECT date, count_total FROM agg_app_day_session ORDER BY date') do sessions[#sessions+1] = row end
	assert(db:close() == sqlite.OK)
	print(json.encode({ kind = 'done', words = words, bigrams = bigrams, sessions = sessions }))
end
if arg and arg[0] and arg[0]:match('test_aggregator_day_boundary%.lua$') then child(); return end
local helpers = require('tests.helpers')
local quote = require('core.text.engine.utils_core').shell_quote
local source = assert(debug.getinfo(1, 'S').source):gsub('^@', '')
helpers.describe('n-gram day transition', function()
	helpers.it('preserves continuity when timestamps cross a day without a rollover marker', function()
		local script = [[
import importlib.util,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('bridge',root/'tools/diagnostics/hs274_persistence_test.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ['ERGOPTI_PHYSICAL_SOURCE_ROOT']=str(root)
with tempfile.TemporaryDirectory(prefix='ergopti-ngram-identity-') as tmp:
 result=bridge.run_fixture(sys.argv[2],tmp,Path(sys.argv[3]).resolve())
 assert not result['words'],result
 assert result['bigrams']==[{'date':'2026-10-17','token':'ab','c':1},{'date':'2026-10-17','token':'bc','c':1},{'date':'2026-10-18','token':'cd','c':1}],result
 assert not result['sessions'],result
print('PASS: markerless continuity preserved')
]]
		local lua = os.getenv('LUA') or arg[-1]
		local command = 'python3 -c ' .. quote(script) .. ' ' .. quote(helpers.driver_root() .. '../../..') .. ' ' .. quote(lua) .. ' ' .. quote(source) .. ' 2>&1'
		local pipe = assert(io.popen(command, 'r')); local output = pipe:read('*a'); local ok = pipe:close()
		helpers.assert_eq(ok, true, output); helpers.assert_eq(output, 'PASS: markerless continuity preserved\n')
	end)
end)
