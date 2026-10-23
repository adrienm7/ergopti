--- tests/unit/modules/llm/agent/test_agent_file_receipts.lua

--- ==============================================================================
--- MODULE: Agent File Completion Receipts (Linux)
--- DESCRIPTION:
--- A failed write or buffered close must neither publish learned thresholds nor
--- hand an incomplete calendar file to a desktop application. Real private files
--- carry the partial bytes; only their write/close receipts are faulted.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Shell = require("adapters.shell_runner")

local FAULTS = { "write_nil", "write_false", "write_throw", "close_nil", "close_false", "close_throw" }

--- Reads the worker's completion acknowledgement without changing its bytes.
--- @param path string
--- @return string
local function state_read_for_fixture(path)
	local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end

--- Exercises one fresh owner and closes every real stream even on the old bug.
--- @param name string Module under test.
--- @param body function Receives owner, private directory and stream observations.
local function with_files(name, body)
	local previous, original_open = package.loaded[name], io.open
	local Writer = require("infra.regular_file_writer")
	local original_writer = Writer.open
	local dir = os.tmpname()
	assert(os.remove(dir)); assert(Shell.run("mkdir " .. Shell.quote(dir)))
	package.loaded[name] = nil
	local owner = require(name)
	local state = { handles = {}, closes = 0 }
	function state.read(path)
		local file = assert(original_open(path, "rb"))
		local text = assert(file:read("*a")); assert(file:close())
		return text
	end
	function state.fault(kind)
		local wrapped = {}
		local function wrap(stream, reason, errno, cleanup)
			if not stream or wrapped[stream] then return stream, reason, errno, cleanup end
			local record = { stream = stream, closed = false }
			state.handles[#state.handles + 1] = record
			local proxy = {
				write = function(_, text)
					assert(stream:write(kind:match("^write_") and text:sub(1, 7) or text))
					if kind == "write_throw" then error("controlled partial write") end
					if kind == "write_nil" then return nil, "controlled full device" end
					if kind == "write_false" then return false, "controlled refused write" end
					return stream
				end,
				close = function()
					state.closes = state.closes + 1
					assert(stream:close()); record.closed = true
					if kind == "close_throw" then error("controlled buffered close") end
					if kind == "close_nil" then return nil, "controlled close failure" end
					if kind == "close_false" then return false, "controlled refused close" end
					return true
				end,
			}
			wrapped[proxy] = true
			return proxy, reason, errno, cleanup
		end
		io.open = function(path, mode)
			if type(path) == "string" and path:sub(1, #dir + 1) == dir .. "/"
				and (mode == "w" or mode == "wb") then return wrap(original_open(path, mode)) end
			return original_open(path, mode)
		end
		Writer.open = function(path, mode)
			if type(path) == "string" and path:sub(1, #dir + 1) == dir .. "/" then
				return wrap(original_writer(path, mode))
			end
			return original_writer(path, mode)
		end
	end
	function state.restore() io.open, Writer.open = original_open, original_writer end
	local ok, detail = xpcall(function() body(owner, dir, state) end, debug.traceback)
	state.restore()
	for _, record in ipairs(state.handles) do
		if not record.closed then record.stream:close() end
	end
	if name == "modules.llm.agent_connectors" then pcall(owner.shutdown) end
	package.loaded[name] = previous
	assert(Shell.run("rm -rf -- " .. Shell.quote(dir)))
	if not ok then error(detail, 0) end
end

helpers.describe("agent file completion receipts", function()
	for _, fault in ipairs(FAULTS) do
		helpers.it("(agent-file-receipts) learning preserves its committed source on " .. fault, function()
			with_files("modules.llm.agent_learning", function(Learning, dir, state)
				local path = dir .. "/learning.json"
				local original = '{"version":1,"apps":{"Mail":{"used":1,"thresholds":{"calendar":0.7}}}}'
				local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
				local config = { system1 = { threshold = 0.7 },
					learning = { step = 0.05, min_threshold = 0.1, max_threshold = 0.95 } }
				Learning._reset_for_test({ path = path, scheduler = {
					after = function() return { armed = true } end, cancel = function() return true end,
				} })
				helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), 0.7)
				local learned = Learning.record(config, "Mail", "calendar", true)
				state.fault(fault)
				local called, saved = pcall(Learning.flush)
				state.restore()
				helpers.assert_true(called, "native write/close refusal is a failed save, not an exception")
				helpers.assert_eq(saved, false)
				helpers.assert_eq(state.closes, 1, "every acquired stream is closed after its write result")
				helpers.assert_eq(state.read(path), original, "partial staging bytes never replace the valid state")
				helpers.assert_eq(Learning.threshold(config, "Mail", "calendar"), learned, "the pending learning survives")
				helpers.assert_true(Learning.flush(), "a healthy later save can publish the retained learning")
				helpers.assert_eq(assert(Json.decode(state.read(path))).apps.Mail.thresholds.calendar, learned)
			end)
		end)

		helpers.it("(agent-file-receipts) calendar refuses desktop handoff on " .. fault, function()
			with_files("modules.llm.agent_connectors", function(Connector, dir, state)
				local starts, completed, directories, payload = 0, {}, 0, nil
				Connector._set_deps_for_test({
					private_dir = function()
						directories = directories + 1
						local path = dir .. "/calendar" .. directories
						assert(Shell.run("mkdir " .. Shell.quote(path))); return path
					end,
					random_hex = function() return "00ff" end,
					utc_stamp = function() return "20261023T120000Z" end,
					run = function(executable, args, _, callback)
						starts = starts + 1
						helpers.assert_eq(executable, "xdg-open")
						payload = state.read(args[1])
						callback({ ok = true, code = 0 }); return {}
					end,
				})
				local file = assert(io.open(helpers.driver_root() .. "/../_shared/modules/llm/agent.json", "r"))
				local config = assert(Json.decode(file:read("*a"))); assert(file:close())
				local action = { type = "reminder", title = "Owned reminder" }
				local function done(accepted) completed[#completed + 1] = accepted end
				state.fault(fault)
				local called, started = pcall(Connector.run, config, action, done)
				state.restore()
				helpers.assert_true(called, "stream failure becomes the connector's explicit refusal")
				helpers.assert_eq(started, false)
				helpers.assert_eq(state.closes, 1)
				helpers.assert_eq(starts, 0, "an incomplete calendar never reaches a desktop launcher")
				helpers.assert_eq(completed, { false }, "one failed action receipt")
				helpers.assert_true(Connector.run(config, action, done), "the following healthy action still runs")
				helpers.assert_eq(starts, 1)
				helpers.assert_eq(completed, { false, true })
				helpers.assert_contains(payload, "BEGIN:VTODO")
				helpers.assert_contains(payload, "SUMMARY:Owned reminder")
			end)
		end)
	end
end)

helpers.describe("exclusive staging native cleanup", function()
	for _, field in ipairs({ "dev", "ino" }) do
		for _, value in ipairs({ -2 ^ 63, -1, 0.5 }) do
			helpers.it("(agent-learning-staging) rejects " .. field .. " identity " .. tostring(value), function()
				with_files("infra.regular_file_writer", function(Writer, dir, state)
					local uv = require("luv")
					local fstat, lstat = uv.fs_fstat, uv.fs_lstat
					local path = dir .. "/exclusive.tmp"
					local function claimed(query, candidate)
						local attrs = query(candidate)
						if attrs then attrs.dev, attrs.ino = 9, 7; attrs[field] = value end
						return attrs
					end
					uv.fs_fstat = function(fd) return claimed(fstat, fd) end
					uv.fs_lstat = function(candidate) return claimed(lstat, candidate) end
					local okay, detail = xpcall(function()
						local file, _, _, cleanup = Writer.open(path, "wx")
						assert(file); assert(file:write("owned")); assert(file:close())
						assert(os.rename(path, dir .. "/retained"))
						local successor = assert(io.open(path, "wb")); assert(successor:write("borrowed successor")); assert(successor:close())
						helpers.assert_eq(cleanup(), false, "only nonnegative exact integer identifiers authorize cleanup")
						helpers.assert_eq(state.read(path), "borrowed successor")
						helpers.assert_eq(state.read(dir .. "/retained"), "owned")
					end, debug.traceback)
					uv.fs_fstat, uv.fs_lstat = fstat, lstat
					if not okay then error(detail, 0) end
				end)
			end)
		end
	end
	for _, mode in ipairs({ "w", "a" }) do
		for _, receipt in ipairs({ "healthy", "refused" }) do
			helpers.it("(agent-learning-staging) preserves arity of " .. mode .. " " .. receipt, function()
				with_files("infra.regular_file_writer", function(Writer, dir)
					local open = io.open
					if receipt == "refused" then
						io.open = function(path, stream_mode)
							if path:match("^/proc/self/fd/%d+$") then return nil, "controlled stream refusal", 13 end
							return open(path, stream_mode)
						end
					end
					local function counted(...) return select("#", ...), ... end
					local count, file, detail, errno = counted(Writer.open(dir .. "/legacy", mode))
					io.open = open
					if file then assert(file:write("healthy")); assert(file:close()) end
					helpers.assert_eq(count, 3, "legacy modes retain their exact public return contract")
					if receipt == "healthy" then helpers.assert_true(file ~= nil)
					else helpers.assert_nil(file); helpers.assert_eq(detail, "controlled stream refusal"); helpers.assert_eq(errno, 13) end
				end)
			end)
		end
	end
	helpers.it("(agent-learning-staging) refuses cleanup from rounded inode identities", function()
		with_files("infra.regular_file_writer", function(Writer, dir, state)
			local uv = require("luv")
			local fstat, lstat = uv.fs_fstat, uv.fs_lstat
			local path = dir .. "/exclusive.tmp"
			local function rounded(query, value)
				local attrs = query(value)
				if attrs then attrs.ino = 2 ^ 53 end
				return attrs
			end
			uv.fs_fstat = function(fd) return rounded(fstat, fd) end
			uv.fs_lstat = function(candidate) return rounded(lstat, candidate) end
			local okay, detail = xpcall(function()
				local file, _, _, cleanup = Writer.open(path, "wx")
				assert(file); assert(file:write("owned")); assert(file:close())
				assert(os.rename(path, dir .. "/retained"))
				local successor = assert(io.open(path, "wb")); assert(successor:write("borrowed successor")); assert(successor:close())
				helpers.assert_eq(cleanup(), false, "a rounded native identifier cannot prove ownership")
				helpers.assert_eq(state.read(path), "borrowed successor")
				helpers.assert_eq(state.read(dir .. "/retained"), "owned")
			end, debug.traceback)
			uv.fs_fstat, uv.fs_lstat = fstat, lstat
			if not okay then error(detail, 0) end
		end)
	end)
	for _, backend in ipairs(jit and { "luv", "ffi" } or { "luv" }) do
		for _, failure in ipairs({ "stream_nil", "stream_false", "stream_throw", "close_nil", "close_false", "close_throw", "stream_successor", "close_successor" }) do
			helpers.it("(agent-learning-staging) settles " .. backend .. " " .. failure, function()
				with_files("infra.regular_file_writer", function(Writer, dir, state)
					local uv = require("luv")
					local previous_uv, previous_ffi = package.loaded.luv, package.loaded.ffi
					local open, uv_close = io.open, uv.fs_close
					local path, retained = dir .. "/exclusive.tmp", dir .. "/retained"
					local fault = true
					local function replace()
						assert(os.rename(path, retained))
						local file = assert(open(path, "wb")); assert(file:write("borrowed successor")); assert(file:close())
					end
					local function refuse()
						if failure:match("_throw$") then error("controlled native boundary refusal") end
						if failure:match("_false$") then return false end
						return nil
					end
					local function settle_close(close, fd, ffi_backend)
						local closed = close(fd)
						if fault and failure:match("^close_") then
							assert(ffi_backend and closed == 0 or not ffi_backend and closed == true)
							if failure == "close_successor" then replace() end
							if ffi_backend and not failure:match("_throw$") then return -1 end
							return refuse()
						end
						return closed
					end
					if backend == "luv" then
						uv.fs_close = function(fd) return settle_close(uv_close, fd, false) end
					else
						local ffi = require("ffi")
						pcall(ffi.cdef, "int close(int fd);")
						local native_close = ffi.C.close
						local calls = setmetatable({ close = function(fd) return settle_close(native_close, fd, true) end }, { __index = ffi.C })
						package.loaded.luv = {}
						package.loaded.ffi = setmetatable({ C = calls }, { __index = ffi })
					end
					io.open = function(candidate, mode)
						if fault and candidate:match("^/proc/self/fd/%d+$") then
							helpers.assert_eq(mode, "w", "exclusive creation reopens its pinned fd using portable stdio")
							if failure:match("^stream_") then
								if failure == "stream_successor" then replace() end
								return refuse()
							end
						end
						return open(candidate, mode)
					end
					local okay, detail = xpcall(function()
						local called, stream = pcall(Writer.open, path, "wx")
						helpers.assert_true(called)
						helpers.assert_nil(stream)
						fault = false
						if failure:match("_successor$") then
							helpers.assert_eq(state.read(path), "borrowed successor", "cleanup cannot unlink a borrowed inode")
							helpers.assert_eq(state.read(retained), "", "the actual created inode is never confused with its successor")
							assert(os.remove(path))
						else helpers.assert_eq(Shell.run("test -e " .. Shell.quote(path)), false, "failed creation leaves no owned orphan") end
						local file, _, _, cleanup = Writer.open(path, "wx")
						helpers.assert_true(file ~= nil, "healthy retry can acquire a new staging inode")
						assert(file:write("healthy")); assert(file:close())
						helpers.assert_eq(state.read(path), "healthy")
						helpers.assert_true(type(cleanup) == "function")
						helpers.assert_true(cleanup())
						helpers.assert_eq(Shell.run("test -e " .. Shell.quote(path)), false)
					end, debug.traceback)
					io.open, uv.fs_close = open, uv_close
					package.loaded.luv, package.loaded.ffi = previous_uv, previous_ffi
					if not okay then error(detail, 0) end
				end)
			end)
		end
	end
end)

helpers.describe("agent learning staging ownership", function()
	for _, kind in ipairs({ "fifo", "regular-symlink", "hardlink", "regular", "directory", "missing" }) do
		helpers.it("(agent-learning-staging) preserves " .. kind .. " and retries after repair", function()
			local folder = os.tmpname()
			assert(os.remove(folder)); assert(Shell.run("mkdir -m 700 -- " .. Shell.quote(folder)))
			local okay, detail = xpcall(function()
				local fixture = helpers.driver_root() .. "/tests/fixtures/native_agent_learning_source.lua"
				local executable = assert(arg and arg[-1])
				helpers.assert_true(Shell.run("timeout --kill-after=2 5 " .. Shell.quote(executable)
					.. " " .. Shell.quote(fixture) .. " " .. Shell.quote(folder) .. " " .. Shell.quote(kind) .. " flush"),
					"staging admission must return without waiting or destroying another file")
				helpers.assert_eq(state_read_for_fixture(folder .. "/complete"), "complete")
			end, debug.traceback)
			for _, leaf in ipairs({ "source", "source.tmp", "target", "complete" }) do os.remove(folder .. "/" .. leaf) end
			assert(os.remove(folder), "every owned fixture entry must be removed")
			if not okay then error(detail, 0) end
		end)
	end

	for _, refusal in ipairs({ "nil", "false", "throw" }) do
		helpers.it("(agent-learning-staging) retries after rename " .. refusal, function()
			with_files("modules.llm.agent_learning", function(Learning, dir, state)
				local path, rename = dir .. "/learning.json", os.rename
				local original = '{"version":1,"apps":{}}'
				local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
				local config = { system1 = { threshold = 0.7 }, learning = { step = 0.05, min_threshold = 0.1, max_threshold = 0.95 } }
				Learning._reset_for_test({ path = path, scheduler = {
					after = function() return { armed = true } end, cancel = function() return true end,
				} })
				local learned = Learning.record(config, "Mail", "calendar", true)
				os.rename = function(from, to)
					if from == path .. ".tmp" then
						if refusal == "throw" then error("controlled rename exception") end
						if refusal == "false" then return false, "controlled rename refusal" end
						return nil, "controlled rename refusal"
					end
					return rename(from, to)
				end
				local called, saved = pcall(Learning.flush)
				os.rename = rename
				helpers.assert_true(called, "rename failure is an explicit failed save")
				helpers.assert_eq(saved, false)
				helpers.assert_eq(state.read(path), original)
				helpers.assert_eq(Shell.run("test -e " .. Shell.quote(path .. ".tmp")), false, "only our failed staging is removed")
				helpers.assert_true(Learning.flush())
				helpers.assert_eq(assert(Json.decode_lossless(state.read(path))).apps.Mail.thresholds.calendar, learned)
			end)
		end)
	end
end)
