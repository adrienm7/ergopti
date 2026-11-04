--- _shared/lua/test/config_scope_script_level_contract.lua

--- ==============================================================================
--- MODULE: Script Log-Level Snapshot Contract
--- DESCRIPTION:
--- The log level is the one Script alias whose live owner is numeric: the logger
--- keeps a threshold (10, 20, 30, 40), while the declaration, the file and the
--- alias carry the canonical token ("DEBUG"…"ERROR"). This contract states what
--- the scope transaction may rely on, on both Lua drivers:
--- 1. a capture is an opaque receipt, taken without persistence;
--- 2. apply takes the canonical token, never a number, and moves the live
---    threshold to that token's number;
--- 3. restore, after a release and a new acquisition, puts back the exact
---    numeric threshold that was live at capture, whatever token set it;
--- 4. a number, a lower-case token, an unknown token and a foreign receipt are
---    refused and leave the live threshold alone;
--- 5. no persistence setter runs: the file and the settings source belong to the
---    transaction.
--- ==============================================================================

--- Registers the contract.
--- @param helpers table Driver test helpers.
--- @param driver string "linux" or "macos".
return function(helpers, driver)
	local owner_module = driver == "macos" and "infra.logger" or "infra.script_settings"

	--- The live numeric threshold, read from the logger this driver owns.
	local function live()
		if driver == "macos" then return require("infra.logger").current_level end
		return require("logger").get_level()
	end

	--- The numeric threshold a canonical token must produce.
	local function threshold(token)
		if driver == "macos" then return require("infra.logger").LEVELS[token] end
		return require("logger").LEVELS[token]
	end

	local function token() return { pending = function() return false end } end

	helpers.describe("script log-level native snapshot", function()
		helpers.it("restores the exact numeric threshold captured, after release and reacquisition", function()
			local native, owner = require(owner_module), token()
			local before = live()
			helpers.assert_eq(native.scope_acquire(owner), true)
			local receipt = native.scope_capture(owner)
			helpers.assert_type(receipt, "table")
			local target = before == threshold("ERROR") and "DEBUG" or "ERROR"
			helpers.assert_eq(native.scope_apply(owner, receipt, target), true)
			helpers.assert_eq(live(), threshold(target), "apply moves the numeric threshold")
			helpers.assert_eq(native.scope_release(owner), true)
			helpers.assert_eq(native.scope_acquire(owner), true)
			helpers.assert_eq(native.scope_restore(owner, receipt), true)
			helpers.assert_eq(live(), before, "restore puts back the captured number")
			helpers.assert_eq(native.scope_release(owner), true)
		end)

		helpers.it("refuses numbers, other spellings and foreign receipts without moving the threshold", function()
			local native, owner = require(owner_module), token()
			local before = live()
			helpers.assert_eq(native.scope_acquire(owner), true)
			local receipt = native.scope_capture(owner)
			for _, value in ipairs({ 10, 40, "error", "Error", "VERBOSE", "", false }) do
				helpers.assert_eq(native.scope_apply(owner, receipt, value), false)
				helpers.assert_eq(live(), before, "a refused value leaves the threshold alone")
			end
			helpers.assert_eq(native.scope_apply(owner, {}, "ERROR"), false)
			helpers.assert_eq(live(), before)
			helpers.assert_eq(native.scope_restore(owner, receipt), true)
			helpers.assert_eq(native.scope_release(owner), true)
		end)

		helpers.it("refuses the ordinary setters while a transaction holds the field", function()
			local native, owner = require(owner_module), token()
			local before = live()
			helpers.assert_eq(native.scope_acquire(owner), true)
			if driver == "macos" then
				helpers.assert_eq(native.set_level("ERROR"), false)
			else
				helpers.assert_eq(native.apply("ERROR"), false)
				helpers.assert_eq(native.set("ERROR"), false)
			end
			helpers.assert_eq(live(), before)
			helpers.assert_eq(native.scope_release(owner), true)
		end)
	end)
end
