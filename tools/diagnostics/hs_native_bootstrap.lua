-- tools/diagnostics/hs_native_bootstrap.lua
-- Runs the original native probes only after an exact startup-owner admission.
-- This standalone feature proof never loads the managed ErgoptiPlus driver.

local M = {}

local function read_json(path)
	local file = assert(io.open(path, "rb"))
	local raw = assert(file:read("*a"))
	assert(file:close())
	return assert(hs.json.decode(raw))
end

local function publish(path, value)
	local temporary = path .. ".pending"
	assert(not hs.fs.attributes(path), "An owned bootstrap receipt already exists")
	local file = assert(io.open(temporary, "wb"))
	assert(file:write(assert(hs.json.encode(value)) .. "\n"))
	assert(file:close())
	assert(os.rename(temporary, path))
end

function M.run(context_path)
	local context = read_json(context_path)
	assert(context.schema_version == 1 and context.contract == "hs.startup.supplementary-feature")
	assert(context.feature == "delayed_timer" or context.feature == "karabiner_config" or context.feature == "script_scope")
	assert(type(context.nonce) == "string" and #context.nonce == 32)
	assert(context.admission_timeout == 10)
	assert(context.feature_timeout == (context.feature == "delayed_timer" and 15 or 10))
	local identity = {
		schema_version = 1,
		contract = context.contract,
		nonce = context.nonce,
		pid = hs.processInfo.processID,
		executable = hs.processInfo.executablePath,
		bundle_id = hs.processInfo.bundleID,
		version = hs.processInfo.version,
	}
	for _, key in ipairs({ "executable", "bundle_id", "version" }) do
		assert(identity[key] == context[key], "The native startup identity differs: " .. key)
	end
	local owner = { timers = {}, started = false, settled = false, errors = {} }
	assert(_G.__ergopti_native_bootstrap == nil, "A supplementary bootstrap already owns admission")
	_G.__ergopti_native_bootstrap = owner
	local probe

	local function finish(complete)
		if owner.settled then return end
		owner.settled = true
		if owner.started and context.feature == "delayed_timer" then
			local ok, receipt = pcall(probe.cleanup, context.nonce)
			if not ok or receipt ~= context.nonce then
				owner.errors[#owner.errors + 1] = "Original timer cleanup refused: " .. tostring(receipt)
			end
		end
		for _, timer in ipairs(owner.timers) do
			local ok, stopped = pcall(timer.stop, timer)
			if not ok or stopped == nil or stopped == false then
				owner.errors[#owner.errors + 1] = "Bootstrap timer stop refused: " .. tostring(stopped)
			end
		end
		local result = {}
		for key, value in pairs(identity) do result[key] = value end
		result.phase = "settled"
		result.complete = complete and #owner.errors == 0
		result.cleanup_acknowledged = #owner.errors == 0
		result.errors = owner.errors
		publish(context.paths.settled, result)
		if #owner.errors == 0 then _G.__ergopti_native_bootstrap = nil end
	end

	local function guarded(callback)
		return function()
			local ok, detail = xpcall(callback, debug.traceback)
			if not ok then
				owner.errors[#owner.errors + 1] = tostring(detail)
				finish(false)
			end
		end
	end

	owner.admission_watchdog = hs.timer.doAfter(context.admission_timeout, guarded(function()
		owner.errors[#owner.errors + 1] = "Native startup admission timed out"
		finish(false)
	end))
	owner.timers[#owner.timers + 1] = owner.admission_watchdog
	owner.poll = hs.timer.new(0.05, guarded(function()
		if owner.started then
			if hs.fs.attributes(context.paths.feature) then finish(true) end
			return
		end
		if not hs.fs.attributes(context.paths.admit) then return end
		local admitted = read_json(context.paths.admit)
		local count = 0
		for key, value in pairs(identity) do
			count = count + 1
			assert(type(admitted[key]) == type(value) and admitted[key] == value,
				"A foreign native startup owner attempted admission: " .. key)
		end
		local fields = 0
		for _ in pairs(admitted) do fields = fields + 1 end
		assert(fields == count + 1 and admitted.phase == "admit", "Native admission has unknown fields")
		assert(owner.admission_watchdog:stop(), "Admission watchdog retirement refused")
		for index = #context.module_roots, 1, -1 do
			local root = context.module_roots[index]
			package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
		end
		probe = assert(dofile(context.probe_source))
		owner.feature_watchdog = hs.timer.doAfter(context.feature_timeout, guarded(function()
			owner.errors[#owner.errors + 1] = "Original native feature receipt timed out"
			finish(false)
		end))
		owner.timers[#owner.timers + 1] = owner.feature_watchdog
		owner.started = true
		local receipt
		if context.feature == "delayed_timer" then
			receipt = probe.run(context.paths.feature, context.nonce)
		else
			receipt = probe.run(context.paths.feature, context.destination, context.nonce)
		end
		assert(receipt == context.nonce, "The original feature did not acknowledge its nonce")
		if hs.fs.attributes(context.paths.feature) then finish(true) end
	end))
	owner.timers[#owner.timers + 1] = owner.poll
	assert(owner.poll:start(), "The native startup admission timer did not start")
	local ready = {}
	for key, value in pairs(identity) do ready[key] = value end
	ready.phase = "ready"
	publish(context.paths.ready, ready)
	return context.nonce
end

return M
