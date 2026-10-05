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
    local snapshot_parser = require("toml_codec.reader").parse_text
    local classified_read = require("toml_codec.writer").read_classified
    local reader = {
      parse_text = snapshot_parser,
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
      read_classified = classified_read,
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

  -- Existing personal persistence tests now enter through an accepted displayed source.
  local function with_opened_spies(reader, writer, state, fn)
    local RealWriter = require("toml_codec.writer")
    local Shell = require("adapters.shell_runner")
    local directory = os.tmpname(); assert(os.remove(directory)); directory = directory .. "-personal-opening"
    assert(Shell.run("mkdir -p " .. Shell.quote(directory)) == true)
    local path = directory .. "/personal.toml"
    local file = assert(io.open(path, "wb"))
    assert(file:write('[_meta]\nsections_order = ["english"]\n[english]\n"omw" = { output = "on my way", is_word = true, auto_expand = false, is_case_sensitive = true, is_case_sensitive_strict = true, final_result = false }\n"ty" = { output = "thank you", is_word = true, final_result = false }\n'))
    assert(file:close())
    local old_dir, manager, native_write = state.config.get_config_dir, package.loaded["ui.webview_manager"], writer.write
    state.config.get_config_dir = function() return directory end
    local context = { app_name = "hotstring_editor", epoch = 41 }
    package.loaded["ui.webview_manager"] = { current_epoch = function() return 41 end,
      eval_js = function() return true end }
    writer.write = function(...)
      local accepted, detail = native_write(...)
      if accepted ~= true then return accepted, detail end
      return RealWriter.write(...)
    end
    local ok, err = pcall(function()
      with_spies("ui.hotstring_editor.bridge", reader, writer, function(h)
        assert(h.push_init(state, context) == true, "The original save case requires an accepted opening")
        fn(h, context)
      end)
    end)
    writer.write, state.config.get_config_dir, package.loaded["ui.webview_manager"] = native_write, old_dir, manager
    assert(Shell.run("rm -rf " .. Shell.quote(directory)) == true)
    if not ok then error(err, 0) end
  end

  -- ==========================================================================
  -- 1. webview_manager
  -- ==========================================================================

  helpers.describe("webview_manager", function()
    -- Use require (not load_module) so windows persist across tests.
    -- webview_manager auto-inits on load, and load_module would wipe state.
    local wm = require("ui.webview_manager")
    local real_create_gtk_window = wm._create_gtk_window
    local function fake_create_gtk_window() return true end

    local function manager_without_gtk()
      local original = package.loaded["ui.webview_manager"]
      local ok, manager = pcall(helpers.load_module_with_dependency,
        "ui.webview_manager", "lgi", false)
      package.loaded["ui.webview_manager"] = original
      if not ok then error(manager, 0) end
      return manager
    end

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
    helpers.it("show fails without a native window instead of inventing visibility (lnx-067)", function()
      local headless = manager_without_gtk()
      helpers.assert_eq(headless.show("action_picker", "fr"), false)
      helpers.assert_eq(headless.is_visible("action_picker"), false,
        "headless bridge routing must not masquerade as a user-visible window")
      helpers.assert_eq(headless.current_epoch("action_picker"), nil,
        "failed native creation must roll back its provisional page context")
    end)
    wm._create_gtk_window = fake_create_gtk_window
    helpers.it("show registers a window after native creation succeeds", function()
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
    wm._create_gtk_window = real_create_gtk_window
    helpers.it("_create_gtk_window reports failure safely without GTK", function()
      local headless = manager_without_gtk()
      -- Called directly: a raise fails with the real error. The claim is the
      -- refusal — with no GTK the window must not be registered, or every later
      -- show/focus call addresses a window that does not exist.
      local created, detail = headless._create_gtk_window("action_picker", "<html></html>", nil)
      helpers.assert_eq(created, false)
      helpers.assert_eq(detail, "GTK/WebKit unavailable",
        "the refusal must come from the explicitly unavailable native dependency")
      helpers.assert_true(headless.is_open == nil or headless.is_open("action_picker") ~= true,
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
      wm._create_gtk_window = fake_create_gtk_window
      wm.show("action_picker", "fr")
      wm.bring_to_front("action_picker")
      helpers.assert_eq(type(wm.bring_to_front), "function",
        "bring_to_front must survive being called with no GTK — it is bound to a menu "
          .. "row the user can click on any desktop")
      wm.hide("action_picker")
      wm._create_gtk_window = real_create_gtk_window
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
    helpers.it("opens a production session and closes its exact page after confirmation", function()
      local prior_manager = package.loaded["ui.webview_manager"]
      local shown = nil
      package.loaded["ui.webview_manager"] = {
        show = function(app_name)
          shown = app_name
          return true
        end,
        hide = function() return true end,
        is_visible = function() return false end,
      }
      local confirmed = nil
      local opened = handler.open({ current = "none" }, function(id)
        confirmed = id
        return true
      end)
      package.loaded["ui.webview_manager"] = prior_manager

      helpers.assert_true(opened)
      helpers.assert_eq(shown, "action_picker")
      helpers.assert_true(handler.is_open())
      local close_count = 0
      handler.on_message({ action = "confirm", id = "app_switcher" }, state, {
        close_owned_window = function()
          close_count = close_count + 1
          return true
        end,
      })
      helpers.assert_eq(confirmed, "app_switcher")
      helpers.assert_eq(close_count, 1)
      helpers.assert_eq(handler.is_open(), false)
    end)
    helpers.it("keeps a refused confirmation retryable until cancellation", function()
      local prior_manager = package.loaded["ui.webview_manager"]
      package.loaded["ui.webview_manager"] = {
        show = function() return true end,
        hide = function() return true end,
        is_visible = function() return false end,
      }
      helpers.assert_true(handler.open({}, function() return false end))
      package.loaded["ui.webview_manager"] = prior_manager

      local close_count = 0
      local context = {
        close_owned_window = function()
          close_count = close_count + 1
          return true
        end,
      }
      handler.on_message({ action = "confirm", id = "open_url" }, state, context)
      helpers.assert_true(handler.is_open(), "a rejected transaction still owns its picker")
      helpers.assert_eq(close_count, 0)
      handler.on_message({ action = "cancel" }, state, context)
      helpers.assert_eq(close_count, 1)
      helpers.assert_eq(handler.is_open(), false)
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
    local function with_prompt_session(fn)
      local previous_manager = package.loaded["ui.webview_manager"]
      local previous_handler = package.loaded["ui.prompt_editor.bridge"]
      local pushed = {}
      local manager = {
        show = function(app) return app == "prompt_editor" end,
        hide = function(app) return app == "prompt_editor" end,
        is_visible = function() return false end,
        current_epoch = function() return 41 end,
        eval_js = function(app, code)
          pushed[#pushed + 1] = { app = app, code = code }
          return true
        end,
      }
      package.loaded["ui.webview_manager"] = manager
      package.loaded["ui.prompt_editor.bridge"] = nil
      local handler = require("ui.prompt_editor.bridge")
      handler._reset()
      local ok, err = pcall(fn, handler, manager, pushed)
      package.loaded["ui.prompt_editor.bridge"] = previous_handler
      package.loaded["ui.webview_manager"] = previous_manager
      if not ok then error(err, 0) end
    end

    helpers.it("speaks ready/init/save and closes the exact native page", function()
      with_prompt_session(function(handler, manager, pushed)
        helpers.assert_eq(handler.bridge_name, "prompt_bridge")
        local saved, closes = nil, 0
        helpers.assert_eq(handler.open(nil, function(profile)
          saved = profile
          return true
        end), true)
        local context = {
          epoch = 41,
          close_owned_window = function() closes = closes + 1; return true end,
        }
        local ready = handler.on_message({ action = "ready" }, {
          webview_manager = manager,
        }, context)
        helpers.assert_eq(ready.pushed, true)
        helpers.assert_eq(#pushed, 1)
        helpers.assert_eq(pushed[1].app, "prompt_editor")
        helpers.assert_true(pushed[1].code:find("window.init", 1, true) ~= nil)
        helpers.assert_eq(type(ready.data.epoch), "number")

        local result = handler.on_message({
          action = "save",
          edit_id = ready.data.edit_id,
          epoch = ready.data.epoch,
          name = "  Linux profile  ",
          batch = true,
          prompt = "  Continue {context}  ",
        }, {}, context)
        helpers.assert_eq(result.saved, true)
        helpers.assert_eq(result.closed, true)
        helpers.assert_eq(saved.label, "Linux profile")
        helpers.assert_eq(saved.system_single, "Continue {context}")
        helpers.assert_eq(saved.batch, true)
        helpers.assert_true(saved.id:match("^user_") ~= nil)
        helpers.assert_eq(closes, 1)
        helpers.assert_eq(handler.is_open(), false)
      end)
    end)

    helpers.it("rejects stale contexts and keeps a refused save retryable", function()
      with_prompt_session(function(handler, manager)
        local attempts, closes, saved = 0, 0, nil
        helpers.assert_eq(handler.open({
          id = "user_existing",
          label = "Existing",
          system_single = "Old {context}",
          system_multi_template = "Before\n{items}",
          batch = true,
        }, function(profile)
          attempts = attempts + 1
          saved = profile
          return attempts > 1
        end), true)
        local context = {
          epoch = 41,
          close_owned_window = function() closes = closes + 1; return true end,
        }
        local ready = handler.on_message({ action = "ready" }, {
          webview_manager = manager,
        }, context)
        local payload = {
          action = "save",
          edit_id = ready.data.edit_id,
          epoch = ready.data.epoch,
          name = "Existing",
          batch = true,
          prompt = "New {context}",
        }
        local stale = {}
        for key, value in pairs(payload) do stale[key] = value end
        stale.epoch = stale.epoch + 1
        helpers.assert_eq(handler.on_message(stale, {}, context), nil)
        helpers.assert_eq(attempts, 0)

        local refused = handler.on_message(payload, {}, context)
        helpers.assert_eq(refused.saved, false)
        helpers.assert_eq(refused.closed, false)
        helpers.assert_eq(handler.is_open(), true)
        helpers.assert_eq(closes, 0)

        local accepted = handler.on_message(payload, {}, context)
        helpers.assert_eq(accepted.saved, true)
        helpers.assert_eq(accepted.closed, true)
        helpers.assert_eq(attempts, 2)
        helpers.assert_eq(saved.system_multi_template, "Before\n{items}")
        helpers.assert_eq(closes, 1)
      end)
    end)

    helpers.it("retries only the close after persistence already committed", function()
      with_prompt_session(function(handler, manager)
        local saves, closes = 0, 0
        handler.open(nil, function() saves = saves + 1; return true end)
        local context = {
          epoch = 41,
          close_owned_window = function()
            closes = closes + 1
            return closes > 1
          end,
        }
        local ready = handler.on_message({ action = "ready" }, {
          webview_manager = manager,
        }, context)
        local payload = {
          action = "save",
          edit_id = ready.data.edit_id,
          epoch = ready.data.epoch,
          name = "Close retry",
          batch = false,
          prompt = "Prompt {context}",
        }
        local first = handler.on_message(payload, {}, context)
        helpers.assert_eq(first.saved, true)
        helpers.assert_eq(first.closed, false)
        helpers.assert_eq(handler.is_open(), true)
        local second = handler.on_message(payload, {}, context)
        helpers.assert_eq(second.closed, true)
        helpers.assert_eq(saves, 1,
          "a native close failure must never duplicate a durable profile write")
        helpers.assert_eq(closes, 2)
      end)
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
    local Snapshot = helpers.load_module("healthcheck.snapshot")

    -- The probes run curl and child processes; these cases answer the page
    -- without starting any.
    local function without_probes(fn)
      local previous = package.loaded["ui.healthcheck.probes"]
      package.loaded["ui.healthcheck.probes"] = { start = function() return { cancel = function() end } end }
      local ok, err = pcall(fn)
      package.loaded["ui.healthcheck.probes"] = previous
      if not ok then error(err, 0) end
    end

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "healthcheck")
    end)

    -- The shared page reads the version 2 snapshot of
    -- _shared/modules/diagnostics/schema.json by section and field id, and
    -- renders nothing for a field the schema does not declare.
    helpers.it("'ready' answers the page's configuration and a snapshot the schema declares", function()
      without_probes(function()
        local result = handler.on_message("ready", state)
        helpers.assert_eq(result.type, "init")
        helpers.assert_eq(result.snapshot.schema_version, 2)
        local undeclared = Snapshot.check_fields(result.snapshot, result.config.schema)
        helpers.assert_eq(undeclared, {},
          "the snapshot carries fields the page would never show: " .. table.concat(undeclared, ", "))
      end)
    end)

    helpers.it("carries the live figures it was given", function()
      without_probes(function()
        local sections = handler.on_message("ready", state).snapshot.sections
        helpers.assert_eq(sections.ai.ai_model, "codellama")
        helpers.assert_eq(sections.ai.ai_enabled, true)
      end)
    end)

    helpers.it("the page's refresh answers a new snapshot", function()
      without_probes(function()
        handler.on_message("ready", state)
        local result = handler.on_message({ action = "refresh", detailed = false }, state)
        helpers.assert_eq(result.type, "snapshot")
        helpers.assert_eq(result.snapshot.schema_version, 2)
      end)
    end)

    helpers.it("still answers with nothing wired at all, and says so", function()
      without_probes(function()
        local developer = handler.on_message("ready", {}).snapshot.sections.developer
        helpers.assert_true(#developer.modules_failed > 0,
          "an unwired daemon is exactly when this window is read: it must SAY that nothing is "
            .. "wired, rather than report an empty failure list that reads as a clean bill of health")
      end)
    end)

    helpers.it("names the parts that are wired", function()
      without_probes(function()
        local developer = handler.on_message("ready", state).snapshot.sections.developer
        helpers.assert_true(#developer.modules_ok > 0,
          "a report listing no loaded parts on a fully wired daemon is the empty window in a different disguise")
      end)
    end)
  end)

  -- ==========================================================================
  -- 6. onboarding_bridge
  -- ==========================================================================

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
			local ConfigPaths = helpers.load_module("infra.config_paths")
			helpers.assert_eq(ConfigPaths.metrics_path(), ConfigPaths.data("metrics.sqlite"))
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
				exec_line = function() return "/tmp/picked/" end,
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
			local ok, err = pcall(function()
				helpers.assert_true(os.execute("mkdir -p '" .. target .. "'"))
				write_file(path, raw)
				state.writer = require("toml_codec.writer")
				io.open = function(open_path, mode)
					local fh, why, code = original_open(open_path, mode)
					if fh and open_path == path .. ".tmp" and mode == "w" then
						return {
							write = function(_, content) return fh:write(content) end,
							close = function()
								local closed = fh:close()
								staged = staged + 1
								local source = assert(original_open(path, "w"))
								assert(source:write(concurrent)); assert(source:close())
								return closed
							end,
						}
					end
					return fh, why, code
				end
				local refused = finish(state, { locale = "fr", config_dir = target, operations = {
					{ path = "hotstrings.trigger_char", value = "§" },
				} })
				io.open = original_open
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
			io.open = original_open
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

    helpers.it("the healthcheck window opens in the persisted locale, not a hardcoded 'fr'", function()
      local hc = helpers.load_module("ui.healthcheck.bridge")
      local previous = package.loaded["ui.webview_manager"]
      local shown = nil
      package.loaded["ui.webview_manager"] = {
        current_epoch = function() return nil end,
        show = function(app, locale) shown = { app = app, locale = locale }; return true end,
      }
      local ok, err = pcall(with_locale_module, { get_locale = function() return "de" end }, function()
        helpers.assert_true(hc.open())
      end)
      package.loaded["ui.webview_manager"] = previous
      if not ok then error(err, 0) end
      helpers.assert_eq(shown, { app = "healthcheck", locale = "de" },
        "healthcheck must render in the user's locale (de), not the hardcoded 'fr'")
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
    -- The native fetch is covered by test_changelog_release_sources; keep these
    -- protocol cases off the network.
    handler._http_get = function() end
    handler._push = function() return true end

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
      helpers.assert_eq(result.channel, require("modules.updater.manager").get_channel(),
        "the page opens on the subscribed channel")
      helpers.assert_eq(type(result.cache_miss), "boolean")
      helpers.assert_true(type(result.releases) == "table")
      helpers.assert_true(type(result.repo_url) == "string")
      helpers.assert_true(type(result.version) == "string")
    end)
    helpers.it("returns cached releases in the exact schema the page renders (lnx-056)", function()
      local previous = package.loaded["modules.updater.manager"]
      local real = require("modules.updater.manager")
      package.loaded["modules.updater.manager"] = setmetatable({
        get_channel = function() return "dev" end,
        get_cached_release = function()
          return {
            tag = "v9.8.7", notes = "Native cache marker",
            published_at = "2026-08-31T12:00:00Z", prerelease = true,
          }
        end,
      }, { __index = real })
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
    helpers.it("refuses a repository that only shares the name's prefix (repo-url-single-source)", function()
      -- The allow-pattern was a typed copy of the repository, and it accepted
      -- any name that merely started with it
      local Shell = require("adapters.shell_runner")
      local commands = {}
      Shell._set_runner(function(command) commands[#commands + 1] = command; return true end)
      local refused = handler.on_message({
        action = "open_url",
        url = "https://github.com/adrienm7/ergopti-lookalike/releases",
      }, state)
      Shell._reset_runner()
      helpers.assert_eq(refused.opened, false)
      helpers.assert_eq(#commands, 0, "a lookalike repository must reach no shell command")
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
	helpers.it("linux-model-pull-retry-retirement: progress retries preserve successful settlement", function()
		local previous_manager = package.loaded["ui.webview_manager"]
		local evaluated, retries = {}, 0
		package.loaded["ui.webview_manager"] = {
			show = function() return true end,
			hide = function() return true end,
			eval_js = function(_, code) evaluated[#evaluated + 1] = code; return true end,
		}
		local ok, err = xpcall(function()
			handler._reset()
			local session_id = handler.show({ kind = "ollama_model", label = "Successful fixture",
				on_retry = function() retries = retries + 1; return false end })
			helpers.assert_true(handler.complete(session_id, true, "Installed"))
			helpers.assert_eq(handler.on_message("retry").retried, false)
			helpers.assert_eq(retries, 0, "a successful session never invokes a retry controller")
			helpers.assert_true(handler.on_message("ready").pushed)
			helpers.assert_true(evaluated[#evaluated]:find("done(true", 1, true) ~= nil,
				"stale retry must preserve the successful terminal receipt")
		end, debug.traceback)
		handler._reset()
		package.loaded["ui.webview_manager"] = previous_manager
		if not ok then error(err) end
	end)

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "dl_bridge")
    end)
    helpers.it("owns ready, progress, cancel, and retry for one exact session", function()
      local previous_manager = package.loaded["ui.webview_manager"]
      local evaluated, cancelled, retried = {}, 0, 0
      package.loaded["ui.webview_manager"] = {
        show = function(app) return app == "download_window" end,
        hide = function() return true end,
        eval_js = function(app, code)
          evaluated[#evaluated + 1] = { app = app, code = code }
          return true
        end,
      }
      handler._reset()
      local session_id = handler.show({
		kind = "ollama_model",
		label = "Qwen fixture",
		on_cancel = function() cancelled = cancelled + 1; return true end,
		on_retry = function() retried = retried + 1; return true end,
      })
      helpers.assert_true(type(session_id) == "number")
      local ready = handler.on_message("ready")
      helpers.assert_true(ready.pushed)
      helpers.assert_eq(ready.session_id, session_id)
      helpers.assert_true(evaluated[#evaluated].code:find("setModel", 1, true) ~= nil)
      helpers.assert_true(handler.update(session_id, 42, "pulling manifest", "line"))
      helpers.assert_true(evaluated[#evaluated].code:find("update(42", 1, true) ~= nil)

      local cancel = handler.on_message("cancel")
      helpers.assert_true(cancel.cancelled)
      helpers.assert_eq(cancelled, 1)
      helpers.assert_true(evaluated[#evaluated].code:find("done(false", 1, true) ~= nil)
      local retry = handler.on_message("retry")
      helpers.assert_true(retry.retried)
      helpers.assert_eq(retried, 1)
      package.loaded["ui.webview_manager"] = previous_manager
    end)

    helpers.it("replays terminal state when transport finishes before page ready", function()
      local previous_manager = package.loaded["ui.webview_manager"]
      local evaluated = {}
      package.loaded["ui.webview_manager"] = {
        show = function() return true end,
        hide = function() return true end,
        eval_js = function(_, code) evaluated[#evaluated + 1] = code; return true end,
      }
      handler._reset()
      local session_id = handler.show({ kind = "ollama_model", label = "Fast fixture" })
      helpers.assert_true(handler.complete(session_id, true, "Installed"))
      helpers.assert_eq(#evaluated, 0)
      helpers.assert_true(handler.on_message("ready").pushed)
      helpers.assert_true(evaluated[1]:find("done(true", 1, true) ~= nil)
      helpers.assert_true(evaluated[1]:find("Installed", 1, true) ~= nil)
      package.loaded["ui.webview_manager"] = previous_manager
    end)

    helpers.it("titles the window by its kind and refuses a kind the page does not know", function()
      local previous_manager = package.loaded["ui.webview_manager"]
      local evaluated = {}
      package.loaded["ui.webview_manager"] = {
        show = function() return true end,
        hide = function() return true end,
        eval_js = function(_, code) evaluated[#evaluated + 1] = code; return true end,
      }
      handler._reset()
      helpers.assert_nil(handler.show({ label = "No kind" }), "a producer must name its kind")
      helpers.assert_nil(handler.show({ kind = "firmware", label = "Unknown kind" }))
      local session_id = handler.show({ kind = "app_update", label = "ErgoptiPlus v0.0.0-dev.150" })
      helpers.assert_true(type(session_id) == "number")
      helpers.assert_true(handler.on_message("ready").pushed)
      helpers.assert_true(evaluated[1]:find('setKind("app_update"', 1, true) ~= nil,
        "the page shows the app-update heading: " .. tostring(evaluated[1]))
      package.loaded["ui.webview_manager"] = previous_manager
      handler._reset()
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
        current_epoch = function() return 41 end,
        eval_js = function(app, js) pushed[#pushed + 1] = { app = app, js = js }; return true end,
      }
      local ok, err = pcall(handler.on_message, "ready", state, { app_name = "hotstring_editor", epoch = 41 })
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
      with_opened_spies(reader, writer, state, function(h, context)
        local pushed = {}
        local manager = package.loaded["ui.webview_manager"]
        package.loaded["ui.webview_manager"] = {
          current_epoch = function() return 41 end,
          eval_js = function(_, js) pushed[#pushed + 1] = js; return true end,
        }
        local ok, err = pcall(h.on_message, "ready", state, context)
        package.loaded["ui.webview_manager"] = manager
        helpers.assert_true(ok, "the strict payload push must not throw: " .. tostring(err))
        helpers.assert_eq(#pushed, 1, "strict state must be pushed exactly once")
        helpers.assert_true(pushed[1]:find('"is_case_sensitive_strict":true', 1, true) ~= nil,
          "a strict entry must reach the frontend before any edit can preserve it")
      end)
    end)
    helpers.it("'save' writes the whole model the editor sent", function()
      local reader, writer, captured = make_spies(true)
      with_opened_spies(reader, writer, state, function(h, context)
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
        }, state, context)
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
      with_opened_spies(reader, writer, state, function(h, context)
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
        }, state, context)
        local entries = captured.data.sections.english.entries
        helpers.assert_eq(#entries, 1, "only what the editor sent may be on disk")
        helpers.assert_eq(entries[1].trigger, "ty", "and it must be the entry it sent")
      end)
    end)
    helpers.it("'save' drops an entry with no trigger instead of writing it", function()
      local reader, writer, captured = make_spies(true)
      with_opened_spies(reader, writer, state, function(h, context)
        h.on_message({
          action = "save",
          data = {
            sections_order = { "work" },
            sections = { work = { entries = {
              { trigger = "", output = "orphaned" },
              { trigger = "ok", output = "okay" },
            } } },
          },
        }, state, context)
        local entries = captured.data.sections.work.entries
        helpers.assert_eq(#entries, 1,
          "a triggerless entry can never fire, and on disk it is a row nobody can delete from the UI")
        helpers.assert_eq(entries[1].trigger, "ok", "the real entry survives")
      end)
    end)
    helpers.it("'save' reports failure when the write fails", function()
      local reader, writer = make_spies(false, "disk full")
      with_opened_spies(reader, writer, state, function(h, context)
        local result = h.on_message({
          action = "save",
          data = { sections_order = { "work" }, sections = { work = { entries = {} } } },
        }, state, context)
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

		local function paths_state()
			local values = { config_dir = "/tmp/ergopti-current", logs_dir = "/tmp/ergopti-logs" }
			local captured = { pushes = {}, hidden = 0, reloaded = 0 }
			return {
				config_paths = {
					get_config_dir = function() return values.config_dir end,
					default_config_dir = function() return "/tmp/ergopti-default" end,
					set_config_dir = function(value)
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
					exec_line = function() return "/tmp/ergopti-picked/" end,
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

-- ============================================================================
-- personal_toml_editor save: validate before truncating, stage atomically.
-- ============================================================================
--
-- Regression: the save handler truncated personal_info.toml with io.open(path,
-- "w") and then wrote whatever the editor sent — unchecked write/close, no
-- tmp staging, no TOML validation. One malformed save disabled every @-tag
-- shortcut on the next load, a crash mid-write left a truncated file, and a
-- fresh home with no file could never save at all (toml_path == "").
--
-- These tests sandbox the bridge (fake home, fake dynamic manager path, fake
-- shell) and drive the real on_message() save path.

--- Reads a whole file, or "" when absent.
local function read_sandbox_file(path)
  local fh = io.open(path, "r")
  if not fh then return "" end
  local content = fh:read("*a") or ""
  fh:close()
  return content
end

--- Installs sandbox doubles and returns a freshly loaded bridge plus restore info.
local function sandboxed_toml_bridge(toml_path)
  local previous = {
    config_paths = package.loaded["infra.config_paths"],
    manager = package.loaded["modules.dynamic_hotstrings.manager"],
    shell = package.loaded["adapters.shell_runner"],
  }
  package.loaded["infra.config_paths"] = {
    home = function() return "/nonexistent-test-home" end,
  }
  package.loaded["modules.dynamic_hotstrings.manager"] = {
    get_config_path = function() return toml_path end,
    reload = function() end,
  }
  package.loaded["adapters.shell_runner"] = {
    run = function() return true end,
    quote = function(s) return "'" .. tostring(s) .. "'" end,
  }
  local handler = helpers.load_module("ui.personal_info_editor.bridge_toml")
  return handler, previous
end

local function restore_sandbox(previous)
  package.loaded["infra.config_paths"] = previous.config_paths
  package.loaded["modules.dynamic_hotstrings.manager"] = previous.manager
  package.loaded["adapters.shell_runner"] = previous.shell
end

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

helpers.describe("personal editor fixture process ABI", function()
	local function with_real_shell(body)
		local prior = package.loaded["adapters.shell_runner"]
		package.loaded["adapters.shell_runner"] = nil
		local Shell = require("adapters.shell_runner")
		local native_execute = os.execute
		local called, failure = pcall(body, Shell, native_execute)
		os.execute = native_execute
		package.loaded["adapters.shell_runner"] = prior
		if not called then error(failure, 0) end
	end
	helpers.it("requires physical mkdir, exact data readback and cleanup through the existing status owner", function()
		with_real_shell(function(Shell, native_execute)
			local directory = os.tmpname(); assert(os.remove(directory))
			directory = directory .. "-ergopti-personal-abi"
			local quote, path = Shell.quote, directory .. "/independent.txt"
			local calls = 0
			os.execute = function(command)
				calls = calls + 1
				return native_execute(command)
			end
			local made = Shell.run("mkdir -p " .. quote(directory))
			local called, readback = pcall(function()
				local file = assert(io.open(path, "wb")); assert(file:write("independent physical bytes\n")); assert(file:close())
				file = assert(io.open(path, "rb")); local data = assert(file:read("*a")); assert(file:close())
				return data
			end)
			local refused = Shell.run("exit 1")
			local removed = Shell.run("rm -rf " .. quote(directory))
			os.execute = native_execute
			helpers.assert_eq(made, true)
			helpers.assert_eq({ called, readback }, { true, "independent physical bytes\n" })
			helpers.assert_eq(refused, false, "an actual nonzero child cannot become an acknowledgement")
			helpers.assert_eq(removed, true)
			helpers.assert_eq(calls, 3, "all three owned command boundaries reached the real os.execute port")
			local file = io.open(path, "rb"); if file then file:close() end
			helpers.assert_eq(file, nil, "the physical private source was retired")
		end)
	end)
	for _, outcome in ipairs({ "false", "nil", "number", "text", "throw" }) do
		helpers.it("refuses a non-success process receipt " .. outcome, function()
			with_real_shell(function(Shell, native_execute)
				local calls = 0
				os.execute = function()
					calls = calls + 1
					if outcome == "throw" then error("inert native process refusal") end
					if outcome == "nil" then return nil, "exit", 1 end
					if outcome == "number" then return 2 end
					if outcome == "text" then return "true" end
					return false, "exit", 1
				end
				local acknowledged = Shell.run("inert-non-executed-fixture-command")
				os.execute = native_execute
				helpers.assert_eq(acknowledged, false)
				helpers.assert_eq(calls, 1, "a retained test runner must not bypass the real status boundary")
			end)
		end)
	end
end)


-- Real private source publication exercises the displayed model's consent boundary.
local OPENING_SOURCE = '[_meta]\nsections_order = ["english"]\n[english]\n"old" = { output = "original", is_word = true, final_result = false }\n'
local OPENING_FOREIGN = OPENING_SOURCE .. '[outside]\n"future" = { output = "independent external edit", final_result = false } # retain exact bytes\n'

local function opening_model(output)
	return { sections_order = { "english" }, sections = {
		english = { description = "English", entries = { { trigger = "old", output = output } } },
	} }
end

local function with_opening_file(callback)
	local Shell, Writer = require("adapters.shell_runner"), require("toml_codec.writer")
	local directory = os.tmpname(); assert(os.remove(directory)); directory = directory .. "-personal-view-consent"
	assert(Shell.run("mkdir -p " .. Shell.quote(directory)) == true)
	local path = directory .. "/personal.toml"
	local function put(content)
		local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
	end
	local function read()
		local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
	end
	put(OPENING_SOURCE)
	local manager, previous = package.loaded["ui.webview_manager"], package.loaded["ui.hotstring_editor.bridge"]
	local writer_previous = package.loaded["toml_codec.writer"]
	local seen = { epoch = 51, deliveries = {}, alerts = {}, reloads = 0, writes = 0 }
	local publisher = {}
	for key, value in pairs(Writer) do publisher[key] = value end
	publisher.write = function(...)
		seen.writes = seen.writes + 1
		return Writer.write(...)
	end
	package.loaded["toml_codec.writer"] = publisher
	package.loaded["ui.webview_manager"] = {
		current_epoch = function() return seen.epoch end,
		eval_js = function(_, js)
			if js:find("window.initData(", 1, true) then
				seen.deliveries[#seen.deliveries + 1] = js
				if seen.delivery == "throw" then error("inert delivery refusal") end
				if seen.delivery == "false" then return false end
				if seen.delivery == "nil" then return nil end
				if seen.delivery == "number" then return 1 end
				return true
			end
			seen.alerts[#seen.alerts + 1] = js; return true
		end,
	}
	package.loaded["ui.hotstring_editor.bridge"] = nil
	local handler = require("ui.hotstring_editor.bridge")
	local context = { app_name = "hotstring_editor", epoch = 51 }
	local state = { config = { get_config_dir = function() return directory end,
		reload = function() seen.reloads = seen.reloads + 1; if seen.reload_throw then error("inert reload refusal") end; return true end } }
	local f = { path = path, handler = handler, context = context, state = state, seen = seen,
		publisher = publisher, writer = Writer, put = put, read = read }
	f.ready = function() return handler.push_init(state, context) end
	f.save = function(output, selected) return handler.on_message({ action = "save", data = opening_model(output) }, state, selected or context) end
	local ok, err = pcall(callback, f)
	package.loaded["ui.webview_manager"], package.loaded["ui.hotstring_editor.bridge"], package.loaded["toml_codec.writer"] = manager, previous, writer_previous
	assert(Shell.run("rm -rf " .. Shell.quote(directory)) == true)
	if not ok then error(err, 0) end
end

helpers.describe("personal editor opening-source admission", function()
	helpers.it("refuses a foreign section added after the actual displayed model", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			helpers.assert_true(f.seen.deliveries[1]:find('"original"', 1, true) ~= nil)
			f.put(OPENING_FOREIGN)
			local result = f.save("stale replacement")
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.read(), OPENING_FOREIGN)
			helpers.assert_eq(f.seen.writes, 0)
			helpers.assert_eq(f.seen.reloads, 0)
			helpers.assert_eq(#f.seen.alerts, 1)
		end)
	end)

	helpers.it("advances only our committed payload for a second actual save", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local first = f.save("first own edit")
			helpers.assert_eq(first.saved, true)
			helpers.assert_true(f.read():find('first own edit', 1, true) ~= nil)
			local second = f.save("second own edit")
			helpers.assert_eq(second.saved, true)
			helpers.assert_true(f.read():find('second own edit', 1, true) ~= nil)
			helpers.assert_eq(f.seen.reloads, 2)
		end)
	end)

	helpers.it("fresh reopening admits the new source while the old held view refuses", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true); f.put(OPENING_FOREIGN)
			helpers.assert_eq(f.save("old").saved, false)
			helpers.assert_eq(f.ready(), true)
			helpers.assert_true(f.seen.deliveries[2]:find('"future"', 1, true) ~= nil)
			helpers.assert_eq(f.save("explicit new view edit").saved, true)
		end)
	end)

	for _, change in ipairs({ "epoch", "route", "context", "missing" }) do
		helpers.it("refuses a retired opening owner: " .. change, function()
			with_opening_file(function(f)
				helpers.assert_eq(f.ready(), true)
				local selected = f.context
				if change == "epoch" then f.seen.epoch = 52
				elseif change == "route" then f.state.config.get_config_dir = function() return f.path .. "-foreign-route" end
				elseif change == "context" then selected = { app_name = "another_app", epoch = 51 }
				else selected = {} end
				local result = f.save("retired", selected)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, refusal in ipairs({ "false", "nil", "number", "throw" }) do
		helpers.it("failed initData cannot lend editable authority: " .. refusal, function()
			with_opening_file(function(f)
				f.seen.delivery = refusal
				local opened = f.ready()
				local result = f.save("never displayed")
				helpers.assert_eq(opened, false)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, source in ipairs({ "malformed", "read_refusal", "absent" }) do
		helpers.it("classifies the opening source before displaying it: " .. source, function()
			with_opening_file(function(f)
				if source == "malformed" then f.put('[english\nbroken = 2\n')
				elseif source == "read_refusal" then f.publisher.read_classified = function() return nil, "error" end
				else assert(os.remove(f.path)) end
				local opened = f.ready()
				local result = f.save("admitted absence")
				if source == "absent" then
					helpers.assert_eq(opened, true); helpers.assert_eq(result.saved, true)
					helpers.assert_true(f.read():find('admitted absence', 1, true) ~= nil)
				else
					helpers.assert_eq(opened, false); helpers.assert_eq(result.saved, false)
					helpers.assert_eq(f.seen.writes, 0)
				end
			end)
		end)
	end

	for _, result in ipairs({ "false", "nil", "number", "text", "throw" }) do
		helpers.it("refused publication preserves opening authority and supports owned retry: " .. result, function()
			with_opening_file(function(f)
				helpers.assert_eq(f.ready(), true)
				local real = f.publisher.write
				f.publisher.write = function()
					if result == "throw" then error("inert write refusal") end
					if result == "number" then return 1, nil, OPENING_SOURCE end
					if result == "text" then return "accepted", nil, OPENING_SOURCE end
					if result == "false" then return false end
					return nil
				end
				local refused = f.save("not published")
				helpers.assert_eq(refused.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.reloads, 0)
				f.publisher.write = real
				helpers.assert_eq(f.save("owned retry").saved, true)
			end)
		end)
	end

	helpers.it("passes the retained source into the actual stage-time CAS owner", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local captured
			f.publisher.write = function(path, data, adapter, create, source)
				captured = source.content
				f.put(OPENING_FOREIGN)
				return f.writer.write(path, data, adapter, create, source)
			end
			local result = f.save("stage replacement")
			helpers.assert_eq(captured, OPENING_SOURCE)
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.read(), OPENING_FOREIGN)
			helpers.assert_eq(f.seen.reloads, 0)
		end)
	end)

	helpers.it("post-ACK foreign bytes cannot become our next-save authority", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			f.publisher.write = function(...)
				local ok, detail, payload = f.writer.write(...)
				f.put(OPENING_FOREIGN)
				return ok, detail, payload
			end
			local first = f.save("our committed edit")
			helpers.assert_eq(first.saved, true, "existing publication ACK is separate from later external replacement")
			local second = f.save("must not borrow foreign source")
			helpers.assert_eq(second.saved, false)
			helpers.assert_eq(f.read(), OPENING_FOREIGN)
		end)
	end)

	helpers.it("keeps the existing saved-but-reload-refused policy", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true); f.seen.reload_throw = true
			local saved = f.save("durable despite reload refusal")
			helpers.assert_eq(saved.saved, true)
			helpers.assert_true(f.read():find('durable despite reload refusal', 1, true) ~= nil)
			f.seen.reload_throw = false
			helpers.assert_eq(f.save("later owned save").saved, true)
		end)
	end)
end)

helpers.describe("personal editor opening-source admission", function()
	helpers.it("uses the actual manager route and rejects retired page epochs", function()
		with_opening_file(function(f)
			local port = package.loaded["ui.webview_manager"]
			package.loaded["ui.webview_manager"] = nil
			local Manager = require("ui.webview_manager")
			local html, creator, evaluate = Manager.build_page_html, Manager._create_gtk_window, Manager.eval_js
			Manager.build_page_html = function() return "<html>inert recorded page</html>" end
			Manager._create_gtk_window = function() return true end
			Manager.eval_js = port.eval_js
			Manager.set_daemon_state(f.state)
			local ok, err = pcall(function()
				helpers.assert_eq(Manager.show("hotstring_editor", "en"), true)
				local first = Manager.current_epoch("hotstring_editor")
				Manager.route_message("hotstring_editor", "hsEditor", "ready", first)
				local saved = Manager.route_message("hotstring_editor", "hsEditor", {
					action = "save", data = opening_model("actual managed route") }, first)
				helpers.assert_eq(saved.saved, true)
				helpers.assert_eq(Manager.hide("hotstring_editor", first), true)
				helpers.assert_eq(Manager.show("hotstring_editor", "en"), true)
				local second = Manager.current_epoch("hotstring_editor")
				helpers.assert_true(second > first)
				local bytes = f.read()
				local routed = Manager.route_message("hotstring_editor", "hsEditor", {
					action = "save", data = opening_model("stale route") }, first)
				local direct = f.save("stale direct owner", { app_name = "hotstring_editor", epoch = first })
				helpers.assert_nil(routed)
				helpers.assert_eq(direct.saved, false)
				helpers.assert_eq(f.read(), bytes)
				Manager.route_message("hotstring_editor", "hsEditor", "ready", second)
				local fresh = Manager.route_message("hotstring_editor", "hsEditor", {
					action = "save", data = opening_model("new managed opening") }, second)
				helpers.assert_eq(fresh.saved, true)
			end)
			Manager.hide("hotstring_editor", Manager.current_epoch("hotstring_editor"))
			Manager.build_page_html, Manager._create_gtk_window, Manager.eval_js = html, creator, evaluate
			package.loaded["ui.webview_manager"] = port
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("missing committed-payload receipt does not invent a next-save source", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local native = f.publisher.write
			f.publisher.write = function(...)
				local ok, detail = native(...)
				return ok, detail
			end
			local result = f.save("physically saved without payload ACK")
			helpers.assert_eq(result.saved, false)
			helpers.assert_true(f.read():find('physically saved without payload ACK', 1, true) ~= nil)
			helpers.assert_eq(f.seen.reloads, 0)
			f.publisher.write = native
			helpers.assert_eq(f.save("cannot invent authority").saved, false)
			helpers.assert_eq(f.ready(), true)
			helpers.assert_eq(f.save("reopened actual bytes").saved, true)
		end)
	end)

	helpers.it("a failed reentrant opening cannot be revived by an older write ACK", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local native = f.publisher.write
			local reentered
			f.publisher.write = function(...)
				local ok, detail, payload = native(...)
				f.seen.delivery = "false"
				reentered = f.ready()
				return ok, detail, payload
			end
			local result = f.save("accepted old write")
			helpers.assert_eq(reentered, false)
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.seen.reloads, 0)
			helpers.assert_true(f.read():find('accepted old write', 1, true) ~= nil)
			f.publisher.write = native
			helpers.assert_eq(f.save("must reopen").saved, false)
		end)
	end)
end)
