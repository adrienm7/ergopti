--- tests/unit/modules/keylogger/privacy/test_cipher_posture.lua
--- Saved encryption consent must never become a plaintext persistence fallback.
local helpers = require("tests.helpers")
require("infra.monotonic") -- Capture the genuine clock before temporary ports.

local function with_unavailable_cipher(saved, body)
	local names = { "infra.metrics_preferences", "modules.keylogger.sqlite_writer",
		"modules.keylogger.text_cipher", "modules.keylogger.text_migration", "modules.keylogger.keylogger" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local preferences = require("tests.support.metrics_preferences_fixture").new({
		initial = { ["metrics.encrypt"] = saved, ["metrics.enabled"] = true },
	})
	local writer = require("tests.fakes").sqlite_writer()
	local cipher = helpers.load_module("modules.keylogger.text_cipher")
	cipher._set_machine_id_path("/nonexistent/ergopti-cipher-posture-machine-id")
	cipher.is_available = function() return false end
	local persisted, direction = 0, nil
	writer.insert_typing_events = function(device, rows)
		for index, row in ipairs(rows) do
			if cipher.encrypt(device, index, row.text) == nil then return false end
			persisted = persisted + 1
		end
		return true
	end
	package.loaded[names[1]], package.loaded[names[2]] = preferences, writer
	package.loaded[names[4]] = { resume = function(mode) direction = mode; return false end }
	package.loaded[names[5]] = nil
	local ok, err = xpcall(function()
		local collector = require(names[5])
		assert(collector.init({ sqlite_path = "/tmp/cipher-posture-logical.sqlite" }) ~= false)
		body(collector, cipher, preferences, function() return persisted, direction end)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("saved encryption capability refusal", function()
	helpers.it("keeps saved ON and refuses persistence instead of silently storing plaintext", function()
		with_unavailable_cipher(true, function(k, cipher, preferences, observed)
			k.on_keydown("a", 1000, "synthetic-app")
			local saved = k.flush()
			local rows, direction = observed()
			helpers.assert_eq(rows, 0, "unavailable encryption must never admit plaintext rows")
			helpers.assert_eq(saved, false, "a refused cipher must never acknowledge saved text")
			helpers.assert_true(k.is_encrypt_enabled())
			helpers.assert_true(k.get_privacy_state().encrypt)
			helpers.assert_true(cipher.is_enabled())
			helpers.assert_true(preferences.snapshot()["metrics.encrypt"])
			helpers.assert_eq(direction, require("keylogger.text_migration").MODE_ENCRYPT,
				"capability refusal must not resume a decryption migration")
			helpers.assert_eq(k._pending_buffer_count_for_test(), 1)
		end)
	end)
	helpers.it("refuses unavailable activation without changing saved OFF or current posture", function()
		with_unavailable_cipher(false, function(k, cipher, preferences)
			helpers.assert_eq(k.set_encrypt_enabled(true), false)
			helpers.assert_eq(cipher.is_enabled(), false)
			helpers.assert_eq(k.is_encrypt_enabled(), false)
			helpers.assert_eq(preferences.snapshot()["metrics.encrypt"], false)
		end)
	end)
end)
