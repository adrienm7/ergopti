-- tools/test/metrics-histogram-native.lua
-- Real SQLite executes every production SELECT. macOS API plumbing is adapted;
-- this checks SQL/Lua composition, not native Hammerspoon JSON conversion.
local root, database = assert(arg[1]), assert(arg[2])
local readers_root = assert(arg[3])
package.path = root .. '/static/ergopti_plus/linux/?.lua;'
	.. root .. '/static/ergopti_plus/_shared/lua/?.lua;' .. package.path
local json = require('json')
local logger = {}
for _, name in ipairs({ 'debug', 'info', 'trace', 'done', 'start', 'success' }) do
	logger[name] = function() end
end
logger.warn = function(_, message) error(message) end
logger.error = logger.warn
package.loaded['logger.shim'] = logger
package.loaded['infra.logger'] = logger
package.loaded['hs.json'] = json
local command = require('modules.keylogger.sqlite_command')

local original_popen = io.popen
io.popen = function(...)
	local pipe = assert(original_popen(...))
	return {
		read = function(_, mode) return pipe:read(mode) end,
		close = function()
			local ok, kind, status = pipe:close()
			assert(ok == true or ok == 0, 'SQLite failed: ' .. tostring(kind) .. ':' .. tostring(status))
			return ok, kind, status
		end,
	}
end
package.loaded['hs.sqlite3'] = {
	open = function(path)
		return {
			exec = function(_, statement)
				assert(statement == 'PRAGMA query_only = 1;', 'unexpected macOS write')
				return 0
			end,
			close = function() end,
			nrows = function(_, sql)
				local pipe = assert(io.popen(assert(command.build(path, sql, { flags = { '-json', '-readonly' } })), 'r'))
				local body = pipe:read('*a')
				pipe:close()
				local rows = body == '' and {} or json.decode(body)
				local index = 0
				return function() index = index + 1; return rows[index] end
			end,
		}
	end,
}

local failures, checks = {}, 0
local function check(label, body)
	checks = checks + 1
	local ok, err = pcall(body)
	if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function equal(actual, expected)
	assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function histogram(value)
	equal(value['20'], 7)
	equal(value['50'], 2)
end
local codes = { 'c', 'bg', 'tg', 'qg', 'pg', 'hx', 'hp', 'w', 'w_bg' }
local today = os.date('%Y-%m-%d')
for _, driver in ipairs({ 'linux', 'macos' }) do
	local reader = assert(loadfile(readers_root .. '/static/ergopti_plus/' .. driver .. '/modules/keylogger/sqlite_reader.lua'))()
	local manifest = reader.read_manifest(database, '2020-01-01', today)
	for _, day in ipairs({ '2020-01-01', today }) do
		for _, app in ipairs({ 'app-a', 'app-b' }) do
			local entry = assert(manifest[day][app])
			check(driver .. ' burst ' .. day .. app, function()
				equal(entry.burst_count_total, 51)
				histogram(entry.burst_length_buckets)
			end)
			check(driver .. ' hourly ' .. day .. app, function()
				equal(entry.hourly['12'].c, 51)
				histogram(entry.hourly['12'].e_buckets)
			end)
			check(driver .. ' min5 ' .. day .. app, function()
				equal(entry.hourly_min5['12:05'].c, 51)
				histogram(entry.hourly_min5['12:05'].e_buckets)
			end)
		end
	end
	local split = reader.read_range_split_today(database, '2020-01-01', today, { 'app-a' })
	equal(split.today['app-b'], nil)
	for _, code in ipairs(codes) do
		for _, part in ipairs({ 'historical', 'today' }) do
			check(driver .. ' ' .. part .. ' ' .. code, function()
				local container = part == 'today' and split.today['app-a'] or split.historical
				local item = assert(container[code].token)
				equal(item.c, 51)
				equal(item.t, 510)
				equal(item.e, 51)
				equal(item.hs, 7)
				equal(item.llm, 10)
				equal(item.o, 13)
			end)
		end
	end
end
assert(#failures == 0, table.concat(failures, '\n'))
print(json.encode({ status = 'ok', checks = checks, sqlite = 'native', macos_api = 'adapted' }))
