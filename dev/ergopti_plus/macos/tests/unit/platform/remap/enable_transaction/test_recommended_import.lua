--- tests/unit/platform/remap/enable_transaction/test_recommended_import.lua

--- ==============================================================================
--- MODULE: The Wizard's Tap-Holds Import In The Remap Owner
--- DESCRIPTION:
--- The first-run wizard's checked tap-hold keys reach the remap owner, the only
--- writer of config_karabiner.toml. A running bridge takes them in its exact
--- settings transaction and reports success only on the Karabiner terminal;
--- a folder it does not run gets the same candidate saved through Config. Each
--- checked key becomes exactly its shipped recommendation, the Tap-Holds switch
--- turns on, and every other key keeps its binding.
---
--- A re-run imported over the keys the user had set: the owner now reports each
--- key as the recommendation or as the user's own setting, refuses to import
--- over the latter, and backs the file up before either write.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

-- The shipped [hs_tap_hold] slots the owner reads, as defaults.lua exposes them.
local PRESET = {
	left_shift = { "copy", "shift" },
	caps_lock = { "return", "cmd" },
	escape = { "none", "none" },
}
local KEYS = { { id = "left_shift" }, { id = "caps_lock" }, { id = "escape" } }
local RUNNING = "/remap/config_karabiner.toml"
local WIZARD = "/wizard/config_karabiner.toml"
local SOURCE = '[tap_holds]\nenabled = false\n[future]\nkeep = true\n'

--- Loads an enabled remap that knows three keys and the preset above, with an
--- observable regeneration and an in-memory disk holding both settings files.
--- @param fixture table remap_transaction_fixture constructors.
--- @return table remap, table calls, table deploy, table disk
local function importing_remap(fixture)
	local remap, calls = fixture.load_enabled_remap()
	package.loaded["platform.remap.defaults"].tap_hold = PRESET
	local Config = package.loaded["platform.remap.config"]
	Config.load_tap_hold_keys = function() return KEYS end
	for index = #remap.TAP_HOLD_KEYS + 1, #KEYS do remap.TAP_HOLD_KEYS[index] = KEYS[index] end
	local disk = { files = { [RUNNING] = SOURCE, [WIZARD] = SOURCE }, expected = {} }
	local save = Config.save_user_config
	Config.save_user_config = function(state, path, overwrite, expected)
		disk.expected[#disk.expected + 1] = expected or false
		return save(state, path, overwrite, expected)
	end
	package.loaded["infra.config_paths"].get = function(key)
		assert(key == "KarabinerConfigPath", "unexpected path key " .. tostring(key))
		return RUNNING
	end
	local files = require("adapters.file_system")
	files.read_with_status = function(path)
		local content = disk.files[path]
		return content, content and "ok" or "absent"
	end
	files.write_if_unchanged = function(path, content, expected)
		local current = disk.files[path]
		if (expected.status == "absent" and current ~= nil)
			or (expected.status == "ok" and current ~= expected.content) then return false, "changed" end
		disk.files[path] = content
		return true
	end
	local deploy = { regenerations = 0 }
	remap.regenerate = function(on_done)
		deploy.regenerations = deploy.regenerations + 1
		deploy.terminal = on_done
		return true
	end
	return remap, calls, deploy, disk
end

--- Makes Config read a wizard folder's settings with the given keys.
--- @param tap_hold_config table Key id -> { tap, hold, timeout_ms }.
--- @return table paths The paths read, in order.
local function wizard_settings(tap_hold_config)
	local paths = {}
	package.loaded["platform.remap.config"].load_user_config = function(_, _, path)
		paths[#paths + 1] = path
		return { enabled = true, tap_holds_enabled = true, mod_combos_enabled = nil,
			tap_hold_config = tap_hold_config, mod_combos_config = {},
			tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000, simultaneous_threshold_ms = 50,
			combo_symmetric = false }, "ok"
	end
	return paths
end

helpers.describe("the remap owner imports the wizard's checked keys", function()
	helpers.it("takes them in the running bridge's transaction over a backup, success on the terminal", function()
		with_fixture(function(fixture)
			local remap, calls, deploy, disk = importing_remap(fixture)
			helpers.assert_true(remap.set_tap_holds_enabled(false))
			helpers.assert_true(remap.set_tap_action("left_shift", "paste"))
			calls.saved_payloads, disk.expected = {}, {}
			local settled = {}
			helpers.assert_true(remap.import_recommended_keys({ keys = { "caps_lock" }, backup_path = "/remap/b-1" },
				function(ok, reason) settled[#settled + 1] = { ok = ok, reason = reason } end))
			helpers.assert_eq(disk.files["/remap/b-1"], SOURCE, "the exact bytes are backed up first")
			helpers.assert_eq(disk.expected, { { status = "ok", content = SOURCE } },
				"the save replaces only the bytes the backup holds")
			helpers.assert_eq(#settled, 0, "no success before the Karabiner terminal")
			helpers.assert_eq(deploy.regenerations, 1)
			local saved = calls.saved_payloads[1]
			helpers.assert_eq(saved.tap_holds_enabled, true, "an imported key is live")
			helpers.assert_eq(saved.tap_hold_config.caps_lock, { tap = "return", hold = "cmd" },
				"the checked key is exactly its recommendation")
			helpers.assert_eq(saved.tap_hold_config.left_shift.tap, "paste", "an unchecked key keeps its binding")
			deploy.terminal(true, "ready")
			helpers.assert_eq(settled, { { ok = true, reason = "ready" } })
			helpers.assert_eq(remap.get_tap_action("caps_lock"), "return")
			helpers.assert_eq(remap.get_tap_holds_enabled(), true)
		end)
	end)

	helpers.it("refuses a key it cannot import exactly, or one of the user's, before any write", function()
		with_fixture(function(fixture)
			local remap, calls, deploy, disk = importing_remap(fixture)
			helpers.assert_true(remap.set_tap_action("left_shift", "paste"))
			local saves = calls.save
			for label, request in pairs({
				["no recommendation"] = { keys = { "escape" }, backup_path = "/remap/b-2" },
				["unknown key"] = { keys = { "hyper" }, backup_path = "/remap/b-2" },
				["twice"] = { keys = { "caps_lock", "caps_lock" }, backup_path = "/remap/b-2" },
				["none"] = { keys = {}, backup_path = "/remap/b-2" },
				["the user's own setting"] = { keys = { "caps_lock", "left_shift" }, backup_path = "/remap/b-2" },
				["no backup"] = { keys = { "caps_lock" } },
			}) do
				local settled = {}
				helpers.assert_eq(remap.import_recommended_keys(request, function(ok, reason)
					settled[#settled + 1] = { ok = ok, reason = reason }
				end), false, label)
				helpers.assert_eq(settled, { { ok = false, reason = "invalid-keys" } }, label)
			end
			helpers.assert_eq(calls.save, saves, "nothing is persisted")
			helpers.assert_nil(disk.files["/remap/b-2"], "nothing is backed up")
			helpers.assert_eq(deploy.regenerations, 0, "nothing is deployed")
			helpers.assert_eq(remap.get_tap_action("left_shift"), "paste")
		end)
	end)

	helpers.it("reports each key as the recommendation or the user's own setting", function()
		with_fixture(function(fixture)
			local remap = importing_remap(fixture)
			local paths = wizard_settings({
				left_shift = { tap = "copy", hold = "shift" },
				caps_lock = { tap = "return", hold = "cmd", timeout_ms = 300 },
				escape = { tap = "none", hold = "none" },
			})
			helpers.assert_eq(remap.recommended_key_report(WIZARD), {
				enabled = true,
				keys = { left_shift = "recommended", caps_lock = "customised" },
			}, "an unbound key is absent: the wizard may import it")
			helpers.assert_eq(paths, { WIZARD }, "the folder's own file is read")
			package.loaded["platform.remap.config"].load_user_config = function() return nil, "error" end
			local report, err = remap.recommended_key_report(WIZARD)
			helpers.assert_nil(report, "an unsafe file is never reported as neutral")
			helpers.assert_type(err, "string")
		end)
	end)

	helpers.it("saves the same candidate to a folder the bridge does not run, over a backup", function()
		with_fixture(function(fixture)
			local remap, calls, deploy, disk = importing_remap(fixture)
			local paths = wizard_settings({ left_shift = { tap = "paste", hold = "none" } })
			calls.saved_payloads, disk.expected = {}, {}
			local saved_ok, detail = remap.save_recommended_keys({ keys = { "caps_lock" }, path = WIZARD,
				backup_path = "/wizard/b-1" })
			helpers.assert_true(saved_ok, tostring(detail))
			helpers.assert_eq(paths, { WIZARD }, "the folder's own file is read")
			helpers.assert_eq(disk.files["/wizard/b-1"], SOURCE, "the exact bytes are backed up first")
			helpers.assert_eq(disk.expected, { { status = "ok", content = SOURCE } },
				"the save replaces only the bytes the backup holds")
			local saved = calls.saved_payloads[1]
			helpers.assert_eq(saved.tap_holds_enabled, true)
			helpers.assert_eq(saved.tap_hold_config.caps_lock, { tap = "return", hold = "cmd" })
			helpers.assert_eq(saved.tap_hold_config.left_shift.tap, "paste", "an unchecked key keeps its binding")
			helpers.assert_nil(saved.enabled, "the save carries no « Ergopti uses Karabiner » decision")
			helpers.assert_eq(deploy.regenerations, 0, "nothing is live there to deploy")
			helpers.assert_eq(remap.get_tap_action("caps_lock"), "none", "the running bridge is left alone")

			for label, request in pairs({
				["the user's own setting"] = { keys = { "left_shift" }, path = WIZARD, backup_path = "/wizard/b-2" },
				["no recommendation"] = { keys = { "escape" }, path = WIZARD, backup_path = "/wizard/b-2" },
				["no backup"] = { keys = { "caps_lock" }, path = WIZARD },
				["a backup that exists"] = { keys = { "caps_lock" }, path = WIZARD, backup_path = "/wizard/b-1" },
			}) do
				helpers.assert_eq(remap.save_recommended_keys(request), false, label)
			end
			package.loaded["platform.remap.config"].load_user_config = function() return nil, "error" end
			helpers.assert_eq(remap.save_recommended_keys({ keys = { "caps_lock" }, path = WIZARD,
				backup_path = "/wizard/b-2" }), false, "an unsafe file is refused, never replaced")
			helpers.assert_eq(#calls.saved_payloads, 1, "no refused save is written")
			helpers.assert_nil(disk.files["/wizard/b-2"], "nor backed up")
		end)
	end)

	-- A bridge whose settings save is still owed makes it to the settings path
	-- in force then: once a wizard moved the configuration, the new folder's
	-- file, over the keys the wizard had just saved there.
	helpers.it("refuses a direct save while the running bridge owes a settings save", function()
		with_fixture(function(fixture)
			local remap, calls, deploy, disk = importing_remap(fixture)
			wizard_settings({})
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_true(remap.import_recommended_keys({ keys = { "left_shift" }, backup_path = "/remap/b-3" }))
			helpers.assert_eq(remap.has_pending_settings_save(), true, "the transaction owes its terminal")
			calls.saved_payloads = {}
			local saved, detail = remap.save_recommended_keys({ keys = { "caps_lock" }, path = WIZARD,
				backup_path = "/wizard/b-3" })
			helpers.assert_eq(saved, false, "the owed save would undo this one")
			helpers.assert_type(detail, "string", "the wizard reports why")
			helpers.assert_eq(#calls.saved_payloads, 0, "nothing is written")
			helpers.assert_nil(disk.files["/wizard/b-3"], "nor backed up")
			deploy.terminal(true, "ready")
			helpers.assert_eq(remap.has_pending_settings_save(), false, "the terminal settles the debt")
			helpers.assert_true(remap.save_recommended_keys({ keys = { "caps_lock" }, path = WIZARD,
				backup_path = "/wizard/b-3" }), "a settled bridge owes nothing")
		end)
	end)
end)

return true
