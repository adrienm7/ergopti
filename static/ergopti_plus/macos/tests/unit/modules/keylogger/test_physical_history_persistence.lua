--- tests/unit/modules/keylogger/test_physical_history_persistence.lua

--- Actual permission writers and persistence; native endpoints are explicit software models.
local function child()
-- tools/diagnostics/hs274-persistence.lua
-- Production Mac persistence/rebuild with actual SQLite and adapted native ports.
local root, temporary, source_root = assert(arg[1]), assert(arg[2]), assert(arg[3])
local driver = source_root .. "/static/ergopti_plus/macos"
local shared = root .. "/static/ergopti_plus/_shared"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. root .. "/static/ergopti_plus/macos/?.lua;" .. shared .. "/lua/?.lua;" .. shared .. "/lua/?/init.lua;" .. package.path
local json = require("json")
local function request(message)
	message.kind = "request"
	assert(io.stdout:write(json.encode(message) .. "\n")); assert(io.stdout:flush())
	local line = assert(io.stdin:read("*l"), "SQLite parent did not return a receipt")
	return assert(json.decode(line))
end
local sqlite = { OK = 0, DONE = 101 }
function sqlite.open(path)
	local opened = request({ op = "open", path = path })
	assert(opened.ok, opened.error)
	local identity, detail = opened.value, ""
	local database = {}
	local function call(operation, sql, values)
		local result = request({ op = operation, connection = identity, sql = sql, values = values })
		if not result.ok then detail = result.error; return nil end
		return result.value
	end
	function database:exec(sql) return call("exec", sql) or 1 end
	function database:errmsg() return detail end
	function database:close() return call("close") end
	function database:nrows(sql)
		local rows = assert(call("rows", sql), detail)
		local index = 0
		return function() index = index + 1; return rows[index] end
	end
	function database:prepare(sql)
		local values
		return { bind_values = function(_, ...) values = { ... } end,
			step = function() assert(call("bound", sql, values), detail); return sqlite.DONE end,
			finalize = function() return sqlite.OK end }
	end
	return database
end
local logs = {}
local logger = {}
for _, method in ipairs({ "trace", "debug", "info", "warn", "start", "done", "success" }) do
	logger[method] = function() end
end
function logger.error(_, message, ...) logs[#logs + 1] = string.format(message, ...) end
function logger.pcall(_, callback, ...) return pcall(callback, ...) end
local fs = {}
function fs.attributes(path, attribute)
	local response = request({ op = "stat", path = path })
	assert(response.ok, response.error)
	local stat = response.value
	if stat == false then return nil end
	local result = { mode = stat.type, size = stat.size }
	return attribute and result[attribute] or result
end
function fs.dir(path)
	local response = request({ op = "directory", path = path })
	assert(response.ok, response.error)
	local scan = { rows = response.value, index = 0 }
	return function(state) state.index = state.index + 1; return state.rows[state.index] end, scan
end
local function read(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local body = file:read("*a"); file:close(); return body
end
local function write(path, body)
	local file = assert(io.open(path, "w")); assert(file:write(body)); assert(file:close()); return true
end
local timer = {}
function timer.new()
	local active = false
	return { start = function(self) active = true; return self end,
		stop = function() active = false; return true end,
		running = function() return active end }
end
function timer.absoluteTime() return math.floor(os.clock() * 1000000000) end
function timer.secondsSinceEpoch() return os.time() end
local file_system = { read = read, write = write,
	read_with_status = function(path) local value = read(path); return value, value and "ok" or "absent" end }
local function ports()
	_G.hs = { fs = fs, timer = timer, json = json,
		execute = function() return "physical-fixture-host" end,
		host = { localizedName = function() return "Fixture" end } }
	package.loaded["hs.fs"], package.loaded["hs.timer"] = fs, timer
	package.loaded["hs.json"], package.loaded["hs.sqlite3"] = json, sqlite
	package.loaded["infra.logger"], package.loaded["adapters.file_system"] = logger, file_system
	package.loaded["infra.paths"] = { shared = function(path) return shared .. "/" .. path end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.text_utils"] = { shell_quote = function(value)
		return "'" .. value:gsub("'", "'\\''") .. "'"
	end }
	package.loaded["modules.keylogger.text_cipher"] = {}
	package.loaded["adapters.timer_scheduler"] = { after = function()
		return { committed = true, timer = {} }, true
	end, cancel = function(handle) handle.timer = nil; return true end, now = os.time }
	package.loaded["modules.keylogger.export"] = { init = function() end,
		sync_foreign_data_sql = function() return {} end, get_native_app_category = function() return "other" end }
end
local metrics = temporary .. "/metrics"
local identity = "physical-release-device"
local by_device = metrics .. "/by_device/" .. identity
for _, path in ipairs({ metrics, metrics .. "/by_device", by_device, temporary .. "/ergopti_metrics",
	temporary .. "/ergopti_metrics/" .. identity }) do assert(request({ op = "mkdir", path = path }).ok) end
write(by_device .. "/device.json", json.encode({ device_id = identity, host_signature = "physical-fixture-host",
	name = "Fixture", os = "darwin", os_version = "fixture", created_at = "2026-09-12 00:00:00.000" }))

-- Actual source writers own permission receipts; only macOS leaf endpoints below are modeled.
local helpers = require("tests.helpers")
local shell = require("tests.support.physical_capture_fixture")
local state, manager, control, tracker, watchers, session
local calendar = "2026-10-05 12:00:00.000"
local observations, timers, refused = {}, {}, {}
local clock_ns = 1000000000
local function sample() clock_ns = clock_ns + 1000000; return clock_ns end
local function timer_new(delay, fn)
	local t={delay=delay, callback=fn, live=false}
	function t:start() self.live=true; return self end
	function t:stop() self.live=false; return true end
	function t:running() return self.live end
	function t:fire() assert(self.live); return self.callback() end
	timers[#timers+1]=t; return t
end
local function find(fn, key)
	for i=1,100 do local n,v=debug.getupvalue(fn,i); if n==key then return v end; if n==nil then break end end
	error("Missing actual writer upvalue: "..key)
end
package.loaded["infra.logger"]=helpers.make_logger_stub()
helpers.load_with_stubs("adapters.physical_observation_clock")
helpers.with_fresh_modules({ "adapters.shell_runner" }, function()
shell.run(function(capture, observed, native)
	native.frames.clock={version=1,domain="mach_absolute_time",numer=1,denom=1}
	local leaf=hs
	leaf.timer.absoluteTime=sample
	leaf.timer.secondsSinceEpoch=os.time
	leaf.timer.new=timer_new
	leaf.timer.doAfter=function(delay,fn) return timer_new(delay,fn):start() end
	leaf.timer.delayed={new=timer_new}
	leaf.json={decode=function(line) local frame=native.dependencies.decode(line); if frame then return frame end; return json.decode(line) end,encode=json.encode}
	-- Real file/SQLite effects share the parent's exact connection and transactions.
	leaf.fs=fs
	leaf.execute=function() return "physical-fixture-host" end
	leaf.host={localizedName=function() return "Fixture" end}
	package.loaded["hs.fs"],package.loaded["hs.sqlite3"]=fs,sqlite
	local log=helpers.make_logger_stub()
	log.error=function(_,msg,...) logs[#logs+1]=string.format(msg,...) end
	package.loaded["infra.logger"]=log
	package.loaded["infra.config_paths"]={metrics_dir=function() return metrics end,get_config_dir=function() return temporary end}
	package.loaded["adapters.file_system"]=file_system
	package.loaded["modules.keylogger.text_cipher"]={is_enabled=function() return false end}
	package.loaded["modules.keylogger.export"]={init=function() end,sync_foreign_data_sql=function() return {} end,get_native_app_category=function() return "other" end}
	package.loaded["infra.manifest_reader"]={default_for=function() return true end}
	package.loaded["infra.dialog_util"]={alert=function() end}
	local kc_running=false
	package.loaded["modules.keylogger.kc_bridge"]={init=function() return true end,set_log_manager=function() return true end,start=function() kc_running=true;return true end,stop=function() kc_running=false;return true end,is_running=function() return kc_running end,is_ke_managed_output_kc=function() return false end}
	package.loaded["adapters.process_lifecycle"]={onAppActivate=function(fn) observations.app=fn;return true end,start=function() return true end,stop=function() return true end}
	package.loaded["adapters.input_source_broker"]={subscribe=function() return true end,unsubscribe=function() return true end}
	package.loaded["adapters.keyboard_hook"]={start=function() return true end,stop=function() return true end,isRunning=function() return true end}
	package.loaded["modules.keymap"]={is_running=function() return false end}
	package.loaded["modules.gestures.engine"]={}
	package.loaded["modules.gestures.actions"]={}
	leaf.caffeinate={watcher={systemDidWake=1,screensDidWake=2,screensDidUnlock=3,systemWillSleep=4,screensDidSleep=5,screensDidLock=6,new=function(fn)
		observations.caffeinate=fn; local w={}; function w:start() return self end; function w:stop() return self end; return w end}}
	local app_name, title, secure="Original","Ordinary",false
	local before_query
	local app={name=function() return app_name end,bundleID=function() return "test."..app_name end,path=function() return "/"..app_name..".app" end,pid=function() return 42 end}
	local win={application=function() return app end,title=function() return title end,isFullScreen=function() return false end}
	local element={attributeValue=function(_,name) if before_query then local action=before_query;before_query=nil;action() end; if name=="AXRole" then return secure and "AXSecureTextField" or "AXTextField" end end}
	local app_element={attributeValue=function(_,name) if name=="AXFocusedUIElement" then return element end end}
	leaf.application.frontmostApplication=function() return app end
	leaf.application.watcher.activated=1
	leaf.window.focusedWindow=function() return win end
	leaf.axuielement={applicationElementForPID=function() return app_element end,applicationElement=function() return app_element end,windowElement=function() return nil end,observer={new=function()
		local o={}; function o:addWatcher() return self end; function o:removeWatcher() return self end; function o:callback(fn) observations.ax=fn;return self end;function o:start() return self end;function o:stop() return self end;return o end}}
	-- The same declared native projection leaf model as existing managed-session controls.
	local Accepted=require("keylogger.physical_accepted_context")
	package.loaded["adapters.physical_history_context"]={new=function(owner,history,borrowed)
		local c,k=borrowed.capture,borrowed.clock
		local ct,kt=c.identity(),k.identity(owner)
		return Accepted.new(owner,{current=function() return c.current(ct)==true and c.admitted(ct)~=nil and k.current(owner,kt)==true end,revision=history.retained_count,convert=tonumber,resolve_interval=function(first,last) return history.resolve_interval(ct,kt,first,last) end,calendar=function() return calendar end,on_refused=function() history.stop(ct) end})
	end}
	package.loaded["adapters.shell_runner"]={spawn=native.dependencies.spawn}
	control=require("modules.shortcuts.script_control")
	manager=require("modules.keylogger.log_manager")
	local keylogger=require("modules.keylogger")
	tracker=require("modules.keylogger.context_tracker")
	watchers=require("modules.keylogger.watchers")
	state=find(keylogger.notify_synthetic,"CoreState")
	assert(keylogger.start(control),table.concat(logs,"\n"))
	for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end
	-- Start first: binding must observe an actual running engine, never assign enabled.
	session=assert(require("modules.keylogger.physical_history_session").init(4096,function(reason) refused[#refused+1]=reason end,{managed=true}))
	assert(session.start(native.options))
	native.verified();native.clocked();native.open()
	local sequence=0
	local function send(down,ticks)
		sequence=sequence+1
		native.frames.batch={version=1,kind="batch",coverage="complete",incarnation="production-fixture",lease="7",records={{sequence=tostring(sequence),device="41",timestamp=tostring(ticks),has_page=true,has_usage=true,page=7,usage=41,value=down and "1" or "0",has_cookie=true,cookie=41}}}
		observed.tasks[3].chunk(nil,"batch\n")
	end
	-- Initial posture is genuinely unknown despite actual engine enabled.
	send(true,sample());send(false,sample())
	assert(not (read(by_device.."/today.log") or ""):find("physical_press",1,true),"Unknown startup must not persist a physical press")
	for _,event in ipairs({1,2,3}) do observations.caffeinate(event) end
	for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end
	tracker.app_watcher_cb("Original",1,app)
	local first=clock_ns+100000000
	local last=first+800000000
	-- Delivery is delayed; current foreground changes after BOTH original ticks.
	clock_ns=last+100000000
	app_name="Latest"; tracker.app_watcher_cb("Latest",1,app)
	send(true,first)
	calendar="2026-10-06 12:00:00.000"
	send(false,last)
	assert(not (read(by_device.."/today.log") or ""):find("physical_press",1,true),"Physical FIFO must defer IO before other writers drain")
	-- An actual pause writer crosses this hold; resume cannot restore its duration.
	local pause_first=sample();send(true,pause_first)
	clock_ns=clock_ns+100000000
	assert(control.pause_all());for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end;assert(control.is_paused(),table.concat(logs,"\n"))
	clock_ns=clock_ns+100000000
	assert(control.resume_all());for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end;assert(not control.is_paused(),table.concat(logs,"\n"))
	tracker.app_watcher_cb("Latest",1,app)
	clock_ns=pause_first+800000000;send(false,clock_ns)
	-- Settle actual resumed writers and native observed posture before the next hold.
	assert(keylogger.start(control));assert(watchers.init_hardware_watchers())
	for _,event in ipairs({1,2,3}) do observations.caffeinate(event) end
	for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end
	-- Real private-title classification, no direct state assignment or ALLOW receipt.
	tracker.app_watcher_cb("Latest",1,app)
	local private_first=sample();send(true,private_first)
	clock_ns=clock_ns+100000000;title="Private Browsing";tracker.update_private_status()
	assert(state.is_private_window==true)
	clock_ns=clock_ns+100000000;title="Ordinary";tracker.update_private_status()
	clock_ns=private_first+800000000;send(false,clock_ns)
	local stopping=os.getenv("ERGOPTI_PERSISTENCE_CASE")=="stop"
	local stop_facts={}
	if stopping then
		observed.tasks[3].refuse_stop=true
		before_query=function()
			local module=require("modules.keylogger.physical_history_session")
			stop_facts.accepted=module.stop(function(complete) stop_facts.complete=complete;stop_facts.callback_retired=module.retired() end)
			stop_facts.retired_inside_source=module.retired()
		end
		tracker.app_watcher_cb("Latest",1,app)
		assert(stop_facts.accepted==true and stop_facts.retired_inside_source==false and stop_facts.complete==nil,"Explicit stop must retain actual writer/native debt")
	else
	-- Genuine normalized lost input terminates a hold without a release credit.
	assert(keylogger.start(control));assert(watchers.init_hardware_watchers())
	for _,event in ipairs({1,2,3}) do observations.caffeinate(event) end
	for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end
	tracker.app_watcher_cb("Latest",1,app)
	local gap_first=sample();send(true,gap_first)
	native.frames.lost={version=1,kind="lost",coverage="complete",incarnation="production-fixture",lease="7",reason="overflow"}
	observed.tasks[3].chunk(nil,"lost\n")
	assert(native.mode.credit_source()==native.mode.SOURCE_GAP)

	end
	manager.ingest_once();manager.ingest_once()
	local body=read(by_device.."/today.log")
	local db=require("modules.keylogger.sqlite_writer").get_db()
	local holds={};for row in db:nrows("SELECT date,app,keycode,sum_ms,count,max_ms,tap_count,hold_count FROM agg_app_day_kc_hold") do holds[#holds+1]=row end
	assert(#holds==1 and holds[1].app=="Original" and holds[1].date=="2026-10-05" and holds[1].keycode==53 and holds[1].sum_ms==800 and holds[1].count==1 and holds[1].max_ms==800 and holds[1].tap_count==0 and holds[1].hold_count==1,"Independent retained hold totals")
	local physical={};for line in body:gmatch("[^\n]+") do local entry=json.decode(line);if entry.action=="physical_press" or entry.action=="physical_release" then physical[#physical+1]=entry end end
	assert(#physical==(stopping and 4 or 5),"Only independently expected accepted presses and uncancelled release")
	assert(physical[1].app=="Original" and physical[2].app=="Original" and physical[1].timestamp=="2026-10-05 12:00:00.000" and physical[2].timestamp==physical[1].timestamp and physical[2].hold_ms==800)
	assert(session.retired()==false,"Loss native task still owns actual retirement debt")
	local function settle_and_continue()
		for _,task in ipairs(observed.tasks) do if not task.settled then task.settle() end end
		for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end
	end
	settle_and_continue()
	local retry_delays={}
	if stopping then
		assert(stop_facts.complete==true and stop_facts.callback_retired==false and require("modules.keylogger.physical_history_session").retired()==true,"Completion ACK only after source/native unwind")
	else
	for n,delay in ipairs({1,2,4}) do
		assert(session.status().state=="waiting" and session.status().retries_used==n)
		assert(native.mode.credit_source()==native.mode.SOURCE_GAP)
		local pending={};for _,t in ipairs(timers) do if t.delay==delay and t.live then pending[#pending+1]=t end end
		assert(#pending==1,"Exactly one retained retry timer")
		retry_delays[#retry_delays+1]=delay
		local base=#observed.tasks+1;pending[1]:fire()
		observed.tasks[base].done(0);observed.tasks[base].settle()
		observed.tasks[base+1].done(0,"clock\n","");observed.tasks[base+1].settle()
		local fresh=require("tests.support.physical_stream_frames").new("fresh-"..n,tostring(n+7),{"41"})
		for k,v in pairs(fresh) do v.coverage="complete";native.frames[k]=v end
		local stream=observed.tasks[base+2]
		stream.chunk(nil,"opened\npage\nready\n")
		assert(session.status().state=="admitted" and session.status().retries_used==n,"Actual successor admission does not reset budget")
		native.frames.lost={version=1,kind="lost",coverage="complete",incarnation="fresh-"..n,lease=tostring(n+7),reason="overflow"}
		stream.chunk(nil,"lost\n")
		settle_and_continue()
	end
	assert(session.status().state=="retired" and session.status().retries_used==3)
	end
	local receipt={kind="done",status=session.status(),errors=logs,refused=refused,body=body,holds=holds,retry_delays=retry_delays,stop_facts=stop_facts}
	session.stop();for _,task in ipairs(observed.tasks) do if not task.settled then task.settle() end end
	for _,t in ipairs(timers) do if t.delay==0 and t.live then t:fire() end end
	receipt.retired=session.retired()
	assert(manager.stop({process_exit=true}))
	local function snapshot()
		local database=require("modules.keylogger.sqlite_writer").get_db()
		local result={holds={},presses={},raw_releases=0}
		for row in database:nrows("SELECT date,app,keycode,sum_ms,count,max_ms,tap_count,hold_count FROM agg_app_day_kc_hold ORDER BY app,keycode") do result.holds[#result.holds+1]=row end
		for row in database:nrows("SELECT keycode,SUM(c) AS c FROM ngram_keycodes GROUP BY keycode ORDER BY keycode") do result.presses[#result.presses+1]=row end
		for row in database:nrows("SELECT count(*) AS count FROM events_system WHERE action='physical_release'") do result.raw_releases=row.count end
		return result
	end
	-- Stop completed before the persistence-only reload; old Session/capabilities never reopen.
	for _,name in ipairs({"modules.keylogger.log_manager","modules.keylogger.sqlite_writer","modules.keylogger.aggregator","modules.keylogger.aggregator.state","modules.keylogger.aggregator.core","modules.keylogger.aggregator.events","modules.keylogger.aggregator.sql"}) do package.loaded[name]=nil end
	ports();manager=require("modules.keylogger.log_manager");assert(manager.init(state))
	receipt.live=snapshot()
	for _,phase in ipairs({"rebuild_one","rebuild_two"}) do
		local database=require("modules.keylogger.sqlite_writer").get_db()
		assert(database:exec("UPDATE agg_app_day_kc_hold SET sum_ms=99999,count=99,max_ms=99999,tap_count=99,hold_count=99;")==sqlite.OK)
		assert(database:exec("UPDATE ngram_keycodes SET c=999;")==sqlite.OK)
		assert(database:exec("UPDATE meta SET value='0' WHERE key='aggregate_cache_revision';")==sqlite.OK)
		assert(manager.stop({process_exit=true}))
		for _,name in ipairs({"modules.keylogger.log_manager","modules.keylogger.sqlite_writer","modules.keylogger.aggregator","modules.keylogger.aggregator.state","modules.keylogger.aggregator.core","modules.keylogger.aggregator.events","modules.keylogger.aggregator.sql"}) do package.loaded[name]=nil end
		ports();manager=require("modules.keylogger.log_manager");assert(manager.init(state))
		receipt[phase]=snapshot()
		helpers.assert_eq(receipt[phase],receipt.live,"Real raw rebuild must recover independent totals")
	end
	assert(manager.stop({process_exit=true}))
	assert(#logs==0,table.concat(logs,"\n"))
	print(json.encode(receipt))
end,{frames={clock={version=1,domain="mach_absolute_time",numer=1,denom=1}}})
end)

end
if arg and arg[0] and arg[0]:match('test_physical_history_persistence%.lua$') then child();return end

local h = require("tests.helpers")
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
h.describe("physical history persistence through actual source writers", function()
	h.it("retains accepted history and rebuilds real SQLite after whole-hold cancellation and bounded recovery", function()
		local driver=h.driver_root()
		local source=assert(debug.getinfo(1,"S").source):gsub("^@", "")
		local root=driver.."../../.."
		local script = [[
import importlib.util,json,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location("owned_persistence",root/"tools/diagnostics/hs274_persistence_test.py")
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);m.ROOT=root
os.environ["ERGOPTI_PHYSICAL_SOURCE_ROOT"]=str(root)
for case in ("recovery","stop"):
	os.environ["ERGOPTI_PERSISTENCE_CASE"]=case
	with tempfile.TemporaryDirectory(prefix="ergopti-history-persistence-") as temporary:
		receipt=m.run_fixture(sys.argv[2],temporary,Path(sys.argv[3]).resolve())
		expected={"holds":[{"date":"2026-10-05","app":"Original","keycode":53,"sum_ms":800,"count":1,"max_ms":800,"tap_count":0,"hold_count":1}],"presses":[{"keycode":53,"c":3 if case=="stop" else 4}],"raw_releases":1}
		if not (receipt["live"]==expected):
			raise AssertionError(receipt["live"])
		if not (receipt["rebuild_one"]==expected and receipt["rebuild_two"]==expected):
			raise AssertionError
		if not (receipt["retired"] is True):
			raise AssertionError
		if case=="recovery":
			if not (receipt["retry_delays"]==[1,2,4]):
				raise AssertionError
		if case=="recovery":
			if not (receipt["status"]["state"]=="retired" and receipt["status"]["retries_used"]==3):
				raise AssertionError
		else:
			if not (receipt["stop_facts"]=={"accepted":True,"retired_inside_source":False,"complete":True,"callback_retired":False}):
				raise AssertionError
		if not (not receipt["errors"]):
			raise AssertionError
print("PASS: actual history/file/SQLite composition, two rebuilds and bounded recovery")
]]
		local executable=os.getenv("LUA") or arg[-1]
		assert(type(executable)=="string" and executable~="","The actual suite Lua executable is required")
		local command="python3 -c "..quote(script).." "..quote(root).." "..quote(executable).." "..quote(source).." 2>&1"
		local pipe=assert(io.popen(command,"r"));local output=pipe:read("*a");local ok,kind,status=pipe:close()
		h.assert_eq(ok,true,output);h.assert_eq(kind,"exit",output);h.assert_eq(status,0,output)
		h.assert_eq(output,"PASS: actual history/file/SQLite composition, two rebuilds and bounded recovery\n")
	end)
end)
