--- tests/unit/platform/remap/enable_transaction/test_scope_owner.lua

--- ==============================================================================
--- MODULE: Remap Scope Transaction
--- DESCRIPTION:
--- The remap part of a manifest scope runs as one exact bulk transaction: the
--- tap_holds scope owns the keys, their master and timings, the shortcuts scope
--- owns the chords. Each request backs up the exact file bytes first, saves only
--- over those bytes, and claims success only on the Karabiner terminal.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

local KEY, COMBO = "left_shift", "left_shift+right_shift"
local SOURCE = '[tap_holds]\nenabled = false\n[future]\nkeep = true\n'

--- Loads an enabled remap whose persistence and backup file are observable.
--- @param fixture table remap_transaction_fixture constructors.
--- @return table remap, table calls, table disk
local function scoped_remap(fixture)
	local remap, calls = fixture.load_enabled_remap()
	local Config = package.loaded["platform.remap.config"]
	local disk = { files = { ["/remap/config_karabiner.toml"] = SOURCE }, expected = {}, regenerations = 0 }
	local neutral_combo = { tap = "none", hold = "none", combo = "none" }
	Config.build_default_state = function()
		return { tap_holds_enabled = false, tap_hold_config = { [KEY] = { tap = "none", hold = "none" } },
			mod_combos_config = { [COMBO] = neutral_combo }, tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000,
			simultaneous_threshold_ms = 50, combo_symmetric = false }
	end
	Config.build_recommended_state = function()
		return { tap_holds_enabled = true, tap_hold_config = { [KEY] = { tap = "copy", hold = "shift" } },
			mod_combos_config = { [COMBO] = { tap = "paste", hold = "none", combo = "none" } },
			tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000, simultaneous_threshold_ms = 50, combo_symmetric = false }
	end
	local save = Config.save_user_config
	Config.save_user_config = function(state, path, overwrite, expected)
		disk.expected[#disk.expected + 1] = expected or false
		return save(state, path, overwrite, expected)
	end
	package.loaded["infra.config_paths"].get = function(key)
		assert(key == "KarabinerConfigPath", "unexpected path key " .. tostring(key))
		return "/remap/config_karabiner.toml"
	end
	local files = require("adapters.file_system")
	files.remove_exact = function(path)
		disk.files[path] = nil
		return true
	end
	files.read_with_status = function(path)
		local content = disk.files[path]
		return content, content and "ok" or "absent"
	end
	files.write_if_unchanged = function(path, content, expected)
		if disk.refuse == path then return false, "refused by the test" end
		local current = disk.files[path]
		if (expected.status == "absent" and current ~= nil)
			or (expected.status == "ok" and current ~= expected.content) then return false, "changed" end
		disk.files[path] = content
		return true
	end
	remap.regenerate = function(on_done)
		disk.regenerations = disk.regenerations + 1
		disk.terminal = on_done
		return true
	end
	helpers.assert_true(remap.set_tap_action(KEY, "escape"))
	helpers.assert_true(remap.set_combo_tap_action(COMBO, "escape"))
	calls.save, calls.saved_payloads = 0, {}
	disk.expected = {}
	return remap, calls, disk
end

--- Requests one scope and returns its settlement record.
local function request(remap, scope, mode, backup_path)
	local settled = {}
	local accepted = remap.apply_scope({ scope = scope, mode = mode, backup_path = backup_path },
		function(ok, reason) settled[#settled + 1] = { ok = ok, reason = reason } end)
	return accepted, settled
end

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
local LAYERS = "tests/unit/platform/remap/no-layers-toml/layers.toml"

--- The shipped preset's bytes.
local function preset()
	local fh = assert(io.open(helpers.shared("keymap/layers.recommended.toml"), "rb"))
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Lets the disk double remove a file, as the macOS adapter does.
local function removable(disk)
	require("adapters.file_system").remove_exact = function(path)
		disk.files[path] = nil
		return true
	end
end

--- Runs a case with an observable owner of the layer's wheel bindings,
--- which Hammerspoon runs (layer-wheel-slots).
--- @param body function Receives the reconciliation counter.
local function with_wheel_owner(body)
	helpers.with_fresh_modules({ "modules.shortcuts.bindings" }, function()
		local owner = { reconciles = 0 }
		package.loaded["modules.shortcuts.bindings"] = { reconcile_layer_wheel = function()
			owner.reconciles = owner.reconciles + 1
			return true
		end }
		body(owner)
	end)
end

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


--- Tracks native layer deletion and the source visible at each regeneration.
--- @param fixture table Real remap transaction fixture constructors.
--- @return table, table, table Remap, persistence calls and boundary observations.
local function cohort_remap(fixture)
	local remap, calls, disk = scoped_remap(fixture)
	disk.layer_reads, disk.layer_writes, disk.removals, disk.layer_at_regeneration = 0, 0, 0, {}
	local files, read = require("adapters.file_system"), require("adapters.file_system").read_with_status
	files.read_with_status = function(path)
		if path == LAYERS then
			disk.layer_reads = disk.layer_reads + 1
			if disk.unreadable then return nil, "error", "controlled native read refusal" end
		end
		return read(path)
	end
	local write = files.write_if_unchanged
	files.write_if_unchanged = function(path, content, expected)
		if path == LAYERS then disk.layer_writes = disk.layer_writes + 1 end
		return write(path, content, expected)
	end
	files.remove_exact = function(path)
		disk.removals = disk.removals + 1
		if disk.refuse_remove then return false, "controlled native removal refusal" end
		disk.files[path] = nil
		return true
	end
	remap.regenerate = function(on_done)
		disk.regenerations = disk.regenerations + 1
		disk.layer_at_regeneration[disk.regenerations] = disk.files[LAYERS] or false
		disk.terminal = on_done
		return true
	end
	return remap, calls, disk
end

--- Captures the new receipt through the real scoped owner.
--- @param remap table Initialized native facade.
--- @param disk table Recording filesystem/deployment boundary.
--- @return table snapshot, table receipt, table callback observations.
local function committed_layer_scope(remap, disk)
	local snapshot, terminal = remap.snapshot_settings(), {}
	helpers.assert_true(remap.apply_scope({ scope = "tap_holds", mode = "recommended", backup_path = "/remap/cohort-backup" },
		function(ok, reason, changes, receipt)
			terminal[#terminal + 1] = { ok = ok, reason = reason, changes = changes, receipt = receipt }
		end))
	disk.terminal(true, "ready")
	helpers.assert_eq(#terminal, 1)
	helpers.assert_eq(terminal[1].ok, true)
	helpers.assert_type(terminal[1].receipt, "table")
	return snapshot, terminal[1].receipt, terminal
end

--- Builds the real global participant around the actual remap facade. Only
--- later category ports and scheduling remain controlled boundary doubles.
--- @param remap table Initialized native facade.
--- @param refuse boolean Whether the later AI owner refuses.
--- @return table global, table observations.
local function global_cohort(remap, refuse)
	local observed = { deferred = {}, refreshes = {} }
	local late = { apply = function() return not refuse end, revert = function() return true end,
		release = function() end, pending = function() return false end, retry_restore = function() return true end }
	local global = require("ui.menu.global_scope").new({
		owners = { llm = function() return late end }, remap = remap,
		backup_path = function(scope) return "/remap/global-cohort-" .. scope end,
		defer = function(fn) observed.deferred[#observed.deferred + 1] = fn; return true end,
		paused = function() return false end,
		refresh = function(ok, report) observed.refreshes[#observed.refreshes + 1] = { ok = ok, report = report } end,
	})
	function observed.continue()
		local fn = table.remove(observed.deferred, 1)
		helpers.assert_type(fn, "function", "the actual participant must schedule its continuation")
		return fn()
	end
	return global, observed
end

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

return true
