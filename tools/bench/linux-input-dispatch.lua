-- tools/bench/linux-input-dispatch.lua
-- Report-only latency probe of one physical keystroke on the Linux driver.
-- Run from the driver root under Linux LuaJIT:
--   cd static/ergopti_plus/linux
--   luajit ../../../tools/bench/linux-input-dispatch.lua [keys] [admitted|unjoined]
-- The REAL main() boots with every shipped hotstring category on and tap-holds
-- off, then each key (MSC_SCAN, EV_KEY, SYN_REPORT, down then up) goes through
-- the REAL keyboard hook reader and dispatch into the daemon's own callbacks.
-- Only the operating-system edges are doubles: evdev bytes, uinput, the output
-- layout, the window query and the accessibility worker. Focus scenarios:
--   admitted  an ordinary field whose worker answers every request at once;
--   unjoined  the real focus watcher over a worker that is alive (heartbeats)
--             but answers no admission request in time, on a desktop without
--             a window query (KDE Wayland), so no field context is ever joined.
-- HOME and the XDG directories are redirected to a scratch folder, so the run
-- never touches the user's configuration, logs or metrics store.
package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;" .. package.path
assert(io.open("ergopti_hotstrings.lua", "rb"), "run from static/ergopti_plus/linux")
local KEYS = tonumber(arg[1]) or 300
local FOCUS = arg[2] or "admitted"
assert(FOCUS == "admitted" or FOCUS == "unjoined", "focus scenario must be admitted or unjoined")

local scratch = os.tmpname()
os.remove(scratch)
assert(os.execute("mkdir -p '" .. scratch .. "'"), "scratch home not created")
local native_getenv = os.getenv
os.getenv = function(name)
	if name == "HOME" then return scratch end
	if type(name) == "string" and name:match("^XDG_") then return nil end
	return native_getenv(name)
end

local luv = require("luv")
local function now_ms() return luv.hrtime() / 1e6 end
local function percentile(sorted, fraction) return sorted[math.max(1, math.ceil(#sorted * fraction))] end

-- Every shipped category on, as the menu's "enable every category" writes it.
local Paths = require("settings.engine.paths")
local original_config = Paths.config
local config_path = scratch .. "/config.toml"
local template = assert(io.open("_generated/config_template.toml", "rb"))
local config_file = assert(io.open(config_path, "wb"))
assert(config_file:write(template:read("*a")))
config_file:close()
template:close()
Paths.config = function(relative)
	if relative == "config.toml" then return config_path end
	return original_config(relative)
end
arg = { "--device", "/dev/null", "--config", "../_shared/hotstrings/data/catalogue" }

-- Output edges: a controlled layout and uinput writer, never a native device.
local code_of, next_code = {}, 256
package.preload["adapters.keyboard_layout"] = function()
	return require("tests.support.layout_cohort_fixture").layout(function(char)
		if not code_of[char] then code_of[char], next_code = next_code, next_code + 1 end
		return code_of[char]
	end)
end
package.preload["platform.input.uinput_writer"] = function()
	return require("tests.fakes").uinput_writer({ on_emit = function() return true end })
end
for _, name in ipairs({ "core.ui.ui.tooltip.preview", "core.ui.ui.tooltip.llm", "tray.adapters.menu",
	"menu.ui.builder.builder", "core.process.adapters.lifecycle", "core.ui.ui.webview_manager",
	"core.fs.engine.file_watchers", "ui.wpm.widget", "modules.keystats.system.system_metrics",
	"platform.system.notifier", "ai.engine.prediction.engine" }) do
	package.preload[name] = function() error("disabled for the dispatch benchmark") end
end
package.preload["platform.focus.secure_field_detector"] = function()
	return {
		invalidateFocus = function() return 1 end, publishFocus = function() return true end,
		refresh = function() return true, "insecure" end, isSecureField = function() return false end,
		getVerdict = function() return "insecure" end, currentEpoch = function() return 1 end,
		isSecureApp = function() return false end, isUrlBar = function() return false end,
	}
end
package.preload["platform.focus.window_info"] = function()
	local function info() return { appId = "bench-editor", windowTitle = "bench-field", bundleId = "", executablePath = "" } end
	return {
		getFocused = info,
		focused_snapshot = function() return info(), "bench-window" end,
		start_privacy_context = function(_, options, callback)
			if FOCUS == "unjoined" then return nil end
			if options.authorized() then
				callback({ app_id = "bench-editor", title = "bench-field", native_identity = "bench-window" })
			end
			return { is_settled = function() return true end, cancel = function() return true end }
		end,
		focused_identity = function() return "bench-window" end,
		focused_text_identity = function() return "bench-text-field" end,
		metrics_sources = function() return {} end,
	}
end

-- The accessibility worker: requests are counted in both scenarios.
local requests, counting = 0, false
if FOCUS == "admitted" then
	package.preload["platform.focus.atspi_focus_watch"] = function()
		local Fixture = require("tests.support.focus_watch_fixture")
		return { new = function()
			local watcher = Fixture.new()
			local barrier = watcher.barrier
			watcher.barrier = function(...)
				if counting then requests = requests + 1 end
				return barrier(...)
			end
			return watcher
		end }
	end
else
	local Json = require("core.text.engine.json")
	local Watch = require("platform.focus.atspi_focus_watch")
	local native_new = Watch.new
	Watch.new = function(options)
		local sequence, last_frame, ready = 0, nil, false
		local function frame(kind)
			sequence, last_frame = sequence + 1, now_ms()
			return Json.encode({ kind = kind, sequence = sequence, request = 0, at_ms = last_frame }) .. "\n"
		end
		local transport = {}
		function transport.command() return "luajit", {} end
		function transport.close() return true end
		function transport.cleanup() return true end
		function transport.request()
			if counting then requests = requests + 1 end
			return true
		end
		function transport.read()
			if not ready then ready = true; return frame("ready") end
			-- The worker's heartbeat cadence keeps its receipts fresh.
			if now_ms() - last_frame >= 250 then return frame("heartbeat") end
			return nil, "again"
		end
		local operation = { started = true }
		function operation:is_running() return true end
		function operation:is_settled() return true end
		function operation:on_settled() end
		function operation:cancel() return true end
		options = options or {}
		options.create_transport = function() return transport end
		options.start_process = function() return operation end
		return native_new(options)
	end
end

local hook = require("platform.input.keyboard_hook")
local callbacks = nil
hook.start = function(options)
	callbacks = options
	assert(require("hotstrings.engine.catalogue.config").enable_all(), "every category must be enabled")
end
hook.isRunning = function() return true end
hook.get_mode = function() return "intercept" end
hook.emergency_stop = function(why) error("emergency stop: " .. tostring(why)) end
hook.pump = function() return 0 end

-- QWERTY evdev codes of the typed sentence.
local CODES = { a = 30, b = 48, c = 46, d = 32, e = 18, f = 33, g = 34, h = 35, i = 23, j = 36, k = 37, l = 38,
	m = 50, n = 49, o = 24, p = 25, q = 16, r = 19, s = 31, t = 20, u = 22, v = 47, w = 17, x = 45, y = 21, z = 44,
	[" "] = 57 }
local TEXT = "the quick brown fox jumps over the lazy dog "

package.preload["core.events.loop"] = function()
	local adapter = dofile("core/events/loop.lua")
	local native_run = adapter.run
	adapter.run = function(loop)
		loop.onPeriodic()
		adapter._run_idle_tick()
		local drive = {
			onChar = callbacks.onChar, onKey = callbacks.onKey, onPhysical = callbacks.onPhysical,
			onHold = callbacks.onHold, onConsume = callbacks.onConsume,
			onHeldModifierKey = callbacks.onHeldModifierKey, onEmitRaw = function() return true end,
		}
		local samples = {}
		counting = true
		for index = 1, KEYS do
			local position = (index - 1) % #TEXT + 1
			local code = CODES[TEXT:sub(position, position)]
			local started = now_ms()
			hook._test_drive({
				{ type = 4, code = 4, value = code }, { type = 1, code = code, value = 1 }, { type = 0, code = 0, value = 0 },
				{ type = 4, code = 4, value = code }, { type = 1, code = code, value = 0 }, { type = 0, code = 0, value = 0 },
			}, drive, true)
			samples[#samples + 1] = now_ms() - started
		end
		counting = false
		table.sort(samples)
		print(string.format("focus=%s keys=%d per key (down+up, ms): p50=%.3f p95=%.3f max=%.3f; worker requests per key=%.2f",
			FOCUS, KEYS, percentile(samples, 0.5), percentile(samples, 0.95), samples[#samples], requests / KEYS))
		local signals = require("core.lifecycle.engine.shutdown.signal_handlers")
		if not signals.is_settled() then
			luv.kill(luv.os_getpid(), "sigterm")
			native_run(loop)
		end
	end
	return adapter
end

local ran, failure = pcall(dofile, "ergopti_hotstrings.lua")
os.execute("rm -rf '" .. scratch .. "'")
os.getenv = native_getenv
assert(ran, failure)
