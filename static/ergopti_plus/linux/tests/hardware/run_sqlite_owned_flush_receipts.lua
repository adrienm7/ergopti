--- tests/hardware/run_sqlite_owned_flush_receipts.lua
--- ==============================================================================
--- MODULE: Native Owned SQLite Flush Receipts
--- DESCRIPTION:
--- Real SQLite transactions demonstrate ambiguous COMMIT resolution, coherent
--- post-rollback projections, large private stdin batches, event-loop progress
--- during a stopped SQLite child, and exact shutdown ACKs. Receipt faults are
--- explicit transport seams; SQLite, timers, processes and databases are real.
--- Software collector input is not a claim of evdev/uinput qualification.
--- ==============================================================================

-- Standalone degraded-mode control: the required package is deliberately absent,
-- while SQLite, configuration and the collector remain real. No native owner is
-- replaced with a fake success and no durability claim is made for the RAM data.
if arg[1] == "--no-luv" then
	package.loaded.luv = nil
	package.preload.luv = function() error("deliberately absent native dependency") end
	require("compat.utf8").install()
	local K = require("modules.keylogger.keylogger")
	local W = require("modules.keylogger.sqlite_writer")
	assert(K.init({ sqlite_path = arg[2] .. "/minimal.sqlite", log_dir = arg[2] .. "/logs" }) ~= false)
	assert(K.is_enabled() and W.is_available() and not W.flush_transport_available())
	local revision = W.get_revision()
	K.on_keydown("a", 1000, "minimal")
	assert(K.flush() == false and K.flush() == false)
	assert(not K.has_flush_debt() and not K.is_flush_pending())
	assert(K._pending_buffer_count_for_test() == 1)
	assert(K.get_range_payload().today.minimal.c.a.c == 1)
	assert(K.apply_configuration(assert(K.configuration_snapshot())) == true)
	assert(K.set_app_category("minimal", "productive", 1) == true)
	assert(K.stop() == true and K.stop() == true)
	assert(K._pending_buffer_count_for_test() == 1 and not K.get_flush_status().committed)
	assert(K.get_flush_status().stopping and not K.has_flush_debt())
	assert(#assert(W.query_rows("SELECT id FROM events_typing;")) == 0)
	assert(W.get_revision() == revision, "unavailable flush must not advance the durable watermark")
	assert(W.get_meta("app_score.minimal") == "1")
	local warnings = 0
	for _, line in ipairs(require("logger").ring_buffer_snapshot()) do
		if line:find("SQLite flush transport unavailable", 1, true) then warnings = warnings + 1 end
	end
	assert(warnings == 1)
	W.close_db()
	print("PASS native dependency absent: RAM retained, no saved ACK or phantom debt, configuration live, one warning")
	os.exit(0)
end

local uv = require("luv")
if arg[1] == "--stale-clock" then
	local timeout = require("infra.timings").ms("keylogger", "sqlite_operation_timeout_ms")
	local cached = uv.now()
	uv.sleep(timeout + 50) -- Deliberately leave libuv's cached loop time stale.
	assert(uv.now() == cached, "fixture must not refresh the loop before dispatch")
	local request = assert(require("infra.sqlite_batch_process").start(arg[2] .. "/clock.sqlite", "SELECT 1;",
		{ owner = "native-sqlite-stale-clock", timeout_ms = timeout }))
	local result
	repeat uv.run("nowait"); result = request:poll(); if not result then uv.sleep(1) end until result
	assert(result.ok and result.output == "1\n", "stale cached loop time expired a newly acquired SQLite deadline")
	print("PASS native stale cached loop time cannot shorten a new canonical SQLite deadline")
	os.exit(0)
end
if arg[1] == "--parent-death" then
	local child_pid
	local spawn = uv.spawn
	uv.spawn = function(executable, options, callback)
		local handle, pid = spawn(executable, options, callback)
		child_pid = pid
		return handle, pid
	end
	local request = assert(require("infra.sqlite_batch_process").start(arg[2] .. "/parent.sqlite",
		"WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n;",
		{ owner = "native-sqlite-parent-death", timeout_ms = require("infra.timings").ms("keylogger", "sqlite_operation_timeout_ms") }))
	assert(child_pid)
	io.stdout:write(string.format("READY %d %d\n", uv.os_getpid(), child_pid)); io.stdout:flush()
	uv.run()
	assert(request:is_settled())
	os.exit(0)
end

require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-owned-flush-XXXXXX"))
for _, key in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. key .. "_HOME", root .. "/" .. key:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled=true\n") and config:close())
local K = require("modules.keylogger.keylogger")
local W = require("modules.keylogger.sqlite_writer")
local Process = require("infra.sqlite_batch_process")
local Drain = require("tests.support.sqlite_flush_native")
local Logger = require("logger")
assert(K.init({ sqlite_path = root .. "/metrics.sqlite", log_dir = root .. "/logs" }) ~= false)
assert(K.is_enabled() and W.is_available())
local checks = 0
local function pass(name) checks = checks + 1; print("PASS " .. name) end
local function scalar(sql) return tonumber(assert(W.query_rows(sql))[1]) end
local function total(app)
	local payload = assert(K.get_range_payload())
	local row, count = payload.today[app], 0
	for _, value in pairs(row and row.c or {}) do count = count + value.c end
	return count
end
local function until_true(predicate)
	local deadline = uv.hrtime() + 4000000000
	repeat
		uv.run("nowait"); K.pump_flush()
		if predicate() then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("Native owned SQLite fixture did not receive its physical ACK")
end

-- Fault only the small protocol receipt AFTER the genuine process/pipe/group
-- physically settled. The transaction itself commits on actual SQLite.
local start = Process.start
local writes, reservations, resolutions = 0, 0, 0
Process.start = function(path, sql, options)
	local commit = sql:find("INSERT INTO meta(key,value) VALUES ('linux_flush_commit:", 1, true) ~= nil
	if commit then writes = writes + 1
	elseif sql:find("linux_next_event_id", 1, true) then reservations = reservations + 1
	elseif sql:find("SELECT COUNT(*) FROM meta", 1, true) then resolutions = resolutions + 1 end
	local request = assert(start(path, sql, options))
	if not commit then return request end
	return {
		is_settled = function() return request:is_settled() end,
		cancel = function() return request:cancel() end,
		poll = function() if request:poll() then return { ok = false, output = "" } end end,
	}
end
K.on_keydown("a", 1000, "ambiguous")
assert(K.flush() == false and K.is_flush_pending())
assert(K.reset_session() == false and K.clear_cache() == false and K.migrate_stored_text() == false)
K.on_keydown("b", 1100, "ambiguous")
assert(K._pending_buffer_count_for_test() == 2)
local callbacks = 0
assert(K.when_flush_settled(function() callbacks = callbacks + 1 end))
assert(callbacks == 0)
assert(Drain.wait(K) and callbacks == 1)
assert(total("ambiguous") == 2)
assert(scalar("SELECT SUM(json_array_length(events_json)) FROM events_typing WHERE app='ambiguous';") == 1)
assert(writes == 1 and reservations == 1 and resolutions == 1)
assert(Drain.flush(K))
assert(writes == 2 and reservations == 2 and resolutions == 2)
assert(total("ambiguous") == 2 and scalar("SELECT SUM(c) FROM ngram_chars WHERE app='ambiguous';") == 2)
Process.start = start
pass("lost successful COMMIT receipt resolves its durable marker without replay or duplicate IDs")
pass("new input stays in the next immutable snapshot, mutations refuse pending debt, callbacks require ACK")

assert(W.exec_sql("CREATE TRIGGER refusal BEFORE INSERT ON agg_app_day_chars_class WHEN NEW.app='rollback' "
	.. "BEGIN SELECT RAISE(ABORT,'owned refusal'); END;"))
K.on_keydown("x", 2000, "rollback")
assert(K.flush() == false)
K.on_keydown("y", 2100, "rollback")
assert(not Drain.wait(K))
assert(K.get_flush_status().read_safe and K.has_flush_debt())
assert(total("rollback") == 2 and scalar("SELECT COUNT(*) FROM events_typing WHERE app='rollback';") == 0)
local cursor = W.get_meta("linux_next_event_id")
assert(K.reset_session() == false)
assert(Drain.control(W, "DROP TRIGGER refusal;"))
assert(Drain.flush(K))
assert(total("rollback") == 2 and scalar("SELECT SUM(c) FROM ngram_chars WHERE app='rollback';") == 2)
assert(tonumber(W.get_meta("linux_next_event_id")) == tonumber(cursor) + 1)
pass("conclusive ABORT exposes complete old+new RAM and retries its acknowledged IDs exactly once")

-- A payload larger than Linux's per-argument ceiling must travel only on the
-- inherited stdin pipe, and all raw/derived rows commit on one connection.
local private = "owned-private-sqlite-sentinel-"
local text = private .. string.rep("x", 200000)
local plan = { raw = { typing = { { app = "large", text = text, events_json = "[]" } },
	hotstrings = {}, shortcuts = {}, switches = {} },
	upserts = { { kind = "ngrams", args = { os.date("%Y-%m-%d"), "large", { x = 200000 }, "ngram_chars" } },
		{ kind = "scancodes", args = { os.date("%Y-%m-%d"), "large", {} } } } }
local spawn = uv.spawn
local children, argument_bytes = 0, 0
uv.spawn = function(executable, options, callback)
	for _, value in ipairs(options.args or {}) do
		assert(not value:find(private, 1, true), "private SQL entered argv")
		argument_bytes = argument_bytes + #value
	end
	children = children + 1
	return spawn(executable, options, callback)
end
local operation = assert(W.start_flush("owned", plan))
until_true(function() operation:pump(); return operation:is_settled() end)
uv.spawn = spawn
assert(operation.result.committed and children == 3 and argument_bytes < 4096)
assert(scalar("SELECT length(text) FROM events_typing WHERE app='large';") == #text)
assert(scalar("SELECT c FROM ngram_chars WHERE app='large';") == 200000)
assert(scalar("SELECT COUNT(*) FROM meta WHERE key LIKE 'linux_flush_commit:%';") == 0)
for _, line in ipairs(Logger.ring_buffer_snapshot()) do assert(not line:find(private, 1, true)) end
pass("200 KB private SQL uses bounded argv, one atomic data transaction, and no retained marker/log body")

-- Add a costly SQL expression only to this deliberate fault transaction. Its
-- actual SQLite PID is stopped AFTER exec/PDEATHSIG binding, before COMMIT.
-- The canonical process deadline stays 1000 ms. No production budget is changed.
local selected, current_commit
uv.spawn = function(executable, options, callback)
	local handle, pid = spawn(executable, options, callback)
	if current_commit then selected = pid end
	return handle, pid
end
Process.start = function(path, sql, options)
	current_commit = sql:find("INSERT INTO meta(key,value) VALUES ('linux_flush_commit:", 1, true) ~= nil
	if current_commit then
		local replacements
		sql, replacements = sql:gsub("\nCOMMIT;\n.output", "\nWITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n;\nCOMMIT;\n.output", 1)
		assert(replacements == 1)
	end
	local request = start(path, sql, options)
	current_commit = false
	return request
end
K.on_keydown("p", 4000, "suspended")
assert(K.flush() == false)
until_true(function()
	if not selected then return false end
	local file = io.open("/proc/" .. selected .. "/comm", "r")
	if not file then return false end
	local name = file:read("*l"); file:close()
	return name == "sqlite3"
end)
assert(uv.kill(selected, "sigstop"))
until_true(function()
	local status = assert(io.open("/proc/" .. selected .. "/status", "r"))
	local process_status = status:read("*a"); status:close()
	return process_status:match("State:%s+T") ~= nil
end)
local ticks = 0
local heartbeat = assert(uv.new_timer())
assert(heartbeat:start(0, 1, function()
	ticks = ticks + 1
	K.on_keydown("q", 4000 + ticks, "suspended")
end))
local begin = uv.hrtime()
repeat uv.run("nowait"); K.pump_flush(); uv.sleep(1) until uv.hrtime() - begin >= 20000000
heartbeat:stop(); heartbeat:close()
assert(ticks >= 5 and K.is_flush_pending())
assert(K.get_dashboard_payload() == nil and K.reset_session() == false)
assert(scalar("SELECT COUNT(*) FROM events_typing WHERE app='suspended';") == 0)
assert(not Drain.wait(K))
assert(K.get_flush_status().read_safe and K.has_flush_debt())
assert(total("suspended") == ticks + 1)
assert(not uv.kill(selected, 0), "timed-out SQLite still exists after physical ACK")
Process.start, uv.spawn = start, spawn
assert(Drain.flush(K))
assert(total("suspended") == ticks + 1)
assert(scalar("SELECT SUM(json_array_length(events_json)) FROM events_typing WHERE app='suspended';") == ticks + 1)
pass("stopped native SQLite leaves timers/input seam live, times out, retires physically, and recovers without loss")


-- The persisted reader and uncommitted collector must apply the same selection.
-- Otherwise selecting an app changes counts merely when an unrelated flush lands.
for _, app in ipairs({ "org.example.selected", "org.example.excluded" }) do
	K.on_keydown("a", 4500, app)
	K.record_physical_key(app, 30, 4500)
end
local function selected_projection()
	local today = assert(K.get_range_payload(nil, nil, { "org.example.selected" })).today
	assert(today["org.example.excluded"] == nil, "unselected application reintroduced from live RAM")
	assert(today["org.example.selected"].c.a.c == 1)
	assert(today["org.example.selected"].sc_kb["30"].c == 1)
end
selected_projection()
assert(Drain.flush(K))
selected_projection()
local all_apps = assert(K.get_range_payload()).today
assert(all_apps["org.example.excluded"].c.a.c == 1)
assert(all_apps["org.example.excluded"].sc_kb["30"].c == 1)
pass("selected-app character and physical-key totals are identical before and after actual COMMIT")


-- Inclusive historical/future intervals must exclude both today's persisted
-- data and the newer RAM delta; committing the latter cannot widen the range.
local Reader = require("modules.keylogger.sqlite_reader")
local selected_app = "org.example.selected"
local today = os.date("%Y-%m-%d")
assert(W.upsert_ngrams("owned-range-history", "2020-01-01", selected_app, { h = { c = 3 } }, "ngram_chars"))
K.on_keydown("r", 4600, selected_app)
K.record_physical_key(selected_app, 31, 4600)
for _, phase in ipairs({ "live", "committed" }) do
	for _, bounds in ipairs({ { "2020-01-01", "2020-01-01" }, { "2100-01-01", "2100-01-01" } }) do
		local persisted = Reader.read_range_split_today(W.get_db_path(), bounds[1], bounds[2], { selected_app })
		local public = assert(K.get_range_payload(bounds[1], bounds[2], { selected_app }))
		assert(next(persisted.today) == nil and next(public.today) == nil, "excluded today slice leaked during " .. phase)
		if bounds[1] == "2020-01-01" then
			assert(persisted.historical.c.h.c == 3 and public.historical.c.h.c == 3)
		end
	end
	local included = assert(K.get_range_payload(today, today, { selected_app })).today[selected_app]
	assert(included.c.a.c == 1 and included.c.r.c == 1)
	assert(included.sc_kb["30"].c == 1 and included.sc_kb["31"].c == 1)
	if phase == "live" then assert(Drain.flush(K)) end
end
assert(scalar("SELECT SUM(json_array_length(events_json)) FROM events_typing WHERE app='org.example.selected';") == 2)
pass("inclusive date ranges keep persisted and live slices stable across an actual COMMIT")

K.on_keydown("z", 5000, "stop")
assert(K.flush() == false)
K.on_keydown("q", 5100, "stop")
assert(K.stop() == false and K.get_flush_status().stopping)
K.on_keydown("n", 5200, "stop")
until_true(function() return K.stop() end)
assert(not K.has_flush_debt())
assert(scalar("SELECT SUM(json_array_length(events_json)) FROM events_typing WHERE app='stop';") == 2)
assert(K.flush() == false)
pass("shutdown waits native ACK and one final new-arrival snapshot, with producers already quiesced")
W.close_db()
local function remove(path)
	if assert(uv.fs_lstat(path)).type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else assert(uv.fs_unlink(path)) end
end
remove(root)
assert(checks == 8)
print(string.format("Native owned SQLite flush: %d checks, 0 failures", checks))
