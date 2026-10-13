--- tests/unit/modules/keylogger/test_physical_history_bootstrap.lua

--- Actual native source/channel software with declared app/window/AX/clock leaf models.
--- These controls establish no Hammerspoon, Mach, signed producer or initial-awake authority.

--- Borrows the existing isolated real SQLite child; its historical assertions stay intact.
local function replace_once(source, before, after)
	local first, last = source:find(before, 1, true)
	assert(first ~= nil, "Missing real fixture boundary")
	assert(not source:find(before, last + 1, true), "Ambiguous real fixture boundary")
	return source:sub(1, first - 1) .. after .. source:sub(last + 1)
end
local function composition_child()
	local root = assert(arg[3])
	local original = root .. "/static/ergopti_plus/macos/tests/unit/modules/keylogger/test_physical_history_persistence.lua"
	local file = assert(io.open(original, "r")); local source = file:read("*a"); file:close()
	-- The wrapper records facts only: every decisive check occurs after protected frames.
	source = replace_once(source, '-- Start first: binding must observe an actual running engine, never assign enabled.', [[
local actual_sampler = assert(tracker.sample_physical_context)
local bootstrap = { calls = 0, acknowledged = true, legacy_conserved = true, ordered = true }
tracker.sample_physical_context = function(owner, token)
	bootstrap.calls = bootstrap.calls + 1
	local start, ax = state.active_app_start, state.ax_observer
	local accepted = actual_sampler(owner, token)
	bootstrap.acknowledged = bootstrap.acknowledged and accepted == true
	bootstrap.legacy_conserved = bootstrap.legacy_conserved and start == state.active_app_start and rawequal(ax, state.ax_observer)
	return accepted
end
local actual_capture_init = capture.init
capture.init = function(ports)
	local context = ports.context
	ports.context = function(...)
		bootstrap.ordered = bootstrap.ordered and bootstrap.calls > 0 and bootstrap.acknowledged
		return context(...)
	end
	return actual_capture_init(ports)
end
-- Start first: binding must observe an actual running engine, never assign enabled.
]])
	source = replace_once(source, 'native.verified();native.clocked();native.open()', [[
native.verified();native.clocked()
local legacy_start, legacy_ax = state.active_app_start, state.ax_observer
native.frames.batch = {version=1,kind="batch",coverage="complete",incarnation="production-fixture",lease="7",records={{sequence="1",device="41",timestamp=tostring(clock_ns-1000000),has_page=true,has_usage=true,page=7,usage=41,value="1",has_cookie=true,cookie=41}}}
observed.tasks[3].chunk(nil,"opened\npage\nready\nbatch\n")
assert(bootstrap.calls == 1 and bootstrap.acknowledged, "Actual baseline must consume exactly one genuine sampler ACK")
assert(state.active_app_start == legacy_start and rawequal(state.ax_observer, legacy_ax), "Baseline must preserve the real legacy app/AX owner")
]])
	source = replace_once(source, 'local sequence=0', 'local sequence=1')
	source = replace_once(source, 'print(json.encode(receipt))', [[
assert(bootstrap.calls == (os.getenv("ERGOPTI_PERSISTENCE_CASE") == "stop" and 1 or 4), "Exactly one sample per actual distinct lease")
assert(bootstrap.legacy_conserved and bootstrap.acknowledged, "All actual samples preserve legacy owners and ACK observations")
receipt.bootstrap = bootstrap
print(json.encode(receipt))
]])
	source = replace_once(source, 'test_physical_history_persistence%.lua$', 'test_physical_history_bootstrap%.lua$')
	assert(load(source, "@" .. original, "t", _G))()
end
if arg and arg[0] and arg[0]:match('test_physical_history_bootstrap%.lua$') then composition_child(); return end

local helpers = require("tests.helpers")
local Privacy = require("modules.keylogger.privacy_context")

local function with_fixture(callback)
	return helpers.with_stub_scope({ "modules.keylogger.context_tracker", "adapters.secure_field_detector",
		"adapters.physical_observation_clock", "keylogger.physical_context_observation" }, function()
		local controls = { paused = false, no_window = false, no_focus = false, no_frontmost = false,
			throw_property = nil, title = "Ordinary window", role = "AXTextField", subrole = nil,
			queries = {}, clock = 1000000000, records = {}, failures = {}, decision_calls = 0, legacy = {} }
		local function query(name)
			controls.queries[#controls.queries + 1] = name
			if controls.on_query then controls.on_query(name) end
			if controls.throw_property == name then error("native refusal: " .. name) end
		end
		local element = { attributeValue = function(_, name)
			query(name)
			if name == "AXRole" then return controls.role end
			if name == "AXSubrole" then return controls.subrole end
			if name == "AXValue" then return "NOT-EMITTED-FIELD-VALUE" end
		end }
		local app_element = { attributeValue = function(_, name)
			query(name); if not controls.no_focus then return element end
		end }
		local app = {
			name = function() query("name"); return controls.app_name or "Editor" end,
			bundleID = function() query("bundleID"); return controls.bundle or "test.editor" end,
			path = function() query("path"); return controls.path or "/Applications/Editor.app" end,
			pid = function() query("pid"); return controls.pid or 4242 end,
		}
		local window_app = { pid = function() query("window_pid"); return controls.window_pid end }
		controls.window_pid = 4242
		local window = { application = function()
			query("window_application"); if not controls.no_window_app then return window_app end
		end, title = function() query("title"); return controls.title end,
			isFullScreen = function() query("fullscreen"); return false end }
		local observer = {
			addWatcher = function(self) query("addWatcher"); return self end,
			removeWatcher = function(self) query("removeWatcher"); return self end,
			callback = function(self, cb) controls.ax_callback = cb; if controls.refuse_callback then return false end; return self end,
			start = function(self) query("start"); if controls.refuse_start then return false end; return self end,
			stop = function(self) query("stop"); return self end,
		}
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function()
				controls.clock = controls.clock + 1
				if controls.clock_reader then return controls.clock_reader() end
				return controls.clock
			end },
			application = { watcher = { activated = 1 }, frontmostApplication = function()
				query("frontmost"); if not controls.no_frontmost then return app end
			end },
			window = { focusedWindow = function() query("window"); if not controls.no_window then return window end end },
			axuielement = { applicationElementForPID = function() query("ax_app"); return app_element end,
				applicationElement = function() query("observer_app"); return app_element end,
				windowElement = function() query("ax_window"); return nil end,
				observer = { new = function() query("observer_new"); return observer end } },
		})
		local state = { is_enabled = true, disabled_apps = {}, active_app_name = "Old",
			active_app_bundle = "test.old", active_app_path = "/Old.app", active_app_pid = 12, active_app_start = 100,
			is_private_window = false, is_secure_field = false, private_filter_enabled = true,
			secure_field_filter_enabled = true, system_auth_filter_enabled = true,
			buffer_events = {}, buffer_text = "", rich_chunks = {}, last_time = 0 }
		helpers.assert_true(tracker.init(state, { append_log = function(row) controls.legacy[#controls.legacy + 1] = row; return true end,
			flush_buffer = function() controls.flushes = (controls.flushes or 0) + 1; return true end,
			log_app_switch = function(a,b,d) controls.legacy[#controls.legacy + 1] = {a,b,d}; return true end },
			function() return controls.paused end))
		controls.bind = function(owner, receive, capacity, decision)
			helpers.assert_eq(type(tracker.bind_physical_correlated_context_observer), "function")
			return tracker.bind_physical_correlated_context_observer(owner or {}, capacity or 128,
				receive or function(record) controls.records[#controls.records + 1] = record; return true end,
				function(reason) controls.failures[#controls.failures + 1] = reason end,
				decision or function()
					controls.decision_calls = controls.decision_calls + 1
					return state.is_enabled and not controls.paused and Privacy.allows_logging(state)
				end)
		end
		controls.activate = function() return tracker.app_watcher_cb("Editor", 1, app) end
		controls.focus = function(focused) return controls.ax_callback(focused, "AXFocusedUIElementChanged", observer) end
		controls.element, controls.app, controls.observer = element, app, observer
		controls.window, controls.window_app = window, window_app
		controls.detector = require("adapters.secure_field_detector")
		callback(tracker, state, controls)
	end)
end


local function last(c) return c.records[#c.records] end
local function count(c, name)
	local n = 0; for _, value in ipairs(c.queries) do if value == name then n = n + 1 end end; return n
end
local function bind(tracker, c)
	local owner = {}
	local ok, token, scope = c.bind(owner)
	helpers.assert_eq(ok, true)
	return owner, token, scope
end
local function same_app(tracker, state, c)
	c.activate()
	state.active_app_start = 100 -- Legacy interval test input, never permission input.
	c.queries, c.legacy, c.flushes = {}, {}, 0
end
local function snapshot(state)
	local s = {}; for key,value in pairs(state) do s[key] = value end; return s
end
local function conserved(before, state)
	for key,value in pairs(before) do helpers.assert_eq(state[key], value, "legacy field changed: " .. key) end
	for key in pairs(state) do helpers.assert_true(before[key] ~= nil, "legacy field added: " .. key) end
end
helpers.describe("fresh-lease physical native field sampling", function()
	helpers.it("requires raw correlated ownership before any clock or native read", function()
		with_fixture(function(tracker, _, c)
			local clock = c.clock
			helpers.assert_eq(tracker.sample_physical_context({}, {}), false)
			helpers.assert_eq(c.clock, clock); helpers.assert_eq(#c.queries, 0)
			local owner, token = bind(tracker, c); clock = c.clock
			local equal_calls = 0
			local forged = setmetatable({}, { __eq = function() equal_calls = equal_calls + 1; return true end })
			helpers.assert_eq(tracker.sample_physical_context(forged, token), false)
			helpers.assert_eq(tracker.sample_physical_context(owner, forged), false)
			helpers.assert_eq(equal_calls, 0); helpers.assert_eq(c.clock, clock); helpers.assert_eq(#c.queries, 0)
		end)
	end)
	helpers.it("preserves same-app start100 and every actual legacy AX/window/buffer owner", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); local before = snapshot(state)
			local cache = c.detector.isSecureField()
			local owner, token = bind(tracker, c)
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			conserved(before, state); helpers.assert_eq(state.active_app_start, 100)
			helpers.assert_eq(#c.legacy, 0); helpers.assert_eq(c.flushes, 0)
			helpers.assert_eq(c.detector.isSecureField(), cache)
			helpers.assert_eq(last(c).source, "fresh_lease_sample"); helpers.assert_eq(last(c).allowed, true)
			helpers.assert_eq(last(c).app.name, "Editor"); helpers.assert_eq(last(c).app.pid, 4242)
			for _, name in ipairs({ "observer_new", "start", "stop", "addWatcher", "removeWatcher", "AXValue", "AXDocument", "ax_window", "fullscreen" }) do
				helpers.assert_eq(count(c, name), 0, "unexpected sampling side effect: " .. name)
			end
		end)
	end)
	helpers.it("retains a different legacy app timeline until the actual activation writer commits", function()
		with_fixture(function(tracker, state, c)
			local before = snapshot(state); local owner, token = bind(tracker, c)
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			conserved(before, state); helpers.assert_eq(last(c).allowed, false)
			helpers.assert_eq(#c.legacy, 0); helpers.assert_eq(c.flushes, nil)
			c.activate(); helpers.assert_eq(c.flushes, 1); helpers.assert_eq(#c.legacy, 1)
			helpers.assert_eq(c.legacy[1][1], "Old"); helpers.assert_eq(c.legacy[1][2], "Editor")
			helpers.assert_true(c.legacy[1][3] >= 900 and c.legacy[1][3] < 901)
			helpers.assert_eq(last(c).allowed, true)
		end)
	end)
	helpers.it("denies before every native read and emits no private title or field content", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); local owner, token = bind(tracker, c)
			local stages = {}
			c.on_query = function(name) stages[#stages + 1] = {name=name, stage=last(c).stage, allowed=last(c).allowed} end
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			for _, fact in ipairs(stages) do helpers.assert_eq(fact.stage, "boundary"); helpers.assert_eq(fact.allowed, false) end
			helpers.assert_true(#stages > 0)
			helpers.assert_eq(last(c).title, nil); helpers.assert_eq(last(c).value, nil); helpers.assert_eq(last(c).document, nil)
		end)
	end)
	helpers.it("observes private fields without clearing or trusting the ordinary legacy cache", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); local owner, token = bind(tracker, c)
			c.title = "Private Browsing"; local before = snapshot(state)
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			helpers.assert_eq(last(c).private, true); helpers.assert_eq(last(c).allowed, false)
			conserved(before, state); helpers.assert_eq(state.is_private_window, false)
		end)
	end)
	helpers.it("uses the existing configured private policy without manufacturing a default", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); state.private_filter_enabled = false
			local owner, token = bind(tracker, c); c.title = "Private Browsing"
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			helpers.assert_eq(last(c).private, true); helpers.assert_eq(last(c).allowed, true)
		end)
	end)
	helpers.it("preserves a conservative denied legacy guard until a real writer updates it", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); state.is_private_window = true
			local owner, token = bind(tracker, c)
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			helpers.assert_eq(last(c).private, false); helpers.assert_eq(last(c).allowed, false)
			helpers.assert_eq(state.is_private_window, true)
		end)
	end)
	helpers.it("applies actual disabled-app policy to the sampled foreground", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); state.disabled_apps = {{bundleID="test.editor"}}
			local owner, token = bind(tracker, c)
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			helpers.assert_eq(last(c).allowed, false)
		end)
	end)
	for _, recipe in ipairs({ {"secure role", "AXSecureTextField", nil}, {"secure subrole", "AXTextField", "AXSecureTextField"} }) do
		helpers.it("reuses actual classifier for " .. recipe[1] .. " without altering its cache", function()
			with_fixture(function(tracker, state, c)
				same_app(tracker, state, c); local owner, token = bind(tracker, c)
				c.role, c.subrole = recipe[2], recipe[3]
				helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
				helpers.assert_eq(last(c).secure, true); helpers.assert_eq(last(c).allowed, false)
				helpers.assert_eq(state.is_secure_field, false); helpers.assert_eq(c.detector.isSecureField(), false)
			end)
		end)
	end
	for _, variant in ipairs({ "no_frontmost", "no_window", "no_focus", "foreign_pid", "float_pid", "nil_role", "bad_subrole", "AXRole" }) do
		helpers.it("acknowledges incomplete denied observation for " .. variant, function()
			with_fixture(function(tracker, state, c)
				same_app(tracker, state, c); local owner, token = bind(tracker, c)
				if variant == "foreign_pid" then c.window_pid = 99
				elseif variant == "float_pid" then c.window_pid = 4242.0
				elseif variant == "nil_role" then c.role = nil
				elseif variant == "bad_subrole" then c.subrole = {}
				elseif variant == "AXRole" then c.throw_property = "AXRole"
				else c[variant] = true end
				helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
				helpers.assert_eq(last(c).allowed, false); helpers.assert_eq(last(c).complete, false)
			end)
		end)
	end
	helpers.it("does not accept floating app PID equal to the tracked integer", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); local owner, token = bind(tracker, c); c.pid = 4242.0
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			helpers.assert_eq(last(c).allowed, false); helpers.assert_eq(last(c).complete, false)
		end)
	end)
	helpers.it("keeps true pause free of sensitive app/window/AX queries", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); local owner, token = bind(tracker, c); c.paused = true
			helpers.assert_eq(tracker.sample_physical_context(owner, token), true)
			helpers.assert_eq(#c.queries, 0); helpers.assert_eq(last(c).allowed, false)
		end)
	end)
	helpers.it("retains the exact source through Role-triggered detach and prevents actual Subrole read", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); local owner, token, scope = bind(tracker, c)
			local inside, detached
			c.on_query = function(name)
				if name == "AXRole" then detached = tracker.unbind_physical_context_observer(owner, token); inside = scope.retired(owner, token) end
			end
			helpers.assert_eq(tracker.sample_physical_context(owner, token), false)
			helpers.assert_eq(detached, true); helpers.assert_eq(inside, false)
			helpers.assert_eq(scope.retired(owner, token), true); helpers.assert_eq(count(c, "AXSubrole"), 0)
			helpers.assert_eq(last(c).stage, "boundary"); helpers.assert_eq(last(c).allowed, false)
		end)
	end)
	helpers.it("cannot publish a sample after genuine app writer reentry", function()
		with_fixture(function(tracker, state, c)
			same_app(tracker, state, c); local owner, token, scope = bind(tracker, c)
			c.on_query = function(name)
				if name == "AXRole" then c.on_query = nil; c.activate() end
			end
			helpers.assert_eq(tracker.sample_physical_context(owner, token), false)
			helpers.assert_eq(scope.current(owner, token), false); helpers.assert_eq(last(c).allowed, false)
		end)
	end)
	helpers.it("does not cross native query boundaries after an exhausted receipt budget", function()
		with_fixture(function(tracker, _, c)
			local owner = {}; local ok, token = c.bind(owner, nil, 1)
			helpers.assert_eq(ok, true); local before = c.clock
			helpers.assert_eq(tracker.sample_physical_context(owner, token), false)
			helpers.assert_eq(#c.queries, 0); helpers.assert_eq(c.clock, before)
		end)
	end)
end)

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
helpers.describe("fresh-lease baseline through real managed source writers", function()
	helpers.it("consumes each real baseline without changing persistence, holds or bounded shutdown/recovery", function()
		local driver = helpers.driver_root()
		local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")
		local root = driver .. "../../.."
		local python = [[
import importlib.util, os, sys, tempfile
from pathlib import Path
root = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("owned_persistence", root / "tools/diagnostics/hs274_persistence_test.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); m.ROOT = root
os.environ["ERGOPTI_PHYSICAL_SOURCE_ROOT"] = str(root)
for case in ("recovery", "stop"):
	os.environ["ERGOPTI_PERSISTENCE_CASE"] = case
	with tempfile.TemporaryDirectory(prefix="ergopti-physical-bootstrap-") as temporary:
		receipt = m.run_fixture(sys.argv[2], temporary, Path(sys.argv[3]).resolve())
		expected = {"holds":[{"date":"2026-10-05","app":"Original","keycode":53,"sum_ms":800,"count":1,"max_ms":800,"tap_count":0,"hold_count":1}],"presses":[{"keycode":53,"c":3 if case=="stop" else 4}],"raw_releases":1}
		if receipt["live"] != expected or receipt["rebuild_one"] != expected or receipt["rebuild_two"] != expected:
			raise AssertionError("Original independent persistence/hold expectations changed")
		if receipt["bootstrap"] != {"calls":1 if case == "stop" else 4,"acknowledged":True,"legacy_conserved":True,"ordered":True}:
			raise AssertionError(receipt["bootstrap"])
		if receipt["retired"] is not True or receipt["errors"]:
			raise AssertionError("Actual source/native/history debt did not settle")
		if case == "recovery" and (receipt["retry_delays"] != [1,2,4] or receipt["status"]["retries_used"] != 3):
			raise AssertionError("Baseline must not reset the actual bounded retry policy")
		if case == "stop" and receipt["stop_facts"] != {"accepted":True,"retired_inside_source":False,"complete":True,"callback_retired":False}:
			raise AssertionError("Actual held source callback/native retirement changed")
print("PASS: actual fresh baseline/context/history/file/SQLite ownership")
]]
		local executable = os.getenv("LUA") or arg[-1]
		helpers.assert_true(type(executable) == "string" and executable ~= "")
		local command = "python3 -c " .. quote(python) .. " " .. quote(root) .. " " .. quote(executable) .. " " .. quote(source) .. " 2>&1"
		local pipe = assert(io.popen(command, "r")); local output = pipe:read("*a"); local ok, kind, status = pipe:close()
		helpers.assert_eq(ok, true, output); helpers.assert_eq(kind, "exit", output); helpers.assert_eq(status, 0, output)
		helpers.assert_eq(output, "PASS: actual fresh baseline/context/history/file/SQLite ownership\n")
	end)
end)

helpers.describe("fresh physical sample dynamic pause boundaries", function()
 helpers.it("prevents actual Subrole read after pause begins inside Role", function()
  with_fixture(function(tracker,state,c)
   same_app(tracker,state,c);local owner,token,scope=bind(tracker,c)
   c.on_query=function(name) if name=="AXRole" then c.paused=true end end
   helpers.assert_eq(tracker.sample_physical_context(owner,token),false)
   helpers.assert_eq(count(c,"AXSubrole"),0);helpers.assert_eq(last(c).allowed,false)
   helpers.assert_eq(scope.current(owner,token),false)
  end)
 end)
 helpers.it("refuses an allowed receipt when pause begins inside its native completion clock", function()
  with_fixture(function(tracker,state,c)
   same_app(tracker,state,c);local owner,token,scope=bind(tracker,c)
   c.on_query=function(name)
    if name=="AXSubrole" then c.clock_reader=function() c.paused=true;return c.clock end end
   end
   helpers.assert_eq(tracker.sample_physical_context(owner,token),false)
   helpers.assert_eq(last(c).allowed,false);helpers.assert_eq(scope.current(owner,token),false)
  end)
 end)
end)
