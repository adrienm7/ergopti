--- tests/unit/modules/diagnostics/test_crash_privacy.lua

local helpers = require("tests.helpers")
local TOKEN = "sk-synthetic_crash_proof_0123456789"
local HOME = "/home/crashprivateowner"
local USER = "crashprivateowner"
local PAYLOAD = "CRASH_SENTINEL api_key=" .. TOKEN .. " file=" .. HOME .. "/private.lua user=" .. USER
local DIRECTORY = "/owned-crash-privacy-fixture"
local ENOENT, EACCES = 2, 13 -- Canonical Linux missing-source and permission receipts.

-- Actual policy admission and redactor, with explicit portable filesystem ports.
-- Real file output is independently exercised by the native causal receipt.
local function with_fixture(body, cold)
	local names = { "infra.logger_sink", "modules.diagnostics.crash_reporter", "logger.shim", "infra.diagnostic_snapshot",
		"infra.version", "infra.paths", "adapters.file_system", "infra.regular_file_reader", "infra.regular_file_writer" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local open, popen, execute, remove, stderr = io.open, io.popen, os.execute, os.remove, io.stderr
	local state = { files = {}, notices = {}, stderr = {}, opened = 0, closed = 0, logger_opened = 0 }
	local function owned(path) return type(path) == "string" and path:sub(1, #DIRECTORY + 1) == DIRECTORY .. "/" end
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
			if owned(path) then state.files[path] = nil; return true end
			return remove(path)
		end
		io.open = function(path, mode)
			if not owned(path) then return open(path, mode) end
			local crash = path:find("/crash_", 1, true) ~= nil
			if crash then state.opened = state.opened + 1 end
			if crash and state.refuse_open then return nil, PAYLOAD, state.refuse_errno end
			if mode == "wx" and state.files[path] ~= nil then return nil, "fixture candidate exists", "EEXIST" end
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
		-- Model the canonical logger acquisitions at their actual public ports.
		-- Policy and other sources outside this owned root keep native read admission.
		local Reader, Writer = require("infra.regular_file_reader"), require("infra.regular_file_writer")
		local reader_ports, writer_ports = {}, {}
		for name, value in pairs(Reader) do reader_ports[name] = value end
		for name, value in pairs(Writer) do writer_ports[name] = value end
		for _, name in ipairs({ "open", "open_source" }) do
			local original = Reader[name]
			reader_ports[name] = function(path)
				if not owned(path) then return original(path) end
				local text = state.files[path]
				if text == nil then return nil, "fixture source is absent", ENOENT end
				return { read = function(_, format)
					assert(format == "*l" or format == "*a", "fixture source requires a canonical text read")
					return format == "*l" and text:match("^([^\n]*)") or text
				end, close = function() return true end }
			end
		end
		writer_ports.open = function(path, mode)
			if not owned(path) then return Writer.open(path, mode) end
			state.logger_opened = state.logger_opened + 1
			if state.refuse_logger_open then return nil, PAYLOAD, EACCES end
			if state.before_writer_open then state.before_writer_open(path, mode) end
			local file, detail, errno = io.open(path, mode)
			if not file or mode ~= "wx" or state.image_failure == "missing" then return file, detail, errno end
			return file, detail, errno, nil, function(expected)
				if state.on_image then state.on_image() end
				if state.image_failure == "throw" then error(PAYLOAD) end
				if state.image_failure == "truthy" then return {} end
				if state.image_failure == "false" then return false end
				if state.image_failure == "nil" then return nil end
				return state.files[path] == expected
			end
		end
		package.loaded["infra.regular_file_reader"], package.loaded["infra.regular_file_writer"] = reader_ports, writer_ports
		Sink = require("infra.logger_sink")
		state.try_install = function(context)
			return Sink.install(Logger, { log_dir = DIRECTORY, redaction_context = context or { home = HOME, user = USER } })
		end
		state.install = function(context) assert(state.try_install(context)) end
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
	helpers.it("keeps file-sink admission false when canonical logger acquisition is refused", function()
		with_fixture(function(s)
			s.refuse_logger_open = true
			helpers.assert_eq(s.try_install(), false)
			helpers.assert_true(s.logger_opened > 0, "The real logger must attempt the canonical writer port")
			helpers.assert_eq(s.Sink.is_file_sink_active(), false)
			helpers.assert_true(#s.stderr > 0, "Native file refusal must be reported")
			helpers.assert_eq(s.opened, 0); helpers.assert_eq(#s.dumps(), 0); helpers.assert_eq(#s.notices, 0)
			no_private(table.concat(s.stderr))
		end, true)
	end)

	helpers.it("redacts protected errors and stack while preserving technical diagnostics", function()
		with_fixture(function(s)
			local ok, original = s.Reporter.protect("engine", function() error(PAYLOAD) end)
			helpers.assert_eq(ok, false); helpers.assert_contains(tostring(original), TOKEN, "caller retains its original error contract")
			local dump = s.dumps(); helpers.assert_eq(#dump, 1); no_private(dump[1].text)
			helpers.assert_contains(dump[1].text, "CRASH_SENTINEL")
			helpers.assert_contains(dump[1].text, "stack traceback:")
			local report = require("json").decode(dump[1].text)
			helpers.assert_eq(report.git_hash, "f1424d19"); helpers.assert_eq(report.commit_source, "build")
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
	for _, phase in ipairs({ "open", "write", "close", "image" }) do
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
	for _, receipt in ipairs({ 13, "EACCES", "EINVAL" }) do
		helpers.it("does not retry exclusive acquisition refusal " .. tostring(receipt), function()
			with_fixture(function(s)
				s.refuse_open, s.refuse_errno = true, receipt
				helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
				helpers.assert_eq(s.opened, 1, "only a proven EEXIST may select another candidate")
				helpers.assert_eq(s.closed, 0); helpers.assert_eq(#s.notices, 0)
				no_private(table.concat(s.stderr))
			end)
		end)
	end

	helpers.it("does not reacquire after sink revocation during an EEXIST receipt", function()
		with_fixture(function(s)
			s.before_writer_open = function(path)
				if path:find("/crash_", 1, true) then
					s.Sink.uninstall(s.Logger)
					s.refuse_open, s.refuse_errno = true, "EEXIST"
				end
			end
			helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
			helpers.assert_eq(s.opened, 1); helpers.assert_eq(s.closed, 0)
			helpers.assert_eq(#s.dumps(), 0); helpers.assert_eq(#s.notices, 0)
			no_private(table.concat(s.stderr))
		end)
	end)

	for _, failure in ipairs({ "throw", "truthy", "false", "nil", "missing" }) do
		helpers.it("refuses failed publication image " .. failure, function()
			with_fixture(function(s)
				s.image_failure = failure
				helpers.assert_eq(s.Reporter.dump("engine", PAYLOAD), false)
				helpers.assert_eq(s.closed, 1); helpers.assert_eq(#s.notices, 0)
				for _, dump in ipairs(s.dumps()) do no_private(dump.text) end
				no_private(table.concat(s.stderr))
			end)
		end)
	end

	helpers.it("redacts module filenames and optional context as well as the error", function()
		with_fixture(function(s)
			helpers.assert_eq(s.Reporter.dump(TOKEN, PAYLOAD, { stack_trace = PAYLOAD, layout = PAYLOAD, locale = PAYLOAD }), true)
			local dump = s.dumps(); helpers.assert_eq(#dump, 1); no_private(dump[1].path); no_private(dump[1].text)
		end)
	end)
end)


if package.config:sub(1, 1) == "/" then
	helpers.describe("native crash history", function()
		helpers.it("acknowledges only a retained redacted report image (crash-published-image)", function()
			local uv = require("luv")
			local directory = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-crash-image-XXXXXX"))
			local names = { "infra.logger_sink", "modules.diagnostics.crash_reporter", "logger.shim" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
			local Writer = require("infra.regular_file_writer")
			local native_write, Sink, Logger = Writer.open
			local ok, err = xpcall(function()
				Logger, Sink = require("logger.shim"), require("infra.logger_sink")
				assert(Sink.install(Logger, { log_dir = directory, redaction_context = { home = HOME, user = USER } }))
				local Reporter = require("modules.diagnostics.crash_reporter")
				for _, mode in ipairs({ "intact", "replaced", "removed" }) do
					local candidate, injected
					Writer.open = function(path, access)
						local file, detail, errno, cleanup, image = native_write(path, access)
						if file and path:find("/crash_", 1, true) then
							candidate, injected = path, true
							if mode ~= "intact" then
								assert(uv.fs_unlink(path))
								if mode == "replaced" then
									local descriptor = assert(uv.fs_open(path, "wx", 384))
									assert(uv.fs_write(descriptor, "FOREIGN_IMAGE_MARKER", 0))
									assert(uv.fs_close(descriptor))
								end
							end
						end
						return file, detail, errno, cleanup, image
					end
					local acknowledged = Reporter.dump("image_" .. mode, "PUBLISHED_IMAGE_MARKER " .. PAYLOAD)
					Writer.open = native_write
					helpers.assert_eq(injected, true, "the native writer must first acquire a real inode")
					local file = io.open(candidate, "rb")
					local text = file and file:read("*a") or nil
					if file then assert(file:close()) end
					if text then no_private(text) end
					if mode == "intact" then
						helpers.assert_eq(acknowledged, true)
						helpers.assert_contains(text, "PUBLISHED_IMAGE_MARKER")
					elseif mode == "replaced" then
						helpers.assert_eq(text, "FOREIGN_IMAGE_MARKER", "verification cannot overwrite or unlink the successor")
						helpers.assert_eq(acknowledged, false, "a report written to an unlinked inode is not published")
					else
						helpers.assert_nil(text)
						helpers.assert_eq(acknowledged, false, "an absent publication cannot be acknowledged")
					end
				end
			end, debug.traceback)
			Writer.open = native_write
			if Sink then Sink.uninstall(Logger) end
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			for _, folder in ipairs({ directory .. "/crash_reports", directory }) do
				local scanner = uv.fs_scandir(folder)
				if scanner then
					while true do local name, kind = uv.fs_scandir_next(scanner); if not name then break end
						if kind == "file" then assert(uv.fs_unlink(folder .. "/" .. name)) end
					end
					assert(uv.fs_rmdir(folder))
				end
			end
			if not ok then error(err, 0) end
		end)

		helpers.it("preserves same-second reports across reporter reloads (crash-exclusive-history)", function()
			local uv = require("luv")
			local directory = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-crash-history-XXXXXX"))
			local names = { "infra.logger_sink", "modules.diagnostics.crash_reporter", "logger.shim" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
			local date, Sink, Logger = os.date
			local Writer = require("infra.regular_file_writer")
			local native_write = Writer.open
			local timestamp = "2026-10-25T12:00:00Z"
			local ok, err = xpcall(function()
				Logger, Sink = require("logger.shim"), require("infra.logger_sink")
				assert(Sink.install(Logger, { log_dir = directory, redaction_context = { home = HOME, user = USER } }))
				os.date = function(format, ...)
					if format == "!%Y-%m-%dT%H:%M:%SZ" then return timestamp end
					return date(format, ...)
				end
				local Reporter = require("modules.diagnostics.crash_reporter")
				for _, marker in ipairs({ "FIRST_HISTORY_MARKER", "SECOND_HISTORY_MARKER" }) do
					helpers.assert_eq(Reporter.dump("engine", marker .. " " .. PAYLOAD), true)
				end
				helpers.assert_eq(Reporter.dump("other", "OTHER_MODULE_MARKER " .. PAYLOAD), true)
				timestamp = "2026-10-25T12:00:01Z"
				helpers.assert_eq(Reporter.dump("engine", "OTHER_SECOND_MARKER " .. PAYLOAD), true)
				timestamp = "2026-10-25T12:00:00Z"
				package.loaded["modules.diagnostics.crash_reporter"] = nil
				Reporter = require("modules.diagnostics.crash_reporter")
				helpers.assert_eq(Reporter.dump("engine", "RELOADED_HISTORY_MARKER " .. PAYLOAD), true)
				local raced = false
				local CrashReport = require("crash_report")
				-- Four reports already occupy this second; race its next free candidate.
				local race_path = directory .. "/crash_reports/" .. CrashReport.file_name(CrashReport.stem(timestamp), 5)
				Writer.open = function(path, mode)
					if path == race_path and not raced then
						helpers.assert_eq(mode, "wx", "the competing inode precedes exclusive acquisition")
						raced = true
						local descriptor = assert(uv.fs_open(path, "wx", 384))
						assert(uv.fs_write(descriptor, "RACE_OWNER_MARKER", 0))
						assert(uv.fs_close(descriptor))
					end
					return native_write(path, mode)
				end
				helpers.assert_eq(Reporter.dump("racing", "RACE_REPORT_MARKER " .. PAYLOAD), true)
				Writer.open = native_write
				helpers.assert_eq(raced, true, "a real competing inode must occupy the candidate at acquisition")
				local files, texts = {}, {}
				local reports = assert(uv.fs_scandir(directory .. "/crash_reports"))
				while true do
					local name = uv.fs_scandir_next(reports); if not name then break end
					local file = assert(io.open(directory .. "/crash_reports/" .. name, "rb"))
					local text = assert(file:read("*a")); assert(file:close())
					no_private(name); no_private(text)
					files[#files + 1], texts[#texts + 1] = name, text
				end
				helpers.assert_eq(#files, 7, "every acknowledged report must survive same-second collisions and reloads")
				local document = table.concat(texts)
				for _, marker in ipairs({ "FIRST_HISTORY_MARKER", "SECOND_HISTORY_MARKER", "OTHER_MODULE_MARKER",
					"OTHER_SECOND_MARKER", "RELOADED_HISTORY_MARKER", "RACE_OWNER_MARKER", "RACE_REPORT_MARKER" }) do
					local _, count = document:gsub(marker, "")
					helpers.assert_eq(count, 1, "each error must survive exactly once")
				end
			end, debug.traceback)
			os.date = date
			Writer.open = native_write
			if Sink then Sink.uninstall(Logger) end
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			for _, folder in ipairs({ directory .. "/crash_reports", directory }) do
				local scanner = uv.fs_scandir(folder)
				if scanner then
					while true do local name, kind = uv.fs_scandir_next(scanner); if not name then break end
						if kind == "file" then assert(uv.fs_unlink(folder .. "/" .. name)) end
					end
					assert(uv.fs_rmdir(folder))
				end
			end
			if not ok then error(err, 0) end
		end)
	end)
end
