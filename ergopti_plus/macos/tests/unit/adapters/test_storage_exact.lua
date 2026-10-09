--- tests/unit/adapters/test_storage_exact.lua

--- ==============================================================================
--- MODULE: Exact Storage Operation Behavioral Tests
--- DESCRIPTION:
--- Verifies that transactional callers can distinguish an absent setting from
--- a native read failure, and can observe whether a native delete completed.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Exact Storage Operations =======
-- ===========================================
-- ===========================================

helpers.describe("Storage exact operations", function()
	helpers.it("read_exact preserves an absent value without reporting failure", function()
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				get = function() return nil end,
			},
		})

		local ok, value = adapter.read_exact("missing")
		helpers.assert_true(ok, "a native read of an absent key must succeed")
		helpers.assert_eq(nil, value, "an absent key must remain distinguishable as nil")
	end)

	helpers.it("read_exact reports a native read failure", function()
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				get = function() error("synthetic settings read failure") end,
			},
		})

		local ok, value = adapter.read_exact("unreadable")
		helpers.assert_eq(false, ok, "a thrown native read must be observable")
		helpers.assert_eq(nil, value, "a failed read must not manufacture a value")
	end)

	helpers.it("delete_exact distinguishes native success from failure", function()
		local store = { ["ergopti.present"] = "value" }
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function(key) store[key] = nil end,
				get = function(key) return store[key] end,
			},
		})

		helpers.assert_true(adapter.delete_exact("present"),
			"a completed native delete must report success")
		helpers.assert_eq(nil, store["ergopti.present"],
			"the exact delete must remove the stored value")
		helpers.assert_true(adapter.delete_exact("already_missing"),
			"deleting an absent key must remain idempotent")

		local noop_store = { ["ergopti.present"] = "value" }
		local noop_adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function() end,
				get = function(key) return noop_store[key] end,
			},
		})
		helpers.assert_eq(false, noop_adapter.delete_exact("present"),
			"a no-op native clear must fail exact readback")
		helpers.assert_eq("value", noop_store["ergopti.present"],
			"the causal fixture must prove that the key remained present")

		local failing_adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function() error("synthetic settings delete failure") end,
			},
		})
		helpers.assert_eq(false, failing_adapter.delete_exact("present"),
			"a thrown native delete must be observable")
	end)

	helpers.it("treats explicit native false as a refused write or delete", function()
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function() return false end,
				clear = function() return false end,
				get = function() return "unchanged" end,
			},
		})
		helpers.assert_eq(adapter.set("owned", "candidate"), false)
		helpers.assert_eq(adapter.delete("owned"), false)
		helpers.assert_eq(adapter.delete_exact("owned"), false)
	end)

	-- hs.settings.clear answers false when the key did not exist. The first
	-- launch of the packaged app deleted an absent reload marker, and logging
	-- that as an ERROR failed the release launch gate.
	helpers.it("treats native false on an absent key as a completed delete", function()
		local errors = {}
		package.loaded["infra.logger"] = nil
		local Logger = helpers.load_with_stubs("infra.logger")
		local original_error = Logger.error
		Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function() return false end,
				get = function() return nil end,
			},
		})
		helpers.assert_eq(adapter.delete("reload_in_progress"), true)
		helpers.assert_eq(adapter.delete_exact("reload_in_progress"), true)
		Logger.error = original_error
		helpers.assert_eq(#errors, 0, "deleting an absent key is no error: " .. table.concat(errors, " | "))
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ Physical Namespace Isolation =======
-- ===============================================
-- ===============================================

helpers.describe("Storage physical namespace isolation", function()
	helpers.it("maps logical keys into ergopti.* and never exposes foreign settings", function()
		local store = {
			["ergopti.owned"] = "old",
			foreign_extension = "must-survive",
		}
		local clears = {}
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value) store[key] = value end,
				get = function(key) return store[key] end,
				clear = function(key)
					clears[#clears + 1] = key
					store[key] = nil
				end,
				getKeys = function()
					return {
						[1] = "ergopti.owned",
						[2] = "foreign_extension",
						["ergopti.owned"] = true,
						foreign_extension = true,
					}
				end,
			},
		})

		helpers.assert_true(adapter.set("owned", "new"))
		helpers.assert_eq(store["ergopti.owned"], "new",
			"the native store must receive only the namespaced physical key")
		helpers.assert_nil(store.owned,
			"the logical key must never leak into Hammerspoon's global domain")
		helpers.assert_eq(adapter.get("owned"), "new")
		local keys = adapter.keys()
		helpers.assert_eq(#keys, 1,
			"the hybrid native key list must be deduplicated and foreign keys filtered")
		helpers.assert_eq(keys[1], "owned")
		helpers.assert_true(adapter.clear(), "owned settings must clear exactly")
		helpers.assert_eq(#clears, 1)
		helpers.assert_eq(clears[1], "ergopti.owned")
		helpers.assert_eq(store.foreign_extension, "must-survive",
			"clear() must not erase another Hammerspoon configuration's setting")
	end)

	helpers.it("rejects physical keys and reports a refused owned clear", function()
		local store = { ["ergopti.owned"] = "value" }
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value) store[key] = value end,
				get = function(key) return store[key] end,
				clear = function() end,
				getKeys = function() return { "ergopti.owned" } end,
			},
		})

		helpers.assert_eq(adapter.set("ergopti.escape", "bad"), false,
			"callers must not bypass the logical namespace boundary")
		helpers.assert_eq(adapter.read_exact("ergopti.escape"), false)
		helpers.assert_eq(adapter.delete_exact("ergopti.escape"), false)
		helpers.assert_eq(adapter.clear(), false,
			"clear must fail closed when exact native readback refuses deletion")
		helpers.assert_eq(store["ergopti.owned"], "value")
	end)

	helpers.it("migrates only allowlisted legacy owners and commits the marker last", function()
		local store = {
			i18n_locale = "fr",
			keyboard_shortcut_cmd_a = "open_app",
			foreign_extension = "must-survive",
			["ergopti.llm_backend"] = "mlx",
			llm_backend = "ollama",
		}
		local writes = {}
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value)
					writes[#writes + 1] = key
					store[key] = value
				end,
				get = function(key) return store[key] end,
				clear = function(key) store[key] = nil end,
				getKeys = function()
					local keys = {}
					for key in pairs(store) do keys[#keys + 1] = key end
					return keys
				end,
			},
		})

		helpers.assert_true(adapter.migrate_legacy_namespace())
		helpers.assert_eq(store["ergopti.i18n_locale"], "fr")
		helpers.assert_eq(store["ergopti.keyboard_shortcut_cmd_a"], "open_app")
		helpers.assert_eq(store["ergopti.llm_backend"], "mlx",
			"an existing namespaced value must win over its legacy twin")
		helpers.assert_nil(store.i18n_locale)
		helpers.assert_nil(store.keyboard_shortcut_cmd_a)
		helpers.assert_nil(store.llm_backend)
		helpers.assert_eq(store.foreign_extension, "must-survive")
		helpers.assert_eq(writes[#writes], "ergopti.settings_namespace_migration_v1",
			"the migration marker must publish only after every legacy owner settles")
	end)

	helpers.it("keeps migration debt retryable until write and clear readback settle", function()
		local function native_keys(store)
			local keys = {}
			for key in pairs(store) do keys[#keys + 1] = key end
			return keys
		end

		local refused_write_store = { i18n_locale = "fr" }
		local refused_write = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value)
					if key ~= "ergopti.i18n_locale" then refused_write_store[key] = value end
				end,
				get = function(key) return refused_write_store[key] end,
				clear = function(key) refused_write_store[key] = nil end,
				getKeys = function() return native_keys(refused_write_store) end,
			},
		})
		helpers.assert_eq(refused_write.migrate_legacy_namespace(), false)
		helpers.assert_eq(refused_write_store.i18n_locale, "fr")
		helpers.assert_nil(refused_write_store["ergopti.i18n_locale"])
		helpers.assert_nil(refused_write_store["ergopti.settings_namespace_migration_v1"],
			"a refused target write must not publish the migration marker")

		local refused_clear_store = { i18n_locale = "fr" }
		local settings = {
			set = function(key, value) refused_clear_store[key] = value end,
			get = function(key) return refused_clear_store[key] end,
			clear = function() end,
			getKeys = function() return native_keys(refused_clear_store) end,
		}
		local refused_clear = helpers.load_with_stubs("adapters.storage", { settings = settings })
		helpers.assert_eq(refused_clear.migrate_legacy_namespace(), false)
		helpers.assert_eq(refused_clear_store.i18n_locale, "fr")
		helpers.assert_eq(refused_clear_store["ergopti.i18n_locale"], "fr")
		helpers.assert_nil(refused_clear_store["ergopti.settings_namespace_migration_v1"],
			"a refused legacy clear must leave the migration retryable")

		settings.clear = function(key) refused_clear_store[key] = nil end
		helpers.assert_true(refused_clear.migrate_legacy_namespace())
		helpers.assert_nil(refused_clear_store.i18n_locale)
		helpers.assert_eq(refused_clear_store["ergopti.i18n_locale"], "fr")
		helpers.assert_eq(refused_clear_store["ergopti.settings_namespace_migration_v1"], true)
	end)
end)

--- Models the documented native settings returns, distinct from hosted execution.
--- @param initial table
--- @return table storage
--- @return table settings_values
--- @return table files
--- @return table backups
--- @return table native_settings
local function settings_cohort_fixture(initial)
	local values, backups = {}, {}
	for key, value in pairs(initial) do values["ergopti." .. key] = value end
	values["another.module"] = "foreign defaults"
	local settings = {
		get = function(key) return values[key] end,
		set = function(key, value) values[key] = value; return true end,
		clear = function(key) local existed = values[key] ~= nil; values[key] = nil; return existed end,
		getKeys = function() local keys = {}; for key in pairs(values) do keys[#keys + 1] = key end; return keys end,
	}
	local files = {
		read_with_status = function(path) if backups[path] == nil then return nil, "absent" end; return backups[path], "ok" end,
		write_if_unchanged = function(path, bytes, expected)
			local source = backups[path]
			if (source == nil and expected.status ~= "absent") or (source ~= nil and (expected.status ~= "ok" or source ~= expected.content)) then return false end
			backups[path] = bytes; return true
		end,
	}
	return helpers.load_with_stubs("adapters.storage", { settings = settings }), values, files, backups, settings
end

helpers.describe("script settings cohorts", function()
	helpers.it("script-storage-cohort exact logical alias gates preserve unrelated defaults", function()
		local storage, values = settings_cohort_fixture({ a = false, foreign = 7 })
		local owner, other = { pending = function() return false end }, {}
		for _, keys in ipairs({ {}, { "a", "a" }, { [2] = "a" }, { "ergopti.a" }, { "a\0b" } }) do helpers.assert_eq(storage.acquire_owned(owner, keys), false) end
		helpers.assert_true(storage.acquire_owned(owner, { "a", "missing" })); helpers.assert_eq(storage.acquire_owned(other, { "a" }), false)
		local receipt = assert(storage.capture_owned(owner)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
		helpers.assert_eq(storage.set("a", true), false); helpers.assert_eq(storage.delete("missing"), false)
		helpers.assert_eq(storage.delete_exact("a"), false); helpers.assert_eq(storage.clear(), false)
		helpers.assert_true(storage.migrate_legacy_namespace(), "disjoint migration remains admitted"); helpers.assert_eq(values["ergopti.a"], false)
		helpers.assert_true(storage.set("foreign", 8)); helpers.assert_eq(values["another.module"], "foreign defaults")
		owner.pending = function() return true end; helpers.assert_eq(storage.release_owned(owner), false)
		owner.pending = function() return nil end; helpers.assert_eq(storage.release_owned(owner), false)
		owner.pending = function() return false end; helpers.assert_true(storage.release_owned(owner))
	end)

	helpers.it("script-storage-cohort detached source cells and forged receipt refusal", function()
		local storage, values, files, backups = settings_cohort_fixture({ a = { list = { 1, 2 } }, b = false })
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b", "missing" }))
		local receipt, cells = storage.capture_owned(owner)
		helpers.assert_eq(cells.b.value, false); helpers.assert_eq(cells.missing.present, false)
		cells.a.value.list[1], cells.b.present = 99, false
		helpers.assert_eq(storage.publish_owned(owner, {}, { b = { present = true, value = true } }, "snapshot", files), false)
		helpers.assert_eq(storage.publish_owned(owner, receipt, { foreign = { present = true, value = 1 } }, "snapshot", files), false)
		helpers.assert_nil(backups.snapshot)
		helpers.assert_true(storage.publish_owned(owner, receipt, { b = { present = true, value = 0 }, missing = { present = true, value = false } }, "snapshot", files))
		helpers.assert_eq(values["ergopti.a"].list[1], 1); helpers.assert_eq(values["ergopti.b"], 0); helpers.assert_eq(values["ergopti.missing"], false)
		helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(values["ergopti.b"], false); helpers.assert_nil(values["ergopti.missing"])
		helpers.assert_true(storage.release_owned(owner))
	end)

	helpers.it("script-storage-cohort verified backup precedes native effects and retained inverse survives reacquisition", function()
		local storage, values, files, backups, settings = settings_cohort_fixture({ a = false, foreign = 1 })
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b" })); local receipt = assert(storage.capture_owned(owner))
		local original_set, observed = settings.set, 0
		settings.set = function(key, value)
			if key == "ergopti.a" or key == "ergopti.b" then
				local backup = assert(require("json").decode_lossless(backups.snapshot))
				helpers.assert_eq(backup.cells.a.value, false); helpers.assert_eq(backup.cells.b.present, false); observed = observed + 1
			end
			return original_set(key, value)
		end
		-- Capture pins the actual native producer callbacks before publication.
		receipt = assert(storage.capture_owned(owner))
		helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true }, b = { present = true, value = "new" } }, "snapshot", files))
		helpers.assert_eq(observed, 2); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
		helpers.assert_true(storage.set("foreign", 99)); helpers.assert_true(storage.release_owned(owner))
		helpers.assert_true(storage.acquire_owned(owner, { "b", "a" })); helpers.assert_true(storage.restore_owned(owner, receipt))
		helpers.assert_eq(values["ergopti.a"], false); helpers.assert_nil(values["ergopti.b"]); helpers.assert_eq(values["ergopti.foreign"], 99)
		helpers.assert_eq(values["another.module"], "foreign defaults"); helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
	end)

	helpers.it("script-storage-cohort explicit false native ACK after effect retains partial inverse and refuses release", function()
		local storage, values, files, _, settings = settings_cohort_fixture({ a = 1, b = 2 })
		local first, native_set = true, settings.set
		settings.set = function(key, value)
			native_set(key, value)
			if key == "ergopti.b" and first then first = false; return false end
			return true
		end
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b" })); local receipt = assert(storage.capture_owned(owner))
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 }, b = { present = true, value = 4 } }, "snapshot", files), false)
		helpers.assert_eq(values["ergopti.a"], 3); helpers.assert_eq(values["ergopti.b"], 4)
		helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
		helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(values["ergopti.a"], 1); helpers.assert_eq(values["ergopti.b"], 2)
		helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner))
	end)

	helpers.it("script-storage-cohort exact source checks every native write and keeps foreign replacements", function()
		local storage, values, files, _, settings = settings_cohort_fixture({ a = 1, b = 2 })
		local set, first = settings.set, true
		settings.set = function(key, value)
			local okay = set(key, value)
			if first then first = false; values["ergopti.b"] = "foreign replacement" end
			return okay
		end
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b" })); local receipt = assert(storage.capture_owned(owner))
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 }, b = { present = true, value = 4 } }, "snapshot", files), false)
		helpers.assert_eq(values["ergopti.a"], 3); helpers.assert_eq(values["ergopti.b"], "foreign replacement")
		helpers.assert_eq(storage.restore_owned(owner, receipt), false); helpers.assert_eq(values["ergopti.b"], "foreign replacement")
		helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
	end)

	helpers.it("script-storage-cohort same-value cooperating successor owns a later native generation", function()
		local storage, values, files = settings_cohort_fixture({ a = 1 })
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
		helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, "snapshot", files))
		helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.set("a", 3)); helpers.assert_true(storage.acquire_owned(owner, { "a" }))
		helpers.assert_eq(storage.restore_owned(owner, receipt), false); helpers.assert_eq(values["ergopti.a"], 3)
		helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
	end)

	helpers.it("script-storage-cohort actual source and native method replacement reject before effects", function()
		local storage, values, files, backups, settings = settings_cohort_fixture({ a = 1 })
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
		values["ergopti.a"] = 2
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, "snapshot", files), false); helpers.assert_nil(backups.snapshot)
		values["ergopti.a"] = 1; local before = settings.set; settings.set = function() return true end
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, "snapshot", files), false); helpers.assert_nil(backups.snapshot)
		settings.set = before; helpers.assert_true(storage.release_owned(owner))
	end)

	helpers.it("script-storage-cohort same-value module replacement and backup callback alias replacement refuse", function()
		local storage, values, files, backups = settings_cohort_fixture({ a = 1 })
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
		package.loaded["adapters.storage"] = { get = function() return 1 end }
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, "snapshot", files), false); helpers.assert_nil(backups.snapshot)
		package.loaded["adapters.storage"] = storage
		local previous, native_write = storage.delete, files.write_if_unchanged
		files.write_if_unchanged = function(path, bytes, expected)
			local okay = native_write(path, bytes, expected); storage.delete = function() return true end; return okay
		end
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, "snapshot", files), false)
		helpers.assert_eq(values["ergopti.a"], 1); storage.delete = previous
		helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
	end)

	helpers.it("script-storage-cohort backup failure and invalid native values refuse without effects", function()
		for _, kind in ipairs({ "refusal", "mismatch", "invalid" }) do
			local storage, values, files, backups = settings_cohort_fixture({ a = 1 })
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			if kind == "invalid" then values["ergopti.a"] = 0 / 0; helpers.assert_eq(storage.capture_owned(owner), nil)
			else
				local receipt = assert(storage.capture_owned(owner))
				files.write_if_unchanged = function() if kind == "mismatch" then backups.snapshot = "wrong"; return true end; return false end
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, "snapshot", files), false)
				helpers.assert_eq(values["ergopti.a"], 1); helpers.assert_true(storage.restore_owned(owner, receipt))
			end
			helpers.assert_true(storage.release_owned(owner))
		end
	end)
end)

helpers.describe("script settings receipt finalization", function()
	helpers.it("script-storage-cohort explicit forget is idempotent without native effects", function()
		local storage, values, files, backups = settings_cohort_fixture({ a = 1 })
		local owner, receipt = {}, nil
		owner.pending = function() local retained = receipt; return retained == nil end
		helpers.assert_true(storage.acquire_owned(owner, { "a" })); receipt = assert(storage.capture_owned(owner))
		helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, "snapshot", files))
		helpers.assert_eq(storage.forget_owned(owner, receipt), false, "held alias gates forbid journal finalization"); helpers.assert_true(storage.release_owned(owner)); local snapshot = backups.snapshot
		local pending = owner.pending; owner.pending = function() return true end; helpers.assert_eq(storage.forget_owned(owner, receipt), false)
		owner.pending = pending; helpers.assert_true(storage.forget_owned(owner, receipt)); helpers.assert_true(storage.forget_owned(owner, receipt))
		helpers.assert_eq(storage.forget_owned({}, receipt), false); helpers.assert_eq(backups.snapshot, snapshot); helpers.assert_eq(values["ergopti.a"], 2)
		helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_eq(storage.restore_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner))
		local weak = setmetatable({ owner, receipt }, { __mode = "v" }); owner, receipt, pending = nil, nil, nil
		collectgarbage("collect"); collectgarbage("collect"); helpers.assert_nil(weak[1]); helpers.assert_nil(weak[2])
	end)
end)

helpers.describe("script settings opaque owner identity", function()
	helpers.it("script-storage-cohort table equality cannot forge native settings receipt owner", function()
		local storage, values, files = settings_cohort_fixture({ a = 1, foreign = 2 })
		local mt = { __eq = function() return true end }; local owner, foreign = setmetatable({}, mt), setmetatable({}, mt)
		helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_true(storage.acquire_owned(foreign, { "foreign" })); local receipt = assert(storage.capture_owned(owner))
		helpers.assert_eq(storage.publish_owned(owner, receipt, { foreign = { present = true, value = 99 } }, "snapshot", files), false)
		helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, "snapshot", files)); helpers.assert_true(storage.release_owned(owner))
		helpers.assert_eq(storage.forget_owned(foreign, receipt), false); helpers.assert_true(storage.release_owned(foreign)); helpers.assert_true(storage.acquire_owned(foreign, { "a" }))
		helpers.assert_eq(storage.restore_owned(foreign, receipt), false); helpers.assert_eq(values["ergopti.a"], 3); helpers.assert_true(storage.release_owned(foreign))
		helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		helpers.assert_eq(storage.forget_owned(foreign, receipt), false)
	end)
end)

helpers.describe("script settings numeric backup admission", function()
	helpers.it("script-storage-cohort exact native integers cannot be rounded by the backup writer", function()
		-- Lua5.4 retains this native integer; LuaJIT has already rounded the
		-- literal before the caller supplies it, so this exact-integer control
		-- is a Lua5.4 settings model, not a macOS native receipt.
		local integer = 9007199254740993
		local storage, values, files, backups = settings_cohort_fixture({ a = false })
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
		if math.type and math.type(integer) == "integer" then
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = integer } }, "cohort-integer-backup", files), false)
			helpers.assert_eq(values["ergopti.a"], false); helpers.assert_nil(backups["cohort-integer-backup"])
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
		end
		local json = require("json")
		local zero_readback = json.decode_lossless(assert(json.encode(-0.0)))
		-- Unlike LuaJIT, Lua5.4 rereads the encoded -0 as positive integer zero.
		if 1 / zero_readback ~= 1 / -0.0 then
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = -0.0 } }, "cohort-zero-backup", files), false)
			helpers.assert_eq(values["ergopti.a"], false); helpers.assert_nil(backups["cohort-zero-backup"])
		end
		helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 0.125 } }, "cohort-exact-backup", files))
		helpers.assert_eq(values["ergopti.a"], 0.125); helpers.assert_true(storage.restore_owned(owner, receipt))
		helpers.assert_eq(values["ergopti.a"], false); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
	end)
end)

helpers.describe("script settings producer load order", function()
	helpers.it("script-storage-cohort loads actual i18n before acquiring the shared writer", function()
		helpers.with_fresh_modules({ "adapters.storage", "infra.i18n", "toml_codec.writer" }, function()
			local storage = settings_cohort_fixture({})
			local i18n = require("infra.i18n")
			helpers.assert_eq(package.loaded["infra.i18n"], i18n)
			helpers.assert_nil(package.loaded["toml_codec.writer"], "Storage boot must not capture fallback i18n through an eager Writer cycle")
			local writer = require("toml_codec.writer")
			helpers.assert_true(type(writer) == "table"); helpers.assert_eq(package.loaded["infra.i18n"], i18n)
			helpers.assert_eq(package.loaded["adapters.storage"], storage)
		end)
	end)
end)

helpers.describe("script settings raw producer identity", function()
	helpers.it("script-storage-cohort forged module equality cannot authorize native settings publication", function()
		for _, stage in ipairs({ "capture", "publish" }) do
			local storage, values, files, backups = settings_cohort_fixture({ a = false })
			local comparisons = 0
			local mt = { __index = function(_, key) return rawget(storage, key) end, __eq = function() comparisons = comparisons + 1; return true end }
			setmetatable(storage, mt); local successor = setmetatable({}, mt)
			helpers.assert_true(not rawequal(successor, storage)); local owner = {}
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			if stage == "capture" then package.loaded["adapters.storage"] = successor; helpers.assert_nil(storage.capture_owned(owner))
			else
				local receipt = assert(storage.capture_owned(owner)); package.loaded["adapters.storage"] = successor
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, "raw-module-backup", files), false)
				helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			end
			helpers.assert_eq(values["ergopti.a"], false); helpers.assert_nil(backups["raw-module-backup"])
			helpers.assert_eq(comparisons, 0); package.loaded["adapters.storage"] = storage; setmetatable(storage, nil)
			helpers.assert_true(storage.release_owned(owner))
		end
	end)

	helpers.it("script-storage-cohort forged settings equality cannot replace the captured native provider", function()
		for _, stage in ipairs({ "capture-read", "publish", "backup" }) do
			local storage, values, files, backups, native = settings_cohort_fixture({ a = false })
			local comparisons = 0
			local mt = { __index = native, __eq = function() comparisons = comparisons + 1; return true end }
			setmetatable(native, mt); local successor = setmetatable({}, mt)
			helpers.assert_true(not rawequal(successor, native)); local owner = {}
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			if stage == "capture-read" then
				local original = native.get
				native.get = function(key) local result = original(key); hs.settings = successor; return result end
				helpers.assert_nil(storage.capture_owned(owner)); native.get = original
			else
				local receipt = assert(storage.capture_owned(owner)); local producer = files
				if stage == "publish" then hs.settings = successor
				else producer = { read_with_status = files.read_with_status, write_if_unchanged = function(path, bytes, expected)
					local result = files.write_if_unchanged(path, bytes, expected); hs.settings = successor; return result
				end } end
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, "raw-native-backup", producer), false)
				if stage == "backup" then
					helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
					hs.settings = native; helpers.assert_true(storage.restore_owned(owner, receipt))
					helpers.assert_eq(storage.pending_owned(owner, receipt), false)
				else helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_nil(backups["raw-native-backup"]) end
			end
			helpers.assert_eq(values["ergopti.a"], false); helpers.assert_eq(comparisons, 0)
			hs.settings = native; setmetatable(native, nil); helpers.assert_true(storage.release_owned(owner))
		end
	end)
end)

helpers.describe("script settings actual void setter contract", function()
	helpers.it("script-storage-cohort SDK void setter publishes and restores only verified owned cells", function()
		local storage, values, files, backups, native = settings_cohort_fixture({ a = false, b = { 1, 2 }, foreign = 7 })
		local set, writes = native.set, 0
		native.set = function(key, value) writes = writes + 1; set(key, value) end
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b", "missing" }))
		local receipt = assert(storage.capture_owned(owner))
		helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 0 }, b = { present = true, value = { 3, 4 } }, missing = { present = true, value = false } }, "void-native-backup", files))
		helpers.assert_eq(writes, 3); helpers.assert_eq(values["ergopti.a"], 0); helpers.assert_eq(values["ergopti.b"], { 3, 4 }); helpers.assert_eq(values["ergopti.missing"], false)
		local saved = require("json").decode_lossless(backups["void-native-backup"])
		helpers.assert_eq(saved.cells.a.value, false); helpers.assert_eq(saved.cells.b.value, { 1, 2 }); helpers.assert_eq(saved.cells.missing.present, false)
		helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.set("foreign", 9))
		helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.acquire_owned(owner, { "missing", "b", "a" }))
		helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(values["ergopti.a"], false); helpers.assert_eq(values["ergopti.b"], { 1, 2 })
		helpers.assert_nil(values["ergopti.missing"]); helpers.assert_eq(values["ergopti.foreign"], 9)
		helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
	end)

	helpers.it("script-storage-cohort no-effect void and false truthy or thrown setter returns never acknowledge", function()
		for _, kind in ipairs({ "noop-void", "false-effect", "truthy-effect", "throw-effect" }) do
			local storage, values, files, _, native = settings_cohort_fixture({ a = 1 })
			local set, first = native.set, true
			native.set = function(key, value)
				if kind == "noop-void" then return nil end
				set(key, value)
				if first then
					first = false
					if kind == "false-effect" then return false end
					if kind == "truthy-effect" then return "acknowledged" end
					error("native setter interrupted after effect")
				end
				return nil
			end
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, "refused-void-backup", files), false)
			if kind == "noop-void" then helpers.assert_eq(values["ergopti.a"], 1); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			else helpers.assert_eq(values["ergopti.a"], 2); helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false) end
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(values["ergopti.a"], 1)
			helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end
	end)

	helpers.it("script-storage-cohort void setter still refuses a changed second owned alias", function()
		local storage, values, files, _, native = settings_cohort_fixture({ a = 1, b = 2 })
		local set = native.set
		native.set = function(key, value) set(key, value); values["ergopti.b"] = "foreign replacement" end
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b" })); local receipt = assert(storage.capture_owned(owner))
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 }, b = { present = true, value = 4 } }, "void-foreign-backup", files), false)
		helpers.assert_eq(values["ergopti.a"], 3); helpers.assert_eq(values["ergopti.b"], "foreign replacement")
		helpers.assert_eq(storage.restore_owned(owner, receipt), false); helpers.assert_eq(values["ergopti.b"], "foreign replacement")
		helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
	end)

	helpers.it("script-storage-cohort native clear still requires its documented Boolean receipt", function()
		local storage, values, files, _, native = settings_cohort_fixture({ a = 1 })
		local clear, set = native.clear, native.set
		native.clear = function(key) clear(key); return nil end
		native.set = function(key, value) set(key, value) end
		local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
		helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = false } }, "void-clear-backup", files), false)
		helpers.assert_nil(values["ergopti.a"]); helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
		helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(values["ergopti.a"], 1)
		helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
	end)
end)


helpers.describe("script settings retired journal roots", function()
	helpers.it("script-storage-cohort successful forget releases a retained authentic settings journal owner", function()
		local storage, values, files, backups = settings_cohort_fixture({ a = 1 })
		local owner = { pending = function() return false end }
		helpers.assert_true(storage.acquire_owned(owner, { "a" }))
		local receipt = assert(storage.capture_owned(owner))
		helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, "snapshot", files))
		-- A native callback retained by LuaJIT may keep the old journal alive
		-- after its receipt-map entry becomes a weak owner tombstone.
		local records, slot = nil, 1
		while true do
			local name, value = debug.getupvalue(storage.forget_owned, slot)
			if name == nil then break end
			if name == "_owned_receipts" then records = value; break end
			slot = slot + 1
		end
		helpers.assert_type(records, "table", "the actual settings receipt map must be reachable")
		local retained_journal = records[receipt]
		helpers.assert_true(rawequal(retained_journal.owner, owner))
		local snapshot = backups.snapshot
		helpers.assert_eq(storage.forget_owned(owner, receipt), false)
		helpers.assert_true(rawequal(retained_journal.owner, owner), "held refusal preserves inverse ownership")
		helpers.assert_true(storage.release_owned(owner))
		for _, pending in ipairs({ function() return true end, function() error("native pending refusal") end }) do
			owner.pending = pending
			helpers.assert_eq(storage.forget_owned(owner, receipt), false)
			helpers.assert_true(rawequal(records[receipt], retained_journal))
			helpers.assert_true(rawequal(retained_journal.owner, owner), "refused finalization must not detach the owner")
		end
		owner.pending = function() return false end
		local native_setmetatable = setmetatable
		setmetatable = function() error("native tombstone allocation refused") end
		local completed = pcall(storage.forget_owned, owner, receipt)
		setmetatable = native_setmetatable
		helpers.assert_eq(completed, false, "tombstone construction must finish before retiring inverse ownership")
		helpers.assert_true(rawequal(records[receipt], retained_journal))
		helpers.assert_true(rawequal(retained_journal.owner, owner))
		helpers.assert_eq(storage.forget_owned({}, receipt), false)
		helpers.assert_true(rawequal(retained_journal.owner, owner))
		helpers.assert_true(storage.forget_owned(owner, receipt))
		helpers.assert_nil(retained_journal.owner, "successful finalization detaches even a rooted retired settings journal")
		helpers.assert_true(storage.forget_owned(owner, receipt), "the weak tombstone keeps exact idempotence")
		helpers.assert_eq(storage.forget_owned({}, receipt), false)
		helpers.assert_eq(backups.snapshot, snapshot); helpers.assert_eq(values["ergopti.a"], 2)
		helpers.assert_true(storage.acquire_owned(owner, { "a" }))
		helpers.assert_eq(storage.restore_owned(owner, receipt), false, "a retained old closure cannot revive its forgotten receipt")
		local fresh = assert(storage.capture_owned(owner))
		helpers.assert_true(fresh ~= receipt)
		helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, fresh))
		helpers.assert_eq(backups.snapshot, snapshot); helpers.assert_eq(values["ergopti.a"], 2)
	end)
end)
