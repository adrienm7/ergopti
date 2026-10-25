--- tests/unit/infra/config/test_personal_info_policy_read.lua

--- ==============================================================================
--- MODULE: Personal-Info Policy Read Receipts
--- DESCRIPTION:
--- Exercises the real privacy loader with native special files and incomplete
--- stream receipts. A policy refusal masks public fields too, without hanging
--- the daemon or accepting bytes whose close was not acknowledged.
--- ==============================================================================

local helpers = require("tests.helpers")
local native = require("luv")
local Shell = require("adapters.shell_runner")

--- Runs one controlled stream receipt through the actual declaration parser.
--- @param stream table Read and close operations with Lua file receipt shapes.
--- @param body function Receives the loader and captured error lines.
local function with_stream(stream, body)
	local names = { "infra.personal_info_fields", "infra.paths", "infra.regular_file_reader", "logger.shim" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local original_open = io.open
	local errors = {}
	local policy_path = "/personal-info-policy-receipt.toml"
	local logger = helpers.make_logger_stub()
	logger.error = function(_, text) errors[#errors + 1] = text end
	package.loaded["logger.shim"] = logger
	package.loaded["infra.paths"] = { shared = function() return policy_path end }
	package.loaded["infra.regular_file_reader"] = { open_source = function() return stream end }
	package.loaded["infra.personal_info_fields"] = nil
	io.open = function(path, ...)
		if path == policy_path then return stream end
		return original_open(path, ...)
	end
	local ok, detail = pcall(function() body(require("infra.personal_info_fields"), errors) end)
	io.open = original_open
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("personal-info-policy-read", function()
	helpers.it("(personal-info-policy-read) refuses a native FIFO before waiting for a writer", function()
		local path = os.tmpname()
		os.remove(path)
		assert(Shell.run("mkfifo -- " .. Shell.quote(path)))
		local code = string.format([[package.path = %q
package.loaded["infra.paths"] = { shared = function() return %q end }
local fields = require("infra.personal_info_fields")
assert(fields.is_masked("phone_number") == true, "an unreadable policy must mask even public fields")
assert(fields.for_preview("0750399576", "phone_number") ~= "0750399576", "the preview must fail closed")
]], package.path, path)
		local expired, exited, exit_code, exit_signal = false, false, nil, nil
		local timer = assert(native.new_timer())
		local child
		child = assert(native.spawn(assert(arg[-1]), { args = { "-e", code } }, function(status, signal)
			exited, exit_code, exit_signal = true, status, signal
			native.timer_stop(timer)
			native.close(timer)
			native.close(child)
		end))
		assert(require("infra.native_timer").start(native, timer, 2000, 0, function()
			expired = true
			child:kill("sigkill")
		end))
		while not exited do native.run("once") end
		native.run("nowait")
		os.remove(path)
		helpers.assert_eq(expired, false, "the first privacy classification must never block on a FIFO")
		helpers.assert_eq(exit_code, 0, "refused file types must produce a usable fail-closed policy")
		helpers.assert_eq(exit_signal, 0, "a killed loader must never count as successful masking")
	end)

	local handle = assert(io.open(require("infra.paths").shared("modules/personal_info/fields.toml"), "r"))
	local valid_policy = assert(handle:read("*a"))
	assert(handle:close())

	helpers.it("(personal-info-policy-read) accepts a complete public declaration", function()
		local closes = 0
		with_stream({ read = function() return valid_policy end, close = function() closes = closes + 1; return true end },
			function(fields, errors)
				helpers.assert_eq(fields.is_masked("phone_number"), false)
				helpers.assert_eq(fields.for_preview("0750399576", "phone_number"), "0750399576")
				helpers.assert_eq(#errors, 0)
			end)
		helpers.assert_eq(closes, 1, "the declaration is read once and its stream is closed once")
	end)

	helpers.it("(personal-info-policy-read) masks everything after an unacknowledged close", function()
		local closes = 0
		with_stream({ read = function() return valid_policy end, close = function() closes = closes + 1; return nil, "EIO" end },
			function(fields, errors)
				helpers.assert_eq(fields.is_masked("phone_number"), true, "valid bytes do not override a failed close")
				helpers.assert_eq(fields.for_preview("0750399576", "phone_number"), "••••••••••")
				helpers.assert_eq(#errors, 1, "the refusal must be diagnosed exactly once")
			end)
		helpers.assert_eq(closes, 1)
	end)

	helpers.it("(personal-info-policy-read) closes an unreadable stream and caches its refusal", function()
		local closes = 0
		with_stream({ read = function() return nil, "EIO" end, close = function() closes = closes + 1; return true end },
			function(fields, errors)
				helpers.assert_eq(fields.is_masked("phone_number"), true)
				helpers.assert_eq(fields.for_preview("0750399576", "phone_number"), "••••••••••")
				helpers.assert_eq(#errors, 1)
			end)
		helpers.assert_eq(closes, 1)
	end)
end)
