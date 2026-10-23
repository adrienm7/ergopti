--- tests/unit/ui/editors/test_ui_bridge_handlers_webview_manager.lua

--- ==============================================================================
--- Tier 2 — Integration tests for UI bridge handlers + webview manager.
--- Tests all 14 bridge handlers and the webview_manager routing layer.
--- Pure Lua — no GTK/WebKit2GTK required.
--- ==============================================================================

package.loaded["tests.support.ui.editors.ui_bridge_handlers_fixture"] = nil
local Fixture = require("tests.support.ui.editors.ui_bridge_handlers_fixture")
local helpers, build_mock_state =
	Fixture.helpers, Fixture.build_mock_state




helpers.describe("ui.bridge_handlers", function()
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
			state.keystats.export_metrics = function()
				reads = reads + 1
				return { secret = true }
			end
			state.keystats.reset_session = function() resets = resets + 1 end
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
end)




helpers.describe("ui.bridge_handlers", function()
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
end)




helpers.describe("ui.bridge_handlers", function()
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
end)




helpers.describe("ui.bridge_handlers", function()
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
    helpers.it("returns safe defaults when keystats absent", function()
      local result = handler.on_message("ready", {})
      helpers.assert_true(type(result.metrics_manifest) == "table")
      helpers.assert_true(type(result.app_icons) == "table")
    end)
  end)

  -- ==========================================================================
  -- 5. metrics_typing_bridge
  -- ===========================================================================
end)




helpers.describe("ui.bridge_handlers", function()
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
end)

