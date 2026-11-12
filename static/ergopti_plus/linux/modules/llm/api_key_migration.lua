--- modules/llm/api_key_migration.lua

--- ==============================================================================
--- MODULE: Background API Key Migration (Linux)
--- DESCRIPTION:
--- Moves the API keys an earlier build wrote in plaintext to the desktop secret
--- service without ever blocking the daemon (decided by the maintainer on
--- 2026-11-11). The daemon starts at once; the move runs here, after boot, and
--- tries again until the keyring lets it through.
---
--- FEATURES & RATIONALE:
--- 1. Every secret-service call is an owned child with a deadline
---    (api_token_store.store_async, clear_async, probe_lock_async): a locked
---    keyring whose prompt nobody answers costs one killed child, never the
---    event loop, so input readiness never waits on it. The synchronous move
---    once blocked the boot before the output keyboard opened (cbbf7766).
--- 2. A locked default collection is read over D-Bus, which never prompts, and
---    the attempt waits for the next probe: no unlock prompt opens behind the
---    user's back. An unknown lock state tries the store under its deadline.
--- 3. The plaintext key stays in api_keys.json until the file names its
---    reference: stores first, then one publication without any further
---    secret-service call. A failed publication deletes what this attempt
---    stored, unless an unacknowledged rename may have published it.
--- 4. Retries: after api_key_migration_retry_ms; each failure other than a
---    locked keyring doubles the delay up to api_key_migration_retry_max_ms.
---    Each attempt logs a start paired with its success or its warning.
--- 5. Explicit ownership: init() takes the ports once and refuses a second
---    call; shutdown() cancels the timer and fences every late callback.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Timings = require("infra.timings")

local LOG = "modules.llm.api_key_migration"

local _ports = nil
local _state = "uninitialized"
local _timer = nil
local _attempt = 0
local _delay_ms = nil
-- The child of the running probe or store, cancelled by shutdown().
local _operation = nil
-- Bumped by shutdown(): a callback of an older generation does nothing.
local _generation = 0




-- =========================================
-- =========================================
-- ======= 1/ Attempt ======================
-- =========================================
-- =========================================

local schedule

--- Whether a callback still belongs to the running owner.
--- @param generation number
--- @return boolean
local function current(generation)
	return generation == _generation and _state ~= "stopped"
end

--- Deletes the keys an attempt stored but no file names, without blocking.
--- @param references table List of references.
local function discard(references)
	for _, reference in ipairs(references) do
		_ports.store.clear_async(reference, _ports.store_timeout_ms, function(ok, reason)
			if not ok then
				Logger.warn(LOG, "A key moved for nothing stays in the secret service under '%s': %s.",
					reference, tostring(reason))
			end
		end)
	end
end

--- Ends an attempt that did not move the keys and plans the next one.
--- @param count number Keys still in plaintext.
--- @param reason string
--- @param locked boolean Whether the keyring was locked (no backoff).
local function retry(count, reason, locked)
	local delay = _delay_ms
	if not locked then _delay_ms = math.min(_delay_ms * 2, _ports.retry_max_ms) end
	Logger.warn(LOG, "%d API key(s) stay in plaintext for now (%s); next attempt in %d s.",
		count, reason, math.floor(delay / 1000))
	schedule(delay)
end

--- Stores each key in turn, then publishes the file with their references.
--- @param keys table List of { id, token }.
--- @param generation number
local function store_all(keys, generation)
	local stored, tokens, references = {}, {}, {}
	local function step(index)
		if not current(generation) then
			discard(references)
			return
		end
		if index > #keys then
			local published, reason, uncertain, nothing_left = _ports.entries.publish_migrated(stored, tokens)
			if published then
				_state = "done"
				Logger.success(LOG, "%d plaintext API key(s) moved to the desktop secret service.", #keys)
				return
			end
			if nothing_left then
				-- A save moved every key while this attempt stored its own copies:
				-- the goal is reached, so the copies go and the migration ends
				-- without the « stay in plaintext » warning (AIX-002).
				discard(references)
				_state = "done"
				Logger.success(LOG, "The plaintext API keys were already moved to the desktop secret service by a save.")
				return
			end
			if not uncertain then discard(references) end
			retry(#keys, tostring(reason), false)
			return
		end
		local key = keys[index]
		_operation = _ports.store.store_async(key.id, key.token, _ports.store_timeout_ms, function(reference, reason)
			_operation = nil
			if not current(generation) then
				if reference then discard({ reference }) end
				return
			end
			if not reference then
				discard(references)
				retry(#keys, "the secret service did not store the key of '" .. key.id .. "': "
					.. tostring(reason), false)
				return
			end
			stored[key.id], tokens[key.id] = reference, key.token
			references[#references + 1] = reference
			step(index + 1)
		end)
	end
	step(1)
end

--- One attempt: read what is left, probe the lock, store, publish.
--- @param generation number
local function attempt(generation)
	_timer = nil
	if not current(generation) then return end
	local listed, keys = pcall(_ports.entries.plaintext_keys)
	if not listed then
		Logger.error(LOG, "The plaintext API keys could not be listed: %s.", tostring(keys))
		_state = "failed"
		return
	end
	if #keys == 0 then
		_state = "done"
		Logger.debug(LOG, "No plaintext API key is left to move.")
		return
	end
	_attempt = _attempt + 1
	_state = "running"
	Logger.start(LOG, "Moving %d plaintext API key(s) to the desktop secret service in the background "
		.. "(attempt %d)…", #keys, _attempt)
	_operation = _ports.store.probe_lock_async(_ports.probe_timeout_ms, function(lock, reason)
		_operation = nil
		if not current(generation) then return end
		if lock == "locked" then
			retry(#keys, "the keyring is locked", true)
			return
		end
		if lock == "unknown" then
			Logger.debug(LOG, "Keyring lock state unknown (%s); the store runs under its deadline.", tostring(reason))
		end
		store_all(keys, generation)
	end)
end

--- Arms the next attempt.
--- @param delay_ms number
schedule = function(delay_ms)
	_state = "waiting"
	local generation = _generation
	_timer = _ports.scheduler.after(delay_ms / 1000, function() attempt(generation) end)
end




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Takes the ports once. A second call is refused: one owner moves the keys.
--- @param ports table|nil { entries?, store?, scheduler?, timings? } for tests;
---   production uses modules.llm.api_entries, modules.llm.api_token_store,
---   adapters.timer_scheduler and the registry's api_key_migration_* values
---   (timings: { probe_ms, store_ms, retry_ms, retry_max_ms }).
--- @return boolean initialized
function M.init(ports)
	if _state ~= "uninitialized" then
		Logger.error(LOG, "init(): the API key migration is already initialized — second owner refused.")
		return false
	end
	ports = type(ports) == "table" and ports or {}
	local timings = type(ports.timings) == "table" and ports.timings or {}
	_ports = {
		entries = ports.entries or require("modules.llm.api_entries"),
		store = ports.store or require("modules.llm.api_token_store"),
		scheduler = ports.scheduler or require("adapters.timer_scheduler"),
		probe_timeout_ms = timings.probe_ms or Timings.ms("llm", "api_key_migration_probe_timeout_ms"),
		store_timeout_ms = timings.store_ms or Timings.ms("llm", "api_key_migration_store_timeout_ms"),
		retry_ms = timings.retry_ms or Timings.ms("llm", "api_key_migration_retry_ms"),
		retry_max_ms = timings.retry_max_ms or Timings.ms("llm", "api_key_migration_retry_max_ms"),
	}
	_delay_ms = _ports.retry_ms
	_state = "initialized"
	Logger.debug(LOG, "API key migration initialized.")
	return true
end

--- Arms the first attempt on the next loop turn and returns at once.
--- @return boolean armed
function M.start()
	if _state ~= "initialized" then
		Logger.error(LOG, "start(): the API key migration is %s, not initialized — not started.", _state)
		return false
	end
	schedule(0)
	return true
end

--- Cancels the pending attempt and fences every late callback.
--- @return boolean stopped
function M.shutdown()
	if _state == "running" then
		Logger.warn(LOG, "The daemon stopped before the plaintext API keys moved; the next start tries again.")
	end
	_generation = _generation + 1
	local cancelled = true
	if _timer then cancelled = _ports.scheduler.cancel(_timer) ~= false end
	_timer = nil
	-- A cancelled child calls nothing back; its process group is killed.
	if type(_operation) == "table" and type(_operation.cancel) == "function" then pcall(_operation.cancel, _operation) end
	_operation = nil
	if _state ~= "uninitialized" then _state = "stopped" end
	return cancelled
end

--- Where the migration stands: uninitialized, initialized, waiting, running,
--- done, failed or stopped.
--- @return string
function M.status()
	return _state
end

return M
