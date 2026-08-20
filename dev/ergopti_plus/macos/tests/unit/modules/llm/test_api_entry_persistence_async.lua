--- tests/unit/modules/llm/test_api_entry_persistence_async.lua

--- ==============================================================================
--- MODULE: Regression — transactional remote API credential persistence
--- DESCRIPTION:
--- Drives the real modules.llm persistence coordinator with controllable
--- Keychain and settings ports. The assertions prove plaintext exclusion,
--- exact readback, supersession fencing, and durable delete tombstones.
--- ==============================================================================

local helpers = require("tests.helpers")

local API_STATE_KEY = "llm_api_state_v1"
local API_CLEANUP_JOURNAL_KEY = "llm_api_keychain_cleanup_v1"

local function contains_string(value, needle, seen)
	if type(value) == "string" then return value:find(needle, 1, true) ~= nil end
	if type(value) ~= "table" then return false end
	seen = seen or {}
	if seen[value] then return false end
	seen[value] = true
	for key, child in pairs(value) do
		if contains_string(key, needle, seen) or contains_string(child, needle, seen) then return true end
	end
	return false
end

local function with_persistence_fixture(options, body)
	options = options or {}
	local module_names = {
		"modules.llm", "modules.llm.profiles", "modules.llm.api_ollama",
		"modules.llm.api_mlx", "modules.llm.api_remote",
		"modules.llm.api_token_crypto", "modules.llm.api_common",
		"infra.logger", "infra.paths", "adapters.timer_scheduler", "adapters.storage",
	}
	local saved = {}
	for _, name in ipairs(module_names) do saved[name] = package.loaded[name] end

	local store = options.initial_store or {}
	local setting_writes = 0
	local fixture = {
		store = store,
		encrypt_jobs = {},
		delete_jobs = {},
		cancel_calls = 0,
		cancel_attempt_ids = {},
		errors = {},
	}
	local entries = options.entries or {}
	local active_id = options.active_id or ""
	local api_remote = {
		set_entries = function(value) entries = value end,
		get_entries = function() return entries end,
		set_active_entry_id = function(value) active_id = value end,
		get_active_entry_id = function() return active_id end,
		prewarm_active_entry_decrypt = function() end,
	}

	package.loaded["modules.llm.profiles"] = { BUILTIN_PROFILES = {} }
	package.loaded["modules.llm.api_ollama"] = {}
	package.loaded["modules.llm.api_mlx"] = {}
	package.loaded["modules.llm.api_remote"] = api_remote
	package.loaded["modules.llm.api_common"] = {}
	package.loaded["modules.llm.api_token_crypto"] = {
		is_encrypted = function(value)
			return type(value) == "string" and value:sub(1, 9) == "keychain:"
		end,
		encrypt_async = function(entry_id, cleartext, callback)
			local job = { id = entry_id, cleartext = cleartext, cancelled = false }
			job.callback = function(ok, reference, reason)
				if job.cancelled then
					callback(false, nil, "cancelled")
				else
					callback(ok, reference, reason)
				end
			end
			fixture.encrypt_jobs[#fixture.encrypt_jobs + 1] = job
			local operation = {
				cancel = function()
					if job.cancelled then return false, "pending" end
					fixture.cancel_calls = fixture.cancel_calls + 1
					fixture.cancel_attempt_ids[#fixture.cancel_attempt_ids + 1] = job.id
					if options.cancel_mode == "refused" then return false, "refused" end
					job.cancelled = true
					if options.cancel_mode == "synchronous" then
						job.callback(false, nil, "cancelled")
						return true, "settled"
					end
					return false, "pending"
				end,
			}
			job.operation = operation
			if type(options.on_encrypt_start) == "function" then
				options.on_encrypt_start(job, #fixture.encrypt_jobs, fixture)
			end
			return operation
		end,
		delete_async = function(entry_id, callback)
			local job = { id = entry_id, callback = callback }
			fixture.delete_jobs[#fixture.delete_jobs + 1] = job
			if options.delete_immediately ~= false then callback(true, nil) end
			return { cancel = function() return true end }
		end,
	}
	package.loaded["infra.logger"] = {
		debug = function() end, info = function() end, warn = function() end,
		start = function() end, success = function() end, done = function() end,
		error = function(_, fmt, ...)
			fixture.errors[#fixture.errors + 1] = string.format(tostring(fmt), ...)
		end,
		pcall = function(_, fn, ...) return pcall(fn, ...) end,
	}
	package.loaded["infra.paths"] = {
		shared = function(relative)
			return "static/ergopti_plus/_shared/" .. relative
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function() return { timer = true, committed = true }, true end,
		cancel = function() return true end,
		now = function() return 0 end,
	}

	local settings = {
		get = function(key) return store[key] end,
		set = function(key, value)
			setting_writes = setting_writes + 1
			if options.throw_on_write == setting_writes then error("settings write exploded") end
			if options.corrupt_on_write == setting_writes and key == API_STATE_KEY then
				store[key] = { corrupt = true }
			else
				store[key] = value
			end
		end,
		clear = function(key) store[key] = nil end,
	}
	package.loaded["adapters.storage"] = {
		set = function(key, value)
			local ok = pcall(settings.set, key, value)
			return ok
		end,
		read_exact = function(key)
			local ok, value = pcall(settings.get, key)
			return ok, ok and value or nil
		end,
		delete_exact = function(key)
			return pcall(settings.clear, key)
		end,
	}

	package.loaded["modules.llm"] = nil
	local ok, err = xpcall(function()
		local llm = helpers.load_with_stubs("modules.llm", { settings = settings })
		fixture.llm = llm
		fixture.api_remote = api_remote
		fixture.get_entries = function() return entries end
		fixture.get_active_id = function() return active_id end
		body(llm, fixture)
	end, debug.traceback)
	for _, name in ipairs(module_names) do package.loaded[name] = saved[name] end
	if not ok then error(err) end
end

helpers.describe("LLM API persistence transaction", function()
	helpers.it("migrates legacy plaintext without copying it into the combined state", function()
		local initial = {
			llm_api_entries = {
				{ id = "entry-a", provider = "openai", token = "legacy-plain-secret", model = "gpt" },
			},
			llm_api_entry_id = "entry-a",
		}
		with_persistence_fixture({ initial_store = initial }, function(llm, fixture)
			helpers.assert_eq(llm.load_api_entries(), true)
			helpers.assert_eq(#fixture.encrypt_jobs, 1,
				"legacy plaintext must migrate automatically without a later menu action")
			helpers.assert_eq(fixture.store[API_STATE_KEY], nil,
				"combined state must remain absent until legacy plaintext reaches Keychain")
			helpers.assert_true(not contains_string(
				fixture.store[API_CLEANUP_JOURNAL_KEY], "legacy-plain-secret"),
				"the crash journal may contain identifiers only")

			fixture.encrypt_jobs[1].callback(true, "keychain:entry-a", nil)
			helpers.assert_eq(fixture.store[API_STATE_KEY].entries[1].token, "keychain:entry-a")
			helpers.assert_eq(fixture.store.llm_api_entries, nil,
				"successful migration must erase the obsolete plaintext-bearing key")
			helpers.assert_eq(fixture.store.llm_api_entry_id, nil)
			helpers.assert_eq(fixture.store[API_CLEANUP_JOURNAL_KEY], nil)
		end)
	end)

	helpers.it("migrates reference-only legacy keys into one combined snapshot", function()
		local initial = {
			llm_api_entries = {
				{ id = "entry-a", provider = "openai", token = "keychain:entry-a", model = "gpt" },
			},
			llm_api_entry_id = "entry-a",
		}
		with_persistence_fixture({ initial_store = initial }, function(llm, fixture)
			helpers.assert_eq(llm.load_api_entries(), true)
			helpers.assert_eq(#fixture.encrypt_jobs, 0,
				"an opaque reference needs no redundant Keychain writer")
			helpers.assert_eq(fixture.store[API_STATE_KEY].entries[1].token, "keychain:entry-a")
			helpers.assert_eq(fixture.store[API_STATE_KEY].active_id, "entry-a")
			helpers.assert_eq(fixture.store.llm_api_entries, nil)
			helpers.assert_eq(fixture.store.llm_api_entry_id, nil)
		end)
	end)

	helpers.it("refuses a malformed combined state instead of resurrecting stale legacy keys", function()
		local initial = {
			[API_STATE_KEY] = { corrupt = true },
			llm_api_entries = {
				{ id = "deleted-entry", token = "legacy-plain-secret" },
			},
			llm_api_entry_id = "deleted-entry",
		}
		with_persistence_fixture({ initial_store = initial }, function(llm, fixture)
			helpers.assert_eq(llm.load_api_entries(), false)
			helpers.assert_eq(#fixture.get_entries(), 0,
				"stale legacy entries must not reappear after combined-state corruption")
			helpers.assert_eq(fixture.get_active_id(), "")
		end)
	end)

	helpers.it("rejects sparse arrays before a hidden plaintext token can bypass validation", function()
		local initial = {
			[API_STATE_KEY] = {
				version = 1,
				entries = {
					[2] = { id = "hidden-entry", token = "hidden-plain-secret" },
				},
				active_id = "hidden-entry",
				pending_keychain_deletes = {},
			},
		}
		with_persistence_fixture({ initial_store = initial }, function(llm, fixture)
			helpers.assert_eq(llm.load_api_entries(), false,
				"a sparse persisted entry array must fail closed")
			helpers.assert_eq(#fixture.get_entries(), 0,
				"the hidden plaintext entry must never enter runtime state")
		end)
	end)

	helpers.it("rejects a dense combined entry missing canonical identity fields", function()
		local initial = {
			[API_STATE_KEY] = {
				version = 1,
				entries = {
					{ id = "entry-a", token = "keychain:entry-a", model = "gpt" },
				},
				active_id = "entry-a",
				pending_keychain_deletes = {},
			},
		}
		with_persistence_fixture({ initial_store = initial }, function(llm, fixture)
			helpers.assert_eq(llm.load_api_entries(), false)
			helpers.assert_eq(#fixture.get_entries(), 0,
				"an entry without provider identity must never reach menu/network state")
		end)
	end)

	helpers.it("rejects malformed, duplicate, and inconsistent combined identities", function()
		local function entry(overrides)
			local value = {
				id = "entry-a", provider = "openai", token = "keychain:entry-a", model = "gpt",
			}
			for key, child in pairs(overrides or {}) do value[key] = child end
			return value
		end
		local cases = {
			{ label = "empty id", entries = { entry({ id = "" }) }, active_id = "" },
			{ label = "non-string id", entries = { entry({ id = 9 }) }, active_id = "" },
			{ label = "non-string provider", entries = { entry({ provider = 7 }) }, active_id = "entry-a" },
			{ label = "empty provider", entries = { entry({ provider = "" }) }, active_id = "entry-a" },
			{ label = "non-string model", entries = { entry({ model = false }) }, active_id = "entry-a" },
			{ label = "empty model", entries = { entry({ model = "" }) }, active_id = "entry-a" },
			{ label = "non-string token", entries = { entry({ token = {} }) }, active_id = "entry-a" },
			{ label = "empty token", entries = { entry({ token = "" }) }, active_id = "entry-a" },
			{ label = "plaintext combined token", entries = { entry({ token = "plain-secret" }) }, active_id = "entry-a" },
			{
				label = "duplicate id",
				entries = { entry(), entry({ provider = "anthropic", token = "keychain:entry-b" }) },
				active_id = "entry-a",
			},
			{ label = "unknown active id", entries = { entry() }, active_id = "missing" },
		}
		for _, case in ipairs(cases) do
			local initial = {
				[API_STATE_KEY] = {
					version = 1,
					entries = case.entries,
					active_id = case.active_id,
					pending_keychain_deletes = {},
				},
			}
			with_persistence_fixture({ initial_store = initial }, function(llm, fixture)
				helpers.assert_eq(llm.load_api_entries(), false,
					"combined corruption must fail closed: " .. case.label)
				helpers.assert_eq(#fixture.get_entries(), 0,
					"invalid combined entry reached runtime: " .. case.label)
			end)
		end
	end)

	helpers.it("rejects cross-entry Keychain references in combined and legacy snapshots", function()
		local cases = {
			{
				label = "combined",
				initial_store = {
					[API_STATE_KEY] = {
						version = 1,
						entries = {
							{ id = "entry-a", provider = "openai", token = "keychain:entry-b", model = "gpt" },
						},
						active_id = "entry-a",
						pending_keychain_deletes = {},
					},
				},
			},
			{
				label = "legacy",
				initial_store = {
					llm_api_entries = {
						{ id = "entry-a", provider = "openai", token = "keychain:entry-b", model = "gpt" },
					},
					llm_api_entry_id = "entry-a",
				},
			},
		}
		for _, case in ipairs(cases) do
			with_persistence_fixture({ initial_store = case.initial_store }, function(llm, fixture)
				helpers.assert_eq(llm.load_api_entries(), false,
					"cross-entry Keychain reference must fail closed: " .. case.label)
				helpers.assert_eq(#fixture.get_entries(), 0,
					"corrupt credential identity reached runtime: " .. case.label)
				helpers.assert_eq(#fixture.encrypt_jobs, 0,
					"corrupt Keychain reference must not be treated as migratable plaintext: " .. case.label)
			end)
		end
	end)

	helpers.it("never writes plaintext and reports encryption failure without success", function()
		with_persistence_fixture({
			entries = { { id = "entry-a", provider = "openai", token = "plain-secret", model = "gpt" } },
			active_id = "entry-a",
		}, function(llm, fixture)
			local results = {}
			llm.persist_api_entries(function(...) results[#results + 1] = table.pack(...) end)
			helpers.assert_eq(#fixture.encrypt_jobs, 1)
			helpers.assert_eq(fixture.store[API_CLEANUP_JOURNAL_KEY], { "entry-a" },
				"cleanup tombstone must be durable before Keychain receives plaintext")
			helpers.assert_true(not contains_string(fixture.store, "plain-secret"),
				"no intermediate settings value may contain the cleartext token")

			fixture.encrypt_jobs[1].callback(false, nil, "denied")
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1][1], false)
			helpers.assert_eq(results[1][3], false,
				"an encryption failure must never be reported as durable success")
			helpers.assert_true(not contains_string(fixture.store, "plain-secret"))
		end)
	end)

	helpers.it("keeps ownership of the live second writer after synchronous first completion", function()
		with_persistence_fixture({
			entries = {
				{ id = "entry-a", provider = "openai", token = "secret-a", model = "gpt-a" },
				{ id = "entry-b", provider = "anthropic", token = "secret-b", model = "gpt-b" },
			},
			active_id = "entry-a",
			on_encrypt_start = function(job, launch_index)
				if launch_index == 1 then
					job.callback(true, "keychain:" .. job.id, nil)
				end
			end,
		}, function(llm, fixture)
			local first, second = {}, {}
			llm.persist_api_entries(function(...) first[#first + 1] = table.pack(...) end)
			helpers.assert_eq(#fixture.encrypt_jobs, 2)
			helpers.assert_eq(#first, 0)

			llm.persist_api_entries(function(...) second[#second + 1] = table.pack(...) end)
			helpers.assert_eq(fixture.cancel_attempt_ids[1], "entry-b",
				"the returned handle for completed job 1 must not overwrite live job 2 ownership")
			helpers.assert_true(fixture.encrypt_jobs[2].cancelled,
				"supersession must logically cancel the exact live second writer")
			helpers.assert_eq(#first, 0,
				"an accepted cancellation request is not native mutation settlement")
			helpers.assert_eq(#fixture.encrypt_jobs, 2,
				"the successor must not overlap the still-live second writer")

			fixture.encrypt_jobs[2].callback(true, "keychain:entry-b", nil)
			helpers.assert_eq(#first, 1)
			helpers.assert_eq(#fixture.encrypt_jobs, 3)

			fixture.encrypt_jobs[3].callback(true, "keychain:entry-a", nil)
			helpers.assert_eq(#fixture.encrypt_jobs, 4)
			fixture.encrypt_jobs[4].callback(true, "keychain:entry-b", nil)
			helpers.assert_eq(#second, 1)
			helpers.assert_eq(second[1][1], true)
		end)
	end)

	helpers.it("does not retain or cancel handles for synchronously completed writers", function()
		with_persistence_fixture({
			entries = {
				{ id = "entry-a", provider = "openai", token = "secret-a", model = "gpt-a" },
				{ id = "entry-b", provider = "anthropic", token = "secret-b", model = "gpt-b" },
			},
			active_id = "entry-a",
			on_encrypt_start = function(job)
				job.callback(true, "keychain:" .. job.id, nil)
			end,
		}, function(llm, fixture)
			local results = {}
			llm.persist_api_entries(function(...) results[#results + 1] = table.pack(...) end)
			helpers.assert_eq(#fixture.encrypt_jobs, 2)
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1][1], true)
			helpers.assert_eq(fixture.cancel_calls, 0,
				"already-completed native handles must never be reacquired then cancelled during stack unwind")
			helpers.assert_eq(fixture.store[API_STATE_KEY].entries[1].token, "keychain:entry-a")
			helpers.assert_eq(fixture.store[API_STATE_KEY].entries[2].token, "keychain:entry-b")
			helpers.assert_true(not contains_string(fixture.store, "secret-a"))
			helpers.assert_true(not contains_string(fixture.store, "secret-b"))
		end)
	end)

	helpers.it("finishes exactly once when encryption fails synchronously", function()
		with_persistence_fixture({
			entries = {
				{ id = "entry-a", provider = "openai", token = "secret-a", model = "gpt-a" },
				{ id = "entry-b", provider = "anthropic", token = "secret-b", model = "gpt-b" },
			},
			active_id = "entry-a",
			on_encrypt_start = function(job)
				job.callback(false, nil, "synchronous_denial")
			end,
		}, function(llm, fixture)
			local results = {}
			llm.persist_api_entries(function(...) results[#results + 1] = table.pack(...) end)
			helpers.assert_eq(#fixture.encrypt_jobs, 1,
				"a synchronous first failure must prevent the second writer from starting")
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1][1], false)
			helpers.assert_eq(results[1][2], "synchronous_denial")
			helpers.assert_eq(fixture.cancel_calls, 0,
				"a synchronously failed handle must not be reacquired during stack unwind")
			helpers.assert_true(not contains_string(fixture.store, "secret-a"))
			helpers.assert_true(not contains_string(fixture.store, "secret-b"))
		end)
	end)

	helpers.it("rejects a successful encryption callback for a different Keychain account", function()
		with_persistence_fixture({
			entries = {
				{ id = "entry-a", provider = "openai", token = "secret-a", model = "gpt-a" },
			},
			active_id = "entry-a",
			on_encrypt_start = function(job)
				job.callback(true, "keychain:entry-b", nil)
			end,
		}, function(llm, fixture)
			local results = {}
			llm.persist_api_entries(function(...) results[#results + 1] = table.pack(...) end)
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1][1], false)
			helpers.assert_eq(results[1][2], "keychain_encrypt_failed")
			helpers.assert_eq(fixture.store[API_STATE_KEY], nil,
				"a cross-entry credential reference must never become durable")
			helpers.assert_eq(fixture.cancel_calls, 0)
			helpers.assert_true(not contains_string(fixture.store, "secret-a"))
		end)
	end)

	helpers.it("rejects a mismatched final readback and restores the tombstoned prior state", function()
		with_persistence_fixture({
			entries = { { id = "entry-a", provider = "openai", token = "plain-secret", model = "gpt" } },
			active_id = "entry-a",
			corrupt_on_write = 2,
			delete_immediately = false,
		}, function(llm, fixture)
			local result = nil
			llm.persist_api_entries(function(...) result = table.pack(...) end)
			fixture.encrypt_jobs[1].callback(true, "keychain:entry-a", nil)
			helpers.assert_true(result ~= nil)
			helpers.assert_eq(result[1], false)
			helpers.assert_eq(result[2], "settings_readback_failed")
			helpers.assert_eq(fixture.store[API_STATE_KEY], nil,
				"failed first combined publication must leave the legacy/new state key absent")
			helpers.assert_eq(fixture.store[API_CLEANUP_JOURNAL_KEY], { "entry-a" },
				"rollback must retain the plaintext-free orphan-cleanup journal")
			helpers.assert_true(not contains_string(fixture.store, "plain-secret"))
		end)
	end)

	helpers.it("waits for superseded native completion and cleanup before starting a successor", function()
		with_persistence_fixture({
			entries = { { id = "entry-a", provider = "openai", token = "new-secret", model = "gpt" } },
			active_id = "entry-a",
			delete_immediately = false,
		}, function(llm, fixture)
			local first, second = {}, {}
			llm.persist_api_entries(function(...) first[#first + 1] = table.pack(...) end)
			llm.persist_api_entries(function(...) second[#second + 1] = table.pack(...) end)
			helpers.assert_eq(fixture.cancel_calls, 1,
				"starting a newer save must cancel the exact older encryption owner")
			helpers.assert_eq(#first, 0,
				"SIGTERM/cancellation request must not settle a native Keychain mutation")
			helpers.assert_eq(#fixture.encrypt_jobs, 1,
				"the successor must wait for the old helper's native completion")
			helpers.assert_eq(#fixture.delete_jobs, 0,
				"orphan cleanup cannot race the still-running writer")

			fixture.encrypt_jobs[1].callback(true, "keychain:entry-a", nil)
			helpers.assert_eq(#first, 1)
			helpers.assert_eq(first[1][2], "cancelled")
			helpers.assert_eq(#fixture.delete_jobs, 1,
				"cleanup starts only after the cancelled helper naturally settles")
			helpers.assert_eq(#fixture.encrypt_jobs, 1,
				"cleanup must commit before a successor can reuse the account")
			fixture.delete_jobs[1].callback(true, nil)
			helpers.assert_eq(#fixture.encrypt_jobs, 2)

			fixture.encrypt_jobs[2].callback(true, "keychain:entry-a", nil)
			helpers.assert_eq(#second, 1)
			helpers.assert_eq(second[1][1], true)
			fixture.encrypt_jobs[2].callback(true, "keychain:entry-a", nil)
			helpers.assert_eq(#second, 1,
				"duplicate encryption callbacks must not republish persistence completion")
			helpers.assert_eq(fixture.store[API_STATE_KEY].entries[1].token, "keychain:entry-a")
		end)
	end)

	helpers.it("never starts a successor while exact writer termination is refused", function()
		with_persistence_fixture({
			entries = { { id = "entry-a", provider = "openai", token = "secret-a", model = "gpt" } },
			active_id = "entry-a",
			cancel_mode = "refused",
		}, function(llm, fixture)
			local first, second = {}, {}
			llm.persist_api_entries(function(...) first[#first + 1] = table.pack(...) end)
			fixture.api_remote.set_entries({
				{ id = "entry-a", provider = "openai", token = "secret-b", model = "gpt" },
			})
			llm.persist_api_entries(function(...) second[#second + 1] = table.pack(...) end)

			helpers.assert_eq(fixture.cancel_calls, 1)
			helpers.assert_eq(#fixture.encrypt_jobs, 1,
				"a refused termination must prevent overlapping writes for the same account")
			helpers.assert_eq(#second, 1)
			helpers.assert_eq(second[1][1], false)
			helpers.assert_eq(second[1][2], "prior_cancellation_refused")
			helpers.assert_eq(#first, 0,
				"the old operation must remain owned until its native completion arrives")

			fixture.encrypt_jobs[1].callback(true, "keychain:entry-a", nil)
			helpers.assert_eq(#first, 1)
			helpers.assert_eq(first[1][1], false,
				"the now-stale old write must not publish settings after it finally settles")
			helpers.assert_eq(#fixture.encrypt_jobs, 1)
		end)
	end)

	helpers.it("keeps a durable delete tombstone until Keychain deletion succeeds", function()
		local initial = {
			[API_STATE_KEY] = {
				version = 1,
				entries = { { id = "entry-a", provider = "openai", token = "keychain:entry-a", model = "gpt" } },
				active_id = "entry-a",
				pending_keychain_deletes = {},
			},
		}
		with_persistence_fixture({ initial_store = initial, delete_immediately = false }, function(llm, fixture)
			helpers.assert_eq(llm.load_api_entries(), true)
			fixture.api_remote.set_entries({})
			fixture.api_remote.set_active_entry_id("")
			local result = nil
			llm.persist_api_entries(function(...) result = table.pack(...) end,
				{ delete_entry_ids = { "entry-a" } })
			helpers.assert_eq(#fixture.delete_jobs, 1)
			helpers.assert_eq(fixture.store[API_STATE_KEY].pending_keychain_deletes, { "entry-a" })
			fixture.delete_jobs[1].callback(false, "locked")
			helpers.assert_eq(result[1], false)
			helpers.assert_eq(result[3], true,
				"entry removal is durable even while cleanup remains pending")
			helpers.assert_eq(fixture.store[API_STATE_KEY].pending_keychain_deletes, { "entry-a" },
				"failed cleanup must leave a retryable durable tombstone")
			fixture.delete_jobs[1].callback(true, nil)
			helpers.assert_eq(fixture.store[API_STATE_KEY].pending_keychain_deletes, { "entry-a" },
				"a duplicate completion must not erase a tombstone after the first failure")

			llm.retry_pending_api_token_deletes()
			helpers.assert_eq(#fixture.delete_jobs, 2)
			fixture.delete_jobs[2].callback(true, nil)
			helpers.assert_eq(#fixture.store[API_STATE_KEY].pending_keychain_deletes, 0,
				"tombstone may clear only after delete and settings readback both commit")
		end)
	end)
end)
