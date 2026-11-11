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

--- A fresh store, entries file and migration owner over the stand-ins.
--- @return table migration, table entries, table store
local function fresh()
	os.execute("rm -rf '" .. DIR .. "' && mkdir -p '" .. DIR .. "'")
	write(PATH, LEGACY)
	-- An earlier suite module may leave a stand-in provider catalogue or entries
	-- owner behind; the real ones classify this file's entry.
	for _, name in ipairs({ "modules.llm.api_remote", "modules.llm.local_server_catalogue",
		"llm.provider_config_policy", "llm.local_server_auth" }) do
		package.loaded[name] = nil
	end
	local store = helpers.load_module("modules.llm.api_token_store")
	package.loaded["modules.llm.api_token_store"] = store
	store._set_tool_for_test(TOOL)
	store._set_probe_tool_for_test(PROBE)
	local entries = helpers.load_module("modules.llm.api_entries")
	entries._set_path_for_test(PATH)
	helpers.assert_eq(#entries.plaintext_keys(), 1, "the fixture's plaintext entry loads")
	local migration = helpers.load_module("modules.llm.api_key_migration")
	helpers.assert_eq(migration.init({ entries = entries, store = store,
		timings = { probe_ms = 2000, store_ms = 400, retry_ms = 150, retry_max_ms = 300 } }), true)
	return migration, entries, store
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

--- Runs a case over a fresh migration, always shutting it down after.
--- @param fn function Receives (migration, entries, store).
-- The real child-process owners: an earlier suite module may leave a stand-in
-- that "succeeds" at once without spawning anything, and every case here is
-- about a real child (CI 43024025237: each attempt ended "done" at once).
local PROCESS_OWNERS = { "adapters.owned_process", "adapters.shell_runner", "adapter_errors" }

local function with_migration(fn)
	local saved = {}
	for _, name in ipairs(PROCESS_OWNERS) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	for _, name in ipairs(PROCESS_OWNERS) do require(name) end
	local ok, err = pcall(function()
		local migration, entries, store = fresh()
		local called, failure = pcall(fn, migration, entries, store)
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
		with_migration(function(migration, _, store)
			blocking_tool()
			probe("")
			local before = uv.hrtime()
			helpers.assert_eq(migration.start(), true)
			local elapsed_ms = (uv.hrtime() - before) / 1e6
			helpers.assert_true(elapsed_ms < 100, "start() returns at once, not after the store: " .. elapsed_ms .. " ms")
			-- While the store blocks (its deadline is 400 ms), input stays served.
			local ticks = run_loop(300)
			helpers.assert_true(ticks >= 15, "the loop keeps ticking while secret-tool blocks: " .. ticks)
			helpers.assert_eq(migration.status(), "running")
			local pid = tonumber(read(DIR .. "/blocked.pid") or "")
			helpers.assert_true(pid ~= nil, "the blocking store did run")
			run_loop(8000, function() return migration.status() == "waiting" end)
			helpers.assert_eq(migration.status(), "waiting", "the attempt ended at its deadline and a retry is armed")
			helpers.assert_true(gone(pid), "the blocked secret-tool was killed")
			helpers.assert_eq(read(PATH), LEGACY, "the plaintext key stays until a move succeeds")
			-- The keyring unlocks: the next attempt moves the key.
			working_tool()
			run_loop(8000, function() return migration.status() == "done" end)
			helpers.assert_eq(migration.status(), "done")
			local text = read(PATH)
			helpers.assert_eq(text:find(CANARY, 1, true), nil, "the plaintext key left the file")
			local reference = require("json").decode(text).entries[1].token
			helpers.assert_true(store.is_reference(reference), "the file names the key: " .. tostring(reference))
			helpers.assert_eq(read(DIR .. "/stdin"), CANARY, "secret-tool read the key on its standard input")
			helpers.assert_eq((read(DIR .. "/argv") or ""):find(CANARY, 1, true), nil, "the key never reached an argument")
		end)
	end)

	helpers.it("a locked keyring is waited for without any store, so no prompt opens", function()
		with_migration(function(migration)
			working_tool()
			probe("(<true>,)")
			helpers.assert_eq(migration.start(), true)
			-- start() arms the first attempt in "waiting"; see it run, then let the
			-- probe child settle on its own time under a loaded suite.
			run_loop(2000, function() return migration.status() == "running" end)
			helpers.assert_eq(migration.status(), "running", "the first attempt started")
			run_loop(8000, function() return migration.status() == "waiting" or read(DIR .. "/argv") ~= nil end)
			helpers.assert_eq(read(DIR .. "/argv"), nil, "nothing is stored while the keyring is locked")
			helpers.assert_eq(migration.status(), "waiting")
			helpers.assert_eq(read(PATH), LEGACY)
			probe("(<false>,)")
			run_loop(8000, function() return migration.status() == "done" end)
			helpers.assert_eq(migration.status(), "done", "an unlocked keyring lets the next probe through")
			helpers.assert_eq(read(PATH):find(CANARY, 1, true), nil)
		end)
	end)

	helpers.it("shutdown fences an attempt in flight and refuses a second owner", function()
		with_migration(function(migration)
			blocking_tool()
			probe("")
			helpers.assert_eq(migration.init(), false, "a second init is refused")
			helpers.assert_eq(migration.start(), true)
			helpers.assert_eq(migration.start(), false, "a second start is refused")
			run_loop(400, function() return read(DIR .. "/blocked.pid") ~= nil end)
			local pid = tonumber(read(DIR .. "/blocked.pid") or "")
			helpers.assert_true(pid ~= nil, "the blocking store did run")
			helpers.assert_eq(migration.shutdown(), true)
			helpers.assert_eq(migration.status(), "stopped")
			run_loop(3000, function() return gone(pid) end)
			helpers.assert_true(gone(pid), "shutdown killed the blocked secret-tool")
			working_tool()
			run_loop(800)
			run_loop(3000)
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
