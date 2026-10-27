--- tests/unit/infra/scope/test_keyboard_layout_scope.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Scope (Linux, config only)
--- DESCRIPTION:
--- The layout category of the global restore on Linux changes config.toml's
--- layout rows, then applies them to the running layout where the session loads
--- one live. Pins the transaction (rows restored or cleared, foreign content
--- kept, exact inverse, refused publication leaves the file alone, a refused
--- revert stays owed), the composition (the participant registers and a later
--- refusal reverts it) and the acknowledgement: a live request settles only once
--- the layout manager reports the layout loaded, and puts the file back if not.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

local SOURCE = '[layout]\ndirect_access_digits = "digits"\nnumber_row_reorder_edges = true\nunknown = "keep"\n[other]\nopaque = [1, 2]\n'

local function with_scope(body)
	Sandbox.with_config(SOURCE, function(path)
		local names = { "infra.config_paths", "infra.keyboard_layout_scope" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local controls = {}
		local backup = path .. ".scope-backup"
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional publication") end,
				write_if_unchanged = function(target, content, expected)
					if controls.refuse == target then return false, "injected refusal" end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			local Scope = require("infra.keyboard_layout_scope")
			local owner = Scope.new({ path = path, backup_path = backup, files = files })
			body(owner, controls, path, backup, Scope)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		os.remove(backup)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Linux keyboard layout scope", function()
	helpers.it("restores the recommended layout rows and keeps foreign content", function()
		with_scope(function(owner, _, path)
			helpers.assert_eq(owner.apply("recommended"), true)
			local document = Codec.decode(Sandbox.read_bytes(path))
			-- Linux recommends the declared defaults, which the file leaves implicit.
			helpers.assert_eq(document.layout.direct_access_digits, nil)
			helpers.assert_eq(document.layout.number_row_reorder_edges, nil)
			helpers.assert_eq(document.layout.unknown, "keep")
			helpers.assert_eq(document.other.opaque, { 1, 2 })
		end)
	end)

	helpers.it("clears the layout rows and keeps foreign content", function()
		with_scope(function(owner, _, path)
			helpers.assert_eq(owner.apply("clear"), true)
			local document = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(document.layout.direct_access_digits, nil)
			helpers.assert_eq(document.layout.number_row_reorder_edges, nil)
			helpers.assert_eq(document.layout.unknown, "keep")
		end)
	end)

	helpers.it("puts the exact bytes back on revert and leaves no debt", function()
		with_scope(function(owner, _, path)
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(owner.apply("recommended"), true)
			helpers.assert_eq(owner.revert(), true)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	helpers.it("preserves a preexisting backup and refuses before changing the file", function()
		with_scope(function(owner, _, path, backup)
			local before = Sandbox.read_bytes(path)
			Sandbox.write_bytes(backup, "reserved backup")
			helpers.assert_eq(owner.apply("recommended"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(Sandbox.read_bytes(backup), "reserved backup")
		end)
	end)

	helpers.it("refuses a paused request and an unknown mode before any request", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq((Scope.apply("recommended", function() return true end)), false)
			helpers.assert_eq((Scope.apply("bogus", function() return false end)), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
		end)
	end)

	helpers.it("composes through the participant and reverts when a later category refuses", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local participant = Scope.participant(function() return false end)
			local settled
			participant.apply("recommended", function(ok) settled = ok end)
			helpers.assert_eq(settled, true)
			helpers.assert_true(Sandbox.read_bytes(path) ~= before)
			local reverted
			participant.revert(function(ok) reverted = ok end)
			helpers.assert_eq(reverted, true)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(participant.pending(), false)
		end)
	end)
end)

--- A layout application the test settles by hand.
local function manual_live(available)
	local live = { calls = 0, pending_callback = nil }
	function live.available() return available end
	function live.apply_stored(on_done)
		live.calls = live.calls + 1
		live.pending_callback = on_done
		return true
	end
	return live
end

helpers.describe("Linux keyboard layout scope: acknowledged after the layout is loaded (number-row-scope-live)", function()
	helpers.it("settles only when the layout manager reports the layout loaded", function()
		with_scope(function(_, _, path, _, Scope)
			local live = manual_live(true)
			local participant = Scope.participant(function() return false end, live)
			local settled
			participant.apply("recommended", function(ok) settled = ok end)
			helpers.assert_eq(settled, nil, "the file is written but the layout is not loaded yet")
			helpers.assert_eq(live.calls, 1)
			helpers.assert_eq(participant.pending(), true, "an application in flight is unsettled debt")
			live.pending_callback(true)
			helpers.assert_eq(settled, true)
			helpers.assert_eq(participant.pending(), false)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).layout.direct_access_digits, nil)
		end)
	end)

	helpers.it("puts the file back and refuses when the layout did not follow", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local live = manual_live(true)
			local participant = Scope.participant(function() return false end, live)
			local settled, detail
			participant.apply("recommended", function(ok, why) settled, detail = ok, why end)
			live.pending_callback(false, "live_apply_failed", "not loaded", "not_loaded")
			helpers.assert_eq(settled, false)
			helpers.assert_contains(detail, "live_apply_failed/not_loaded")
			helpers.assert_eq(Sandbox.read_bytes(path), before, "the restored rows are not left in the file")
			helpers.assert_eq(participant.pending(), false)
		end)
	end)

	helpers.it("stays config only where the session cannot load a layout live", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local live = manual_live(false)
			local participant = Scope.participant(function() return false end, live)
			local settled
			participant.apply("recommended", function(ok) settled = ok end)
			helpers.assert_eq(settled, true)
			helpers.assert_eq(live.calls, 0)
			helpers.assert_true(Sandbox.read_bytes(path) ~= before)
		end)
	end)

	helpers.it("reverts the file, then the running layout, and reports a layout that does not follow", function()
		with_scope(function(_, _, path, _, Scope)
			local before = Sandbox.read_bytes(path)
			local live = manual_live(true)
			local participant = Scope.participant(function() return false end, live)
			participant.apply("recommended", function() end)
			live.pending_callback(true)
			local reverted
			participant.revert(function(ok) reverted = ok end)
			helpers.assert_eq(Sandbox.read_bytes(path), before, "the file is back first")
			helpers.assert_eq(reverted, nil, "the layout is not back yet")
			helpers.assert_eq(live.calls, 2)
			live.pending_callback(false, "live_apply_failed")
			helpers.assert_eq(reverted, false)
		end)
	end)
end)
