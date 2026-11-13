--- macos/tests/unit/updater/engine/test_config_backup_api_entries.lua

--- ==============================================================================
--- MODULE: Configuration Backup Of The Remote API Entries (macOS)
--- DESCRIPTION:
--- Windows backs the remote API entries up with its configuration folder
--- (api_entries.json) and Linux with api_keys.json; this driver keeps them in
--- hs.settings, so its backup copies them through a native port and its restore
--- writes them back (maintainer decision of 2026-11-06: align on the most
--- complete OS). The rest of hs.settings is runtime state and stays out.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the binding over an in-memory Storage adapter.
--- @param store table logical key -> value
--- @param body function fn(Backup, store, failures)
local function with_store(store, body)
	local failures = {}
	helpers.with_fresh_modules({ "updater.engine.config_backup", "core.fs.adapters.storage", "settings.engine.paths" }, function()
		package.loaded["core.fs.adapters.storage"] = {
			read_exact = function(key)
				if failures.read then return false, nil end
				return true, store[key]
			end,
			set = function(key, value)
				if failures.set then return false end
				store[key] = value
				return true
			end,
		}
		package.loaded["settings.engine.paths"] = { get_config_dir = function() return "/Users/me/cfg" end }
		body(helpers.load_with_stubs("updater.engine.config_backup"), store, failures)
	end)
end

--- The root of one id, or nil.
local function root_of(roots, id)
	for _, root in ipairs(roots) do if root.id == id then return root end end
	return nil
end

helpers.describe("macOS configuration backup: API entries (backup-api-entries)", function()
	helpers.it("(backup-api-entries) the default roots carry the API entries beside the configuration folder", function()
		with_store({}, function(Backup)
			local roots = assert(Backup._default_roots())
			helpers.assert_eq(roots[1].id, "config")
			local api = root_of(roots, "api_entries")
			helpers.assert_true(api ~= nil, "the API entries are backed up, as on Windows and Linux")
			helpers.assert_eq(api.name, "api_entries.json")
			helpers.assert_eq(#roots, 2, "no other hs.settings value is copied")
		end)
	end)

	helpers.it("(backup-api-entries) reads canonical JSON and writes the backed-up value back", function()
		local state = { version = 1, entries = { { id = "a", provider = "openai", token = "keychain:a#r1" } }, active_id = "a" }
		with_store({ llm_api_state_v1 = state }, function(Backup, store)
			local port = Backup._api_entries_port()
			local content = assert(port.read())
			helpers.assert_true(content:find('"token":"keychain:a#r1"', 1, true) ~= nil,
				"a Keychain reference, never a key: " .. content)
			helpers.assert_eq(port.read(), content, "the same value reads as the same bytes")
			store.llm_api_state_v1 = { version = 1, entries = {}, active_id = "" }
			helpers.assert_eq(port.replace(content), true)
			helpers.assert_eq(store.llm_api_state_v1.active_id, "a")
			helpers.assert_eq(port.read(), content, "the restored value reads back as the backup")
		end)
	end)

	helpers.it("(backup-api-entries) absence is no file; a failed read or write is a failure", function()
		with_store({}, function(Backup, _, failures)
			local port = Backup._api_entries_port()
			local content, status = port.read()
			helpers.assert_nil(content)
			helpers.assert_eq(status, "absent")
			failures.read = true
			content, status = port.read()
			helpers.assert_nil(content)
			helpers.assert_true(status ~= "absent", "an unreadable store never reads as no entries")
			failures.read, failures.set = false, true
			helpers.assert_nil(port.replace('{"version":1,"entries":[]}'))
			failures.set = false
			helpers.assert_nil(port.replace("not json"), "a damaged copy is refused, never stored")
		end)
	end)

	helpers.it("(backup-api-entries) uses the hs.settings key the LLM module owns", function()
		local source = assert(helpers.read_driver_unit("local API_STATE_KEY"))
		local key = source:match('local API_STATE_KEY%s*=%s*"([^"]+)"')
		helpers.assert_true(key ~= nil, "ai/engine/init.lua declares API_STATE_KEY")
		with_store({}, function(Backup) helpers.assert_eq(Backup.API_STATE_KEY, key) end)
	end)
end)
