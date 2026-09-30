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
			controls.files = files
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
	helpers.it("clears an outdated owned value instead of refusing (config-outdated-metrics)", function()
		-- An old-shape leaf is outdated configuration: the reset that removes
		-- it must never be refused because of it.
		with_scope(function(owner, collector, _, _, _, path)
			local malformed = '[metrics]\nenabled = "yes"\n'
			Sandbox.write_bytes(path, malformed)
			helpers.assert_eq(owner.apply("clear"), true)
			helpers.assert_true(not Sandbox.read_bytes(path):find('enabled = "yes"', 1, true),
				"the clear removes the outdated value")
			helpers.assert_eq(collector.is_enabled(), false)
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

helpers.describe("Linux metrics scope rendered commands", function()
	helpers.it("keeps the daemon menu pause provider live after context construction", function()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = file:read("*a")
		file:close()
		local context = source:match("local function _build_menu_ctx%(%)%s*(.-)on_toggle_pause%s*=")
		helpers.assert_not_nil(context, "the production context builder must be present")
		local expression = context:match("\n%s*is_paused%s*=%s*([^,\n]+)")
		helpers.assert_not_nil(expression, "the production context must pass a live pause provider")
		local paused = false
		local read = assert((loadstring or load)("local script_actions = ...; return " .. expression))
		local getter = read({ is_paused = function() return paused end })
		helpers.assert_eq(type(getter), "function", "the daemon must pass the getter rather than its snapshot")
		helpers.assert_eq(getter(), false)
		paused = true
		helpers.assert_eq(getter(), true)
	end)
	for _, scenario in ipairs({ "clear", "recommended", "cancel", "publication refusal", "pause before confirmation", "pause during confirmation" }) do
		helpers.it("routes " .. scenario .. " through the actual terminal owner", function()
			local loaded = {}
			for name, value in pairs(package.loaded) do loaded[name] = value end
			local ok, err = pcall(function()
				package.loaded["adapters.storage"] = {
					get = function(_, default) return default end,
					set = function() error("metrics scope must not write legacy storage") end,
				}
				with_scope(function(_, collector, widget, readout, controls, path)
					local renderer = require("infra.manifest_menu")
					local root = renderer.get_root()
					local old_rows, old_top = root.metrics_menu, root.top_level
					local execute = os.execute
					local old_files = package.loaded["adapters.file_system"]
					local backups, changed, questions, paused = {}, 0, 0, false
					local mode = scenario == "recommended" and "recommended" or "clear"
					local key = mode == "clear" and "common.clear_to_system" or "common.restore_recommended"
					local id = mode == "clear" and "scope_clear" or "scope_restore"
					local source = Sandbox.read_bytes(path)
					local passed, detail = pcall(function()
						root.metrics_menu = {{ type = "command", id = id, i18n = key }}
						root.top_level = {{ id = "metrics" }}
						controls.on_publish = function(target)
							if target ~= path then backups[#backups + 1] = target end
						end
						if scenario == "publication refusal" then controls.refuse = path end
						package.loaded["adapters.file_system"] = controls.files
						os.execute = function(command)
							if command:find("zenity --question", 1, true) then
								questions = questions + 1
								helpers.assert_contains(command, require("infra.i18n").get("menu.metrics.title"))
								if scenario == "pause during confirmation" then paused = true end
								return scenario == "cancel" and 1 or 0
							end
							if command:find("command -v zenity", 1, true) then return 0 end
							return execute(command)
						end
						package.loaded["ui.menu.menu_builder"] = nil
						local rows = require("ui.menu.menu_builder").build({ keylogger = collector,
							paused = false, is_paused = function() return paused end,
							on_menu_changed = function() changed = changed + 1 end })
						local action
						local function find(items)
							for _, row in ipairs(items) do
								if row.title == require("infra.i18n").get(key) then action = row.fn end
								if row.menu then find(row.menu) end
							end
						end
						find(rows)
						helpers.assert_eq(type(action), "function", "the real renderer must bind the scope command")
						if scenario == "pause before confirmation" then paused = true end
						action()
						local committed = scenario == "clear" or scenario == "recommended"
						helpers.assert_eq(changed, committed and 1 or 0)
						-- Only a clear asks; the restore applies at once
						-- (restore-recommended-no-confirm).
						local asks = mode == "clear" and scenario ~= "pause before confirmation"
						helpers.assert_eq(questions, asks and 1 or 0)
						if committed then
							helpers.assert_eq(#backups, 1)
							helpers.assert_eq(Sandbox.read_bytes(backups[1]), source)
							helpers.assert_eq(collector.is_enabled(), mode == "recommended")
							if mode == "clear" then
								helpers.assert_eq(widget.is_running(), false)
								helpers.assert_eq(readout.is_running(), false)
							end
							local result = Codec.decode(Sandbox.read_bytes(path))
							helpers.assert_eq(result.metrics.unknown, "keep")
							helpers.assert_eq(result.other.value, 42)
						else
							helpers.assert_eq(#backups, scenario == "publication refusal" and 1 or 0)
							helpers.assert_eq(Sandbox.read_bytes(path), source)
							helpers.assert_true(collector.is_enabled())
							helpers.assert_true(widget.is_running())
							helpers.assert_true(readout.is_running())
						end
					end)
					root.metrics_menu, root.top_level, os.execute = old_rows, old_top, execute
					package.loaded["adapters.file_system"] = old_files
					for _, backup in ipairs(backups) do os.remove(backup) end
					if not passed then error(detail, 0) end
				end)
			end)
			for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
			for name, value in pairs(loaded) do package.loaded[name] = value end
			if not ok then error(err, 0) end
		end)
	end
end)

helpers.describe("Linux metrics scope revert", function()
	helpers.it("reverts a committed clear to the exact file and the running collector", function()
		with_scope(function(owner, collector, _, _, _, path, backup)
			helpers.assert_eq(owner.apply("clear"), true)
			helpers.assert_eq(collector.is_enabled(), false)
			local reverted, detail = owner.revert()
			helpers.assert_eq(reverted, true, detail)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(collector.is_enabled())
			helpers.assert_eq(owner.pending(), false)
			os.remove(backup)
			helpers.assert_eq(owner.apply("clear"), true, "the preference owner is released after a revert")
		end)
	end)
end)
