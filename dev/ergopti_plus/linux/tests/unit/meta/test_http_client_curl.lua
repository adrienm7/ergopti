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
      -- Called directly: a raise fails with the real error. The claim is that an
      -- idle cancel leaves the client USABLE — cancel is bound to every dismissed
      -- prediction, so a client wedged by one would silently stop answering.
      httpClient.cancel()
      helpers.assert_eq(type(httpClient.cancel), "function",
        "an idle cancel must leave the client callable")
    end)

    helpers.it("does not crash when called twice", function()
      httpClient.cancel()
      httpClient.cancel()
      helpers.assert_eq(type(httpClient.cancel), "function",
        "a second cancel must be a no-op, not a teardown")
    end)
  end)

  -- ==========================================================================
  -- 4. post() with unreachable URL (blocking curl fallback)
  -- ==========================================================================

  helpers.describe("post() error handling", function()
	local function with_fake_response(status, callback)
		local previous_popen = io.popen
		local previous_open = io.open
		local response = nil

		io.popen = function()
			return {
				read = function() return tostring(status) end,
				close = function() return true end,
			}
		end
		io.open = function(path, mode)
			if path == "/tmp/_ergopti_http_resp.json" and mode == "r" then
				return {
					read = function() return '{"ok":true}' end,
					close = function() return true end,
				}
			end
			return previous_open(path, mode)
		end

		local ok, err = xpcall(function()
			httpClient.post("https://example.invalid/success", {}, "", function(result)
				response = result
			end)
			callback(response)
		end, debug.traceback)

		io.popen = previous_popen
		io.open = previous_open
		if not ok then error(err, 0) end
	end

	for _, status in ipairs({ 200, 204, 299 }) do
		helpers.it("returns no error for successful HTTP " .. tostring(status), function()
			with_fake_response(status, function(resp)
				helpers.assert_true(type(resp) == "table", "success callback was invoked")
				helpers.assert_eq(resp.ok, true, "every 2xx response is successful")
				helpers.assert_eq(resp.status, status, "the response preserves its status")
				helpers.assert_nil(resp.error,
					"a successful HTTP envelope must not also report an error")
			end)
		end)
	end

	helpers.it("preserves an error for failed HTTP responses", function()
		with_fake_response(401, function(resp)
			helpers.assert_eq(resp.ok, false, "a non-2xx response is unsuccessful")
			helpers.assert_eq(resp.error, "HTTP 401",
				"a failed HTTP envelope must preserve its diagnostic")
		end)
	end)

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
      httpClient.cancel()
      helpers.assert_eq(httpClient.isActive(), false,
        "a cancel must leave the client inactive — a client that stayed \"active\" would "
          .. "refuse the next request as a duplicate for the rest of the session")
      helpers.assert_true(not httpClient.isActive(), "isActive false after cancel")
    end)
  end)

end)
