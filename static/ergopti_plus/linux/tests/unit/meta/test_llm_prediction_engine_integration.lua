--- tests/unit/meta/test_llm_prediction_engine_integration.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine Integration Tests
--- Tests the prediction engine's delegate methods to profiles (get_models,
--- get_current_model, set_model) and the new enable/disable/menu-compat methods.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

helpers.describe("prediction_engine integration", function()

  -- ==========================================================================
  -- 1. Module loads with no mock
  -- ==========================================================================

  helpers.it("prediction_engine module loads without error", function()
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
      package.loaded["adapters.text_sender"] = {
        send = function() end,
        eraseChars = function() end,
      }
    end

    local function teardown_mocks()
      package.loaded["modules.llm.api_ollama"] = nil
      package.loaded["modules.llm.profiles"] = nil
      package.loaded["adapters.text_sender"] = nil
    end

    setup_mocks()
    local pe = helpers.load_module("modules.llm.prediction_engine")
    pe.init({ engine = {}, keyboard_hook = {} })
    teardown_mocks()

    helpers.it("is_enabled returns boolean", function()
      helpers.assert_true(type(pe.is_enabled()) == "boolean")
    end)

    helpers.it("enable/disable round-trip", function()
      pe.enable()
      helpers.assert_true(pe.is_enabled(), "should be enabled after enable()")
      pe.disable()
      helpers.assert_eq(pe.is_enabled(), false, "should be disabled after disable()")
      pe.enable()
    end)

    helpers.it("toggle flips state", function()
      pe.enable()
      pe.toggle()
      helpers.assert_eq(pe.is_enabled(), false)
      pe.toggle()
      helpers.assert_true(pe.is_enabled())
    end)

    helpers.it("get_models delegates to profiles", function()
      setup_mocks()
      local pe2 = helpers.load_module("modules.llm.prediction_engine")
      pe2.init({ engine = {}, keyboard_hook = {} })
      local models = pe2.get_models()
      teardown_mocks()
      helpers.assert_true(type(models) == "table")
      helpers.assert_eq(#models, 3)
    end)

    helpers.it("get_current_model delegates to profiles", function()
      setup_mocks()
      local pe2 = helpers.load_module("modules.llm.prediction_engine")
      pe2.init({ engine = {}, keyboard_hook = {} })
      local model = pe2.get_current_model()
      teardown_mocks()
      helpers.assert_eq(model, "codellama")
    end)

    helpers.it("get_models returns empty when profiles absent", function()
      local pe2 = helpers.load_module("modules.llm.prediction_engine")
      -- Don't mock profiles — get_models should return {}.
      local models = pe2.get_models()
      helpers.assert_true(type(models) == "table")
      helpers.assert_eq(#models, 0)
    end)

    helpers.it("get_max_tokens returns a positive number", function()
      local t = pe.get_max_tokens()
      helpers.assert_true(type(t) == "number")
      helpers.assert_true(t > 0, "max_tokens should be positive")
    end)

    helpers.it("get_temperature returns a number in [0, 2]", function()
      local t = pe.get_temperature()
      helpers.assert_true(type(t) == "number")
      helpers.assert_true(t >= 0 and t <= 2, "temperature in range")
    end)

    helpers.it("get_triggers returns the configured triggers", function()
      local triggers = pe.get_triggers()
      helpers.assert_true(type(triggers) == "table")
      helpers.assert_true(#triggers >= 2, "should have at least 2 default triggers")
    end)

    helpers.it("is_auto_inject is a boolean", function()
      helpers.assert_true(type(pe.is_auto_inject()) == "boolean")
    end)

    helpers.it("is_predicting returns false when idle", function()
      helpers.assert_eq(pe.is_predicting(), false)
    end)

    helpers.it("get_max_context returns the configured value", function()
      local ctx = pe.get_max_context()
      helpers.assert_true(type(ctx) == "number")
      helpers.assert_true(ctx > 0)
    end)

    helpers.it("set_max_context changes the value", function()
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
    helpers.it("profiles module loads without error", function()
      local ok, pf = pcall(require, "modules.llm.profiles")
      helpers.assert_true(ok, "require should succeed")
      helpers.assert_true(type(pf) == "table", "should return a table")
    end)

    helpers.it("profiles.init with empty opts sets defaults", function()
      local pf = helpers.load_module("modules.llm.profiles")
      pf.init({})
      helpers.assert_true(type(pf.is_enabled) == "function")
      helpers.assert_true(type(pf.get_current_model) == "function")
      helpers.assert_true(type(pf.get_models) == "function")
      helpers.assert_true(type(pf.get_base_url) == "function")
    end)

    helpers.it("profiles.toggle toggles enabled state", function()
      local pf = helpers.load_module("modules.llm.profiles")
      pf.init({})
      local initial = pf.is_enabled()
      pf.toggle()
      helpers.assert_eq(pf.is_enabled(), not initial)
      pf.toggle()
      helpers.assert_eq(pf.is_enabled(), initial)
    end)

    helpers.it("profiles.set_model changes current model", function()
      local pf = helpers.load_module("modules.llm.profiles")
      pf.init({ model = "codellama" })
      helpers.assert_eq(pf.get_current_model(), "codellama")
      pf.set_model("llama3")
      helpers.assert_eq(pf.get_current_model(), "llama3")
    end)

    helpers.it("profiles and prediction state stay durable when storage fails", function()
      local previous_storage = package.loaded["adapters.storage"]
      local previous_profiles = package.loaded["modules.llm.profiles"]
      local previous_prediction = package.loaded["modules.llm.prediction_engine"]
      local storage = Fakes.storage({
        initial = { ["llm.model"] = "codellama", ["llm.enabled"] = false },
        writes_fail = true,
      })
      package.loaded["adapters.storage"] = storage
      package.loaded["modules.llm.profiles"] = nil
      local profiles = require("modules.llm.profiles")
      profiles.init({})

      helpers.assert_eq(profiles.set_model("llama3"), false)
      helpers.assert_eq(profiles.get_current_model(), "codellama",
        "a failed model write must not publish a session-only selection")
      helpers.assert_eq(profiles.enable(), false)
      helpers.assert_eq(profiles.is_enabled(), false,
        "a failed enable write must not turn only the profile state on")

      package.loaded["modules.llm.prediction_engine"] = nil
      local prediction = require("modules.llm.prediction_engine")
      prediction.init({})
      helpers.assert_eq(prediction.enable(), false)
      helpers.assert_eq(prediction.is_enabled(), false,
        "the engine must not diverge from the profile that refused persistence")

      package.loaded["adapters.storage"] = previous_storage
      package.loaded["modules.llm.profiles"] = previous_profiles
      package.loaded["modules.llm.prediction_engine"] = previous_prediction
    end)
  end)

end)
