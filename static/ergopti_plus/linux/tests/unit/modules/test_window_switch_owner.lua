--- tests/unit/modules/test_window_switch_owner.lua

local helpers = require("tests.helpers")
local Policy = require("cursor_window_policy")
local Switch = require("adapters.window_switch")
local Display = require("infra.display_server")
local PACKET = [[pointer
X=1500
Y=200
SCREEN=0
WINDOW=101
monitors
Monitors: 2
 0: +*LEFT 1000/300x800/240+0+0 LEFT
 1: +RIGHT 1000/300x800/240+1000+0 RIGHT
active
101
desktop
0
stacking
0x65, 0x66, 0x67
window 0x65
WINDOW=101
X=100
Y=100
WIDTH=500
HEIGHT=400
SCREEN=0
DESKTOP=0
ELIGIBLE=1
end_window
window 0x66
WINDOW=102
X=1100
Y=100
WIDTH=500
HEIGHT=400
SCREEN=0
DESKTOP=0
ELIGIBLE=1
end_window
window 0x67
WINDOW=103
X=100
Y=100
WIDTH=500
HEIGHT=400
SCREEN=0
DESKTOP=0
ELIGIBLE=1
end_window
end_snapshot
]]
local INITIAL = "source\nROOT=100\n" .. PACKET:gsub("desktop\n", "focus\n501\n101\n301\n100\nend_focus\ndesktop\n", 1)
local FINAL = INITIAL:gsub("active\n101", "active\n102", 1):gsub("focus\n501\n101\n301\n100", "focus\n502\n102\n302\n100", 1)

local function fixture(options, body)
	options = options or {}
	local old = Display.kind()
	Display._set_for_test(Display.X11, "fixture")
	local f = { starts = {}, callbacks = {}, timers = {}, files = {}, closes = 0, fd_closes = 0, fail_remove = false }
	local next_fd, fds = 0, {}
	local constants = require("luv").constants
	local native = {
		exepath = function() return "/fixture/luajit" end,
		constants = constants,
		fs_mkdtemp = function() return "/owned/111" end,
		fs_open = function(path, flags)
			if flags == "wx" then f.files[path] = { bytes = "", ino = #fds + 1 } end
			if not f.files[path] then return nil end
			if flags == constants.O_RDONLY + constants.O_NONBLOCK and options.foreign_read and not f.foreign then
				f.foreign = true
				f.files[path] = { bytes = f.files[path].bytes, ino = 999, type = options.foreign_type }
			end
			f.open_flags = f.open_flags or {}; f.open_flags[#f.open_flags + 1] = flags
			next_fd = next_fd + 1; fds[next_fd] = path; return next_fd
		end,
		fs_fstat = function(fd)
			local file = f.files[fds[fd]]
			return { type = file.type or "file", dev = 1, ino = file.ino, mode = 384, size = #file.bytes }
		end,
		fs_lstat = function(path)
			if path == "/owned/111" then return { type = "directory", dev = 1, ino = 0 } end
			local file = f.files[path]
			return file and { type = file.type or "file", dev = 1, ino = file.ino, mode = 384, size = #file.bytes } or nil
		end,
		fs_read = function(fd) return f.files[fds[fd]].bytes end,
		fs_close = function()
			if f.close_refused == "throw" then error("controlled close throw") end
			if f.close_refused then return false end
			f.fd_closes = f.fd_closes + 1; return true
		end,
		fs_write = function(fd, bytes) f.files[fds[fd]].bytes = bytes; return #bytes end,
		fs_ftruncate = function(fd, size) f.files[fds[fd]].bytes = f.files[fds[fd]].bytes:sub(1, size); return true end,
		fs_unlink = function(path) if f.fail_remove then return false end; f.files[path] = nil; return true end,
		fs_rmdir = function() return true end,
		new_timer = function() return {} end,
		timer_start = function(timer, _, _, callback) f.timers[timer] = callback; return 0 end,
		timer_stop = function() return 0 end,
		close = function(timer, callback)
			f.closes = f.closes + 1
			if options.delay_close then f.close_callback = callback else callback() end
		end,
	}
	local runner = { spawn = function(_, arguments, completed, admitted)
		local h = { status = 0, settled = false, arguments = arguments }
		f.starts[#f.starts + 1] = h
		return {
			start = function()
				if not admitted() then return false end
				f.files[arguments[5]].bytes = arguments[4] == "snapshot" and (options.initial or INITIAL) or (options.final or FINAL)
				return true
			end,
			isSettled = function() return h.settled end,
			terminate = function() h.cancelled = true; return false end,
			onSettled = function(callback) h.retire = callback; return true end,
		}
	end }
	function f.resolve(index, status)
		local h = f.starts[index]; h.status, h.settled = status or 0, true
		if not h.cancelled then
			-- The completion port still belongs to this exact spawn.
			f.callbacks[index](h.status)
		end
		h.retire()
	end
	-- Capture the terminal port separately from native retirement.
	local spawn = runner.spawn
	runner.spawn = function(executable, arguments, completed, admitted)
		f.callbacks[#f.callbacks + 1] = completed
		return spawn(executable, arguments, completed, admitted)
	end
	local owner
	owner = Switch.new(function(binding)
		if options.capture then options.capture(owner, f) end
		return function() return f.allowed ~= false end
	end, { native = native, runner = runner, source = function() return f.source or ":111.0" end })
	local ok, err = pcall(body, owner, f)
	Display._set_for_test(old, "restored")
	if not ok then error(err, 0) end
end

helpers.describe("Cursor-window source and asynchronous ownership", function()
	helpers.it("replays the recovered independent cursor-display vector unchanged", function()
		local first = Policy.parse_snapshot(PACKET)
		helpers.assert_eq(Policy.candidate(first), 102)
		helpers.assert_eq(first.active, 101)
		helpers.assert_eq(first.monitor.x, 1000)
	end)
	helpers.it("accepts a genuine outputless logical monitor row", function()
		local first = Policy.parse_snapshot(PACKET:gsub("%+RIGHT 1000/300x800/240%+1000%+0 RIGHT", "+RIGHT 1000/300x800/240+1000+0"))
		helpers.assert_eq(Policy.candidate(first), 102)
	end)
	helpers.it("adopts focus only after exact native process and timer retirement", function()
		fixture({ delay_close = true }, function(owner, f)
			local result = nil
			helpers.assert_true(owner.run("binding", function(value) result = value end))
			helpers.assert_eq(#f.starts, 1)
			f.resolve(1)
			helpers.assert_eq(#f.starts, 1)
			helpers.assert_eq(result, nil)
			f.close_callback()
			helpers.assert_eq(#f.starts, 2)
			f.resolve(2)
			helpers.assert_eq(result, nil)
			f.close_callback()
			helpers.assert_eq(result, true)
			helpers.assert_eq(owner.has_pending(), false)
		end)
	end)
	helpers.it("requires exact active-window readback even after a zero exit", function()
		fixture({ final = INITIAL }, function(owner, f)
			local result
			helpers.assert_true(owner.run("binding", function(value) result = value end))
			f.resolve(1); f.resolve(2)
			helpers.assert_eq(result, false)
		end)
	end)
	for _, change in ipairs({
		{ name = "native root", packet = FINAL:gsub("ROOT=100", "ROOT=200", 1) },
		{ name = "pointer screen", packet = FINAL:gsub("SCREEN=0", "SCREEN=1", 1) },
		{ name = "monitor geometry", packet = FINAL:gsub("1000/300x800/240%+1000%+0", "1000/300x800/240+1001+0", 1) },
		{ name = "cursor display", packet = FINAL:gsub("X=1500", "X=200", 1) },
		{ name = "desktop", packet = FINAL:gsub("desktop\n0", "desktop\n1", 1) },
		{ name = "target eligibility", packet = FINAL:gsub("DESKTOP=0\nELIGIBLE=1\nend_window\nwindow 0x67", "DESKTOP=0\nELIGIBLE=0\nend_window\nwindow 0x67", 1) },
	}) do
		helpers.it("refuses changed " .. change.name .. " on final ACK", function()
			fixture({ final = change.packet }, function(owner, f)
				local result
				helpers.assert_true(owner.run("binding", function(value) result = value end))
				f.resolve(1); f.resolve(2)
				helpers.assert_eq(result, false)
			end)
		end)
	end
	helpers.it("retains false resource retirement rather than acknowledging idle", function()
		fixture({}, function(owner, f)
			local result
			helpers.assert_true(owner.run("binding", function(value) result = value end))
			f.resolve(1); f.fail_remove = true; f.resolve(2)
			helpers.assert_eq(result, nil)
			helpers.assert_true(owner.has_pending())
			f.fail_remove = false
			for _, tick in pairs(f.timers) do tick() end
			helpers.assert_eq(result, true)
			helpers.assert_eq(owner.has_pending(), false)
		end)
	end)
	helpers.it("cannot overwrite reentrant acquisition or acknowledge idle during capture", function()
		fixture({ capture = function(owner)
			helpers.assert_eq(owner.run("nested"), false)
			helpers.assert_eq(owner.stop(), false)
		end }, function(owner, f)
			helpers.assert_eq(owner.run("binding"), false)
			helpers.assert_eq(#f.starts, 0)
			helpers.assert_eq(owner.has_pending(), false)
		end)
	end)
	helpers.it("pause cannot settle a still-owned native group", function()
		fixture({}, function(owner, f)
			local result
			helpers.assert_true(owner.run("binding", function(value) result = value end))
			helpers.assert_eq(owner.stop(), false)
			helpers.assert_true(owner.has_pending())
			f.resolve(1)
			helpers.assert_eq(result, false)
			helpers.assert_eq(#f.starts, 1)
			helpers.assert_eq(owner.has_pending(), false)
		end)
	end)
	helpers.it("source revocation after snapshot cannot start the focus worker", function()
		fixture({}, function(owner, f)
			local result
			helpers.assert_true(owner.run("binding", function(value) result = value end))
			f.source = ":112.0"; f.resolve(1)
			helpers.assert_eq(result, false)
			helpers.assert_eq(#f.starts, 1)
		end)
	end)
	-- These malformed packet mutations are recovered independent vectors.
	for _, packet in ipairs({
		PACKET:sub(1, -2),
		PACKET:gsub("X=1500", "UNKNOWN=1\nX=1500", 1),
		PACKET:gsub("WIDTH=500", "UNKNOWN=1\nWIDTH=500", 1),
		PACKET:gsub("Monitors: 2", "Monitors: 999999999999999999999999", 1),
		PACKET:gsub("1000/300x800", "999999999999999999999999/300x800", 1),
		PACKET:gsub("0x65, 0x66, 0x67", "0x65, , 0x66, 0x67", 1),
		PACKET .. "unexpected\n",
		PACKET:gsub("WIDTH=500", "WIDTH=0", 1),
		PACKET:gsub("0x65, 0x66, 0x67", "0x65, 0x66, 0x66", 1),
		PACKET:gsub("1000/300x800/240%+1000%+0", "1000/300x800/240+0+0", 1),
	}) do
		helpers.it("refuses a recovered malformed packet without activation authority", function()
			helpers.assert_eq(Policy.parse_snapshot(packet), nil)
		end)
	end
	for _, change in ipairs({
		{ name = "cursor moved to active display", packet = PACKET:gsub("X=1500", "X=200", 1) },
		{ name = "cursor outside displays", packet = PACKET:gsub("X=1500", "X=2500", 1) },
		{ name = "active changed", packet = PACKET:gsub("active\n101", "active\n103", 1) },
		{ name = "target moved", packet = PACKET:gsub("X=1100", "X=100", 1) },
		{ name = "target minimized", packet = PACKET:gsub("DESKTOP=0\nELIGIBLE=1\nend_window\nwindow 0x67", "DESKTOP=0\nELIGIBLE=0\nend_window\nwindow 0x67", 1) },
		{ name = "desktop changed", packet = PACKET:gsub("desktop\n0", "desktop\n1", 1) },
	}) do
		helpers.it("preserves recovered revalidation refusal for " .. change.name, function()
			helpers.assert_eq(Policy.revalidated(Policy.parse_snapshot(INITIAL), Policy.parse_snapshot("source\nROOT=100\n" .. change.packet), 102), false)
		end)
	end
	helpers.it("preserves the recovered spanning centre rather than origin placement", function()
		helpers.assert_eq(Policy.candidate(Policy.parse_snapshot(PACKET:gsub("X=1100", "X=800", 1))), 102)
	end)

	helpers.it("closes the exact acquired read fd while preserving foreign pathname content", function()
		fixture({ foreign_read = true }, function(owner, f)
			helpers.assert_true(owner.run("binding"))
			f.resolve(1)
			helpers.assert_eq(f.fd_closes, 6, "five creation fds and the foreign-content read fd must retire")
			helpers.assert_true(owner.has_pending(), "foreign pathname debt must not be discarded")
			helpers.assert_eq(#f.starts, 1)
			helpers.assert_eq(f.files["/owned/111/initial"].ino, 999)
		end)
	end)
	for _, kind in ipairs({ "directory", "fifo" }) do
		helpers.it("closes an acquired foreign " .. kind .. " descriptor without blocking or deleting it", function()
			fixture({ foreign_read = true, foreign_type = kind }, function(owner, f)
				helpers.assert_true(owner.run("binding"))
				f.resolve(1)
				helpers.assert_eq(f.fd_closes, 6)
				helpers.assert_true(owner.has_pending())
				helpers.assert_eq(f.files["/owned/111/initial"].type, kind)
				local constants = require("luv").constants
				helpers.assert_eq(f.open_flags[6], constants.O_RDONLY + constants.O_NONBLOCK)
			end)
		end)
	end
	helpers.it("refuses EWMH-only focus without native input-focus ancestry", function()
		local forged = FINAL:gsub("focus\n502\n102\n302\n100", "focus\n501\n101\n301\n100", 1)
		fixture({ final = forged }, function(owner, f)
			local result
			helpers.assert_true(owner.run("binding", function(value) result = value end))
			f.resolve(1); f.resolve(2)
			helpers.assert_eq(result, false)
		end)
	end)
	helpers.it("admits a descendant input focus under the target native window", function()
		helpers.assert_true(Policy.acknowledged(Policy.parse_snapshot(INITIAL), Policy.parse_snapshot(FINAL), 102))
	end)

	helpers.it("passes original parent-acquired directory and five file identities to the fixed worker", function()
		fixture({}, function(owner, f)
			helpers.assert_true(owner.run("binding"))
			helpers.assert_eq(f.starts[1].arguments[12], "1:0,1:1,1:2,1:3,1:4,1:5")
			helpers.assert_eq(f.starts[1].arguments[13], "/owned/111")
			f.resolve(1)
			helpers.assert_eq(f.starts[2].arguments[12], "1:0,1:1,1:2,1:3,1:4,1:5")
			f.resolve(2)
		end)
	end)
	helpers.it("issues each native phase permit only after fresh source admission", function()
		fixture({}, function(owner, f)
			helpers.assert_true(owner.run("binding"))
			f.resolve(1)
			for _, phase in ipairs({ 1, 2 }) do
				f.files["/owned/111/request"].bytes = "READY " .. phase .. "\n"
				for _, tick in pairs(f.timers) do tick() end
				helpers.assert_eq(f.files["/owned/111/permit"].bytes, "PERMIT " .. phase .. "\n")
			end
			f.resolve(2)
			helpers.assert_eq(owner.has_pending(), false)
		end)
	end)
	helpers.it("withdraws phase permission after source revocation and retains physical debt", function()
		fixture({}, function(owner, f)
			helpers.assert_true(owner.run("binding"))
			f.resolve(1)
			f.files["/owned/111/request"].bytes = "READY 2\n"
			f.allowed = false
			for _, tick in pairs(f.timers) do tick() end
			helpers.assert_eq(f.files["/owned/111/permit"].bytes, "REVOKED\n")
			helpers.assert_true(owner.has_pending())
			f.resolve(2)
			helpers.assert_eq(owner.has_pending(), false)
		end)
	end)
	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("retains exact opened descriptor after native close " .. refusal, function()
			fixture({}, function(owner, f)
				helpers.assert_true(owner.run("binding"))
				f.resolve(1)
				f.files["/owned/111/request"].bytes = "READY 2\n"
				f.close_refused = refusal
				for _, tick in pairs(f.timers) do tick() end
				helpers.assert_true(owner.has_pending())
				f.resolve(2)
				helpers.assert_true(owner.has_pending())
				f.close_refused = nil
				for _, tick in pairs(f.timers) do tick() end
				helpers.assert_eq(owner.has_pending(), false)
			end)
		end)
	end

end)

helpers.describe("GNU timeout capability admission", function()
	local Runner = require("adapters.program_runner")
	local Shell = require("adapters.shell_runner")
	for _, receipt in ipairs({ "supported", "refused", "unknown", "numeric", "text", "throw" }) do
		helpers.it("requires exact GNU timeout capability receipt: " .. receipt, function()
			local previous = Display.kind()
			local supported, has_command, exec_checked = Runner.supported, Shell.has_command, Shell.exec_checked
			local probes = 0
			Display._set_for_test(Display.X11, "capability fixture")
			Runner.supported = function() return true end
			Shell.has_command = function() return true end
			Shell.exec_checked = function(command)
				probes = probes + 1
				helpers.assert_eq(command, "timeout --foreground 1 sh -c ':' 2>/dev/null")
				if receipt == "throw" then error("controlled capability refusal") end
				if receipt == "supported" then return true, "" end
				if receipt == "refused" then return false, "" end
				if receipt == "numeric" then return 0, "" end
				if receipt == "text" then return "true", "" end
				return nil
			end
			local checked, failure = pcall(function()
				local available, reason, tool = Switch.available()
				helpers.assert_eq(available, receipt == "supported")
				helpers.assert_eq(probes, 1)
				if receipt ~= "supported" then
					helpers.assert_eq(reason, "dialog.action_picker.requires_tool")
					helpers.assert_eq(tool, "GNU timeout")
				end
			end)
			Runner.supported, Shell.has_command, Shell.exec_checked = supported, has_command, exec_checked
			Display._set_for_test(previous, "restored")
			if not checked then error(failure, 0) end
		end)
	end
end)

helpers.describe("Unsigned X11 window identity transport", function()
	local HIGH = { root = "2147483748", first = "2147483749", target = "2147483750", third = "2147483751",
		hex = { first = "0x80000065", target = "0x80000066", third = "0x80000067" }, expected = 2147483750 }
	local MAXIMUM = { root = "4294967292", first = "4294967293", target = "4294967295", third = "4294967294",
		hex = { first = "0xfffffffd", target = "0xffffffff", third = "0xfffffffe" }, expected = 4294967295 }
	-- Fixed native spelling vectors: xprop emits hex while xdotool/xwininfo emit decimal.
	local function frame(ids, hex, final)
		local named = hex and ids.hex or ids
		local active = final and named.target or named.first
		local lines = { "source", "ROOT=" .. ids.root, "pointer", "X=1500", "Y=200", "SCREEN=0",
			"WINDOW=" .. ids.first, "monitors", "Monitors: 2",
			" 0: +*LEFT 1000/300x800/240+0+0 LEFT", " 1: +RIGHT 1000/300x800/240+1000+0 RIGHT",
			"active", active, "focus", active, ids.root, "end_focus", "desktop", "0", "stacking",
			ids.hex.first .. ", " .. ids.hex.target .. ", " .. ids.hex.third }
		for _, entry in ipairs({ { "first", "100" }, { "target", "1100" }, { "third", "100" } }) do
			local key, x = entry[1], entry[2]
			for _, line in ipairs({ "window " .. named[key], "WINDOW=" .. ids[key], "X=" .. x, "Y=100",
				"WIDTH=500", "HEIGHT=400", "SCREEN=0", "DESKTOP=0", "ELIGIBLE=1", "end_window" }) do
				lines[#lines + 1] = line
			end
		end
		lines[#lines + 1] = "end_snapshot"
		return table.concat(lines, "\n") .. "\n"
	end
	for _, hex in ipairs({ false, true }) do
		helpers.it("accepts high-bit XIDs with " .. (hex and "hex" or "decimal") .. " native identifiers", function()
			local snapshot = Policy.parse_snapshot(frame(HIGH, hex, false))
			helpers.assert_not_nil(snapshot)
			helpers.assert_eq(snapshot.root, 2147483748); helpers.assert_eq(snapshot.active, 2147483749)
			helpers.assert_eq(snapshot.focus_chain, { 2147483749, 2147483748 })
			helpers.assert_eq(snapshot.order, { 2147483749, 2147483750, 2147483751 })
			helpers.assert_eq(Policy.candidate(snapshot), 2147483750)
		end)
		helpers.it("revalidates high-bit identity across " .. (hex and "hex to decimal" or "decimal to hex"), function()
			local first = Policy.parse_snapshot(frame(HIGH, hex, false))
			local current = Policy.parse_snapshot(frame(HIGH, not hex, false))
			helpers.assert_not_nil(first); helpers.assert_not_nil(current)
			helpers.assert_true(Policy.revalidated(first, current, 2147483750))
			helpers.assert_eq(Policy.revalidated(first, current, 2147483751), false)
		end)
		helpers.it("acknowledges high-bit target across " .. (hex and "hex to decimal" or "decimal to hex"), function()
			local first = Policy.parse_snapshot(frame(HIGH, hex, false))
			local current = Policy.parse_snapshot(frame(HIGH, not hex, true))
			helpers.assert_not_nil(first); helpers.assert_not_nil(current)
			helpers.assert_true(Policy.acknowledged(first, current, 2147483750))
			helpers.assert_eq(Policy.acknowledged(first, current, 2147483751), false)
		end)
		helpers.it("accepts uint32 maximum through " .. (hex and "hex" or "decimal") .. " target readback", function()
			local first = Policy.parse_snapshot(frame(MAXIMUM, not hex, false))
			local current = Policy.parse_snapshot(frame(MAXIMUM, hex, true))
			helpers.assert_not_nil(first); helpers.assert_not_nil(current)
			helpers.assert_eq(Policy.candidate(first), 4294967295)
			helpers.assert_eq(current.active, 4294967295)
			helpers.assert_true(Policy.acknowledged(first, current, 4294967295))
		end)
	end
	for _, invalid in ipairs({
		{ "zero", "0" }, { "hex zero", "0x0" }, { "negative", "-1" },
		{ "decimal overflow", "4294967296" }, { "hex overflow", "0x100000000" },
		{ "fraction", "2147483749.0" }, { "exponent", "2.147483749e9" },
		{ "decimal suffix", "2147483749x" }, { "hex suffix", "0x80000065z" },
	}) do
		helpers.it("refuses unsigned identity " .. invalid[1], function()
			local packet = frame(HIGH, false, false):gsub("active\n2147483749\n", "active\n" .. invalid[2] .. "\n", 1)
			helpers.assert_nil(Policy.parse_snapshot(packet))
		end)
	end
	helpers.it("refuses mismatched high-bit geometry identity", function()
		local packet = frame(HIGH, true, false):gsub("WINDOW=2147483750", "WINDOW=2147483751", 1)
		helpers.assert_nil(Policy.parse_snapshot(packet))
	end)
	helpers.it("requires the acknowledged high-bit target in native focus ancestry", function()
		local first = Policy.parse_snapshot(frame(HIGH, false, false))
		local current = Policy.parse_snapshot(frame(HIGH, true, true):gsub("focus\n0x80000066", "focus\n0x80000065", 1))
		helpers.assert_not_nil(first); helpers.assert_not_nil(current)
		helpers.assert_eq(Policy.acknowledged(first, current, 2147483750), false)
	end)
	for _, bounds in ipairs({
		{ "minimum", "-2147483647", "-2147483000", "-2147483300" },
		{ "maximum", "2147482647", "2147483147", "2147482747" },
	}) do
		helpers.it("preserves signed coordinate " .. bounds[1] .. " with unsigned identities", function()
			local packet = frame(HIGH, false, false):gsub("X=1500", "X=" .. bounds[3], 1)
				:gsub("%+RIGHT 1000/300x800/240%+1000%+0 RIGHT",
					"+RIGHT 1000/300x800/240" .. (bounds[2]:sub(1, 1) == "-" and "" or "+") .. bounds[2] .. "+0 RIGHT", 1)
				:gsub("X=1100", "X=" .. bounds[4], 1)
			local snapshot = Policy.parse_snapshot(packet)
			helpers.assert_not_nil(snapshot); helpers.assert_eq(Policy.candidate(snapshot), 2147483750)
		end)
	end
	for _, invalid in ipairs({
		{ "coordinate upper overflow", "X=1500", "X=2147483648" },
		{ "coordinate lower overflow", "X=1500", "X=-2147483648" },
		{ "screen upper overflow", "SCREEN=0", "SCREEN=2147483648" },
		{ "negative screen", "SCREEN=0", "SCREEN=-1" },
	}) do
		helpers.it("retains signed field refusal: " .. invalid[1], function()
			local packet = frame(HIGH, false, false):gsub(invalid[2], invalid[3], 1)
			helpers.assert_nil(Policy.parse_snapshot(packet))
		end)
	end
end)
