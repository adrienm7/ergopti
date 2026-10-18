--- tests/unit/modules/diagnostics/test_crash_privacy.lua

local helpers = require("tests.helpers")
local TOKEN = "sk-synthetic_crash_proof_0123456789"
local HOME = "/home/crashprivateowner"
local USER = "crashprivateowner"
local PAYLOAD = "CRASH_SENTINEL api_key=" .. TOKEN .. " file=" .. HOME .. "/private.lua user=" .. USER
local DIRECTORY = "/owned-crash-privacy-fixture"

-- Actual policy admission and redactor, with explicit portable filesystem ports.
-- Real file output is independently exercised by the native causal receipt.
local function with_fixture(body, cold)
	local names = { "infra.logger_sink", "modules.diagnostics.crash_reporter", "logger.shim", "infra.diagnostic_snapshot",
		"infra.version", "infra.paths", "adapters.file_system" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local open, popen, execute, remove, stderr = io.open, io.popen, os.execute, os.remove, io.stderr
	local state = { files = {}, notices = {}, stderr = {}, opened = 0, closed = 0 }
	local Logger = helpers.make_logger_stub()
	Logger.set_sink = function(fn) state.sink = fn end
	Logger.enable_repeat_collapsing = function() end
	Logger.disable_repeat_collapsing = function() end
	Logger.error = function(_, fmt, ...) state.notices[#state.notices + 1] = string.format(fmt, ...) end
	package.loaded["logger.shim"] = Logger
	local Sink
	local ok, err = xpcall(function()
		io.stderr = { write = function(_, text) state.stderr[#state.stderr + 1] = text; return true end }
		os.execute = function() return 0 end
		io.popen = function() return nil end
		os.remove = function(path)
			if path:sub(1, #DIRECTORY) == DIRECTORY then state.files[path] = nil; return true end
			return remove(path)
		end
		io.open = function(path, mode)
			if path:sub(1, #DIRECTORY) ~= DIRECTORY then return open(path, mode) end
			local crash = path:find("/crash_", 1, true) ~= nil
			if crash then state.opened = state.opened + 1 end
			if crash and state.refuse_open then return nil, PAYLOAD end
			state.files[path] = mode == "a" and (state.files[path] or "") or ""
			local file = {}
			function file:write(text)
				state.files[path] = state.files[path] .. text
				if crash and state.on_write then state.on_write() end
				if crash and state.refuse_write then return nil, PAYLOAD end
				return self
			end
			function file:flush() return true end
			function file:close()
				if crash then state.closed = state.closed + 1 end
				if crash and state.on_close then state.on_close() end
				if crash and state.refuse_close then return nil, PAYLOAD end
				return true
			end
			if crash and state.on_open then state.on_open() end
			return file
		end
		Sink = require("infra.logger_sink")
		state.install = function(context)
			assert(Sink.install(Logger, { log_dir = DIRECTORY, redaction_context = context or { home = HOME, user = USER } }))
		end
		if not cold then state.install() end
		package.loaded["infra.diagnostic_snapshot"] = { resolve_commit = function()
			if state.on_facts then state.on_facts() end
			return "f1424d19", "build"
		end }
		state.Sink, state.Logger = Sink, Logger
		state.Reporter = require("modules.diagnostics.crash_reporter")
		state.dumps = function()
			local result = {}; for path, text in pairs(state.files) do if path:find("/crash_", 1, true) then result[#result + 1] = { path = path, text = text } end end
			return result
		end
		body(state)
	end, debug.traceback)
	if Sink then pcall(Sink.uninstall, Logger) end
	io.open, io.popen, os.execute, os.remove, io.stderr = open, popen, execute, remove, stderr
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

local function no_private(text)
	for _, private in ipairs({ TOKEN, HOME, USER }) do helpers.assert_true(not text:find(private, 1, true), "private data cannot reach an output") end
end

helpers.describe("crash privacy admission", function()
	helpers.it("redacts protected errors and stack while preserving technical diagnostics", function()
		with_fixture(function(s)
			local ok, original = s.Reporter.protect("engine", function() error(PAYLOAD) end)
			helpers.assert_eq(ok, false); helpers.assert_contains(tostring(original), TOKEN, "caller retains its original error contract")
			local dump = s.dumps(); helpers.assert_eq(#dump, 1); no_private(dump[1].text)
			helpers.assert_contains(dump[1].text, "CRASH_SENTINEL")
			helpers.assert_contains(dump[1].text, "stack traceback:")
			helpers.assert_contains(dump[1].text, "f1424d19 (build)")
			helpers.assert_eq(s.closed, 1); helpers.assert_eq(#s.notices, 1)
		end)
	end)
	for _, phase in ipairs({ "cold", "closed" }) do
		helpers.it("refuses private output when sink is " .. phase, function()
			with_fixture(function(s)
				if phase == "closed" then s.Sink.uninstall(s.Logger) end
				helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
				helpers.assert_eq(s.opened, 0); helpers.assert_eq(#s.dumps(), 0); helpers.assert_eq(#s.notices, 0)
				no_private(table.concat(s.stderr)); helpers.assert_true(#s.stderr > 0)
			end, phase == "cold")
		end)
	end
	helpers.it("never substitutes the successor redactor for an in-progress dump", function()
		with_fixture(function(s)
			local redact, current = s.Sink.capture_redactor()
			s.on_facts = function()
				s.on_facts = nil; s.Sink.uninstall(s.Logger)
				s.install({ home = "/home/successorowner", user = "successorowner" })
			end
			helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
			helpers.assert_eq(current(), false); helpers.assert_eq(redact(PAYLOAD), nil)
			helpers.assert_eq(s.opened, 0); helpers.assert_eq(#s.notices, 0); no_private(table.concat(s.stderr))
			helpers.assert_eq(s.Reporter.dump("engine", "CRASH_SENTINEL api_key=" .. TOKEN .. " /home/successorowner/file"), true)
			local dump = s.dumps(); helpers.assert_eq(#dump, 1); no_private(dump[1].text)
			helpers.assert_true(not dump[1].text:find("successorowner", 1, true))
		end)
	end)
	for _, phase in ipairs({ "open", "write", "close" }) do
		helpers.it("retires a dump revoked during " .. phase, function()
			with_fixture(function(s)
				s["on_" .. phase] = function() s.Sink.uninstall(s.Logger) end
				helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
				helpers.assert_eq(s.closed, 1); helpers.assert_eq(#s.notices, 0)
				for _, dump in ipairs(s.dumps()) do no_private(dump.text) end
				no_private(table.concat(s.stderr))
			end)
		end)
	end
	for _, phase in ipairs({ "open", "write", "close" }) do
		helpers.it("refuses failed " .. phase .. " without announcing or exposing private partial bytes", function()
			with_fixture(function(s)
				s["refuse_" .. phase] = true
				helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
				helpers.assert_eq(#s.notices, 0)
				for _, dump in ipairs(s.dumps()) do no_private(dump.text) end
				no_private(table.concat(s.stderr))
			end)
		end)
	end
	for _, failure in ipairs({ "throw", "nil", "truthy" }) do
		helpers.it("refuses redaction provider " .. failure .. " without raw fallback", function()
			with_fixture(function(s)
				local Redact = require("diagnostics.redact")
				local original = Redact.apply
				Redact.apply = function()
					if failure == "throw" then error(PAYLOAD) end
					if failure == "truthy" then return {} end
				end
				local ok, err = xpcall(function()
					helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
					helpers.assert_eq(s.opened, 0); helpers.assert_eq(#s.notices, 0)
					no_private(table.concat(s.stderr))
				end, debug.traceback)
				Redact.apply = original
				if not ok then error(err, 0) end
			end)
		end)
	end
	helpers.it("retains an explicitly fresh successor report published during the old close", function()
		with_fixture(function(s)
			s.on_close = function()
				s.on_close = nil; s.Sink.uninstall(s.Logger); s.install()
				helpers.assert_eq(s.Reporter.dump("engine", "SUCCESSOR_MARKER api_key=" .. TOKEN), true)
			end
			helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
			local dumps = s.dumps(); helpers.assert_true(#dumps > 0)
			local found = false
			for _, dump in ipairs(dumps) do
				no_private(dump.text)
				if dump.text:find("SUCCESSOR_MARKER", 1, true) then found = true end
			end
			helpers.assert_true(found, "retired cleanup cannot delete a completed successor")
			helpers.assert_eq(#s.notices, 1)
		end)
	end)
	helpers.it("redacts module filenames and optional context as well as the error", function()
		with_fixture(function(s)
			helpers.assert_eq(s.Reporter.dump(TOKEN, PAYLOAD, { stack_trace = PAYLOAD, layout = PAYLOAD, locale = PAYLOAD }), true)
			local dump = s.dumps(); helpers.assert_eq(#dump, 1); no_private(dump[1].path); no_private(dump[1].text)
		end)
	end)
end)
