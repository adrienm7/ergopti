-- _shared/lua/llm/request_plan/ports.lua

--- ==============================================================================
--- MODULE: LLM Request Plan — Ports
--- DESCRIPTION:
--- The three outside services the prediction orchestration drives, as contracts
--- a driver's existing owner is checked against: an HTTP client that sends the
--- request chain, a timer scheduler that arms the debounce and the retry, and a
--- tooltip renderer that shows the predictions and their info bar. The plan
--- itself never calls them (it only decides); the engine does, through these
--- shapes, so a test can drive the same decisions with a recording double.
---
--- FEATURES & RATIONALE:
--- 1. A contract is a list of required methods with their documented signature.
---    `check` raises on a missing method instead of letting the first call fail
---    late inside a timer or a network callback.
--- 2. Each driver adapts its own owner (macOS builds an HttpClient instance with
---    adapters.http_client.new(); Linux uses the module itself); the contracts
---    describe what the engine needs, not how an OS provides it.
--- 3. Seconds for timers, milliseconds for the plan: the engine converts once, at
---    the timer port, as both drivers' schedulers already take seconds.
---
--- Pinned by the per-driver request plan contract tests.
--- ==============================================================================

local M = {}

--- Required methods of each port, with the signature the engine relies on.
M.CONTRACTS = {
	HttpClient = {
		post = "post(url, headers, body, callback, options) -> started: sends a buffered POST; "
			.. "callback receives the result exactly once.",
		cancel = "cancel(owner): abandons the requests an owner started; their callbacks do not fire.",
	},
	TimerScheduler = {
		after = "after(delay_seconds, fn) -> handle: fires fn once; the handle is opaque.",
		cancel = "cancel(handle): stops a handle that has not fired; harmless on one that has.",
	},
	TooltipRenderer = {
		show = "show(rows) -> boolean: draws the predictions and, last, the info bar row.",
		hide = "hide(): removes the tooltip.",
		is_visible = "is_visible() -> boolean: whether the tooltip is on screen.",
	},
}




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- Checks that an owner offers every method of a port's contract.
--- @param port_name string "HttpClient", "TimerScheduler" or "TooltipRenderer".
--- @param owner table The driver's adapter for that port.
--- @return table owner The same owner, for chaining.
function M.check(port_name, owner)
	local contract = M.CONTRACTS[port_name]
	if contract == nil then error("unknown port: " .. tostring(port_name), 2) end
	if type(owner) ~= "table" then error(port_name .. " must be a table", 2) end
	local missing = {}
	for method in pairs(contract) do
		if type(owner[method]) ~= "function" then missing[#missing + 1] = method end
	end
	table.sort(missing)
	if #missing > 0 then
		error(port_name .. " lacks: " .. table.concat(missing, ", "), 2)
	end
	return owner
end

return M
