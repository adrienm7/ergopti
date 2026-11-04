--- _shared/lua/test/user_code_driver_contract.lua

--- ==============================================================================
--- MODULE: Programmable Hotstrings Driver Lifecycle Contract
--- DESCRIPTION:
--- Drives dynamic_hotstrings/user_code_driver over a scripted native owner and an
--- in-memory personal source, the way both drivers' native owners are driven in
--- production: the single started generation, the missing-versus-failed problem
--- and its once-only reporting, the gate that stays closed until a source
--- publishes, the activation interval and the port that holds it, the
--- configuration inverse, and the optional ports (a claimed suffix, a deferred
--- report, the shape of a preview). Both drivers replay these cases.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Driver = require("dynamic_hotstrings.user_code_driver")

	local SOURCE_OK = [[return function(api)
		return {{id="clock",suffix="@c",preview="Clock",callback=function() return "12:00" end}}
	end]]

	--- Builds a module over scripted ports.
	--- @param options table|nil { optional = { claims, defer_report, preview_view, apply_time }, omit = port name }
	local function build(options)
		options = options or {}
		local fixture = {
			source = nil, warns = {}, errors = {}, notified = {},
			native = { name = "native" },
		}
		local logger = {}
		for _, level in ipairs({ "start", "success", "info", "debug", "done", "trace" }) do
			logger[level] = function() end
		end
		logger.warn = function(_, fmt, ...) fixture.warns[#fixture.warns + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) fixture.errors[#fixture.errors + 1] = string.format(fmt, ...) end
		local ports = {
			logger = logger, log = "TEST", platform = "testos",
			read = function()
				if fixture.source == nil then return nil, "absent" end
				return fixture.source, "ok"
			end,
			write = function(_, text)
				fixture.source = text
				return true
			end,
			config_dir = function() return "/owned" end,
			translate = function(key) return "T:" .. key end,
			notify = function(text, severity)
				fixture.notified[#fixture.notified + 1] = { text = text, severity = severity }
				return true
			end,
			default_time_seconds = function() return 0.5 end,
			native_binding = function()
				return {
					capture = function(rule, seconds)
						fixture.captured_seconds = seconds
						return { rule = rule }
					end,
					current = function() return true end,
					publication_current = function() return true end,
					publication_cached = function() return true end,
					invoke = function(rule, context, done)
						return {
							start = function()
								local ok, result = pcall(rule.callback, context)
								if ok then done(result) else done(nil, "callback-error") end
								return true
							end,
							cancel = function() return true end,
						}
					end,
					commit = function() return true end,
				}
			end,
		}
		for name, value in pairs(options.optional or {}) do ports[name] = value end
		if options.omit then ports[options.omit] = nil end
		local module = Driver.new(ports)
		return module, fixture
	end

	helpers.describe("programmable hotstring driver lifecycle (user-code-driver-contract)", function()
		helpers.it("(user-code-driver-contract) refuses to be built without its required ports", function()
			for _, name in ipairs({ "read", "write", "config_dir", "translate", "notify", "default_time_seconds", "native_binding" }) do
				helpers.assert_throws(function() build({ omit = name }) end)
			end
			helpers.assert_throws(function() Driver.new({}) end)
			helpers.assert_throws(function() build({ optional = { apply_time = "not a function" } }) end)
		end)

		helpers.it("(user-code-driver-contract) starts one generation and keeps the gate closed at boot", function()
			local module, fixture = build()
			helpers.assert_eq(module.source_path(), "/owned/" .. Driver.SOURCE_FILE)
			helpers.assert_true(module.start(fixture.native))
			helpers.assert_true(module.start(fixture.native), "the same native owner restarts as a no-op")
			helpers.assert_eq(module.start({}), false, "another owner is refused while one generation runs")
			helpers.assert_eq(module.is_enabled(), false)
			helpers.assert_eq(module.count(), 0)
			helpers.assert_eq(#fixture.notified, 0)
		end)

		helpers.it("(user-code-driver-contract) reports a missing source once, as a warning and no notification", function()
			local module, fixture = build()
			module.start(fixture.native)
			helpers.assert_eq((module.set_enabled(true)), false)
			helpers.assert_eq(module.problem(), "missing")
			helpers.assert_eq(#fixture.warns, 1)
			helpers.assert_contains(fixture.warns[1], "does not exist")
			helpers.assert_eq(#fixture.notified, 0)
			module.set_enabled(true)
			helpers.assert_eq(#fixture.warns, 1, "the same refusal logs nothing more")
			helpers.assert_eq(#fixture.errors, 0, "a missing source is not a driver error")
		end)

		helpers.it("(user-code-driver-contract) reports a failing source once with a warning notification", function()
			local module, fixture = build()
			fixture.source = "not lua!"
			module.start(fixture.native)
			helpers.assert_eq((module.set_enabled(true)), false)
			helpers.assert_eq(module.problem(), "failed")
			helpers.assert_eq(#fixture.notified, 1)
			helpers.assert_eq(fixture.notified[1].severity, "warning")
			helpers.assert_eq(fixture.notified[1].text, "T:" .. Driver.ERROR_TEXT_KEY)
			module.set_enabled(true)
			helpers.assert_eq(#fixture.notified, 1)
			helpers.assert_eq(module.is_enabled(), false)
		end)

		helpers.it("(user-code-driver-contract) publishes a valid source, clears the problem and closes on disable", function()
			local module, fixture = build()
			module.start(fixture.native)
			module.set_enabled(true)
			helpers.assert_eq(module.problem(), "missing")
			helpers.assert_true(module.create_example())
			helpers.assert_eq(module.create_example(), false, "an existing source is never overwritten")
			fixture.source = SOURCE_OK
			helpers.assert_true((module.set_enabled(true)))
			helpers.assert_nil(module.problem())
			helpers.assert_true(module.is_enabled())
			helpers.assert_eq(module.count(), 1)
			helpers.assert_true((module.set_enabled(false)))
			helpers.assert_eq(module.is_enabled(), false)
			helpers.assert_eq(module.count(), 1, "admitted metadata is counted independently of the gate")
		end)

		helpers.it("(user-code-driver-contract) applies the manifest interval first and the native port holds it", function()
			local applied = {}
			local module, fixture = build({ optional = {
				apply_time = function(native, seconds)
					applied[#applied + 1] = { native = native, seconds = seconds }
					return true
				end,
			} })
			fixture.source = SOURCE_OK
			module.start(fixture.native)
			helpers.assert_true((module.set_enabled(true)))
			helpers.assert_eq(module.time_activation(), 0.5)
			helpers.assert_eq(applied[1].seconds, 0.5)
			helpers.assert_eq(applied[1].native, fixture.native)
			helpers.assert_true((module.set_time_activation(0)))
			helpers.assert_eq(module.time_activation(), 0)
			for _, bad in ipairs({ -1, 0 / 0, math.huge }) do
				helpers.assert_eq((module.set_time_activation(bad)), false)
			end
			helpers.assert_eq((module.set_time_activation("1")), false)
			helpers.assert_eq(module.time_activation(), 0, "a refused interval changes nothing")
		end)

		helpers.it("(user-code-driver-contract) stays disabled when the native owner refuses the interval", function()
			local module, fixture = build({ optional = { apply_time = function() return false end } })
			fixture.source = SOURCE_OK
			module.start(fixture.native)
			helpers.assert_eq((module.set_enabled(true)), false)
			helpers.assert_nil(module.time_activation())
			helpers.assert_eq(module.is_enabled(), false)
		end)

		helpers.it("(user-code-driver-contract) hands the interval to the capture port when there is no native holder", function()
			local module, fixture = build()
			fixture.source = SOURCE_OK
			module.start(fixture.native)
			helpers.assert_true((module.set_enabled(true)))
			helpers.assert_true(module.request("x@c"))
			helpers.assert_eq(fixture.captured_seconds, 0.5)
		end)

		helpers.it("(user-code-driver-contract) lets a claimed suffix pre-empt a request and a preview", function()
			local claimed = false
			local module, fixture = build({ optional = { claims = function() return claimed end } })
			fixture.source = SOURCE_OK
			module.start(fixture.native)
			module.set_enabled(true)
			helpers.assert_eq(module.preview("x@c").preview, "Clock", "the default preview is the descriptor")
			claimed = true
			helpers.assert_eq(module.request("x@c"), false)
			helpers.assert_nil(module.preview("x@c"))
		end)

		helpers.it("(user-code-driver-contract) shapes a preview through the driver's port", function()
			local module, fixture = build({ optional = { preview_view = function(row) return row.preview end } })
			fixture.source = SOURCE_OK
			module.start(fixture.native)
			module.set_enabled(true)
			helpers.assert_eq(module.preview("x@c"), "Clock")
			helpers.assert_nil(module.preview("x@nothing"))
		end)

		helpers.it("(user-code-driver-contract) reports a failing callback as a warning and honours a deferred report", function()
			local module, fixture = build()
			fixture.source = [[return function(api)
				return {{id="boom",suffix="@b",preview="Boom",callback=function() error("user bug") end}}
			end]]
			module.start(fixture.native)
			module.set_enabled(true)
			module.request("x@b")
			helpers.assert_true(#fixture.notified >= 1, "the user is told")
			helpers.assert_eq(#fixture.errors + #fixture.warns >= 1, true)
			for _, line in ipairs(fixture.warns) do
				helpers.assert_eq(line:find("user bug", 1, true), nil, "content is withheld")
			end

			local deferred_module, deferred = build({ optional = { defer_report = function()
				return true
			end } })
			deferred.source = fixture.source
			deferred_module.start(deferred.native)
			deferred_module.set_enabled(true)
			deferred_module.request("x@b")
			helpers.assert_eq(#deferred.notified, 0, "a deferred report is not also delivered now")
		end)

		helpers.it("(user-code-driver-contract) restores the configuration inverse and stops cleanly", function()
			local applied = {}
			local module, fixture = build({ optional = {
				apply_time = function(_, seconds) applied[#applied + 1] = seconds; return true end,
			} })
			fixture.source = SOURCE_OK
			module.start(fixture.native)
			helpers.assert_true((module.set_enabled(true)))
			local snapshot = module.scope_snapshot()
			helpers.assert_true(snapshot ~= nil, "a published source can be captured")
			helpers.assert_true(module.scope_adopt(snapshot, 0.25, false))
			helpers.assert_eq(module.is_enabled(), false)
			helpers.assert_eq(module.time_activation(), 0.25)
			helpers.assert_true(module.scope_restore(snapshot))
			helpers.assert_true(module.is_enabled(), "the inverse reopens the gate")
			helpers.assert_eq(module.time_activation(), 0.5)
			helpers.assert_eq(applied[#applied], 0.5, "the native interval is restored too")
			helpers.assert_true(module.stop())
			helpers.assert_eq(module.is_enabled(), false)
			helpers.assert_eq(module.count(), 0)
			helpers.assert_nil(module.time_activation())
			helpers.assert_true(module.start(fixture.native), "a stopped module starts a new generation")
		end)
	end)
end

return M
