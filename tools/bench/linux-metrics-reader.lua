-- tools/bench/linux-metrics-reader.lua
-- Synthetic production-reader probe; no daemon, WebKit, or painted-frame claim.
local root, database = assert(arg[1]), assert(arg[2])
local days, apps, events = assert(tonumber(arg[3])), assert(tonumber(arg[4])), assert(tonumber(arg[5]))
package.path = root .. '/static/ergopti_plus/linux/?.lua;'
	.. root .. '/static/ergopti_plus/_shared/lua/?.lua;' .. package.path
package.loaded['logger.shim'] = {
	debug = function() end, info = function() end,
	warn = function(_, message) io.stderr:write(tostring(message), '\n') end,
	error = function(_, message) error(tostring(message)) end,
}
local ffi = require('ffi')
ffi.cdef[[struct timespec { long tv_sec; long tv_nsec; }; int clock_gettime(int, struct timespec *);]]
local function now()
	local value = ffi.new('struct timespec[1]')
	assert(ffi.C.clock_gettime(1, value) == 0)
	return tonumber(value[0].tv_sec) * 1000 + tonumber(value[0].tv_nsec) / 1000000
end
local reader = require('modules.keylogger.sqlite_reader')
local bridge = require('ui.metrics_typing.bridge')
local json = require('json')
local phases, calls = {}, 0
local native_popen = io.popen
io.popen = function(...)
	calls = calls + 1
	return native_popen(...)
end
local function measure(name, callback)
	local started, before = now(), calls
	local result = callback()
	phases[#phases + 1] = { name = name, elapsed_ms = now() - started, cli_calls = calls - before }
	return result
end
local function check_range(payload, selected_apps)
	for _, code in ipairs({ 'c', 'bg', 'tg', 'qg', 'pg', 'hx', 'hp', 'w', 'w_bg' }) do
		assert(payload.historical[code].synthetic0.c == (days - 1) * selected_apps * 7,
			'missing or duplicated historical n-grams: ' .. code)
		assert(payload.today['synthetic.app.0'][code].synthetic0.c == 7,
			'missing or duplicated today n-grams: ' .. code)
	end
end
-- This port composes real reader methods, NOT the daemon's cache/live-delta path.
local state = { keylogger = { get_dashboard_payload = function(options)
	local manifest = measure('manifest', function() return reader.read_manifest(database) end)
	local today = os.date('%Y-%m-%d')
	assert(manifest[today] and manifest[today]['synthetic.app.0'], 'missing seeded manifest')
	assert(manifest[today]['synthetic.app.0'].chars == events * 7, 'incorrect seeded manifest total')
	local prefetch
	if options.include_prefetch then
		prefetch = measure('range', function() return reader.read_range_split_today(database) end)
		check_range(prefetch, apps)
	end
	return { metrics_manifest = manifest, _prefetch_data = prefetch }
end, get_range_payload = function(first, last, apps)
	return measure('filtered_range', function() return reader.read_range_split_today(database, first, last, apps) end)
end } }
for _, action in ipairs({ 'ready', 'refresh', 'ready' }) do
	measure('composed_bridge_' .. action, function() return bridge.on_message({ action = action }, state) end)
end
measure('composed_bridge_range', function()
	local payload = bridge.on_message({ action = 'range', apps = { 'synthetic.app.0' }, request_id = 17 }, state)
	assert(payload.range_request_id == 17 and payload._prefetch_data.historical.c.synthetic0)
	check_range(payload._prefetch_data, 1)
	return payload
end)
print(json.encode({ phases = phases, cli_calls = calls, painted = false,
	scope = 'real reader and bridge with synthetic keylogger composition; no cache or live delta' }))
