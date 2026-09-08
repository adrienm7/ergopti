--- tests/unit/infra/test_app_picker_logger_reentry.lua

--- ==============================================================================
--- MODULE: Application Picker Diagnostic Reentry
--- DESCRIPTION:
--- Diagnostic sinks can start new requests but cannot restore obsolete authority.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.app_picker_discovery_fixture")

helpers.describe("app_picker: chooser authority across diagnostic reentry", function()
	for _, boundary in ipairs({ "request", "cleanup", "queued" }) do
		helpers.it("keeps only the latest settings destination after " .. boundary .. " logging", function()
			with_picker(function(picker, state)
				local applied = {}
				local function action(label)
					return picker.build_menu({}, function() applied[#applied + 1] = label end)[1].action
				end
				local a, b, c = action("A"), action("B"), action("C")
				local needle = boundary == "request" and "started."
					or boundary == "cleanup" and "cleanup completed" or "queued behind"
				if boundary == "cleanup" then
					a()
					state.pending[1].callback(0, "/Applications/A.app\0")
				end
				state.on_log = function(_, message)
					if message:find(needle, 1, true) then
						state.on_log = nil
						c()
					end
				end
				if boundary == "queued" then
					local original_new = _G.hs.chooser.new
					local reentered = false
					_G.hs.chooser.new = function(callback)
						local chooser = original_new(callback)
						local original_show = chooser.show
						function chooser:show()
							if not reentered then reentered = true; b() end
							return original_show(self)
						end
						return chooser
					end
				end
				if boundary == "cleanup" then b() else a() end
				if boundary == "request" then
					helpers.assert_eq(#state.pending, 2)
					state.pending[1].callback(0, "/Applications/Current.app\0")
					state.pending[2].callback(0, "/Applications/Stale.app\0")
				elseif boundary == "queued" then
					state.pending[1].callback(0, "/Applications/Current.app\0")
				end
				if boundary ~= "request" then
					helpers.assert_eq(#state.deferred, 1)
					table.remove(state.deferred, 1)()
				end
				helpers.assert_nil(state.on_log, "the target diagnostic boundary must actually run")
				helpers.assert_eq(#applied, 0)
				helpers.assert_eq(#state.choosers, boundary == "request" and 1 or 2)
				for _, chooser in ipairs(state.choosers) do
					chooser.callback({ text = "Current", appPath = "/Applications/Current.app" })
				end
				helpers.assert_eq(applied, { "C" }, "retired callbacks must not change any settings destination")
			end)
		end)
	end
end)
