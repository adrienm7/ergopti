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
        -- Flat functions, matching how hotstrings_config actually defines them.
        -- This mock used to take a leading `self` because the bridge called
        -- through `:` — so `is_group_enabled` received the module as its group
        -- name and answered "enabled" for everything, and `toggle_group`
        -- silently no-opped on its own string guard. The mock was shaped to the
        -- bug, which is why the bridge's own test could never see it.
        get_groups     = function() return { "accents", "math", "code" } end,
        is_group_enabled = function(g) return g ~= "code" end,
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
                  auto_expand = false, is_case_sensitive = true, final_result = false,
                  is_case_sensitive_strict = true },
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
    local wm = require("ui.webview_manager")

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
			helpers.assert_true(wm.hide("action_picker"))
      helpers.assert_eq(wm.is_visible("action_picker"), false)
    end)
		helpers.it("a GTK delete-event retires the page context before reopen (lnx-057)", function()
			helpers.assert_true(wm.show("metrics_apps", "en"))
			local first_epoch = wm.current_epoch("metrics_apps")
			helpers.assert_true(wm._handle_delete_event("metrics_apps", first_epoch),
				"the current native close must destroy its page context, not hide its poller")
			helpers.assert_eq(wm.current_epoch("metrics_apps"), nil)

			helpers.assert_true(wm.show("metrics_apps", "en"))
			local replacement_epoch = wm.current_epoch("metrics_apps")
			helpers.assert_true(replacement_epoch > first_epoch,
				"reopening must create one fresh page context")
			helpers.assert_eq(wm._handle_delete_event("metrics_apps", first_epoch), false,
				"a late close callback must not retire the replacement context")
			helpers.assert_eq(wm.current_epoch("metrics_apps"), replacement_epoch)
			helpers.assert_true(wm.hide("metrics_apps", replacement_epoch))
		end)
		helpers.it("hide releases only the input ownership of that page epoch", function()
			local gate = helpers.load_module("infra.input_capture_gate").new()
			helpers.assert_true(wm.show("hotstring_editor", "en"))
			local epoch = wm.current_epoch("hotstring_editor")
			helpers.assert_true(type(epoch) == "number")
			wm.set_daemon_state({ input_capture_gate = gate })
			local stale_message = wm.route_message("hotstring_editor", "hsEditor", {
				action = "window_focus", data = { focused = true },
			}, epoch - 1)
			helpers.assert_eq(stale_message, nil)
			helpers.assert_eq(gate.blocks_text(), false,
				"an old page must not reach the replacement page's bridge state")
			helpers.assert_true(gate.acquire("hotstring_editor", epoch))
			wm.hide("hotstring_editor")
			helpers.assert_eq(gate.blocks_text(), false,
				"native hide/destroy must not strand global input inhibition")

			helpers.assert_true(gate.acquire("hotstring_editor", epoch + 1))
			helpers.assert_eq(wm._release_app_ownership("hotstring_editor", epoch), false)
			helpers.assert_true(gate.blocks_text(),
				"a late lifecycle callback from the old page must not release its replacement")
			gate.release_all()
			wm.set_daemon_state(build_mock_state())
		end)
		helpers.it("routes a page close through its registered app identity", function()
			helpers.assert_true(wm.show("hotstrings_config_window", "en"))
			helpers.assert_true(wm.is_visible("hotstrings_config_window"))
			wm.set_daemon_state(build_mock_state())
			local epoch = wm.current_epoch("hotstrings_config_window")
			local stale = wm.route_message("hotstrings_config_window",
				"hotstrings_config_bridge", { action = "close" }, epoch - 1)
			helpers.assert_eq(stale, nil)
			helpers.assert_true(wm.is_visible("hotstrings_config_window"),
				"a stale page callback cannot close its replacement")
			local result = wm.route_message("hotstrings_config_window",
				"hotstrings_config_bridge", { action = "close" })
			helpers.assert_true(result.closed)
			helpers.assert_eq(wm.is_visible("hotstrings_config_window"), false)
			helpers.assert_true(wm.show("hotstrings_config_window", "en"),
				"a closed settings page must reopen with a fresh owned window")
			helpers.assert_true(wm.is_visible("hotstrings_config_window"))
			wm.hide("hotstrings_config_window")
		end)
    helpers.it("set/get daemon state round-trips", function()
      local state = { engine = { loaded = true } }
      wm.set_daemon_state(state)
      local got = wm.get_daemon_state()
      helpers.assert_true(got.engine ~= nil)
      helpers.assert_true(got.engine.loaded)
    end)
    helpers.it("route_message rejects unknown bridge names", function()
      local result = wm.route_message("action_picker", "nonexistent_bridge", "hello")
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
      local handler = require("ui.action_picker.bridge")
      handler.on_confirm = function(id) confirmed = id end
      wm.route_message("action_picker", "action_picker_bridge",
        { action = "confirm", id = "tab_new" })
      handler.on_confirm = nil
      helpers.assert_eq(confirmed, "tab_new",
        "a confirm must reach the handler with the id the user picked — routing that "
          .. "silently dropped it is exactly what made the Linux picker inert")
    end)
    helpers.it("a metrics page cannot invoke or read a foreign privileged bridge", function()
      wm.set_daemon_state(build_mock_state())
      local prompt_handler = require("ui.prompt_editor.bridge")
      local original = prompt_handler.on_message
      local foreign_calls = 0
      prompt_handler.on_message = function()
        foreign_calls = foreign_calls + 1
        return { secret = "must-not-leak" }
      end
      local result = wm.route_message("metrics_apps", "prompt_bridge",
        { action = "save_prompt", content = "hostile" })
      prompt_handler.on_message = original
      helpers.assert_eq(result, nil, "a foreign bridge must yield no response")
      helpers.assert_eq(foreign_calls, 0, "a foreign handler must never be invoked")
    end)

		helpers.it("a hostile page reads no metrics and mutates no collection state", function()
			local state = build_mock_state()
			local reads = 0
			local resets = 0
			state.keylogger.export_metrics = function()
				reads = reads + 1
				return { secret = true }
			end
			state.keylogger.reset_session = function() resets = resets + 1 end
			wm.set_daemon_state(state)

			local stolen = wm.route_message("action_picker", "metrics_typing_bridge",
				{ action = "range", start_date = "2026-01-01", end_date = "2026-12-31" })
			local reset_reply = wm.route_message("metrics_typing", "metrics_apps_bridge",
				{ action = "reset" })

			helpers.assert_eq(stolen, nil, "a foreign metrics bridge yields no response")
			helpers.assert_eq(reset_reply, nil, "a foreign mutation bridge yields no response")
			helpers.assert_eq(reads, 0, "the metrics collection was not read")
			helpers.assert_eq(resets, 0, "the metrics collection was not reset")
		end)

    helpers.it("the numeric prompt owns the bridge omitted by the old global list", function()
      local result = wm.route_message("numeric_prompt", "numeric_prompt_bridge", "cancel")
      helpers.assert_true(type(result) == "table",
        "the page-specific registry must include numeric_prompt_bridge")
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
      -- Called directly: a raise fails with the real error. The claim is the
      -- no-op — with no GTK the window must not be registered, or every later
      -- show/focus call addresses a window that does not exist.
      wm._create_gtk_window("test", "<html></html>", nil)
      helpers.assert_true(wm.is_open == nil or wm.is_open("test") ~= true,
        "no GTK means no window, and no window means nothing registered")
    end)
    helpers.it("_destroy_gtk_window no-ops safely without GTK", function()
      wm._destroy_gtk_window("nonexistent")
      helpers.assert_true(wm.is_open == nil or wm.is_open("nonexistent") ~= true,
        "destroying a window that was never created must leave nothing behind")
    end)
    helpers.it("_focus_gtk_window no-ops safely without GTK", function()
      wm._focus_gtk_window("nonexistent")
      helpers.assert_true(wm.is_open == nil or wm.is_open("nonexistent") ~= true,
        "focusing a window that does not exist must not conjure one")
    end)
    helpers.it("bring_to_front calls _focus_gtk_window", function()
      wm.show("action_picker", "fr")
      wm.bring_to_front("action_picker")
      helpers.assert_eq(type(wm.bring_to_front), "function",
        "bring_to_front must survive being called with no GTK — it is bound to a menu "
          .. "row the user can click on any desktop")
      wm.hide("action_picker")
    end)
  end)

  -- ==========================================================================
  -- 2. action_picker_bridge
  -- ==========================================================================

  helpers.describe("action_picker_bridge", function()
    local handler = helpers.load_module("ui.action_picker.bridge")
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
			helpers.assert_true(#p.items > 10,
				"the production action registry must populate the picker, not a missing compatibility module")
			local found = false
			for _, item in ipairs(p.items) do
				if item.id == "app_switcher" and type(item.label) == "string" and item.label ~= "" then
					found = true
				end
				helpers.assert_true(item.id ~= "none",
					"the translated no-op row is owned by the page and must not be duplicated")
			end
			helpers.assert_true(found,
				"a supported shared action and its label must reach the picker payload")
    end)
    helpers.it("handles unknown action gracefully", function()
      local result = handler.on_message({ action = "invalid" }, state)
      helpers.assert_eq(result, nil)
    end)

    -- The picker is told what to render by an init(...) push after it reports
    -- ready — there is no reply channel it could learn it from. For a long time
    -- "ready" was only logged, so the page opened, said ready, and rendered an
    -- empty list forever. Nothing failed: build_init_payload was correct and
    -- tested, the handler answered every message, and both halves looked done.
    --
    -- Asserting on the emitted JAVASCRIPT, not on the payload function, is the
    -- point. A test that calls build_init_payload() and checks its keys is the
    -- test that already existed while the channel did not.
    local function capture_push(opts, body)
      local wm_mod = helpers.load_module("ui.webview_manager")
      local original = wm_mod.eval_js
      local seen = {}
      wm_mod.eval_js = function(app, js)
        seen[#seen + 1] = { app = app, js = js }
        return true
      end
      handler.pending_opts = opts
      local ok, err = pcall(body, seen)
      wm_mod.eval_js = original
      handler.pending_opts = nil
      if not ok then error(err, 0) end
      return seen
    end

    helpers.it("a 'ready' table pushes init(...) into the picker's own window", function()
      capture_push({ current = "tab_new", allow_native = true }, function(seen)
        handler.on_message({ action = "ready" }, state)
        helpers.assert_eq(#seen, 1, "exactly one push per ready — no push, or two, is a bug")
        helpers.assert_eq(seen[1].app, "action_picker",
          "the push must be addressed to the picker's window, not broadcast")
        helpers.assert_true(seen[1].js:sub(1, 5) == "init(",
          "the page defines init(data); anything else evaluates to nothing and says so nowhere")
        helpers.assert_true(seen[1].js:find("tab_new", 1, true) ~= nil,
          "pending_opts must reach the payload — a push carrying defaults renders the "
            .. "wrong current selection and looks like the user's binding was lost")
        helpers.assert_true(seen[1].js:find("searchPlaceholder", 1, true) ~= nil,
          "the i18n strings must be in the pushed JSON, not left for the page to invent")
      end)
    end)

    helpers.it("a bare 'ready' string pushes init(...) too", function()
      -- Two code paths reach "ready": the JSON table and the host_bridge
      -- fallback that delivers the bare word. Wiring one and not the other is a
      -- picker that works or not depending on how the page happened to post.
      capture_push(nil, function(seen)
        handler.on_message("ready", state)
        helpers.assert_eq(#seen, 1, "the bare-string path must push as well")
        helpers.assert_true(seen[1].js:sub(1, 5) == "init(")
      end)
    end)

    helpers.it("confirm and cancel push nothing", function()
      capture_push(nil, function(seen)
        handler.on_message({ action = "confirm", id = "tab_new" }, state)
        handler.on_message({ action = "cancel" }, state)
        helpers.assert_eq(#seen, 0,
          "init() is a first-render push; re-pushing it on every message would reset "
            .. "the search box under the user's fingers")
      end)
    end)
  end)

  -- ==========================================================================
  -- 3. prompt_editor_bridge
  -- ==========================================================================

  helpers.describe("prompt_editor_bridge", function()
    local handler = helpers.load_module("ui.prompt_editor.bridge")
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
    local handler = helpers.load_module("ui.metrics_apps.bridge")
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
    local handler = helpers.load_module("ui.metrics_typing.bridge")
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
				action = "range", request_id = 41,
				start_date = "2026-07-01", end_date = "2026-07-18", apps = { "firefox" },
			}, state)
			helpers.assert_true(type(result) == "table")
			helpers.assert_eq(result._prefetch_data.historical.c.a.c, 2)
			helpers.assert_eq(result._prefetch_data.today.firefox.c.b.c, 3)
			helpers.assert_eq(result.metrics_manifest["2026-07-18"].firefox.chars, 20)
			helpers.assert_eq(result.range_request_id, 41,
				"range replies must preserve the UI request owner across the native bridge")
		end)
  end)

  -- ===========================================================================
  -- 6. healthcheck_bridge
  -- ==========================================================================

  helpers.describe("healthcheck_bridge", function()
    local handler = helpers.load_module("ui.healthcheck.bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "healthcheck")
    end)
    -- These cases used to assert a `modules` table of this bridge's own
    -- invention. The shared page reads `version, sys, uptime_sec, warn_count,
    -- err_count, ports_validated, failed_adapters, last_error, recent_issues,
    -- pause_state, keylogger, llm, layout, hotstrings, logs, config` and found
    -- none of them, so the window rendered empty while both sides reported
    -- success. The assertion is now the shared contract itself, which is
    -- strictly more than the old shape checked: sixteen named fields instead of
    -- five invented ones.
    local Snapshot = helpers.load_module("healthcheck.snapshot")

    helpers.it("'ready' answers in the shape the shared page reads", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(type(result) == "table")
      local ok, missing = Snapshot.validate_snapshot(result)
      helpers.assert_true(ok,
        "the snapshot is missing " .. table.concat(missing or {}, ", ")
          .. " — the page reads these by name and renders nothing for the ones "
          .. "it cannot find, which looks like a daemon with no diagnostics "
          .. "rather than two halves speaking different languages")
    end)

    helpers.it("carries the live figures it was given", function()
      local result = handler.on_message("ready", state)
      helpers.assert_eq(result.keylogger.events_session, 42,
        "the keystroke count must survive the reshape")
      helpers.assert_eq(result.llm.model, "codellama")
      helpers.assert_eq(result.hotstrings.personal_count, 50,
        "the mapping count moved from modules.config to hotstrings, which is "
          .. "where the page looks for it")
      helpers.assert_eq(result.layout.ergopti_base, "qwerty")
    end)

    helpers.it("'refresh' answers in the same shape", function()
      local result = handler.on_message("refresh", state)
      helpers.assert_true((Snapshot.validate_snapshot(result)),
        "a refresh that answers a different shape is a window that empties "
          .. "itself the first time the user asks it to update")
    end)

    helpers.it("still answers the contract with nothing wired at all", function()
      local result = handler.on_message("ready", {})
      local ok, missing = Snapshot.validate_snapshot(result)
      helpers.assert_true(ok,
        "an unwired daemon is exactly when this window is read, so it must not "
          .. "be the case that answers only arrive when nothing is wrong: "
          .. table.concat(missing or {}, ", "))
      helpers.assert_true(#result.failed_adapters > 0,
        "and it must SAY that nothing is wired, rather than reporting an empty "
          .. "failure list that reads as a clean bill of health")
    end)

    helpers.it("names the parts that are wired and the parts that are not", function()
      local result = handler.on_message("ready", state)
      helpers.assert_true(#result.loaded_adapters > 0,
        "a report listing no loaded parts on a fully wired daemon is the empty "
          .. "window in a different disguise")
    end)
  end)

  -- ==========================================================================
  -- 6. onboarding_bridge
  -- ==========================================================================

  helpers.describe("onboarding_bridge", function()
    local handler = helpers.load_module("ui.onboarding.bridge")

		local function onboarding_state()
			local values = {
				categories = { accents = true, code = false },
				magic_key = "★", magic_custom = false,
				metrics = false, gestures = false, locale = "en",
				config_dir = "/tmp/ergopti-default",
			}
			local captured = { pushes = {}, writes = {}, hidden = 0, changed = 0 }
			local state = {
				layout = "qwerty",
				config = {
					get_categories = function() return { accents = {}, code = {} } end,
					is_group_enabled = function(id) return values.categories[id] end,
					enable_all = function()
						values.categories.accents = true; values.categories.code = true
						return 1
					end,
					disable_all = function()
						values.categories.accents = false; values.categories.code = false
						return 1
					end,
					enable_group = function(id) values.categories[id] = true; return true end,
					disable_group = function(id) values.categories[id] = false; return true end,
				},
				magic_key = {
					get = function() return values.magic_key end,
					is_customised = function() return values.magic_custom end,
					validate = function(value) return type(value) == "string" and value ~= "" end,
					set = function(value)
						values.magic_key = value; values.magic_custom = value ~= "★"; return true
					end,
					reset = function() values.magic_key = "★"; values.magic_custom = false; return true end,
				},
				keylogger = {
					is_enabled = function() return values.metrics end,
					set_enabled = function(value) values.metrics = value; return true end,
				},
				gestures = {
					is_enabled = function() return values.gestures end,
					set_enabled = function(value) values.gestures = value; return true end,
				},
				i18n = {
					get_locale = function() return values.locale end,
					list_locales = function() return { "en", "fr" } end,
					get = function(key) return key end,
					set_locale = function(value) values.locale = value; return true end,
				},
				config_paths = {
					default_config_dir = function() return "/tmp/ergopti-default" end,
					get_config_dir = function() return values.config_dir end,
					set_config_dir = function(value) values.config_dir = value; return true end,
					data = function(rel) return "/tmp/data/" .. rel end,
				},
				writer = {
					batch_write = function(path, updates)
						captured.writes[#captured.writes + 1] = { path = path, updates = updates }
						return true
					end,
				},
				webview_manager = {
					eval_js = function(app, code)
						captured.pushes[#captured.pushes + 1] = { app = app, code = code }
						return true
					end,
					hide = function(app)
						helpers.assert_eq(app, "onboarding")
						captured.hidden = captured.hidden + 1
					end,
				},
				on_config_changed = function() captured.changed = captured.changed + 1 end,
			}
			return state, values, captured
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
			helpers.assert_eq(result.data.answers.use_ergopti, false,
				"one disabled category must preselect the global answer as off")
			helpers.assert_eq(result.data.answers.magic_key, "★")
			helpers.assert_true(#result.data.locales >= 21)
			helpers.assert_contains(captured.pushes[1].code, "window.initData")
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

		helpers.it("preserves explicit false values while loading an existing config", function()
			local answers = handler._answers_from_config({
				hotstrings = { enabled = false, trigger_char = ";" },
				metrics = { enabled = false },
				gestures = { enabled = false },
			}, "/tmp/existing")
			helpers.assert_eq(answers, {
				config_dir = "/tmp/existing", use_ergopti = false, magic_key = ";",
				use_metrics = false, use_gestures = false,
			})
		end)

		helpers.it("returns a native folder picker choice through setConfigDir", function()
			local state, _, captured = onboarding_state()
			state.shell = {
				has_command = function(binary) return binary == "zenity" end,
				quote = function(value) return "'" .. value .. "'" end,
				exec_line = function() return "/tmp/picked/" end,
			}
			local result = handler.on_message({ action = "pickConfigDir", current = "" }, state)
			helpers.assert_true(result.picked)
			helpers.assert_eq(result.path, "/tmp/picked")
			helpers.assert_contains(captured.pushes[1].code, "window.setConfigDir")
		end)

		helpers.it("commits every answer and closes only after the canonical write", function()
			local state, values, captured = onboarding_state()
			local result = handler.on_message({ action = "finish", answers = {
				locale = "fr", use_ergopti = true, magic_key = ";",
				config_dir = "/tmp/ergopti-custom/", use_metrics = true, use_gestures = true,
			} }, state)
			helpers.assert_true(result.done)
			helpers.assert_true(values.categories.accents and values.categories.code)
			helpers.assert_eq(values.magic_key, ";")
			helpers.assert_true(values.metrics and values.gestures)
			helpers.assert_eq(values.locale, "fr")
			helpers.assert_eq(values.config_dir, "/tmp/ergopti-custom")
			helpers.assert_eq(captured.writes[1].path, "/tmp/ergopti-custom/config.toml")
			helpers.assert_eq(captured.writes[1].updates[5], {
				section = "script", key = "onboarding_done", value = true,
			})
			helpers.assert_eq(captured.hidden, 1)
			helpers.assert_eq(captured.changed, 1)
		end)

		helpers.it("rejects malformed finish data without writing or closing", function()
			local state, _, captured = onboarding_state()
			local result = handler.on_message({ action = "finish", answers = {
				locale = "en", use_ergopti = "false", magic_key = "★",
				config_dir = "relative", use_metrics = false, use_gestures = false,
			} }, state)
			helpers.assert_eq(result.done, false)
			helpers.assert_eq(#captured.writes, 0)
			helpers.assert_eq(captured.hidden, 0)
		end)

		helpers.it("restores every live authority when the final config write fails", function()
			local state, values, captured = onboarding_state()
			state.writer.batch_write = function() return false, "disk full" end
			local result = handler.on_message({ action = "finish", answers = {
				locale = "fr", use_ergopti = true, magic_key = ";",
				config_dir = "/tmp/ergopti-custom", use_metrics = true, use_gestures = true,
			} }, state)
			helpers.assert_eq(result.done, false)
			helpers.assert_eq(values.categories, { accents = true, code = false })
			helpers.assert_eq(values.magic_key, "★")
			helpers.assert_eq(values.magic_custom, false)
			helpers.assert_eq(values.metrics, false)
			helpers.assert_eq(values.gestures, false)
			helpers.assert_eq(values.locale, "en")
			helpers.assert_eq(values.config_dir, "/tmp/ergopti-default")
			helpers.assert_eq(captured.hidden, 0,
				"a failed transaction must leave the wizard open for retry")
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

  helpers.describe("bridge locale routing (i18n)", function()

    -- Stubs lib.i18n.get_locale, runs fn, then restores package.loaded so the
    -- stub never leaks into later test files.
    local function with_locale_module(mod, fn)
      local prev = package.loaded["infra.i18n"]
      package.loaded["infra.i18n"] = mod
      local ok, err = pcall(fn)
      package.loaded["infra.i18n"] = prev
      if not ok then error(err, 0) end
    end

    helpers.it("healthcheck payload uses the persisted locale, not a hardcoded 'fr'", function()
      local hc = helpers.load_module("ui.healthcheck.bridge")
      with_locale_module({ get_locale = function() return "de" end }, function()
        local result = hc.on_message("ready", build_mock_state())
        helpers.assert_eq(result.locale, "de",
          "healthcheck must render in the user's locale (de), not the hardcoded 'fr'")
      end)
    end)

    helpers.it("falls back to 'fr' when lib.i18n resolves no locale", function()
      local hc = helpers.load_module("ui.healthcheck.bridge")
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
    local handler = helpers.load_module("ui.hotstrings_config_window.bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hotstrings_config_bridge")
    end)
    helpers.it("'ready' pushes the keys the settings page renders from", function()
      -- This asserted `{groups = {{name, enabled}}, mapping_count, parse_errors,
      -- config_dir}` — four keys, and the page destructures none of them. It
      -- walks state.categories and state.presets, and its group selector wants
      -- {key, label}. So the suite was green while the window drew an empty page
      -- with a selector full of blank entries.
      local pushed = {}
      local manager = package.loaded["ui.webview_manager"]
      package.loaded["ui.webview_manager"] = {
        eval_js = function(app, js) pushed[#pushed + 1] = { app = app, js = js }; return true end,
      }
      handler.on_message("ready", state)
      package.loaded["ui.webview_manager"] = manager

      helpers.assert_eq(#pushed, 1, "exactly one push into the page")
      helpers.assert_eq(pushed[1].app, "hotstrings_config_window",
        "into the page's own directory name")
      for _, key in ipairs({ "categories", "groups", "presets", "global_default_delay_ms" }) do
        helpers.assert_true(pushed[1].js:find('"' .. key .. '"', 1, true) ~= nil,
          "carrying " .. key .. ", which script.js reads")
      end
      helpers.assert_true(pushed[1].js:find('"mapping_count"', 1, true) == nil,
        "and not the four keys it never read")
    end)
    -- Rewritten on 2026-08-05. The cases that stood here exercised toggle_group,
    -- reload, add_hotstring and delete_hotstring — none of which the shared
    -- settings window has ever sent. They tested this bridge against a protocol
    -- that does not exist, which is exactly why the four actions the window DOES
    -- send and this bridge did not answer (set_priority, clear_priority,
    -- set_all_grey, close) went unnoticed: the suite was green and comparing
    -- nothing.
    helpers.it("'set_color' records the override for the category the user clicked", function()
      local seen = {}
      local s2 = build_mock_state()
      s2.config.set_override = function(cat, sec, field, value)
        seen[#seen + 1] = { cat = cat, sec = sec, field = field, value = value }
      end
      handler.on_message({ action = "set_color", category = "accents", hex = "#ff0000" }, s2)
      helpers.assert_eq(#seen, 1, "a colour change must reach the config module exactly once")
      helpers.assert_eq(seen[1].cat, "accents", "and name the category")
      helpers.assert_eq(seen[1].field, "color", "under the colour field")
      helpers.assert_eq(seen[1].value, "#ff0000", "with the colour the user picked")
    end)
    helpers.it("'set_color' with an empty section means the category itself", function()
      local seen = {}
      local s2 = build_mock_state()
      s2.config.set_override = function(cat, sec, field, value)
        seen[#seen + 1] = { cat = cat, sec = sec, field = field, value = value }
      end
      -- The window sends section: '' for a category-level edit. Passing it
      -- through writes an override under a section nothing has, so it never
      -- resolves and the colour silently does not apply.
      handler.on_message({ action = "set_color", category = "accents", section = "", hex = "#00ff00" }, s2)
      helpers.assert_eq(seen[1].sec, nil, "the empty string must become nil, not a section key")
    end)
    helpers.it("'set_priority' accepts a value in range and refuses one outside it", function()
      local seen = {}
      local s2 = build_mock_state()
      s2.config.set_override = function(cat, sec, field, value)
        seen[#seen + 1] = { cat = cat, field = field, value = value }
      end
      handler.on_message({ action = "set_priority", category = "accents", priority = 42 }, s2)
      helpers.assert_eq(#seen, 1, "an in-range priority must be recorded")
      helpers.assert_eq(seen[1].value, 42, "with the value the user typed")

      -- Re-validated rather than trusted: a priority outside the tier range
      -- silently reorders every hotstring source against every other, with
      -- nothing on screen to say so.
      handler.on_message({ action = "set_priority", category = "accents", priority = 500 }, s2)
      helpers.assert_eq(#seen, 1, "an out-of-range priority must be refused, not clamped")
    end)
    helpers.it("'clear_priority' removes the override rather than writing a default", function()
      local seen = {}
      local s2 = build_mock_state()
      s2.config.set_override = function(cat, sec, field, value)
        seen[#seen + 1] = { field = field, value = value }
      end
      handler.on_message({ action = "clear_priority", category = "accents" }, s2)
      helpers.assert_eq(#seen, 1, "clearing must reach the config module")
      helpers.assert_eq(seen[1].value, nil,
        "and pass nil — writing a number would pin the entry to whatever that default was")
    end)
    helpers.it("'set_all_grey' repaints every category AND clears the section colours", function()
      local seen = {}
      local s2 = build_mock_state()
      s2.config.get_neutral_color = function() return "#6e6e73" end
      s2.config.get_categories = function()
        return { accents = { sections_order = { "acute", "grave" } } }
      end
      s2.config.set_override = function(cat, sec, field, value)
        seen[#seen + 1] = { cat = cat, sec = sec, value = value }
      end
      handler.on_message({ action = "set_all_grey" }, s2)

      local category_painted, sections_cleared = false, 0
      for _, call in ipairs(seen) do
        if call.sec == nil and call.value == "#6e6e73" then category_painted = true end
        if call.sec ~= nil and call.value == nil then sections_cleared = sections_cleared + 1 end
      end
      helpers.assert_true(category_painted, "the category's own colour must become the neutral shade")
      -- The half that matters: leaving the per-section overrides repaints the
      -- headings and leaves the rows beneath in their old colours, which reads to
      -- the user as a button that half-worked.
      helpers.assert_eq(sections_cleared, 2, "and every per-section colour override must be wiped")
    end)
    helpers.it("'set_all_grey' changes nothing when the neutral colour cannot be read", function()
      local seen = {}
      local s2 = build_mock_state()
      s2.config.get_categories = function() return { accents = {} } end
      s2.config.get_neutral_color = nil
      s2.config.set_override = function() seen[#seen + 1] = true end
      handler.on_message({ action = "set_all_grey" }, s2)
      -- No hardcoded fallback: substituting a literal would repaint every category
      -- a shade nothing else in the product uses.
      helpers.assert_eq(#seen, 0, "a missing neutral colour must stop the repaint, not invent one")
    end)
    helpers.it("'reset_all' clears every category's overrides", function()
      local cleared = {}
      local s2 = build_mock_state()
      s2.config.reset_defaults = function() end
      s2.config.get_categories = function() return { accents = {}, code = {} } end
      s2.config.clear_override = function(id) cleared[#cleared + 1] = id end
      handler.on_message({ action = "reset_all" }, s2)
      helpers.assert_eq(#cleared, 2, "every category must be reset, not the first one found")
    end)
    helpers.it("'close' is answered so the host can tear the webview down", function()
      local close_calls = 0
      local result = handler.on_message({ action = "close" }, build_mock_state(), {
        close_owned_window = function() close_calls = close_calls + 1; return true end,
      })
      -- A window whose X does nothing is one the user force-quits, and on a
      -- webview host that can leave the process running with no visible window.
      helpers.assert_eq(close_calls, 1, "the close request must reach its owned host capability")
      helpers.assert_true(result.closed)
    end)
  end)

  -- ==========================================================================
  -- 8. changelog_bridge
  -- ==========================================================================

  helpers.describe("changelog_bridge", function()
    local handler = helpers.load_module("ui.changelog.bridge")
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
      helpers.assert_eq(result.action, "releases")
      helpers.assert_eq(result.channel, "main")
      helpers.assert_eq(type(result.cache_miss), "boolean")
      helpers.assert_true(type(result.releases) == "table")
      helpers.assert_true(type(result.repo_url) == "string")
      helpers.assert_true(type(result.version) == "string")
    end)
    helpers.it("returns cached releases in the exact schema the page renders (lnx-056)", function()
      local previous = package.loaded["modules.updater.manager"]
      package.loaded["modules.updater.manager"] = {
        get_channel = function() return "dev" end,
        get_cached_release = function()
          return {
            tag = "v9.8.7", notes = "Native cache marker",
            published_at = "2026-08-31T12:00:00Z", prerelease = true,
          }
        end,
      }
      local result = handler.on_message({ action = "fetch", channel = "dev" }, state)
      package.loaded["modules.updater.manager"] = previous
      helpers.assert_eq(result.channel, "dev")
      helpers.assert_eq(result.cache_miss, false)
      helpers.assert_eq(result.releases[1].tag_name, "v9.8.7")
      helpers.assert_eq(result.releases[1].body, "Native cache marker")
      helpers.assert_eq(result.releases[1].html_url,
        "https://github.com/adrienm7/ergopti/releases/tag/v9.8.7")
      helpers.assert_eq(result.releases[1].published_at, "2026-08-31T12:00:00Z")
      helpers.assert_eq(result.releases[1].prerelease, true)
      helpers.assert_eq(result.releases[1].tag, nil,
        "the obsolete Linux-only schema must not survive beside the canonical one")
    end)
    helpers.it("opens only repository URLs and reports the launcher outcome (lnx-056)", function()
      local Shell = require("adapters.shell_runner")
      local commands = {}
      Shell._set_runner(function(command)
        commands[#commands + 1] = command
        return true
      end)
      local accepted = handler.on_message({
        action = "open_url",
        url = "https://github.com/adrienm7/ergopti/releases/tag/v9.8.7",
      }, state)
      Shell._reset_runner()
      helpers.assert_true(accepted.opened)
      helpers.assert_eq(accepted.action, "open_url")
      helpers.assert_true(#commands == 2 and commands[2]:find("xdg-open", 1, true) ~= nil,
        "the validated URL must reach the desktop opener after its capability probe")

      commands = {}
      Shell._set_runner(function(command) commands[#commands + 1] = command; return true end)
      local refused = handler.on_message({ action = "open_url", url = "https://evil.example/" }, state)
      Shell._reset_runner()
      helpers.assert_eq(refused.opened, false)
      helpers.assert_eq(#commands, 0, "a foreign URL must reach no shell command")
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
    local handler = helpers.load_module("ui.download_window.bridge")
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
    local handler = helpers.load_module("ui.hotstring_editor.bridge")
    local state = build_mock_state()

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "hsEditor")
    end)
    -- Rewritten on 2026-08-05. These asserted a payload of {groups, hotstrings}
    -- and a save of {trigger, replacement, group} — a protocol the shared editor
    -- has never spoken. window.initData reads {sections, trigger_char,
    -- default_priority, open_mode}, and persist() sends the WHOLE model as
    -- {sections_order, sections}. The suite was green while the editor opened
    -- EMPTY on this driver, every time.
    helpers.it("'ready' PUSHES window.initData rather than returning the payload", function()
      -- The second half of the same bug. The keys were right; the delivery was
      -- not. This bridge returned the payload as a bridge response, and the
      -- shared editor page has no reader for one — it reveals #app (display:none
      -- in the markup) only from inside window.initData, at script.js:1376. So
      -- the editor stayed on "Chargement…" for ever, with a perfectly correct
      -- payload sitting in a return value nothing collected.
      local pushed = {}
      local manager = package.loaded["ui.webview_manager"]
      package.loaded["ui.webview_manager"] = {
        eval_js = function(app, js) pushed[#pushed + 1] = { app = app, js = js }; return true end,
      }
      local ok, err = pcall(handler.on_message, "ready", state)
      package.loaded["ui.webview_manager"] = manager
      helpers.assert_true(ok, "the ready branch must not throw: " .. tostring(err))

      helpers.assert_eq(#pushed, 1, "exactly one push into the page")
      helpers.assert_eq(pushed[1].app, "hotstring_editor",
        "into the page's own directory name — the key eval_js looks a live webview up by")
      helpers.assert_true(pushed[1].js:find("window.initData(", 1, true) ~= nil,
        "calling the entry point the page defines, not some other function")
      helpers.assert_true(pushed[1].js:find("if(window.initData)", 1, true) ~= nil,
        "guarded, because a push landing before the page defines it throws inside "
          .. "the webview where nothing on this side would see it")
      for _, key in ipairs({ "sections", "trigger_char", "open_mode" }) do
        helpers.assert_true(pushed[1].js:find('"' .. key .. '"', 1, true) ~= nil,
          "and carrying " .. key .. ", which the page destructures")
      end
    end)
    helpers.it("'ready' carries strict-case state into the shared frontend", function()
      local reader, writer = make_spies(true)
      with_spies("ui.hotstring_editor.bridge", reader, writer, function(h)
        local pushed = {}
        local manager = package.loaded["ui.webview_manager"]
        package.loaded["ui.webview_manager"] = {
          eval_js = function(_, js) pushed[#pushed + 1] = js; return true end,
        }
        local ok, err = pcall(h.on_message, "ready", state)
        package.loaded["ui.webview_manager"] = manager
        helpers.assert_true(ok, "the strict payload push must not throw: " .. tostring(err))
        helpers.assert_eq(#pushed, 1, "strict state must be pushed exactly once")
        helpers.assert_true(pushed[1]:find('"is_case_sensitive_strict":true', 1, true) ~= nil,
          "a strict entry must reach the frontend before any edit can preserve it")
      end)
    end)
    helpers.it("'save' writes the whole model the editor sent", function()
      local reader, writer, captured = make_spies(true)
      with_spies("ui.hotstring_editor.bridge", reader, writer, function(h)
        local result = h.on_message({
          action = "save",
          data = {
            sections_order = { "work" },
            sections = { work = { description = "Work", entries = {
              { trigger = "btw", output = "by the way", is_word = true,
                is_case_sensitive = true, is_case_sensitive_strict = true },
              { trigger = "omw", output = "on my way" },
            } } },
          },
        }, state)
        helpers.assert_true(result.saved, "a successful write must report saved = true")
        local entries = captured.data.sections.work.entries
        helpers.assert_eq(#entries, 2, "every entry the editor sent must be written")
        helpers.assert_eq(entries[1].trigger, "btw", "in the order it sent them")
        helpers.assert_eq(entries[1].is_word, true, "with its flags preserved")
        helpers.assert_eq(entries[1].is_case_sensitive_strict, true,
          "including the strict-case flag that changes matching semantics")
      end)
    end)
    helpers.it("'save' replaces rather than merges, so a deletion sticks", function()
      local reader, writer, captured = make_spies(true)
      with_spies("ui.hotstring_editor.bridge", reader, writer, function(h)
        -- The shared script sends its ENTIRE state on every save, so an entry the
        -- user deleted is simply absent from the payload. Merging into what is on
        -- disk would bring it back, and the deletion would appear to work until
        -- the next restart.
        h.on_message({
          action = "save",
          data = {
            sections_order = { "english" },
            sections = { english = { description = "English", entries = {
              { trigger = "ty", output = "thank you" },
            } } },
          },
        }, state)
        local entries = captured.data.sections.english.entries
        helpers.assert_eq(#entries, 1, "only what the editor sent may be on disk")
        helpers.assert_eq(entries[1].trigger, "ty", "and it must be the entry it sent")
      end)
    end)
    helpers.it("'save' drops an entry with no trigger instead of writing it", function()
      local reader, writer, captured = make_spies(true)
      with_spies("ui.hotstring_editor.bridge", reader, writer, function(h)
        h.on_message({
          action = "save",
          data = {
            sections_order = { "work" },
            sections = { work = { entries = {
              { trigger = "", output = "orphaned" },
              { trigger = "ok", output = "okay" },
            } } },
          },
        }, state)
        local entries = captured.data.sections.work.entries
        helpers.assert_eq(#entries, 1,
          "a triggerless entry can never fire, and on disk it is a row nobody can delete from the UI")
        helpers.assert_eq(entries[1].trigger, "ok", "the real entry survives")
      end)
    end)
    helpers.it("'save' reports failure when the write fails", function()
      local reader, writer = make_spies(false, "disk full")
      with_spies("ui.hotstring_editor.bridge", reader, writer, function(h)
        local result = h.on_message({
          action = "save",
          data = { sections_order = { "work" }, sections = { work = { entries = {} } } },
        }, state)
        helpers.assert_eq(result.saved, false, "a failed write must not report success")
      end)
    end)
    helpers.it("'save_pref' stores a declared preference and refuses an unknown key", function()
      local ok = handler.on_message(
        { action = "save_pref", data = { key = "compact_view", value = true } }, state)
      helpers.assert_true(ok ~= nil and ok.saved == true, "a declared preference must be stored")

      -- The page is the least trusted input the daemon has, and these share
      -- storage with the category toggles: an unbounded key/value write is how a
      -- UI bug becomes a corrupted config.
      local refused = handler.on_message(
        { action = "save_pref", data = { key = "../../evil", value = 1 } }, state)
      helpers.assert_true(refused ~= nil and refused.saved == false,
        "an undeclared preference key must be refused, not written")
    end)
    helpers.it("'save_pref' reports a storage failure and rejects the wrong value type", function()
      local previous_storage = package.loaded["adapters.storage"]
      local previous_handler = package.loaded["ui.hotstring_editor.bridge"]
      package.loaded["adapters.storage"] = {
        get = function(_key, default_value) return default_value end,
        set = function() return false end,
      }
      package.loaded["ui.hotstring_editor.bridge"] = nil
      local failing = require("ui.hotstring_editor.bridge")

      local failed = failing.on_message(
        { action = "save_pref", data = { key = "compact_view", value = true } }, state)
      local mistyped = failing.on_message(
        { action = "save_pref", data = { key = "compact_view", value = "true" } }, state)

      package.loaded["adapters.storage"] = previous_storage
      package.loaded["ui.hotstring_editor.bridge"] = previous_handler
      helpers.assert_eq(failed.saved, false,
        "the page must not receive saved=true when the durable write failed")
      helpers.assert_eq(mistyped.saved, false,
        "the dispatch path must enforce the same preference type as set_pref()")
    end)
    helpers.it("'window_focus' owns the input gate at the trusted page epoch", function()
      local gate_mod = helpers.load_module("infra.input_capture_gate")
      local resets = 0
      local s2 = build_mock_state()
      s2.input_capture_gate = gate_mod.new({
        on_block = function() resets = resets + 1 end,
      })
      local focused = handler.on_message(
        { action = "window_focus", data = { focused = true } }, s2,
        { app_name = "hotstring_editor", epoch = 41 })
      helpers.assert_true(focused.ok)
      helpers.assert_true(s2.input_capture_gate.blocks_text(),
        "the production input consumers must observe an owned gate, not a decorative state flag")
      helpers.assert_eq(resets, 1)

      local stale = handler.on_message(
        { action = "window_focus", data = { focused = false } }, s2,
        { app_name = "hotstring_editor", epoch = 40 })
      helpers.assert_eq(stale.ok, false)
      helpers.assert_true(s2.input_capture_gate.blocks_text())

      local blurred = handler.on_message(
        { action = "window_focus", data = { focused = false } }, s2,
        { app_name = "hotstring_editor", epoch = 41 })
      helpers.assert_true(blurred.ok)
      helpers.assert_eq(s2.input_capture_gate.blocks_text(), false)
    end)
  end)

  -- ==========================================================================
  -- 11. paths_editor_bridge
  -- ==========================================================================

  helpers.describe("paths_editor_bridge", function()
    local handler = helpers.load_module("ui.paths_editor.bridge")
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
    local handler = helpers.load_module("ui.personal_info_editor.bridge")
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
    local handler = helpers.load_module("ui.model_browser.bridge")
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
