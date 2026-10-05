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


helpers.describe("LLM private native claims", function()
	helpers.it("releases actual preference and quiescent engine primitives while public pending remains true", function()
		with_scope(function(_, engine, controls, path, backup)
			local Preferences = require("infra.llm_preferences")
			local public, claim, primary = {}, {}, nil
			claim.pending = function() return primary.pending() end
			primary = require("config_scope_transaction").new({ path = path, backup_path = backup,
				files = { read_with_status = function(target) return Writer.read_classified(target) end,
					write = function() error("unconditional publication") end,
					write_if_unchanged = function(target, content, expected)
						return Writer.publish_if_unchanged(target, content, nil, expected)
					end }, manifest = require("infra.manifest_reader"),
				capture = function()
					helpers.assert_eq(engine.quiesce_configuration(claim), true)
					return engine.configuration_snapshot(claim)
				end,
				apply = function() return engine.apply_configuration(claim, { enabled = false }) end,
				restore = function(snapshot) return engine.apply_configuration(claim, snapshot) end })
			local releases = {}
			local function native_release(name, port)
				return function(token)
					helpers.assert_eq(token, claim)
					helpers.assert_eq(public.pending(), true)
					helpers.assert_eq(claim.pending(), false)
					releases[#releases + 1] = name
					return port(token)
				end
			end
			local owner = require("config_scope_fenced_transaction").new({ owner = public, native_token = claim,
				transaction = primary, scope = "llm", available = function() return true end,
				fences = { { acquire = Preferences.acquire, release = native_release("preferences", Preferences.release) },
					{ acquire = engine.acquire_configuration, release = native_release("engine", engine.release_configuration) } } })
			helpers.assert_eq(owner.apply("clear"), true)
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(Preferences.admit(), true)
			helpers.assert_eq(owner.revert(), true)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(engine.is_enabled(), true)
			helpers.assert_eq(releases, { "engine", "preferences", "engine", "preferences" })
			helpers.assert_eq(controls.requests, 0)
			helpers.assert_eq(owner.pending(), false)
		end)
	end)
end)

helpers.describe("LLM retained native release and stop debt", function()
	local expected = { llm = { enabled = true, unknown = "keep", generation = { temperature = 0.9 },
		trigger = { secure_filter_enabled = false, url_bar_filter_enabled = false, debounce_ms = 600 },
		models = { ollama = "private-model" }, profiles = { num_predictions = 1 }, display = { streaming = true } },
		api_credentials = { token = "untouched" }, foreign = { value = 42 } }
	local receipts = {
		{ name = "nil", reply = function() return nil end },
		{ name = "false", reply = function() return false end },
		{ name = "truthy string", reply = function() return "true" end },
		{ name = "wrong object", reply = function() return {} end },
		{ name = "exception", reply = function() error("native AI release refused") end },
	}
	local function controlled_scope(engine, controls, path, selected, refusal)
		local Preferences = require("infra.llm_preferences")
		local blocked, live, acknowledged, faults, scope = true, {}, {}, {}, nil
		for _, entry in ipairs({ { "preferences", Preferences, "acquire", "release" },
			{ "engine", engine, "acquire_configuration", "release_configuration" } }) do
			local name, native = entry[1], entry[2]
			local acquire, release = native[entry[3]], native[entry[4]]
			native[entry[3]] = function(token)
				if faults.acquire == name or (faults.reacquire == name and acknowledged[name]) then return false end
				local accepted = acquire(token)
				if accepted == true then helpers.assert_nil(live[name], "a live claim is not reacquired"); live[name] = token end
				return accepted
			end
			native[entry[4]] = function(token)
				helpers.assert_eq(live[name], token, "only the exact live native claim can release")
				if selected == name and blocked then return refusal() end
				helpers.assert_eq(scope.pending(), true, "public ownership remains pending until native acknowledgement")
				helpers.assert_eq(token.pending(), false, "native token retains only primary and stop debt")
				local accepted = release(token)
				if accepted == true then live[name] = nil; acknowledged[name] = (acknowledged[name] or 0) + 1 end
				return accepted
			end
		end
		local files = { read_with_status = function(target) return Writer.read_classified(target) end,
			write = function() error("unconditional AI scope publication") end,
			write_if_unchanged = function(target, content, source)
				if faults.on_publish then faults.on_publish(target) end
				return Writer.publish_if_unchanged(target, content, nil, source)
			end }
		faults.files = files
		scope = require("infra.llm_scope").new({ path = path, backup_path = path .. ".scope-backup", files = files, engine = engine })
		return scope, function(value) blocked = value == true end, live, faults
	end
	local function restored(engine, controls, path, live)
		helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected, "complete independent source model")
		helpers.assert_eq(engine.is_enabled(), true)
		helpers.assert_eq(require("modules.llm.settings").get("temperature"), 0.9)
		helpers.assert_eq(require("modules.llm.profiles").get_current_model(), "private-model")
		helpers.assert_eq(next(live), nil)
	end
	for _, mode in ipairs({ "clear", "recommended" }) do
		for _, selected in ipairs({ "preferences", "engine" }) do
			for _, receipt in ipairs(receipts) do
				helpers.it("compensates " .. mode .. " on " .. selected .. " " .. receipt.name .. " release", function()
					with_scope(function(_, engine, controls, path)
						helpers.assert_true(engine.trigger_now())
						local scope, unblock, live = controlled_scope(engine, controls, path, selected, receipt.reply)
						local called, committed = pcall(scope.apply, mode)
						helpers.assert_eq(called, true)
						helpers.assert_eq(committed, false)
						helpers.assert_eq(scope.pending(), true)
						helpers.assert_eq(scope.release(), false)
						helpers.assert_eq(scope.apply("clear"), false)
						helpers.assert_eq(engine.trigger_now(), false)
						helpers.assert_eq(require("modules.llm.settings").set("temperature", 0.6), false)
						unblock()
						helpers.assert_eq(scope.retry_restore(), true)
						helpers.assert_eq(scope.pending(), false)
						helpers.assert_eq(controls.requests, 1, "compensation cannot resend the paid prompt")
						helpers.assert_eq(controls.active, false)
						restored(engine, controls, path, live)
					end)
				end)
			end
		end
	end
	helpers.it("retains an acquired preference claim when engine acquisition and cleanup refuse", function()
		with_scope(function(_, engine, controls, path, backup)
			local scope, unblock, live, faults = controlled_scope(engine, controls, path, "preferences", function() return false end)
			faults.acquire = "engine"
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			local _, status = Writer.read_classified(backup)
			helpers.assert_eq(status, "absent", "no primary snapshot before both native claims")
			unblock()
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.requests, 0)
			restored(engine, controls, path, live)
		end)
	end)
	helpers.it("retains native stop debt through a later refused release without publishing preferences", function()
		with_scope(function(_, engine, controls, path, backup)
			helpers.assert_true(engine.trigger_now())
			local scope, unblock, live = controlled_scope(engine, controls, path, "engine", function() return false end)
			controls.stop_refused = true
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(controls.active, true)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			local _, status = Writer.read_classified(backup)
			helpers.assert_eq(status, "absent")
			controls.stop_refused = false
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(controls.active, false)
			helpers.assert_eq(scope.pending(), true, "stop acknowledgement does not drop release debt")
			unblock()
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.requests, 1)
			restored(engine, controls, path, live)
		end)
	end)
	helpers.it("retains the committed inverse through a native stop refusal on explicit revert", function()
		with_scope(function(_, engine, controls, path)
			local scope, block, live = controlled_scope(engine, controls, path, "engine", function() return false end)
			block(false)
			helpers.assert_eq(scope.apply("recommended"), true)
			local candidate = Sandbox.read_bytes(path)
			helpers.assert_true(engine.trigger_now())
			controls.stop_refused = true
			helpers.assert_eq(scope.revert(), false)
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), candidate)
			controls.stop_refused = false
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.requests, 1)
			restored(engine, controls, path, live)
		end)
	end)
	helpers.it("holds the candidate until a released engine claim can be reacquired for its inverse", function()
		with_scope(function(_, engine, controls, path)
			local scope, unblock, live, faults = controlled_scope(engine, controls, path, "preferences", function() return false end)
			faults.reacquire = "engine"
			helpers.assert_eq(scope.apply("clear"), false)
			local candidate = Sandbox.read_bytes(path)
			helpers.assert_true(candidate ~= SOURCE)
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), candidate)
			faults.reacquire = nil
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.requests, 0)
			restored(engine, controls, path, live)
		end)
	end)
	helpers.it("preserves an external source while native compensation remains exactly owned", function()
		with_scope(function(_, engine, controls, path)
			local scope, unblock, live, faults = controlled_scope(engine, controls, path, "engine", function() return false end)
			local publish, writes, candidate = faults.files.write_if_unchanged, 0, nil
			local foreign = '[external]\nowner = "later"\n'
			faults.files.write_if_unchanged = function(target, content, source)
				if target == path then writes = writes + 1; if writes == 2 then Sandbox.write_bytes(path, foreign) end end
				local ok, detail = publish(target, content, source)
				if target == path and writes == 1 and ok == true then candidate = Sandbox.read_bytes(path) end
				return ok, detail
			end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_eq(engine.trigger_now(), false)
			Sandbox.write_bytes(path, candidate) -- Explicit fixture repair of this journal's candidate generation.
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.requests, 0)
			restored(engine, controls, path, live)
		end)
	end)
	helpers.it("settles release-only debt after explicit inverse without repeating reader restore", function()
		with_scope(function(_, engine, controls, path)
			local scope, block, live = controlled_scope(engine, controls, path, "preferences", function() return false end)
			block(false)
			helpers.assert_eq(scope.apply("recommended"), true)
			block(true)
			helpers.assert_eq(scope.revert(), false)
			local settings = require("modules.llm.settings")
			local restore, replay = settings.restore_configuration, 0
			settings.restore_configuration = function(...) replay = replay + 1; return restore(...) end
			block(false)
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(replay, 0)
			restored(engine, controls, path, live)
		end)
	end)
	helpers.it("halts actual global progression before Metrics while AI release debt is retained", function()
		with_scope(function(_, engine, controls, path)
			local scope, unblock, live = controlled_scope(engine, controls, path, "engine", function() return false end)
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
				logger = logger, participants = function() return { hotstrings = before, llm = actual, metrics = after } end })
			local verdict, report
			global.apply("recommended", function(ok, detail) verdict, report = ok, detail end)
			helpers.assert_eq(verdict, false)
			helpers.assert_eq(report.failed, "llm")
			helpers.assert_eq(global.pending(), true)
			helpers.assert_eq(trace, { "before.apply" })
			unblock()
			local settled
			global.retry_restore(function(ok) settled = ok end)
			helpers.assert_eq(settled, true)
			helpers.assert_eq(trace, { "before.apply", "before.revert" })
			helpers.assert_eq(global.pending(), false)
			restored(engine, controls, path, live)
		end)
	end)
end)
