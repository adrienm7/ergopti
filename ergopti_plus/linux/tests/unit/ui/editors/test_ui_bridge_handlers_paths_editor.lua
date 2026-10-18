--- tests/unit/ui/editors/test_ui_bridge_handlers_paths_editor.lua

--- ==============================================================================
--- Tier 2 — Integration tests for UI bridge handlers + webview manager.
--- Tests all 14 bridge handlers and the webview_manager routing layer.
--- Pure Lua — no GTK/WebKit2GTK required.
--- ==============================================================================

package.loaded["tests.support.ui.editors.ui_bridge_handlers_fixture"] = nil
local Fixture = require("tests.support.ui.editors.ui_bridge_handlers_fixture")
local helpers, read_sandbox_file, sandboxed_toml_bridge, restore_sandbox, build_mock_state =
	Fixture.helpers, Fixture.read_sandbox_file, Fixture.sandboxed_toml_bridge, Fixture.restore_sandbox, Fixture.build_mock_state




helpers.describe("ui.bridge_handlers", function()
  helpers.describe("paths_editor_bridge", function()
    local handler = helpers.load_module("ui.paths_editor.bridge")

		local function paths_state()
			local values = { config_dir = "/tmp/ergopti-current", logs_dir = "/tmp/ergopti-logs" }
			local captured = { pushes = {}, hidden = 0, reloaded = 0 }
			return {
				config_paths = {
					get_config_dir = function() return values.config_dir end,
					default_config_dir = function() return "/tmp/ergopti-default" end,
					set_paths = function(value)
						if type(value) ~= "string" or value:sub(1, 1) ~= "/" then return false end
						values.config_dir = value:gsub("/+$", "")
						return true
					end,
					get_logs_dir = function() return values.logs_dir end,
					default_logs_dir = function() return "/tmp/ergopti-default-logs" end,
				},
				i18n = { get = function(key) return "translated:" .. key end },
				shell = {
					has_command = function(binary) return binary == "zenity" end,
					quote = function(value) return "'" .. value .. "'" end,
					exec_checked = function() return true, "/tmp/ergopti-picked/" end,
				},
				webview_manager = {
					eval_js = function(app, code)
						captured.pushes[#captured.pushes + 1] = { app = app, code = code }
						return true
					end,
					hide = function(app)
						helpers.assert_eq(app, "paths_editor")
						captured.hidden = captured.hidden + 1
						return true
					end,
				},
				on_reload = function() captured.reloaded = captured.reloaded + 1; return true end,
			}, values, captured
		end

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsPaths")
    end)
		helpers.it("pushes the shared initData contract on ready", function()
			local state, _, captured = paths_state()
			local result = handler.on_message({ action = "ready" }, state)
			helpers.assert_true(result.pushed)
			helpers.assert_eq(result.data.configDir, "/tmp/ergopti-current")
			helpers.assert_eq(result.data.defaultConfigDir, "/tmp/ergopti-default")
			helpers.assert_eq(result.data.logsDir, "/tmp/ergopti-logs")
			helpers.assert_eq(result.data.defaultLogsDir, "/tmp/ergopti-default-logs")
			helpers.assert_eq(result.data.version, require("infra.version").VERSION)
			helpers.assert_eq(result.data.strings["paths_editor.heading"],
				"translated:paths_editor.heading")
			helpers.assert_eq(captured.pushes[1].app, "paths_editor")
			helpers.assert_contains(captured.pushes[1].code, "window.initData")
    end)
		helpers.it("returns the native picker result through applyBrowseResult", function()
			local state, _, captured = paths_state()
			local result = handler.on_message({ action = "browse" }, state)
			helpers.assert_true(result.picked and result.pushed)
			helpers.assert_eq(result.path, "/tmp/ergopti-picked")
			helpers.assert_contains(captured.pushes[1].code, "window.applyBrowseResult")
			helpers.assert_contains(captured.pushes[1].code, "/tmp/ergopti-picked")
		end)
		helpers.it("persists configDir, closes, and reloads on save", function()
			local state, values, captured = paths_state()
			local result = handler.on_message({
				action = "save", configDir = "/tmp/ergopti-saved/",
			}, state)
			helpers.assert_true(result.saved and result.hidden and result.reloaded)
			helpers.assert_eq(values.config_dir, "/tmp/ergopti-saved")
			helpers.assert_eq(captured.hidden, 1)
			helpers.assert_eq(captured.reloaded, 1)
		end)
		helpers.it("closes without persistence on cancel", function()
			local state, values, captured = paths_state()
			local result = handler.on_message({ action = "cancel" }, state)
			helpers.assert_true(result.cancelled and result.hidden)
			helpers.assert_eq(values.config_dir, "/tmp/ergopti-current")
			helpers.assert_eq(captured.hidden, 1)
			helpers.assert_eq(captured.reloaded, 0)
    end)
  end)

  -- ==========================================================================
  -- 12. personal_info_editor_bridge
  -- ==========================================================================
end)




helpers.describe("ui.bridge_handlers", function()
  helpers.describe("personal_info_editor_bridge", function()
    local handler = helpers.load_module("ui.personal_info_editor.bridge")

    local function personal_state(save_result, reload_result)
      local captured = { close_count = 0, reload_count = 0 }
      local state = build_mock_state()
      state.dyn_hotstrings = {
        get_info = function()
          return { first_name = "Ada", email_address = "ada@example.test" }
        end,
        get_letters = function() return { p = "first_name" } end,
        get_trigger_char = function() return "★" end,
        save_info = function(values)
          captured.values = values
          return save_result
        end,
      }
      state.i18n = { get = function(key) return "translated:" .. key end }
      state.webview_manager = {
        eval_js = function(app_name, js)
          captured.app_name = app_name
          captured.js = js
          return true
        end,
      }
      state.config.reload = function()
        captured.reload_count = captured.reload_count + 1
        return reload_result, true
      end
      local context = {
        close_owned_window = function()
          captured.close_count = captured.close_count + 1
          return true
        end,
      }
      return state, context, captured
    end

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsPersonalInfo")
    end)
    helpers.it("pushes the exact shared-page initData contract on ready", function()
      local state, _, captured = personal_state(true, 2)
      local result = handler.on_message({ action = "ready" }, state)
      helpers.assert_true(result.pushed)
      helpers.assert_eq(captured.app_name, "personal_info_editor")
      helpers.assert_true(captured.js:find("window.initData", 1, true) ~= nil)
      helpers.assert_true(captured.js:find('"first_name"', 1, true) ~= nil)
      helpers.assert_true(captured.js:find('"(@p★)"', 1, true) ~= nil)
    end)
    helpers.it("commits the page's values, reloads, then closes its exact page", function()
      local state, context, captured = personal_state(true, 2)
      local values = { first_name = "Grace", email_address = "grace@example.test" }
      local result = handler.on_message({ action = "save", values = values }, state, context)
      helpers.assert_true(result.saved and result.reloaded and result.closed)
      helpers.assert_eq(captured.values, values)
      helpers.assert_eq(captured.reload_count, 1)
      helpers.assert_eq(captured.close_count, 1)
    end)
    helpers.it("keeps the editor open when persistence refuses the page values", function()
      local state, context, captured = personal_state(false, 2)
      local result = handler.on_message({ action = "save", values = { first_name = "Grace" } },
        state, context)
      helpers.assert_eq(result.saved, false)
      helpers.assert_eq(captured.reload_count, 0)
      helpers.assert_eq(captured.close_count, 0)
    end)
    helpers.it("closes the exact page without persistence on cancel", function()
      local state, context, captured = personal_state(true, 2)
      local result = handler.on_message({ action = "cancel" }, state, context)
      helpers.assert_true(result.cancelled and result.closed)
      helpers.assert_eq(captured.values, nil)
      helpers.assert_eq(captured.close_count, 1)
    end)
  end)

  -- ==========================================================================
  -- 13. model_browser_bridge
  -- ==========================================================================
end)




helpers.describe("ui.bridge_handlers", function()
  helpers.describe("model_browser_bridge", function()
    local handler = helpers.load_module("ui.model_browser.bridge")

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "model_browser_bridge")
    end)
    helpers.it("pushes the curated Ollama catalogue and routes exact page actions", function()
      local previous_manager = package.loaded["ui.webview_manager"]
      local pushed, selected, download, closes = {}, nil, nil, 0
      package.loaded["ui.webview_manager"] = {
        eval_js = function(app, code)
          pushed[#pushed + 1] = { app = app, code = code }
          return true
        end,
      }
      handler._reset()
      local state = {
        llm = {
          get_models = function() return { "qwen3.5:0.8b" } end,
          get_current_model = function() return "qwen3.5:0.8b" end,
          set_model = function(name) selected = name; return true end,
          download_model = function(runtime_name, label)
            download = { runtime_name = runtime_name, label = label }
            return true
          end,
        },
      }
      local context = {
        close_owned_window = function() closes = closes + 1; return true end,
      }
      local ready = handler.on_message("ready", state, context)
      helpers.assert_true(ready.pushed)
      helpers.assert_eq(pushed[1].app, "model_browser")
      helpers.assert_true(pushed[1].code:find("window.injectModels", 1, true) ~= nil)
      helpers.assert_true(#ready.data.models > 0)

      local installed, available = nil, nil
      for _, row in ipairs(ready.data.models) do
        if row.runtime_name == "qwen3.5:0.8b" then installed = row end
        if not available and row.installed ~= true then available = row end
      end
      helpers.assert_not_nil(installed)
      helpers.assert_not_nil(available)
      local chosen = handler.on_message({ action = "select_model", name = installed.name }, state, context)
      helpers.assert_true(chosen.selected and chosen.closed)
      helpers.assert_eq(selected, installed.runtime_name)
      local queued = handler.on_message({ action = "select_model", name = available.name }, state, context)
      helpers.assert_true(queued.downloading and queued.closed)
      helpers.assert_eq(download.runtime_name, available.runtime_name)
      helpers.assert_eq(download.label, available.name)
      helpers.assert_eq(closes, 2)
      package.loaded["ui.webview_manager"] = previous_manager
    end)
  end)

  -- ==========================================================================
  -- 14. token_bridge
  -- ==========================================================================
end)




helpers.describe("ui.bridge_handlers", function()
  helpers.describe("token_bridge", function()
    local handler = helpers.load_module("ui.token_prompt.bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "token_bridge")
    end)
    helpers.it("'ready' returns token settings", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.max_tokens) == "number")
      helpers.assert_true(type(result.triggers) == "table")
      helpers.assert_true(result.auto_inject ~= nil)
    end)
    helpers.it("handles 'save_settings' action", function()
      local result = handler.on_message({ action = "save_settings", settings = { max_tokens = 512, temperature = 0.5 } }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.saved)
    end)
    helpers.it("handles 'test_prompt' action", function()
      local result = handler.on_message({ action = "test_prompt", prompt = "Hello world" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.requested)
    end)
  end)

  -- ==========================================================================
  -- 15. personal_toml_editor
  -- ==========================================================================
end)




helpers.describe("ui.bridge_handlers", function()
  helpers.describe("personal_toml_editor", function()
    local handler = helpers.load_module("ui.personal_info_editor.bridge_toml")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "personal_toml_editor")
    end)
    helpers.it("'ready' returns TOML content", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.toml_content) == "string")
      helpers.assert_true(type(result.toml_path) == "string")
      helpers.assert_eq(result.readonly, false)
    end)
    helpers.it("handles 'reload' action", function()
      local result = handler.on_message({ action = "reload" }, state)
      helpers.assert_true(type(result) == "table")
    end)
  end)
end)




helpers.describe("personal_toml_editor save (toml-save)", function()

  helpers.it("toml-save: refuses malformed TOML and keeps the previous file", function()
    local path = os.tmpname()
    local seed = io.open(path, "w")
    seed:write('[info]\nfirst_name = "Ada"\n')
    seed:close()
    local handler, previous = sandboxed_toml_bridge(path)
    local ok, err = pcall(function()
      local result = handler.on_message({ action = "save", content = "[info\nbroken" }, {})
      helpers.assert_true(type(result) == "table" and result.saved == false,
        "a malformed save must be refused loudly, not stored")
      helpers.assert_eq(read_sandbox_file(path), '[info]\nfirst_name = "Ada"\n',
        "the previous file must survive the refused save byte for byte")
    end)
    restore_sandbox(previous)
    os.remove(path)
    if not ok then error(err, 0) end
  end)

  helpers.it("toml-save: saves valid TOML exactly and stages atomically", function()
    local path = os.tmpname()
    os.remove(path)
    local seed = io.open(path, "w")
    seed:write('[info]\nfirst_name = "Ada"\n')
    seed:close()
    local handler, previous = sandboxed_toml_bridge(path)
    local ok, err = pcall(function()
      local sent = '[info]\nfirst_name = "Grace"\n'
      local result = handler.on_message({ action = "save", content = sent }, {})
      helpers.assert_true(type(result) == "table" and result.saved == true,
        "a valid save must succeed")
      helpers.assert_eq(result.path, path, "…at the resolved personal_info.toml path")
      helpers.assert_eq(read_sandbox_file(path), sent,
        "the file must carry exactly what was sent")
      helpers.assert_true(io.open(path .. ".tmp", "r") == nil,
        "no staging litter may survive a published save")
    end)
    restore_sandbox(previous)
    os.remove(path)
    os.remove(path .. ".tmp")
    if not ok then error(err, 0) end
  end)

  helpers.it("toml-save: creates the file on first save", function()
    local path = os.tmpname()
    os.remove(path)
    local handler, previous = sandboxed_toml_bridge(path)
    local ok, err = pcall(function()
      local result = handler.on_message({ action = "save", content = '[info]\nfirst_name = "New"\n' }, {})
      helpers.assert_true(type(result) == "table" and result.saved == true,
        "a fresh home with no file must still be able to save — the editor is the only writer some users have")
      helpers.assert_eq(read_sandbox_file(path), '[info]\nfirst_name = "New"\n',
        "the created file must carry what was sent")
    end)
    restore_sandbox(previous)
    os.remove(path)
    os.remove(path .. ".tmp")
    if not ok then error(err, 0) end
  end)

  helpers.it("toml-save: refuses blank content loudly", function()
    local path = os.tmpname()
    local seed = io.open(path, "w")
    seed:write('[info]\nfirst_name = "Ada"\n')
    seed:close()
    local handler, previous = sandboxed_toml_bridge(path)
    local ok, err = pcall(function()
      local result = handler.on_message({ action = "save", content = "" }, {})
      helpers.assert_true(type(result) == "table" and result.saved == false,
        "blank content must be refused with an answer, not dropped silently")
      helpers.assert_eq(read_sandbox_file(path), '[info]\nfirst_name = "Ada"\n',
        "and the previous file must be untouched")
    end)
    restore_sandbox(previous)
    os.remove(path)
    if not ok then error(err, 0) end
  end)

end)




helpers.describe("personal editor: canonical reload acknowledgement", function()
	local function state_for(reload)
		local observed = { saves = 0, closes = 0, refreshes = 0 }
		local state = {
			dyn_hotstrings = { save_info = function() observed.saves = observed.saves + 1;return true end },
			config = { reload = reload },
			on_config_changed = function() observed.refreshes = observed.refreshes + 1 end,
		}
		local context = { close_owned_window = function() observed.closes = observed.closes + 1;return true end }
		return state, context, observed
	end
	for _, count in ipairs({ 0, 7 }) do
		helpers.it("admits a canonical successful reload count " .. count, function()
			local state, context, seen = state_for(function() return count, true end)
			local result = helpers.load_module("ui.personal_info_editor.bridge").on_message(
				{ action = "save", values = { first_name = "independent" } }, state, context)
			helpers.assert_eq(result, { saved = true, reloaded = true, closed = true })
			helpers.assert_eq(seen, { saves = 1, closes = 1, refreshes = 1 })
		end)
	end
	for _, outcome in ipairs({ "false", "nil", "number", "text", "throw", "missing" }) do
		helpers.it("retains a saved editor after reload acknowledgement " .. outcome, function()
			local reload = function()
				if outcome == "throw" then error("inert catalogue reload refusal") end
				if outcome == "nil" then return 0, nil end
				if outcome == "number" then return 0, 2 end
				if outcome == "text" then return 0, "true" end
				return 0, false, "inert catalogue reload refusal"
			end
			if outcome == "missing" then reload = nil end
			local state, context, seen = state_for(reload)
			local result = helpers.load_module("ui.personal_info_editor.bridge").on_message(
				{ action = "save", values = { first_name = "independent" } }, state, context)
			helpers.assert_eq(result, { saved = true, reloaded = false, closed = false })
			helpers.assert_eq(seen, { saves = 1, closes = 0, refreshes = 0 })
		end)
	end
	local function read(path)
		local file = assert(io.open(path, "rb"));local text = file:read("*a");assert(file:close());return text
	end
	local function write(path, content)
		local file = assert(io.open(path, "wb"));assert(file:write(content));assert(file:close())
	end
	local function with_native_owners(body)
		local directory = os.tmpname();assert(os.remove(directory));directory = directory .. "-ergopti-personal-reload"
		local Shell = require("adapters.shell_runner")
		local quote = Shell.quote
		assert(Shell.run("mkdir -p " .. quote(directory)) == true)
		local path, choices, empty = directory .. "/personal_info.toml", directory .. "/config.toml", directory .. "/personal_hotstrings.toml"
		local original = '# independent personal fields\n[info]\nfirst_name = "Ada"\n[letters]\np = "first_name"\n[future]\nvalues = [3, 9] # keep this comment\n'
		write(path, original);write(choices, '[future]\nlabel = "unchanged"\n');write(empty, '# deliberately empty valid hotstring catalogue\n[raw]\n')
		local prior = {};for name, value in pairs(package.loaded) do prior[name] = value end
		local called, failure = pcall(function()
			for _, name in ipairs({ "modules.dynamic_hotstrings.manager", "dynamic_hotstrings", "infra.hotstring_preferences",
				"modules.hotstrings.hotstrings_config" }) do package.loaded[name] = nil end
			local preferences = require("infra.hotstring_preferences")
			assert(preferences._set_file_for_test(choices))
			local dynamic = require("modules.dynamic_hotstrings.manager")
			assert(dynamic.init({ personal_info_path = path, trigger_char = "★" }))
			local config = require("modules.hotstrings.hotstrings_config")
			assert(config._set_config_file_for_test(choices))
			assert(config._set_override_config_dir_for_test(directory))
			body({ dynamic = dynamic, config = config, path = path, choices = choices, empty = empty,
				original = original, directory = directory })
		end)
		for name in pairs(package.loaded) do if prior[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(prior) do package.loaded[name] = value end
		local removed = Shell.run("rm -rf " .. quote(directory))
		assert(removed == true, "the owned native-file fixture is physically retired")
		for name, value in pairs(prior) do assert(package.loaded[name] == value, "every prior module identity is restored") end
		if not called then error(failure, 0) end
	end
	for _, outcome in ipairs({ "committed", "uninitialized", "false", "nil", "number", "throw" }) do
		helpers.it("consumes the actual canonical catalogue receipt after a real personal save " .. outcome, function()
			with_native_owners(function(c)
				local engine = require("hotstring_engine").new()
				local native_load = engine.load_mappings
				if outcome ~= "uninitialized" then assert(c.config.init(engine, c.empty)) end
				local calls = 0
				if outcome ~= "committed" and outcome ~= "uninitialized" then
					engine.load_mappings = function()
						calls = calls + 1
						if outcome == "throw" then error("inert engine publication refusal") end
						if outcome == "nil" then return nil end
						if outcome == "number" then return 2 end
						return false
					end
				end
				local closes, refreshes = 0, 0
				local native_reload, receipt = c.config.reload, nil
				c.config.reload = function()
					local count, committed, reason = native_reload()
					receipt = { count = count, committed = committed }
					return count, committed, reason
				end
				local handler = helpers.load_module("ui.personal_info_editor.bridge")
				local called, result = pcall(handler.on_message, { action = "save", values = { first_name = "Grace" } },
					{ dyn_hotstrings = c.dynamic, config = c.config,
						on_config_changed = function() refreshes = refreshes + 1 end },
					{ close_owned_window = function() closes = closes + 1;return true end })
				engine.load_mappings, c.config.reload = native_load, native_reload
				print(string.format("PERSONAL_RELOAD outcome=%s native_count=%s native_ack=%s closes=%d refreshes=%d", outcome,
					tostring(receipt and receipt.count), tostring(receipt and receipt.committed), closes, refreshes))
				helpers.assert_eq({ called, result }, { true,
					{ saved = true, reloaded = outcome == "committed", closed = outcome == "committed" } },
					"the protected native handler returns the acknowledged save and runtime outcome")
				helpers.assert_eq(receipt, { count = 0, committed = outcome == "committed" })
				helpers.assert_eq(read(c.path), c.original:gsub('first_name = "Ada"', 'first_name = "Grace"', 1),
					"the actual acknowledged leaf writer retains independent future data and comments")
				helpers.assert_eq(c.dynamic.get_info().first_name, "Grace", "the real dynamic save refreshed its own rules")
				helpers.assert_eq(result, { saved = true, reloaded = outcome == "committed", closed = outcome == "committed" },
					"durable save and static-catalogue runtime publication remain separate acknowledgements")
				helpers.assert_eq(closes, outcome == "committed" and 1 or 0)
				helpers.assert_eq(refreshes, outcome == "committed" and 1 or 0)
				helpers.assert_eq(calls, (outcome == "committed" or outcome == "uninitialized") and 0 or 1)
				if outcome == "committed" then
					local count, published = c.config.reload()
					helpers.assert_eq(count, 0, "a legitimately empty actual catalogue still commits")
					helpers.assert_eq(published, true)
				end
				if outcome ~= "committed" then
					if outcome == "uninitialized" then assert(c.config.init(engine, c.empty)) end
					local retry = handler.on_message({ action = "save", values = { first_name = "Grace" } },
						{ dyn_hotstrings = c.dynamic, config = c.config,
							on_config_changed = function() refreshes = refreshes + 1 end },
						{ close_owned_window = function() closes = closes + 1;return true end })
					helpers.assert_eq(retry, { saved = true, reloaded = true, closed = true })
					helpers.assert_eq(closes, 1);helpers.assert_eq(refreshes, 1)
					helpers.assert_eq(read(c.path), c.original:gsub('first_name = "Ada"', 'first_name = "Grace"', 1))
				end
			end)
		end)
	end
end)




helpers.describe("wizard explicit locale acknowledgment", function()
	local function read(path)
		local fh = assert(io.open(path, "rb"))
		local raw = assert(fh:read("*a")); assert(fh:close())
		return raw
	end

	local function write(path, raw)
		local fh = assert(io.open(path, "wb"))
		assert(fh:write(raw)); assert(fh:close())
	end

	local function with_real_locale(options)
		local names = { "infra.i18n", "infra.locale", "infra.config_paths", "adapters.storage" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local root = os.tmpname()
		os.remove(root)
		local made = os.execute("mkdir -p " .. string.format("%q", root .. "/ergopti_plus")
			.. " " .. string.format("%q", root .. "/config"))
		helpers.assert_true(made == true or made == 0)
		local storage_path = root .. "/ergopti_plus/storage.json"
		local config_path = root .. "/config/config.toml"
		local storage_seed = '{"locale":"zz_UNSUPPORTED","future":{"retained":true}}\n'
		local config_seed = '[gestures]\nenabled = false\n[future]\nvalue = "retained"\n'
		write(storage_path, storage_seed); write(config_path, config_seed)
		local original_rename = os.rename
		local captured = { storage_attempts = 0, writes = 0, hidden = 0, restarts = 0, errors = {} }
		local observed = nil
		local ok, err = xpcall(function()
			package.loaded["infra.config_paths"] = { config_home = function() return root end }
			package.loaded["infra.locale"] = nil
			package.loaded["adapters.storage"] = nil
			package.loaded["infra.i18n"] = nil
			local i18n = require("infra.i18n")
			i18n.init()
			local before_locale = i18n.get_locale()
			os.rename = function(from, to)
				if from == storage_path .. ".tmp" and to == storage_path then
					captured.storage_attempts = captured.storage_attempts + 1
					if options.rename == "throw" then error("owned locale rename refused") end
					if options.rename == "false" then return nil, "owned locale rename refused", 13 end
				end
				return original_rename(from, to)
			end
			if options.receipt then
				i18n.persist_locale = function()
					if options.receipt == "throw" then error("locale owner refused") end
					if options.receipt == "nil" then return nil end
					if options.receipt == "truthy" then return "unconfirmed" end
					return false
				end
			end
			if options.missing_owner then i18n.persist_locale = nil end
			local Writer = require("toml_codec.writer")
			local state = {
				i18n = i18n,
				manifest = require("infra.manifest_reader"),
				config_paths = {
					default_config_dir = function() return root .. "/config" end,
					get_config_dir = function() return root .. "/config" end,
					set_config_dir = function() return true end,
				},
				prepare_destination = function() return true end,
				writer = { batch_write = function(path, rows)
					captured.writes = captured.writes + 1
					if options.config_refusal then return false, "owned configuration refusal" end
					return Writer.batch_write(path, rows)
				end },
				webview_manager = { hide = function() captured.hidden = captured.hidden + 1 end },
				restart = function() captured.restarts = captured.restarts + 1; return true end,
				notify_error = function(key) captured.errors[#captured.errors + 1] = key end,
			}
			local result = require("ui.onboarding.bridge").on_message({ action = "finish", answers = {
				locale = options.code or "fr", config_dir = "",
				operations = { { path = "gestures.enabled", value = true } },
			} }, state)
			observed = {
				result = result, captured = captured, before = before_locale, after = i18n.get_locale(),
				storage_raw = read(storage_path), config_raw = read(config_path),
				storage_original = read(storage_path) == storage_seed,
				config_original = read(config_path) == config_seed,
			}
		end, debug.traceback)
		os.rename = original_rename
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		os.remove(storage_path .. ".tmp"); os.remove(storage_path); os.remove(config_path)
		os.execute("rmdir " .. string.format("%q", root .. "/ergopti_plus")
			.. " " .. string.format("%q", root .. "/config"))
		os.execute("rmdir " .. string.format("%q", root))
		if not ok then error(err, 0) end
		return observed
	end

	local function assert_refused(observed, key)
		helpers.assert_eq(observed.result.done, false)
		helpers.assert_eq(observed.before, "fr", "unsupported persisted selection uses the runtime fallback")
		helpers.assert_eq(observed.after, "fr", "refusal cannot publish a different runtime locale")
		helpers.assert_eq(observed.captured.writes, 0)
		helpers.assert_eq(observed.captured.hidden, 0)
		helpers.assert_eq(observed.captured.restarts, 0)
		helpers.assert_eq(observed.captured.errors, { key })
		helpers.assert_true(observed.storage_original)
		helpers.assert_true(observed.config_original)
	end

	for _, code in ipairs({ "fr", "en" }) do
		for _, mode in ipairs({ "false", "throw" }) do
			helpers.it("(wizard-locale-ack) keeps the wizard open after " .. mode .. " publication of " .. code, function()
				local observed = with_real_locale({ code = code, rename = mode })
				assert_refused(observed, "onboarding.error.locale_persist_failed")
				helpers.assert_eq(observed.captured.storage_attempts, 1)
			end)
		end
	end

	for _, code in ipairs({ "fr", "en" }) do
		helpers.it("(wizard-locale-ack) completes only after actual locale and configuration readback for " .. code, function()
			local observed = with_real_locale({ code = code })
			helpers.assert_eq(observed.result, { done = true, restarted = true })
			helpers.assert_eq(observed.after, code)
			helpers.assert_eq(require("json").decode(observed.storage_raw),
				{ locale = code, future = { retained = true } })
			helpers.assert_contains(observed.config_raw, "enabled = true")
			helpers.assert_contains(observed.config_raw, 'value = "retained"')
			helpers.assert_eq(observed.captured.storage_attempts, 1)
			helpers.assert_eq(observed.captured.writes, 1)
			helpers.assert_eq(observed.captured.hidden, 1)
			helpers.assert_eq(observed.captured.restarts, 1)
			helpers.assert_eq(observed.captured.errors, {})
		end)
	end

	for _, receipt in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("(wizard-locale-ack) rejects a " .. receipt .. " explicit owner receipt", function()
			local observed = with_real_locale({ receipt = receipt })
			assert_refused(observed, "onboarding.error.locale_persist_failed")
			helpers.assert_eq(observed.captured.storage_attempts, 0)
		end)
	end

	helpers.it("(wizard-locale-ack) refuses a missing explicit owner", function()
		local observed = with_real_locale({ missing_owner = true })
		assert_refused(observed, "onboarding.error.locale_persist_failed")
	end)

	for _, code in ipairs({ "fr", "en" }) do
		helpers.it("(wizard-locale-ack) retains existing runtime rollback after later config refusal for " .. code, function()
			local observed = with_real_locale({ code = code, config_refusal = true })
			helpers.assert_eq(observed.result.done, false)
			helpers.assert_eq(observed.after, "fr")
			helpers.assert_eq(observed.captured.hidden, 0)
			helpers.assert_eq(observed.captured.restarts, 0)
			helpers.assert_eq(observed.captured.errors, { "onboarding.error.write_failed" })
			helpers.assert_true(observed.config_original)
			helpers.assert_eq(require("json").decode(observed.storage_raw),
				{ locale = "fr", future = { retained = true } },
				"the existing runtime rollback persists its runtime snapshot, not an invented raw-source transaction")
		end)
	end
end)

