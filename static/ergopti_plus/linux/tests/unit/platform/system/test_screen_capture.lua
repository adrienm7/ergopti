--- tests/unit/platform/system/test_screen_capture.lua

--- ==============================================================================
--- MODULE: Private Screen Capture Script (Linux)
--- DESCRIPTION:
--- Runs the capture script of platform/system/screen_capture.lua under a PATH holding
--- only fake screenshot tools, and reads its outcome the way the adapter does:
--- which tool draws a region, that a cancelled region reads as cancelled and
--- opens no second tool, that the whole screen falls through the tools, and
--- that the image is downscaled when ImageMagick is there.
---
--- ROOT CAUSE ENCODED:
--- The screenshot actions run a cascade in the background and never learn its
--- outcome; the screen actions must tell a capture from a cancellation from a
--- failure, and a cascade of interactive tools would open a second region
--- picker after the user cancelled the first.
--- ==============================================================================

local helpers = require("tests.helpers")
local ScreenCapture = require("platform.system.screen_capture")
local ShellRunner = require("core.process.adapters.shell_runner")

local EDGE = 1568

--- Captures staging receipts at the actual ShellRunner adapter interface.
local function with_staging_receipt(receipt, body)
	local saved_checked, saved_line, saved_async = ShellRunner.exec_checked, ShellRunner.exec_line, ShellRunner.run_async
	local state = { spawns = 0 }
	ShellRunner.exec_checked = function() return receipt.ok, receipt.output, "native mktemp refusal" end
	ShellRunner.exec_line = function()
		local line = receipt.output:match("^([^\r\n]*)")
		return line ~= "" and line or nil
	end
	ShellRunner.run_async = function(executable, args, options, callback)
		state.spawns = state.spawns + 1
		state.executable, state.args, state.callback = executable, args, callback
		return { cancel = function() return true end, on_settled = function(fn) fn(); return true end }
	end
	local ok, err = xpcall(function() body(state) end, debug.traceback)
	ScreenCapture.shutdown()
	ShellRunner.exec_checked, ShellRunner.exec_line, ShellRunner.run_async = saved_checked, saved_line, saved_async
	if not ok then error(err, 0) end
end

helpers.describe("linux-screen-path-receipts", function()
	helpers.it("refuses a successful exit after native output reading failed", function()
		with_staging_receipt({ ok = true, output = "/owned/ergopti-screen.ABCDEFGH\n" }, function(state)
			local outcome
			assert(ScreenCapture.capture("full", EDGE, function(value) outcome = value end))
			state.callback({ ok = false, code = 0, stdout = "", error = "native output read failed" })
			helpers.assert_eq(outcome.status, "failed", "a later successful exit cannot erase the read failure")
		end)
	end)
	helpers.it("requires an acknowledged successful capture", function()
		with_staging_receipt({ ok = true, output = "/owned/ergopti-screen.ABCDEFGH\n" }, function(state)
			local outcome
			assert(ScreenCapture.capture("full", EDGE, function(value) outcome = value end))
			state.callback({ ok = false, code = 0, stdout = "" })
			helpers.assert_eq(outcome.status, "failed")
		end)
	end)
	for index, path in ipairs({
		"/owned/plain/ergopti-screen.ABCDEFGH", "/owned/line\npart/ergopti-screen.ABCDEFGH",
		"/owned/carriage\rpart/ergopti-screen.ABCDEFGH", "/owned/quote-é'漢\npart/ergopti-screen.ABCDEFGH",
		"/owned/tail\n/ergopti-screen.ABCDEFGH", "/owned/crlf\r\npart/ergopti-screen.ABCDEFGH",
	}) do
		helpers.it("linux-screen-path-receipts: preserves literal staging bytes " .. index, function()
			with_staging_receipt({ ok = true, output = path .. "\n" }, function(state)
				local handle, reason = ScreenCapture.capture("full", EDGE, function() end)
				helpers.assert_true(handle ~= nil, tostring(reason))
				helpers.assert_eq(handle.dir, path, "only mktemp's final protocol newline may be removed")
				helpers.assert_eq(handle.path, path .. "/screen.png")
				helpers.assert_eq(state.spawns, 1)
				helpers.assert_eq(state.executable, "sh")
				helpers.assert_eq(state.args[4], handle.path, "native argv and cleanup must name the same image")
			end)
		end)
	end
	for _, receipt in ipairs({
		{ name = "failed empty", ok = false, output = "" },
		{ name = "failed partial", ok = false, output = "/owned/partial\n" },
		{ name = "missing path", ok = true, output = "" },
		{ name = "empty line", ok = true, output = "\n" },
	}) do
		helpers.it("linux-screen-path-receipts: refuses " .. receipt.name .. " without dispatch", function()
			with_staging_receipt(receipt, function(state)
				local callbacks = 0
				local handle, reason = ScreenCapture.capture("full", EDGE, function() callbacks = callbacks + 1 end)
				helpers.assert_eq(handle, nil)
				helpers.assert_true(type(reason) == "string" and reason ~= "")
				helpers.assert_eq(state.spawns, 0, "failed staging cannot launch a capture outside its private directory")
				helpers.assert_eq(callbacks, 0)
			end)
		end)
	end
end)

helpers.it("screen capture removes its private directory when async startup raises", function()
	local uv = require("luv")
	local saved = ShellRunner.run_async
	local directory
	ShellRunner.run_async = function(_, args)
		directory = args[4]:match("^(.*)/screen%.png$")
		error("injected startup failure")
	end
	local ok, handle, reason = pcall(ScreenCapture.capture, "full", EDGE, function() end)
	ShellRunner.run_async = saved
	local remains = directory and uv.fs_lstat(directory)
	if directory then os.remove(directory) end
	helpers.assert_true(ok, "startup exceptions must be reported as a refusal")
	helpers.assert_eq(handle, nil)
	helpers.assert_true(type(reason) == "string")
	helpers.assert_eq(remains, nil, "private capture directory leaked")
end)

helpers.it("linux-screen-refused-cleanup: retain private image until the refused child exits", function()
	local uv = require("luv")
	local saved, directory, listener = ShellRunner.run_async
	ShellRunner.run_async = function(_, args)
		directory = args[4]:match("^(.*)/screen%.png$")
		local image = assert(io.open(args[4], "wb")); image:write("private screenshot"); image:close()
		local scaled = assert(io.open(args[4] .. ".scaled.png", "wb")); scaled:write("partial"); scaled:close()
		return nil, "pipe activation failed", { on_settled = function(fn) listener = fn; return true end }
	end
	local ok, err = pcall(function()
		local handle = ScreenCapture.capture("full", EDGE, function() error("refusal must not publish") end)
		helpers.assert_nil(handle)
		helpers.assert_true(uv.fs_lstat(directory .. "/screen.png") ~= nil)
		helpers.assert_true(type(listener) == "function", "native cleanup must remain observed")
		listener()
		helpers.assert_nil(uv.fs_lstat(directory), "private image and staging directory must be removed after exit")
	end)
	ShellRunner.run_async = saved
	if directory then os.remove(directory .. "/screen.png"); os.remove(directory) end
	assert(ok, err)
end)

helpers.it("linux-screen-refused-cleanup: retire an image after an already settled refusal", function()
	local uv = require("luv")
	local saved, directory = ShellRunner.run_async
	ShellRunner.run_async = function(_, args)
		directory = args[4]:match("^(.*)/screen%.png$")
		local image = assert(io.open(args[4], "wb")); image:write("private screenshot"); image:close()
		return nil, "pipe activation failed"
	end
	local ok, err = pcall(function()
		helpers.assert_nil(ScreenCapture.capture("full", EDGE, function() end))
		helpers.assert_nil(uv.fs_lstat(directory), "a settled refusal must remove its image and directory")
	end)
	ShellRunner.run_async = saved
	if directory then os.remove(directory .. "/screen.png"); os.remove(directory) end
	assert(ok, err)
end)

helpers.it("retires a real completed capture after its image has been consumed", function()
	local uv, original, handle, outcome = require("luv"), ScreenCapture.SCRIPT, nil, nil
	local ok, detail = xpcall(function()
		ScreenCapture.SCRIPT = 'printf private > "$1"'
		handle = assert(ScreenCapture.capture("full", EDGE, function(value) outcome = value end))
		local deadline = uv.hrtime() + 3000000000
		while not outcome do
			assert(uv.hrtime() < deadline, "controlled capture did not finish")
			uv.run("nowait"); uv.sleep(1)
		end
		helpers.assert_eq(outcome.status, "ok")
		local file = assert(io.open(handle.path, "rb")); helpers.assert_eq(file:read("*a"), "private"); file:close()
		helpers.assert_true(ScreenCapture.cleanup_pending())
		helpers.assert_true(handle.discard())
		helpers.assert_nil(uv.fs_lstat(handle.dir))
		helpers.assert_eq(ScreenCapture.cleanup_pending(), false)
	end, debug.traceback)
	ScreenCapture.SCRIPT = original
	if handle and uv.fs_lstat(handle.dir) then
		pcall(handle.cancel); pcall(handle.discard)
		for _ = 1, 100 do uv.run("nowait"); uv.sleep(1) end
	end
	if not ok then error(detail, 0) end
end)

helpers.it("retires both staged images only after a real cancelled child settles", function()
	local uv, original, handle = require("luv"), ScreenCapture.SCRIPT, nil
	local finished, settled = false, false
	local ok, detail = xpcall(function()
		ScreenCapture.SCRIPT = 'printf private > "$1"; printf partial > "$1.scaled.png"; exec sleep 30'
		handle = assert(ScreenCapture.capture("full", EDGE, function() finished = true end))
		local deadline = uv.hrtime() + 3000000000
		while not uv.fs_lstat(handle.path .. ".scaled.png") do
			assert(uv.hrtime() < deadline, "controlled child did not reach its write")
			uv.run("nowait"); uv.sleep(1)
		end
		helpers.assert_true(ScreenCapture.cleanup_pending(), "active captures retain cleanup ownership")
		local loop_stopped = false
		local shutdown = require("core.lifecycle.engine.shutdown.coordinator").new({
			pre_wait = { { name = "screen capture cleanup", wait_for_ack = true,
				stop = function() return ScreenCapture.shutdown() end } },
			keyboard_hook = { isRunning = function() return false end, stop = function() end,
				emergency_stop = function() end },
			event_loop = { stop = function() loop_stopped = true end },
		})
		shutdown.request("quit")
		helpers.assert_true(shutdown.is_pending() and not loop_stopped, "the loop must stay alive for child retirement")
		helpers.assert_true(uv.fs_lstat(handle.path) ~= nil, "cleanup waits for native child retirement")
		helpers.assert_true(uv.fs_lstat(handle.path .. ".scaled.png") ~= nil)
		while uv.fs_lstat(handle.dir) do
			assert(uv.hrtime() < deadline, "cancelled child cleanup did not settle")
			uv.run("nowait"); uv.sleep(1)
		end
		settled = true
		helpers.assert_eq(ScreenCapture.cleanup_pending(), false)
		helpers.assert_true(shutdown.poll() and loop_stopped, "shutdown follows exact staging cleanup")
		helpers.assert_eq(finished, false, "cancelled capture cannot publish a result")
	end, debug.traceback)
	ScreenCapture.SCRIPT = original
	if handle and not settled then
		pcall(handle.cancel); pcall(handle.discard)
		for _ = 1, 100 do uv.run("nowait"); uv.sleep(1) end
	end
	if not ok then error(detail, 0) end
end)

-- The fake tools. Each logs its name and arguments; the behaviour is chosen
-- per scenario.
local BEHAVIOURS = {
	slurp_ok = 'printf "10,20 30x40"',
	slurp_ok_with_warning = 'echo "compositor warning" >&2; printf "10,20 30x40"',
	slurp_cancel = 'echo "selection cancelled" >&2; exit 1',
	slurp_broken = 'echo "compositor does not support wlr-layer-shell" >&2; exit 1',
	write_last = 'for a; do last=$a; done; printf "png" > "$last"',
	exit_ok_no_file = 'exit 0',
	fail = 'exit 1',
	maim_cancel = 'echo "Selection was cancelled by keystroke or right-click." >&2; exit 1',
	magick_ok = 'for a; do last=$a; done; printf "scaled" > "$last"',
	magick_partial = 'for a; do last=$a; done; printf "truncated" > "$last"; exit 1',
}

--- Runs the capture script with the given fake tools.
--- @param mode string "region" or "full".
--- @param tools table { [tool] = behaviour key }.
--- @param wayland boolean Whether WAYLAND_DISPLAY is set.
--- @return table outcome classify() result, plus calls (tool lines) and the image path.
local function run(mode, tools, wayland)
	local pipe = io.popen("mktemp -d")
	local root = pipe:read("*l")
	pipe:close()
	local bin, log, out = root .. "/bin", root .. "/calls.log", root .. "/screen.png"
	os.execute("mkdir " .. ShellRunner.quote(bin))
	os.execute("ln -s /bin/rm " .. ShellRunner.quote(bin .. "/rm"))
	os.execute("ln -s /bin/mv " .. ShellRunner.quote(bin .. "/mv"))
	for tool, behaviour in pairs(tools) do
		local path = bin .. "/" .. tool
		local handle = assert(io.open(path, "w"))
		handle:write("#!/bin/sh\nprintf '%s %s\\n' \"${0##*/}\" \"$*\" >> \"$LOGF\"\n",
			assert(BEHAVIOURS[behaviour], behaviour), "\n")
		handle:close()
		os.execute("chmod +x " .. ShellRunner.quote(path))
	end
	local outer = 'PATH="$1" LOGF="$2" WAYLAND_DISPLAY="$3" /bin/sh -c "$4" sh "$5" "$6" "$7"; echo "exit:$?"'
	local command = "sh -c " .. ShellRunner.quote(outer) .. " sh " .. table.concat({
		ShellRunner.quote(bin), ShellRunner.quote(log), ShellRunner.quote(wayland and "wayland-0" or ""),
		ShellRunner.quote(ScreenCapture.SCRIPT), ShellRunner.quote(out), tostring(EDGE), mode,
	}, " ")
	local output_pipe = io.popen(command)
	local output = output_pipe:read("*a")
	output_pipe:close()
	local code = tonumber(output:match("exit:(%d+)"))
	local calls = {}
	local handle = io.open(log, "r")
	if handle then
		for line in handle:lines() do calls[#calls + 1] = line end
		handle:close()
	end
	local image = io.open(out, "rb")
	local bytes = image and image:read("*a")
	if image then image:close() end
	os.execute("rm -rf " .. ShellRunner.quote(root))
	local outcome = ScreenCapture.classify(mode, code, output, nil)
	outcome.calls = calls
	outcome.code = code
	outcome.wrote = image ~= nil
	outcome.image = bytes
	return outcome
end

--- The tool names that ran, in order.
--- @param outcome table
--- @return string
local function tools_run(outcome)
	local names = {}
	for index, line in ipairs(outcome.calls) do names[index] = line:match("^(%S+)") end
	return table.concat(names, ",")
end

helpers.describe("screen capture: a region is drawn with one tool", function()
	helpers.it("linux-screen-slurp-warning: keeps stderr out of successful geometry", function()
		local outcome = run("region", { slurp = "slurp_ok_with_warning", grim = "write_last" }, true)
		helpers.assert_eq(outcome.status, "ok")
		helpers.assert_true(outcome.calls[2]:find("-g 10,20 30x40", 1, true) ~= nil, outcome.calls[2])
	end)

	helpers.it("uses slurp and grim under Wayland, with the drawn geometry", function()
		local outcome = run("region", { slurp = "slurp_ok", grim = "write_last", ["gnome-screenshot"] = "write_last" }, true)
		helpers.assert_eq(outcome.status, "ok")
		helpers.assert_eq(tools_run(outcome), "slurp,grim")
		helpers.assert_true(outcome.calls[2]:find("-g 10,20 30x40", 1, true) ~= nil, outcome.calls[2])
		helpers.assert_eq(outcome.scaled, false, "no ImageMagick: sent unscaled")
	end)

	helpers.it("a cancelled slurp is a cancellation, and no other tool opens", function()
		local outcome = run("region", { slurp = "slurp_cancel", grim = "write_last", ["gnome-screenshot"] = "write_last" }, true)
		helpers.assert_eq(outcome.status, "cancelled")
		helpers.assert_eq(tools_run(outcome), "slurp")
	end)

	helpers.it("a slurp the compositor refuses falls through to the next tool", function()
		local outcome = run("region", { slurp = "slurp_broken", grim = "write_last", ["gnome-screenshot"] = "write_last" }, true)
		helpers.assert_eq(outcome.status, "ok")
		helpers.assert_eq(tools_run(outcome), "slurp,gnome-screenshot")
		helpers.assert_true(outcome.calls[2]:find("-a -f", 1, true) ~= nil, outcome.calls[2])
	end)

	helpers.it("gnome-screenshot closed without a region is a cancellation", function()
		local outcome = run("region", { ["gnome-screenshot"] = "exit_ok_no_file", spectacle = "write_last" }, false)
		helpers.assert_eq(outcome.status, "cancelled")
		helpers.assert_eq(tools_run(outcome), "gnome-screenshot", "spectacle never opens after it")
	end)

	helpers.it("a failing region tool does not open the next one either", function()
		local outcome = run("region", { ["gnome-screenshot"] = "fail", spectacle = "write_last" }, false)
		helpers.assert_eq(outcome.status, "failed")
		helpers.assert_eq(tools_run(outcome), "gnome-screenshot")
	end)

	helpers.it("maim's cancellation reads as cancelled", function()
		local outcome = run("region", { maim = "maim_cancel" }, false)
		helpers.assert_eq(outcome.status, "cancelled")
	end)

	helpers.it("no tool at all is a failure the user is told about", function()
		local outcome = run("region", {}, false)
		helpers.assert_eq(outcome.status, "failed")
		helpers.assert_eq(outcome.code, ScreenCapture.EXIT_NO_TOOL)
	end)
end)

helpers.describe("screen capture: the whole screen falls through the tools", function()

	helpers.it("takes the pointer's monitor with spectacle when grim fails, and downscales", function()
		local outcome = run("full", { grim = "fail", spectacle = "write_last", magick = "magick_ok" }, false)
		helpers.assert_eq(outcome.status, "ok")
		helpers.assert_eq(tools_run(outcome), "grim,spectacle,magick")
		helpers.assert_true(outcome.calls[2]:find("-m", 1, true) ~= nil, "spectacle --current: " .. outcome.calls[2])
		helpers.assert_true(outcome.calls[3]:find("-resize " .. EDGE .. "x" .. EDGE .. ">", 1, true) ~= nil,
			outcome.calls[3])
		helpers.assert_eq(outcome.scaled, true)
	end)

	helpers.it("keeps the original screenshot when resizing writes partial output and fails", function()
		local outcome = run("full", { grim = "write_last", magick = "magick_partial" }, false)
		helpers.assert_eq(outcome.status, "ok")
		helpers.assert_eq(outcome.scaled, false)
		helpers.assert_eq(outcome.image, "png", "a failed resize must not replace the original bytes")
	end)

	helpers.it("a tool that writes nothing is a failure, not a cancellation", function()
		local outcome = run("full", { grim = "exit_ok_no_file" }, false)
		helpers.assert_eq(outcome.status, "failed")
	end)

	helpers.it("tools that all fail are a failure", function()
		local outcome = run("full", { grim = "fail", maim = "fail" }, false)
		helpers.assert_eq(outcome.status, "failed")
		helpers.assert_eq(tools_run(outcome), "grim,maim")
	end)

	helpers.it("a timed-out capture is a failure", function()
		helpers.assert_eq(ScreenCapture.classify("region", nil, nil, "timeout").status, "failed")
	end)

	helpers.it("a failure names a closed reason id and keeps the detail apart", function()
		local Errors = require("diagnostics.engine.adapter_errors")
		helpers.assert_eq(ScreenCapture.classify("full", ScreenCapture.EXIT_NO_TOOL, nil, nil).reason,
			Errors.SCREEN_CAPTURE_NO_TOOL)
		helpers.assert_eq(ScreenCapture.classify("full", ScreenCapture.EXIT_NO_FILE, nil, nil).reason,
			Errors.SCREEN_CAPTURE_NO_IMAGE)
		local timed_out = ScreenCapture.classify("region", nil, nil, "timeout")
		helpers.assert_eq(timed_out.reason, Errors.SCREEN_CAPTURE_DID_NOT_FINISH)
		helpers.assert_eq(timed_out.detail, "timeout")
		local failed = ScreenCapture.classify("full", 7, nil, nil)
		helpers.assert_eq(failed.reason, Errors.SCREEN_CAPTURE_TOOL_FAILED)
		helpers.assert_eq(failed.detail, 7)
	end)
end)

helpers.it("independent: retry staging cleanup after real directory permissions recover", function()
	local uv = require("luv")
	local original_script, original_remove = ScreenCapture.SCRIPT, os.remove
	local handle, attempts = nil, 0
	local ok, detail = xpcall(function()
		ScreenCapture.SCRIPT = 'printf private > "$1"; exec sleep 30'
		handle = assert(ScreenCapture.capture("full", EDGE, function() end))
		local deadline = uv.hrtime() + 5e9
		while not uv.fs_lstat(handle.path) do assert(uv.hrtime() < deadline); uv.run("nowait"); uv.sleep(1) end
		assert(uv.fs_chmod(handle.dir, 0))
		assert(not uv.fs_open(handle.path, "r", 0), "the test identity must actually lack directory access")
		os.remove = function(path) if path == handle.path then attempts = attempts + 1 end; return original_remove(path) end
		assert(handle.discard()); handle.cancel()
		while attempts == 0 do assert(uv.hrtime() < deadline, "child must physically settle"); uv.run("nowait"); uv.sleep(1) end
		assert(uv.fs_chmod(handle.dir, 448))
		os.remove = original_remove
		helpers.assert_true(ScreenCapture.shutdown(), "retired files must be retried after permissions recover")
		helpers.assert_nil(uv.fs_lstat(handle.dir))
	end, debug.traceback)
	os.remove = original_remove; ScreenCapture.SCRIPT = original_script
	if handle then uv.fs_chmod(handle.dir, 448); original_remove(handle.path); original_remove(handle.path .. ".scaled.png"); original_remove(handle.dir) end
	if not ok then error(detail, 0) end
end)
helpers.it("independent: retry refused settlement observation after failed capture admission", function()
 local uv=require("luv"); local original=ShellRunner.run_async; local calls,listener,dir=0,nil,nil
 ShellRunner.run_async=function(_,args)
  dir=args[4]:match("^(.*)/screen%.png$");local f=assert(io.open(args[4],"w"));f:write("private");f:close()
  return nil,"post-spawn refusal",{on_settled=function(fn) calls=calls+1;if calls==1 then return false end;listener=fn;return true end}
 end
 local ok,detail=xpcall(function()
  helpers.assert_nil(ScreenCapture.capture("full",EDGE,function() end));helpers.assert_eq(calls,1)
  helpers.assert_eq(ScreenCapture.shutdown(),false);helpers.assert_eq(calls,2,"retained child observer must be retried")
  assert(listener);helpers.assert_eq(ScreenCapture.shutdown(),false);helpers.assert_eq(calls,2,"accepted observer must not be registered twice");listener();helpers.assert_true(ScreenCapture.shutdown());helpers.assert_nil(uv.fs_lstat(dir))
 end,debug.traceback)
 ShellRunner.run_async=original;if dir then os.remove(dir.."/screen.png");os.remove(dir) end
 if not ok then error(detail,0) end
end)
