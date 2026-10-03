--- tests/unit/adapters/test_screen_capture.lua

--- ==============================================================================
--- MODULE: Private Screen Capture Script (Linux)
--- DESCRIPTION:
--- Runs the capture script of adapters/screen_capture.lua under a PATH holding
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
local ScreenCapture = require("adapters.screen_capture")
local ShellRunner = require("adapters.shell_runner")

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
		return { cancel = function() return true end }
	end
	local ok, err = xpcall(function() body(state) end, debug.traceback)
	ShellRunner.exec_checked, ShellRunner.exec_line, ShellRunner.run_async = saved_checked, saved_line, saved_async
	if not ok then error(err, 0) end
end

helpers.describe("linux-screen-path-receipts", function()
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

-- The fake tools. Each logs its name and arguments; the behaviour is chosen
-- per scenario.
local BEHAVIOURS = {
	slurp_ok = 'printf "10,20 30x40"',
	slurp_cancel = 'echo "selection cancelled" >&2; exit 1',
	slurp_broken = 'echo "compositor does not support wlr-layer-shell" >&2; exit 1',
	write_last = 'for a; do last=$a; done; printf "png" > "$last"',
	exit_ok_no_file = 'exit 0',
	fail = 'exit 1',
	maim_cancel = 'echo "Selection was cancelled by keystroke or right-click." >&2; exit 1',
	magick_ok = 'exit 0',
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
	if image then image:close() end
	os.execute("rm -rf " .. ShellRunner.quote(root))
	local outcome = ScreenCapture.classify(mode, code, output, nil)
	outcome.calls = calls
	outcome.code = code
	outcome.wrote = image ~= nil
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
end)
