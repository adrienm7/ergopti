--- tests/unit/modules/llm/remote/test_api_key_migration.lua

--- ==============================================================================
--- MODULE: Background API Key Migration Never Blocks The Daemon
--- DESCRIPTION:
--- Decided by the maintainer on 2026-11-11: a plaintext API key moves to the
--- secret service in the background. The boot only arms the move, so a locked
--- keyring (a secret-tool that blocks on a prompt nobody answers) never delays
--- input readiness: the event loop keeps ticking, the store is killed at its
--- deadline, the plaintext key stays in api_keys.json, and a later attempt
--- moves it once the keyring lets it through. The first test failed before
--- the change: the boot ran migrate_plaintext() synchronously and its
--- io.popen of secret-tool held the loop until the child exited (cbbf7766).
--- Real child processes and the real luv loop; only secret-tool and gdbus are
--- stand-ins.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv = require("luv")

local DIR = os.tmpname()
os.remove(DIR)
local PATH = DIR .. "/api_keys.json"
local TOOL = DIR .. "/secret-tool"
local PROBE = DIR .. "/gdbus"
local CANARY = "csk-MIGRATIONCANARY"

local LEGACY = '{"version":1,"active_id":"cerebras-1","entries":[{"id":"cerebras-1","provider":"cerebras",'
	.. '"label":"cerebras/qwen","token":"' .. CANARY .. '","model":"","base_url":""}]}'

--- Writes a file.
--- @param path string
--- @param text string
local function write(path, text)
	local fh = assert(io.open(path, "wb"))
	fh:write(text)
	fh:close()
end

--- Reads a file, or nil.
--- @param path string
--- @return string|nil
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- An executable shell script.
--- @param path string
--- @param body string
local function script(path, body)
	write(path, "#!/bin/sh\n" .. body .. "\n")
	os.execute("chmod 700 '" .. path .. "'")
end

--- A secret-tool whose store blocks, as on a keyring prompt nobody answers.
local function blocking_tool()
	script(TOOL, 'echo $$ > "' .. DIR .. '/blocked.pid"\nexec sleep 30')
end

--- A secret-tool that stores: argv and stdin are recorded apart.
local function working_tool()
	script(TOOL, 'printf "%s\\n" "$*" >> "' .. DIR .. '/argv"\ncat > "' .. DIR .. '/stdin"\nexit 0')
end

--- A gdbus answering the Locked property.
--- @param answer string "(<true>,)", "(<false>,)", or "" to fail (unknown).
local function probe(answer)
	if answer == "" then script(PROBE, "exit 1") else script(PROBE, "printf '%s\\n' '" .. answer .. "'") end
end

--- Runs the real loop until done() or the wall clock passes limit_ms, while a
--- 10 ms ticker stands for input readiness.
--- @param limit_ms number
--- @param done function|nil
--- @return number ticks Ticker firings meanwhile.
local function run_loop(limit_ms, done)
	local ticks = 0
	local ticker = uv.new_timer()
	ticker:start(10, 10, function() ticks = ticks + 1 end)
	uv.update_time()
	local started = uv.now()
	while uv.now() - started < limit_ms and not (done and done()) do
		uv.run("once")
		uv.update_time()
	end
	ticker:stop()
	ticker:close()
	uv.run("nowait")
	return ticks
end

--- A scheduler the test fires by hand: the attempts run when the case says
--- so, never on a timer that can race the loop's tick.
--- @return table scheduler { after, cancel, fire, pending }
local function manual_scheduler()
	local scheduler = { queue = {} }
	function scheduler.after(delay_s, fn)
		local handle = { delay_s = delay_s, fn = fn }
		scheduler.queue[#scheduler.queue + 1] = handle
		return handle
	end
	function scheduler.cancel(handle)
		if type(handle) == "table" then handle.cancelled = true end
		return true
	end
	--- The armed timers not yet fired or cancelled.
	function scheduler.pending()
		local live = {}
		for _, handle in ipairs(scheduler.queue) do
			if not handle.cancelled and not handle.fired then live[#live + 1] = handle end
		end
		return live
	end
	--- Fires the one armed timer, as its delay ending would.
	function scheduler.fire()
		local live = scheduler.pending()
		helpers.assert_eq(#live, 1, "exactly one attempt is armed")
		live[1].fired = true
		live[1].fn()
		return live[1]
	end
	return scheduler
end

--- The store's background calls, recorded in the order their answers arrive:
--- the cases wait on this log, which only grows, never on a passing state.
--- @param store table The real api_token_store.
--- @return table proxy, table log
local function recording_store(store)
	local log = {}
	local proxy = setmetatable({}, { __index = store })
	function proxy.probe_lock_async(timeout_ms, callback)
		log[#log + 1] = "probe"
		return store.probe_lock_async(timeout_ms, function(lock, reason)
			log[#log + 1] = "probe:" .. tostring(lock)
			callback(lock, reason)
		end)
	end
	function proxy.store_async(entry_id, token, timeout_ms, callback)
		log[#log + 1] = "store"
		return store.store_async(entry_id, token, timeout_ms, function(reference, reason)
			log[#log + 1] = reference and "store:ok" or "store:refused"
			callback(reference, reason)
		end)
	end
	return proxy, log
end

--- Whether the log holds an entry.
--- @param log table
--- @param entry string
--- @return boolean
local function logged(log, entry)
	for _, value in ipairs(log) do if value == entry then return true end end
	return false
end

-- Deadlines far above any loop jitter: a case never wins or loses a race
-- against them. The store's own is what the first case waits out.
local PROBE_MS, STORE_MS, RETRY_MS = 10000, 3000, 60000

--- A fresh store, entries file and migration owner over the stand-ins.
--- @return table migration, table entries, table store, table scheduler, table log
local function fresh()
	os.execute("rm -rf '" .. DIR .. "' && mkdir -p '" .. DIR .. "'")
	write(PATH, LEGACY)
	-- An earlier suite module may leave a stand-in provider catalogue or entries
	-- owner behind; the real ones classify this file's entry.
	for _, name in ipairs({ "modules.llm.api_remote", "modules.llm.local_server_catalogue",
		"ai.engine.policy.provider_config_policy", "ai.engine.local_servers.auth" }) do
		package.loaded[name] = nil
	end
	local store = helpers.load_module("modules.llm.api_token_store")
	package.loaded["modules.llm.api_token_store"] = store
	-- Under tests/run.lua an earlier module's secret-service fake can still be
	-- installed on this store (CI 43024025237: each store answered at once, so
	-- every attempt ended "done"); these cases run the real secret-tool path.
	store._set_backend_for_test(nil)
	store._set_async_start_for_test(nil)
	store._set_tool_for_test(TOOL)
	store._set_probe_tool_for_test(PROBE)
	local entries = helpers.load_module("modules.llm.api_entries")
	entries._set_path_for_test(PATH)
	helpers.assert_eq(#entries.plaintext_keys(), 1, "the fixture's plaintext entry loads")
	local scheduler = manual_scheduler()
	local recorded, log = recording_store(store)
	local migration = helpers.load_module("modules.llm.api_key_migration")
	helpers.assert_eq(migration.init({ entries = entries, store = recorded, scheduler = scheduler,
		timings = { probe_ms = PROBE_MS, store_ms = STORE_MS, retry_ms = RETRY_MS, retry_max_ms = RETRY_MS } }), true)
	return migration, entries, store, scheduler, log
end

--- Whether a process is gone.
--- @param pid number|nil
--- @return boolean
local function gone(pid)
	if not pid then return false end
	local probe_pipe = assert(io.popen("kill -0 " .. pid .. " 2>/dev/null && echo alive"))
	local alive = probe_pipe:read("*a")
	probe_pipe:close()
	return not alive:find("alive", 1, true)
end

-- The real child-process owners: an earlier suite module may leave a stand-in
-- that "succeeds" at once without spawning anything, and every case here is
-- about a real child (CI 43024025237: each attempt ended "done" at once).
local PROCESS_OWNERS = { "adapters.owned_process", "adapters.shell_runner", "diagnostics.engine.adapter_errors" }

-- Longest wait for a child to answer: a bound on a loaded runner, never a
-- timing the case relies on.
local SETTLE_MS = 20000

--- Runs a case over a fresh migration, always shutting it down after.
--- @param fn function Receives (migration, entries, store, scheduler, log).
local function with_migration(fn)
	local saved = {}
	for _, name in ipairs(PROCESS_OWNERS) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	for _, name in ipairs(PROCESS_OWNERS) do require(name) end
	local ok, err = pcall(function()
		local migration, entries, store, scheduler, log = fresh()
		local called, failure = pcall(fn, migration, entries, store, scheduler, log)
		migration.shutdown()
		store._set_tool_for_test(nil)
		store._set_probe_tool_for_test(nil)
		-- Let a killed child of a failed case retire before the next case.
		run_loop(100)
		if not called then error(failure, 0) end
	end)
	for _, name in ipairs(PROCESS_OWNERS) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("api_key_migration: a locked keyring never delays input readiness (linux-api-key-background-migration)", function()

	helpers.it("a blocking secret-tool leaves the loop ticking, is killed at its deadline and keeps the plaintext", function()
		with_migration(function(migration, _, store, scheduler, log)
			blocking_tool()
			probe("")
			local before = uv.hrtime()
			helpers.assert_eq(migration.start(), true)
			local elapsed_ms = (uv.hrtime() - before) / 1e6
			helpers.assert_true(elapsed_ms < 100, "start() returns at once, not after the store: " .. elapsed_ms .. " ms")
			helpers.assert_eq(scheduler.pending()[1].delay_s, 0, "the first attempt waits for the next loop turn")
			scheduler.fire()
			helpers.assert_eq(migration.status(), "running")
			run_loop(SETTLE_MS, function() return read(DIR .. "/blocked.pid") ~= nil end)
			local pid = tonumber(read(DIR .. "/blocked.pid") or "")
			helpers.assert_true(pid ~= nil, "the blocking store did run")
			-- While the store blocks, input stays served: the loop keeps ticking
			-- until the store's deadline settles the attempt.
			local ticks = run_loop(SETTLE_MS, function() return logged(log, "store:refused") end)
			helpers.assert_true(logged(log, "store:refused"), "the blocked store was refused at its deadline")
			helpers.assert_true(ticks >= STORE_MS / 1000 * 10, "the loop kept ticking while secret-tool blocked: " .. ticks)
			helpers.assert_eq(migration.status(), "waiting", "a retry is armed")
			helpers.assert_eq(scheduler.pending()[1].delay_s, RETRY_MS / 1000)
			run_loop(SETTLE_MS, function() return gone(pid) end)
			helpers.assert_true(gone(pid), "the blocked secret-tool was killed")
			helpers.assert_eq(read(PATH), LEGACY, "the plaintext key stays until a move succeeds")
			-- The keyring unlocks: the next attempt moves the key.
			working_tool()
			scheduler.fire()
			run_loop(SETTLE_MS, function() return migration.status() == "done" end)
			helpers.assert_eq(migration.status(), "done")
			local text = read(PATH)
			helpers.assert_eq(text:find(CANARY, 1, true), nil, "the plaintext key left the file")
			local reference = require("core.text.engine.json").decode(text).entries[1].token
			helpers.assert_true(store.is_reference(reference), "the file names the key: " .. tostring(reference))
			helpers.assert_eq(read(DIR .. "/stdin"), CANARY, "secret-tool read the key on its standard input")
			helpers.assert_eq((read(DIR .. "/argv") or ""):find(CANARY, 1, true), nil, "the key never reached an argument")
		end)
	end)

	helpers.it("a locked keyring is waited for without any store, so no prompt opens", function()
		with_migration(function(migration, _, _, scheduler, log)
			working_tool()
			probe("(<true>,)")
			helpers.assert_eq(migration.start(), true)
			scheduler.fire()
			helpers.assert_eq(migration.status(), "running", "the first attempt started")
			run_loop(SETTLE_MS, function() return logged(log, "probe:locked") end)
			helpers.assert_true(logged(log, "probe:locked"), "the probe read the keyring locked")
			helpers.assert_eq(logged(log, "store"), false, "nothing is stored while the keyring is locked")
			helpers.assert_eq(read(DIR .. "/argv"), nil, "secret-tool never ran")
			helpers.assert_eq(migration.status(), "waiting")
			helpers.assert_eq(scheduler.pending()[1].delay_s, RETRY_MS / 1000, "a locked keyring is probed again later")
			helpers.assert_eq(read(PATH), LEGACY)
			probe("(<false>,)")
			scheduler.fire()
			run_loop(SETTLE_MS, function() return migration.status() == "done" end)
			helpers.assert_eq(migration.status(), "done", "an unlocked keyring lets the next probe through")
			helpers.assert_true(logged(log, "probe:unlocked") and logged(log, "store:ok"))
			helpers.assert_eq(read(PATH):find(CANARY, 1, true), nil)
		end)
	end)

	helpers.it("shutdown fences an attempt in flight and refuses a second owner", function()
		with_migration(function(migration, _, _, scheduler, log)
			blocking_tool()
			probe("")
			helpers.assert_eq(migration.init(), false, "a second init is refused")
			helpers.assert_eq(migration.start(), true)
			helpers.assert_eq(migration.start(), false, "a second start is refused")
			scheduler.fire()
			run_loop(SETTLE_MS, function() return read(DIR .. "/blocked.pid") ~= nil end)
			local pid = tonumber(read(DIR .. "/blocked.pid") or "")
			helpers.assert_true(pid ~= nil, "the blocking store did run")
			helpers.assert_eq(migration.shutdown(), true)
			helpers.assert_eq(migration.status(), "stopped")
			run_loop(SETTLE_MS, function() return gone(pid) end)
			helpers.assert_true(gone(pid), "shutdown killed the blocked secret-tool")
			helpers.assert_eq(#scheduler.pending(), 0, "no attempt stays armed")
			helpers.assert_eq(logged(log, "store:refused") or logged(log, "store:ok"), false,
				"a cancelled child calls nothing back")
			helpers.assert_eq(read(PATH), LEGACY, "nothing is published after shutdown")
		end)
	end)

	helpers.it("the boot arms the background move and never runs the synchronous one", function()
		local source = read(helpers.driver_root() .. "/ergopti_hotstrings.lua")
		helpers.assert_true(source ~= nil and source:find("modules.llm.api_key_migration", 1, true) ~= nil,
			"the boot starts the background owner")
		helpers.assert_true(source:find("migration.init() and migration.start()", 1, true) ~= nil,
			"init and start, inside a pcall so a failure never stops the boot")
		helpers.assert_eq(source:find("migrate_plaintext", 1, true), nil,
			"the blocking move is not on the boot path")
	end)
end)

-- The migration's own outcomes over faked ports: a save that moved every key
-- first (AIX-002) and a shutdown in the middle of an attempt (AIX-003).
helpers.describe("api_key_migration: an attempt overtaken by a save or a shutdown", function()
	--- Loads a fresh migration over scripted entries and store ports.
	local function faked()
		local saved_migration, saved_logger = package.loaded["modules.llm.api_key_migration"], package.loaded["core.logger.engine.shim"]
		local world = { logs = {}, timers = {}, pending = {}, cleared = {}, plaintext = 2 }
		package.loaded["core.logger.engine.shim"] = setmetatable({}, { __index = function(_, level)
			return function(_, fmt, ...) world.logs[#world.logs + 1] = level .. ": " .. string.format(fmt, ...) end
		end })
		package.loaded["modules.llm.api_key_migration"] = nil
		local migration = require("modules.llm.api_key_migration")
		assert(migration.init({
			entries = {
				plaintext_keys = function()
					if world.plaintext == 0 then return {} end
					return { { id = "a", token = "ka" }, { id = "b", token = "kb" } }
				end,
				publish_migrated = function()
					if world.plaintext == 0 then return false, "no plaintext key is left to move", false, true end
					world.plaintext = 0
					return true
				end,
			},
			store = {
				probe_lock_async = function(_, callback) callback("unlocked") end,
				store_async = function(id, _, _, callback)
					world.pending[#world.pending + 1] = { id = id, callback = callback }
					return { cancel = function() end }
				end,
				clear_async = function(reference, _, callback) world.cleared[#world.cleared + 1] = reference; callback(true) end,
			},
			scheduler = {
				after = function(_, fn) world.timers[#world.timers + 1] = fn; return {} end,
				cancel = function() return true end,
			},
			timings = { probe_ms = 1, store_ms = 1, retry_ms = 60000, retry_max_ms = 1800000 },
		}))
		world.restore = function()
			migration.shutdown()
			package.loaded["modules.llm.api_key_migration"] = saved_migration
			package.loaded["core.logger.engine.shim"] = saved_logger
		end
		return migration, world
	end

	helpers.it("(aix-002-migration-overtaken) a save that moved every key ends the migration without a warning", function()
		local migration, world = faked()
		migration.start(); table.remove(world.timers, 1)()
		world.pending[1].callback("secret-service:a#1")
		world.plaintext = 0 -- the menu's save stored both keys itself
		world.pending[2].callback("secret-service:b#1")
		helpers.assert_eq(migration.status(), "done")
		for _, line in ipairs(world.logs) do
			helpers.assert_true(not line:find("stay in plaintext", 1, true), "false warning: " .. line)
		end
		helpers.assert_eq(world.cleared, { "secret-service:a#1", "secret-service:b#1" }, "the attempt's own copies go")
		helpers.assert_eq(#world.timers, 0, "no further attempt is armed")
		world.restore()
	end)

	helpers.it("(aix-003-migration-shutdown-orphans) a shutdown discards the keys the attempt already stored", function()
		local migration, world = faked()
		migration.start(); table.remove(world.timers, 1)()
		world.pending[1].callback("secret-service:a#2")
		helpers.assert_eq(migration.shutdown(), true)
		helpers.assert_eq(world.cleared, { "secret-service:a#2" }, "no stored key is left named by no file")
		world.restore()
	end)
end)
