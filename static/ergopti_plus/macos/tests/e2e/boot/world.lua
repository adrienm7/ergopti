--- tests/e2e/boot/world.lua

--- ==============================================================================
--- MODULE: Headless macOS World For The Boot Scenarios
--- DESCRIPTION:
--- Completes the shared hs stub (tests/stubs/hs.lua) into a Mac the REAL
--- init.lua can boot on: a launcher that exported its environment and is alive,
--- a native logger worker that acknowledges every record, a virtual clock that
--- fires timers in order, windows and tasks that answer like their native
--- counterparts, a set-up Karabiner-Elements with a ready remap guardian, and a
--- file-system guard over the installed application. Everything between those
--- edges is production code.
---
--- FEATURES & RATIONALE:
--- 1. Recorded, never hidden: every user-visible dialog, every write under the
---    application bundle and every read of a file the bundle does not ship is
---    printed as an E2E_ line for the parent to judge
---    (hardening-a-startup-zero-error, hardening-b-installed-layout).
--- 2. Native contracts, not permissive stubs: start() returns the object, a
---    webview's JavaScript callback gets the native `{code = 0}` sentinel, and a
---    task completes on a later timer turn with an exit status, as hs.task does.
--- 3. One clock: hs.timer, secondsSinceEpoch and absoluteTime share a virtual
---    time that only run() advances, so a boot is deterministic and fast.
--- 4. One machine: system folders (/Applications, /Library) resolve inside the
---    scenario's own root, so the Mac the boot sees is the same on every host.
--- 5. Either processor: the scenario names the architecture `uname -m`
---    answers, because the platform default AI backend follows it.
--- 6. Named machines (M.MACHINES): the selected keyboard layout under both of
---    its names, how long the Karabiner lease worker takes to answer, and what
---    happens while the boot's first RESUME is in flight (layout-name-forms,
---    lease-stop-supersedes-activation).
--- 7. Every process has a processor: each started task is recorded with the
---    architectures its executable carries, as the Mach-O header of the
---    modelled file declares them (hardening-h-no-rosetta). On Apple silicon a
---    task whose executable has no arm64 slice runs under Rosetta, and macOS
---    tells the user an Intel app is starting: recorded as E2E_ROSETTA.
--- ==============================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Recording helpers =======
-- ====================================
-- ====================================

local _emit = print

--- Prints one observation line for the parent process.
--- @param kind string Observation kind (DIALOG, BUNDLE_WRITE, …).
--- @param detail any Detail text; newlines are flattened.
local function record(kind, detail)
	_emit("E2E_" .. kind .. " " .. (tostring(detail):gsub("[\r\n]+", " | ")))
end
M.record = record

--- Returns a native-handle double: every unknown method returns the handle
--- itself, the way Hammerspoon's chainable setters do.
--- @param fields table|nil Methods or values that must answer otherwise.
--- @return table handle
local function handle(fields)
	return setmetatable(fields or {}, { __index = function(t, key)
		local method = function(self) return self end
		rawset(t, key, method)
		return method
	end })
end
M.handle = handle

--- Quotes one path for /bin/sh.
--- @param value string
--- @return string
local function sh_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
M.sh_quote = sh_quote

--- Runs one POSIX command, true on a zero exit.
--- @param command string
--- @return boolean
local function sh(command)
	local result = os.execute(command)
	return result == true or result == 0
end
M.sh = sh

--- Writes one file, creating its folder.
--- @param path string
--- @param content string
function M.write_file(path, content)
	assert(sh("mkdir -p " .. sh_quote(path:match("^(.*)/[^/]+$"))), "cannot create the folder of " .. path)
	local fh = assert(io.open(path, "wb"))
	fh:write(content)
	fh:close()
end





-- ===================================
-- ===================================
-- ======= 2/ Virtual clock ==========
-- ===================================
-- ===================================

--- Installs hs.timer over one virtual clock.
--- @param hs table The hs stub.
local function install_timers(hs)
	-- Starts at the real time, so two boots of one scenario never share a
	-- timestamp-derived name (backups are named after absoluteTime).
	local epoch = os.time()
	local clock_ns = epoch * 1000000000
	local timers = {}
	local sequence = 0
	local function new_timer(interval, fn, repeats)
		sequence = sequence + 1
		local timer = { interval = interval or 0, fn = fn, repeats = repeats, active = false, seq = sequence }
		function timer:start(delay)
			if delay ~= nil then self.interval = delay end
			self.active = true
			self.due = clock_ns + math.floor((self.interval or 0) * 1e9)
			return self
		end
		function timer:stop() self.active = false; return self end
		function timer:running() return self.active end
		timer.isRunning = timer.running
		function timer:nextTrigger() return self.active and (self.due - clock_ns) / 1e9 or nil end
		function timer:setNextTrigger(seconds)
			self.active = true
			self.due = clock_ns + math.floor(seconds * 1e9)
			return self
		end
		function timer:setDelay(delay) self.interval = delay; return self end
		function timer:fire() if self.fn then self.fn(self) end return self end
		timers[#timers + 1] = timer
		return timer
	end
	hs.timer.new = function(interval, fn) return new_timer(interval, fn, true) end
	hs.timer.doAfter = function(delay, fn) return new_timer(delay, fn, false):start() end
	hs.timer.doEvery = function(interval, fn) return new_timer(interval, fn, true):start() end
	hs.timer.delayed = { new = function(delay, fn) return new_timer(delay, fn, false) end }
	hs.timer.secondsSinceEpoch = function() return clock_ns / 1e9 end
	hs.timer.absoluteTime = function() return clock_ns end
	hs.timer.usleep = function(microseconds) clock_ns = clock_ns + math.floor(microseconds * 1000) end

	--- Fires every due timer in order until `horizon_sec` of virtual time passed.
	--- @param horizon_sec number Virtual seconds to run.
	--- @param max_fires number Safety bound on callbacks.
	--- @param after_each function|nil Called after every callback.
	--- @return integer fired
	function M.run(horizon_sec, max_fires, after_each)
		local stop_at = clock_ns + math.floor(horizon_sec * 1e9)
		local fired = 0
		while fired < max_fires do
			local best = nil
			for _, timer in ipairs(timers) do
				if timer.active and timer.due <= stop_at and (best == nil or timer.due < best.due
					or (timer.due == best.due and timer.seq < best.seq)) then
					best = timer
				end
			end
			if not best then break end
			if best.due > clock_ns then clock_ns = best.due end
			if best.repeats then
				best.due = clock_ns + math.max(1, math.floor((best.interval or 0) * 1e9))
			else
				best.active = false
			end
			fired = fired + 1
			local ok, err = xpcall(function() best.fn(best) end, debug.traceback)
			if not ok then record("TIMER_RAISED", err) end
			if after_each then after_each() end
		end
		if clock_ns < stop_at then clock_ns = stop_at end
		return fired
	end
end





-- ==================================================
-- ==================================================
-- ======= 3/ The machine: files and commands =======
-- ==================================================
-- ==================================================

-- System folders the boot probes. They resolve inside the scenario's root so a
-- CI runner's own /Applications cannot change what the boot sees; /var/db holds
-- the xcode-select link that names the active developer tools.
local SYSTEM_PREFIXES = { "/Applications/", "/Library/", "/usr/local/", "/opt/homebrew/", "/var/db/" }

--- Maps a system path into the scenario's machine root.
--- @param machine_root string
--- @param path any
--- @return any
local function redirect(machine_root, path)
	if type(path) ~= "string" then return path end
	for _, prefix in ipairs(SYSTEM_PREFIXES) do
		if path:sub(1, #prefix) == prefix or path .. "/" == prefix then return machine_root .. path end
	end
	return path
end

--- Populates a Mac on which Karabiner-Elements is installed and running and
--- its DriverKit extension is activated: the state every Tap-Hold user is in.
--- @param machine_root string
--- @param home string
function M.install_karabiner(machine_root, home)
	local support = machine_root .. "/Library/Application Support/org.pqrs/Karabiner-Elements"
	M.write_file(machine_root .. "/Applications/Karabiner-Elements.app/Contents/Info.plist", "<plist/>\n")
	M.write_file(support .. "/bin/karabiner_cli", "#!/bin/sh\n")
	M.write_file(support .. "/Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service", "#!/bin/sh\n")
	M.write_file(home .. "/.config/karabiner/karabiner.json", [[{
    "profiles": [
        {
            "name": "Default profile",
            "selected": true,
            "virtual_hid_keyboard": { "keyboard_type_v2": "ansi" }
        }
    ]
}
]])
end

-- Mach-O CPU types (<mach/machine.h>) of the processors a Mac runs.
local CPU_TYPES = { x86_64 = 0x01000007, arm64 = 0x0100000C }
local CPU_NAMES = { [0x01000007] = "x86_64", [0x0100000C] = "arm64" }

-- Executables of the sealed system volume: Apple ships every one with both
-- slices, so they never need Rosetta.
local SYSTEM_EXECUTABLE_PREFIXES = { "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/", "/System/" }

-- The xcode-select shims of /usr/bin: the code they run is the same tool of
-- the active developer folder, whatever processor that copy was built for.
local DEVELOPER_SHIMS = { ["/usr/bin/python3"] = "usr/bin/python3" }

-- Where the shims look when neither DEVELOPER_DIR nor the xcode-select link
-- names a developer folder, in the order libxcselect tries them.
local DEFAULT_DEVELOPER_DIRS = { "/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools" }

--- Encodes one unsigned 32-bit integer.
--- @param value integer
--- @param big_endian boolean
--- @return string bytes
local function u32(value, big_endian)
	local bytes = {}
	for index = 1, 4 do
		bytes[index] = math.floor(value / 256 ^ (index - 1)) % 256
	end
	if big_endian then bytes = { bytes[4], bytes[3], bytes[2], bytes[1] } end
	return string.char(bytes[1], bytes[2], bytes[3], bytes[4])
end

--- Writes the Mach-O header of an executable built for the given processors:
--- a thin 64-bit header for one, a universal (fat) header for several.
--- @param path string File to write (already mapped into the machine root).
--- @param archs table Architecture names, e.g. { "x86_64" } or { "x86_64", "arm64" }.
function M.write_macho(path, archs)
	local content
	if #archs == 1 then
		content = u32(0xFEEDFACF, false) .. u32(assert(CPU_TYPES[archs[1]], archs[1]), false)
			.. u32(0, false) .. u32(2, false) .. string.rep("\0", 16)
	else
		local parts = { u32(0xCAFEBABE, true), u32(#archs, true) }
		for index, arch in ipairs(archs) do
			parts[#parts + 1] = u32(assert(CPU_TYPES[arch], arch), true) .. u32(0, true)
				.. u32(4096 * index, true) .. u32(4096, true) .. u32(12, true)
		end
		content = table.concat(parts)
	end
	M.write_file(path, content)
	assert(sh("chmod 755 " .. sh_quote(path)), "cannot make " .. path .. " executable")
end

--- Reads the processors a modelled executable file declares.
--- @param file_path string Path already mapped into the machine root.
--- @return table|nil archs, string|nil reason ("missing", "script:<interpreter>", "unknown")
local function file_archs(file_path)
	local fh = io.open(file_path, "rb")
	if not fh then return nil, "missing" end
	local head = fh:read(4096) or ""
	fh:close()
	if head:sub(1, 2) == "#!" then
		return nil, "script:" .. (head:match("^#!%s*(%S+)") or "")
	end
	local function be(offset)
		local a, b, c, d = head:byte(offset, offset + 3)
		return ((a * 256 + b) * 256 + c) * 256 + d
	end
	local function le(offset)
		local a, b, c, d = head:byte(offset, offset + 3)
		return ((d * 256 + c) * 256 + b) * 256 + a
	end
	if #head < 8 then return nil, "unknown" end
	if be(1) == 0xCAFEBABE then
		local archs = {}
		for index = 1, be(5) do
			archs[#archs + 1] = CPU_NAMES[be(9 + (index - 1) * 20)] or "other"
		end
		return archs
	end
	if le(1) == 0xFEEDFACF then return { CPU_NAMES[le(5)] or "other" } end
	return nil, "unknown"
end

--- The processors an executable the boot starts declares on this machine.
--- @param machine_root string
--- @param path string Executable as production names it.
--- @param depth integer|nil Script interpreters followed so far.
--- @return table|nil archs, string detail Where the answer came from.
function M.declared_archs(machine_root, path, depth)
	local shim_tool = DEVELOPER_SHIMS[path]
	if shim_tool then
		local developer = os.getenv("DEVELOPER_DIR")
		if type(developer) ~= "string" or developer == "" then
			local reader = io.popen("readlink " .. sh_quote(redirect(machine_root, "/var/db/xcode_select_link"))
				.. " 2>/dev/null")
			local target = reader and reader:read("*l") or nil
			if reader then reader:close() end
			developer = (type(target) == "string" and target ~= "") and target or nil
		end
		if developer == nil then
			for _, candidate in ipairs(DEFAULT_DEVELOPER_DIRS) do
				if developer == nil and file_archs(redirect(machine_root, candidate .. "/" .. shim_tool)) then
					developer = candidate
				end
			end
		end
		if developer == nil then return nil, "no developer tools behind " .. path end
		local tool = developer .. "/" .. shim_tool
		return (file_archs(redirect(machine_root, tool))), tool
	end
	for _, prefix in ipairs(SYSTEM_EXECUTABLE_PREFIXES) do
		if path:sub(1, #prefix) == prefix then return { "x86_64", "arm64" }, "system volume" end
	end
	local archs, reason = file_archs(redirect(machine_root, path))
	local interpreter = type(reason) == "string" and reason:match("^script:(.+)$")
	if interpreter and (depth or 0) < 2 then
		return M.declared_archs(machine_root, interpreter, (depth or 0) + 1)
	end
	return archs, reason or path
end

--- Gives the machine the developer tools a current macOS installs: the
--- Command Line Tools with a universal python3, unless the scenario already
--- modelled another copy.
--- @param machine_root string
function M.install_developer_tools(machine_root)
	local python = machine_root .. "/Library/Developer/CommandLineTools/usr/bin/python3"
	local fh = io.open(python, "rb")
	if fh then fh:close(); return end
	M.write_macho(python, { "x86_64", "arm64" })
end

-- The answers of the commands a set-up Mac runs for the boot, by executable.
local HELPER_ROLE_ANSWERS = {
	["--login-startup"] = "disabled\n",
	["--register-remap-guardian"] = "ready\n",
	["--remap-guardian-status"] = "ready\n",
	["--open-remap-guardian-settings"] = "not_required\n",
}

-- Keyboard layouts a machine can select, under the two names macOS gives one
-- layout: hs.keycodes reports its localised name, `defaults read
-- com.apple.HIToolbox AppleSelectedInputSources` its KeyboardLayout Name. They
-- differ for an Ergopti layout (modules/keymap/input_sources.lua).
local LAYOUTS = {
	abc = { localised = "ABC", hitoolbox = "ABC", id = 252, source_id = "com.apple.keylayout.ABC" },
	french = { localised = "French", hitoolbox = "French", id = 1, source_id = "com.apple.keylayout.French" },
	ergopti = { localised = "Ergopti+", hitoolbox = "Ergopti_v2_2_2_plus", id = -27340,
		source_id = "org.sil.ukelele.keyboardlayout.ergopti.ergopti_v2_2_2_plus" },
}

--- Independent, bounded NONE-state observations of the modelled OS sources.
-- These physical keys matter to source selection/dead-key regressions; unknown
-- machine keys emit no text. The native Swift lane qualifies real TIS/UC output.
-- Ergopti entries resolve the shipped .keylayout's NONE actions, not action IDs
-- or the script's effective remap index (native key 8 emits ★, not "j").
local NATIVE_SOURCE_LEVELS = {
	["com.apple.keylayout.ABC"] = {
		[8]="c", [10]="§", [33]="[", [38]="j", [42]="\\", [50]="`",
	},
	["com.apple.keylayout.French"] = {
		[8]="c", [38]="j", [39]="ù", [41]="m", [33]={text="", dead=true},
	},
	["org.sil.ukelele.keyboardlayout.ergopti.ergopti_v2_2_2_plus"] = {
		[8]="★", [10]="$", [30]="j", [33]="z", [38]="s", [50]="ê", [42]={text="", dead=true},
	},
}

--- Models only the selected machine's exact native source and requested order.
--- @param args table Canonical launcher role arguments.
--- @param layout table Current source descriptor.
--- @return table answer Strict JSON receipt or native argument refusal.
local function keyboard_source_answer(args, layout)
	local map = layout and NATIVE_SOURCE_LEVELS[layout.source_id]
	if args[1] ~= "--keyboard-source-probe" or not map or args[2] ~= layout.source_id or #args < 3 then
		return {code=64, stderr="invalid selected keyboard-source request"}
	end
	local levels, seen = {}, {}
	for index=3, #args do
		local raw = args[index]
		local canonical = type(raw) == "string" and (raw == "0" or raw:match("^[1-9]%d*$") ~= nil)
		local code = canonical and tonumber(raw) or nil
		if not code or code % 1 ~= 0 or code < 0 or code > 127
			or tostring(code) ~= raw or seen[code] then
			return {code=64, stderr="invalid native keyboard-source codes"}
		end
		seen[code] = true
		local value = map[code]
		local text = type(value) == "string" and value or (value and value.text or "")
		local dead = type(value) == "table" and value.dead == true or false
		levels[#levels+1] = {code=code, text=text, dead=dead, direct=not dead and text ~= ""}
	end
	return {code=0, stdout=require("json").encode({version=1, source_id=layout.source_id,
		keyboard_type=40, levels=levels}) .. "\n"}
end
M.keyboard_source_answer = keyboard_source_answer

-- The machines a scenario can boot on. `worker` delays are within the lease
--- worker's own budgets (READY_ACK_TIMEOUT_SEC 4 s, a command 1.75 s). A
--- `during_resume` event happens once, `after` seconds into the boot's first
--- RESUME, while its answer is still due.
M.MACHINES = {
	standard = { layout = "abc", worker = { ready_after = 0, answer_after = 0 } },
	-- A user of an Ergopti layout on a start-up busy enough that the worker
	-- answers late: RESUME is in flight when the first layout poll runs, 2 s
	-- after the remap init.
	ergopti_layout_slow_worker = { layout = "ergopti", worker = { ready_after = 1.0, answer_after = 1.5 } },
	-- The user switches the layout while the boot's RESUME is in flight.
	layout_switch_during_resume = { layout = "abc", worker = { ready_after = 0, answer_after = 1.0 },
		during_resume = { after = 0.1, switch_layout = "french" } },
	-- A reload (the menu, a shortcut, a watched file) during the same window.
	reload_during_resume = { layout = "abc", worker = { ready_after = 0, answer_after = 1.0 },
		during_resume = { after = 0.1, reload = true } },
}

-- The machine being booted and what it did; set by M.install.
local _machine = nil
local _selected_layout = nil
M.lease_workers_started = 0
M.native_reloads = 0

--- AppleSelectedInputSources as `defaults read` prints it.
--- @param layout table One of LAYOUTS.
--- @return string
local function selected_input_sources(layout)
	local name = layout.hitoolbox:match("^%w+$") and layout.hitoolbox or ('"' .. layout.hitoolbox .. '"')
	return "(\n        {\n        InputSourceKind = \"Keyboard Layout\";\n"
		.. "        \"KeyboardLayout ID\" = " .. layout.id .. ";\n"
		.. "        \"KeyboardLayout Name\" = " .. name .. ";\n    }\n)\n"
end

-- The options karabiner_cli defines (Karabiner-Elements 16,
-- src/bin/cli/src/main.cpp).
local KARABINER_CLI_OPTIONS = {
	["select-profile"] = true, ["show-current-profile-name"] = true, ["list-profile-names"] = true,
	["set-variables"] = true, ["copy-current-profile-to-system-default-profile"] = true,
	["remove-system-default-profile"] = true, ["lint-complex-modifications"] = true,
	["format-json"] = true, ["eval-js"] = true, ["silent"] = true, ["version"] = true,
	["version-number"] = true, ["help"] = true,
}

--- Whether a path exists on the machine (system folders already redirected).
--- @param path string
--- @return boolean
local function file_exists(path)
	local ok, attributes = pcall(hs.fs.attributes, path)
	return ok and type(attributes) == "table"
end

--- Selects the machine's keyboard layout and delivers the input-source
--- notification macOS posts for the switch.
--- @param name string LAYOUTS key.
local function switch_layout(name)
	_selected_layout = assert(LAYOUTS[name], "E2E world: unknown layout " .. tostring(name))
	record("LAYOUT_SWITCH", _selected_layout.localised)
	hs.keycodes.__fire_input_source_changed()
end

--- Runs the machine's `during_resume` event once, while the boot's first
--- RESUME answer is still due.
local function schedule_during_resume()
	local event = _machine.during_resume
	if not event or event.fired then return end
	event.fired = true
	hs.timer.doAfter(event.after, function()
		if event.switch_layout then switch_layout(event.switch_layout) end
		if event.reload then
			record("RELOAD_REQUESTED", "while the boot's RESUME is in flight")
			hs.reload()
		end
	end)
end

--- The Karabiner lease worker's line protocol, as RemapLeaseWorker.swift
--- speaks it once the guardian is ready: READY, then one answer per command,
--- each after the machine's worker delay.
--- @param api table { emit(text, delay), exit(code) }
--- @return function on_input
local function lease_worker(api)
	local worker = _machine.worker
	M.lease_workers_started = M.lease_workers_started + 1
	api.emit("READY\n", worker.ready_after)
	return function(data)
		for line in tostring(data):gmatch("[^\n]+") do
			local sequence = line:match("^PING (%d+)$")
			if sequence then api.emit("PONG " .. sequence .. "\n")
			elseif line == "PAUSE" then api.emit("PAUSED\n", worker.answer_after)
			elseif line == "RESUME" then
				api.emit("RESUMED\n", worker.answer_after)
				schedule_during_resume()
			elseif line == "STOP" then
				api.emit("STOPPED\n")
				api.exit(0)
			end
		end
	end
end

--- Answers one command of the set-up Mac.
--- @param path string Executable.
--- @param args table Arguments.
--- @param helper string The launcher executable.
--- @return table answer { code, stdout, stderr } or { interactive = fn }
local function machine_answer(path, args, helper)
	if path == helper then
		if args[1] == "--keyboard-source-probe" then return keyboard_source_answer(args, _selected_layout) end
		if args[1] == "--karabiner-lease-worker" then return { interactive = lease_worker } end
		if args[1] == "--karabiner-lease-revoke" then return { code = 0 } end
		local answer = HELPER_ROLE_ANSWERS[args[1]]
		if answer then return { code = 0, stdout = answer } end
	end
	if path:match("/karabiner_cli$") then
		-- cxxopts answers any option Karabiner-Elements does not define with exit
		-- status 2 (src/bin/cli/src/main.cpp); the CLI reads no user variable.
		for _, arg in ipairs(args) do
			local option = tostring(arg):match("^%-%-([%w-]+)")
			if option and not KARABINER_CLI_OPTIONS[option] then
				return { code = 2, stderr = "error parsing options: Option '" .. option .. "' does not exist" }
			end
		end
		return { code = 0 }
	end
	if path == "/usr/bin/open" then
		-- open(1) refuses a file that does not exist; a missing target is a
		-- window or file the user asked for and never saw.
		local target = args[#args]
		if type(target) == "string" and target:sub(1, 1) == "/" and not file_exists(target) then
			record("OPEN_MISSING", target)
			return { code = 1, stderr = "The file " .. target .. " does not exist." }
		end
		return { code = 0 }
	end
	if path == "/usr/bin/defaults" and args[1] == "read" and args[3] == "AppleSelectedInputSources" then
		return { code = 0, stdout = selected_input_sources(_selected_layout) }
	end
	if path == "/usr/bin/defaults" and args[1] == "read" and args[3] == "AppleEnabledInputSources" then
		return { code = 0, stdout = selected_input_sources(_selected_layout) }
	end
	if path:match("/python[%d.]*$") and args[1] == "-c" then
		local source = tostring(args[2])
		-- The active-layout probe of releases before hardening-h, and the
		-- display-mirror helper on a single screen.
		if source:find("AppleEnabledInputSources", 1, true) then
			return { code = 0, stdout = '["' .. _selected_layout.hitoolbox .. '"]\n' }
		end
		if source:find("CGGetOnlineDisplayList", 1, true) then return { code = 0, stdout = "single_screen\n" } end
		return { code = 0, stdout = "" }
	end
	if path == "/usr/bin/shortcuts" then return { code = 0, stdout = "" } end
	if path == "/bin/sh" or path == "/bin/zsh" or path == "/bin/bash" then return { code = 0, stdout = "" } end
	return { code = 127, stderr = tostring(path) .. ": this command is not modelled by the E2E Mac" }
end

-- The processors a Mac can have, as `uname -m` names them. The platform
-- default AI backend follows it (modules/llm/backend_detector.lua): MLX on
-- Apple silicon, Ollama on Intel, which an older config.toml without a
-- selected backend restores.
M.ARCHITECTURES = { "arm64", "x86_64" }

--- hs.execute answers of the set-up Mac, by substring of the command line.
--- @param arch string One of M.ARCHITECTURES.
--- @return table answers { substring, output, success }
local function execute_answers(arch)
	return {
		{ "systemextensionsctl list", "1 extension(s)\n--- com.apple.system_extension.driver_extension\n"
			.. "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n"
			.. "*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)\t"
			.. "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice\t[activated enabled]\n", true },
		{ "/usr/bin/pgrep", "123\n", true },
		{ "uname -m", arch .. "\n", true },
		{ "sw_vers -productVersion", "15.5\n", true },
	}
end





-- ============================================
-- ============================================
-- ======= 4/ Launcher and native edges =======
-- ============================================
-- ============================================

--- Builds the environment the Swift launcher exports to the embedded runtime.
--- @param app_root string Directory holding ErgoptiPlus.app.
--- @param home string The private HOME.
--- @return table env
function M.launcher_environment(app_root, home)
	local bundle = app_root .. "/ErgoptiPlus.app"
	local logs = home .. "/Library/Logs/ergopti_plus"
	return {
		ERGOPTI_LAUNCHER_PID = "4242",
		ERGOPTI_LAUNCHER_BUNDLE_ID = "com.ergoptiplus.app",
		ERGOPTI_LOG_PORT = "49321",
		ERGOPTI_LOG_TOKEN = string.rep("e2e-token-", 5),
		ERGOPTI_LAUNCHER_VERSION = "0.0.0-e2e",
		ERGOPTI_CONFIG_DIR = bundle .. "/Contents/Resources/static/ergopti_plus/macos",
		ERGOPTI_PATHS_FILE = home .. "/Library/Application Support/ErgoptiPlus/paths.toml",
		ERGOPTI_LAUNCHER_EXECUTABLE = bundle .. "/Contents/MacOS/ErgoptiPlus",
		ERGOPTI_REMAP_GUARDIAN_STATUS = "ready",
		ERGOPTI_LAUNCHER_DEVICE = "16777233",
		ERGOPTI_LAUNCHER_INODE = "424242",
		ERGOPTI_FATAL_REPORT_FILE = logs .. "/hammerspoon-fatal.txt",
		ERGOPTI_LAUNCHER_LOG_FILE = logs .. "/launcher.log",
		HOME = home,
	}
end

--- Replaces the native logger transport: every record is acknowledged on the
--- next clock turn, as the launcher's datagram worker does.
local function install_log_transport()
	local pending, options = {}, nil
	package.preload["adapters.log_transport"] = function()
		local transport = {}
		function transport.start(start_options) options = start_options; return true end
		function transport.enqueue(line, variant)
			local log_record = { line = line, variant = variant }
			pending[#pending + 1] = log_record
			return log_record
		end
		function transport.flush()
			local batch = pending
			pending = {}
			for _, log_record in ipairs(batch) do
				if options then options.on_delivered(log_record) else _emit(log_record.line) end
			end
		end
		function transport.drain(callback) transport.flush(); callback(true); return true end
		function transport.stop() return true end
		function transport.status() return { active = options ~= nil, queued = #pending } end
		return transport
	end
end

--- Installs the launcher environment, its live application and its helper.
--- @param hs table The hs stub.
--- @param env table launcher_environment().
local function install_launcher(hs, env)
	local real_getenv = os.getenv
	os.getenv = function(name)
		if env[name] ~= nil then return env[name] end
		-- A GUI launch carries no DEVELOPER_DIR; a CI runner's own must not choose
		-- the developer tools of the modelled Mac.
		if name == "DEVELOPER_DIR" then return nil end
		return real_getenv(name)
	end
	hs.application.__set_for_pid(tonumber(env.ERGOPTI_LAUNCHER_PID), handle({
		pid = function() return tonumber(env.ERGOPTI_LAUNCHER_PID) end,
		bundleID = function() return env.ERGOPTI_LAUNCHER_BUNDLE_ID end,
		name = function() return "ErgoptiPlus" end,
		isRunning = function() return true end,
	}))
	-- The launcher binary, identified by the device and inode it exported.
	local helper = env.ERGOPTI_LAUNCHER_EXECUTABLE
	local function with_helper_identity(original)
		return function(path, ...)
			if path == helper then
				return { mode = "file", dev = tonumber(env.ERGOPTI_LAUNCHER_DEVICE),
					ino = tonumber(env.ERGOPTI_LAUNCHER_INODE), permissions = "rwxr-xr-x", size = 1 }
			end
			return original(path, ...)
		end
	end
	hs.fs.attributes = with_helper_identity(hs.fs.attributes)
	hs.fs.symlinkAttributes = with_helper_identity(hs.fs.symlinkAttributes or hs.fs.attributes)
	M.write_file(env.ERGOPTI_LAUNCHER_LOG_FILE, "")
end





-- ==================================
-- ==================================
-- ======= 5/ Native doubles ========
-- ==================================
-- ==================================

--- Completes the hs stub where the boot needs a native answer it lacks.
--- @param hs table The hs stub.
--- @param env table launcher_environment().
--- @param arch string One of M.ARCHITECTURES.
--- @param machine_root string
local function install_natives(hs, env, arch, machine_root)
	hs.accessibilityState = function() return true end
	hs.settings.getKeys = function()
		local keys = {}
		for key in pairs(hs.settings.__store) do keys[#keys + 1] = key end
		table.sort(keys)
		return keys
	end
	hs.fs.link = function(source, destination, symbolic)
		if sh("ln " .. (symbolic and "-s " or "") .. sh_quote(source) .. " " .. sh_quote(destination)
			.. " 2>/dev/null") then return true end
		return nil, "link refused"
	end
	hs.fs.rmdir = function(path)
		if sh("rmdir " .. sh_quote(path) .. " 2>/dev/null") then return true end
		return nil, "rmdir refused"
	end
	-- A real directory listing: (iterator, directory object), raising on a
	-- path that is not a directory, as hs.fs.dir does.
	hs.fs.dir = function(path)
		local listing = io.popen("ls -a " .. sh_quote(path) .. " 2>/dev/null")
		local entries = {}
		for name in listing:lines() do entries[#entries + 1] = name end
		listing:close()
		if #entries == 0 then error("cannot open " .. tostring(path) .. ": No such file or directory", 2) end
		local index = 0
		local directory = setmetatable({}, { __name = "hs.fs.dir directory object" })
		return function(state)
			if state ~= directory then error("directory metatable expected", 2) end
			index = index + 1
			return entries[index]
		end, directory
	end

	-- pathToAbsolute expands ~ and resolves links, and answers nil for a path
	-- that does not exist, as the native one does. POSIX sh only: BSD realpath
	-- (a Mac running the suite) has no -e.
	local RESOLVE = 'p=$1; if [ -d "$p" ]; then (cd -P -- "$p" && pwd -P); elif [ -e "$p" ]; then '
		.. 'd=$(cd -P -- "$(dirname -- "$p")" && pwd -P) && printf \'%s/%s\\n\' "${d%/}" "$(basename -- "$p")"; fi'
	hs.fs.pathToAbsolute = function(path)
		if type(path) ~= "string" or path == "" then return nil end
		if path:sub(1, 1) == "~" then path = env.HOME .. path:sub(2) end
		local resolver = io.popen("sh -c " .. sh_quote(RESOLVE) .. " sh " .. sh_quote(path) .. " 2>/dev/null")
		local resolved = resolver:read("*l")
		resolver:close()
		if type(resolved) ~= "string" or resolved == "" then return nil end
		return resolved
	end

	-- The machine's selected input source, under its localised name.
	hs.keycodes.currentLayout = function() return _selected_layout.localised end
	hs.keycodes.currentSourceID = function() return _selected_layout.source_id end
	hs.keycodes.layouts = function() return { _selected_layout.localised } end
	hs.keycodes.methods = function() return {} end
	hs.keycodes.setLayout = function() return true end

	-- Windows, dialogs and notifications a user would see.
	hs.webview.windowMasks = { borderless = 0, titled = 1, closable = 2, miniaturizable = 4, resizable = 8,
		utility = 16, nonactivating = 128, HUD = 8192, fullSizeContentView = 32768 }
	hs.webview.new = function(frame)
		local webview = handle({})
		webview.hswindow = function() return handle({ id = function() return 99 end }) end
		webview.frame = function(self, new_frame)
			if new_frame then return self end
			return frame or { x = 0, y = 0, w = 800, h = 600 }
		end
		-- A loaded page: every global function a readiness probe names exists,
		-- and a publication function acknowledges what it applied (true).
		webview.evaluateJavaScript = function(self, code, callback)
			local result = nil
			if type(code) == "string" and code:match("^typeof window%.[%w_]+$") then
				result = "function"
			elseif type(code) == "string" and code:match("^window%.publish[%w_]*%(") then
				result = true
			end
			if type(callback) == "function" then callback(result, { code = 0 }) end
			return self
		end
		webview.isVisible = function() return true end
		webview.delete = function() return nil end
		return webview
	end
	-- A modal answers with M.dialog_choice(buttons), the first button unless a
	-- scenario chose otherwise for the dialog it is about to raise.
	hs.dialog.blockAlert = function(message, informative, first, second)
		record("DIALOG", "blockAlert: " .. tostring(message) .. " — " .. tostring(informative))
		return M.dialog_choice({ first, second })
	end
	hs.dialog.alert = function(_, _, _, message, informative)
		record("DIALOG", "alert: " .. tostring(message) .. " — " .. tostring(informative))
	end
	hs.dialog.textPrompt = function(message, informative, default, first)
		record("DIALOG", "textPrompt: " .. tostring(message) .. " — " .. tostring(informative))
		return first, default or ""
	end
	hs.dialog.chooseFileOrFolder = function(message)
		record("DIALOG", "chooseFileOrFolder: " .. tostring(message))
		return nil
	end
	-- A notification is what a boot tells the user without taking the keyboard:
	-- recorded when sent, not judged, so a scenario can require one.
	hs.notify.new = function(first, second)
		local attributes = type(first) == "table" and first or second or {}
		local notification = handle({})
		notification.send = function(self)
			record("NOTIFY", tostring(attributes.title) .. " — " .. tostring(attributes.informativeText))
			return self
		end
		return notification
	end
	local applescript = hs.osascript.applescript
	hs.osascript.applescript = function(source)
		if type(source) == "string" and (source:find("display dialog", 1, true)
			or source:find("display alert", 1, true)) then
			record("DIALOG", "osascript: " .. source:sub(1, 160))
		end
		return applescript(source)
	end

	-- The local HTTP server of the VS Code caret bridge: listening only between
	-- start() and stop(), as its getPort() reports.
	hs.httpserver = { new = function()
		local port, listening = 0, false
		return handle({
			setPort = function(self, value) port = value; return self end,
			start = function(self) listening = true; return self end,
			stop = function(self) listening = false; return self end,
			getPort = function() return listening and port or 0 end,
		})
	end }

	-- Tasks complete on a later clock turn, as hs.task does. An interactive
	-- answer speaks a line protocol over the task's stdin and stdout.
	local helper = env.ERGOPTI_LAUNCHER_EXECUTABLE
	local next_pid = 7100
	hs.task.new = function(path, callback, stream_or_args, maybe_args)
		local stream = type(stream_or_args) == "function" and stream_or_args or nil
		local args = type(stream_or_args) == "table" and stream_or_args or maybe_args or {}
		next_pid = next_pid + 1
		local running, environment, pid, on_input = false, {}, next_pid, nil
		local task = handle({})
		local function finish(code, stdout, stderr)
			if not running then return end
			running = false
			if type(callback) == "function" then callback(code, stdout or "", stderr or "") end
		end
		task.start = function(self)
			running = true
			record("TASK", path .. " " .. table.concat(args, " "):sub(1, 200))
			local archs, source = M.declared_archs(machine_root, path)
			local listed = archs and table.concat(archs, ",") or "unknown"
			record("SPAWN_ARCH", path .. " [" .. listed .. "] (" .. tostring(source) .. ")")
			if arch == "arm64" and archs then
				local native = false
				for _, slice in ipairs(archs) do native = native or slice == "arm64" end
				if not native then record("ROSETTA", path .. " [" .. listed .. "] (" .. tostring(source) .. ")") end
			end
			local answer = machine_answer(path, args, helper)
			if answer.interactive then
				local api = {
					emit = function(text, delay)
						hs.timer.doAfter(0.01 + (delay or 0), function()
							if running and stream then stream(self, text, "") end
						end)
					end,
					exit = function(code) hs.timer.doAfter(0.02, function() finish(code, "", "") end) end,
				}
				on_input = answer.interactive(api)
			else
				hs.timer.doAfter(0.05, function() finish(answer.code, answer.stdout, answer.stderr) end)
			end
			return self
		end
		task.setInput = function(self, data)
			if running and on_input then on_input(data) end
			return self
		end
		task.closeInput = function(self) return self end
		task.terminate = function(self)
			if running then hs.timer.doAfter(0, function() finish(15, "", "") end) end
			return self
		end
		task.isRunning = function() return running end
		task.pid = function() return pid end
		task.environment = function()
			local copy = {}
			for key, value in pairs(environment) do copy[key] = value end
			return copy
		end
		task.setEnvironment = function(self, candidate)
			environment = {}
			for key, value in pairs(candidate or {}) do environment[key] = value end
			return self
		end
		return task
	end
	for _, answer in ipairs(execute_answers(arch)) do hs.__set_exec(answer[1], answer[2], answer[3]) end

	-- The menu bar item keeps the menu it is given, so a scenario can click a
	-- row the way the user does (M.menu_items, M.click).
	hs.menubar.new = function()
		local item = handle({})
		item.setMenu = function(self, menu) M.menubar_menu = menu; return self end
		return item
	end

	-- Watchers whose start() returns the object, as the natives do.
	local function watcher_factory() return function() return handle({}) end end
	hs.distributednotifications = { new = watcher_factory() }
	hs.pathwatcher.new = watcher_factory()
	hs.caffeinate = hs.caffeinate or {}
	hs.caffeinate.watcher = hs.caffeinate.watcher or { new = watcher_factory(), systemDidWake = 0,
		systemWillSleep = 1, screensDidSleep = 2, screensDidWake = 3, screensDidLock = 7, screensDidUnlock = 8 }
end

--- The button a modal dialog answers with; scenarios replace it for the one
--- dialog they are about to raise.
--- @param buttons table The dialog's buttons, first one the default.
--- @return string
function M.dialog_choice(buttons)
	return buttons[1]
end

--- The rows of the menu bar menu, built the way Hammerspoon builds it on a
--- click: a function menu is called with no modifier held.
--- @return table|nil items
function M.menu_items()
	local menu = M.menubar_menu
	if type(menu) == "function" then return menu({}) end
	return menu
end

--- Finds the row at the end of a path of titles, one per menu level, the way
--- a user reaches it: several submenus carry rows with the same title.
--- @param items table|nil
--- @param path table Titles from the top level down.
--- @return table|nil row
function M.find_row(items, path)
	local row = nil
	for _, title in ipairs(path) do
		row = nil
		for _, candidate in ipairs(type(items) == "table" and items or {}) do
			if tostring(candidate.title) == title then row = candidate; break end
		end
		if row == nil then return nil end
		items = row.menu
	end
	return row
end

--- Delivers one pointer event to every started event tap that watches its
--- type, as the window server does when the user moves or clicks.
--- @param hs table The hs stub.
--- @param type_name string hs.eventtap.event.types key, e.g. "mouseMoved".
--- @return integer delivered Number of taps that received it.
function M.pointer_event(hs, type_name)
	local event_type = hs.eventtap.event.types[type_name]
	local delivered = 0
	for _, tap in ipairs(hs.eventtap.__taps) do
		local watched = false
		for _, watched_type in ipairs(tap.enabled and tap.types or {}) do
			if watched_type == event_type then watched = true end
		end
		if watched then
			local event = {
				getType = function() return event_type end,
				getProperty = function() return 0 end,
				getFlags = function() return {} end,
				location = function() return { x = 400, y = 300 } end,
			}
			local ok, err = xpcall(tap.fn, debug.traceback, event)
			if not ok then record("TAP_RAISED", err) end
			delivered = delivered + 1
		end
	end
	return delivered
end

--- Installs `require("hs.x")` for the native extensions the stub provides.
--- @param hs table The hs stub.
local function install_extension_searcher(hs)
	table.insert(package.searchers, 2, function(name)
		local path = name:match("^hs%.(.+)$")
		if not path or path:match("^_asm") then return nil end
		local value = hs
		for part in path:gmatch("[^.]+") do value = type(value) == "table" and value[part] or nil end
		if value == nil then return "\n\tno hs extension " .. name .. " in the E2E world" end
		return function() return value end
	end)
end





-- =============================================
-- =============================================
-- ======= 6/ File system of the machine =======
-- =============================================
-- =============================================

--- Redirects system folders into the machine root and watches every file
--- operation production code makes under the application bundle. A write is
--- user data kept in a read-only bundle; a read of a file the bundle does not
--- ship is user data looked up there (the class of the empty apps dashboard).
--- Only calls made from the bundle's own Lua are judged: the stub's existence
--- probes are the harness, not the product.
--- @param hs table The hs stub.
--- @param options table { app_root, machine_root, shipped_optional }
local function install_file_system(hs, options)
	local bundle = options.app_root .. "/ErgoptiPlus.app"
	local prefix = bundle .. "/"
	local shipped_optional = options.shipped_optional or {}
	local function inside(path)
		return type(path) == "string" and (path == bundle or path:sub(1, #prefix) == prefix)
	end
	--- The production source that made the call, or nil for harness code.
	local function production_caller()
		for level = 3, 7 do
			local info = debug.getinfo(level, "Sl")
			if not info then return nil end
			local source = (info.source or ""):gsub("^@", "")
			if inside(source) then return source:sub(#prefix + 1) .. ":" .. tostring(info.currentline) end
			if source:find("/tests/", 1, true) then return nil end
		end
		return nil
	end
	local function map(path) return redirect(options.machine_root, path) end
	local real_open = io.open
	local function exists(path)
		local fh = real_open(path, "r")
		if fh then fh:close(); return true end
		return false
	end
	io.open = function(path, mode)
		if inside(path) then
			local caller = production_caller()
			if caller then
				if type(mode) == "string" and mode:find("[wa+]") ~= nil then
					record("BUNDLE_WRITE", caller .. " opens " .. path .. " (" .. mode .. ")")
				elseif not exists(path) and not shipped_optional[path] then
					record("BUNDLE_READ_MISSING", caller .. " reads " .. path)
				end
			end
		end
		return real_open(map(path), mode)
	end
	local real_remove, real_rename = os.remove, os.rename
	os.remove = function(path)
		local caller = inside(path) and production_caller()
		if caller then record("BUNDLE_WRITE", caller .. " removes " .. path) end
		return real_remove(map(path))
	end
	os.rename = function(from, to)
		-- rename(p, p) is Lua's existence probe, not a write.
		local caller = from ~= to and (inside(from) or inside(to)) and production_caller()
		if caller then record("BUNDLE_WRITE", caller .. " renames " .. tostring(from) .. " to " .. tostring(to)) end
		return real_rename(map(from), map(to))
	end
	for _, name in ipairs({ "attributes", "symlinkAttributes", "pathToAbsolute", "dir" }) do
		local original = hs.fs[name]
		hs.fs[name] = function(path, ...) return original(map(path), ...) end
	end
	for _, name in ipairs({ "mkdir", "link", "rmdir", "touch" }) do
		local original = hs.fs[name]
		if type(original) == "function" then
			hs.fs[name] = function(path, target, ...)
				local caller = (inside(path) or inside(target)) and production_caller()
				if caller then record("BUNDLE_WRITE", caller .. " " .. name .. " " .. tostring(path)) end
				return original(map(path), map(target), ...)
			end
		end
	end
end





-- =============================
-- =============================
-- ======= 7/ Public API =======
-- =============================
-- =============================

--- Builds the world around the hs stub. Call before init.lua runs.
--- @param hs table The hs stub, already the global `hs`.
--- @param options table { app_root, machine_root, home, arch, machine, shipped_optional }
--- @return table env The launcher environment in force.
function M.install(hs, options)
	local known_arch = false
	for _, arch in ipairs(M.ARCHITECTURES) do known_arch = known_arch or options.arch == arch end
	if not known_arch then error("E2E world: unknown processor architecture " .. tostring(options.arch), 2) end
	_machine = M.MACHINES[options.machine or "standard"]
	if not _machine then error("E2E world: unknown machine " .. tostring(options.machine), 2) end
	_selected_layout = assert(LAYOUTS[_machine.layout], "E2E world: unknown layout " .. tostring(_machine.layout))
	-- The native reload: the old Lua VM would be replaced here.
	hs.reload = function()
		M.native_reloads = M.native_reloads + 1
		record("NATIVE_RELOAD", "the controlled reload reached hs.reload")
	end
	local env = M.launcher_environment(options.app_root, options.home)
	install_log_transport()
	install_timers(hs)
	install_launcher(hs, env)
	M.install_developer_tools(options.machine_root)
	install_natives(hs, env, options.arch, options.machine_root)
	install_extension_searcher(hs)
	install_file_system(hs, options)
	hs.configdir = env.ERGOPTI_CONFIG_DIR
	local real_exit = os.exit
	os.exit = function(code)
		M.flush_logs()
		record("EXIT", tostring(code) .. " " .. debug.traceback("", 2))
		io.stdout:flush()
		real_exit(code)
	end
	return env
end

--- Delivers every queued log record to the logger's sink.
function M.flush_logs()
	local loaded = package.loaded["adapters.log_transport"]
	if type(loaded) == "table" and type(loaded.flush) == "function" then loaded.flush() end
end

return M
