--- tests/unit/adapters/test_clipboard_native_result_contract.lua

--- ==============================================================================
--- MODULE: Clipboard adapter native-result contract
--- DESCRIPTION:
--- Hammerspoon clipboard writers return booleans. A successful pcall containing
--- false or nil is an operational refusal, not a committed write/restore.
--- `clearContents()` is the exception: it has no result and succeeds on non-throw.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_clipboard(pasteboard)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("adapters.clipboard", { pasteboard = pasteboard })
end


helpers.describe("clipboard adapter: native boolean results are authoritative", function()
	for _, refusal in ipairs({ false, "nil" }) do
		helpers.it("write returns false when setContents returns " .. tostring(refusal), function()
			local clipboard = load_clipboard({
				setContents = function()
					if refusal == "nil" then return nil end
					return refusal
				end,
			})
			helpers.assert_eq(clipboard.write("payload"), false,
				"pcall success must not turn a refused native write into success")
		end)

		helpers.it("restore returns false when writeAllData returns " .. tostring(refusal), function()
			local clipboard = load_clipboard({
				writeAllData = function()
					if refusal == "nil" then return nil end
					return refusal
				end,
			})
			helpers.assert_eq(clipboard.restore({ ["public.utf8-plain-text"] = "original" }), false,
				"pcall success must not release clipboard ownership after restore refusal")
		end)
	end

	helpers.it("restore nil accepts clearContents' documented void result", function()
		local cleared = 0
		local clipboard = load_clipboard({
			clearContents = function() cleared = cleared + 1 end,
		})
		helpers.assert_eq(clipboard.restore(nil), true)
		helpers.assert_eq(cleared, 1)
	end)
end)
