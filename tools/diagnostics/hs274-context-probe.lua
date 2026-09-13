-- tools/diagnostics/hs274-context-probe.lua
-- Requires actual context notifications after controlled native WebView changes.
local Result = require("adapters.webview_result")
local M = {}
local PHASES = {
	{ name = "private", allowed = false, title = "Private Browsing", field = "input" },
	{ name = "public", allowed = true, title = "HS274 input fixture", field = "input" },
	{ name = "secure", allowed = false, title = "HS274 input fixture", field = "secret" },
	{ name = "resumed", allowed = true, title = "HS274 input fixture", field = "input" },
}

function M.new(view, observations, receipt, on_complete, on_error)
	local state, timer, phase, baseline, deadline, applied = "new", nil, 0, 0, 0, false
	local probe = {}
	function probe.stop()
		state = "stopped"
		if timer then
			assert(timer:stop() ~= false, "Native context probe timer refused stop")
			timer = nil
		end
	end
	local function guard(callback)
		if state ~= "running" then return end
		local ok, err = xpcall(callback, debug.traceback)
		if not ok then
			local stopped, detail = pcall(probe.stop)
			if not stopped then err = err .. "\n" .. tostring(detail) end
			on_error(err)
		end
	end
	local function advance()
		phase = phase + 1
		if phase > #PHASES then probe.stop(); on_complete(); return end
		local target, current = PHASES[phase], phase
		baseline, applied = #observations, false
		deadline = hs.timer.absoluteTime() + 2000000000
		assert(view:windowTitle(target.title), "Native context probe title was refused")
		local script = "document.getElementById('" .. target.field .. "').focus(); document.activeElement.id === '" .. target.field .. "'"
		assert(view:evaluateJavaScript(script, function(focused, err)
			guard(function()
				if current ~= phase then return end
				assert(not Result.is_error(err) and focused == true, "Native context probe focus failed")
				applied = true
			end)
		end), "Native context probe JavaScript was refused")
	end
	local function poll()
		guard(function()
			assert(hs.timer.absoluteTime() <= deadline, "Native context probe observation timed out: " .. PHASES[phase].name)
			local latest = observations[#observations]
			if applied and #observations > baseline and latest.allowed == PHASES[phase].allowed then
				receipt[#receipt + 1] = { phase = PHASES[phase].name, observation = #observations }
				advance()
			end
		end)
	end
	function probe.start()
		assert(state == "new", "Native context probe cannot restart")
		state = "running"
		guard(function()
			timer = assert(hs.timer.doEvery(0.02, poll), "Native context probe timer was refused")
			advance()
		end)
	end
	return probe
end

return M
