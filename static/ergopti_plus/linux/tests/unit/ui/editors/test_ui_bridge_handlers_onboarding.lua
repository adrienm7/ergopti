--- tests/unit/ui/editors/test_ui_bridge_handlers_onboarding.lua

--- ==============================================================================
--- Tier 2 — Integration tests for UI bridge handlers + webview manager.
--- Tests all 14 bridge handlers and the webview_manager routing layer.
--- Pure Lua — no GTK/WebKit2GTK required.
--- ==============================================================================

package.loaded["tests.support.ui.editors.ui_bridge_handlers_fixture"] = nil
local Fixture = require("tests.support.ui.editors.ui_bridge_handlers_fixture")
local helpers =
	Fixture.helpers




--- Runs the real resolver with one fresh owner, restoring the caller's exact cache.
--- @param body function Receives the freshly reloaded configuration paths module.
local function with_real_config_paths(body)
	local previous = package.loaded["infra.config_paths"]
	local ok, detail = pcall(function()
		body(helpers.load_module("infra.config_paths"))
	end)
	package.loaded["infra.config_paths"] = previous
	if not ok then error(detail, 0) end
end

helpers.describe("ui.bridge_handlers", function()
  helpers.describe("onboarding_bridge", function()
    local handler = helpers.load_module("ui.onboarding.bridge")

		-- A folder name no test creates, so the pages start from neutral values
		-- unless a case writes a configuration on purpose.
		local function scratch_dir()
			local path = os.tmpname()
			os.remove(path)
			return path
		end

		local function write_file(path, content)
			local fh = assert(io.open(path, "w"))
			fh:write(content)
			fh:close()
		end

		local function onboarding_state()
			local default_dir = scratch_dir()
			local values = { locale = "en", config_dir = default_dir }
			local captured = { pushes = {}, writes = {}, prepared = {}, hidden = 0, titles = {},
				restarts = {}, notices = 0, errors = {} }
			local state = {
				layout = "qwerty",
				manifest = helpers.load_module("infra.manifest_reader"),
				i18n = {
					get_locale = function() return values.locale end,
					list_locales = function() return { "en", "fr" } end,
					get = function(key) return key end,
					set_locale = function(value) values.locale = value; return true end,
					persist_locale = function(value) values.locale = value; return true end,
				},
				config_paths = {
					default_config_dir = function() return default_dir end,
					get_config_dir = function() return values.config_dir end,
					set_config_dir = function(value) values.config_dir = value; return true end,
					config = function(rel) return values.config_dir .. "/" .. rel end,
					data = function(rel) return "/tmp/data/" .. rel end,
					metrics_path = function() return "/tmp/data/metrics.sqlite" end,
				},
				writer = {
					batch_write = function(path, updates)
						captured.writes[#captured.writes + 1] = { path = path, updates = updates }
						return true
					end,
				},
				prepare_destination = function(path)
					captured.prepared[#captured.prepared + 1] = path
					return true
				end,
				webview_manager = {
					eval_js = function(app, code)
						captured.pushes[#captured.pushes + 1] = { app = app, code = code }
						return true
					end,
					hide = function(app)
						helpers.assert_eq(app, "onboarding")
						captured.hidden = captured.hidden + 1
					end,
					set_title = function(app, label)
						captured.titles[#captured.titles + 1] = { app = app, label = label }
						return true
					end,
				},
				restart = function(reason)
					captured.restarts[#captured.restarts + 1] = reason
					return true
				end,
				notify_restart_required = function() captured.notices = captured.notices + 1 end,
				notify_error = function(key) captured.errors[#captured.errors + 1] = key end,
			}
			return state, values, captured
		end

		local function finish(state, answers)
			return handler.on_message({ action = "finish", answers = answers }, state)
		end

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsOnboarding")
    end)

		helpers.it("pushes the complete shared initData contract on ready", function()
			local state, _, captured = onboarding_state()
			local result = handler.on_message({ action = "ready" }, state)
			helpers.assert_true(result.pushed)
			helpers.assert_eq(result.data.platform, "linux")
			helpers.assert_eq(result.data.locale, "en")
			helpers.assert_eq(result.data.system_layout, "qwerty")
			helpers.assert_eq(result.data.config_dir, "", "the default folder is not a custom choice")
			helpers.assert_eq(result.data.current, {}, "an absent config.toml leaves every page neutral")
			helpers.assert_true(#result.data.locales >= 21)
			helpers.assert_contains(captured.pushes[1].code, "window.initData")
		end)

		for _, current_dir in ipairs({ "/virtual/default-A", "/virtual/custom-B" }) do
			helpers.it("(onboarding-empty-folder) ready names the default destination from " .. current_dir, function()
				local state, values, captured = onboarding_state()
				values.config_dir = current_dir
				state.config_paths.default_config_dir = function() return "/virtual/default-A" end
				local result = handler.on_message({ action = "ready" }, state)
				helpers.assert_true(result.pushed)
				helpers.assert_eq(#captured.pushes, 1)
				local arguments = captured.pushes[1].code:match("window%.initData%((.*)%)$")
				helpers.assert_type(arguments, "string", "the actual ready producer must publish its payload")
				local delivered = require("json").decode(arguments)
				helpers.assert_eq(delivered.empty_config_dir, "/virtual/default-A",
					"clearing a Linux field selects the OS default, even from a custom folder")
				helpers.assert_eq(result.data.empty_config_dir, "/virtual/default-A")
				helpers.assert_eq(delivered.default_config_dir, "/virtual/default-A")
				helpers.assert_eq(delivered.config_dir, current_dir == "/virtual/default-A" and "" or "/virtual/custom-B",
					"the displayed custom choice retains its original contract")
				helpers.assert_eq(#captured.writes, 0, "initial presentation cannot write configuration")
				helpers.assert_eq(#captured.prepared, 0, "initial presentation cannot prepare a destination")
			end)
		end

		helpers.it("(onboarding-rerun) initData shows the values config.toml holds", function()
			local state = onboarding_state()
			local folder = scratch_dir()
			helpers.assert_true(os.execute("mkdir -p '" .. folder .. "'"))
			local path = folder .. "/config.toml"
			write_file(path, '[gestures]\nenabled = false\n[hotstrings.modules.distancesreduction]\nqu = true\n'
				.. '[unrelated]\nenabled = true\n')
			state.config_paths.config = function(rel)
				helpers.assert_eq(rel, "config.toml")
				return path
			end
			local result = handler.on_message({ action = "ready" }, state)
			os.remove(path)
			os.remove(folder)
			helpers.assert_true(result.pushed)
			helpers.assert_eq(result.data.current, {
				["gestures.enabled"] = false, ["hotstrings.modules.distancesreduction.qu"] = true,
			}, "a re-run shows the answers in force, an explicit false included")
		end)

		-- A re-run started the Tap-Holds page at No with Tap-Holds on, pre-checked
		-- every key and imported over the user's own ones.
		helpers.it("(onboarding-rerun) initData shows the tap-hold keys and switch of the folder", function()
			local state, values = onboarding_state()
			local folder = scratch_dir()
			helpers.assert_true(os.execute("mkdir -p '" .. folder .. "'"))
			values.config_dir = folder
			write_file(folder .. "/tap_hold.toml", '[tap_hold]\nenabled = true\n'
				.. '[tap_hold.keys.caps_lock]\ntime_activation_seconds = 0.35\ntap_action = "enter"\n'
				.. 'hold_modifier = "ctrl"\n'
				.. '[tap_hold.keys.left_alt]\ntap_action = "escape"\n')
			local ready = handler.on_message({ action = "ready" }, state)
			local chosen = handler.on_message({ action = "loadExistingConfig", config_dir = folder, request = 5 }, state)
			write_file(folder .. "/tap_hold.toml", '[tap_hold.keys.left_alt\n')
			local broken = handler.on_message({ action = "ready" }, state)
			os.remove(folder .. "/tap_hold.toml")
			os.remove(folder)
			local expected = {
				["tap_holds.enabled"] = true,
				["tap_holds.keys.caps_lock"] = true,
				["tap_holds.keys.left_alt"] = "customised",
			}
			helpers.assert_eq(ready.data.current, expected,
				"an imported key reads as on, the user's own one as kept, and the switch as in force")
			helpers.assert_eq(chosen.values, expected, "a chosen folder reads its own tap-hold file")
			helpers.assert_eq(broken.pushed, false, "an unreadable tap-hold file never opens a neutral page")
		end)

		helpers.it("(onboarding-rerun) an unreadable config.toml never opens neutral pages", function()
			local state, _, captured = onboarding_state()
			local path = os.tmpname()
			write_file(path, "[gestures\nenabled = \n")
			state.config_paths.config = function() return path end
			local result = handler.on_message({ action = "ready" }, state)
			os.remove(path)
			helpers.assert_eq(result.pushed, false,
				"showing defaults over a broken file would overwrite it with answers the user never gave")
			helpers.assert_eq(#captured.pushes, 0)
		end)

		helpers.it("uses the persisted locale in the shared initData contract", function()
			local state = onboarding_state()
			state.i18n.get_locale = function() return "de" end
			local result = handler.on_message({ action = "ready" }, state)
			helpers.assert_eq(result.data.locale, "de",
				"onboarding must open in the user's locale, not a hardcoded locale")
		end)

		helpers.it("previews and selects only a shipped locale", function()
			local state, _, captured = onboarding_state()
			local preview = handler.on_message({ action = "previewLocale", locale = "fr" }, state)
			helpers.assert_true(preview.pushed)
			helpers.assert_contains(captured.pushes[1].code, "window.applyStrings")
			helpers.assert_true(handler.on_message({
				action = "localeSelected", locale = "fr",
			}, state).accepted)
			helpers.assert_eq(handler.on_message({
				action = "localeSelected", locale = "xx",
			}, state).accepted, false)
		end)

		helpers.it("(onboarding-window-title) retitles the window in the previewed locale", function()
			local state, _, captured = onboarding_state()
			local result = handler.on_message({ action = "previewLocale", locale = "fr" }, state)
			helpers.assert_true(result.titled)
			helpers.assert_eq(captured.titles[1], { app = "onboarding", label = "Configuration" })
		end)

		helpers.it("(onboarding-window-title) titles the window in the current locale on ready", function()
			local state, _, captured = onboarding_state()
			local result = handler.on_message({ action = "ready" }, state)
			helpers.assert_true(result.titled)
			helpers.assert_eq(captured.titles[1], { app = "onboarding", label = "Setup" })
		end)

		helpers.it("(onboarding-window-title) an unshipped locale leaves the title alone", function()
			local state, _, captured = onboarding_state()
			local result = handler.on_message({ action = "previewLocale", locale = "xx" }, state)
			helpers.assert_eq(result.pushed, false)
			helpers.assert_eq(#captured.titles, 0)
		end)

		helpers.it("(onboarding-metrics-path) initData carries the keylogger's metrics store", function()
			local state = onboarding_state()
			local result = handler.on_message({ action = "ready" }, state)
			helpers.assert_eq(result.data.metrics_path, "/tmp/data/metrics.sqlite")
			helpers.assert_type(result.data.strings["dialog.metrics.enable_warning"], "string")
			helpers.assert_nil(result.data.strings["dialog.metrics.enable_warning_formatted"],
				"a pre-formatted warning freezes the path at open time")
		end)

		helpers.it("(onboarding-metrics-path) a chosen folder answers with the same store", function()
			local state, _, captured = onboarding_state()
			local result = handler.on_message({ action = "resolveMetricsPath",
				config_dir = "/tmp/elsewhere/", request = 4 }, state)
			helpers.assert_true(result.pushed)
			helpers.assert_eq(result.path, "/tmp/data/metrics.sqlite",
				"the Linux store lives in the data dir and must not follow the config folder")
			helpers.assert_contains(captured.pushes[1].code, "window.setMetricsPath")
			helpers.assert_contains(captured.pushes[1].code, '"request":4')
		end)

		helpers.it("(onboarding-metrics-path) a request without its number is refused", function()
			local state, _, captured = onboarding_state()
			local result = handler.on_message({ action = "resolveMetricsPath", config_dir = "/x" }, state)
			helpers.assert_eq(result.pushed, false)
			helpers.assert_eq(#captured.pushes, 0)
		end)

		helpers.it("(onboarding-metrics-path) the real resolver names the keylogger store", function()
			local previous = package.loaded["infra.config_paths"]
			with_real_config_paths(function(ConfigPaths)
				helpers.assert_eq(ConfigPaths.metrics_path(), ConfigPaths.data("metrics.sqlite"))
			end)
			helpers.assert_true(rawequal(package.loaded["infra.config_paths"], previous), "the real resolver retains the original path owner")
		end)

		helpers.it("(onboarding-metrics-path) restores a warm preference path owner after a resolver failure", function()
			local paths = require("infra.config_paths")
			local preferences = require("infra.metrics_preferences")
			local failure, visited = {}, 0
			local ok, detail = pcall(with_real_config_paths, function(fresh)
				helpers.assert_true(not rawequal(fresh, paths), "exercise a genuine fresh resolver")
				helpers.assert_eq(fresh.metrics_path(), fresh.data("metrics.sqlite"))
				visited = visited + 1
				error(failure, 0)
			end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(rawequal(detail, failure), "preserve the resolver's original failure")
			helpers.assert_eq(visited, 1)
			helpers.assert_true(rawequal(require("infra.config_paths"), paths), "a failed resolver cannot replace the warm preference path owner")
			helpers.assert_true(rawequal(require("infra.metrics_preferences"), preferences))
		end)

		helpers.it("(onboarding-window-title) the product name appears once in the window title", function()
			local manager = helpers.load_module("ui.webview_manager")
			local title = manager.window_title("Setup")
			helpers.assert_eq(title, "ErgoptiPlus — Setup")
			local _, count = title:gsub("ErgoptiPlus", "")
			helpers.assert_eq(count, 1)
			helpers.assert_eq(manager.window_title(""), "ErgoptiPlus")
			helpers.assert_eq(manager.set_title("onboarding", "Setup"), false,
				"retitling a window that is not open must report failure")
		end)

		helpers.it("(onboarding-rerun) projects a configuration onto wizard paths and marks what it reads", function()
			local marked = {}
			local values = handler.config_values({
				gestures = { enabled = false },
				hotstrings = { modules = { distancesreduction = { qu = true } }, trigger_char = ";" },
				unrelated = { enabled = true },
			}, function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(values, {
				["gestures.enabled"] = false, ["hotstrings.modules.distancesreduction.qu"] = true,
				["hotstrings.trigger_char"] = ";",
			}, "explicit false and the preserved raw trigger are configured values, not absent ones")
			table.sort(marked)
			helpers.assert_eq(marked, { "gestures.enabled", "hotstrings.modules.distancesreduction.qu", "hotstrings.trigger_char" },
				"the unused-key cleanup must never offer a key the wizard reads, and only those")
		end)

		helpers.it("(onboarding-rerun) a chosen folder reloads its own values under the request number", function()
			local state, _, captured = onboarding_state()
			local folder = scratch_dir()
			local absent = handler.on_message({ action = "loadExistingConfig",
				config_dir = folder .. "/", request = 3 }, state)
			helpers.assert_true(absent.loaded)
			helpers.assert_eq(absent.values, {}, "a folder without config.toml reloads neutral pages")
			helpers.assert_contains(captured.pushes[1].code, "window.applyCurrentValues")
			helpers.assert_contains(captured.pushes[1].code, '"request":3')

			helpers.assert_true(os.execute("mkdir -p '" .. folder .. "'"))
			write_file(folder .. "/config.toml", "[metrics]\nenabled = true\n")
			local present = handler.on_message({ action = "loadExistingConfig",
				config_dir = folder, request = 4 }, state)
			os.remove(folder .. "/config.toml")
			os.remove(folder)
			helpers.assert_eq(present.values, { ["metrics.enabled"] = true })

			local refused = handler.on_message({ action = "loadExistingConfig", config_dir = folder }, state)
			helpers.assert_eq(refused.loaded, false, "an answer without its request number could land late")
			helpers.assert_eq(#captured.pushes, 2)
		end)

		helpers.it("returns a native folder picker choice through setConfigDir", function()
			local state, _, captured = onboarding_state()
			state.shell = {
				has_command = function(binary) return binary == "zenity" end,
				quote = function(value) return "'" .. value .. "'" end,
				exec_checked = function() return true, "/tmp/picked/" end,
			}
			local result = handler.on_message({ action = "pickConfigDir", current = "" }, state)
			helpers.assert_true(result.picked)
			helpers.assert_eq(result.path, "/tmp/picked")
			helpers.assert_contains(captured.pushes[1].code, "window.setConfigDir")
		end)

		helpers.it("commits the answered paths in one versioned write, then restarts the daemon", function()
			local state, values, captured = onboarding_state()
			local target = scratch_dir()
			local result = finish(state, {
				locale = "fr", config_dir = target .. "/",
				operations = {
					{ path = "gestures.enabled", value = true },
					{ path = "metrics.enabled", value = false },
				},
			})
			helpers.assert_eq(result, { done = true, restarted = true })
			helpers.assert_eq(values.locale, "fr")
			helpers.assert_eq(values.config_dir, target)
			helpers.assert_eq(captured.prepared, { target .. "/config.toml" },
				"the destination is versioned before anything is written to it")
			helpers.assert_eq(captured.writes, { {
				path = target .. "/config.toml",
				updates = {
					{ section = "gestures", key = "enabled", value = true },
					{ section = "metrics", key = "enabled", delete = true },
				},
			} }, "every answer lands in one atomic batch and a neutral answer stays sparse")
			helpers.assert_eq(captured.hidden, 1)
			helpers.assert_eq(captured.restarts, { "the setup wizard" },
				"every module reads config.toml when it starts, so the daemon restarts once")
			helpers.assert_eq(captured.notices, 0)
			helpers.assert_eq(captured.errors, {})
		end)

		helpers.it("tells the user the answers apply at the next start when the daemon cannot restart", function()
			local state, _, captured = onboarding_state()
			state.restart = function() return false end
			local result = finish(state, {
				locale = "en", config_dir = "", operations = { { path = "gestures.enabled", value = true } },
			})
			helpers.assert_eq(result, { done = true, restarted = false })
			helpers.assert_eq(#captured.writes, 1, "the answers are already saved")
			helpers.assert_eq(captured.notices, 1)
		end)

		-- The Tap-Holds page asked, then imported nothing: its keys live in
		-- tap_hold.toml, which only the tap-hold writer owns.
		helpers.it("(onboarding-tap-holds) imports the checked keys into the chosen folder after the answers", function()
			local state, _, captured = onboarding_state()
			local target = scratch_dir()
			helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
			local Writer = helpers.load_module("platform.remap.tap_hold_writer")
			local imports = {}
			state.tap_hold_writer = setmetatable({
				import_recommended = function(path, keys, preset)
					imports[#imports + 1] = { path = path, keys = keys, config_writes = #captured.writes }
					return Writer.import_recommended(path, keys, preset)
				end,
			}, { __index = Writer })
			local result = finish(state, { locale = "en", config_dir = target, operations = {
				{ path = "tap_holds.keys.caps_lock", value = true },
				{ path = "gestures.enabled", value = true },
				{ path = "tap_holds.keys.left_alt", value = false },
				{ path = "tap_holds.keys.tab", value = true },
			} })
			local loaded = require("platform.remap.tap_hold_loader").load(
				require("infra.paths").shared("tap_hold/defaults.toml"), target .. "/tap_hold.toml")
			os.remove(target .. "/tap_hold.toml")
			os.remove(target)
			helpers.assert_eq(result, { done = true, restarted = true })
			helpers.assert_eq(imports, { { path = target .. "/tap_hold.toml", keys = { "caps_lock", "tab" },
				config_writes = 1 } }, "one import of the checked keys, into the chosen folder, after the answers")
			helpers.assert_eq(captured.writes[1].updates, { { section = "gestures", key = "enabled", value = true } },
				"no tap-hold key reaches config.toml")
			helpers.assert_eq(loaded.enabled, true, "the import switches the Tap-Holds on in their own file")
			helpers.assert_eq(loaded.keys.caps_lock.tap_action, "enter")
			helpers.assert_true(loaded.keys.tab ~= nil)
			helpers.assert_nil(loaded.keys.left_alt, "an unchecked key is not written")
			helpers.assert_eq(captured.errors, {})
		end)

		-- A fresh install has no layers.toml, which binds no key: the imported
		-- left_alt entered an empty navigation layer. The key now brings
		-- Ergopti's recommended layer along, never over the user's own file.
		local function import_left_alt(state, target)
			helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
			return finish(state, { locale = "en", config_dir = target, operations = {
				{ path = "tap_holds.keys.left_alt", value = true },
			} })
		end

		local function remove_folder(target)
			for _, name in ipairs({ "tap_hold.toml", "layers.toml" }) do os.remove(target .. "/" .. name) end
			os.remove(target)
		end

		local function read_text(path)
			local fh = io.open(path, "rb")
			if not fh then return nil end
			local text = fh:read("*a")
			fh:close()
			return text
		end

		helpers.it("(nav-layer-fresh-install-default) the key holding the layer brings Ergopti's layer into a new folder", function()
			local state, _, captured = onboarding_state()
			local target = scratch_dir()
			local result = import_left_alt(state, target)
			local text = read_text(target .. "/layers.toml")
			local ok, layer = pcall(require("platform.remap.nav_layer").load,
				{ shared_root = require("infra.paths").shared_root(), config_dir = target })
			remove_folder(target)
			helpers.assert_eq(result, { done = true, restarted = true })
			helpers.assert_eq(captured.errors, {})
			helpers.assert_eq(text, read_text(require("infra.paths").shared("keymap/layers.recommended.toml")),
				"layers.toml holds the recommended layer's exact bytes")
			helpers.assert_true(ok and next(layer) ~= nil, "the imported layer binds keys on Linux: " .. tostring(layer))
		end)

		helpers.it("(nav-layer-fresh-install-default) an existing layers.toml is never replaced", function()
			local state, _, captured = onboarding_state()
			local target = scratch_dir()
			helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
			local own = '[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"KeyJ" = "keystroke:ArrowDown"\n'
			write_file(target .. "/layers.toml", own)
			local result = import_left_alt(state, target)
			local text = read_text(target .. "/layers.toml")
			remove_folder(target)
			helpers.assert_true(result.done)
			helpers.assert_eq(captured.errors, {})
			helpers.assert_eq(text, own, "the user's layer file stays byte for byte")
		end)

		helpers.it("(nav-layer-fresh-install-default) keys that do not hold the layer import no layer file", function()
			local state = onboarding_state()
			local target = scratch_dir()
			helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
			finish(state, { locale = "en", config_dir = target, operations = {
				{ path = "tap_holds.keys.caps_lock", value = true },
				{ path = "tap_holds.keys.left_alt", value = false },
			} })
			local text = read_text(target .. "/layers.toml")
			remove_folder(target)
			helpers.assert_nil(text, "no layer is imported without the key that enters it")
		end)

		helpers.it("(nav-layer-fresh-install-default) a layer that cannot be written is reported, the keys stay", function()
			local state, _, captured = onboarding_state()
			local target = scratch_dir()
			local LayerPreset = require("keymap.layer_preset")
			state.layer_preset = setmetatable({
				import_if_absent = function() return nil, "disk full" end,
			}, { __index = LayerPreset })
			local result = import_left_alt(state, target)
			local keys = read_text(target .. "/tap_hold.toml")
			remove_folder(target)
			helpers.assert_eq(result, { done = true, restarted = true })
			helpers.assert_true(keys ~= nil, "the tap-hold keys are imported")
			helpers.assert_eq(captured.errors, { "onboarding.error.nav_layer_import" })
		end)

		helpers.it("(onboarding-tap-holds) a No or an unchecked list never reaches the tap-hold writer", function()
			local state, _, captured = onboarding_state()
			local calls = 0
			state.tap_hold_writer = {
				FILE_NAME = "tap_hold.toml",
				import_recommended = function() calls = calls + 1; return true end,
			}
			local result = finish(state, { locale = "en", config_dir = "", operations = {
				{ path = "tap_holds.keys.caps_lock", value = false },
				{ path = "gestures.enabled", value = false },
			} })
			helpers.assert_true(result.done)
			helpers.assert_eq(calls, 0, "nothing is written for a key the user did not keep")
			helpers.assert_eq(#captured.writes, 1)
		end)

		helpers.it("(onboarding-tap-holds) a refused import is reported and the saved answers still apply", function()
			local state, _, captured = onboarding_state()
			state.tap_hold_writer = {
				FILE_NAME = "tap_hold.toml",
				import_recommended = function() return false, "tap_hold.toml does not parse" end,
			}
			local result = finish(state, { locale = "en", config_dir = "", operations = {
				{ path = "tap_holds.keys.caps_lock", value = true },
			} })
			helpers.assert_eq(result, { done = true, restarted = true })
			helpers.assert_eq(#captured.writes, 1, "the other answers are saved")
			helpers.assert_eq(captured.errors, { "onboarding.error.tap_holds_import" },
				"the user is told the keys were not imported")
		end)

		-- Category, section and magic-key choices are config.toml leaves of the
		-- chosen folder: written before the switch, they stayed in the old one and
		-- the next start switched every catalogue off.
		helpers.it("writes the hotstring choices into the chosen configuration folder", function()
			local state, values, captured = onboarding_state()
			local target = scratch_dir()
			local folder_at_write = nil
			local batch_write = state.writer.batch_write
			state.writer.batch_write = function(path, updates)
				folder_at_write = values.config_dir
				return batch_write(path, updates)
			end
			local result = finish(state, { locale = "en", config_dir = target,
				operations = { { path = "hotstrings.groups.distancesreduction", value = true } } })
			helpers.assert_true(result.done)
			helpers.assert_eq(folder_at_write, target, "the folder switches before any choice is written")
			helpers.assert_eq(captured.writes[1].path, target .. "/config.toml")
		end)

		-- The page exposes Linux trigger selection, but forged common characters
		-- must not turn an ordinary word into a destructive hotstring trigger.
		for _, case in ipairs({
			{ ";", "dialog.magic_key.error_common" }, { "ù", "dialog.magic_key.error_common" },
			{ "e", "dialog.magic_key.error_common" }, { "א", "dialog.magic_key.error_common" },
			{ "ab", "dialog.magic_key.error_length" }, { "\255", "dialog.magic_key.error_length" },
			{ "\192\175", "dialog.magic_key.error_length" }, { "", "dialog.magic_key.error_empty" },
		}) do
			helpers.it("(onboarding-linux-trigger) refuses unsafe answer " .. case[2] .. " " .. string.format("%q", case[1]), function()
				local state, values, captured = onboarding_state()
				local previous = values.config_dir
				local changes = 0
				state.i18n.persist_locale = function() changes = changes + 1; return true end
				state.config_paths.set_config_dir = function() changes = changes + 1; return true end
				local result = finish(state, { locale = "fr", config_dir = scratch_dir(), operations = {
					{ path = "gestures.enabled", value = true },
					{ path = "hotstrings.trigger_char", value = case[1] },
				} })
				helpers.assert_eq(result, { done = false })
				helpers.assert_eq(changes, 0, "the whole payload is refused before changing either preference")
				helpers.assert_eq(values, { locale = "en", config_dir = previous })
				helpers.assert_eq(captured.writes, {})
				helpers.assert_eq(captured.prepared, {})
				helpers.assert_eq(captured.hidden, 0, "the wizard remains available for retry")
				helpers.assert_eq(captured.restarts, {})
				helpers.assert_eq(captured.errors, { case[2] }, "the existing translated reason reaches the user")
				-- Retrying the same wizard needs no new state or reinitialization.
				captured.errors = {}
				state.i18n.persist_locale = function(value) values.locale = value; return true end
				state.config_paths.set_config_dir = function(value) values.config_dir = value; return true end
				local retried = finish(state, { locale = "en", config_dir = "", operations = {
					{ path = "hotstrings.trigger_char", value = "§" },
				} })
				helpers.assert_true(retried.done)
				helpers.assert_eq(captured.errors, {})
				helpers.assert_eq(captured.writes[1].updates, { { section = "hotstrings", key = "trigger_char", value = "§" } })
			end)
		end

		for _, stale in ipairs({ ";", "ù" }) do
			helpers.it("(onboarding-linux-trigger) preserves an existing outdated trigger until explicit replacement " .. stale, function()
				local state, _, captured = onboarding_state()
				local target = scratch_dir()
				local path = target .. "/config.toml"
				local raw = '[_meta]\nschema_version = 7\n[hotstrings]\ntrigger_char = "' .. stale
					.. '"\n[future]\nkeep = "independent"\n'
				local ok, err = pcall(function()
					helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
					write_file(path, raw)
					state.writer = require("toml_codec.writer")
					local ready = handler.on_message({ action = "loadExistingConfig", config_dir = target, request = 17 }, state)
					helpers.assert_true(ready.loaded)
					helpers.assert_eq(ready.values["hotstrings.trigger_char"], stale)
					helpers.assert_contains(captured.pushes[#captured.pushes].code, '"request":17', "the selected folder keeps its request identity")
					local retained = finish(state, { locale = "en", config_dir = target, operations = {} })
					helpers.assert_true(retained.done)
					local fh = assert(io.open(path, "r")); local kept = fh:read("*a"); fh:close()
					helpers.assert_eq(kept, raw, "an untouched outdated trigger and future neighbor remain byte-exact")
					local replaced = finish(state, { locale = "en", config_dir = target, operations = {
						{ path = "hotstrings.trigger_char", value = "§" },
					} })
					helpers.assert_true(replaced.done)
					helpers.assert_eq(captured.errors, {})
					fh = assert(io.open(path, "r"))
					local decoded = require("toml_codec").decode(fh:read("*a")); fh:close()
					helpers.assert_eq(decoded.hotstrings.trigger_char, "§", "the explicit accepted choice replaces only its leaf")
					helpers.assert_eq(decoded.future.keep, "independent")
				end)
				os.remove(path); os.remove(path .. ".tmp"); os.remove(target)
				if not ok then error(err, 0) end
			end)
		end

		for _, fixture in ipairs({
			{ name = "number", value = 7, toml = "trigger_char = 7\n" },
			{ name = "false", value = false, toml = "trigger_char = false\n" },
			{ name = "empty", value = "", toml = 'trigger_char = ""\n' },
			{ name = "inline table", value = { retained = "independent" }, toml = 'trigger_char = { retained = "independent" }\n' },
			{ name = "table header", value = { retained = "independent" }, toml = '[hotstrings.trigger_char]\nretained = "independent"\n' },
		}) do
			helpers.it("(onboarding-linux-trigger) retains untouched outdated " .. fixture.name .. " and accepts an explicit leaf replacement", function()
				local state, _, captured = onboarding_state()
				local target = scratch_dir()
				local path = target .. "/config.toml"
				local raw = '[_meta]\nschema_version = 7\n[hotstrings]\n' .. fixture.toml
					.. '[future]\nkeep = "independent"\n'
				local ok, err = pcall(function()
					helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
					write_file(path, raw)
					state.writer = require("toml_codec.writer")
					local ready = handler.on_message({ action = "loadExistingConfig", config_dir = target, request = 23 }, state)
					helpers.assert_true(ready.loaded)
					helpers.assert_eq(ready.values["hotstrings.trigger_char"], fixture.value)
					local retained = finish(state, { locale = "en", config_dir = target, operations = {} })
					helpers.assert_true(retained.done)
					local fh = assert(io.open(path, "r")); local bytes = fh:read("*a"); fh:close()
					helpers.assert_eq(bytes, raw, "without explicit trigger intent the complete source is byte-exact")
					local changed = finish(state, { locale = "en", config_dir = target, operations = {
						{ path = "hotstrings.trigger_char", value = "§" },
					} })
					helpers.assert_true(changed.done)
					helpers.assert_eq(captured.errors, {})
					fh = assert(io.open(path, "r"))
					local document = require("toml_codec").decode(fh:read("*a")); fh:close()
					helpers.assert_eq(document, { _meta = { schema_version = 7 },
						hotstrings = { trigger_char = "§" }, future = { keep = "independent" } },
						"explicit replacement changes only the owned leaf, preserving the complete neighbor document")
				end)
				os.remove(path); os.remove(path .. ".tmp"); os.remove(target)
				if not ok then error(err, 0) end
			end)
		end

		helpers.it("(onboarding-linux-trigger) retains a concurrent source change and retries after writer publication refusal", function()
			local state, values, captured = onboarding_state()
			local previous_dir = values.config_dir
			local target = scratch_dir()
			local path = target .. "/config.toml"
			local raw = '[_meta]\nschema_version = 7\n[hotstrings]\ntrigger_char = false\n[future]\nkeep = "independent"\n'
			local concurrent = raw .. '# concurrent edit during candidate staging\n'
			local original_open, staged = io.open, 0
			local NativeWriter = require("infra.regular_file_writer")
			local original_stage = NativeWriter.open
			local ok, err = pcall(function()
				helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
				write_file(path, raw)
				state.writer = require("toml_codec.writer")
				NativeWriter.open = function(open_path, mode)
					if open_path ~= path .. ".tmp" or mode ~= "wx" then return original_stage(open_path, mode) end
					local function opened(fh, ...)
						if not fh then return fh, ... end
						return {
							write = function(_, content) return fh:write(content) end,
							close = function()
								local function closed(...)
									staged = staged + 1
									local source = assert(original_open(path, "w"))
									assert(source:write(concurrent)); assert(source:close())
									return ...
								end
								return closed(fh:close())
							end,
						}, ...
					end
					return opened(original_stage(open_path, mode))
				end
				local refused = finish(state, { locale = "fr", config_dir = target, operations = {
					{ path = "hotstrings.trigger_char", value = "§" },
				} })
				NativeWriter.open = original_stage
				helpers.assert_eq(staged, 1, "the actual writer reaches the concurrent staging boundary")
				helpers.assert_eq(refused, { done = false })
				helpers.assert_eq(values, { locale = "en", config_dir = previous_dir }, "the failed commit restores preferences")
				helpers.assert_eq(captured.errors, { "onboarding.error.write_failed" })
				helpers.assert_eq(captured.hidden, 0)
				helpers.assert_eq(captured.restarts, {})
				local fh = assert(original_open(path, "r")); local bytes = fh:read("*a"); fh:close()
				helpers.assert_eq(bytes, concurrent, "the real exact-source fence preserves the external edit")
				helpers.assert_nil(original_open(path .. ".tmp", "r"), "no rejected staging file remains")
				captured.errors = {}
				local retried = finish(state, { locale = "en", config_dir = target, operations = {
					{ path = "hotstrings.trigger_char", value = "§" },
				} })
				helpers.assert_true(retried.done)
				helpers.assert_eq(captured.errors, {})
				fh = assert(original_open(path, "r")); bytes = fh:read("*a"); fh:close()
				helpers.assert_true(bytes:find('# concurrent edit during candidate staging', 1, true) ~= nil)
				helpers.assert_eq(require("toml_codec").decode(bytes).hotstrings.trigger_char, "§")
			end)
			NativeWriter.open = original_stage
			os.remove(path); os.remove(path .. ".tmp"); os.remove(target)
			if not ok then error(err, 0) end
		end)

		for _, candidate in ipairs({ "§", "★", "→", "😀" }) do
			helpers.it("(onboarding-linux-trigger) persists and re-reads safe symbol " .. candidate, function()
				local state, values, captured = onboarding_state()
				local target = scratch_dir()
				local path = target .. "/config.toml"
				local stored = nil
				if candidate ~= "★" then stored = candidate end
				local saved_preferences = package.loaded["infra.hotstring_preferences"]
				local saved_magic = package.loaded["modules.hotstrings.magic_key"]
				local ok, err = pcall(function()
					helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
					write_file(path, '[_meta]\nschema_version = 7\n[future]\nkeep = "independent"\n')
					state.writer = require("toml_codec.writer")
					local result = finish(state, { locale = "en", config_dir = target, operations = {
						{ path = "hotstrings.trigger_char", value = candidate },
					} })
					helpers.assert_true(result.done)
					helpers.assert_eq(captured.errors, {})
					local fh = assert(io.open(path, "r"))
					local decoded = require("toml_codec").decode(fh:read("*a")); fh:close()
					helpers.assert_eq(decoded.future.keep, "independent", "a future neighbor is preserved")
					helpers.assert_eq(decoded._meta.schema_version, 7)
					helpers.assert_eq((decoded.hotstrings or {}).trigger_char, stored)
					local preferences = helpers.load_module("infra.hotstring_preferences")
					preferences._set_file_for_test(path)
					helpers.assert_true(preferences.refresh())
					local magic = helpers.load_module("modules.hotstrings.magic_key")
					helpers.assert_eq(magic.get(), candidate, "a fresh runtime owner reads the wizard's choice")
					local ready = handler.on_message({ action = "ready" }, state)
					helpers.assert_eq(ready.data.current["hotstrings.trigger_char"], stored,
						"a re-run shows the persisted custom value and leaves the default sparse")
				end)
				package.loaded["infra.hotstring_preferences"] = saved_preferences
				package.loaded["modules.hotstrings.magic_key"] = saved_magic
				os.remove(path); os.remove(path .. ".tmp"); os.remove(target)
				if not ok then error(err, 0) end
			end)
		end

		helpers.it("rejects malformed finish data without writing or closing", function()
			for label, answers in pairs({
				["string value"] = { locale = "en", config_dir = "",
					operations = { { path = "gestures.enabled", value = "true" } } },
				["relative folder"] = { locale = "en", config_dir = "relative",
					operations = { { path = "gestures.enabled", value = true } } },
				["unshipped locale"] = { locale = "xx", config_dir = "",
					operations = { { path = "gestures.enabled", value = true } } },
				["retired marker"] = { locale = "en", config_dir = "",
					operations = { { path = "script.onboarding_done", value = true } } },
				["duplicate path"] = { locale = "en", config_dir = "", operations = {
					{ path = "gestures.enabled", value = true }, { path = "gestures.enabled", value = false },
				} },
				["legacy answers"] = { locale = "en", config_dir = "", use_ergopti = true },
			}) do
				local state, values, captured = onboarding_state()
				local default_dir = values.config_dir
				local result = finish(state, answers)
				helpers.assert_eq(result.done, false, label)
				helpers.assert_eq(#captured.writes, 0, label)
				helpers.assert_eq(captured.hidden, 0, label)
				helpers.assert_eq(#captured.restarts, 0, label)
				helpers.assert_eq(values.locale, "en", label .. ": a refused payload changes nothing")
				helpers.assert_eq(values.config_dir, default_dir, label)
				helpers.assert_eq(captured.errors, { "onboarding.error.invalid_answers" },
					label .. ": the user is told why nothing was saved")
			end
		end)

		helpers.it("restores the language and folder and says what failed when a commit step fails", function()
			for label, case in pairs({
				["unversionable destination"] = { "onboarding.error.write_failed", function(state)
					state.prepare_destination = function() return false, "written by a newer version" end
				end },
				["failed write"] = { "onboarding.error.write_failed", function(state)
					state.writer.batch_write = function() return false, "disk full" end
				end },
				["refused language"] = { "onboarding.error.locale_persist_failed", function(state)
					state.i18n.persist_locale = function() return false end
				end },
				["refused folder"] = { "paths_editor.save_failed", function(state)
					state.config_paths.set_config_dir = function() return false end
				end },
			}) do
				local expected, arrange = case[1], case[2]
				local state, values, captured = onboarding_state()
				local default_dir = values.config_dir
				arrange(state)
				local result = finish(state, {
					locale = "fr", config_dir = scratch_dir(),
					operations = { { path = "gestures.enabled", value = true } },
				})
				helpers.assert_eq(result.done, false, label)
				helpers.assert_eq(values.locale, "en", label)
				helpers.assert_eq(values.config_dir, default_dir, label)
				helpers.assert_eq(captured.hidden, 0, label .. ": a failed transaction leaves the wizard open for retry")
				helpers.assert_eq(#captured.restarts, 0, label)
				helpers.assert_eq(#captured.writes, 0, label)
				helpers.assert_eq(captured.errors, { expected }, label .. ": the user is told what failed")
			end
		end)

		helpers.it("covers every action the shared page posts", function()
			local path = helpers.driver_root() .. "/../_shared/ui/onboarding/script.js"
			local fh = assert(io.open(path, "r"))
			local source = fh:read("*a")
			fh:close()
			local found = 0
			for action in source:gmatch("_post%(%{ action: '([^']+)'") do
				found = found + 1
				helpers.assert_true(handler.ACTIONS[action] == true,
					"the Linux bridge does not recognise the shared action " .. action)
			end
			helpers.assert_true(found >= 8,
				"the contract scan must observe every onboarding action, not pass on an empty match")
		end)
  end)

  -- ==========================================================================
  -- 6b. Locale routing (i18n) — dashboards follow the persisted locale
  -- ==========================================================================
end)

