--- infra/signal_handlers.lua
--- ==============================================================================
--- MODULE: Native Daemon Signal Ownership
--- DESCRIPTION:
--- Installs loop-thread luv signal callbacks without luaposix. Loading this module
--- acquires nothing. Handles stay owned until their exact close callbacks retire;
--- the shutdown coordinator starts that final phase after external cleanup ACKs.
--- ==============================================================================
local M = {}
local active = nil

--- Reports physical retirement, including a refused partial installation.
--- @return boolean settled
function M.is_settled() return active == nil end

--- Retires only this installation's captured native handles. Requesting close is
--- not its acknowledgment, and a failed close remains retryable.
--- @return boolean settled
local function stop()
	local owner = active
	if not owner then return true end
	owner.admitted = false
	for _, entry in ipairs(owner.entries) do
		if not entry.closed then
			-- libuv asserts on signal_stop() for a closing watcher. Retrying the
			-- physical barrier must wait for that handle's existing close ACK.
			local closing, is_closing = pcall(owner.native.is_closing, entry.handle)
			if closing and is_closing == false then
				-- close() also stops a watcher if signal_stop refused or raised.
				-- Only its callback proves physical retirement in either case.
				local stopped, receipt = pcall(owner.native.signal_stop, entry.handle)
				if not stopped or receipt == nil or receipt == false then entry.stop_refused = true end
				pcall(owner.native.close, entry.handle, function()
					if active ~= owner or entry.closed then return end
					entry.closed = true
					for _, pending in ipairs(owner.entries) do if not pending.closed then return end end
					if not owner.inconclusive then active = nil end
				end)
			end
		end
	end
	if #owner.entries == 0 and not owner.inconclusive then active = nil end
	return active == nil
end

M.stop = stop

--- Installs one terminal/reload callback set after CLI admission. A refusal keeps
--- any acquired handles reachable through stop()/is_settled() until close ACKs.
--- @param opts table { on_term, on_hup, on_usr1? }; on_usr1 rings the local
---   reload control.
--- @return boolean admitted, string|nil error
function M.start(opts)
	if active then return false, "Signal installation is already owned or retiring" end
	if type(opts) ~= "table" or type(opts.on_term) ~= "function" or type(opts.on_hup) ~= "function"
		or (opts.on_usr1 ~= nil and type(opts.on_usr1) ~= "function") then
		return false, "Signal callbacks are incomplete"
	end
	local loaded, uv = pcall(require, "luv")
	if not loaded or type(uv) ~= "table" then return false, "Native luv signal support is unavailable" end
	local native = {}
	for _, name in ipairs({ "new_signal", "signal_start", "signal_stop", "is_closing", "close" }) do
		if type(uv[name]) ~= "function" then return false, "Native luv signal export is unavailable: " .. name end
		native[name] = uv[name]
	end
	local owner = { entries = {}, native = native, admitted = false }
	active = owner
	local specs = { { "sigint", opts.on_term, 2 }, { "sigterm", opts.on_term, 15 }, { "sighup", opts.on_hup, 1 } }
	if opts.on_usr1 then specs[#specs + 1] = { "sigusr1", opts.on_usr1, 10 } end
	for _, spec in ipairs(specs) do
		local allocated, handle = pcall(native.new_signal)
		if not allocated or handle == nil or handle == false then
			-- A constructor that raises supplies no handle proving whether it
			-- acquired a resource. Retain that inconclusive admission claim.
			if not allocated then owner.inconclusive = true end
			stop()
			return false, "Native signal handle allocation failed: " .. spec[1]
		end
		local entry = { handle = handle, closed = false }
		owner.entries[#owner.entries + 1] = entry
		local callback, number = spec[2], spec[3]
		local started, receipt = pcall(native.signal_start, handle, spec[1], function()
			if active == owner and owner.admitted then callback(number) end
		end)
		if not started or receipt == nil or receipt == false then
			stop()
			return false, "Native signal handler activation failed: " .. spec[1]
		end
	end
	owner.admitted = true
	return true
end

return M
