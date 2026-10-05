--- tests/hardware/run_sqlite_kc_hold_projection.lua

--- ==============================================================================
--- MODULE: Native Reader Modifier-Hold Projection (Linux)
--- DESCRIPTION:
--- Public Writer APIs persist real SQLite data. Independent SQL proves the
--- device sum, maximum and rounding before Reader emits canonical dashboard
--- names. This validates software statistics, not physical tap-hold behavior.
--- OWNED_READER_PROOF selects the existing private output directory used by
--- run_sqlite_kc_hold_consumers.cjs and retains exact native evidence.
--- ==============================================================================

local uv = require('luv')
require('compat.utf8').install()
local Writer = require('modules.keylogger.sqlite_writer')
local Reader = require('modules.keylogger.sqlite_reader')
local Json = require('json')
local root = assert(os.getenv('OWNED_READER_PROOF'))
local db = root .. '/metrics.sqlite'
local checks, failures = 0, 0
local function check(name, fn)
	checks = checks + 1
	local ok, err = xpcall(fn, debug.traceback)
	if ok then print('PASS ' .. name) else failures = failures + 1; io.stderr:write('FAIL ' .. name .. ': ' .. tostring(err) .. '\n') end
end
assert(Writer.open_db(db))
assert(Writer.upsert_app_day('d1','2026-10-03','editor',{chars=20,time_ms=10000}))
local fixtures = {
	{'d1','2026-10-03','editor',29,900,3,500,2,1},
	{'d2','2026-10-03','editor',29,600,2,600,1,1},
	{'d1','2026-10-03','editor',42,70,2,50,2,0},
	{'d1','2026-10-03','browser',29,200,1,200,0,1},
	{'d1','2026-10-02','editor',29,333,1,333,1,0},
}
for _, r in ipairs(fixtures) do assert(Writer.upsert_kc_hold(r[1], {date=r[2], app=r[3], keycode=r[4], sum_ms=r[5], count=r[6], max_ms=r[7], tap_count=r[8], hold_count=r[9]})) end
check('independent SQL preserves the exact two-device integer aggregate', function()
	local rows = assert(Writer.query_rows("SELECT SUM(sum_ms),SUM(count),MAX(max_ms),SUM(tap_count),SUM(hold_count),COUNT(*) FROM agg_app_day_kc_hold WHERE date='2026-10-03' AND app='editor' AND keycode=29;"))
	assert(#rows == 1 and rows[1] == '1500|5|600|3|2|2', 'independent native SUM/MAX aggregate differs: ' .. table.concat(rows, ';'))
end)
local m = Reader.read_manifest(db,'2026-10-03','2026-10-03', {'editor'})
check('Reader retains exact selected day, app and key records', function()
	assert(m['2026-10-03'] and m['2026-10-03'].editor)
	assert(not m['2026-10-02'] and not m['2026-10-03'].browser)
	assert(m['2026-10-03'].editor.kc_hold['29'] and m['2026-10-03'].editor.kc_hold['42'])
end)
local h = m['2026-10-03'].editor.kc_hold['29']
for _, f in ipairs({{'s',1500},{'n',5},{'m',600},{'tap',3},{'hold',2}}) do
	check('canonical modifier-hold field ' .. f[1],function() assert(h[f[1]] == f[2], f[1] .. ' expected ' .. f[2] .. ', received ' .. tostring(h[f[1]])) end)
end
check('the complete record matches the five shared schema keys only',function()
	local allowed = {s=true,n=true,m=true,tap=true,hold=true}
	local count = 0
	for field in pairs(h) do assert(allowed[field], 'SQL-only transport field ' .. field); count = count + 1 end
	assert(count == 5)
end)
local fh = assert(io.open(root .. '/manifest.json', 'wb')); assert(fh:write(Json.encode(m))); assert(fh:close())

assert(Writer.upsert_kc_hold('d1', { date = '2026-10-03', app = 'rounding-controls', keycode = 56,
	sum_ms = 123.9, count = 2.9, max_ms = 77.9, tap_count = 1.9, hold_count = 1.9 }))
assert(Writer.upsert_kc_hold('d2', { date = '2026-10-03', app = 'rounding-controls', keycode = 57,
	sum_ms = 0, count = 0, max_ms = 0, tap_count = 0, hold_count = 0 }))
check('native Writer preserves existing integer rounding before projection', function()
	local rows = assert(Writer.query_rows("SELECT sum_ms,count,max_ms,tap_count,hold_count FROM agg_app_day_kc_hold WHERE app='rounding-controls' AND keycode=56;"))
	assert(#rows == 1 and rows[1] == '123|2|77|1|1')
end)
check('native Writer preserves legitimate zero statistics', function()
	local rows = assert(Writer.query_rows("SELECT sum_ms,count,max_ms,tap_count,hold_count FROM agg_app_day_kc_hold WHERE app='rounding-controls' AND keycode=57;"))
	assert(#rows == 1 and rows[1] == '0|0|0|0|0')
end)
local controls = Reader.read_manifest(db, '2026-10-03', '2026-10-03', { 'rounding-controls' })['2026-10-03']['rounding-controls'].kc_hold
for _, fixture in ipairs({ { '56', { s = 123, n = 2, m = 77, tap = 1, hold = 1 } }, { '57', { s = 0, n = 0, m = 0, tap = 0, hold = 0 } } }) do
	check('Reader preserves exact typed native control ' .. fixture[1], function()
		local record, count = controls[fixture[1]], 0
		for field, expected in pairs(fixture[2]) do
			assert(type(record[field]) == 'number' and record[field] == expected)
			count = count + 1
		end
		for field in pairs(record) do assert(fixture[2][field] ~= nil); count = count - 1 end
		assert(count == 0)
	end)
end

Writer.close_db()
print(string.format('Native Reader modifier-hold projection: %d checks, %d failures',checks,failures))
assert(checks == 12)
os.exit(failures == 0 and 0 or 1)
