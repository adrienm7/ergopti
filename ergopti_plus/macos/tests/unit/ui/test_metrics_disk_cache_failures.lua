--- tests/unit/ui/test_metrics_disk_cache_failures.lua

--- ==============================================================================
--- MODULE: Metrics Disk Cache Failure Boundaries
--- DESCRIPTION:
--- Cache persistence failures remain visible without blocking live publication.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.metrics_delivery_fixture")

helpers.describe("metrics disk cache persistence", function()
	for _, mode in ipairs({ "throw", "nil", "number" }) do
		helpers.it("(metrics-cache-write) rejects encoding " .. mode .. " before opening", function()
			with_delivery(false, function(dashboard, _, evaluations, _, successes, pending)
				local previous_open, opens, warnings = io.open, 0, 0
				local ok, err = xpcall(function()
					package.loaded["hs.json"].encode = function(value)
						if type(value.manifest) == "string" then
							if mode == "throw" then error("PRIVATE_CACHE_PAYLOAD") end
							if mode == "number" then return 42 end
							return nil
						end
						return "{}"
					end
					package.loaded["infra.logger"].warn = function(_, message, ...)
						warnings = warnings + 1
						helpers.assert_true(string.format(message, ...):find("encoding", 1, true) ~= nil)
					end
					io.open = function() opens = opens + 1; error("cache must not open") end
					helpers.assert_true(dashboard.push_live_update())
					pending[#pending]()
					helpers.assert_eq(opens, 0)
					helpers.assert_eq(warnings, 1)
					evaluations[#evaluations].done("function")
					evaluations[#evaluations].done(true)
					helpers.assert_eq(#successes, 1)
				end, debug.traceback)
				io.open = previous_open
				if not ok then error(err, 0) end
			end)
		end)
	end
	helpers.it("(metrics-cache-write) throttles an outage and rearms after recovery", function()
		with_delivery(false, function(dashboard, _, _, _, _, pending)
			local previous_open, refused, warnings = io.open, true, 0
			local ok, err = xpcall(function()
				package.loaded["infra.logger"].warn = function() warnings = warnings + 1 end
				io.open = function()
					if refused then return nil, "PRIVATE_CACHE_PATH", 13 end
					return { write = function(self) return self end, close = function() return true end }
				end
				local function refresh()
					helpers.assert_true(dashboard.push_live_update())
					pending[#pending]()
				end
				refresh(); refresh()
				helpers.assert_eq(warnings, 1)
				refused = false
				refresh()
				helpers.assert_eq(warnings, 1)
				refused = true
				refresh()
				helpers.assert_eq(warnings, 2)
			end, debug.traceback)
			io.open = previous_open
			if not ok then error(err, 0) end
		end)
	end)
	for _, mode in ipairs({ "open_refused", "open_throw", "write_refused", "write_throw",
		"close_refused", "close_throw", "success" }) do
		helpers.it("(metrics-cache-write) reports " .. mode .. " without losing live UI", function()
			with_delivery(false, function(dashboard, _, evaluations, errors, successes, pending)
				local previous_open = io.open
				local warnings, opens, writes, closes = {}, 0, 0, 0
				local ok, err = xpcall(function()
					package.loaded["infra.logger"].warn = function(_, message, ...)
						warnings[#warnings + 1] = string.format(message, ...)
					end
					io.open = function(_, file_mode)
						helpers.assert_eq(file_mode, "w")
						opens = opens + 1
						if mode == "open_throw" then error("PRIVATE_CACHE_PATH") end
						if mode == "open_refused" then return nil, "PRIVATE_CACHE_PATH", 13 end
						return {
							write = function(self)
								writes = writes + 1
								if mode == "write_throw" then error("PRIVATE_CACHE_PAYLOAD") end
								if mode == "write_refused" then return nil, "PRIVATE_CACHE_PAYLOAD", 28 end
								return self
							end,
							close = function()
								closes = closes + 1
								if mode == "close_throw" then error("PRIVATE_CACHE_PATH") end
								if mode == "close_refused" then return nil, "PRIVATE_CACHE_PATH", 28 end
								return true
							end,
						}
					end
					helpers.assert_true(dashboard.push_live_update())
					pending[#pending]()
					helpers.assert_eq(opens, 1)
					helpers.assert_eq(#warnings, mode == "success" and 0 or 1)
					if mode ~= "success" then
						helpers.assert_true(warnings[1]:find("cache", 1, true) ~= nil)
						helpers.assert_eq(warnings[1]:find("PRIVATE_CACHE", 1, true), nil)
					end
					if mode == "write_refused" or mode == "write_throw" or mode == "close_refused" or mode == "success" then
						helpers.assert_eq(writes, 1)
						helpers.assert_eq(closes, 1)
					end
					evaluations[#evaluations].done("function")
					evaluations[#evaluations].done(true)
					helpers.assert_eq(#successes, 1)
					helpers.assert_eq(#errors, 0)
				end, debug.traceback)
				io.open = previous_open
				if not ok then error(err, 0) end
			end)
		end)
	end
end)
