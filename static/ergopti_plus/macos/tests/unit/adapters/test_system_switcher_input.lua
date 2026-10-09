--- tests/unit/adapters/test_system_switcher_input.lua

--- Executes actual input and sampler owners with controlled Quartz/task boundaries.
local helpers = require("tests.helpers")
local eq = helpers.assert_eq
local function with_input(body, setup)
	local names = { "adapters.system_switcher_input", "adapters.system_switcher_sampler",
		"adapters.timer_scheduler", "modules.gestures.native_app_switcher", "adapters.synthetic_input",
		"adapters.window_manager", "adapters.storage", "infra.logger", "infra.timings",
		"modules.gestures.native_app_switcher_action", "adapters.system_switcher_runtime" }
	local saved, old_hs = {}, hs
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local path = os.tmpname()
	local out = assert(io.open(path, "wb")); assert(out:write("owned helper")); assert(out:close())
	local f = { timers = {}, tasks = {}, posts = {}, frames = {}, hid = {}, session = {},
		front = 10, time = 1, source = true, tap_ack = true, timer_ack = true,
		release_ack = true, access = true, digest = string.rep("a", 64), tags = 0, lease_count = 0 }
	local function flags(held)
		local result = 0
		for key in pairs(held) do
			if key == 54 or key == 55 then result = result | 0x100000
			elseif key == 56 or key == 60 then result = result | 0x20000
			elseif key == 58 or key == 61 then result = result | 0x80000
			elseif key == 59 or key == 62 then result = result | 0x40000 end
		end
		return result
	end
	local function frame(request)
		local held = {}; for key in pairs(f.session) do held[#held + 1] = key end
		local hid = {}; for key in pairs(f.hid) do hid[#hid + 1] = key end
		return { version = 1, request = request, source = "hid_system", held = hid, flags = f.hid_flags or flags(f.hid),
			listen_access = f.listen ~= false, post_access = f.post_access ~= false, ax_trusted = f.access,
			session = { version = 1, request = request, source = "combined_session", held = held, flags = f.session_flags or flags(f.session) } }
	end
	local scheduler = {
		every = function(_, fn)
			if f.timer_throw then error("uncertain timer acquisition") end
			local timer = { fn = fn, running = true }; f.timers[#f.timers + 1] = timer
			return timer, true
		end,
		cancel = function(timer)
			if not f.timer_ack then return false end
			timer.running = false; return true
		end,
		awake_time = function() return f.time end,
	}
	local native = {
		processInfo = { processID = 99 }, accessibilityState = function() return f.access end,
		fs = { symlinkAttributes = function(p)
			if p ~= path or f.pin_revoked then return nil end
			return { mode = "file", dev = 1, ino = 2 }
		end }, hash = { SHA256 = function(bytes) return bytes == "owned helper" and f.digest or "changed" end },
		json = { decode = function(raw) return f.frames[raw] end }, task = {}, eventtap = { event = {} },
	}
	native.task.new = function(p, callback, args)
		eq(p, path)
		local task = { request = tonumber(args[1]), callback = callback, running = false,
			env = { ERGOPTI_LOG_TOKEN = "controlled authority", PATH = "/usr/bin" } }
		function task:environment() return self.env end
		function task:setEnvironment(env) self.env = env; return self end
		function task:start()
			eq(self.env.ERGOPTI_LOG_TOKEN, nil); eq(self.env.PATH, "/usr/bin")
			self.running = true
			if f.start_refused then return false end
			return self
		end
		function task:isRunning() return self.running end
		function task:terminate() if not f.task_stuck then self.running = false end; return self end
		f.tasks[#f.tasks + 1] = task
		return task
	end
	local types = { flagsChanged = 1, keyDown = 2, keyUp = 3, otherMouseUp = 4,
		leftMouseUp = 5, rightMouseUp = 6 }
	local props = { eventSourceUserData = 1, eventSourceUnixProcessID = 2, eventSourceStateID = 3,
		mouseEventButtonNumber = 4 }
	native.eventtap.event.types, native.eventtap.event.properties = types, props
	native.eventtap.new = function(_, callback)
		local tap = { enabled = false, callback = callback }
		function tap:start() self.enabled = true; return self end
		function tap:isEnabled() return self.enabled end
		function tap:stop() if not f.tap_ack then return false end; self.enabled = false; return self end
		f.tap = tap; return tap
	end
	native.eventtap.event.newKeyEvent = function(key, down)
		local event = { key = key, down = down, props = { [2] = 99, [3] = f.created_source_id or -1 } }
		function event:setProperty(prop, value) self.props[prop] = value; return self end
		function event:getProperty(prop) return self.props[prop] end
		function event:getKeyCode() return self.key end
		function event:getType() return self.key == 55 and 1 or (self.down and 2 or 3) end
		function event:getFlags()
			if self.key == 55 then return { cmd = self.down } end
			return { cmd = f.session[55] == true }
		end
		function event:post()
			f.posts[#f.posts + 1] = { key = self.key, down = self.down, tag = self.props[1] }
			if self.down then f.session[self.key] = true else f.session[self.key] = nil end
			if f.keep_session and self.key == 55 and not self.down then f.session[55] = true end
			if f.spoof_pid then self.props[2] = 500 end
			if f.observed_source_id then self.props[3] = f.observed_source_id end
			if not f.no_observation then eq(f.tap.callback(self), false) end
			if f.post_refused then return false end
			return self
		end
		if f.construct_edge then f.construct_edge(event, key, down) end
		return event
	end
	function f.step(count)
		for _ = 1, count or 1 do
			for _, task in ipairs(f.tasks) do
				if task.running and not task.completed and not f.task_stuck then
					task.completed, task.running = true, false
					local key = tostring(task.request)
					local raw = frame(task.request)
					if f.alter_frame then f.alter_frame(raw) end
					f.frames[key] = raw; task.callback(0, key, "")
				end
			end
			local current = {}; for _, timer in ipairs(f.timers) do current[#current + 1] = timer end
			for _, timer in ipairs(current) do if timer.running then timer.fn() end end
			f.time = f.time + 0.02
		end
	end
	f.scheduler, f.native = scheduler, native
	f.descriptor = { path = path, sha256 = f.digest, dev = 1, ino = 2 }
	function f.actual_synthetic()
		native.eventtap.event.newMouseEvent = function() error("no mouse fallback") end
		native.timer = { absoluteTime = function() return 1000000000 end,
			secondsSinceEpoch = function() return 1 end,
			doAfter = function() error("no unowned timer") end,
			delayed = { new = function(_, callback)
				local handle = { callback = callback, active = false }
				function handle:start() self.active = true; return self end
				function handle:stop() self.active = false; return self end
				function handle:running() return self.active end
				return handle
			end } }
		native.mouse = { absolutePosition = function() return { x = 0, y = 0 } end }
		native.application = {}
		local store = {}
		package.loaded["adapters.storage"] = { get = function(key) return store[key] end,
			set = function(key, value) store[key] = value; return true end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.synthetic_input"] = nil
		return require("adapters.synthetic_input")
	end
	function f.action()
		f.actual_synthetic()
		package.loaded["adapters.system_switcher_runtime"] = { descriptor = function() return f.descriptor end }
		package.loaded["infra.timings"] = { sec = function(_, key)
			return key == "native_switcher_deadline_ms" and 8 or 0.02
		end }
		package.loaded["adapters.window_manager"] = { frontmost_pid = function() return f.front end }
		return require("modules.gestures.native_app_switcher_action")
	end
	if setup then setup(f) end
	package.loaded["adapters.timer_scheduler"] = scheduler
	_G.hs = native
	local ok, failure = xpcall(function()
		f.owner = assert(require("adapters.system_switcher_input").new(
			{ path = path, sha256 = f.digest, dev = 1, ino = 2 }, {
				acquire = function() f.lease_count = f.lease_count + 1; return {} end,
				tag = function() f.tags = f.tags + 1; return f.tags end,
				release = function() if f.release_ack then f.lease_count = f.lease_count - 1 end; return f.release_ack end,
			}, { poll_sec = 0.02 }))
		f.cap, f.received = {}, {}
		function f.prepare()
			return f.owner.prepare(f.cap, function(cap, ordinal)
				eq(cap, f.cap); f.received[#f.received + 1] = ordinal; return true
			end, function() return f.source end)
		end
		function f.edge(ordinal)
			eq(f.owner.post(f.cap, ordinal), true); f.step(3)
		end
		body(f)
	end, debug.traceback)
	_G.hs = old_hs
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	assert(os.remove(path))
	if not ok then error(failure, 0) end
end

local function foreign(f, key)
	local event = {}
	function event:getProperty(prop) return prop == 2 and 500 or 0 end
	function event:getKeyCode() return key or 56 end
	function event:getType() return 1 end
	function event:getFlags() return { shift = true, cmd = f.session[55] == true } end
	eq(f.tap.callback(event), false)
end

helpers.describe("native switcher intervening input and exact session state", function()
	helpers.it("invalidates a clear helper snapshot when foreign input precedes task receipt", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1)
			local sent = false
			f.alter_frame = function()
				if not sent then
					sent = true; f.hid[56], f.session[56] = true, true; foreign(f, 56)
				end
			end
			eq(f.owner.post(f.cap, 2), true); f.step(4)
			eq(sent, true); eq(#f.posts, 1); eq(f.owner.observed(f.cap, 2), false)
			eq(f.owner.retire(f.cap), false)
			f.alter_frame = nil; f.hid[56], f.session[56] = nil, nil
			f.step(8); eq(f.owner.retire(f.cap), true)
			eq(#f.posts, 2); eq(f.posts[2].key, 55); eq(f.posts[2].down, false)
		end)
	end)
	helpers.it("rejects fresh foreign session modifiers after its own Command without a HID grant", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); f.session[56] = true
			eq(f.owner.post(f.cap, 2), true); f.step(5)
			eq(#f.posts, 1); eq(f.owner.observed(f.cap, 2), false); eq(f.owner.retire(f.cap), false)
			f.session[56] = nil; f.step(8); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("rejects flags-only foreign session state independently from the key roster", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); f.session_flags = 0x140000
			eq(f.owner.post(f.cap, 2), true); f.step(5)
			eq(#f.posts, 1); eq(f.owner.observed(f.cap, 2), false); eq(f.owner.retire(f.cap), false)
			f.session_flags = nil; f.step(8); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("requires the exact acknowledged Command before a later native Tab", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); f.session[55] = nil
			eq(f.owner.post(f.cap, 2), true); f.step(5)
			eq(f.owner.observed(f.cap, 2), false)
			for _, row in ipairs(f.posts) do eq(row.key, 55) end
			f.step(5); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("fences a foreign event delivered while constructing the next native edge", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1)
			f.construct_edge = function(_, key, down)
				if key == 48 and down then foreign(f, 56) end
			end
			eq(f.owner.post(f.cap, 2), true); f.step(5)
			for _, row in ipairs(f.posts) do eq(row.key, 55) end
			eq(f.owner.observed(f.cap, 2), false); f.step(5); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("refuses a constructed Tab carrying foreign modifier flags before native posting", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1)
			f.construct_edge = function(event, key, down)
				if key == 48 and down then
					function event:getFlags() return { cmd = true, shift = true } end
				end
			end
			eq(f.owner.post(f.cap, 2), true); f.step(5)
			for _, row in ipairs(f.posts) do eq(row.key, 55) end
			eq(f.owner.observed(f.cap, 2), false); f.step(5); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("revokes foreign events between ordinals before accepting another edge", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); foreign(f, 56)
			eq(f.owner.post(f.cap, 2), false); eq(f.owner.observed(f.cap, 1), false)
			f.step(8); eq(f.owner.retire(f.cap), true)
			for _, row in ipairs(f.posts) do eq(row.key, 55) end
		end)
	end)
	helpers.it("refuses native output when the owned observation tap becomes disabled", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); f.tap.enabled = false
			eq(f.owner.post(f.cap, 2), false); f.step(5)
			eq(#f.posts, 1); eq(f.owner.retire(f.cap), false)
			f.tap.enabled = true; f.step(8); eq(f.owner.retire(f.cap), true)
		end)
	end)
end)

helpers.describe("native switcher exact input and sample owner", function()
	helpers.it("posts four explicit observed edges and waits for independent session release", function()
		with_input(function(f)
			eq(f.owner.ready(), true); eq(f.prepare(), true)
			for n = 1, 4 do f.edge(n) end
			eq(f.owner.released(f.cap), false); f.step(2)
			eq(f.owner.released(f.cap), true); eq(table.concat(f.received, ","), "1,2,3,4")
			eq(#f.posts, 4); eq(f.owner.retire(f.cap), true); eq(f.lease_count, 0)
			eq(f.owner.retire(f.cap), true); eq(f.owner.ready(), true)
		end)
	end)
	helpers.it("refuses TCC denial and never substitutes post admission for observed delivery", function()
		with_input(function(f)
			f.access = false; eq(f.owner.ready(), false); eq(#f.posts, 0)
			f.access = true; eq(f.prepare(), true); f.no_observation = true
			eq(f.owner.post(f.cap, 1), true); f.step(8)
			eq(f.owner.observed(f.cap, 1), false); eq(#f.received, 0)
			eq(f.owner.retire(f.cap), false)
			f.no_observation = false; eq(f.owner.cancel(f.cap), true); f.step(8)
			eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("rejects inherited HID state before any input mutation", function()
		with_input(function(f)
			f.hid[54] = true; eq(f.prepare(), true); eq(f.owner.post(f.cap, 1), true); f.step(5)
			eq(#f.posts, 0); eq(f.owner.observed(f.cap, 1), false)
			eq(f.owner.cancel(f.cap), true); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("rejects inherited combined-session state independently from clear HID", function()
		with_input(function(f)
			f.session[55] = true; eq(f.prepare(), true); eq(f.owner.post(f.cap, 1), true); f.step(5)
			eq(#f.posts, 0); eq(f.owner.cancel(f.cap), true); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("does not retire from local up observation while session state remains held", function()
		with_input(function(f)
			eq(f.prepare(), true); for n = 1, 4 do f.edge(n) end; f.step(5)
			eq(f.owner.released(f.cap), false); eq(f.owner.retire(f.cap), false)
			f.keep_session = false; f.session[55] = nil; f.step(3)
			eq(f.owner.released(f.cap), true); eq(f.owner.retire(f.cap), true)
		end, function(f) f.keep_session = true end)
	end)
	helpers.it("compensates both posted downs in exact Tab then Command order after cancellation", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); f.edge(2)
			eq(f.owner.cancel(f.cap), true); eq(f.owner.retire(f.cap), false); f.step(10)
			eq(#f.posts, 4); eq(f.posts[3].key, 48); eq(f.posts[3].down, false)
			eq(f.posts[4].key, 55); eq(f.posts[4].down, false)
			eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("keeps ambiguous post debt after refused return and compensates it", function()
		with_input(function(f)
			eq(f.prepare(), true); f.post_refused = true; f.edge(1)
			eq(#f.received, 0); eq(f.owner.retire(f.cap), false)
			f.post_refused = false; f.step(10); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("rejects wrong-pid tagged observations and never advances the broker", function()
		with_input(function(f)
			eq(f.prepare(), true); f.spoof_pid = true; f.edge(1)
			eq(#f.received, 0); eq(f.owner.observed(f.cap, 1), false)
			f.spoof_pid = false; f.step(10); eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("holds exact native tap stop debt and blocks a successor", function()
		with_input(function(f)
			eq(f.prepare(), true); eq(f.owner.cancel(f.cap), true); f.tap_ack = false
			eq(f.owner.retire(f.cap), false); eq(f.prepare(), false); eq(f.owner.ready(), false)
			f.tap_ack = true; eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("holds timer stop debt independently from native tap retirement", function()
		with_input(function(f)
			eq(f.prepare(), true); eq(f.owner.cancel(f.cap), true); f.timer_ack = false
			eq(f.owner.retire(f.cap), false); eq(f.tap.enabled, false); eq(f.lease_count, 1)
			f.timer_ack = true; eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("retains the exact helper task after refused start while it is still running", function()
		with_input(function(f)
			eq(f.prepare(), true); eq(f.owner.post(f.cap, 1), true); f.step(2)
			eq(#f.posts, 0); eq(f.owner.cancel(f.cap), true); eq(f.owner.retire(f.cap), false)
			f.task_stuck = false; eq(f.owner.retire(f.cap), true)
		end, function(f) f.task_stuck = true; f.start_refused = true end)
	end)
	helpers.it("rejects malformed or stale native samples before mutating input", function()
		for _, change in ipairs({
			function(raw) raw.session.request = raw.request + 1 end,
			function(raw) raw.session.held = { 55, 55 } end,
			function(raw) raw.session.extra = true end,
			function(raw) raw.listen_access = false end,
			function(raw) raw.post_access = false end,
		}) do
			with_input(function(f)
				eq(f.prepare(), true); eq(f.owner.post(f.cap, 1), true); f.step(4)
				eq(#f.posts, 0); eq(f.owner.cancel(f.cap), true); eq(f.owner.retire(f.cap), true)
			end, function(f) f.alter_frame = change end)
		end
	end)
	helpers.it("does not emit after publication revocation and retains provenance until ACK", function()
		with_input(function(f)
			eq(f.prepare(), true); f.source = false; eq(f.owner.post(f.cap, 1), false); f.step(1)
			f.release_ack = false; eq(f.owner.retire(f.cap), false); eq(#f.posts, 0)
			f.release_ack = true; eq(f.owner.retire(f.cap), true)
		end)
	end)
	helpers.it("refuses foreign capabilities, stale ordinals, and unknown timer acquisition", function()
		with_input(function(f)
			eq(f.prepare(), true); eq(f.owner.post({}, 1), false); eq(f.owner.post(f.cap, 2), false)
			eq(f.owner.retire({}), false); eq(f.owner.cancel({}), false)
			eq(f.owner.cancel(f.cap), true); eq(f.owner.retire(f.cap), true)
		end)
		with_input(function(f)
			eq(f.prepare(), false); eq(f.owner.retire(f.cap), false); eq(f.lease_count, 1)
		end, function(f) f.timer_throw = true end)
	end)
	helpers.it("joins the actual product facade and terminal broker through native input ports", function()
		with_input(function(f)
			package.loaded["adapters.synthetic_input"] = {
				system_switcher_available = f.owner.ready, prepare_system_switcher = f.owner.prepare,
				post_system_switcher_edge = f.owner.post, system_switcher_observation_current = f.owner.observed,
				system_switcher_release_current = f.owner.released, cancel_system_switcher = f.owner.cancel,
				retire_system_switcher = f.owner.retire,
			}
			package.loaded["adapters.window_manager"] = { frontmost_pid = function() return f.front end }
			local facade = require("modules.gestures.native_app_switcher")
			eq(facade.init({ deadline_sec = 4, poll_sec = 0.02 }), true)
			local source = { current = function() return f.source end, cached = function() return f.source end }
			local cap, admitted = facade.request(source); eq(admitted, true)
			f.step(20); eq(#f.posts, 4); eq(facade.status(cap), nil)
			f.front = 11; f.step(2); eq(facade.status(cap), "switched"); eq(f.lease_count, 0)
		end)
	end)
	helpers.it("uses the actual central synthetic lease and provenance without an independent tag namespace", function()
		with_input(function(f)
			local input = f.actual_synthetic()
			eq(input.init_system_switcher(f.descriptor, { poll_sec = 0.02 }), true)
			eq(input.init_system_switcher(f.descriptor, { poll_sec = 0.02 }), false)
			eq(input.prepare_system_switcher(f.cap, function() return true end, function() return f.source end), true)
			eq(input.stats().active_transactions, 1)
			eq(input.post_system_switcher_edge(f.cap, 1), true); f.step(3)
			local metadata = input.lookup_tag(f.posts[1].tag)
			eq(metadata.effect, "action"); eq(metadata.owner, "gestures.system_switcher")
			eq(metadata.source_pid, 99); eq(metadata.phase, "down")
			eq(input.cancel_system_switcher(f.cap), true); f.step(8)
			f.tap_ack = false; eq(input.retire_system_switcher(f.cap), false)
			eq(input.stats().active_transactions, 1)
			f.tap_ack = true; eq(input.retire_system_switcher(f.cap), true)
			eq(input.stats().active_transactions, 0)
		end)
	end)
	helpers.it("joins actual product scope, facade, broker, native ports and central lease", function()
		with_input(function(f)
			local action = f.action()
			local publication = { current = function() return f.source end, cached = function() return f.source end }
			eq(action.request("gestures", publication), true); f.step(20)
			eq(action.has_pending("gestures"), true); eq(#f.posts, 4)
			eq(action.pause("shortcut_bindings"), true); eq(action.has_pending("gestures"), true)
			eq(action.request("shortcut_bindings", publication), false)
			f.front = 11; f.step(2); eq(action.has_pending("gestures"), false)
			eq(package.loaded["adapters.synthetic_input"].stats().active_transactions, 0)
			eq(action.resume("shortcut_bindings"), true)
			eq(action.request("shortcut_bindings", publication), true); f.step(3)
			eq(action.pause("gestures"), true); eq(action.has_pending("shortcut_bindings"), true)
			eq(action.pause("shortcut_bindings"), false); eq(action.resume("shortcut_bindings"), false)
			f.step(10); eq(action.pause("shortcut_bindings"), true)
			eq(action.resume("shortcut_bindings"), true)
		end)
	end)
	helpers.it("fences actual product acquisition when a source callback pauses its parent", function()
		with_input(function(f)
			local action = f.action()
			local calls = 0
			local publication = { current = function()
				calls = calls + 1
				if calls == 1 then eq(action.pause("gestures"), false) end
				return true
			end, cached = function() return true end }
			eq(action.request("gestures", publication), false)
			eq(action.has_pending("gestures"), false); eq(#f.posts, 0)
			eq(action.resume("gestures"), true)
		end)
	end)
	helpers.it("rejects revoked helper identity and retains posted release debt until exact restoration", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1)
			local digest = f.digest; f.digest = string.rep("b", 64); f.step(3)
			eq(#f.posts, 1); eq(f.owner.retire(f.cap), false)
			eq(f.owner.ready(), false)
			f.digest = digest; f.step(10); eq(f.owner.retire(f.cap), true)
		end)
	end)
end)

helpers.describe("native factory source identity differs from its SDK selector", function()
	helpers.it("observes four edges with the literal native private source identity", function()
		with_input(function(f)
			eq(f.prepare(), true); for ordinal = 1, 4 do f.edge(ordinal) end; f.step(4)
			eq(table.concat(f.received, ","), "1,2,3,4")
			eq(f.owner.released(f.cap), true); eq(f.owner.retire(f.cap), true)
		end, function(f) f.created_source_id = 1649760492 end)
	end)
	helpers.it("rejects the private selector as an observed field when the factory identity differs", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); eq(#f.received, 0)
			eq(f.owner.observed(f.cap, 1), false); eq(f.owner.retire(f.cap), false)
			f.observed_source_id = nil; f.step(10); eq(f.owner.retire(f.cap), true)
		end, function(f) f.created_source_id = 1649760492; f.observed_source_id = -1 end)
	end)
	helpers.it("rejects another positive source identity despite exact PID and central tag", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1); eq(#f.received, 0)
			eq(f.owner.observed(f.cap, 1), false); eq(f.owner.retire(f.cap), false)
			f.observed_source_id = nil; f.step(10); eq(f.owner.retire(f.cap), true)
		end, function(f) f.created_source_id = 1649760492; f.observed_source_id = 1649760493 end)
	end)
	helpers.it("revokes a replaced native factory and compensates with its captured factory", function()
		with_input(function(f)
			eq(f.prepare(), true); f.edge(1)
			f.native.eventtap.event.newKeyEvent = function() error("foreign factory must not run") end
			eq(f.owner.post(f.cap, 2), false); f.step(10)
			eq(#f.posts, 2); eq(f.posts[2].key, 55); eq(f.posts[2].down, false)
			eq(f.owner.retire(f.cap), true)
		end, function(f) f.created_source_id = 1649760492 end)
	end)
end)
