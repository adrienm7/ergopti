--- tests/unit/meta/test_ui_bridge_handlers.lua

--- ==============================================================================
--- Tier 2 — Integration tests for UI bridge handlers + webview manager.
--- Tests all 14 bridge handlers and the webview_manager routing layer.
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
        get_dashboard_payload = function()
          return {
            metrics_manifest = {
              ["2026-07-18"] = {
                firefox = { chars = 20, time = 3000, app_time_ms = 120000, category = "Unknown" },
              },
            },
            app_icons = {},
            _prefetch_data = { historical = {}, today = {} },
            driver_meta = { os = "linux", heatmap_id = "sc_kb" },
          }
        end,
		get_range_payload = function(start_date, end_date, apps)
			return {
				historical = { c = { a = { c = 2, t = 0, e = 0, hs = 0, llm = 0, o = 0 } } },
				today = { firefox = { c = { b = { c = 3, t = 0, e = 0, hs = 0, llm = 0, o = 0 } } } },
			}
		end,
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
  -- Spy reader/writer for the hotstring persistence handlers. The reader seeds
  -- two sibling entries so a correct merge must preserve them; the writer
  -- captures the payload and can be told to fail, so we can assert the handlers
  -- propagate the real write result instead of hard-coding success.
  -- ==========================================================================

  local function make_spies(write_result, write_err)
    local captured = {}
    local reader = {
      parse = function(_path)
        return {
          meta = { description = "english" },
          sections_order = { "english" },
          sections = {
            english = {
              description = "english",
              entries = {
                { trigger = "omw", output = "on my way", is_word = true,
                  auto_expand = false, is_case_sensitive = false, final_result = false },
                { trigger = "ty", output = "thank you", is_word = true,
                  auto_expand = false, is_case_sensitive = false, final_result = false },
              },
            },
          },
        }
      end,
    }
    local writer = {
      write = function(path, data)
        captured.path = path
        captured.data = data
        return write_result, write_err
      end,
    }
    return reader, writer, captured
  end

  -- Injects the spies into package.loaded, loads the handler fresh so its lazy
  -- _get_reader/_get_writer resolve to the spies, runs fn(handler), then restores.
  local function with_spies(module_name, reader, writer, fn)
    local prev_r = package.loaded["toml_codec.reader"]
    local prev_w = package.loaded["toml_codec.writer"]
    package.loaded["toml_codec.reader"] = reader
    package.loaded["toml_codec.writer"] = writer
    local handler = helpers.load_module(module_name)
    local ok, err = pcall(fn, handler)
    package.loaded["toml_codec.reader"] = prev_r
    package.loaded["toml_codec.writer"] = prev_w
    if not ok then error(err, 0) end
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
    -- The picker's protocol is confirm/cancel/ready and none of them returns a
    -- value — the page is told things by an init(...) push, not by a reply. This
    -- case used to post {action="search"} and assert a result table, a protocol
    -- the page has never spoken; it passed because the handler had been written
    -- to the same invention.
    helpers.it("route_message reaches the action_picker handler", function()
      wm.show("action_picker", "fr")
      wm.set_daemon_state(build_mock_state())
      local confirmed = nil
      local handler = require("modules.ui.bridge_handlers.action_picker_bridge")
      handler.on_confirm = function(id) confirmed = id end
      wm.route_message("action_picker_bridge", { action = "confirm", id = "tab_new" })
      handler.on_confirm = nil
      helpers.assert_eq(confirmed, "tab_new",
        "a confirm must reach the handler with the id the user picked — routing that "
          .. "silently dropped it is exactly what made the Linux picker inert")
    end)
    -- Regression: the handler file was named personal_toml_editor.lua without
    -- the "_bridge" suffix that _load_handler() requires, so route_message()
    -- could never resolve it and silently returned nil. The file must be named
    -- personal_toml_editor_bridge.lua for on-demand routing to succeed.
    helpers.it("route_message loads the personal_toml_editor bridge on demand", function()
      wm.set_daemon_state(build_mock_state())
      local result = wm.route_message("personal_toml_editor", "ready")
      helpers.assert_true(type(result) == "table",
        "route_message must load and dispatch to the personal_toml_editor bridge")
      helpers.assert_true(type(result.toml_content) == "string",
        "personal_toml_editor payload must include toml_content")
    end)

    -- GTK operations are exported (native window creation).
    helpers.it("exports _create_gtk_window", function()
      helpers.assert_true(type(wm._create_gtk_window) == "function")
    end)
    helpers.it("exports _destroy_gtk_window", function()
      helpers.assert_true(type(wm._destroy_gtk_window) == "function")
    end)
    helpers.it("exports _focus_gtk_window", function()
      helpers.assert_true(type(wm._focus_gtk_window) == "function")
    end)
    helpers.it("_create_gtk_window no-ops safely without GTK", function()
      local ok = pcall(function()
        wm._create_gtk_window("test", "<html></html>", nil)
      end)
      helpers.assert_true(ok, "_create_gtk_window should not crash when lgi absent")
    end)
    helpers.it("_destroy_gtk_window no-ops safely without GTK", function()
      local ok = pcall(function()
        wm._destroy_gtk_window("nonexistent")
      end)
      helpers.assert_true(ok, "_destroy_gtk_window should not crash when lgi absent")
    end)
    helpers.it("_focus_gtk_window no-ops safely without GTK", function()
      local ok = pcall(function()
        wm._focus_gtk_window("nonexistent")
      end)
      helpers.assert_true(ok, "_focus_gtk_window should not crash when lgi absent")
    end)
    helpers.it("bring_to_front calls _focus_gtk_window", function()
      wm.show("action_picker", "fr")
      local ok = pcall(function() wm.bring_to_front("action_picker") end)
      helpers.assert_true(ok, "bring_to_front should not crash")
      wm.hide("action_picker")
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
    helpers.it("handles 'confirm' and passes the picked id on", function()
      local seen = nil
      handler.on_confirm = function(id) seen = id end
      handler.on_message({ action = "confirm", id = "app_switcher" }, state)
      handler.on_confirm = nil
      helpers.assert_eq(seen, "app_switcher", "the id the user picked must reach the caller")
    end)
    helpers.it("passes the two specials through unchanged", function()
      local seen = {}
      handler.on_confirm = function(id) seen[#seen + 1] = id end
      handler.on_message({ action = "confirm", id = "none" }, state)
      handler.on_message({ action = "confirm", id = "__native__" }, state)
      handler.on_confirm = nil
      helpers.assert_eq(seen[1], "none", "\"none\" is a real choice, not an absence")
      helpers.assert_eq(seen[2], "__native__",
        "and __native__ means \"leave the OS binding alone\" — the handler must not "
          .. "decide what either means")
    end)
    helpers.it("handles 'cancel'", function()
      local cancelled = false
      handler.on_cancel = function() cancelled = true end
      handler.on_message({ action = "cancel" }, state)
      handler.on_cancel = nil
      helpers.assert_true(cancelled, "dismissing the picker must reach the caller")
    end)
    helpers.it("build_init_payload matches the shape init(data) reads", function()
      local p = handler.build_init_payload({ current = "tab_new", allow_native = true })
      for _, key in ipairs({ "title", "label", "current", "allowNative", "nativeLabel",
                             "noneLabel", "searchPlaceholder", "noResults", "cancelLabel", "items" }) do
        helpers.assert_true(p[key] ~= nil, "init(data) reads data." .. key .. " — it must be present")
      end
      helpers.assert_eq(p.current, "tab_new", "the already-bound id must be carried through")
      helpers.assert_eq(p.allowNative, true, "and the native flag")
      helpers.assert_eq(type(p.items), "table", "items must be a list, even when empty")
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
  -- 4. metrics_apps_bridge
  -- ==========================================================================

  helpers.describe("metrics_apps_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.metrics_apps_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "metrics_apps_bridge")
    end)
    helpers.it("'ready' returns the shared metrics manifest", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.metrics_manifest) == "table")
      helpers.assert_eq(result.metrics_manifest["2026-07-18"].firefox.app_time_ms, 120000)
      helpers.assert_true(type(result.app_icons) == "table")
    end)
    helpers.it("'refresh' returns same payload", function()
      local result = handler.on_message("refresh", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.metrics_manifest["2026-07-18"].firefox.chars, 20)
    end)
    helpers.it("'reset' action works", function()
      local result = handler.on_message({ action = "reset" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.metrics_manifest) == "table")
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
      helpers.assert_true(type(result.metrics_manifest) == "table")
      helpers.assert_true(type(result.app_icons) == "table")
    end)
  end)

  -- ==========================================================================
  -- 5. metrics_typing_bridge
  -- ===========================================================================

  helpers.describe("metrics_typing_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.metrics_typing_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "metrics_typing_bridge")
    end)
    helpers.it("returns the same shared metrics contract on ready", function()
      local result = handler.on_message({ action = "ready" }, state)
      helpers.assert_true(type(result.metrics_manifest) == "table")
      helpers.assert_eq(result.metrics_manifest["2026-07-18"].firefox.chars, 20)
    end)
    helpers.it("returns nil for unknown actions", function()
      helpers.assert_eq(handler.on_message("unknown", state), nil)
    end)
    helpers.it("returns a selected n-gram range over the native Linux bridge", function()
      local result = handler.on_message({
        action = "range", start_date = "2026-07-01", end_date = "2026-07-18", apps = { "firefox" },
      }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result._prefetch_data.historical.c.a.c, 2)
      helpers.assert_eq(result._prefetch_data.today.firefox.c.b.c, 3)
      helpers.assert_eq(result.metrics_manifest["2026-07-18"].firefox.chars, 20)
    end)
  end)

  -- ===========================================================================
  -- 6. healthcheck_bridge
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
  -- 6b. Locale routing (i18n) — dashboards follow the persisted locale
  -- ==========================================================================

  helpers.describe("bridge locale routing (i18n)", function()

    -- Stubs lib.i18n.get_locale, runs fn, then restores package.loaded so the
    -- stub never leaks into later test files.
    local function with_locale_module(mod, fn)
      local prev = package.loaded["lib.i18n"]
      package.loaded["lib.i18n"] = mod
      local ok, err = pcall(fn)
      package.loaded["lib.i18n"] = prev
      if not ok then error(err, 0) end
    end

    helpers.it("healthcheck payload uses the persisted locale, not a hardcoded 'fr'", function()
      local hc = helpers.load_module("modules.ui.bridge_handlers.healthcheck_bridge")
      with_locale_module({ get_locale = function() return "de" end }, function()
        local result = hc.on_message("ready", build_mock_state())
        helpers.assert_eq(result.locale, "de",
          "healthcheck must render in the user's locale (de), not the hardcoded 'fr'")
      end)
    end)

    helpers.it("onboarding init uses the persisted locale, not a hardcoded 'fr'", function()
      local ob = helpers.load_module("modules.ui.bridge_handlers.onboarding_bridge")
      with_locale_module({ get_locale = function() return "de" end }, function()
        local result = ob.on_message({ step = "init" }, build_mock_state())
        helpers.assert_eq(result.current_locale, "de",
          "onboarding must open in the user's locale (de), not the hardcoded 'fr'")
      end)
    end)

    helpers.it("falls back to 'fr' when lib.i18n resolves no locale", function()
      local hc = helpers.load_module("modules.ui.bridge_handlers.healthcheck_bridge")
      with_locale_module({ get_locale = function() return nil end }, function()
        local result = hc.on_message("ready", build_mock_state())
        helpers.assert_eq(result.locale, "fr",
          "must fall back to 'fr' when no locale resolves (fail-safe default)")
      end)
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
    helpers.it("'add_hotstring' merges into the existing group and reports the write result", function()
      local reader, writer, captured = make_spies(true)
      with_spies("modules.ui.bridge_handlers.hotstrings_config_bridge", reader, writer, function(h)
        local result = h.on_message({ action = "add_hotstring", trigger = "btw", replacement = "by the way", group = "english" }, state)
        helpers.assert_true(result.added, "a successful write must report added = true")
        -- Root cause: a single-entry payload used to overwrite the whole group,
        -- destroying the two seeded siblings. Merge must preserve them.
        local entries = captured.data.sections.english.entries
        helpers.assert_eq(#entries, 3, "merge must preserve the pre-existing siblings")
        local triggers = {}
        for _, e in ipairs(entries) do triggers[e.trigger] = true end
        helpers.assert_true(triggers.omw and triggers.ty, "seeded 'omw'/'ty' must survive the add")
        helpers.assert_true(triggers.btw, "the new 'btw' must be persisted")
      end)
    end)
    helpers.it("'add_hotstring' reports failure when the write fails", function()
      local reader, writer = make_spies(false, "disk full")
      with_spies("modules.ui.bridge_handlers.hotstrings_config_bridge", reader, writer, function(h)
        local result = h.on_message({ action = "add_hotstring", trigger = "btw", replacement = "by the way", group = "english" }, state)
        helpers.assert_eq(result.added, false, "a failed write must not report success")
      end)
    end)
    helpers.it("'delete_hotstring' removes only the target and keeps siblings", function()
      local reader, writer, captured = make_spies(true)
      with_spies("modules.ui.bridge_handlers.hotstrings_config_bridge", reader, writer, function(h)
        local result = h.on_message({ action = "delete_hotstring", trigger = "omw", group = "english" }, state)
        helpers.assert_true(result.deleted)
        -- Root cause: delete used to write an empty entry list, wiping the group.
        local entries = captured.data.sections.english.entries
        helpers.assert_eq(#entries, 1, "only the target entry may be removed")
        helpers.assert_eq(entries[1].trigger, "ty", "the sibling 'ty' must survive the delete")
      end)
    end)
  end)

  -- ==========================================================================
  -- 8. changelog_bridge
  -- ==========================================================================

  helpers.describe("changelog_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.changelog_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "changelog_bridge")
    end)
    helpers.it("exports on_message", function()
      helpers.assert_true(type(handler.on_message) == "function")
    end)
    helpers.it("'ready' returns initial payload", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.releases) == "table")
      helpers.assert_true(type(result.repo_url) == "string")
      helpers.assert_true(type(result.version) == "string")
    end)
    helpers.it("'refresh' returns same payload", function()
      local result = handler.on_message("refresh", state)
      helpers.assert_true(type(result) == "table")
    end)
    helpers.it("handles 'close' string", function()
      local result = handler.on_message("close", state)
      helpers.assert_eq(result, nil)
    end)
  end)

  -- ==========================================================================
  -- 9. dl_bridge
  -- ==========================================================================

  helpers.describe("dl_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.dl_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "dl_bridge")
    end)
    helpers.it("'ready' returns initial payload", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.downloads) == "table")
    end)
    helpers.it("handles 'cancel' action", function()
      local result = handler.on_message({ action = "cancel", id = "dl_1" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.cancelled)
    end)
    helpers.it("handles 'retry' action", function()
      local result = handler.on_message({ action = "retry", url = "https://example.com/asset.zip" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.started)
    end)
  end)

  -- ==========================================================================
  -- 10. hotstring_editor_bridge
  -- ==========================================================================

  helpers.describe("hotstring_editor_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.hotstring_editor_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsEditor")
    end)
    helpers.it("'ready' returns initial payload", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.groups) == "table")
      helpers.assert_true(type(result.hotstrings) == "table")
    end)
    helpers.it("'save' merges into the existing group and reports the write result", function()
      local reader, writer, captured = make_spies(true)
      with_spies("modules.ui.bridge_handlers.hotstring_editor_bridge", reader, writer, function(h)
        local result = h.on_message({ action = "save", trigger = "btw", replacement = "by the way", group = "english" }, state)
        helpers.assert_true(result.saved, "a successful write must report saved = true")
        local entries = captured.data.sections.english.entries
        helpers.assert_eq(#entries, 3, "merge must preserve the pre-existing siblings")
        local triggers = {}
        for _, e in ipairs(entries) do triggers[e.trigger] = true end
        helpers.assert_true(triggers.omw and triggers.ty, "seeded 'omw'/'ty' must survive the save")
        helpers.assert_true(triggers.btw, "the new 'btw' must be persisted")
      end)
    end)
    helpers.it("'save' reports failure when the write fails", function()
      local reader, writer = make_spies(false, "disk full")
      with_spies("modules.ui.bridge_handlers.hotstring_editor_bridge", reader, writer, function(h)
        local result = h.on_message({ action = "save", trigger = "btw", replacement = "by the way", group = "english" }, state)
        helpers.assert_eq(result.saved, false, "a failed write must not report success")
      end)
    end)
    helpers.it("'delete' removes only the target and keeps siblings", function()
      local reader, writer, captured = make_spies(true)
      with_spies("modules.ui.bridge_handlers.hotstring_editor_bridge", reader, writer, function(h)
        local result = h.on_message({ action = "delete", trigger = "omw", group = "english" }, state)
        helpers.assert_true(result.deleted)
        local entries = captured.data.sections.english.entries
        helpers.assert_eq(#entries, 1, "only the target entry may be removed")
        helpers.assert_eq(entries[1].trigger, "ty", "the sibling 'ty' must survive the delete")
      end)
    end)
    helpers.it("handles 'duplicate' action", function()
      local result = handler.on_message({ action = "duplicate", trigger = "btw" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.duplicated)
    end)
  end)

  -- ==========================================================================
  -- 11. paths_editor_bridge
  -- ==========================================================================

  helpers.describe("paths_editor_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.paths_editor_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsPaths")
    end)
    helpers.it("'ready' returns paths payload", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.paths) == "table")
      helpers.assert_true(type(result.paths.config_dir) == "string")
      helpers.assert_eq(result.platform, "linux")
    end)
    helpers.it("handles 'save' action", function()
      local result = handler.on_message({ action = "save", key = "config_dir", value = "/tmp/test" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.saved)
    end)
  end)

  -- ==========================================================================
  -- 12. personal_info_editor_bridge
  -- ==========================================================================

  helpers.describe("personal_info_editor_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.personal_info_editor_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsPersonalInfo")
    end)
    helpers.it("'ready' returns info payload", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.info) == "table")
      helpers.assert_true(type(result.info.first_name) == "string")
      helpers.assert_true(type(result.trigger_char) == "string")
    end)
    helpers.it("handles 'save' action for single field", function()
      local result = handler.on_message({ action = "save", field = "first_name", value = "Jean" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.saved)
      helpers.assert_eq(result.field, "first_name")
    end)
    helpers.it("handles 'save_all' action", function()
      local result = handler.on_message({ action = "save_all", info = { first_name = "Jean" } }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.saved)
    end)
  end)

  -- ==========================================================================
  -- 13. model_browser_bridge
  -- ==========================================================================

  helpers.describe("model_browser_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.model_browser_bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "model_browser_bridge")
    end)
    helpers.it("'ready' returns model list", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(type(result.models) == "table")
      helpers.assert_eq(#result.models, 3)
      helpers.assert_eq(result.current_model, "codellama")
      helpers.assert_eq(result.provider, "ollama")
      helpers.assert_true(result.enabled)
    end)
    helpers.it("handles 'select' action", function()
      local result = handler.on_message({ action = "select", model = "llama3" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.model, "llama3")
    end)
    helpers.it("handles 'download' action", function()
      local result = handler.on_message({ action = "download", model = "mistral" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_true(result.downloading)
      helpers.assert_eq(result.model, "mistral")
    end)
    helpers.it("handles 'delete' action", function()
      local result = handler.on_message({ action = "delete", model = "mistral" }, state)
      helpers.assert_true(type(result) == "table")
      helpers.assert_eq(result.deleted, false)  -- honest: not implemented
      helpers.assert_eq(result.model, "mistral")
    end)
  end)

  -- ==========================================================================
  -- 14. token_bridge
  -- ==========================================================================

  helpers.describe("token_bridge", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.token_bridge")
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

  helpers.describe("personal_toml_editor", function()
    local handler = helpers.load_module("modules.ui.bridge_handlers.personal_toml_editor_bridge")
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
