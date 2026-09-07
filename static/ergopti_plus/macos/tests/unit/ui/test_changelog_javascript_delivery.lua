--- tests/unit/ui/test_changelog_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Changelog JavaScript Delivery
--- DESCRIPTION:
--- Distinguishes native admission from execution through real ready and queued routes.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

--- Captures diagnostics without replacing the real controller publication path.
--- @return table logs Observable lifecycle and error records.
local function observe_logs()
	local logs = { errors = {}, done = 0 }
	local logger = package.loaded["infra.logger"]
	logger.error = function(_, message, ...) logs.errors[#logs.errors + 1] = string.format(message, ...) end
	logger.done = function() logs.done = logs.done + 1 end
	return logs
end

helpers.describe("changelog JavaScript delivery", function()
	helpers.it("bounds repeated failures across distinct submissions in one session (changelog-js-delivery)", function()
		with_changelog(function(changelog, state, post)
			local logs = observe_logs()
			helpers.assert_true(changelog.open())
			post("ready")
			for index = 1, 2 do
				post({ action = "fetch", channel = "main" })
				state.callbacks[index](200, state.main_body, {})
				state.javascript_callbacks[index](nil, { message = "PRIVATE_SCRIPT" })
			end
			helpers.assert_eq(#state.evaluations, 2)
			helpers.assert_eq(#logs.errors, 1)
			helpers.assert_eq(logs.done, 0)
		end)
	end)

	for _, ready in ipairs({ false, true }) do
		helpers.it("observes failed error-state publication, ready=" .. tostring(ready) .. " (changelog-js-delivery)", function()
			with_changelog(function(changelog, state, post)
				local logs = observe_logs()
				helpers.assert_true(changelog.open())
				if ready then post("ready") end
				post({ action = "fetch", channel = "main" })
				state.callbacks[1](503, "", {})
				if not ready then post("ready") end
				helpers.assert_true(state.evaluations[1]:find("injectError", 1, true) ~= nil)
				state.javascript_callbacks[1](nil, { message = "PRIVATE_SCRIPT" })
				helpers.assert_eq(#logs.errors, 1)
				helpers.assert_eq(logs.done, 0)
			end)
		end)
	end

	for _, route in ipairs({ "ready", "queued" }) do
		for _, mode in ipairs({ "throw", "nil", "false", "async_error", "success", "sync_refused", "sync_success" }) do
			helpers.it(route .. " " .. mode .. " observes execution (changelog-js-delivery)", function()
				with_changelog(function(changelog, state, post)
					local logs = observe_logs()
					helpers.assert_true(changelog.open())
					local callbacks, submissions = {}, 0
					state.view.evaluateJavaScript = function(self, code, callback)
						submissions = submissions + 1
						helpers.assert_true(code:find("injectReleases", 1, true) ~= nil)
						callbacks[#callbacks + 1] = callback
						if mode == "throw" then error("PRIVATE_SCRIPT") end
						if mode == "nil" then return nil end
						if mode == "false" then return false end
						if mode:match("^sync") and callback then callback(nil, nil) end
						if mode == "sync_refused" then return nil end
						return self
					end
					if route == "ready" then post("ready") end
					post({ action = "fetch", channel = "main" })
					state.callbacks[1](200, state.main_body, {})
					if route == "queued" then
						helpers.assert_eq(logs.done, 0, "queued content has not executed")
						post("ready")
					end
					helpers.assert_eq(submissions, 1)
					if mode == "success" or mode == "async_error" then
						helpers.assert_eq(logs.done, 0, "admission alone is not success")
						helpers.assert_type(callbacks[1], "function")
						callbacks[1](nil, mode == "async_error" and { message = "PRIVATE_SCRIPT" } or nil)
						callbacks[1](nil, nil)
					end
					local succeeded = mode == "success" or mode == "sync_success"
					helpers.assert_eq(logs.done, succeeded and 1 or 0)
					helpers.assert_eq(#logs.errors, succeeded and 0 or 1)
					helpers.assert_eq(table.concat(logs.errors):find("PRIVATE_SCRIPT", 1, true), nil)
				end)
			end)
		end
	end

	for _, replacement in ipairs({ "channel", "window" }) do
		helpers.it("rejects completion after " .. replacement .. " replacement (changelog-js-delivery)", function()
			with_changelog(function(changelog, state, post)
				local logs = observe_logs()
				helpers.assert_true(changelog.open())
				post("ready")
				post({ action = "fetch", channel = "main" })
				state.callbacks[1](200, state.main_body, {})
				local old = state.javascript_callbacks[1]
				helpers.assert_type(old, "function")
				if replacement == "window" then changelog.close(); helpers.assert_true(changelog.open()) end
				post("ready")
				post({ action = "fetch", channel = "dev" })
				old(nil, { message = "PRIVATE_SCRIPT" })
				old(nil, nil)
				helpers.assert_eq(logs.done, 0)
				helpers.assert_eq(#logs.errors, 0)
				state.callbacks[2](200, state.dev_body, {})
				state.javascript_callbacks[2](nil, nil)
				helpers.assert_eq(logs.done, 1)
			end)
		end)
	end

	helpers.it("bounds failure diagnostics and fences their reentrant successor (changelog-js-delivery)", function()
		with_changelog(function(changelog, state, post)
			local logs = observe_logs()
			helpers.assert_true(changelog.open())
			post("ready")
			post({ action = "fetch", channel = "main" })
			state.callbacks[1](200, state.main_body, {})
			local old = state.javascript_callbacks[1]
			helpers.assert_type(old, "function")
			local logger, first = package.loaded["infra.logger"], true
			local report = logger.error
			logger.error = function(...)
				report(...)
				if first then first = false; changelog.close(); changelog.open() end
			end
			old(nil, { message = "PRIVATE_SCRIPT" })
			old(nil, nil)
			helpers.assert_eq(#logs.errors, 1)
			helpers.assert_eq(state.creates, 2)
			helpers.assert_eq(logs.done, 0)
		end)
	end)
end)
