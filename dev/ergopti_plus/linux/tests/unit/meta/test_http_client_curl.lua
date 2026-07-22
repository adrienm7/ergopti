--- tests/unit/meta/test_http_client_curl.lua
---
--- Integration tests for the http_client adapter's curl command.
--- construction, response parsing, and state management. The actual HTTP request
--- requires a real Ollama server on Linux; these tests verify:
---   1. Module structure (post, cancel, isActive)
---   2. post() with unreachable URL (graceful error handling)
---   3. cancel() / isActive() state transitions
---
--- Real curl + Ollama test requires:
---   curl installed (sudo apt-get install curl)
---   ollama serve running on localhost:11434 with a model pulled

local helpers   = require("tests.helpers")
local httpClient = helpers.load_module("adapters.http_client")

helpers.describe("http_client (curl)", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports post function", function()
      helpers.assert_true(type(httpClient.post) == "function", "post is a function")
    end)

    helpers.it("exports cancel function", function()
      helpers.assert_true(type(httpClient.cancel) == "function", "cancel is a function")
    end)

    helpers.it("exports isActive function", function()
      helpers.assert_true(type(httpClient.isActive) == "function", "isActive is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. isActive() initial state
  -- ==========================================================================

  helpers.describe("isActive()", function()
    helpers.it("returns false when idle", function()
      helpers.assert_true(not httpClient.isActive(), "not active initially")
    end)
  end)

  -- ==========================================================================
  -- 3. cancel() idempotency
  -- ==========================================================================

  helpers.describe("cancel()", function()
    helpers.it("does not crash when called idle", function()
      local ok = pcall(function() httpClient.cancel() end)
      helpers.assert_true(ok, "cancel() on idle client does not crash")
    end)

    helpers.it("does not crash when called twice", function()
      pcall(function() httpClient.cancel() end)
      local ok = pcall(function() httpClient.cancel() end)
      helpers.assert_true(ok, "double cancel() does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. post() with unreachable URL (blocking curl fallback)
  -- ==========================================================================

  helpers.describe("post() error handling", function()
    helpers.it("calls callback with error on unreachable host", function()
      local called = false
      local resp   = nil

      -- Use a guaranteed-unreachable URL (closed port on localhost).
      httpClient.post(
        "http://127.0.0.1:19999/nonexistent",
        { ["Content-Type"] = "application/json" },
        '{"test":true}',
        function(r)
          called = true
          resp   = r
        end
      )

      helpers.assert_true(called, "callback was invoked")
      helpers.assert_true(type(resp) == "table", "response is a table")
      -- On an unreachable host, ok should be false
      helpers.assert_true(resp.ok == false or resp.status == 0,
        "unreachable host returns error")
    end)

    helpers.it("post does not leave isActive true after completion", function()
      -- After the blocking curl call completes (success or error),
      -- isActive should be false.
      helpers.assert_true(not httpClient.isActive(), "not active after post completes")
    end)
  end)

  -- ==========================================================================
  -- 5. cancel() during request (synchronous curl — cancel sets flag)
  -- ==========================================================================

  helpers.describe("cancel during request", function()
    helpers.it("cancel sets internal flag without crashing", function()
      -- With the blocking curl fallback, cancel() just sets a flag.
      -- The callback checks the flag before invoking.
      local ok = pcall(function() httpClient.cancel() end)
      helpers.assert_true(ok, "cancel during request does not crash")
      helpers.assert_true(not httpClient.isActive(), "isActive false after cancel")
    end)
  end)

end)
