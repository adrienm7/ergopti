--- tests/unit/infra/test_llm_scope.lua

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local SOURCE = '[llm]\nenabled = true\nunknown = "keep"\n[llm.generation]\ntemperature = 0.9\n'
	.. '[llm.trigger]\nsecure_filter_enabled = false\nurl_bar_filter_enabled = false\ndebounce_ms = 600\n'
	.. '[llm.models]\nollama = "private-model"\n[llm.profiles]\nnum_predictions = 1\n'
	.. '[llm.display]\nstreaming = true\n'
	.. '[api_credentials]\ntoken = "untouched"\n[foreign]\nvalue = 42\n'

local function with_scope(body)
	Sandbox.with_config(SOURCE, function(path)
		local loaded_before = {}
		for name, value in pairs(package.loaded) do loaded_before[name] = value end
		local names = { "infra.config_paths", "infra.llm_preferences", "infra.llm_scope",
			"adapters.http_client", "adapters.secure_field_detector", "ui.tooltip.llm",
			"adapters.storage", "modules.hotstrings.magic_key" }
		for _, name in ipairs({ "settings", "trigger_settings", "display_settings", "navigation_settings",
			"profile_settings", "profiles", "prediction_engine", "api_ollama", "api_remote" }) do
			names[#names + 1] = "modules.llm." .. name
		end
		local previous, controls = {}, { requests = 0, stops = 0, timers = {} }
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local backup = path .. ".scope-backup"
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end,
				config_home = function() return path .. ".home" end }
			package.loaded["adapters.secure_field_detector"] = { isSecureField = function() return false end,
				isUrlBar = function() return false end }
			package.loaded["adapters.http_client"] = {
				postStream = function(_, _, _, _, chunk, done)
					controls.requests = controls.requests + 1
					controls.chunk, controls.done, controls.active = chunk, done, true
					return true
				end,
				cancel = function()
					controls.stops = controls.stops + 1
					if controls.stop_refused then return false end
					controls.active = false
					return true
				end,
			}
			require("tests.support.owned_http_fixture").attach(package.loaded["adapters.http_client"])
			local overlay = require("ui.tooltip.llm")
			overlay.init({ style = {}, renderer = {
				show = function() controls.visible = true; return true end,
				hide = function()
					if controls.hide_refused then return false end
					controls.visible = false
					return true
				end,
			} })
			local scheduler = {
				after = function(_, callback)
					local handle = { armed = true, callback = callback }
					controls.timers[#controls.timers + 1] = handle
					return handle
				end,
				cancel = function(handle)
					if controls.timer_refused then return false end
					handle.armed = false
					return true
				end,
			}
			local engine = require("modules.llm.prediction_engine")
			engine.init({ overlay = overlay, scheduler = scheduler, engine = {
				current_buffer = function() return "Hello world" end,
			} })
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional write") end,
				write_if_unchanged = function(target, content, expected)
					if controls.on_publish then controls.on_publish(target) end
					if controls.refuse == target then return false, "injected refusal" end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			local owner = require("infra.llm_scope").new({ path = path, backup_path = backup, files = files })
			body(owner, engine, controls, path, backup)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		-- The real tray builder imports sibling modules that retain storage ports.
		-- None may escape with a reference to this private configuration fixture.
		for name in pairs(package.loaded) do if loaded_before[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded_before) do package.loaded[name] = value end
		os.remove(backup)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Linux terminal LLM scope", function()
	helpers.it("clears an outdated owned value instead of refusing (config-outdated-llm)", function()
		-- One old-shape AI leaf made every AI preference read raise, so the
		-- reset that would remove it was refused because of it.
		with_scope(function(owner, _, _, path)
			local malformed = '[llm]\nenabled = "wrong"\n'
			Sandbox.write_bytes(path, malformed)
			helpers.assert_eq(owner.apply("clear"), true)
			helpers.assert_true(not Sandbox.read_bytes(path):find('enabled = "wrong"', 1, true),
				"the clear removes the outdated value")
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	helpers.it("preserves an occupied backup and the existing preference posture", function()
		with_scope(function(owner, engine, _, path, backup)
			Sandbox.write_bytes(backup, "reserved")
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(backup), "reserved")
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(engine.is_enabled())
		end)
	end)

	helpers.it("clears consumed settings and runtime without touching credentials or unknown neighbors", function()
		with_scope(function(owner, engine, _, path, backup)
			local settings = require("modules.llm.settings")
			helpers.assert_eq(settings.get("temperature"), 0.9)
			helpers.assert_true(owner.apply("clear"))
			helpers.assert_eq(Sandbox.read_bytes(backup), SOURCE)
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(require("modules.llm.profiles").is_enabled(), false)
			helpers.assert_eq(settings.get("temperature"), require("infra.manifest_reader").default_for("llm.generation.temperature"))
			local document = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(document.llm.enabled, nil)
			helpers.assert_eq(document.llm.unknown, "keep")
			helpers.assert_eq(document.api_credentials.token, "untouched")
			helpers.assert_eq(document.foreign.value, 42)
		end)
	end)

	helpers.it("restores recommendations while preserving an existing explicit consent", function()
		with_scope(function(owner, engine, _, path)
			helpers.assert_true(owner.apply("recommended"))
			helpers.assert_true(engine.is_enabled())
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).llm.enabled, true)
		end)
	end)

	helpers.it("does not grant consent while restoring recommendations", function()
		with_scope(function(owner, engine, _, path)
			helpers.assert_true(engine.disable())
			helpers.assert_true(owner.apply("recommended"))
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).llm.enabled, nil)
		end)
	end)

	helpers.it("cancels the actual backend before publication and never resends a paid prompt on rollback", function()
		with_scope(function(owner, engine, controls, path)
			helpers.assert_true(engine.trigger_now())
			helpers.assert_eq(controls.requests, 1)
			controls.refuse = path
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(controls.active, false)
			helpers.assert_eq(controls.requests, 1)
			helpers.assert_true(engine.is_enabled())
			helpers.assert_eq(require("modules.llm.profiles").get_current_model(), "private-model")
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
		end)
	end)

	helpers.it("retains a refused transport and fences ordinary mutation until explicit recovery", function()
		with_scope(function(owner, engine, controls, path, backup)
			helpers.assert_true(engine.trigger_now())
			controls.stop_refused = true
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_true(owner.pending())
			helpers.assert_true(controls.active)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			local _, status = Writer.read_classified(backup)
			helpers.assert_eq(status, "absent")
			helpers.assert_eq(engine.trigger_now(), false)
			helpers.assert_eq(engine.set_backend("api"), false)
			helpers.assert_eq(require("modules.llm.settings").set("temperature", 0.6), false)
			controls.chunk('{"message":{"content":" sunshine today everywhere around the world"}}\n')
			helpers.assert_eq(require("ui.tooltip.llm").is_showing(), false,
				"late transport chunks cannot publish an offer while cancellation is pending")
			controls.stop_refused = false
			helpers.assert_true(owner.retry_restore())
			helpers.assert_eq(controls.active, false)
			helpers.assert_eq(controls.requests, 1)
			helpers.assert_true(require("modules.llm.settings").set("temperature", 0.6))
		end)
	end)

	helpers.it("presents the same transport chunk while ordinary admission is open", function()
		with_scope(function(_, engine, controls)
			helpers.assert_true(engine.trigger_now())
			controls.chunk('{"message":{"content":" sunshine today everywhere around the world"}}\n')
			helpers.assert_true(require("ui.tooltip.llm").is_showing(), "positive control for the late-chunk rejection")
		end)
	end)

	helpers.it("retains refused timer cancellation and blocks its callback from starting a request", function()
		with_scope(function(owner, engine, controls, path)
			engine.on_char("d", "Hello world", {})
			helpers.assert_eq(#controls.timers, 1)
			controls.timer_refused = true
			helpers.assert_eq(owner.apply("clear"), false)
			controls.timers[1].callback()
			helpers.assert_eq(controls.requests, 0)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			controls.timer_refused = false
			helpers.assert_true(owner.retry_restore())
			helpers.assert_eq(controls.timers[1].armed, false, "retry still owns the refused native timer")
		end)
	end)

	helpers.it("keeps a native hide refusal pending without discarding its offer", function()
		with_scope(function(owner, _, controls, path)
			local overlay = require("ui.tooltip.llm")
			helpers.assert_true(overlay.show({{ to_type = "word" }}, {}))
			controls.hide_refused = true
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_true(overlay.is_showing())
			helpers.assert_true(owner.pending())
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			controls.hide_refused = false
			helpers.assert_true(owner.retry_restore())
		end)
	end)

	helpers.it("restores exact cached state when conditional publication detects a concurrent edit", function()
		with_scope(function(owner, engine, controls, path)
			local settings = require("modules.llm.settings")
			helpers.assert_eq(settings.get("temperature"), 0.9)
			controls.on_publish = function(target)
				if target == path then Sandbox.write_bytes(path, SOURCE .. '\n[external]\nvalue = 9\n') end
			end
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_true(engine.is_enabled())
			helpers.assert_eq(settings.get("temperature"), 0.9)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).external.value, 9)
		end)
	end)

	helpers.it("retains failed compensation and refuses sibling writes until native recovery", function()
		with_scope(function(owner, engine, controls, path)
			controls.refuse = path
			controls.on_publish = function(target) if target == path then controls.hide_refused = true end end
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_true(owner.pending())
			helpers.assert_eq(engine.enable(), false)
			controls.hide_refused = false
			helpers.assert_true(owner.retry_restore())
			helpers.assert_true(engine.is_enabled())
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
		end)
	end)

	-- The AI menu offers the restore alone: its clear row was retired
	-- (ai-menu-no-clear, test_llm_menu_toggle_row.lua).
	helpers.it("dispatches the real rendered restore command into the terminal owner", function()
		with_scope(function(owner, engine, _, path)
			local renderer = require("infra.manifest_menu")
			local root = renderer.get_root()
			local old_rows = root.llm_menu
			local old_top = root.top_level
			local old_builder = package.loaded["ui.menu.menu_builder"]
			local execute = os.execute
			local scope = require("infra.llm_scope")
			local old_apply = scope.apply
			local key = "common.restore_recommended"
			local changed, questions = 0, 0
			local ok, err = pcall(function()
				-- Pending common declarations stay private to this renderer test.
				root.llm_menu = {{ type = "command", id = "scope_restore", i18n = key }}
				root.top_level = {{ id = "llm" }}
				os.execute = function(command)
					if command:find("zenity --question", 1, true) then
						questions = questions + 1
						helpers.assert_contains(command, require("infra.i18n").get("menu.llm.title"))
						return 0
					end
					if command:find("command -v zenity", 1, true) then return 0 end
					return execute(command)
				end
				scope.apply = function(selected) return owner.apply(selected) end
				package.loaded["ui.menu.menu_builder"] = nil
				local rows = require("ui.menu.menu_builder").build({ llm = engine,
					on_menu_changed = function() changed = changed + 1 end })
				local action
				local function find(items)
					for _, row in ipairs(items) do
						if row.title == require("infra.i18n").get(key) then action = row.fn end
						if row.menu then find(row.menu) end
					end
				end
				local llm_label = require("infra.i18n").get("menu.llm.title")
				for _, row in ipairs(rows) do
					if row.menu and row.title:find(llm_label, 1, true) then find(row.menu) end
				end
				helpers.assert_eq(type(action), "function")
				action()
				helpers.assert_eq(changed, 1)
				-- A restore never asks (restore-recommended-no-confirm).
				helpers.assert_eq(questions, 0)
				helpers.assert_eq(engine.is_enabled(), true)
				helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).llm.unknown, "keep")
			end)
			root.llm_menu, root.top_level, scope.apply, os.execute = old_rows, old_top, old_apply, execute
			package.loaded["ui.menu.menu_builder"] = old_builder
			if not ok then error(err, 0) end
		end)
	end)
end)

helpers.describe("Linux terminal LLM scope revert", function()
	helpers.it("reverts a committed clear to the exact file and the enabled engine", function()
		with_scope(function(owner, engine, _, path, backup)
			helpers.assert_true(owner.apply("clear"))
			helpers.assert_eq(engine.is_enabled(), false)
			local reverted, detail = owner.revert()
			helpers.assert_eq(reverted, true, detail)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(engine.is_enabled())
			helpers.assert_eq(require("modules.llm.settings").get("temperature"), 0.9)
			helpers.assert_eq(owner.pending(), false)
			os.remove(backup)
			helpers.assert_true(owner.apply("clear"), "the AI ownership is released after a revert")
		end)
	end)
end)
