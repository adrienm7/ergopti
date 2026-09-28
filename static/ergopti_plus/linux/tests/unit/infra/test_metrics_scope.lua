--- tests/unit/infra/test_metrics_scope.lua

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

local SOURCE = '[metrics]\nenabled = true\nprivate_filter_enabled = false\nwpm_widget_visible = true\nwpm_menubar_visible = true\nunknown = "keep"\n[other]\nvalue = 42\n'

local function with_scope(body)
	Sandbox.with_config(SOURCE, function(path)
		local names = { "infra.config_paths", "infra.metrics_preferences", "infra.metrics_scope",
			"modules.keylogger.keylogger", "modules.keylogger.text_cipher", "modules.keylogger.text_migration",
			"ui.wpm.widget", "ui.wpm.tray_readout" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local controls = { cipher = false, migrations = 0, backups = {} }
		local backup = path .. ".scope-backup"
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["modules.keylogger.text_cipher"] = {
				is_enabled = function() return controls.cipher end, is_available = function() return true end,
				set_enabled = function(value) controls.cipher = value; return true end,
			}
			package.loaded["modules.keylogger.text_migration"] = {
				is_running = function() return controls.migrating == true end,
				start = function() controls.migrations = controls.migrations + 1 end,
			}
			local collector = require("modules.keylogger.keylogger")
			local widget, readout = require("ui.wpm.widget"), require("ui.wpm.tray_readout")
			local surface = { hide = function() if controls.hide then return controls.hide() end; return true end }
			widget._set_surface(surface)
			helpers.assert_true(collector.set_enabled(true))
			helpers.assert_true(collector.set_private_filter_enabled(false))
			helpers.assert_true(widget.start())
			helpers.assert_true(readout.start())
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional publication") end,
				write_if_unchanged = function(target, content, expected)
					if controls.on_publish then controls.on_publish(target) end
					if controls.refuse == target then return false, "injected refusal" end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			local owner = require("infra.metrics_scope").new({ path = path, backup_path = backup,
				collector = collector, widget = widget, readout = readout, files = files })
			body(owner, collector, widget, readout, controls, path, backup)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		os.remove(backup)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Linux metrics scope transaction", function()
	helpers.it("rejects malformed owned source values before creating a backup", function()
		with_scope(function(owner, collector, _, _, _, path, backup)
			local malformed = '[metrics]\nenabled = "yes"\n'
			Sandbox.write_bytes(path, malformed)
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), malformed)
			helpers.assert_true(collector.is_enabled())
			local _, status = Writer.read_classified(backup)
			helpers.assert_eq(status, "absent")
		end)
	end)

	helpers.it("preserves a preexisting backup and refuses before changing runtime", function()
		with_scope(function(owner, collector, _, _, _, path, backup)
			local before = Sandbox.read_bytes(path)
			Sandbox.write_bytes(backup, "reserved backup")
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(Sandbox.read_bytes(backup), "reserved backup")
			helpers.assert_true(collector.is_enabled())
		end)
	end)

	helpers.it("preserves concurrent external edits and restores exact native state", function()
		with_scope(function(owner, collector, widget, readout, controls, path)
			local external = '[metrics]\nenabled = true\n[foreign]\nvalue = 17\n'
			controls.on_publish = function(target)
				if target == path then Sandbox.write_bytes(path, external) end
			end
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), external)
			helpers.assert_true(collector.is_enabled())
			helpers.assert_true(widget.is_running())
			helpers.assert_true(readout.is_running())
		end)
	end)

	helpers.it("clears all owned preferences with an exact backup and preserves unknown neighbors", function()
		with_scope(function(owner, collector, widget, readout, controls, path, backup)
			local before = Sandbox.read_bytes(path)
			helpers.assert_true(owner.apply("clear"))
			helpers.assert_eq(Sandbox.read_bytes(backup), before)
			helpers.assert_eq(collector.is_enabled(), false)
			helpers.assert_eq(widget.is_running(), false)
			helpers.assert_eq(readout.is_running(), false)
			local result = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(result.metrics.enabled, nil)
			helpers.assert_eq(result.metrics.unknown, "keep")
			helpers.assert_eq(result.other.value, 42)
			helpers.assert_eq(controls.migrations, 0)
		end)
	end)

	helpers.it("restores recommendations without granting collector consent", function()
		with_scope(function(owner, collector, _, _, controls, path)
			helpers.assert_true(collector.set_enabled(false))
			helpers.assert_true(owner.apply("recommended"))
			helpers.assert_eq(collector.is_enabled(), false)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).metrics.enabled, nil)
			helpers.assert_eq(controls.migrations, 0)
		end)
	end)

	helpers.it("restores actual runtime after a refused publication without changing source", function()
		with_scope(function(owner, collector, widget, readout, controls, path)
			local before = Sandbox.read_bytes(path)
			controls.refuse = path
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_true(collector.is_enabled())
			helpers.assert_true(widget.is_running())
			helpers.assert_true(readout.is_running())
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	helpers.it("retains refused compensation and fences sibling mutations until recovery", function()
		with_scope(function(owner, collector, widget, _, controls, path)
			controls.refuse = path
			controls.on_publish = function(target)
				if target == path then controls.hide = function() return false end end
			end
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_true(owner.pending())
			controls.refuse, controls.on_publish = nil, nil
			helpers.assert_eq(collector.set_enabled(false), false)
			helpers.assert_eq(widget.set_graph(true), false)
			helpers.assert_eq(widget.restore(), false)
			controls.hide = nil
			helpers.assert_true(owner.retry_restore())
			helpers.assert_true(collector.set_enabled(false))
		end)
	end)

	helpers.it("refuses an active historical conversion before creating the backup", function()
		with_scope(function(owner, _, _, _, controls, path, backup)
			local before = Sandbox.read_bytes(path)
			controls.migrating = true
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			local _, status = Writer.read_classified(backup)
			helpers.assert_eq(status, "absent")
		end)
	end)
end)
