--- tests/unit/platform/remap/enable_transaction/test_scope_owner_transaction.lua

--- ==============================================================================
--- MODULE: Remap Scope Transaction
--- DESCRIPTION:
--- The remap part of a manifest scope runs as one exact bulk transaction: the
--- tap_holds scope owns the keys, their master and timings, the shortcuts scope
--- owns the chords. Each request backs up the exact file bytes first, saves only
--- over those bytes, and claims success only on the Karabiner terminal.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.enable_transaction.scope_owner_fixture"] = nil
local Fixture = require("tests.support.platform.remap.enable_transaction.scope_owner_fixture")
local COMBO = Fixture.COMBO
local KEY = Fixture.KEY
local LAYERS = Fixture.LAYERS
local SOURCE = Fixture.SOURCE
local assert_layer_removal = Fixture.assert_layer_removal
local preset = Fixture.preset
local removable = Fixture.removable
local request = Fixture.request
local scoped_remap = Fixture.scoped_remap
local with_fixture = Fixture.with_fixture
local with_wheel_owner = Fixture.with_wheel_owner





helpers.describe("remap scope transaction", function()
	helpers.it("restores the recommended keys over a verified backup, leaving the chords", function()
		with_fixture(function(fixture)
			local remap, calls, disk = scoped_remap(fixture)
			local accepted, settled = request(remap, "tap_holds", "recommended", "/remap/backup-1")
			helpers.assert_true(accepted)
			helpers.assert_eq(disk.files["/remap/backup-1"], SOURCE, "the exact bytes are backed up first")
			helpers.assert_eq(disk.expected, { { status = "ok", content = SOURCE } },
				"the save may only replace the backed-up bytes")
			local saved = calls.saved_payloads[1]
			helpers.assert_eq(saved.tap_holds_enabled, require("infra.manifest_reader").recommended_for("tap_holds.enabled"))
			helpers.assert_eq(saved.tap_hold_config[KEY], { tap = "copy", hold = "shift" })
			helpers.assert_eq(saved.mod_combos_config[COMBO].tap, "escape", "the chords belong to the shortcuts scope")
			helpers.assert_eq(#settled, 0, "no success before the Karabiner terminal")
			disk.terminal(true, "ready")
			helpers.assert_eq(settled, { { ok = true, reason = "ready" } })
			helpers.assert_eq(remap.get_tap_action(KEY), "copy")
			helpers.assert_eq(remap.get_tap_holds_enabled(), true)
		end)
	end)

	-- The clear once put the switch back to its neutral off with the keys, so the
	-- next key the user set did nothing until the switch was found again.
	helpers.it("(tap-hold-clear-keeps-switch) clears the keys and leaves the switch as it is", function()
		for _, switch in ipairs({ true, false }) do
			with_fixture(function(fixture)
				local remap, calls, disk = scoped_remap(fixture)
				helpers.assert_true(remap.set_tap_holds_enabled(switch))
				calls.save, calls.saved_payloads = 0, {}
				helpers.assert_true(request(remap, "tap_holds", "clear", "/remap/backup-2"))
				disk.terminal(true, "ready")
				local saved = calls.saved_payloads[1]
				helpers.assert_eq(saved.tap_holds_enabled, switch, "the clear owns the keys, not the switch")
				helpers.assert_eq(saved.tap_hold_config[KEY], { tap = "none", hold = "none" })
				helpers.assert_eq(remap.get_tap_action(KEY), "none")
				helpers.assert_eq(remap.get_tap_holds_enabled(), switch)
				helpers.assert_eq(remap.get_combo_tap_action(COMBO), "escape")
			end)
		end
	end)

	helpers.it("lets the shortcuts scope own only the chords", function()
		with_fixture(function(fixture)
			local remap, calls, disk = scoped_remap(fixture)
			helpers.assert_true(request(remap, "shortcuts", "clear", "/remap/backup-3"))
			disk.terminal(true, "ready")
			local saved = calls.saved_payloads[1]
			helpers.assert_eq(saved.mod_combos_config[COMBO], { tap = "none", hold = "none", combo = "none" })
			helpers.assert_eq(saved.tap_hold_config[KEY].tap, "escape", "the keys belong to the tap_holds scope")
		end)
	end)

	helpers.it("refuses before any write when the backup cannot be made", function()
		with_fixture(function(fixture)
			local remap, calls, disk = scoped_remap(fixture)
			disk.files["/remap/backup-4"] = "an earlier backup"
			local accepted, settled = request(remap, "tap_holds", "clear", "/remap/backup-4")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(settled, { { ok = false, reason = "backup-refused" } })
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(disk.files["/remap/backup-4"], "an earlier backup")
			helpers.assert_eq(disk.regenerations, 0)
			helpers.assert_eq(remap.get_tap_action(KEY), "escape")
		end)
	end)

	helpers.it("restores the prior settings on a negative Karabiner terminal", function()
		with_fixture(function(fixture)
			local remap, calls, disk = scoped_remap(fixture)
			local _, settled = request(remap, "tap_holds", "recommended", "/remap/backup-5")
			disk.terminal(false, "activation-failed")
			helpers.assert_eq(calls.save, 2, "the inverse is persisted")
			helpers.assert_eq(calls.saved_payloads[2].tap_hold_config[KEY].tap, "escape")
			helpers.assert_eq(remap.settings_pending(), true, "the inverse regeneration is still owed")
			disk.terminal(true, "ready")
			helpers.assert_eq(settled[1].ok, false)
			helpers.assert_eq(remap.get_tap_action(KEY), "escape")
			helpers.assert_eq(remap.settings_pending(), false)
			helpers.assert_eq(remap.retry_settings_recovery(), true, "nothing is left to settle")
		end)
	end)

	helpers.it("refuses an unknown scope, mode or backup before touching anything", function()
		with_fixture(function(fixture)
			local remap, calls, disk = scoped_remap(fixture)
			for _, bad in ipairs({ { "gestures", "clear", "/b" }, { "tap_holds", "factory", "/b" }, { "tap_holds", "clear", "" } }) do
				local accepted, settled = request(remap, bad[1], bad[2], bad[3])
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(settled, { { ok = false, reason = "invalid-scope-request" } })
			end
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(disk.regenerations, 0)
		end)
	end)
end)

-- A fresh install has no layers.toml, which binds no key: the restored
-- left_command held an empty navigation layer. The tap-holds restore now
-- creates the recommended layer where there is none, before the regeneration
-- that deploys it, and takes it back when the transaction is refused.
-- Where the fixture's configuration folder keeps its layer file.

--- The shipped preset's bytes.

--- Owns conditional layer removal over the same classified in-memory disk.

--- Pins the production inverse to one exact conditional source and route.

helpers.describe("remap layer fixture: conditional removal", function()
	helpers.it("routes exact source removal through the classified native capability", function()
		with_fixture(function(fixture)
			local _, _, disk = scoped_remap(fixture)
			removable(disk)
			disk.files[LAYERS] = "# independently authored fixture source\n"
			local callback_count = 0
			local on_error = function() callback_count = callback_count + 1 end
			local expected = { status = "ok", content = disk.files[LAYERS] }
			helpers.assert_true(require("toml_codec.writer").remove_if_unchanged(LAYERS,
				require("adapters.file_system"), expected, { require_conditional = true, on_error = on_error }))
			helpers.assert_nil(disk.files[LAYERS])
			helpers.assert_eq(#disk.removal_calls, 1)
			helpers.assert_eq(disk.removal_calls[1].path, LAYERS)
			helpers.assert_eq(disk.removal_calls[1].expected, expected)
			helpers.assert_true(disk.removal_calls[1].on_error == on_error)
			helpers.assert_eq(callback_count, 0, "acknowledged removal reports no failure")
		end)
	end)
	helpers.it("refuses foreign routes, changed sources and explicit native refusal without deleting", function()
		for _, cause in ipairs({ "route", "source", "refusal" }) do
			with_fixture(function(fixture)
				local _, _, disk = scoped_remap(fixture)
				removable(disk)
				local original, foreign = "# owned layer\n", "/foreign/layers.toml"
				disk.files[LAYERS], disk.files[foreign] = original, original
				local path = cause == "route" and foreign or LAYERS
				local expected = { status = "ok", content = cause == "source" and "# stale source\n" or original }
				disk.refuse_remove = cause == "refusal"
				local callback_count = 0
				local on_error = function(category)
					helpers.assert_eq(category, "removal")
					callback_count = callback_count + 1
				end
				helpers.assert_eq(require("toml_codec.writer").remove_if_unchanged(path,
					require("adapters.file_system"), expected, { require_conditional = true, on_error = on_error }), false)
				helpers.assert_eq(disk.files[LAYERS], original)
				helpers.assert_eq(disk.files[foreign], original)
				helpers.assert_eq(#disk.removal_calls, 1)
				helpers.assert_eq(disk.removal_calls[1].path, path)
				helpers.assert_eq(disk.removal_calls[1].expected, expected)
				helpers.assert_true(disk.removal_calls[1].on_error == on_error)
				helpers.assert_eq(callback_count, 1, "one refusal belongs to the exact callback")
			end)
		end
	end)
end)

--- Runs a case with an observable owner of the layer's wheel bindings,
--- which Hammerspoon runs (layer-wheel-slots).
--- @param body function Receives the reconciliation counter.

helpers.describe("remap scope transaction: the recommended navigation layer", function()
	helpers.it("(nav-layer-fresh-install-default) the restore creates layers.toml before the regeneration", function()
		with_fixture(function(fixture) with_wheel_owner(function(wheel)
			local remap, _, disk = scoped_remap(fixture)
			removable(disk)
			local accepted, settled = request(remap, "tap_holds", "recommended", "/remap/backup-7")
			helpers.assert_true(accepted)
			helpers.assert_eq(disk.files[LAYERS], preset(), "the layer is on disk when the regeneration reads it")
			helpers.assert_eq(wheel.reconciles, 0, "the wheel waits for the restore's terminal")
			disk.terminal(true, "ready")
			helpers.assert_eq(settled, { { ok = true, reason = "ready" } })
			helpers.assert_eq(disk.files[LAYERS], preset())
			helpers.assert_eq(wheel.reconciles, 1, "the restored layer's wheel reaches its owner (layer-wheel-slots)")
		end) end)
	end)

	helpers.it("(nav-layer-fresh-install-default) an existing layers.toml is never replaced", function()
		with_fixture(function(fixture)
			local remap, _, disk = scoped_remap(fixture)
			removable(disk)
			disk.files[LAYERS] = "# the user's own layer\n"
			helpers.assert_true(request(remap, "tap_holds", "recommended", "/remap/backup-8"))
			disk.terminal(false, "activation-failed")
			disk.terminal(true, "ready")
			helpers.assert_eq(disk.files[LAYERS], "# the user's own layer\n", "kept, and kept by the refusal too")
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) a refused restore takes the created layer back", function()
		with_fixture(function(fixture) with_wheel_owner(function(wheel)
			local remap, _, disk = scoped_remap(fixture)
			removable(disk)
			local _, settled = request(remap, "tap_holds", "recommended", "/remap/backup-9")
			disk.terminal(false, "activation-failed")
			disk.terminal(true, "ready")
			helpers.assert_eq(settled[1].ok, false)
			helpers.assert_nil(disk.files[LAYERS], "no layer file outlives a refused restore")
			helpers.assert_eq(disk.removals, { { path = LAYERS, status = "ok", content = preset() } },
				"the inverse conditionally removes only the exact created preset")
			assert_layer_removal(disk)
			helpers.assert_eq(wheel.reconciles, 0, "a refused restore leaves the wheel as it was")
		end) end)
	end)

	helpers.it("(nav-layer-fresh-install-default) clear and the shortcuts scope never touch the layer", function()
		for _, scope in ipairs({ { "tap_holds", "clear" }, { "shortcuts", "recommended" } }) do
			with_fixture(function(fixture)
				local remap, _, disk = scoped_remap(fixture)
				helpers.assert_true(request(remap, scope[1], scope[2], "/remap/backup-10"))
				disk.terminal(true, "ready")
				helpers.assert_nil(disk.files[LAYERS], scope[1] .. " " .. scope[2])
			end)
		end
	end)
end)

-- Picking the navigation layer as the hold of a key or of a combination saved
-- the hold and nothing else: in a folder with no layers.toml the key entered a
-- layer that binds no key. The pick brings the recommended layer along, as
-- the restore does.
helpers.describe("remap setters: a hold that enters the layer brings it along", function()
	local SETTERS = {
		{ name = "key", set = function(remap, action) return remap.set_hold_action(KEY, action) end,
			get = function(remap) return remap.get_hold_action(KEY) end },
		{ name = "combination", set = function(remap, action) return remap.set_combo_hold_action(COMBO, action) end,
			get = function(remap) return remap.get_combo_hold_action(COMBO) end },
	}

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) the layer hold creates layers.toml and tells the wheel owner", function()
		for _, setter in ipairs(SETTERS) do
			with_fixture(function(fixture) with_wheel_owner(function(wheel)
				local remap, _, disk = scoped_remap(fixture)
				removable(disk)
				helpers.assert_true(setter.set(remap, "shift"), setter.name)
				helpers.assert_nil(disk.files[LAYERS], setter.name .. ": a modifier hold brings no layer file")
				helpers.assert_true(setter.set(remap, "layer"), setter.name)
				helpers.assert_eq(setter.get(remap), "layer", setter.name)
				helpers.assert_eq(disk.files[LAYERS], preset(), setter.name .. ": the recommended layer's exact bytes")
				helpers.assert_eq(wheel.reconciles, 1, setter.name .. ": the new layer's wheel reaches its owner")
				helpers.assert_true(setter.set(remap, "layer"), setter.name)
				helpers.assert_eq(wheel.reconciles, 1, setter.name .. ": a kept file changes nothing for the wheel")
			end) end)
		end
	end)

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) an existing layers.toml is never replaced", function()
		for _, setter in ipairs(SETTERS) do
			with_fixture(function(fixture)
				local remap, calls, disk = scoped_remap(fixture)
				removable(disk)
				disk.files[LAYERS] = "# the user's own layer\n"
				helpers.assert_true(setter.set(remap, "layer"), setter.name)
				helpers.assert_eq(disk.files[LAYERS], "# the user's own layer\n", setter.name)
				calls.set_save_succeeds(false)
				helpers.assert_eq(setter.set(remap, "layer"), false, setter.name)
				helpers.assert_eq(disk.files[LAYERS], "# the user's own layer\n",
					setter.name .. ": a refused save removes only a file the pick created")
			end)
		end
	end)

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) a hold that is not saved takes the created layer back", function()
		for _, setter in ipairs(SETTERS) do
			with_fixture(function(fixture) with_wheel_owner(function(wheel)
				local remap, calls, disk = scoped_remap(fixture)
				removable(disk)
				calls.set_save_succeeds(false)
				helpers.assert_eq(setter.set(remap, "layer"), false, setter.name)
				helpers.assert_nil(disk.files[LAYERS], setter.name .. ": no layer file outlives a refused save")
				helpers.assert_eq(disk.removals, { { path = LAYERS, status = "ok", content = preset() } },
					setter.name .. ": the native conditional inverse owns the exact preset bytes")
				assert_layer_removal(disk)
				helpers.assert_eq(wheel.reconciles, 0, setter.name .. ": the wheel is left as it was")
			end) end)
		end
	end)

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) a layer that cannot be imported refuses the hold", function()
		for _, setter in ipairs(SETTERS) do
			with_fixture(function(fixture)
				local remap, calls, disk = scoped_remap(fixture)
				disk.refuse = LAYERS
				helpers.assert_eq(setter.set(remap, "layer"), false, setter.name)
				helpers.assert_eq(setter.get(remap), "none", setter.name .. ": the hold is left as it was")
				helpers.assert_eq(calls.save, 0, setter.name .. ": nothing is saved for a layer that is not there")
			end)
		end
	end)
end)


helpers.describe("the combination menu has its own native scope", function()
	for _, mode in ipairs({ "recommended", "clear" }) do
		helpers.it("applies " .. mode .. " to pairs and recovers a negative terminal", function()
			with_fixture(function(fixture)
				local remap, calls, disk = scoped_remap(fixture)
				helpers.assert_true(remap.set_mod_combos_enabled(false))
				calls.save, calls.saved_payloads = 0, {}
				local accepted, settled = request(remap, "key_combinations", mode, "/remap/combination-backup")
				helpers.assert_true(accepted)
				helpers.assert_eq(disk.files["/remap/combination-backup"], SOURCE)
				local saved = calls.saved_payloads[1]
				helpers.assert_eq(saved.tap_hold_config[KEY].tap, "escape", "other keys remain intact")
				helpers.assert_eq(saved.mod_combos_config[COMBO].tap, mode == "recommended" and "paste" or "none")
				if mode == "clear" then
					helpers.assert_eq(saved.mod_combos_enabled, false, "clear preserves the switch")
				end
				helpers.assert_eq(#settled, 0, "acceptance is not success")
				disk.terminal(false, "activation-failed")
				disk.terminal(true, "ready")
				helpers.assert_eq(settled[1].ok, false)
				helpers.assert_eq(remap.get_combo_tap_action(COMBO), "escape")
				helpers.assert_eq(remap.get_mod_combos_enabled(), false)
			end)
		end)
	end
end)
