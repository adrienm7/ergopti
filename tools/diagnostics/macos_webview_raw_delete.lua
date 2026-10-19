-- tools/diagnostics/macos_webview_raw_delete.lua
-- Isolated reproduction of the pinned binding defect, never product admission.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local json = require("hs.json")
local config = assert(json.read(directory .. "/webview-config.json"))
local probe = { timers = {}, finished = false, closes = 0 }
_G.ERGOPTI_WEBVIEW_RAW_DELETE_PROBE = probe
local finish

local function cleanup()
	for timer in pairs(probe.timers) do timer:stop() end
	probe.timers = {}
	if probe.view and getmetatable(probe.view) ~= nil then
		-- Failure cleanup is outside the measured raw operation. A still-live
		-- candidate must not reproduce recursive automatic GC during shutdown.
		assert(probe.view:deleteOnClose(false) == probe.view, "raw cleanup opt-out refused")
		assert(probe.view:deleteOnClose() == false, "raw cleanup opt-out did not persist")
		probe.view:hide()
		probe.view:delete()
		assert(getmetatable(probe.view) == nil, "raw cleanup retained its userdata")
	end
end
hs.shutdownCallback = cleanup

finish = function(failure)
	if probe.finished then return end
	probe.finished = true
	local ok, cleanup_error = xpcall(cleanup, debug.traceback)
	local receipt = {
		schema_version = 1, contract = "native.webview-raw-delete", nonce = config.nonce,
		status = not failure and ok and "observed" or "error", error = failure,
		cleanup_error = not ok and tostring(cleanup_error) or nil,
		source_revision = config.source_revision, pid = hs.processInfo.processID,
		version = hs.processInfo.version, runtime = "native Hammerspoon",
		features = { visible_before = probe.visible == true, native_opt_in = probe.opted_in == true,
			close_callback_count = probe.closes, userdata_consumed = probe.consumed == true,
			runloop_continued = probe.continued == true },
		cleanup = { windows_consumed = ok, timers_stopped = next(probe.timers) == nil },
		ucc_userdata_gc = "unmeasured; no controller constructed",
	}
	assert(json.write(receipt, config.output_dir .. "/result.json.tmp", true, true), "raw result staging refused")
	assert(os.rename(config.output_dir .. "/result.json.tmp", config.output_dir .. "/result.json"),
		"raw result publication refused")
end

local function guarded(body)
	local ok, error = xpcall(body, debug.traceback)
	if not ok then finish(tostring(error)) end
end

local function later(body)
	local timer
	timer = hs.timer.doAfter(0.1, function()
		probe.timers[timer] = nil
		if not probe.finished then guarded(body) end
	end)
	probe.timers[assert(timer, "raw native timer refused")] = true
end

guarded(function()
	assert(hs.processInfo.version == config.expected_version, "unexpected raw native runtime")
	assert(hs.screen.mainScreen(), "raw control has no native GUI screen")
	local timeout = hs.timer.doAfter(45, function() finish("raw native observation deadline exceeded") end)
	probe.timers[assert(timeout)] = true
	local view = assert(hs.webview.new({ x = 80, y = 80, w = 260, h = 160 }, {}))
	probe.view = view
	assert(type(view) == "userdata", "raw native webview unavailable")
	assert(view:deleteOnClose(true) == view and view:deleteOnClose() == true, "raw opt-in refused")
	probe.opted_in = true
	view:windowStyle({ "titled", "closable" }):windowTitle("Raw delete binding control")
	view:windowCallback(function(action, exact)
		guarded(function()
			if action == "closing" then
				assert(rawequal(exact, view), "raw close borrowed a different native window")
				probe.closes = probe.closes + 1
			end
		end)
	end)
	view:show()
	local function consumed()
		later(function()
			if getmetatable(view) ~= nil then consumed(); return end
			assert(probe.closes == 1, "raw close callback was not exact-once")
			probe.consumed, probe.continued = true, true
			finish()
		end)
	end
	later(function()
		assert(view:isVisible() == true, "raw control was not visibly presented")
		probe.visible = true
		-- Preserve the exact failing public operation. Its expected native stderr
		-- signature is classified separately, never counted as a product success.
		view:delete()
		consumed()
	end)
end)
