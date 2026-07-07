--- tests/unit/meta/test_ui_bridge_handlers.lua

--- ==============================================================================
--- Tier 2 — Integration tests for UI bridge handlers + webview manager.
--- Tests all 6 bridge handlers and the webview_manager routing layer.
--- Pure Lua — no GTK/WebKit2GTK required.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("ui.bridge_handlers", function()

  -- ==========================================================================
  -- Shared mock daemon state used by all bridge handlers.
  -- ==========================================================================

  local function build_mock_state()
    return {
      engine    = { loaded = true },
      keylogger = {
        get_session_stats = function() return { keystrokes = 42, words = 8, duration_ms = 120000 } end,
        get_wpm           = function() return 35.5 end,
        get_app_stats     = function() return { firefox = { keystrokes = 20 }, code = { keystrokes = 22 } } end,
        is_suppressed     = function() return false end,
        suppress          = function() end,
        unsuppress        = function() end,
        reset_session     = function() end,
        export_json       = function() return '{"keystrokes":42}' end,
      },
      config = {
        get_groups     = function() return { "accents", "math", "code" } end,
        is_group_enabled = function(_, g) return g ~= "code" end,
        toggle_group   = function(g) end,
        reload         = function() return 10 end,
        mapping_count  = function() return 50 end,
        parse_error_count = function() return 2 end,
        get_config_dir = function() return "/home/user/.config/ergopti/hotstrings" end,
      },
      llm = {
        is_enabled        = function() return true end,
        get_current_model = function() return "codellama" end,
        get_models        = function() return { "codellama", "mistral", "llama3" } end,
        get_triggers      = function() return { "//", ";;" } end,
        toggle            = function() end,
        set_model         = function(m) end,
        predict           = function(ctx) end,
      },
      layout = "qwerty",
    }
  end

  -- ==========================================================================
  -- 1. webview_manager
  -- ==========================================================================

  helpers.describe("webview_manager", function()
    -- Use require (not load_module) so windows persist across tests.
    -- webview_manager auto-inits on load, and load_module would wipe state.
    local wm = require("modules.ui.webview_manager")

    helpers.it("exports init", function()
      helpers.assert_true(type(wm.init) == "function")
    end)
    helpers.it("exports show", function()
      helpers.assert_true(type(wm.show) == "function")
    end)
    helpers.it("exports hide", function()
      helpers.assert_true(type(wm.hide) == "function")
    end)
    helpers.it("exports route_message", function()
      helpers.assert_true(type(wm.route_message) == "function")
    end)
    helpers.it("exports set_daemon_state", function()
      helpers.assert_true(type(wm.set_daemon_state) == "function")
    end)
    helpers.it("exports get_daemon_state", function()
      helpers.assert_true(type(wm.get_daemon_state) == "function")
    end)
    helpers.it("show registers a window", function()
      local ok = wm.show("action_picker", "fr")
      helpers.assert_true(ok)
      helpers.assert_true(wm.is_visible("action_picker"))
    end)
    helpers.it("hide closes a window", function()
      wm.show("action_picker", "fr")
      wm.hide("action_picker")
      helpers.assert_eq(wm.is_visible("action_picker"), false)
    end)
    helpers.it("set/get daemon state round-trips", function()
      local state = { engine = { loaded = true } }
      wm.set_daemon_state(state)
      local got = wm.get_daemon_state()
      helpers.assert_true(got.engine ~= nil)
      helpers.assert_true(got.engine.loaded)
    end)
    helpers.it("route_message rejects unknown bridge names", function()
      local result = wm.route_message("nonexistent_bridge", "hello")
      helpers.assert_eq(result, nil)
    end)
    helpers.it("route_message routes to action_picker handler", function()
      wm.show("action_picker", "fr")
      wm.set_daemon_state(build_mock_state())
      local result = wm.route_message("action_picker_bridge", { action = "search", query = "test" })
      helpers.assert_true(type(result) == "table", "route_message should return a table")
      helpers.assert_true(type(result.results) == "table", "result.results should be a table")
    end)
  end)

  -- ==========================================================================
  -- 2. action_picker_bridge
  -- ==========================================================================

  helpers.describe("action_picker_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.action_picker_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "action_picker_bridge")
    end)
    helpers.it("exports on_message", function()
      helpers.assert_true(type(handler.on_message) == "function")
    end)
    helpers.it("handles 'ready' string", function()
      local result = handler.on_message("ready", state)
      helpers.assert_eq(result, nil)
    end)
    helpers.it("handles 'search' action", function()
      local result = handler.on_message({ action = "search", query = "hotstrings" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.results) == "table")
      helpers.assert_true(#result.results > 0)
    end)
    helpers.it("handles 'execute' action", function()
      local result = handler.on_message({ action = "execute", command = "reload" }, state)
      helpers.assert_eq(result, nil)
    end)
    helpers.it("handles unknown action gracefully", function()
      local result = handler.on_message({ action = "invalid" }, state)
      helpers.assert_eq(result, nil)
    end)
  end)

  -- ==========================================================================
  -- 3. prompt_editor_bridge
  -- ==========================================================================

  helpers.describe("prompt_editor_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.prompt_editor_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "prompt_bridge")
    end)
    helpers.it("'ready' returns initial payload", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.enabled, true)
      helpers.assert_eq(result.current_model, "codellama")
      helpers.assert_eq(#result.available_models, 3)
      helpers.assert_eq(#result.triggers, 2)
    end)
    helpers.it("'set_model' action works", function()
      local result = handler.on_message({ action = "set_model", model = "llama3" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.model, "llama3")
    end)
    helpers.it("'toggle_enabled' action works", function()
      local result = handler.on_message({ action = "toggle_enabled" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.enabled ~= nil)
    end)
    helpers.it("'save_prompt' action works", function()
      local result = handler.on_message({ action = "save_prompt", title = "Test", content = "abc" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.saved)
    end)
  end)

  -- ==========================================================================
  -- 4. metrics_typing_bridge
  -- ==========================================================================

  helpers.describe("metrics_typing_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.metrics_typing_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "metrics_apps_bridge")
    end)
    helpers.it("'ready' returns full stats", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.keystrokes, 42)
      helpers.assert_eq(result.wpm, 35.5)
      helpers.assert_eq(result.words, 8)
      helpers.assert_true(type(result.apps) == "table")
    end)
    helpers.it("'refresh' returns same payload", function()
      local result = handler.on_message("refresh", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.keystrokes, 42)
    end)
    helpers.it("'reset' action works", function()
      local result = handler.on_message({ action = "reset" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.keystrokes, 42)  -- mock returns same value
    end)
    helpers.it("'pause' action works", function()
      local result = handler.on_message({ action = "pause" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.suppressed)
    end)
    helpers.it("'resume' action works", function()
      local result = handler.on_message({ action = "resume" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.suppressed, false)
    end)
    helpers.it("returns safe defaults when keylogger absent", function()
      local result = handler.on_message("ready", {})
      helpers.assert_eq(result.keystrokes, 0)
      helpers.assert_eq(result.wpm, 0)
    end)
  end)

  -- ==========================================================================
  -- 5. healthcheck_bridge
  -- ==========================================================================

  helpers.describe("healthcheck_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.healthcheck_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "healthcheck")
    end)
    helpers.it("'ready' returns full health status", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.modules) == "table")
      helpers.assert_eq(result.modules.engine.status, "ok")
      helpers.assert_eq(result.modules.keylogger.status, "ok")
      helpers.assert_eq(result.modules.keylogger.keystrokes, 42)
      helpers.assert_eq(result.modules.config.status, "ok")
      helpers.assert_eq(result.modules.config.mapping_count, 50)
      helpers.assert_eq(result.modules.config.parse_errors, 2)
      helpers.assert_eq(result.modules.llm.status, "ok")
      helpers.assert_eq(result.modules.llm.model, "codellama")
      helpers.assert_eq(result.modules.layout.layout, "qwerty")
    end)
    helpers.it("'refresh' returns same data", function()
      local result = handler.on_message("refresh", state)
      helpers.assert_eq(result.modules.engine.status, "ok")
    end)
    helpers.it("reports missing modules correctly", function()
      local empty = {}
      local result = handler.on_message("ready", empty)
      helpers.assert_eq(result.modules.engine.status, "missing")
      helpers.assert_eq(result.modules.keylogger.status, "missing")
      helpers.assert_eq(result.modules.llm.status, "missing")
    end)
    helpers.it("reports disabled LLM correctly", function()
      local st = build_mock_state()
      st.llm.is_enabled = function() return false end
      local result = handler.on_message("ready", st)
      helpers.assert_eq(result.modules.llm.status, "disabled")
    end)
  end)

  -- ==========================================================================
  -- 6. onboarding_bridge
  -- ==========================================================================

  helpers.describe("onboarding_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.onboarding_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsOnboarding")
    end)
    helpers.it("step=init returns current state", function()
      local result = handler.on_message({ step = "init" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.current_layout, "qwerty")
      helpers.assert_true(result.llm_available)
    end)
    helpers.it("step=layout returns accepted", function()
      local result = handler.on_message({ step = "layout", data = { layout = "azerty" } }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.accepted)
    end)
    helpers.it("step=language returns accepted", function()
      local result = handler.on_message({ step = "language", data = { locale = "en" } }, state)
      helpers.assert_true(result.accepted)
    end)
    helpers.it("step=llm_setup returns accepted", function()
      local result = handler.on_message({ step = "llm_setup", data = { model = "llama3" } }, state)
      helpers.assert_true(result.accepted)
    end)
    helpers.it("step=complete returns done", function()
      local result = handler.on_message({ step = "complete" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.done)
    end)
  end)

  -- ==========================================================================
  -- 7. hotstrings_config_bridge
  -- ==========================================================================

  helpers.describe("hotstrings_config_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.hotstrings_config_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hotstrings_config_bridge")
    end)
    helpers.it("'ready' returns groups + stats", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.groups) == "table")
      helpers.assert_eq(#result.groups, 3)
      helpers.assert_eq(result.groups[1].name, "accents")
      helpers.assert_true(result.groups[1].enabled)
      -- "code" should be disabled per mock.
      helpers.assert_eq(result.groups[3].name, "code")
      helpers.assert_eq(result.groups[3].enabled, false)
      helpers.assert_eq(result.mapping_count, 50)
      helpers.assert_eq(result.parse_errors, 2)
      helpers.assert_eq(result.config_dir, "/home/user/.config/ergopti/hotstrings")
    end)
    helpers.it("'toggle_group' returns refreshed data", function()
      local result = handler.on_message({ action = "toggle_group", group = "accents" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(#result.groups > 0)
    end)
    helpers.it("'reload' returns refreshed data", function()
      local result = handler.on_message({ action = "reload" }, state)
      helpers.assert_true(type(result) == "table")
    end)
    helpers.it("'add_hotstring' returns added", function()
      local result = handler.on_message({ action = "add_hotstring", trigger = "btw", replacement = "by the way", group = "english" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.added)
    end)
    helpers.it("'delete_hotstring' returns deleted", function()
      local result = handler.on_message({ action = "delete_hotstring", trigger = "btw" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.deleted)
    end)
  end)

end)
