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
	-- The Metrics menu offers the restore alone since 2026-09-30 (the maintainer
	-- retired its clear); the owner's clear stays covered above and composed by
	-- the Configuration clear. No row asks a question.
	helpers.it("the real Metrics submenu opens with its switch and restore, and offers no clear", function()
		local loaded = {}
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local ok, err = pcall(function()
			package.loaded["adapters.storage"] = {
				get = function(_, default) return default end,
				set = function() error("metrics scope must not write legacy storage") end,
			}
			with_scope(function(_, collector)
				local i18n = require("infra.i18n")
				package.loaded["ui.menu.menu_builder"] = nil
				local passed, detail = pcall(function()
					local rows = require("ui.menu.menu_builder").build({ keylogger = collector,
						paused = false, is_paused = function() return false end })
					local submenu
					for _, row in ipairs(rows) do
						if row.menu and row.title:find(i18n.get("menu.metrics.title"), 1, true) then submenu = row.menu end
					end
					helpers.assert_true(type(submenu) == "table", "the real Metrics submenu must exist")
					helpers.assert_eq(table.concat({ submenu[1].title, submenu[2].title, submenu[3].title }, " | "),
						table.concat({ i18n.get("menu.metrics.enable"), i18n.get("common.restore_recommended"), "-" }, " | "))
					helpers.assert_eq(type(submenu[2].fn), "function")
					for _, row in ipairs(submenu) do
						helpers.assert_true(row.title ~= i18n.get("common.clear_to_system"), "the Metrics clear is retired")
					end
				end)
				if not passed then error(detail, 0) end
			end)
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		if not ok then error(err, 0) end
	end)
	for _, scenario in ipairs({ "recommended", "publication refusal", "pause before the click" }) do
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
					local mode = "recommended"
					local key, id = "common.restore_recommended", "scope_restore"
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
							if command:find("zenity", 1, true) then
								questions = questions + 1
								return 0
							end
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
						if scenario == "pause before the click" then paused = true end
						action()
						local committed = scenario == "recommended"
						helpers.assert_eq(changed, committed and 1 or 0)
						helpers.assert_eq(questions, 0, "the restore applies at once (restore-recommended-no-confirm)")
						if committed then
							helpers.assert_eq(#backups, 1)
							helpers.assert_eq(Sandbox.read_bytes(backups[1]), source)
							helpers.assert_eq(collector.is_enabled(), mode == "recommended")
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


helpers.describe("metrics private native claim", function()
	helpers.it("releases the actual preference primitive without hiding public pending", function()
		with_scope(function(_, _, _, _, controls, path, backup)
			local Preferences = require("infra.metrics_preferences")
			local public, claim, primary = {}, {}, nil
			local runtime = "original"
			claim.pending = function() return primary.pending() end
			primary = require("config_scope_transaction").new({ path = path, backup_path = backup,
				files = controls.files, manifest = require("infra.manifest_reader"),
				capture = function() return { marker = runtime } end,
				apply = function() runtime = "candidate"; return true end,
				restore = function(snapshot) runtime = snapshot.marker; return true end })
			local releases = 0
			local owner = require("config_scope_fenced_transaction").new({ owner = public, native_token = claim,
				transaction = primary, scope = "metrics", available = function() return true end,
				fences = { { acquire = Preferences.acquire, release = function(token)
					helpers.assert_eq(token, claim)
					helpers.assert_eq(public.pending(), true)
					helpers.assert_eq(token.pending(), false)
					releases = releases + 1
					return Preferences.release(token)
				end } } })
			helpers.assert_eq(owner.apply("clear"), true)
			helpers.assert_eq(Preferences.admit(), true)
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(owner.revert(), true)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(runtime, "original")
			helpers.assert_eq(releases, 2)
			helpers.assert_eq(Preferences.admit(), true)
		end)
	end)
end)

helpers.describe("metrics retained native release debt", function()
	local expected = { metrics = { enabled = true, private_filter_enabled = false,
		wpm_widget_visible = true, wpm_menubar_visible = true, unknown = "keep" }, other = { value = 42 } }
	local receipts = {
		{ name = "nil", reply = function() return nil end },
		{ name = "false", reply = function() return false end },
		{ name = "truthy string", reply = function() return "true" end },
		{ name = "wrong object", reply = function() return {} end },
		{ name = "exception", reply = function() error("native metrics release refused") end },
	}
	local function controlled_scope(collector, widget, readout, controls, path, refusal)
		local Preferences = require("infra.metrics_preferences")
		local acquire, release = Preferences.acquire, Preferences.release
		local blocked, live, scope = true, nil, nil
		Preferences.acquire = function(token)
			local accepted = acquire(token)
			if accepted == true then helpers.assert_nil(live, "an acknowledged claim is acquired once"); live = token end
			return accepted
		end
		Preferences.release = function(token)
			helpers.assert_eq(live, token, "only the exact native claim can release")
			if blocked then return refusal() end
			helpers.assert_eq(scope.pending(), true, "public ownership remains pending during release")
			helpers.assert_eq(token.pending(), false, "native release sees only settled primary compensation")
			local accepted = release(token)
			if accepted == true then live = nil end
			return accepted
		end
		scope = require("infra.metrics_scope").new({ path = path, backup_path = path .. ".scope-backup",
			collector = collector, widget = widget, readout = readout, files = controls.files })
		return scope, function(value) blocked = value == true end, function() return live end
	end
	local function restored(collector, widget, readout, controls, path, claim)
		helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected, "complete handwritten source model")
		helpers.assert_eq(collector.is_enabled(), true)
		helpers.assert_eq(collector.configuration_snapshot().private_filter_enabled, false)
		helpers.assert_eq(widget.is_running(), true)
		helpers.assert_eq(readout.is_running(), true)
		helpers.assert_eq(controls.migrations, 0, "preference compensation cannot start history conversion")
		helpers.assert_nil(claim())
		helpers.assert_eq(require("infra.metrics_preferences").admit(), true)
	end
	for _, mode in ipairs({ "clear", "recommended" }) do
		for _, receipt in ipairs(receipts) do
			helpers.it("compensates " .. mode .. " native runtime and source on " .. receipt.name .. " release", function()
				with_scope(function(_, collector, widget, readout, controls, path)
					local scope, unblock, claim = controlled_scope(collector, widget, readout, controls, path, receipt.reply)
					helpers.assert_eq(scope.apply(mode), false)
					helpers.assert_eq(scope.pending(), true)
					helpers.assert_eq(scope.release(), false)
					helpers.assert_eq(scope.apply("clear"), false)
					helpers.assert_eq(collector.set_enabled(false), false, "ordinary writes cannot replace retained debt")
					unblock()
					helpers.assert_eq(scope.retry_restore(), true)
					helpers.assert_eq(scope.pending(), false)
					restored(collector, widget, readout, controls, path, claim)
				end)
			end)
		end
	end
	helpers.it("preserves an external successor under the exact retained native inverse", function()
		with_scope(function(_, collector, widget, readout, controls, path)
			local scope, unblock, claim = controlled_scope(collector, widget, readout, controls, path, function() return false end)
			local publish, writes, candidate = controls.files.write_if_unchanged, 0, nil
			local foreign = '[external]\nowner = "later"\n'
			controls.files.write_if_unchanged = function(target, content, expected_source)
				if target == path then writes = writes + 1; if writes == 2 then Sandbox.write_bytes(path, foreign) end end
				local ok, detail = publish(target, content, expected_source)
				if target == path and writes == 1 and ok == true then candidate = Sandbox.read_bytes(path) end
				return ok, detail
			end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_eq(require("infra.metrics_preferences").admit(), false)
			Sandbox.write_bytes(path, candidate) -- Explicit fixture repair of the retained candidate generation.
			helpers.assert_eq(scope.retry_restore(), true)
			restored(collector, widget, readout, controls, path, claim)
		end)
	end)
	helpers.it("settles release-only debt after an acknowledged explicit inverse", function()
		with_scope(function(_, collector, widget, readout, controls, path)
			local scope, block, claim = controlled_scope(collector, widget, readout, controls, path, function() return false end)
			block(false)
			helpers.assert_eq(scope.apply("recommended"), true)
			block(true)
			helpers.assert_eq(scope.revert(), false)
			helpers.assert_eq(scope.pending(), true)
			local apply, replay = collector.apply_configuration, 0
			collector.apply_configuration = function(...) replay = replay + 1; return apply(...) end
			block(false)
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(replay, 0, "an acknowledged native inverse is not replayed")
			restored(collector, widget, readout, controls, path, claim)
		end)
	end)
	helpers.it("halts the actual global composition before a later participant on native debt", function()
		with_scope(function(_, collector, widget, readout, controls, path)
			local scope, unblock, claim = controlled_scope(collector, widget, readout, controls, path, function() return false end)
			local trace = {}
			local before = { apply = function(_, done) trace[#trace + 1] = "before.apply"; done(true) end,
				revert = function(done) trace[#trace + 1] = "before.revert"; done(true) end,
				release = function() end, pending = function() return false end, retry_restore = function(done) done(true) end }
			local after = { apply = function(_, done) trace[#trace + 1] = "after.apply"; done(true) end,
				revert = function(done) done(true) end, release = function() end,
				pending = function() return false end, retry_restore = function(done) done(true) end }
			local actual = require("config_scope_participant").synchronous({ apply = scope.apply, owner = function() return scope end })
			local logger = {}; for _, name in ipairs({ "start", "success", "warn", "info", "error" }) do logger[name] = function() end end
			local global = require("config_scope_composition").new({ manifest = require("infra.manifest_reader"), scope = "global",
				logger = logger, participants = function() return { tap_holds = before, metrics = { actual, after } } end })
			local verdict, report
			global.apply("recommended", function(ok, detail) verdict, report = ok, detail end)
			helpers.assert_eq(verdict, false)
			helpers.assert_eq(report.failed, "metrics")
			helpers.assert_eq(global.pending(), true)
			helpers.assert_eq(trace, { "before.apply" })
			unblock()
			local settled
			global.retry_restore(function(ok) settled = ok end)
			helpers.assert_eq(settled, true)
			helpers.assert_eq(trace, { "before.apply", "before.revert" })
			helpers.assert_eq(global.pending(), false)
			restored(collector, widget, readout, controls, path, claim)
		end)
	end)
end)
