--- tests/hardware/run_text_migration_consumer.lua
--- ==============================================================================
--- MODULE: Native Typed-Text Migration Settings Contract
--- DESCRIPTION:
--- Exercises the real collector, SQLite backend and AES provider. The setting
--- acknowledges future-write posture; migration acceptance is a separate receipt.
--- An owned machine identity keeps the proof independent of the host's ID.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Fixture = require("tests.support.keystats_native_fixture")
local Preferences = require("tests.support.metrics_preferences_fixture")
local TextCrypto = require("keystats.text_crypto")
local uv = require("luv")
local cipher = require("modules.keystats.text_cipher")
local directory = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-migration-consumer-XXXXXX"))
local path, machine_id = directory .. "/metrics.sqlite", directory .. "/machine-id"
local machine = assert(io.open(machine_id, "wb"))
assert(machine:write("0123456789abcdef0123456789abcdef\n"))
assert(machine:close())
cipher._set_machine_id_path(machine_id)
local Logger = require("logger.shim")
local original_error, failures = Logger.error, 0
local original_success, completions = Logger.success, 0
Logger.success = function(tag, ...)
	if tag == "modules.keystats.text_migration" then completions = completions + 1 end
	return original_success(tag, ...)
end
Logger.error = function(tag, ...)
	if tag == "modules.keystats.text_migration" then failures = failures + 1 end
	return original_error(tag, ...)
end
local ok, failure = xpcall(function()
	Preferences.with(function(preferences)
		Fixture.with(function(k)
			k.init({ sqlite_path = path })
			require("tests.support.metrics_consent_fixture").enable(k)
			local writer = require("modules.keystats.sqlite_writer")
			assert(require("infra.openssl_cipher").available, "This public-consumer proof requires native AES")
			assert(cipher.is_available(), "The owned machine identity must derive a real encryption key")
			local device = assert(writer.query_rows("SELECT device_id FROM devices LIMIT 1;"))[1]
			assert(writer.insert_typing_events(device, { { app = "owned-app", text = "historical-original" } }))
			local key = require("keystats.text_migration_runner").CURSOR_META_KEY
			assert(writer.exec_sql("CREATE TRIGGER owned_cursor_refusal BEFORE INSERT ON meta WHEN NEW.key='" .. key .. "' BEGIN SELECT RAISE(FAIL,'owned refusal'); END;"))
			local posture = k.set_encrypt_enabled(true)
			print("posture_return=" .. tostring(posture))
			print("posture_in_force=" .. tostring(k.is_encrypt_enabled()))
			print("migration_running=" .. tostring(k.get_migration_progress().running))
			print("durable_intent=" .. tostring(writer.get_meta(key)))
			print("migration_errors=" .. failures)
			assert(posture and k.is_encrypt_enabled())
			assert(preferences.snapshot()[require("config_keys").KEY.METRICS_ENCRYPT] == true)
			assert(completions == 0, "refusing historical work must never announce its success")
			assert(not k.get_migration_progress().running and writer.get_meta(key) == nil and failures == 1)
			k.on_keydown("b", 1000, "owned-app")
			Fixture.flush(k)
			local rows = assert(writer.query_rows("SELECT text FROM events_typing ORDER BY id;"))
			assert(#rows == 2)
			print("historical_row_encrypted=" .. tostring(TextCrypto.is_encrypted(rows[1])))
			print("future_row_encrypted=" .. tostring(TextCrypto.is_encrypted(rows[2])))
			assert(not TextCrypto.is_encrypted(rows[1]) and TextCrypto.is_encrypted(rows[2]))
			assert(writer.exec_sql("DROP TRIGGER owned_cursor_refusal;"))
			assert(k.migrate_stored_text())
			for _ = 1, #rows + 1 do if not k.get_migration_progress().running then break end; k.pump_migration() end
			assert(not k.get_migration_progress().running)
			rows = assert(writer.query_rows("SELECT text FROM events_typing ORDER BY id;"))
			assert(TextCrypto.is_encrypted(rows[1]) and cipher.decrypt(rows[1]) == "historical-original")
			assert(completions == 1)
			print("manual_migration_retry_completed=true")
			-- OFF is a successful posture value, not a failed operation. Its healthy
			-- migration must also survive stopping before the first periodic slice.
			assert(k.set_encrypt_enabled(false) == false and not k.is_encrypt_enabled())
			assert(writer.get_meta(key) == "decrypt:0")
			local migration = require("modules.keystats.text_migration")
			migration._set_backend(nil)
			assert(migration.resume("decrypt", device))
			for _ = 1, #rows + 1 do if not migration.is_running() then break end; k.pump_migration() end
			assert(not migration.is_running())
			rows = assert(writer.query_rows("SELECT text FROM events_typing ORDER BY id;"))
			assert(rows[1] == "historical-original" and rows[2] == "b")
			print("published_off_posture_resumes_byte_exact=true")
		end)
	end)
end, debug.traceback)
Logger.error = original_error
Logger.success = original_success
local cleaned, cleanup_error = pcall(function()
	cipher._set_machine_id_path(nil)
	for name in uv.fs_scandir_next, assert(uv.fs_scandir(directory)) do
		assert(uv.fs_unlink(directory .. "/" .. name))
	end
	assert(uv.fs_rmdir(directory))
end)
assert(ok, failure)
assert(cleaned, cleanup_error)
