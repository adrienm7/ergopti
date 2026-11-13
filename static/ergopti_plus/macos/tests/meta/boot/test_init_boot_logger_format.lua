--- tests/meta/boot/test_init_boot_logger_format.lua

--- Boot logger admission: the privacy rules are admitted before any other
--- dependency may log. The init-boot-logger placeholder regression ({1} and
--- {2} in a boot WARNING, which string.format never replaces) is judged on
--- real boots by tests/e2e/boot/boot_scenarios.lua: no boot line may keep a
--- {N} placeholder.

local helpers = require("tests.helpers")


helpers.describe("boot privacy admission", function()
	helpers.it("mac-logger-privacy: actual bootstrap refuses unavailable policy before later dependencies", function()
		local source = assert(helpers.read_driver_source("Logger.initialize_privacy(raw)"))
		helpers.assert_true(source:find("assert(io.open(logger_shared_root", 1, true) == nil,
			"Privacy file acquisition belongs to its bootstrap adapter, not root orchestration")
		local adapter = assert(helpers.read_driver_source("function M.read_privacy_policy(shared_root)"))
		local block = assert(source:match("%-%- Admit canonical privacy.-(do\n.-\nend)\nlocal Storage"), "Actual privacy boot is required")
		local run = assert(load("local logger_shared_root, Logger = ...\n" .. block .. "\nreturn true", "owned privacy boot", "t",
			{ pcall = pcall, assert = assert, type = type, print = function() end, io = {} }))
		for _, mode in ipairs({ "accepted", "open", "read", "close", "identity", "report_refused", "report_throw", "require_throw", "console_throw" }) do
			local observed = { closes = 0, initialized = 0, notices = {}, reports = {}, exits = {} }
			local logger
			local env
			env = { pcall = pcall, assert = assert, type = type,
				print = function(text)
					if mode == "console_throw" then error("PRIVATE_CONSOLE_REFUSAL") end
					observed.notices[#observed.notices + 1] = text
				end,
				os = { exit = function(code) observed.exits[#observed.exits + 1] = code end },
				require = function(name)
					if name == "adapters.boot_journal" then
						return assert(load(adapter, "actual boot journal", "t", {
							assert = assert, type = type, pcall = pcall, io = env.io,
							require = function(module)
								helpers.assert_eq(module, "infra.logger")
								return logger
							end,
						}))()
					end
					helpers.assert_eq(name, "adapters.boot_fatal")
					if mode == "require_throw" then error("PRIVATE_REPORT_IMPORT_REFUSAL") end
					return { report = function(...)
						observed.reports[#observed.reports + 1] = table.pack(...)
						if mode == "report_throw" then error("PRIVATE_REPORT_REFUSAL") end
						return mode ~= "report_refused"
					end }
				end,
				io = { open = function(path, access)
					helpers.assert_eq(path, "/owned-shared/diagnostics/data/redaction.json")
					helpers.assert_eq(access, "rb")
					if mode == "open" then error("PrivateUser /Users/PrivateUser/private") end
					return { read = function()
						if mode == "read" then error("PrivateUser /Users/PrivateUser/private") end
						return "owned policy"
					end, close = function() observed.closes = observed.closes + 1; return mode ~= "close" end }
				end } }
			logger = { initialize_privacy = function(raw)
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
