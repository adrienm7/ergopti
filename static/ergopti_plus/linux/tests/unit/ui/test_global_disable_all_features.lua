--- tests/unit/ui/test_global_disable_all_features.lua

--- ==============================================================================
--- MODULE: « Disable all » Works Like A Pause, « Enable all » Restores (Linux)
--- DESCRIPTION:
--- The tray's « Disable all » only switched the hotstrings off, and « Enable
--- all » switched every category AND every bundled section on instead of giving
--- the user back what they had. Both now go through ui/menu/global_feature_switch:
--- every feature switch goes off (hotstrings, shortcuts, gestures, AI, metrics,
--- dynamic hotstrings, kanata tap-holds), no assignment is touched, and Enable
--- all restores the persisted snapshot.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")
local Switch = helpers.load_module("ui.menu.global_feature_switch")

--- A boolean feature double that records every change and its assignments.
--- @param id string
--- @param on boolean
--- @param log table Shared change log.
--- @return table descriptor, table state
local function feature(id, on, log)
	local state = { on = on, assignments = { swipe_3_left = "select_line" }, refuse = false }
	local function set(want)
		if state.refuse then return false end
		log[#log + 1] = id .. "=" .. tostring(want)
		state.on = want
		return true
	end
	return {
		id = id,
		capture = function() return state.on end,
		disable = function() return set(false) end,
		restore = function(value) return set(value == true) end,
		enable = function() return set(true) end,
	}, state
end

--- Every feature id the daemon must hand to the switch.
local DAEMON_FEATURES = {
	"hotstrings", "shortcuts", "gestures", "llm", "metrics", "dynamic_hotstrings", "tap_holds",
}

helpers.describe("global disable all (linux): every feature, assignments kept", function()
	helpers.it("switches every feature off and keeps every assignment", function()
		local log = {}
		local shortcuts, s_state = feature("shortcuts", true, log)
		local gestures, g_state = feature("gestures", true, log)
		local metrics, m_state = feature("metrics", false, log)
		local storage = Fakes.storage()
		local switch = Switch.new({ features = { shortcuts, gestures, metrics }, storage = storage })
		helpers.assert_true(switch.disable_all())
		helpers.assert_eq(s_state.on, false)
		helpers.assert_eq(g_state.on, false)
		helpers.assert_eq(m_state.on, false)
		helpers.assert_eq(g_state.assignments.swipe_3_left, "select_line",
			"Disable all must switch features, never clear a binding")
		helpers.assert_true(switch.is_all_disabled())
		helpers.assert_eq(storage.values[Switch.STORAGE_KEY],
			{ shortcuts = true, gestures = true, metrics = false },
			"the snapshot is what each feature had before Disable all")
	end)

	helpers.it("restores exactly the previous state, not everything on", function()
		local log = {}
		local shortcuts, s_state = feature("shortcuts", true, log)
		local metrics, m_state = feature("metrics", false, log)
		local storage = Fakes.storage()
		local switch = Switch.new({ features = { shortcuts, metrics }, storage = storage })
		switch.disable_all()
		helpers.assert_true(switch.enable_all())
		helpers.assert_eq(s_state.on, true, "a feature that was on comes back on")
		helpers.assert_eq(m_state.on, false, "a feature the user had off stays off")
		helpers.assert_true(not switch.is_all_disabled(), "the snapshot is consumed")
	end)

	helpers.it("restores after a restart from the persisted snapshot", function()
		local storage = Fakes.storage({ initial = {
			[Switch.STORAGE_KEY] = { shortcuts = true, metrics = false },
		} })
		local log = {}
		local shortcuts, s_state = feature("shortcuts", false, log)
		local metrics, m_state = feature("metrics", false, log)
		local switch = Switch.new({ features = { shortcuts, metrics }, storage = storage })
		helpers.assert_true(switch.enable_all())
		helpers.assert_eq(s_state.on, true)
		helpers.assert_eq(m_state.on, false)
	end)

	helpers.it("rolls every switched feature back when one refuses", function()
		local log = {}
		local shortcuts, s_state = feature("shortcuts", true, log)
		local gestures, g_state = feature("gestures", true, log)
		g_state.refuse = true
		local storage = Fakes.storage()
		local switch = Switch.new({ features = { shortcuts, gestures }, storage = storage })
		helpers.assert_true(not switch.disable_all())
		helpers.assert_eq(s_state.on, true, "the feature already switched off is switched back on")
		helpers.assert_true(not switch.is_all_disabled(), "a failed Disable all leaves no snapshot")
	end)

	helpers.it("changes nothing when the snapshot cannot be persisted", function()
		local log = {}
		local shortcuts, s_state = feature("shortcuts", true, log)
		local switch = Switch.new({ features = { shortcuts }, storage = Fakes.storage({ writes_fail = true }) })
		helpers.assert_true(not switch.disable_all())
		helpers.assert_eq(s_state.on, true)
		helpers.assert_eq(log, {})
	end)

	helpers.it("re-applies the runtime-only switches after a restart", function()
		local log = {}
		local dyn, d_state = feature("dynamic_hotstrings", true, log)
		dyn.persistent = false
		local shortcuts = feature("shortcuts", false, log)
		local storage = Fakes.storage({ initial = {
			[Switch.STORAGE_KEY] = { dynamic_hotstrings = true, shortcuts = true },
		} })
		local switch = Switch.new({ features = { dyn, shortcuts }, storage = storage })
		helpers.assert_eq(switch.reapply_after_boot(), 1)
		helpers.assert_eq(d_state.on, false)
		helpers.assert_eq(log, { "dynamic_hotstrings=false" },
			"persisted switches already read back off; only the runtime one is re-applied")
	end)
end)

helpers.describe("global disable all (linux): hotstring gates restore exactly", function()
	helpers.it("gives back the gates and the section choices the user had", function()
		local Loader = require("modules.hotstrings.loader")
		local saved = {}
		for _, name in ipairs({ "load_catalogue", "list_subdirs", "find_toml_files" }) do saved[name] = Loader[name] end
		local storage_before = package.loaded["adapters.storage"]
		local config_before = package.loaded["modules.hotstrings.hotstrings_config"]
		local storage = Fakes.storage({ initial = {
			["hotstrings.disabled_categories"] = "beta",
		} })
		package.loaded["adapters.storage"] = storage
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		Loader.list_subdirs = function() return {} end
		Loader.find_toml_files = function() return {} end
		Loader.load_catalogue = function()
			return {
				committed = true, errors = 0, mappings = {},
				categories = {
					alpha = { sections = { s1 = {}, s2 = {} } },
					beta = { sections = { s3 = {} } },
					gamma = { sections = {} },
				},
			}
		end
		local ok, err = pcall(function()
			local config = require("modules.hotstrings.hotstrings_config")
			config.init(require("modules.hotstrings.engine").new(), "/tmp/ergopti_global_switch_probe.toml")
			config.load_all()
			local before = storage.values["hotstrings.disabled_categories"]
			local closed = config.closed_category_gates()
			helpers.assert_eq(closed, { "beta" })
			config.disable_all()
			helpers.assert_eq(config.closed_category_gates(), { "alpha", "beta", "gamma" })
			helpers.assert_true(config.restore_category_gates(closed))
			helpers.assert_eq(storage.values["hotstrings.disabled_categories"], before,
				"Enable all used to add an enabled mark for every section, switching bundled packs on")
		end)
		for name, fn in pairs(saved) do Loader[name] = fn end
		package.loaded["adapters.storage"] = storage_before
		package.loaded["modules.hotstrings.hotstrings_config"] = config_before
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("global disable all (linux): kanata tap-holds switch", function()
	helpers.it("types every tap-hold key natively when the feature is off", function()
		local Gen = require("tap_hold.kanata_generator")
		local keys = {
			caps_lock  = { time_activation_seconds = 0.2, tap_action = "enter", hold_modifier = "ctrl" },
			left_shift = { time_activation_seconds = 0.2, tap_action = "copy", hold_modifier = "shift" },
			tab        = { time_activation_seconds = 0.2, tap_action = "alt_tab_monitor", hold_modifier = "alt" },
			right_ctrl = { time_activation_seconds = 0.2, tap_action = "one_shot_shift" },
		}
		local on = Gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		local off = Gen.generate(keys, { one_shot_shift_timeout_ms = 2000, tap_holds_enabled = false })
		helpers.assert_true(on:find("tap-hold-press", 1, true) ~= nil, "on keeps the directives")
		helpers.assert_nil(off:find("tap-hold-press", 1, true), "off emits no tap-hold directive")
		helpers.assert_nil(off:find("one-shot", 1, true), "off emits no one-shot directive")
		for _, line in ipairs({ "cap        caps", "lsft       lsft", "alttab     tab", "ossft      rctl" }) do
			helpers.assert_true(off:find(line, 1, true) ~= nil,
				"every alias the layer references stays defined: missing '" .. line .. "' in\n" .. off)
		end
	end)
end)

helpers.describe("global disable all (linux): the tap-hold switch reaches kanata", function()
	helpers.it("restarts a running kanata and rolls back when it cannot", function()
		local Remap = helpers.load_module("platform.remap.manager")
		local real_running, real_restart = Remap.is_running, Remap.restart
		local restarts = {}
		local restart_ok = true
		Remap.is_running = function() return true end
		Remap.restart = function()
			restarts[#restarts + 1] = Remap.tap_holds_enabled()
			return restart_ok
		end
		local ok, err = pcall(function()
			helpers.assert_true(Remap.set_tap_holds_enabled(false))
			helpers.assert_eq(restarts, { false }, "kanata restarts on the configuration without tap-holds")
			helpers.assert_eq(Remap.tap_holds_enabled(), false)
			restart_ok = false
			helpers.assert_true(not Remap.set_tap_holds_enabled(true))
			helpers.assert_eq(Remap.tap_holds_enabled(), false,
				"a switch kanata could not apply is rolled back, not reported as on")
		end)
		Remap.is_running, Remap.restart = real_running, real_restart
		helpers.load_module("platform.remap.manager")
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("global disable all (linux): the daemon hands every feature over", function()
	helpers.it("wires the tray rows to the switch with every feature", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("global_switch.disable_all()", 1, true) ~= nil,
			"the Disable all row must go through the global switch")
		helpers.assert_true(src:find("global_switch.enable_all()", 1, true) ~= nil,
			"the Enable all row must go through the global switch")
		helpers.assert_nil(src:find("on_enable_all%s*=%s*function%(%)%s*hotstrings_config%.enable_all"),
			"Enable all must not switch every hotstring section on")
		for _, id in ipairs(DAEMON_FEATURES) do
			helpers.assert_true(src:find('"' .. id .. '"', 1, true) ~= nil,
				"the daemon must hand the '" .. id .. "' feature to the global switch")
		end
		helpers.assert_true(src:find("global_switch.reapply_after_boot()", 1, true) ~= nil,
			"runtime-only switches must be re-applied after a restart")
	end)
end)
