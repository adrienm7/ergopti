--- tests/unit/ui/test_typing_reset_completion.lua

--- ==============================================================================
--- MODULE: Typing Reset Completion Tests
--- DESCRIPTION:
--- Acknowledges exact reset ownership only after the disk transaction settles.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

helpers.describe("typing reset completion", function()
	for _, mode in ipairs({ "refused", "execution_error", "retired" }) do
		helpers.it("(typing-reset-completion) terminal delivery " .. mode, function()
			with_delivery(function(_, context, _, errors, _, evaluations)
				package.loaded["hs.json"].decode = function() return { action = "clear_cache", reset_id = 1 } end
				local native = context.webview.evaluateJavaScript
				context.webview.evaluateJavaScript = function(self, code, done)
					if mode == "refused" and code:find("complete_cache_reset", 1, true) then return nil end
					return native(self, code, done)
				end
				local original, removals = os.remove, 0
				os.remove = function() removals = removals + 1; return true end
				local ok, err = xpcall(function()
					context.poll(); evaluations[1].done("request", nil); evaluations[2].done(true, nil)
					if mode == "retired" then context.on_close() end
					if mode ~= "refused" then evaluations[3].done(nil, {}) end
					helpers.assert_eq(removals, 1)
					helpers.assert_eq(#errors, mode == "retired" and 0 or 1)
				end, debug.traceback)
				os.remove = original
				if not ok then error(err, 0) end
			end)
		end)
	end
	helpers.it("(typing-reset-completion) purge logging reentry cannot acknowledge the successor with old ownership", function()
		with_delivery(function(_, context, _, _, _, evaluations)
			local id, removals = 1, 0
			package.loaded["hs.json"].decode = function() return { action = "clear_cache", reset_id = id } end
			local function dispatch()
				context.poll(); evaluations[#evaluations].done("request", nil)
				evaluations[#evaluations].done(true, nil)
			end
			package.loaded["infra.logger"].info = function(_, template)
				if template == "Caches cleared by user reset." and id == 1 then id = 2; dispatch() end
			end
			local original = os.remove
			os.remove = function() removals = removals + 1; return true end
			local ok, err = xpcall(function()
				dispatch()
				helpers.assert_eq(removals, 2)
				helpers.assert_eq(#evaluations, 5)
				helpers.assert_eq(evaluations[5].code, "window.complete_cache_reset(2,true);")
			end, debug.traceback)
			os.remove = original
			if not ok then error(err, 0) end
		end)
	end)
	helpers.it("(typing-reset-completion) duplicate retries acknowledgement without repeating purge", function()
		with_delivery(function(_, context, _, _, _, evaluations)
			local id, removals = 1, 0
			package.loaded["hs.json"].decode = function() return { action = "clear_cache", reset_id = id } end
			local original = os.remove
			os.remove = function() removals = removals + 1; return true end
			local ok, err = xpcall(function()
				local function dispatch()
					context.poll(); evaluations[#evaluations].done("request", nil)
					evaluations[#evaluations].done(true, nil)
				end
				dispatch(); dispatch()
				helpers.assert_eq(removals, 1)
				helpers.assert_eq(evaluations[#evaluations].code, "window.complete_cache_reset(1,true);")
				id = 2; dispatch()
				helpers.assert_eq(removals, 2)
				id = 1; dispatch()
				helpers.assert_eq(removals, 2)
				helpers.assert_eq(#evaluations, 11)
			end, debug.traceback)
			os.remove = original
			if not ok then error(err, 0) end
		end)
	end)
	for _, id in ipairs({ false, 0, -1, 1.5, 2 ^ 53, "1", "missing", 0 / 0, math.huge }) do
		helpers.it("(typing-reset-completion) invalid reset owner " .. tostring(id), function()
			with_delivery(function(_, context, _, errors, _, evaluations)
				package.loaded["hs.json"].decode = function()
					if id == "missing" then return { action = "clear_cache" } end
					return { action = "clear_cache", reset_id = id }
				end
				local original, removals = os.remove, 0
				os.remove = function() removals = removals + 1; return true end
				local ok, err = pcall(function()
					context.poll(); evaluations[1].done("request", nil); evaluations[2].done(true, nil)
				end)
				os.remove = original
				if not ok then error(err, 0) end
				helpers.assert_eq(removals, 0)
				helpers.assert_eq(#evaluations, 2)
				helpers.assert_eq(#errors, 1)
				helpers.assert_true(errors[1]:find("invalid reset owner", 1, true) ~= nil)
			end)
		end)
	end
	for _, success in ipairs({ true, false }) do
		helpers.it("(typing-reset-completion) acknowledges actual purge result " .. tostring(success), function()
			with_delivery(function(_, context, _, _, _, evaluations)
				package.loaded["hs.json"].decode = function() return { action = "clear_cache", reset_id = 1 } end
				local original_remove, removals = os.remove, 0
				os.remove = function()
					removals = removals + 1
					helpers.assert_eq(#evaluations, 2, "no completion before native purge")
					if success then return true end
					return nil, "PRIVATE_DETAIL", 13
				end
				local ok, err = xpcall(function()
					context.poll(); evaluations[1].done("request", nil)
					helpers.assert_eq(removals, 0)
					evaluations[2].done(true, nil)
					helpers.assert_eq(removals, 1)
					helpers.assert_eq(#evaluations, 3)
					helpers.assert_eq(evaluations[3].code, "window.complete_cache_reset(1," .. tostring(success) .. ");")
				end, debug.traceback)
				os.remove = original_remove
				if not ok then error(err, 0) end
			end)
		end)
	end
end)
