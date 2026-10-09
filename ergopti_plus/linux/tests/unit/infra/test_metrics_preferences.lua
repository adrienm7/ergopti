--- tests/unit/infra/test_metrics_preferences.lua

--- ==============================================================================
--- MODULE: Canonical Metrics Preference Contract
--- DESCRIPTION:
--- Exercises real TOML publication and fresh collector/readout consumers with
--- an isolated file, including conflicting legacy values and malformed input.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")

local function with_config(source, body)
	Sandbox.with_config(source, function(path)
		local names = { "infra.config_paths", "infra.metrics_preferences", "modules.keylogger.keylogger",
			"adapters.storage", "ui.wpm.widget", "ui.wpm.tray_readout" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function(name)
				helpers.assert_eq(name, "config.toml")
				return path
			end }
			package.loaded["infra.metrics_preferences"] = nil
			body(require("infra.metrics_preferences"), path)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("canonical metrics preferences", function()
	helpers.it("cleanup retains canonical metric choices and offers only unknown neighbors", function()
		with_config('[metrics]\nenabled = true\nwpm_widget_colors = false\nfuture = 42\n', function(_, path)
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "future")
		end)
	end)

	helpers.it("both WPM surfaces read canonical choices and persist their own leaves", function()
		with_config('[metrics]\nwpm_widget_colors = false\nwpm_menubar_colors = false\n', function(_, path)
			package.loaded["adapters.storage"] = require("tests.fakes").storage({ initial = {
				["wpm_widget.source_colors"] = true, ["wpm_menubar.colors"] = true,
				["wpm_widget.pos_x"] = 300, ["wpm_widget.pos_y"] = 400,
			} })
			for _, name in ipairs({ "ui.wpm.widget", "ui.wpm.tray_readout" }) do
				package.loaded[name] = nil
				local readout = require(name)
				helpers.assert_eq(readout.restore(), false)
				helpers.assert_eq(readout.uses_source_colors(), false)
				helpers.assert_true(readout.set_use_source_colors(true))
				package.loaded[name] = nil
				local restarted = require(name)
				restarted.restore()
				helpers.assert_eq(restarted.uses_source_colors(), true)
			end
			local metrics = Codec.decode(Sandbox.read_bytes(path)).metrics
			helpers.assert_eq(metrics.wpm_widget_colors, nil)
			helpers.assert_eq(metrics.wpm_menubar_colors, nil)
			helpers.assert_eq(package.loaded["adapters.storage"].get("wpm_widget.pos_x"), 300)
			helpers.assert_eq(package.loaded["adapters.storage"].get("wpm_widget.pos_y"), 400)
		end)
	end)

	helpers.it("collector reads canonical consent and never imports the legacy store", function()
		with_config('[metrics]\nenabled = true\nprivate_filter_enabled = false\n', function(_, path)
			package.loaded["adapters.storage"] = require("tests.fakes").storage({ initial = {
				["metrics.enabled"] = false, ["metrics.private_filter_enabled"] = true,
			} })
			package.loaded["modules.keylogger.keylogger"] = nil
			local collector = require("modules.keylogger.keylogger")
			collector.init({ sqlite_path = path .. ".sqlite", log_dir = path .. ".logs" })
			helpers.assert_eq(collector.is_enabled(), true)
			helpers.assert_eq(collector.get_privacy_state().private_filter_enabled, false)
			helpers.assert_true(collector.set_enabled(false))
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).metrics.enabled, nil)
		end)
	end)

	helpers.it("reads exact canonical choices and manifest defaults without rewriting", function()
		local source = '[metrics]\nenabled = true\nprivate_filter_enabled = false\nunknown = "keep"\n'
		with_config(source, function(preferences, path)
			helpers.assert_eq(preferences.get("metrics.enabled"), true)
			helpers.assert_eq(preferences.get("metrics.private_filter_enabled"), false)
			helpers.assert_eq(preferences.get("metrics.wpm_widget_visible"),
				require("infra.manifest_reader").default_for("metrics.wpm_widget_visible"))
			helpers.assert_eq(Sandbox.read_bytes(path), source)
		end)
	end)

	helpers.it("writes sparse choices through the real TOML owner and preserves neighbors", function()
		with_config('[metrics]\nunknown = "keep"\n[other]\nvalue = 9\n', function(preferences, path)
			helpers.assert_true(preferences.set("metrics.enabled", true))
			local config = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(config.metrics.enabled, true)
			helpers.assert_eq(config.metrics.unknown, "keep")
			helpers.assert_eq(config.other.value, 9)
			package.loaded["infra.metrics_preferences"] = nil
			local restarted = require("infra.metrics_preferences")
			helpers.assert_eq(restarted.get("metrics.enabled"), true)
			helpers.assert_true(restarted.set("metrics.enabled", false))
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).metrics.enabled, nil)
		end)
	end)

	helpers.it("refuses a malformed source without overwriting it", function()
		local source = '[metrics\n'
		with_config(source, function(preferences, path)
			local accepted = pcall(preferences.get, "metrics.enabled")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(preferences.set("metrics.enabled", true), false)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
		end)
	end)

	helpers.it("reads an old-shape boolean as neutral and offers it for cleanup (config-outdated-metrics)", function()
		-- One wrong-typed leaf used to refuse every read, write and scope of the
		-- domain, and made the cleanup report the whole file as unreadable.
		local source = '[metrics]\nenabled = "true"\nwpm_widget_colors = false\n'
		with_config(source, function(preferences, path)
			helpers.assert_eq(preferences.get("metrics.enabled"), false, "never read as consent")
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "metrics", "enabled" })
			helpers.assert_true(preferences.set("metrics.enabled", true), "a new choice replaces the old shape")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).metrics.enabled, true)
		end)
	end)

	helpers.it("refuses unknown ownership and nonboolean values", function()
		with_config('', function(preferences, path)
			helpers.assert_eq(preferences.set("metrics.future", true), false)
			helpers.assert_eq(preferences.set("gestures.enabled", true), false)
			helpers.assert_eq(preferences.set("metrics.enabled", "true"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), '')
		end)
	end)
end)
