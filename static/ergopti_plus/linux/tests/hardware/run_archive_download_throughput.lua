--- tests/hardware/run_archive_download_throughput.lua

--- ==============================================================================
--- MODULE: Owned Archive Download Throughput
--- DESCRIPTION:
--- Times the Ollama archive download path on a loopback HTTP server: the
--- production curl transport, archive output lease and event loop, the daemon's
--- idle wait on a quiet input source, and the runtime source fence
--- (runtime_source, ai.engine.preferences, install_admission, install_resolver)
--- re-admitting each chunk. Only the RAM owners above that fence (the repair,
--- phase and installer predicates, the engine and profile state) are stubs,
--- each answering as its production counterpart does while nothing changes.
---
--- USAGE (Linux, LuaJIT, luv, curl, python3; from the driver root):
---     HOME=<private dir> luajit tests/hardware/run_archive_download_throughput.lua [MiB] [revoke]
--- HOME must be a directory only its owner can write: the install resolver
--- refuses a shared ancestor, as it does in production. The configuration is
--- written, then left quiet for 4 s, so the preference reader's change token
--- stands for its bytes when the download starts (ai/engine/preferences.lua).
--- `revoke` then picks another model by rewriting config.toml in place, with
--- the same size, once a quarter of the body is written: the edit only the
--- token's change time can see. It asserts the download stops before the next
--- chunk lands.
--- ==============================================================================

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = assert(self_path:match("^(.*)/tests/hardware/[^/]+$")
	or self_path:match("^tests/hardware/[^/]+$") and ".", "run from the driver tree")
package.path = table.concat({ driver_root .. "/?.lua", driver_root .. "/?/init.lua",
	driver_root .. "/../_shared/?.lua", driver_root .. "/../_shared/?/init.lua", package.path }, ";")

local MIB = 1024 * 1024
local total_mib = tonumber(arg[1] or "64")
local revoke = arg[2] == "revoke"
assert(total_mib and total_mib > 0 and total_mib % 1 == 0, "the size is a whole number of MiB")
local total = total_mib * MIB

local uv = require("luv")
local Paths = require("settings.engine.paths")
local KEY = require("settings.engine.keys").KEY
local Writer = require("core.text.engine.toml_codec.writer")
local Clock = require("core.logger.engine.monotonic")
local config = Paths.config("config.toml")

--- Runs a shell command; LuaJIT answers 0 and Lua 5.2+ true on success.
--- @param command string
local function shell(command)
	local result = os.execute(command)
	assert(result == true or result == 0, "command failed: " .. command)
end

--- Writes the configuration the download is admitted against.
--- @param model string Selected Ollama model.
local function write_config(model)
	local handle = assert(io.open(config, "wb"))
	assert(handle:write("[llm]\nenabled = false\n\n[llm.models]\nselected = \"ollama\"\nollama = \"" .. model .. "\"\n"))
	assert(handle:close())
end

--- Picks another model of the same length in place: same inode, same size.
local function edit_config_in_place()
	local handle = assert(io.open(config, "r+b"))
	local bytes = handle:read("*a")
	local at = assert(bytes:find("bench-model", 1, true), "the bench model is configured")
	assert(handle:seek("set", at - 1))
	assert(handle:write("bench-mode2"))
	assert(handle:close())
end
shell("mkdir -p -m 700 '" .. config:match("^(.*)/[^/]+$") .. "'")
write_config("bench-model")

-- The corpus and its server: an independent process, as a real mirror is.
local work = assert(uv.fs_mkdtemp(os.getenv("HOME") .. "/archive-bench-XXXXXX"))
local corpus = work .. "/archive.bin"
shell("head -c " .. total .. " /dev/urandom > '" .. corpus .. "'")
local server_script = [[
import http.server, sys, functools
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
handler = functools.partial(Quiet, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
print(server.server_address[1], flush=True)
server.serve_forever()
]]
local server_out = assert(uv.new_pipe(false))
local server = uv.spawn("python3", { args = { "-c", server_script, work }, stdio = { nil, server_out, nil } },
	function() end)
assert(server, "python3 is required for the loopback server")
local port
assert(uv.read_start(server_out, function(_, chunk)
	if chunk and not port then port = tonumber(chunk:match("(%d+)")) end
end))
while not port do uv.run("once") end
uv.read_stop(server_out)

-- Counters on the source fence: every read of config.toml and every ancestor walk.
local config_reads, config_us = 0, 0
local read_classified = Writer.read_classified
Writer.read_classified = function(path, ...)
	if path ~= config then return read_classified(path, ...) end
	local started = uv.hrtime()
	local a, b, c = read_classified(path, ...)
	config_reads, config_us = config_reads + 1, config_us + (uv.hrtime() - started) / 1e3
	return a, b, c
end

-- The production source owner over RAM stand-ins for the engine and profiles.
local origin = "http://127.0.0.1:11434"
local native_state = { paused = false, blocked = false, revision = 1, app_epoch = 1, enabled = false,
	backend = "ollama", origin = origin, model = "bench-model" }
local source = require("ai.engine.local_servers.runtime_source").new({
	preferences = require("ai.engine.preferences"),
	profiles = { enable = function() return false end, disable = function() return false end,
		is_enabled = function() return false end },
	writer = Writer, manifest = require("menu.engine.manifest_reader"),
	engine = { state = function()
		local copy = {}
		for key, value in pairs(native_state) do copy[key] = value end
		return copy
	end, publish_enabled = function() return false end, restore_disabled = function() return false end,
		admit_write = function() return false end },
	backend_key = KEY.LLM_MODELS_SELECTED, path = config,
})
local snapshot = assert(source.capture(), "the source fence refuses the bench configuration")

local resolver = assert(require("ai.engine.ollama.install_resolver").new())
local resolver_checks, resolver_current = 0, resolver.current
resolver.current = function(...)
	resolver_checks = resolver_checks + 1
	return resolver_current(...)
end
-- runtime_repair.current: its entry and budget are RAM; the source is not.
local function repair_current() return source.current(snapshot) == true end
local files = assert(require("ai.engine.ollama.install_admission").new(resolver,
	require("ai.engine.ollama.install_files"), repair_current, true))
-- install_phase.current, then archive_installer.current around it.
local function phase_current() return repair_current() and files.current() == true end
local function installer_current()
	local ok, allowed = pcall(phase_current)
	return ok and allowed == true
end

local Output = require("infra.archive_output")
local Target = require("core.network.engine.http_output_target")
local Http = require("core.network.adapters.http_client")
local EventLoop = require("core.events.loop")
local EvdevReader = require("platform.input.evdev_reader")

local deadline = Clock.now_ms() + 900000
local owner = {}
local output_dir = assert(uv.fs_mkdtemp(work .. "/out-XXXXXX"))
-- archive_output's pinned artifact: its master budget (RAM), then the phase.
local lease = assert(Output.native().reserve(output_dir, owner, function(exact)
	return exact == owner and installer_current()
end, deadline), "archive output lease refused")
local ticket = assert(lease:begin())
local target = assert(Target.create(lease, ticket))

-- A quiet keyboard: the daemon's idle wait sleeps on it, as on an idle desktop.
local fifo = work .. "/keyboard"
shell("mkfifo '" .. fifo .. "'")
assert(EvdevReader.use_ffi_backend() and EvdevReader.open(fifo, EvdevReader.KEYBOARD))
local keep_open = assert(uv.fs_open(fifo, "w", 438))

local chunks, written = 0, 0
local native_write = uv.fs_write
uv.fs_write = function(fd, chunk, offset, callback)
	if type(callback) ~= "function" then return native_write(fd, chunk, offset, callback) end
	return native_write(fd, chunk, offset, function(err, count)
		if count then chunks, written = chunks + 1, written + count end
		if revoke and written >= total / 4 and not native_state.revoked then
			native_state.revoked, native_state.revoked_at = true, written
			edit_config_in_place() -- An external edit: the user picked another model.
		end
		return callback(err, count)
	end)
end

-- Quiet past the reader's QUIET_SECONDS, so the download runs on the token.
uv.sleep(4000)

local result
local started = uv.hrtime()
local operation = Http.download_output_owned("http://127.0.0.1:" .. port .. "/archive.bin", {}, target, {
	owner = "archive-throughput", authorized = installer_current, absolute_deadline_ms = deadline,
	follow_redirects = true, https_only = false, max_download_bytes = total, timeout_ms = 900000,
}, function(value) result = value end)
assert(operation and operation.started, "the owned download did not start")

EventLoop.run({
	-- A revoked download publishes no result (its source is no longer current):
	-- its physical settlement alone ends the run.
	onIdle = function()
		if (result or revoke) and operation:is_settled() then EventLoop.stop() end
	end,
	-- As the daemon's: the loop's own companion joins the input sources.
	idleWait = function(timeout_ms, loop_companion)
		return EvdevReader.wait_any_readable(timeout_ms, loop_companion and { loop_companion } or nil)
	end,
})
local seconds = (uv.hrtime() - started) / 1e9
local counts = require("core.logger.engine.perf_counters").snapshot().counts
uv.fs_write = native_write
Writer.read_classified = read_classified

lease:cancel()
while not lease:is_settled() do uv.run("once") end
uv.fs_close(keep_open)
EvdevReader.close(EvdevReader.KEYBOARD)
uv.process_kill(server, "sigterm")
uv.close(server_out)
while uv.loop_alive() do uv.run("once") end
os.execute("rm -rf '" .. work .. "'")

local per_chunk = math.max(chunks, 1)
print(string.format("bytes=%d chunks=%d seconds=%.2f throughput=%.1f MB/s", written, chunks, seconds,
	written / 1e6 / seconds))
print(string.format("full config reads=%d (%.1f per chunk, %.0f us per chunk) resolver_checks=%d (%.1f per chunk)",
	config_reads, config_reads / per_chunk, config_us / per_chunk, resolver_checks, resolver_checks / per_chunk))
print(string.format("idle waits: %d ended by a descriptor, %d timed out, %d skipped on request",
	counts["loop.idle_wakes_input"] or 0, counts["loop.idle_timeouts"] or 0, counts["loop.idle_wakes_requested"] or 0))
print(string.format("result ok=%s status=%s error=%s", tostring(result and result.ok), tostring(result and result.status),
	tostring(result and result.error)))
if revoke then
	assert(native_state.revoked, "the body ended before the edit")
	assert(not (result and result.ok), "the download completed after its source changed")
	assert(written <= native_state.revoked_at + 65536,
		"more than one chunk landed after the edit: " .. (written - native_state.revoked_at) .. " bytes")
	print(string.format("REVOKED after %d bytes; %d bytes landed after the edit", native_state.revoked_at,
		written - native_state.revoked_at))
else
	assert(result and result.ok == true and written == total, "the download did not complete")
end
