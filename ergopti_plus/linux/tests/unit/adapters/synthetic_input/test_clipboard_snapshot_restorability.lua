-- static/ergopti_plus/linux/tests/unit/adapters/synthetic_input/test_clipboard_snapshot_restorability.lua
--- Real clipboard/ShellRunner composition with a private in-memory transport.
local helpers = require("tests.helpers")
local REPLACEMENT = "EP79_PRIVATE_REPLACEMENT_CANARY"
local SELECTED = "EP79_PRIVATE_SELECTED_CANARY"
local URI = "file:///owned/EP79_PRIVATE_URI_CANARY\n"

local function with_snapshot(saved, body)
	local loaded, globals = {}, {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local old_cpath, old_ffi_preload = package.cpath, package.preload.ffi
	local attempts = 0
	local function blocked()
		attempts = attempts + 1
		error("snapshot fixture forbids native operations", 0)
	end
	local function guard(object, name)
		globals[#globals + 1] = { object, name, object[name] }
		object[name] = blocked
	end
	local shell, logger
	local okay, detail = xpcall(function()
		for _, name in ipairs({ "popen", "open", "tmpfile", "input", "output", "lines", "read" }) do guard(io, name) end
		for _, name in ipairs({ "execute", "remove", "rename", "tmpname", "clock", "date", "time" }) do guard(os, name) end
		guard(package, "loadlib")
		package.cpath = ""
		package.loaded.luv = setmetatable({}, { __index = function() return blocked end })
		package.loaded.ffi, package.preload.ffi = nil, blocked
		for _, name in ipairs({ "logger", "logger.shim", "infra.monotonic", "infra.display_server", "adapters.shell_runner", "adapters.clipboard" }) do
			package.loaded[name] = nil
		end
		logger = require("logger")
		logger.timestamp_fn = function() return "2000-01-01 00:00:00:000" end
		local tick = 0
		logger.clock_fn = function() tick = tick + 10; return tick end
		logger.set_level("debug")
		assert(require("logger.shim") == logger)
		local logs = {}
		logger.set_sink(function(line) logs[#logs + 1] = line end)
		local display = require("infra.display_server")
		display._set_for_test(display.X11, "private-memory")
		shell = require("adapters.shell_runner")
		local validate, run, checked, exact = shell.validate_spawn_args, shell.run, shell.exec_checked, shell.with_exact_stdin
		local s = { value = saved, writes = {}, reads = {}, settles = {}, emits = {}, transforms = 0, layout_calls = 0 }
		package.loaded["adapters.keyboard_layout"] = {
			shortcut_keycode = function(char, fallback)
				s.layout_calls = s.layout_calls + 1
				assert(char == "v" and fallback == 47)
				return 47
			end,
		}
		shell._set_runner(function(command)
			assert(not command:find("\0", 1, true), "the real guard must run before the transport seam")
			if command == "command -v " .. shell.quote("xclip") .. " >/dev/null 2>&1" then return true end
			local clipboard = "timeout 1 xclip -selection clipboard -o 2>/dev/null"
			local primary = "timeout 1 xclip -selection primary -o 2>/dev/null"
			local uri = "timeout 1 xclip -selection clipboard -t text/uri-list -o 2>/dev/null"
			if command == clipboard or command == primary or command == uri then
				s.reads[#s.reads + 1] = command
				return { ok = true, output = s.value }
			end
			-- Decode the real generated command independently; no writer/guard mock.
			local header, rest = command:match("^([^\n]*)\n(.*)$")
			local count, token = (header or ""):match("^head %-c (%d+) <<'([%w_]+)' | timeout 1 xclip %-selection clipboard %-in$")
			assert(count and token and rest, "unexpected private transport command")
			local suffix = "\n" .. token .. "\n"
			assert(rest:sub(-#suffix) == suffix)
			local text = rest:sub(1, #rest - #suffix)
			assert(#text == tonumber(count), "the actual writer must preserve exact byte length")
			s.writes[#s.writes + 1] = text
			s.value = text
			return true
		end)
		local clip = require("adapters.clipboard")
		local function sleep(ms) s.settles[#s.settles + 1] = ms; return true end
		local function combo(name)
			s.emits[#s.emits + 1] = name
			if name == "ctrl+c" then s.value = s.uri and URI or SELECTED end
			return true
		end
		local channel = { emit = function(code, value)
			s.emits[#s.emits + 1] = { code, value }; return true
		end }
		function s.invoke(owner)
			if owner == "stage" then
				s.stage = clip.new_paste_stage(REPLACEMENT, sleep, 47, function() return true end)
				local ready = s.stage.prepare()
				if ready then s.closed = s.stage.close() end
				return ready
			elseif owner == "paste_text" then return clip.paste_text(REPLACEMENT, channel, sleep)
			elseif owner == "read_selection" then return clip.read_selection(combo, sleep)
			elseif owner == "read_selection_uri_list" then s.uri = true; return clip.read_selection_uri_list(combo, sleep)
			elseif owner == "transform_selection" then
				return clip.transform_selection(function(text)
					s.transforms = s.transforms + 1
					assert(text == SELECTED)
					return REPLACEMENT
				end, combo, sleep)
			end
			error("unknown owned API")
		end
		body(clip, s)
		assert(shell.validate_spawn_args == validate and shell.run == run
			and shell.exec_checked == checked and shell.with_exact_stdin == exact,
			"real composition and guard must remain unchanged")
		for _, lines in ipairs({ logs, logger.ring_buffer_snapshot() }) do
			for _, line in ipairs(lines) do
				assert(not line:find("EP79_PRIVATE", 1, true), "snapshot/replacement/selection canary leaked to logs")
				assert(not line:find("A\0B", 1, true), "binary snapshot leaked to logs")
			end
		end
	end, debug.traceback)
	if shell then shell._reset_runner() end
	if logger then logger.set_sink(nil) end
	package.cpath, package.preload.ffi = old_cpath, old_ffi_preload
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	for i = #globals, 1, -1 do local item = globals[i]; item[1][item[2]] = item[3] end
	if not okay then error(detail, 0) end
	helpers.assert_eq(attempts, 0, "no native operation may replace the private test transport")
end

local owners = { "stage", "paste_text", "read_selection", "read_selection_uri_list", "transform_selection" }
helpers.describe("clipboard snapshot restorability", function()
	for _, owner in ipairs(owners) do
		for _, sample in ipairs({ { name = "NUL", bytes = "A\0B" }, { name = "canary NUL", bytes = "EP79_PRIVATE_SNAPSHOT_A\0B" } }) do
			helpers.it("snapshot preflight: " .. owner .. " refuses " .. sample.name .. " before mutation", function()
				with_snapshot(sample.bytes, function(_, s)
					local accepted = s.invoke(owner)
					-- Check mutation first: baseline APIs can return false too late.
					helpers.assert_eq(#s.writes, 0, "a nonrestorable snapshot must be refused before the first temporary write")
					helpers.assert_eq(s.value, sample.bytes, "the original bytes must remain untouched")
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(#s.reads, 1)
					helpers.assert_eq({ #s.settles, #s.emits, s.transforms, s.layout_calls }, { 0, 0, 0, 0 })
					if s.stage then
						helpers.assert_eq(s.stage.close(), true)
						helpers.assert_eq(s.stage.close(), true)
						helpers.assert_eq({ #s.writes, #s.reads, #s.settles, #s.emits }, { 0, 1, 0, 0 })
					end
				end)
			end)
		end
		for _, sample in ipairs({
			{ name = "ASCII", bytes = "EP79_PRIVATE_ASCII" },
			{ name = "empty", bytes = "" },
			{ name = "UTF8", bytes = "EP79_PRIVATE_UTF8 é漢" },
			{ name = "UTF8 two final LF", bytes = "EP79_PRIVATE_UTF8 é漢\n\n" },
		}) do
			helpers.it("snapshot preflight: " .. owner .. " restores " .. sample.name .. " exactly", function()
				with_snapshot(sample.bytes, function(_, s)
					local accepted, text = s.invoke(owner)
					helpers.assert_eq(accepted, true)
					helpers.assert_eq(s.value, sample.bytes)
					helpers.assert_eq(s.writes[#s.writes], sample.bytes, "the actual generated writer must restore every original byte")
					if owner == "stage" then
						helpers.assert_eq(s.closed, true)
						helpers.assert_eq(s.stage.close(), true)
						helpers.assert_eq(#s.writes, 2)
					elseif owner == "read_selection" then helpers.assert_eq(text, SELECTED)
					elseif owner == "read_selection_uri_list" then helpers.assert_eq(text, URI) end
				end)
			end)
		end
	end
	for _, method in ipairs({ "read_checked", "read_primary" }) do
		helpers.it("snapshot preflight: raw " .. method .. " retains NUL without writes", function()
			local bytes = "EP79_PRIVATE_RAW_A\0B"
			with_snapshot(bytes, function(clip, s)
				local accepted, text, why = clip[method]()
				helpers.assert_eq({ accepted, text }, { true, bytes })
				helpers.assert_nil(why)
				helpers.assert_eq({ #s.writes, #s.reads, #s.emits, #s.settles }, { 0, 1, 0, 0 })
			end)
		end)
	end
	helpers.it("snapshot preflight: existing writer hard guard still refuses NUL before dispatch", function()
		with_snapshot("original", function(clip, s)
			helpers.assert_eq(clip.write("EP79_PRIVATE_WRITE_A\0B"), false)
			helpers.assert_eq(s.value, "original")
			helpers.assert_eq({ #s.writes, #s.reads }, { 0, 0 })
		end)
	end)
end)
