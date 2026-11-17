--- tests/hardware/lib/gtk_fields_session.lua

--- ==============================================================================
--- MODULE: Real GTK Fields, Their Privacy Owner And The XTest Wire
--- DESCRIPTION:
--- What the flows run by run_gtk_fields_live.sh share:
--- 1. A tests/hardware/gtk_fields_fixture.py window, mapped once openbox
---    manages it (x11_window_manager.py), whose fields' texts, focus and caret
---    are read from the state document the fixture rewrites whole.
--- 2. The daemon's privacy owner on the real accessibility bus: the resident
---    AT-SPI focus watch, the secure-field detector and the metrics focus guard
---    built as ergopti_hotstrings.lua builds them, whose capture_text_owner is
---    the text destination every typing action retains.
--- 3. The production uinput writer with its last hop moved to XTest
---    (lib/xtest_uinput_backend.lua): Xvfb reads no evdev device, and the X
---    server maps each key through its own XKB keymap as it would a uinput key.
--- ==============================================================================

local M = {}

local uv = require("luv")
local Json = require("core.text.engine.json")
local Shell = require("core.process.adapters.shell_runner")

local WAIT_SECONDS = 10
local POLL_MS = 20
-- AT-SPI's ATSPI_ROLE_PASSWORD_TEXT, the role an invisible GtkEntry reports.
local PASSWORD_ROLE = 40





-- =================================
-- =================================
-- ======= 1/ The GTK window =======
-- =================================
-- =================================

--- Polls until the predicate holds or the deadline passes, running the loop.
--- @param predicate function
--- @param seconds number|nil
--- @return boolean
function M.settle(predicate, seconds)
	local deadline = uv.hrtime() + (seconds or WAIT_SECONDS) * 1e9
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(POLL_MS)
	until uv.hrtime() > deadline
	return predicate() and true or false
end

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local content = file:read("*a")
	file:close()
	return content
end

--- Opens the fixture window and waits until openbox manages it.
--- @param title string Unique window title.
--- @param kinds table Field kinds in Tab order ("text" or "password").
--- @return table fixture { state, control, wait_state, stop, directory }
function M.open_window(title, kinds)
	local directory = assert(uv.fs_mkdtemp(os.getenv("HOME") .. "/gtk-fields-XXXXXX"))
	local args = { "tests/hardware/gtk_fields_fixture.py", directory, title }
	for _, kind in ipairs(kinds) do args[#args + 1] = kind end
	local handle, pid = uv.spawn("python3", { args = args, stdio = { nil, nil, 2 } }, function() end)
	assert(handle, "the GTK fixture could not start: " .. tostring(pid))
	local fixture = { directory = directory }

	--- The fixture's last whole state document, or nil before its first.
	function fixture.state()
		local body = read_file(directory .. "/state.json")
		if not body then return nil end
		local ok, state = pcall(Json.decode, body)
		return ok and state or nil
	end

	--- Waits until the fixture's state satisfies the predicate.
	function fixture.wait_state(predicate, seconds)
		return M.settle(function()
			local state = fixture.state()
			return state ~= nil and predicate(state) == true
		end, seconds)
	end

	--- Replaces the texts (when given), focuses a field and selects [start, stop).
	function fixture.control(target, start, stop, texts)
		local request = { target = target, start = start or 0, ["end"] = stop or -1, texts = texts }
		local staged = directory .. "/control.json.tmp"
		local file = assert(io.open(staged, "wb"))
		assert(file:write(Json.encode(request)))
		assert(file:close())
		assert(os.rename(staged, directory .. "/control.json"))
		assert(uv.kill(pid, "sigusr1") == 0, "the GTK fixture must receive its control signal")
		return fixture.wait_state(function(state) return state.focused == target end)
	end

	function fixture.stop()
		uv.kill(pid, "sigterm")
		Shell.run("rm -rf " .. Shell.quote(directory))
	end

	assert(fixture.wait_state(function(state) return type(state.texts) == "table" end),
		"the GTK fixture must publish its first state")
	local found, window = false, nil
	M.settle(function()
		found, window = Shell.exec_checked("xdotool search --onlyvisible --name " .. Shell.quote("^" .. title .. "$"))
		return found == true and window ~= ""
	end)
	window = window and window:match("%d+")
	assert(window, "the GTK fixture window must map")
	assert(Shell.exec_checked("python3 tests/hardware/x11_window_manager.py managed " .. window),
		"openbox must manage the GTK fixture window")
	fixture.window = window
	return fixture
end





-- ====================================
-- ====================================
-- ======= 2/ The privacy owner =======
-- ====================================
-- ====================================

--- Builds the daemon's privacy owner on the session's accessibility bus.
--- @return table privacy { guard, watch, detector, join, stop }
function M.privacy_owner()
	local Window = require("platform.focus.window_info")
	local Detector = require("platform.focus.secure_field_detector")
	local Keystats = require("modules.keystats.keystats")
	local Clock = require("core.logger.engine.monotonic")
	local Timings = require("core.timing.engine.timings")
	local Watch = require("platform.focus.atspi_focus_watch").new()
	local Guard = require("modules.keystats.focus_guard").new({
		watch = Watch, detector = Detector, keystats = Keystats,
		now_ms = Clock.now_ms, settle_ms = Timings.ms("privacy", "focus_settle_ms"),
		retry_ms = Timings.ms("privacy", "context_retry_ms"),
		capture_context_async = Window.start_privacy_context,
		publish_context = function(context) return true, Keystats.is_context_protected(context.app_id, context.title) end,
	})
	assert(Watch.start() and Watch.wait_ready(), "the resident AT-SPI focus watch must become ready")
	Guard.prime()
	local privacy = { guard = Guard, watch = Watch, detector = Detector }

	--- Waits until the focused field is joined to a fresh privacy context.
	--- @param admitted boolean True for an ordinary field, false for a password.
	--- @return boolean joined
	function privacy.join(admitted)
		local joined = M.settle(function()
			Guard.refresh(true)
			if admitted then return Guard.capture_text_owner() ~= nil end
			local snapshot = Watch.snapshot()
			return type(snapshot) == "table" and snapshot.role == PASSWORD_ROLE and Guard.blocks_text()
				and Guard.capture_text_owner() == nil
		end, 5)
		if not joined then
			local snapshot = Watch.snapshot()
			io.stderr:write(string.format("privacy join failed: verdict=%s role=%s blocks=%s\n",
				tostring(Detector.getVerdict()), tostring(type(snapshot) == "table" and snapshot.role),
				tostring(Guard.blocks_text())))
		end
		return joined
	end

	function privacy.stop()
		Guard.stop()
		Watch.stop()
		return M.settle(function() return Guard.stop() and Watch.is_settled() end, 5)
	end

	return privacy
end





-- =================================
-- =================================
-- ======= 3/ The XTest wire =======
-- =================================
-- =================================

--- Moves the production writer's last hop to XTest and opens the output.
--- @return table wire Records every key event written (wire.events).
function M.xtest_wire()
	local Backend = require("tests.hardware.lib.xtest_uinput_backend")
	local Writer = require("platform.input.uinput_writer")
	local wire = Backend.new()
	Writer._set_backend(wire)
	local node = os.getenv("HOME") .. "/uinput-xtest"
	local file = assert(io.open(node, "wb"))
	assert(file:close())
	Writer._set_path_for_test(node)
	assert(require("modules.hotstrings.injector").open_fast_channel(), "the output channel must open on the XTest wire")
	return wire
end

return M
