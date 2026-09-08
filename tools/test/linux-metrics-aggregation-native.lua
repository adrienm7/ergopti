-- tools/test/linux-metrics-aggregation-native.lua
-- Execute production projection against real SQLite, then against raw-row SQL.
local root, database = assert(arg[1]), assert(arg[2])
package.path = root .. '/static/ergopti_plus/linux/?.lua;'
	.. root .. '/static/ergopti_plus/_shared/lua/?.lua;' .. package.path
package.loaded['logger.shim'] = {
	debug = function() end, info = function() end,
	warn = function(_, message) error(message) end,
	error = function(_, message) error(message) end,
}
local json = require('json')
local command = require('modules.keylogger.sqlite_command')
local reader = require('modules.keylogger.sqlite_reader')
local original_build, original_popen = command.build, io.popen
local row_count = 0
io.popen = function(...)
	local pipe = assert(original_popen(...))
	return {
		read = function(_, mode)
			local body = pipe:read(mode)
			local rows = body == '' and {} or json.decode(body)
			assert(type(rows) == 'table', 'native SQLite must return JSON rows')
			row_count = row_count + #rows
			return body
		end,
		close = function()
			local ok, kind, status = pipe:close()
			assert(ok == true or ok == 0, 'native SQLite exit failed: ' .. tostring(kind) .. ':' .. tostring(status))
			return ok, kind, status
		end,
	}
end
local function equal(a, b)
	assert(type(a) == type(b), 'projection type changed')
	if type(a) == 'number' then
		assert(math.abs(a - b) <= 1e-12 * math.max(1, math.abs(a), math.abs(b)), 'numeric projection changed')
		return
	end
	if type(a) ~= 'table' then assert(a == b, 'projection value changed'); return end
	for k, v in pairs(a) do equal(v, b[k]) end
	for k in pairs(b) do assert(a[k] ~= nil, 'projection key lost') end
end
local function workload()
	return {
		reader.read_ngrams(database),
		reader.read_range_split_today(database),
		reader.read_range_split_today(database, '2020-01-01', nil, { 'app-a' }),
		reader.read_ngrams(database, '2020-01-01', '2020-01-01', { 'app-b' }),
		reader.read_ngrams(database, '1900-01-01', '1900-01-02'),
	}
end
local candidate = workload()
local grouped_rows = row_count
-- Freeze the previous two SQL projections, not a second copy of Lua merge logic.
command.build = function(db, sql, options)
	if sql:find('FROM ngram_', 1, true) and not sql:find('FROM ngram_scancodes', 1, true) then
		local columns = sql:find('SELECT app,', 1, true) and 'app, token, c, td, e, esrc_json' or 'token, c, td, e, esrc_json'
		-- Remove only the new typed partition; retain the actual date/app filters.
		sql = sql:gsub(" AND %(typeof%(c%).*$", ';')
		sql = sql:gsub(" WHERE %(typeof%(c%).*$", ';')
		sql = sql:gsub('SELECT .- FROM ', 'SELECT ' .. columns .. ' FROM ', 1)
		sql = sql:gsub(' GROUP BY .-;', ';')
	end
	return original_build(db, sql, options)
end
row_count = 0
local baseline = workload()
equal(baseline, candidate)
assert(baseline[1].c.token.c > 0 and baseline[1].c.token.hs > 0, 'nonempty semantic control required')
assert(grouped_rows < row_count, 'production must transport fewer rows than the raw query')
print(json.encode({ status = 'ok', grouped_rows = grouped_rows, raw_rows = row_count }))
