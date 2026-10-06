-- tools/test/linux-metrics-aggregation-native.lua
-- Execute production projection against real SQLite, then against raw-row SQL.
local root, database = assert(arg[1]), assert(arg[2])
local control = arg[3]
assert(control == nil or control == 'legacy-global-column' or control == 'legacy-app-column',
	'unknown raw projection contract control')
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
local first_native_output
local function native_rows(output)
	local accepted, body, reason = command.read_exit_receipt(output)
	assert(accepted == true, 'native SQLite exit receipt failed: ' .. tostring(reason))
	local rows = body == '' and {} or json.decode(body)
	assert(type(rows) == 'table', 'native SQLite must return JSON rows')
	return rows
end
local function refuses_rows(output, reason)
	local ok, detail = pcall(native_rows, output)
	assert(ok == false and tostring(detail):find(reason, 1, true),
		'native SQLite refusal must retain its specific receipt or JSON failure')
end
assert(#native_rows('[]\n\nERGOPTI_SQL_EXIT_STATUS=0\n') == 0, 'empty JSON rows must remain admitted')
assert(#native_rows('\nERGOPTI_SQL_EXIT_STATUS=0\n') == 0, 'empty successful output must remain admitted')
refuses_rows('[]\n', 'native SQLite exit receipt failed:')
refuses_rows('[]\n\nERGOPTI_SQL_EXIT_STATUS=1\n', 'native SQLite exit receipt failed:')
refuses_rows('[]\n\nERGOPTI_SQL_EXIT_STATUS=invalid\n', 'native SQLite exit receipt failed:')
refuses_rows('{malformed}\n\nERGOPTI_SQL_EXIT_STATUS=0\n', 'native SQLite must return JSON rows')
-- Exercise the native CLI failure too; LuaJIT's pclose can conceal its exit status.
local failure_command = assert(command.build(database, 'SELECT missing_synthetic_column;', {
	flags = { '-readonly', '-json' }, capture_exit = true,
}))
local failure_pipe = assert(original_popen(failure_command, 'r'))
local failure_output = assert(failure_pipe:read('*a'))
failure_pipe:close()
refuses_rows(failure_output, 'native SQLite exit receipt failed:')
io.popen = function(...)
	local pipe = assert(original_popen(...))
	return {
		read = function(_, mode)
			local output = pipe:read(mode)
			local rows = native_rows(output)
			first_native_output = first_native_output or output
			row_count = row_count + #rows
			return output
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
-- Equality alone can compare two truncated projections. Pin complete literal
-- keys and independently seeded metrics before switching to raw-row SQL.
local transport_tokens = { 'quote"token', 'back\\slash', 'literal\\u0000',
	'nul\0tailA', 'nul\0tailB', 'line\n\tend' }
local codes = { 'c', 'bg', 'tg', 'qg', 'pg', 'hx', 'hp', 'w', 'w_bg' }
for _, code in ipairs(codes) do
	for _, token in ipairs(transport_tokens) do
		local total = assert(candidate[1][code][token], 'complete global token key missing')
		assert(total.c == 8 and total.t == 16 and total.e == 4, 'independent global token metrics changed')
		for _, app in ipairs({ 'app-a', 'app-b' }) do
			local today = assert(candidate[2].today[app][code][token], 'complete application token key missing')
			assert(today.c == 2 and today.t == 4 and today.e == 1, 'independent application token metrics changed')
		end
	end
end
-- Mutate an actual successful native output as well as the independent literals.
assert(type(first_native_output) == 'string', 'real native output control required')
local missing_receipt, removed = first_native_output:gsub('\n[^\n]+\n$', '')
assert(removed == 1 and missing_receipt ~= first_native_output, 'missing-receipt control must change native output')
refuses_rows(missing_receipt, 'native SQLite exit receipt failed:')
local refused_receipt, replaced = first_native_output:gsub('0\n$', '7\n')
assert(replaced == 1 and refused_receipt ~= first_native_output, 'refused-receipt control must change native output')
refuses_rows(refused_receipt, 'native SQLite exit receipt failed:')
-- Freeze the previous two SQL projections, not a second copy of Lua merge logic.
command.build = function(db, sql, options)
	if sql:find('FROM ngram_', 1, true) and not sql:find('FROM ngram_scancodes', 1, true) then
		local by_app = sql:find('SELECT app,', 1, true) ~= nil
		-- Raw rows must retain the reader's complete-token transport contract;
		-- only aggregation changes between the two projections.
		local token_column = 'json_quote(token) AS token_json'
		if (by_app and control == 'legacy-app-column')
			or (not by_app and control == 'legacy-global-column') then
			token_column = 'token'
		end
		local columns = (by_app and 'app, ' or '') .. token_column .. ', c, td, e, esrc_json'
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
