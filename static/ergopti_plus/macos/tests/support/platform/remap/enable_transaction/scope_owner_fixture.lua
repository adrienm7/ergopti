--- tests/support/platform/remap/enable_transaction/scope_owner_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_scope_owner
--- DESCRIPTION:
--- Prelude shared by the test_scope_owner_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
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
	-- This remap fixture models persistence over its private disk. Native
	-- cooperative locking is exercised with real files by the adapter suite.
	files.remove_if_unchanged = function(path, expected)
		if disk.files[path] ~= expected.content then return false, "changed" end
		return files.remove_exact(path)
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


local LAYERS = "tests/unit/platform/remap/no-layers-toml/layers.toml"

local function preset()
	local fh = assert(io.open(helpers.shared("keymap/layers.recommended.toml"), "rb"))
	local text = fh:read("*a")
	fh:close()
	return text
end

local function removable(disk)
	local files = require("adapters.file_system")
	disk.removal_calls = {}
	disk.removals = {}
	files.remove_exact = function() error("layer compensation must use conditional removal") end
	files.remove_if_unchanged = function(path, expected, on_error)
		disk.removals[#disk.removals + 1] = { path = path, status = expected.status, content = expected.content }
		disk.removal_calls[#disk.removal_calls + 1] = { path = path,
			expected = { status = expected.status, content = expected.content }, on_error = on_error }
		if path ~= LAYERS or expected.status ~= "ok" or type(expected.content) ~= "string"
			or disk.files[path] ~= expected.content or disk.refuse_remove == true then
			if on_error then on_error("removal") end
			return false, "fixture conditional removal refused"
		end
		disk.files[path] = nil
		return true
	end
end

local function assert_layer_removal(disk)
	helpers.assert_eq(#disk.removal_calls, 1, "one conditional inverse removes the created layer")
	helpers.assert_eq(disk.removal_calls[1].path, LAYERS)
	helpers.assert_eq(disk.removal_calls[1].expected, { status = "ok", content = preset() })
	helpers.assert_nil(disk.removal_calls[1].on_error, "ordinary compensation keeps its actual callback policy")
end

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

return {
	COMBO = COMBO,
	KEY = KEY,
	LAYERS = LAYERS,
	SOURCE = SOURCE,
	assert_layer_removal = assert_layer_removal,
	cohort_remap = cohort_remap,
	committed_layer_scope = committed_layer_scope,
	global_cohort = global_cohort,
	preset = preset,
	removable = removable,
	request = request,
	scoped_remap = scoped_remap,
	with_fixture = with_fixture,
	with_wheel_owner = with_wheel_owner,
}
