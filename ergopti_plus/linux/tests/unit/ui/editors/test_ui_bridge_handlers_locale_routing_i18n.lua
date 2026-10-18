--- tests/unit/ui/editors/test_ui_bridge_handlers_locale_routing_i18n.lua

--- ==============================================================================
--- Tier 2 — Integration tests for UI bridge handlers + webview manager.
--- Tests all 14 bridge handlers and the webview_manager routing layer.
--- Pure Lua — no GTK/WebKit2GTK required.
--- ==============================================================================

package.loaded["tests.support.ui.editors.ui_bridge_handlers_fixture"] = nil
local Fixture = require("tests.support.ui.editors.ui_bridge_handlers_fixture")
local helpers, build_mock_state, make_spies, with_opened_spies =
	Fixture.helpers, Fixture.build_mock_state, Fixture.make_spies, Fixture.with_opened_spies




helpers.describe("ui.bridge_handlers", function()
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
end)




helpers.describe("ui.bridge_handlers", function()
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
end)




helpers.describe("ui.bridge_handlers", function()
  helpers.describe("changelog_bridge", function()
    local handler = helpers.load_module("ui.changelog.bridge")
    local original_handler = handler
    local native_document = require("tests.support.document_fixture").new("changelog", original_handler, build_mock_state())
    handler = native_document.proxy()
    local state = build_mock_state()
    -- The native fetch is covered by test_changelog_release_sources; keep these
    -- protocol cases off the network.
    original_handler._http_get = function() end
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
    native_document.close()
  end)

  -- ==========================================================================
  -- 9. dl_bridge
  -- ==========================================================================
end)




helpers.describe("ui.bridge_handlers", function()
  helpers.describe("dl_bridge", function()
    local handler = helpers.load_module("ui.download_window.bridge")
	helpers.it("linux-model-pull-retry-retirement: progress retries preserve successful settlement", function()
		local previous_manager = package.loaded["ui.webview_manager"]
		local evaluated, retries = {}, 0
		local native_document = require("tests.support.document_fixture").new("download_window", handler, {})
      native_document.on_effect = function(code) evaluated[#evaluated + 1] = code end
      local original_handler = handler
      handler = native_document.proxy()
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
		native_document.close(); handler = original_handler
      package.loaded["ui.webview_manager"] = previous_manager
		if not ok then error(err) end
	end)

    helpers.it("has correct bridge_name", function()
      helpers.assert_eq(handler.bridge_name, "dl_bridge")
    end)
    helpers.it("owns ready, progress, cancel, and retry for one exact session", function()
      local previous_manager = package.loaded["ui.webview_manager"]
      local evaluated, cancelled, retried = {}, 0, 0
      local native_document = require("tests.support.document_fixture").new("download_window", handler, {})
      native_document.on_effect = function(code) evaluated[#evaluated + 1] = { app = "download_window", code = code } end
      local original_handler = handler
      handler = native_document.proxy()
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

      local cancel = handler.on_message({ action = "cancel", session = session_id })
      helpers.assert_true(cancel.cancelled)
      helpers.assert_eq(cancelled, 1)
      helpers.assert_true(evaluated[#evaluated].code:find("done(false", 1, true) ~= nil)
      helpers.assert_eq(handler.on_message("retry").retried, false, "an unbound retained string cannot retry cancellation")
      -- A new explicit request owns a failed retry fixture; cancellation itself
      -- does not keep authorization to restart the retired native operation.
      local retry_id = handler.show({ kind = "ollama_model", label = "Owned retry fixture",
        on_retry = function() retried = retried + 1; return true end })
      helpers.assert_true(handler.complete(retry_id, false, "Independent download failure"))
      local failure_epoch = handler.on_message("ready").failure_epoch
      local retry = handler.on_message({ action = "failure_action", id = "retry",
        session = retry_id, epoch = failure_epoch })
      helpers.assert_true(retry.retried)
      helpers.assert_eq(retried, 1)
      native_document.close(); handler = original_handler
      package.loaded["ui.webview_manager"] = previous_manager
    end)

    helpers.it("replays terminal state when transport finishes before page ready", function()
      local previous_manager = package.loaded["ui.webview_manager"]
      local evaluated = {}
      local native_document = require("tests.support.document_fixture").new("download_window", handler, {})
      native_document.on_effect = function(code) evaluated[#evaluated + 1] = code end
      local original_handler = handler
      handler = native_document.proxy()
      handler._reset()
      local session_id = handler.show({ kind = "ollama_model", label = "Fast fixture" })
      helpers.assert_true(handler.complete(session_id, true, "Installed"))
      helpers.assert_eq(#evaluated, 0)
      helpers.assert_true(handler.on_message("ready").pushed)
      helpers.assert_true(evaluated[1]:find("done(true", 1, true) ~= nil)
      helpers.assert_true(evaluated[1]:find("Installed", 1, true) ~= nil)
      native_document.close(); handler = original_handler
      package.loaded["ui.webview_manager"] = previous_manager
    end)

    helpers.it("titles the window by its kind and refuses a kind the page does not know", function()
      local previous_manager = package.loaded["ui.webview_manager"]
      local evaluated = {}
      local native_document = require("tests.support.document_fixture").new("download_window", handler, {})
      native_document.on_effect = function(code) evaluated[#evaluated + 1] = code end
      local original_handler = handler
      handler = native_document.proxy()
      handler._reset()
      helpers.assert_nil(handler.show({ label = "No kind" }), "a producer must name its kind")
      helpers.assert_nil(handler.show({ kind = "firmware", label = "Unknown kind" }))
      local session_id = handler.show({ kind = "app_update", label = "ErgoptiPlus v0.0.0-dev.150" })
      helpers.assert_true(type(session_id) == "number")
      helpers.assert_true(handler.on_message("ready").pushed)
      helpers.assert_true(evaluated[1]:find('setKind("app_update"', 1, true) ~= nil,
        "the page shows the app-update heading: " .. tostring(evaluated[1]))
      native_document.close(); handler = original_handler
      package.loaded["ui.webview_manager"] = previous_manager
      handler._reset()
    end)
  end)

  -- ==========================================================================
  -- 10. hotstring_editor_bridge
  -- ==========================================================================
end)




helpers.describe("ui.bridge_handlers", function()
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
        local result = h.on_message({
          action = "save",
          data = {
            sections_order = { "english" },
            sections = { english = { description = "English", entries = {
              { trigger = "ty", output = "thank you" },
            } } },
          },
        }, state, context)
        helpers.assert_true(result.saved, "the genuine writer must acknowledge the displayed model")
        local entries = captured.data.sections.english.entries
        helpers.assert_eq(#entries, 1, "only what the editor sent may be on disk")
        helpers.assert_eq(entries[1].trigger, "ty", "and it must be the entry it sent")
      end)
    end)
    helpers.it("'save' drops an entry with no trigger instead of writing it", function()
      local reader, writer, captured = make_spies(true)
      with_opened_spies(reader, writer, state, function(h, context)
        local result = h.on_message({
          action = "save",
          data = {
            sections_order = { "work" },
            sections = { work = { entries = {
              { trigger = "", output = "orphaned" },
              { trigger = "ok", output = "okay" },
            } } },
          },
        }, state, context)
        helpers.assert_true(result.saved, "the genuine writer must acknowledge the displayed model")
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
end)

