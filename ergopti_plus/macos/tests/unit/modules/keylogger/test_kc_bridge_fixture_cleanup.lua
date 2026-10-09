--- tests/unit/modules/keylogger/test_kc_bridge_fixture_cleanup.lua

--- ==============================================================================
--- MODULE: Karabiner Ledger Fixture Cleanup Regressions
--- DESCRIPTION:
--- Observes real scratch paths, producer retirement and predecessor restoration.
--- ==============================================================================

local helpers = require("tests.helpers")
local fs = require("tests.stubs.hs").fs
local fixture = require("tests.support.kc_bridge_fixture")

local owners = {
	"infra.logger", "infra.config_paths", "adapters.timer_scheduler",
	"modules.keylogger.kc_bridge", "modules.keylogger", "tests.stubs.hs",
}
helpers.describe("KC fixture cleanup and owner restoration", function()
	for _, predecessor_kind in ipairs({ "absent", "false", "table" }) do
		for _, mode in ipairs({ "success", "callback", "metrics" }) do
			helpers.it("(kc-fixture-cleanup) " .. predecessor_kind .. "/" .. mode, function()
				helpers.with_fresh_modules(owners, function()
					local previous = {}
					for _, name in ipairs(owners) do
						local value
						if predecessor_kind == "false" then value = false end
						if predecessor_kind == "table" then value = {} end
						package.loaded[name], previous[name] = value, value
					end
					local previous_hs, original_require = rawget(_G, "hs"), require
					local marker = "kc-cleanup-" .. mode
					local ctx, bridge, callback_reached, injected
					if mode == "metrics" then
						_G.require = function(name)
							local results = table.pack(original_require(name))
							if name == "tests.stubs.hs" and not injected then
								local native_mkdir = results[1].fs.mkdir
								results[1].fs.mkdir = function(path)
									if path:match("/metrics$") then
										injected = true
										return nil, marker
									end
									return native_mkdir(path)
								end
							end
							return table.unpack(results, 1, results.n)
						end
					end
					local allocated
					local original_tmpname = os.tmpname
					os.tmpname = function() allocated = original_tmpname(); return allocated end
					local outcome = table.pack(pcall(fixture.with_context, function(value)
						ctx, callback_reached = value, true
						bridge = ctx.load()
						assert(bridge.init({ ok = true }, nil, {}, {}, function() return true end) == true)
						ctx.append("a")
						ctx.watcher_callback()
						assert(bridge.get_stats().offset > 0, "real ledger must have drained")
						if mode == "callback" then error(marker) end
						return "first", nil, "third"
					end))
					_G.require, os.tmpname = original_require, original_tmpname
					local root_exists = allocated and fs.attributes(allocated) ~= nil
					local active_producers = 0
					if ctx then
						for _, handles in ipairs({ ctx.watchers, ctx.timers }) do
							for _, handle in ipairs(handles) do
								if handle.active then active_producers = active_producers + 1 end
							end
						end
					end
					-- Rescue only artifacts and handles observed from this exact invocation.
					if bridge then assert(bridge.stop() == true) end
					if root_exists then
						local log_path = allocated .. "/metrics/karabiner_kc.log"
						if fs.attributes(log_path) then assert(os.remove(log_path)) end
						assert(fs.rmdir(allocated .. "/metrics"))
						assert(fs.rmdir(allocated))
					end
					assert(type(allocated) == "string", "must allocate an actual scratch path")
					assert(outcome[1] == (mode == "success"), tostring(outcome[2]))
					if mode == "success" then
						assert(outcome.n == 4 and outcome[2] == "first" and outcome[3] == nil and outcome[4] == "third")
					elseif mode == "callback" then
						assert(tostring(outcome[2]):find(marker, 1, true), tostring(outcome[2]))
					else
						assert(injected and not callback_reached, "construction refusal must precede callback")
						assert(tostring(outcome[2]):find(marker, 1, true), "native mkdir error must remain visible")
					end
					assert(not root_exists, "scratch root must be absent before rescue cleanup")
					assert(active_producers == 0, "watchers and timers must be stopped before rescue cleanup")
					assert(rawget(_G, "hs") == previous_hs, "native host must be restored")
					for _, name in ipairs(owners) do
						assert(package.loaded[name] == previous[name], "owner not restored: " .. name)
					end
				end)
			end)
		end
	end
end)
