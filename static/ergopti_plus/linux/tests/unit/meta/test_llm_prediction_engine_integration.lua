--- tests/unit/meta/test_llm_prediction_engine_integration.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine Integration Tests
--- Tests the prediction engine's delegate methods to profiles (get_models,
--- get_current_model, set_model) and the new enable/disable/menu-compat methods.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local REFUSED_STORAGE_MODULES = { "adapters.http_client", "modules.llm.enable_admission",
  "infra.llm_preferences", "modules.llm.profiles", "modules.llm.prediction_engine" }

--- Isolates the actual admission and publication owners, including failed assertions.
--- @param body function Receives profiles, prediction, storage and a version receipt.
local function with_refused_storage(body)
  local previous, pending = {}, nil
  for _, name in ipairs(REFUSED_STORAGE_MODULES) do previous[name] = package.loaded[name] end
  local ok, err = pcall(function()
    local storage = PreferencesFixture.new({
      initial = { ["llm.models.ollama"] = "codellama", ["llm.enabled"] = false },
      writes_fail = true,
    })
    package.loaded["infra.llm_preferences"] = storage
    package.loaded["adapters.http_client"] = {
      get = function(url, _, _, callback)
        helpers.assert_eq(url, "http://127.0.0.1:11434/api/version")
        pending = callback
        return true
      end,
      cancel = function() pending = nil; return true end,
    }
    require("tests.support.owned_http_fixture").attach(package.loaded["adapters.http_client"])
    package.loaded["modules.llm.enable_admission"] = nil
    package.loaded["modules.llm.profiles"] = nil
    package.loaded["modules.llm.prediction_engine"] = nil
    local profiles = require("modules.llm.profiles")
    profiles.init({})
    local prediction = require("modules.llm.prediction_engine")
    prediction.init({})
    body(profiles, prediction, storage, function()
      helpers.assert_type(pending, "function", "the real admission must dispatch a version request")
      local callback = pending
      pending = nil
      callback({ ok = true, status = 200, body = '{"version":"0.12.3"}' })
    end)
  end)
  for _, name in ipairs(REFUSED_STORAGE_MODULES) do package.loaded[name] = previous[name] end
  if not ok then error(err, 0) end
end

helpers.describe("prediction_engine integration", function()

  -- ==========================================================================
  -- 1. Module loads with no mock
  -- ==========================================================================

  PreferencesFixture.it("prediction_engine module loads without error", function()
    local ok, pe = pcall(require, "modules.llm.prediction_engine")
    helpers.assert_true(ok, "require should succeed")
    helpers.assert_true(type(pe) == "table", "should return a table")
  end)

  -- ==========================================================================
  -- 2. Menu-compatible methods after init
  -- ==========================================================================

  helpers.describe("menu-compatible methods", function()
    -- Mock the lazy dependencies so the engine can initialise.
    local function setup_mocks()
      package.loaded["modules.llm.api_ollama"] = {
        chat = function() end,
        cancel = function() end,
      }
      package.loaded["modules.llm.profiles"] = {
        init = function() end,
        get_models = function() return { "codellama", "mistral", "llama3" } end,
        get_current_model = function() return "codellama" end,
        set_model = function() end,
        refresh_models = function() end,
        get_base_url = function() return "http://127.0.0.1:11434" end,
      }
    end

    local function teardown_mocks()
      package.loaded["modules.llm.api_ollama"] = nil
      package.loaded["modules.llm.profiles"] = nil
    end

    setup_mocks()
    local pe = helpers.load_module("modules.llm.prediction_engine")
    pe.init({ engine = {}, keyboard_hook = {} })
    teardown_mocks()

    PreferencesFixture.it("is_enabled returns boolean", function()
      helpers.assert_true(type(pe.is_enabled()) == "boolean")
    end)

    local function with_enable_receipt(body)
      local names = { "adapters.http_client", "modules.llm.enable_admission",
        "modules.llm.profiles", "modules.llm.prediction_engine" }
      local previous, pending = {}, nil
      for _, name in ipairs(names) do previous[name] = package.loaded[name] end
      package.loaded["adapters.http_client"] = {
        get = function(_, _, _, callback) pending = callback; return true end,
        cancel = function() pending = nil; return true end,
      }
      require("tests.support.owned_http_fixture").attach(package.loaded["adapters.http_client"])
    package.loaded["modules.llm.enable_admission"] = nil
      package.loaded["modules.llm.profiles"] = nil
      package.loaded["modules.llm.prediction_engine"] = nil
      local ok, err = pcall(function()
        local preferences = require("infra.llm_preferences")
        helpers.assert_true(preferences.set("llm.enabled", false))
        local engine = require("modules.llm.prediction_engine")
        engine.init({ engine = {}, keyboard_hook = {} })
        body(engine, function()
          helpers.assert_true(type(pending) == "function", "a real version request must precede enable")
          local callback = pending
          pending = nil
          callback({ ok = true, status = 200, body = '{"version":"0.12.3"}' })
        end)
      end)
      for _, name in ipairs(names) do package.loaded[name] = previous[name] end
      if not ok then error(err, 0) end
    end

    PreferencesFixture.it("enable/disable round-trip", function()
      with_enable_receipt(function(engine, answer)
        helpers.assert_true(engine.enable())
        helpers.assert_eq(engine.is_enabled(), false, "a dispatched request is not enable acknowledgement")
        answer()
        helpers.assert_true(engine.is_enabled(), "should be enabled after acknowledged version and write")
        helpers.assert_true(engine.disable())
        helpers.assert_eq(engine.is_enabled(), false, "should be disabled after disable()")
      end)
    end)

    PreferencesFixture.it("toggle flips state", function()
      with_enable_receipt(function(engine, answer)
        helpers.assert_true(engine.toggle())
        helpers.assert_eq(engine.is_enabled(), false)
        answer()
        helpers.assert_true(engine.is_enabled())
        helpers.assert_true(engine.toggle())
        helpers.assert_eq(engine.is_enabled(), false)
        helpers.assert_true(engine.toggle())
        helpers.assert_eq(engine.is_enabled(), false)
        answer()
        helpers.assert_true(engine.is_enabled())
      end)
    end)

    PreferencesFixture.it("get_models delegates to profiles", function()
      setup_mocks()
      local pe2 = helpers.load_module("modules.llm.prediction_engine")
      pe2.init({ engine = {}, keyboard_hook = {} })
      local models = pe2.get_models()
      teardown_mocks()
      helpers.assert_true(type(models) == "table")
      helpers.assert_eq(#models, 3)
    end)

    PreferencesFixture.it("get_current_model delegates to profiles", function()
      setup_mocks()
      local pe2 = helpers.load_module("modules.llm.prediction_engine")
      pe2.init({ engine = {}, keyboard_hook = {} })
      local model = pe2.get_current_model()
      teardown_mocks()
      helpers.assert_eq(model, "codellama")
    end)

    PreferencesFixture.it("get_models returns empty when profiles absent", function()
      local pe2 = helpers.load_module("modules.llm.prediction_engine")
      -- Don't mock profiles — get_models should return {}.
      local models = pe2.get_models()
      helpers.assert_true(type(models) == "table")
      helpers.assert_eq(#models, 0)
    end)

    PreferencesFixture.it("get_max_tokens returns a positive number", function()
      local t = pe.get_max_tokens()
      helpers.assert_true(type(t) == "number")
      helpers.assert_true(t > 0, "max_tokens should be positive")
    end)

    PreferencesFixture.it("get_temperature returns a number in [0, 2]", function()
      local t = pe.get_temperature()
      helpers.assert_true(type(t) == "number")
      helpers.assert_true(t >= 0 and t <= 2, "temperature in range")
    end)

    PreferencesFixture.it("get_triggers returns the configured triggers", function()
      local triggers = pe.get_triggers()
      helpers.assert_true(type(triggers) == "table")
      helpers.assert_true(#triggers >= 2, "should have at least 2 default triggers")
    end)

    PreferencesFixture.it("is_auto_inject is a boolean", function()
      helpers.assert_true(type(pe.is_auto_inject()) == "boolean")
    end)

    PreferencesFixture.it("is_predicting returns false when idle", function()
      helpers.assert_eq(pe.is_predicting(), false)
    end)

    PreferencesFixture.it("get_max_context returns the configured value", function()
      local ctx = pe.get_max_context()
      helpers.assert_true(type(ctx) == "number")
      helpers.assert_true(ctx > 0)
    end)

    PreferencesFixture.it("set_max_context changes the value", function()
      pe.set_max_context(1000)
      helpers.assert_eq(pe.get_max_context(), 1000)
      pe.set_max_context(500)  -- restore
      helpers.assert_eq(pe.get_max_context(), 500)
    end)

  end)

  -- ==========================================================================
  -- 3. Profiles persistence (mock storage)
  -- ==========================================================================

  helpers.describe("profiles persistence", function()
    PreferencesFixture.it("profiles module loads without error", function()
      local ok, pf = pcall(require, "modules.llm.profiles")
      helpers.assert_true(ok, "require should succeed")
      helpers.assert_true(type(pf) == "table", "should return a table")
    end)

    PreferencesFixture.it("profiles.init with empty opts sets defaults", function()
      local pf = helpers.load_module("modules.llm.profiles")
      pf.init({})
      helpers.assert_true(type(pf.is_enabled) == "function")
      helpers.assert_true(type(pf.get_current_model) == "function")
      helpers.assert_true(type(pf.get_models) == "function")
      helpers.assert_true(type(pf.get_base_url) == "function")
      helpers.assert_eq(pf.get_base_url(), "http://127.0.0.1:11434",
        "profiles own an origin, never an operation endpoint")
    end)

    PreferencesFixture.it("profiles query the exact /api/tags endpoint", function()
      local previous_popen = io.popen
      local command = nil
      io.popen = function(value)
        command = value
        return {
          read = function() return '{"models":[{"name":"test-model"}]}' end,
          close = function() return true end,
        }
      end

      local ok, err = pcall(function()
        local pf = helpers.load_module("modules.llm.profiles")
        pf.init({})
        local models = pf.refresh_models()
        helpers.assert_eq(models[1], "test-model")
      end)
      io.popen = previous_popen

      helpers.assert_true(ok, "profile refresh must complete: " .. tostring(err))
      helpers.assert_true(command and command:find("'http://127.0.0.1:11434/api/tags'", 1, true),
        "the model catalogue must request the exact tags endpoint")
      helpers.assert_true(command:find("/api/chat/api/tags", 1, true) == nil,
        "the chat path must never prefix the tags operation")
    end)

    PreferencesFixture.it("profiles.toggle toggles enabled state", function()
      local pf = helpers.load_module("modules.llm.profiles")
      pf.init({})
      local initial = pf.is_enabled()
      pf.toggle()
      helpers.assert_eq(pf.is_enabled(), not initial)
      pf.toggle()
      helpers.assert_eq(pf.is_enabled(), initial)
    end)

    PreferencesFixture.it("profiles.set_model changes current model", function()
      local pf = helpers.load_module("modules.llm.profiles")
      pf.init({ model = "codellama" })
      helpers.assert_eq(pf.get_current_model(), "codellama")
      pf.set_model("llama3")
      helpers.assert_eq(pf.get_current_model(), "llama3")
    end)

    PreferencesFixture.it("profiles and prediction state stay durable when storage fails", function()
      with_refused_storage(function(profiles, prediction, storage, answer)
        helpers.assert_eq(profiles.set_model("llama3"), false)
        helpers.assert_eq(profiles.get_current_model(), "codellama",
          "a failed model write must not publish a session-only selection")
        helpers.assert_eq(profiles.enable(), false)
        helpers.assert_eq(profiles.is_enabled(), false,
          "a failed enable write must not turn only the profile state on")

        local writes, set_many = 0, storage.set_many
        storage.set_many = function(values, expected_source, admission)
          writes = writes + 1
          return set_many(values, expected_source, admission)
        end
        helpers.assert_true(prediction.enable(), "true acknowledges version dispatch only")
        helpers.assert_eq(prediction.is_enabled(), false)
        helpers.assert_eq(writes, 0, "persistence must wait for a successful version receipt")
        answer()
        helpers.assert_eq(writes, 1, "the admitted callback must reach the refusing durable writer")
        helpers.assert_eq(storage.get("llm.enabled"), false)
        helpers.assert_eq(profiles.is_enabled(), false)
        helpers.assert_eq(prediction.is_enabled(), false,
          "the engine must not diverge from the profile that refused persistence")
      end)
    end)

    helpers.it("refused-storage fixture restores all owners after an assertion failure", function()
      local previous = {}
      for _, name in ipairs(REFUSED_STORAGE_MODULES) do previous[name] = package.loaded[name] end
      local ok, err = pcall(function()
        with_refused_storage(function(_, prediction)
          helpers.assert_true(prediction.enable())
          error("refused-storage-cleanup-sentinel", 0)
        end)
      end)
      helpers.assert_eq(ok, false)
      helpers.assert_true(tostring(err):find("refused-storage-cleanup-sentinel", 1, true) ~= nil)
      for _, name in ipairs(REFUSED_STORAGE_MODULES) do
        helpers.assert_true(rawequal(package.loaded[name], previous[name]), "the prior identity must survive: " .. name)
      end
      helpers.assert_type(require("infra.llm_preferences").mark_config_read, "function")
      local settings = require("modules.llm.settings")
      local read_ok, read_error = pcall(settings.mark_config_reads, {}, function() end)
      helpers.assert_true(read_ok, "the real configuration reader must remain usable: " .. tostring(read_error))
    end)
  end)

end)
