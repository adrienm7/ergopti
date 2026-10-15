--- _shared/lua/test/runner_timing.lua

--- ==============================================================================
--- MODULE: Shared Lua Runner Wall Timing
--- DESCRIPTION:
--- Records case and module-load wall intervals without changing their protected
--- call verdicts. The runner captures the native clock before fixtures replace
--- package.loaded entries; invalid measurements remain explicit diagnostic debt.
--- ==============================================================================

local M = {}
local format = string.format
local native_stdout = io.stdout
local native_write = native_stdout.write
local native_flush = native_stdout.flush

local function finite(value)
	return type(value) == "number" and value == value
		and value >= 0 and value < math.huge
end

local function quoted(value)
	return '"' .. value:gsub('[%z\1-\31\\"]', function(byte)
		if byte == '"' then return '\\"' end
		if byte == "\\" then return "\\\\" end
		return format("\\u%04x", byte:byte())
	end) .. '"'
end

--- Serializes one diagnostic row, separate from pass/fail and assertion counts.
--- @param row table Completed timing record.
--- @return string Structured log line accepted by tools/test/report.cjs.
function M.line(row)
	return "# lua_timing " .. format(
		'{"schema":1,"driver":%s,"id":%d,"kind":%s,"module":%s,"name":%s,"status":%s,"elapsed_ms":%s,"timing_error":%s}',
		quoted(row.driver), row.id, quoted(row.kind), quoted(row.module),
		quoted(row.name), quoted(row.status),
		row.elapsed_ms and format("%.6f", row.elapsed_ms) or "null",
		quoted(row.timing_error)
	)
end

--- Builds an independent recorder over an explicit nanosecond wall clock.
--- Injected ports let both interpreters test failure paths without native work.
--- @param driver string Diagnostic driver identity.
--- @param now_ns function Captured monotonic nanosecond clock.
--- @param emit function Receives a completed record.
--- @return table Recorder with measure and has_errors methods.
function M.new(driver, now_ns, emit)
	assert(type(driver) == "string" and driver ~= "", "timing driver is required")
	assert(type(now_ns) == "function", "monotonic timing provider is required")
	assert(type(emit) == "function", "timing sink is required")
	local sequence, failures, last = 0, 0, nil
	local recorder = {}

	local function sample()
		local ok, value = pcall(now_ns)
		if not ok then return nil, "clock_failed" end
		if not finite(value) then return nil, "clock_invalid" end
		if last and value < last then return nil, "clock_reversed" end
		last = value
		return value
	end

	--- Measures the original protected call, including its setup and exceptions.
	--- A broken clock or sink cannot replace the callback's original error object.
	--- @param kind string Case or module interval.
	--- @param name string Authored case or module name.
	--- @param callback function Original subject including setup.
	--- @param owner string|nil Module containing the case.
	--- @return boolean ok Original protected-call verdict.
	--- @return any result Original protected-call result or error object.
	--- @return table row Completed diagnostic row.
	function recorder.measure(kind, name, callback, owner)
		assert(kind == "case" or kind == "module", "timing kind is invalid")
		assert(type(name) == "string" and type(callback) == "function", "timing subject is invalid")
		sequence = sequence + 1
		local id = sequence
		local started, start_error = sample()
		local ok, result = pcall(callback)
		local finished, finish_error = sample()
		local timing_error = start_error or finish_error or ""
		local row = {
			driver = driver, id = id, kind = kind, module = owner or "",
			name = name, status = ok and "pass" or "fail", timing_error = timing_error,
			elapsed_ms = timing_error == "" and (finished - started) / 1000000 or nil,
		}
		if timing_error ~= "" then failures = failures + 1 end
		local emitted = pcall(emit, row)
		if not emitted then failures = failures + 1 end
		return ok, result, row
	end

	--- Reports incomplete diagnostics independently from assertion verdicts.
	--- @return boolean failed True after an invalid clock or failed sink.
	function recorder.has_errors() return failures > 0 end

	--- Applies the existing plain substring filter before reading the clock.
	--- @param name string Authored case name.
	--- @param callback function Original body.
	--- @param setup function|nil Current before_each hook.
	--- @param filter string|nil Existing runner substring filter.
	--- @param owner string|nil Current test module.
	--- @return boolean|nil ok Nil for a filtered case; otherwise original verdict.
	--- @return any result Original protected-call result or error.
	function recorder.case(name, callback, setup, filter, owner)
		if filter and not string.find(name, filter, 1, true) then return nil end
		return recorder.measure("case", name, function()
			if setup then setup() end
			callback()
		end, owner)
	end
	return recorder
end

--- Captures the real luv clock before any test mutates native module stubs.
--- Both canonical CI interpreters must admit their installed native provider.
--- @param driver string Diagnostic driver identity.
--- @param emit function|nil Recording sink for isolated contract tests.
--- @return table Recorder bound to the captured native clock and output sink.
function M.capture(driver, emit)
	local ok, provider = pcall(require, "luv")
	assert(ok and type(provider) == "table" and type(provider.hrtime) == "function",
		"Lua runner wall timing requires native luv.hrtime")
	local now_ns = provider.hrtime
	return M.new(driver, now_ns, emit or function(row)
		-- Finish the parent's complete frame before the next case can start a child.
		assert(native_write(native_stdout, M.line(row) .. "\n"))
		assert(native_flush(native_stdout))
	end)
end

return M
