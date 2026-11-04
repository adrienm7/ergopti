--- adapters/desktop_opener_worker.lua

--- ==============================================================================
--- MODULE: Detached Desktop Launch Worker (Linux)
--- DESCRIPTION:
--- Confirms the desktop launcher's exit without lending it driver descriptors or
--- membership of the owned helper group. The desktop receives the application
--- lifetime; stopping this helper never promises to stop an accepted application.
--- ==============================================================================

local M = {}

--- Launches one literal desktop target in a distinct session.
--- @param argv table Literal target and canonical deadline as decimal text.
--- @return integer Process exit status.
function M.run(argv)
	if type(argv) ~= "table" or #argv ~= 2 or type(argv[1]) ~= "string" or argv[1] == ""
		or argv[1]:find("\0", 1, true) or type(argv[2]) ~= "string" or not argv[2]:match("^[1-9]%d*$") then return 64 end
	local timeout = tonumber(argv[2])
	if not timeout or timeout == math.huge or timeout % 1 ~= 0 then return 64 end
	for index in pairs(argv) do
		if type(index) ~= "number" or index % 1 ~= 0 or index > 2 then return 64 end
	end
	local uv = require("luv")
	local child, status, timer = nil, nil, uv.new_timer()
	if not timer then return 69 end
	local function close(handle)
		if handle and not uv.is_closing(handle) then uv.close(handle) end
	end
	local function finish(code)
		if status ~= nil then return end
		status = code
		uv.timer_stop(timer)
		close(timer)
		-- Closing the observer handle does not signal the already transferred
		-- desktop session. This bound also survives a crash of the daemon.
		close(child)
	end
	uv.update_time()
	local started, reason = uv.timer_start(timer, timeout, 0, function() finish(124) end)
	if started == nil or started == false or reason ~= nil then
		close(timer); uv.run(); return 69
	end
	child = uv.spawn("xdg-open", { args = { argv[1] }, detached = true, stdio = { nil, nil, nil } }, function(code, signal)
		finish(signal ~= 0 and 128 + signal or code)
	end)
	if not child then io.stderr:write("Desktop launcher spawn refused.\n"); finish(69) end
	uv.run()
	return type(status) == "number" and status or 70
end

if type(arg) == "table" and type(arg[0]) == "string"
	and arg[0]:gsub("\\", "/"):match("([^/]+)$") == "desktop_opener_worker.lua" then
	if arg[1] == "--help" and arg[2] == nil then
		io.write("Usage: desktop_opener_worker.lua TARGET TIMEOUT_MS\n")
		os.exit(0)
	end
	os.exit(M.run(arg))
end

return M
