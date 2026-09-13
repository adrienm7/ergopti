-- tools/diagnostics/hs274-target.lua
-- Drive a separate native target while keeping AX observations in the consumer.
local M = {}

function M.new(config, on_error)
	local sequence, timer, window_id, stopped = 0, nil, nil, false
	local target = {}
	local function send(phase)
		sequence = sequence + 1
		local pending = config.target_request .. ".pending"
		assert(hs.json.write({ sequence = sequence, phase = phase }, pending, true, true), "Cannot write target command")
		assert(os.rename(pending, config.target_request), "Cannot publish target command")
	end
	function target:hswindow()
		local window = window_id and hs.window.get(window_id)
		assert(not window or window:application():pid() == config.target_pid, "Native target window identity changed")
		return window
	end
	function target:request(phase, callback)
		assert(not stopped and not timer, "Native target request overlaps or follows stop")
		send(phase)
		local deadline = hs.timer.absoluteTime() + 2000000000
		local active = true
		timer = assert(hs.timer.doEvery(0.02, function()
			if not active or stopped then return end
			local ok, err = xpcall(function()
				assert(hs.timer.absoluteTime() <= deadline, "Native target response timed out")
				if not hs.fs.attributes(config.target_response) then return end
				local receipt = assert(hs.json.read(config.target_response), "Malformed native target receipt")
				if receipt.sequence < sequence then return end
				assert(receipt.sequence == sequence and receipt.phase == phase and receipt.pid == config.target_pid,
					"Native target response identity mismatch")
				assert(type(receipt.window_id) == "number" and receipt.window_id > 0, "Missing native target window")
				assert(not window_id or receipt.window_id == window_id, "Native target replaced its window")
				window_id = receipt.window_id
				assert(timer:stop() ~= false, "Native target timer did not stop")
				timer, active = nil, false
				callback()
			end, debug.traceback)
			if not ok then
				active = false
				local closed, detail = pcall(target.delete, target)
				if not closed then err = err .. "\n" .. tostring(detail) end
				on_error(err)
			end
		end), "Native target timer was refused")
	end
	function target:delete()
		if stopped then return true end
		stopped = true
		if timer then assert(timer:stop() ~= false, "Native target timer did not stop"); timer = nil end
		send("close")
		return true
	end
	return target
end

return M
