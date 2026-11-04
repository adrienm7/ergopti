--- tests/unit/platform/remap/enable_transaction/test_scope_owner_navigation_layer.lua

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
local KEY = Fixture.KEY
local LAYERS = Fixture.LAYERS
local cohort_remap = Fixture.cohort_remap
local committed_layer_scope = Fixture.committed_layer_scope
local global_cohort = Fixture.global_cohort
local preset = Fixture.preset
local request = Fixture.request
local with_fixture = Fixture.with_fixture





--- Tracks native layer deletion and the source visible at each regeneration.
--- @param fixture table Real remap transaction fixture constructors.
--- @return table, table, table Remap, persistence calls and boundary observations.

--- Captures the new receipt through the real scoped owner.
--- @param remap table Initialized native facade.
--- @param disk table Recording filesystem/deployment boundary.
--- @return table snapshot, table receipt, table callback observations.

--- Builds the real global participant around the actual remap facade. Only
--- later category ports and scheduling remain controlled boundary doubles.
--- @param remap table Initialized native facade.
--- @param refuse boolean Whether the later AI owner refuses.
--- @return table global, table observations.

helpers.describe("macOS remap navigation-layer cohort", function()
	helpers.it("backs up before creating a recommended sibling (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, calls, disk = cohort_remap(fixture)
			disk.files["/remap/cohort-occupied"] = "foreign backup"
			helpers.assert_eq(request(remap, "tap_holds", "recommended", "/remap/cohort-occupied"), false)
			helpers.assert_nil(disk.files[LAYERS])
			helpers.assert_eq(disk.layer_writes, 0, "a refused backup must never create the sibling")
			helpers.assert_eq(calls.save, 0)
		end)
	end)

	helpers.it("removes the imported sibling before compiling a failed candidate's inverse (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local _, settled = request(remap, "tap_holds", "recommended", "/remap/cohort-1")
			helpers.assert_eq(disk.files[LAYERS], preset())
			disk.terminal(false, "candidate-failed")
			helpers.assert_nil(disk.files[LAYERS])
			helpers.assert_eq(disk.layer_at_regeneration, { preset(), false })
			helpers.assert_eq(#settled, 0, "a pending inverse terminal is not an acknowledgement")
			disk.terminal(true, "inverse-ready")
			helpers.assert_eq(settled[1].ok, false)
			helpers.assert_eq(remap.settings_pending(), false)
		end)
	end)

	for _, obstruction in ipairs({ "refuse_remove", "unreadable", "external_edit" }) do
		helpers.it("retains " .. obstruction .. " cleanup debt without losing the sibling (scope-layer-cohort)", function()
			with_fixture(function(fixture)
				local remap, calls, disk = cohort_remap(fixture)
				local _, settled = request(remap, "tap_holds", "recommended", "/remap/cohort-2")
				if obstruction == "external_edit" then disk.files[LAYERS] = "# external layer change\n"
				else disk[obstruction] = true end
				local retained = disk.files[LAYERS]
				disk.terminal(false, "candidate-failed")
				helpers.assert_eq(settled, { { ok = false, reason = "candidate-failed" } })
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(disk.regenerations, 1)
				helpers.assert_eq(disk.files[LAYERS], retained)
				local saves = calls.save
				helpers.assert_eq(remap.set_tap_action(KEY, "none"), false)
				helpers.assert_eq(calls.save, saves)
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(disk.files[LAYERS], retained)
				if obstruction == "external_edit" then disk.files[LAYERS] = preset()
				else disk[obstruction] = false end
				helpers.assert_eq(remap.retry_settings_recovery(), false, "accepted inverse still owes its terminal")
				helpers.assert_nil(disk.files[LAYERS])
				helpers.assert_eq(disk.layer_at_regeneration[2], false)
				disk.terminal(true, "inverse-ready")
				helpers.assert_eq(remap.settings_pending(), false)
				helpers.assert_eq(#settled, 1, "cleanup retries do not repeat the original callback")
			end)
		end)
	end

	helpers.it("retains an unacknowledged cleanup after candidate persistence refusal (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, calls, disk = cohort_remap(fixture)
			calls.set_save_succeeds(false)
			disk.refuse_remove = true
			local accepted, settled = request(remap, "tap_holds", "recommended", "/remap/cohort-3")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(settled[1].reason, "candidate-persistence-failed")
			helpers.assert_eq(remap.settings_pending(), true)
			helpers.assert_eq(disk.files[LAYERS], preset())
			helpers.assert_eq(disk.regenerations, 0)
			disk.refuse_remove = false
			helpers.assert_eq(remap.retry_settings_recovery(), true)
			helpers.assert_nil(disk.files[LAYERS])
			helpers.assert_eq(disk.regenerations, 0)
		end)
	end)

	helpers.it("restores a parent's complete cohort using private receipt identity (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local snapshot, receipt = committed_layer_scope(remap, disk)
			receipt.path, receipt.content = "/foreign/layers.toml", "borrowed mutation"
			disk.files["/foreign/layers.toml"] = "foreign source"
			local outcomes = {}
			helpers.assert_true(remap.restore_settings(snapshot, function(ok) outcomes[#outcomes + 1] = ok end, receipt))
			helpers.assert_nil(disk.files[LAYERS])
			helpers.assert_eq(disk.files["/foreign/layers.toml"], "foreign source")
			helpers.assert_eq(disk.layer_at_regeneration[2], false)
			helpers.assert_eq(#outcomes, 0)
			disk.terminal(true, "parent-inverse-ready")
			helpers.assert_eq(outcomes, { true })
			helpers.assert_eq(remap.restore_settings(snapshot, function() end, receipt), false,
				"a consumed capability cannot remove a later file")
		end)
	end)

	helpers.it("refuses a forged receipt before any native effects (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, calls, disk = cohort_remap(fixture)
			local snapshot, receipt = committed_layer_scope(remap, disk)
			local saves, forged = calls.save, {}
			for key, value in pairs(receipt) do forged[key] = value end
			helpers.assert_eq(remap.restore_settings(snapshot, function() end, forged), false)
			helpers.assert_eq(calls.save, saves)
			helpers.assert_eq(disk.removals, 0)
			helpers.assert_eq(disk.files[LAYERS], preset())
		end)
	end)

	helpers.it("reverses a refused parent inverse without losing its imported sibling (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local snapshot, receipt = committed_layer_scope(remap, disk)
			local outcomes = {}
			helpers.assert_true(remap.restore_settings(snapshot, function(ok) outcomes[#outcomes + 1] = ok end, receipt))
			helpers.assert_nil(disk.files[LAYERS])
			disk.terminal(false, "parent-inverse-failed")
			helpers.assert_eq(disk.files[LAYERS], preset(), "the failed inverse restores its exact pre-call cohort")
			helpers.assert_eq(disk.layer_at_regeneration, { preset(), false, preset() })
			helpers.assert_eq(#outcomes, 0)
			disk.terminal(true, "inverse-compensation-ready")
			helpers.assert_eq(outcomes, { false })
			helpers.assert_true(remap.restore_settings(snapshot, function(ok) outcomes[#outcomes + 1] = ok end, receipt))
			disk.terminal(true, "parent-retry-ready")
			helpers.assert_eq(outcomes, { false, true })
			helpers.assert_nil(disk.files[LAYERS])
		end)
	end)

	helpers.it("keeps a conflicting parent-inverse compensation pending (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local snapshot, receipt = committed_layer_scope(remap, disk)
			helpers.assert_true(remap.restore_settings(snapshot, function() end, receipt))
			disk.files[LAYERS] = "# external replacement while inverse deploys\n"
			disk.terminal(false, "parent-inverse-failed")
			helpers.assert_eq(remap.settings_pending(), true)
			helpers.assert_eq(disk.files[LAYERS], "# external replacement while inverse deploys\n")
			helpers.assert_eq(remap.retry_settings_recovery(), false)
			helpers.assert_eq(disk.regenerations, 2)
		end)
	end)

	helpers.it("a later global category refusal restores settings and the layer before completion (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local global, observed = global_cohort(remap, true)
			helpers.assert_true(global.apply("recommended"))
			disk.terminal(true, "tap-holds-ready"); observed.continue()
			disk.terminal(true, "chords-ready"); observed.continue()
			helpers.assert_eq(global.pending(), true)
			disk.terminal(true, "chords-inverse-ready"); observed.continue()
			helpers.assert_nil(disk.files[LAYERS], "the parent retains the exact import receipt")
			helpers.assert_eq(disk.layer_at_regeneration[4], false)
			helpers.assert_eq(#observed.refreshes, 0)
			disk.terminal(true, "tap-holds-inverse-ready"); observed.continue()
			helpers.assert_eq(observed.refreshes[1].ok, false)
			helpers.assert_eq(observed.refreshes[1].report.reverted, true)
			helpers.assert_eq(global.pending(), false)
			helpers.assert_eq(remap.get_tap_action(KEY), "escape")
		end)
	end)

	helpers.it("global retry still owes its parent target after native compensation settles (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local global, observed = global_cohort(remap, true)
			helpers.assert_true(global.apply("recommended"))
			disk.terminal(true, "tap-holds-ready"); observed.continue()
			disk.terminal(true, "chords-ready"); observed.continue()
			disk.terminal(true, "chords-inverse-ready"); observed.continue()
			disk.terminal(false, "tap-holds-inverse-failed")
			disk.terminal(false, "native-compensation-failed"); observed.continue()
			helpers.assert_eq(global.pending(), true)
			helpers.assert_eq(observed.refreshes[1].report.reverted, false)
			local results = {}
			helpers.assert_true(global.retry_restore(function(ok) results[#results + 1] = ok end))
			helpers.assert_eq(results, { false })
			disk.terminal(false, "native-compensation-still-failed")
			local regenerate = remap.regenerate
			remap.regenerate = function(done)
				remap.regenerate = regenerate
				done(true, "native-compensation-ready")
				return true
			end
			helpers.assert_true(global.retry_restore(function(ok) results[#results + 1] = ok end))
			helpers.assert_eq(global.pending(), true, "recovery alone cannot acknowledge the parent's inverse")
			helpers.assert_nil(disk.files[LAYERS])
			helpers.assert_eq(#results, 1)
			disk.terminal(true, "parent-target-ready"); observed.continue()
			helpers.assert_eq(results, { false, true })
			helpers.assert_eq(global.pending(), false)
			helpers.assert_eq(remap.get_tap_action(KEY), "escape")
		end)
	end)

	helpers.it("an absent success receipt never releases the global cohort (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local apply = remap.apply_scope
			remap.apply_scope = function(options, done)
				return apply(options, function(ok, reason, count) done(ok, reason, count) end)
			end
			local global, observed = global_cohort(remap, false)
			helpers.assert_true(global.apply("recommended"))
			disk.terminal(true, "tap-holds-ready"); observed.continue()
			helpers.assert_eq(#observed.refreshes, 1, "a missing receipt must settle as global refusal")
			helpers.assert_eq(observed.refreshes[1].ok, false)
			helpers.assert_eq(observed.refreshes[1].report.reverted, false)
			helpers.assert_eq(global.pending(), true)
			helpers.assert_eq(disk.regenerations, 1)
			helpers.assert_eq(disk.files[LAYERS], preset())
		end)
	end)

	helpers.it("global success keeps the acknowledged import (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			local global, observed = global_cohort(remap, false)
			helpers.assert_true(global.apply("recommended"))
			disk.terminal(true, "tap-holds-ready"); observed.continue()
			disk.terminal(true, "chords-ready"); observed.continue()
			helpers.assert_eq(observed.refreshes[1].ok, true)
			helpers.assert_eq(global.pending(), false)
			helpers.assert_eq(disk.files[LAYERS], preset())
			helpers.assert_eq(disk.removals, 0)
		end)
	end)
end)


helpers.describe("macOS remap cohort source races", function()
	helpers.it("detects a layer edited between cleanup admission and native undo (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			helpers.assert_true(request(remap, "tap_holds", "recommended", "/remap/cohort-race-1"))
			local files, base = require("adapters.file_system"), require("adapters.file_system").read_with_status
			local reads = 0
			files.read_with_status = function(path)
				if path == LAYERS then
					reads = reads + 1
					if reads == 2 then disk.files[path] = "# externally changed inside cleanup\n" end
				end
				return base(path)
			end
			disk.terminal(false, "candidate-failed")
			helpers.assert_eq(remap.settings_pending(), true)
			helpers.assert_eq(disk.files[LAYERS], "# externally changed inside cleanup\n")
			helpers.assert_eq(disk.regenerations, 1, "a foreign retained source cannot count as restored absence")
		end)
	end)

	helpers.it("verifies native removal instead of accepting a false successful receipt (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			helpers.assert_true(request(remap, "tap_holds", "recommended", "/remap/cohort-race-2"))
			require("adapters.file_system").remove_exact = function() return true end
			disk.terminal(false, "candidate-failed")
			helpers.assert_eq(remap.settings_pending(), true)
			helpers.assert_eq(disk.files[LAYERS], preset())
			helpers.assert_eq(disk.regenerations, 1)
		end)
	end)

	helpers.it("retains partial parent preparation until its removed bytes are restored (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, calls, disk = cohort_remap(fixture)
			local snapshot, receipt = committed_layer_scope(remap, disk)
			local saves = calls.save
			require("adapters.file_system").remove_exact = function(path)
				disk.files[path], disk.unreadable = nil, true
				return true
			end
			helpers.assert_eq(remap.restore_settings(snapshot, function() end, receipt), false)
			helpers.assert_eq(remap.settings_pending(), true)
			helpers.assert_eq(calls.save, saves, "a partial sibling preparation must not persist the target")
			disk.unreadable = false
			helpers.assert_eq(remap.retry_settings_recovery(), true)
			helpers.assert_eq(disk.files[LAYERS], preset())
			helpers.assert_eq(remap.get_tap_action(KEY), "copy")
			helpers.assert_eq(disk.regenerations, 1)
		end)
	end)

	helpers.it("restores a partial removal even when the native boundary refuses (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, calls, disk = cohort_remap(fixture)
			local snapshot, receipt = committed_layer_scope(remap, disk)
			local saves = calls.save
			require("adapters.file_system").remove_exact = function(path)
				disk.files[path], disk.unreadable = nil, true
				return false, "controlled refusal after partial removal"
			end
			helpers.assert_eq(remap.restore_settings(snapshot, function() end, receipt), false)
			helpers.assert_eq(remap.settings_pending(), true)
			helpers.assert_eq(calls.save, saves)
			disk.unreadable = false
			helpers.assert_eq(remap.retry_settings_recovery(), true)
			helpers.assert_eq(disk.files[LAYERS], preset(), "the failed parent inverse still owes its removed source")
			helpers.assert_eq(remap.get_tap_action(KEY), "copy")
			helpers.assert_eq(disk.regenerations, 1)
		end)
	end)

	helpers.it("keeps an existing user's layer outside the global mutation cohort (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, _, disk = cohort_remap(fixture)
			disk.files[LAYERS] = "# foreign layer content\n"
			local global, observed = global_cohort(remap, true)
			helpers.assert_true(global.apply("recommended"))
			disk.terminal(true, "tap-holds-ready"); observed.continue()
			disk.terminal(true, "chords-ready"); observed.continue()
			disk.terminal(true, "chords-inverse-ready"); observed.continue()
			disk.terminal(true, "tap-holds-inverse-ready"); observed.continue()
			helpers.assert_eq(global.pending(), false)
			helpers.assert_eq(observed.refreshes[1].report.reverted, true)
			helpers.assert_eq(disk.files[LAYERS], "# foreign layer content\n")
			helpers.assert_eq(disk.layer_writes, 0)
			helpers.assert_eq(disk.removals, 0)
		end)
	end)
end)


helpers.describe("macOS parent inverse removal-release debt", function()
	helpers.it("retains no-effect unlink debt until native release settles (scope-layer-cohort)", function()
		with_fixture(function(fixture)
			local remap, calls, disk = cohort_remap(fixture)
			local snapshot, receipt = committed_layer_scope(remap, disk)
			local blocked, cleanup_calls, outcomes = true, 0, {}
			local saves = calls.save
			require("adapters.file_system").remove_if_unchanged = function(path, expected)
				helpers.assert_eq(path, LAYERS)
				helpers.assert_eq(expected.content, disk.files[path])
				return false, "unlink refused without effect; release retained", function()
					cleanup_calls = cleanup_calls + 1
					return not blocked, nil, false
				end
			end
			helpers.assert_eq(remap.restore_settings(snapshot, function(ok) outcomes[#outcomes + 1] = ok end, receipt), false)
			helpers.assert_eq(remap.settings_pending(), true,
				"no settings or file effect cannot retire the retained native release")
			helpers.assert_eq(outcomes, { false }, "the facade must report refusal while retaining cleanup debt")
			helpers.assert_eq(remap.retry_settings_recovery(), false)
			helpers.assert_eq(remap.settings_pending(), true)
			helpers.assert_eq(calls.save, saves)
			helpers.assert_eq(disk.files[LAYERS], preset())
			helpers.assert_eq(disk.regenerations, 1)
			blocked = false
			helpers.assert_eq(remap.retry_settings_recovery(), true)
			helpers.assert_eq(remap.settings_pending(), false)
			helpers.assert_eq(outcomes, { false })
			helpers.assert_eq(cleanup_calls, 3, "the actual parent must retry the same retained capability")
			helpers.assert_eq(disk.files[LAYERS], preset())
			helpers.assert_eq(remap.get_tap_action(KEY), "copy")
			helpers.assert_eq(disk.regenerations, 1)
		end)
	end)
end)
