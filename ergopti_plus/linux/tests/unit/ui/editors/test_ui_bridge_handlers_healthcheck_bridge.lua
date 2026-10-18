--- tests/unit/ui/editors/test_ui_bridge_handlers_healthcheck_bridge.lua

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
end)

