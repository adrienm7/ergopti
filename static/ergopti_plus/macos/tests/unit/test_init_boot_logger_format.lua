--- tests/unit/test_init_boot_logger_format.lua

--- Regression test for init-boot-logger: init.lua had a Logger.warn call
--- that used "{1}" and "{2}" as format placeholders. The Logger uses Lua's
--- string.format under the hood, which does not recognise {N} syntax — only
--- %s, %d, %q, etc. The warning was emitted as a literal string with "{1}"
--- and "{2}" still in it, hiding the actual directory paths from the log.
---
--- Fix: replaced "{1}" and "{2}" with "%s" in the format string.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "../../init.lua"
-- Fallback: look from the test root
local fh = io.open(src_path, "r")
if not fh then
	src_path = helpers.driver_root() .. "init.lua"
	fh = io.open(src_path, "r")
end
if not fh then error("init.lua not readable (tried driver_root/../../init.lua and driver_root/init.lua)") end
local src = fh:read("*a") ; fh:close()

-- Test 1: The old {1}/{2} placeholders must not appear in a Logger call.
local has_old_placeholder = src:find("'{1}'", 1, true) ~= nil or src:find('"{1}"', 1, true) ~= nil
helpers.assert_true(
	not has_old_placeholder,
	"init.lua must not use '{1}' as a Logger format placeholder — use '%s' (init-boot-logger)"
)

-- Test 2: The corrected %s format must appear in the hotstring fallback warning.
-- Use plain search — the literal chars "%s" (percent + s) must appear in the format string.
local has_correct_format = src:find("Logger.info(LOG, \"No shared hotstring groups in '%s'", 1, true) ~= nil
helpers.assert_true(
	has_correct_format,
	"init.lua must use '%%s' in the informational hotstring fallback log (init-boot-logger)"
)

print("[PASS] test_init_boot_logger_format")


helpers.describe("boot privacy admission", function()
	helpers.it("mac-logger-privacy: actual bootstrap refuses unavailable policy before later dependencies", function()
		local source = assert(helpers.read_driver_source("Logger.initialize_privacy(raw)"))
		local block = assert(source:match("%-%- Admit canonical privacy.-(do\n.-\nend)\nlocal Storage"), "Actual privacy boot is required")
		local run = assert(load("local logger_shared_root, Logger = ...\n" .. block .. "\nreturn true", "owned privacy boot", "t",
			{ pcall = pcall, assert = assert, type = type, print = function() end, io = {} }))
		for _, mode in ipairs({ "accepted", "open", "read", "close", "identity", "report_refused", "report_throw", "require_throw", "console_throw" }) do
			local observed = { closes = 0, initialized = 0, notices = {}, reports = {}, exits = {} }
			local env = { pcall = pcall, assert = assert, type = type,
				print = function(text)
					if mode == "console_throw" then error("PRIVATE_CONSOLE_REFUSAL") end
					observed.notices[#observed.notices + 1] = text
				end,
				os = { exit = function(code) observed.exits[#observed.exits + 1] = code end },
				require = function(name)
					helpers.assert_eq(name, "adapters.boot_fatal")
					if mode == "require_throw" then error("PRIVATE_REPORT_IMPORT_REFUSAL") end
					return { report = function(...)
						observed.reports[#observed.reports + 1] = table.pack(...)
						if mode == "report_throw" then error("PRIVATE_REPORT_REFUSAL") end
						return mode ~= "report_refused"
					end }
				end,
				io = { open = function(path, access)
					helpers.assert_eq(path, "/owned-shared/modules/diagnostics/redaction.json")
					helpers.assert_eq(access, "rb")
					if mode == "open" then error("PrivateUser /Users/PrivateUser/private") end
					return { read = function()
						if mode == "read" then error("PrivateUser /Users/PrivateUser/private") end
						return "owned policy"
					end, close = function() observed.closes = observed.closes + 1; return mode ~= "close" end }
				end } }
			local logger = { initialize_privacy = function(raw)
				observed.initialized = observed.initialized + 1
				helpers.assert_eq(observed.closes, 1, "Read ownership is retired before privacy commit")
				helpers.assert_eq(raw, "owned policy")
				if mode ~= "accepted" then error("PrivateUser /Users/PrivateUser/private") end
			end }
			run = assert(load("local logger_shared_root, Logger = ...\n" .. block .. "\nreturn true", "owned privacy boot", "t", env))
			helpers.assert_eq(run("/owned-shared", logger), mode == "accepted" and true or nil)
			helpers.assert_eq(observed.initialized, (mode ~= "open" and mode ~= "read" and mode ~= "close") and 1 or 0)
			helpers.assert_eq(observed.closes, mode == "open" and 0 or 1)
			helpers.assert_eq(observed.notices, (mode == "accepted" or mode == "console_throw") and {} or { "[logger] Privacy initialization refused; bootstrap not continued." })
			helpers.assert_eq(observed.exits, mode == "accepted" and {} or { 1 }, "Reporting or console refusal cannot reopen successful boot")
			helpers.assert_eq(observed.reports, (mode == "accepted" or mode == "require_throw") and {}
				or { { "logger_privacy", "Canonical log privacy admission refused.", n = 3 } })
		end
	end)
end)
