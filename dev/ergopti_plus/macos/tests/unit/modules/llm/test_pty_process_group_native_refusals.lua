--- tests/unit/modules/llm/test_pty_process_group_native_refusals.lua

--- Behavioral regression for HS-012 PTY wrapper publication. Native file
--- methods can mutate before returning false/nil or throwing, so the wrapper
--- must reject publication and retain the exact close/remove capability.

local helpers = require("tests.helpers")

local function native_result(mode, success)
	if mode == "throw" then error("native operation exploded") end
	if mode == "false" then return false, "refused" end
	if mode == "nil" then return nil, "refused" end
	return success
end

local function with_fixture(options, callback)
	options = options or {}
	local original_open = io.open
	local original_tmpname = os.tmpname
	local original_remove = os.remove
	local original_logger = package.loaded["infra.logger"]
	local original_module = package.loaded["modules.llm.pty_process_group"]
	local fixture = {
		write_mode = options.write_mode or "true",
		close_mode = options.close_mode or "true",
		remove_mode = options.remove_mode or "true",
		write_calls = 0,
		close_calls = 0,
		remove_calls = 0,
		path = "/tmp/ergopti-pty-wrapper-test.py",
		paths = {
			"/tmp/ergopti-pty-wrapper-test.py",
			"/tmp/ergopti-pty-wrapper-sibling.py",
		},
		tmpname_calls = 0,
		open_calls = 0,
		files = {},
		close_receivers = {},
	}

	os.tmpname = function()
		fixture.tmpname_calls = fixture.tmpname_calls + 1
		return fixture.paths[fixture.tmpname_calls]
			or (fixture.path .. "." .. tostring(fixture.tmpname_calls))
	end
	os.remove = function(path)
		helpers.assert_true(path == fixture.paths[1] or path == fixture.paths[2])
		fixture.remove_calls = fixture.remove_calls + 1
		return native_result(fixture.remove_mode, true)
	end
	io.open = function(path, mode)
		helpers.assert_true(path == fixture.paths[1] or path == fixture.paths[2])
		helpers.assert_eq(mode, "w")
		fixture.open_calls = fixture.open_calls + 1
		local file = {
			id = fixture.open_calls,
			path = path,
			close_attempted = false,
		}
		function file:write(payload)
			fixture.write_calls = fixture.write_calls + 1
			helpers.assert_true(type(payload) == "string" and #payload > 100)
			return native_result(fixture.write_mode, self)
		end
		function file:close()
			self.close_attempted = true
			fixture.close_calls = fixture.close_calls + 1
			fixture.close_receivers[#fixture.close_receivers + 1] = self
			return native_result(fixture.close_mode, true)
		end
		fixture.files[#fixture.files + 1] = file
		return file
	end

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.llm.pty_process_group"] = nil
	local module = require("modules.llm.pty_process_group")
	local ok, result = xpcall(function()
		return callback(fixture, module)
	end, debug.traceback)
	io.open = original_open
	os.tmpname = original_tmpname
	os.remove = original_remove
	package.loaded["infra.logger"] = original_logger
	package.loaded["modules.llm.pty_process_group"] = original_module
	if not ok then error(result, 0) end
	return result
end

helpers.describe("HS-012 PTY process-group native result contracts", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects wrapper publication when write returns " .. mode, function()
			with_fixture({ write_mode = mode }, function(fixture, module)
				local path = module.create("write refusal")
				helpers.assert_eq(path, nil)
				helpers.assert_eq(fixture.write_calls, 1)
				helpers.assert_eq(fixture.close_calls, 1)
				helpers.assert_eq(fixture.remove_calls, 1)
			end)
		end)

		helpers.it("retains an exact wrapper when close returns " .. mode, function()
			with_fixture({ close_mode = mode }, function(fixture, module)
				local path = module.create("close refusal")
				helpers.assert_eq(path, nil)
				local first_file = fixture.files[1]
				helpers.assert_not_nil(first_file)
				helpers.assert_true(first_file.close_attempted)
				helpers.assert_eq(fixture.close_calls, 1)
				helpers.assert_eq(fixture.remove_calls, 0)

				helpers.assert_eq(module.create("blocked sibling"), nil)
				helpers.assert_eq(fixture.tmpname_calls, 1,
					"cleanup debt must block a sibling before path allocation")
				helpers.assert_eq(fixture.open_calls, 1,
					"cleanup debt must block a second file capability")
				helpers.assert_eq(#fixture.files, 1)
				helpers.assert_eq(fixture.close_receivers[1], first_file)
				helpers.assert_eq(fixture.close_receivers[2], first_file,
					"successor admission must retry the identical file handle")

				fixture.close_mode = "true"
				helpers.assert_true(module.retry_cleanup())
				helpers.assert_eq(fixture.close_receivers[#fixture.close_receivers],
					first_file)
				helpers.assert_eq(fixture.remove_calls, 1)

				local sibling_path = module.create("settled sibling")
				helpers.assert_eq(sibling_path, fixture.paths[2])
				helpers.assert_eq(fixture.tmpname_calls, 2)
				helpers.assert_eq(fixture.open_calls, 2)
				helpers.assert_true(fixture.files[2] ~= first_file)
				helpers.assert_eq(fixture.close_receivers[#fixture.close_receivers],
					fixture.files[2])
				helpers.assert_true(module.remove(sibling_path))
			end)
		end)

		helpers.it("retains an exact wrapper path when remove returns " .. mode, function()
			with_fixture({ remove_mode = mode }, function(fixture, module)
				local path = module.create("remove refusal")
				helpers.assert_eq(path, fixture.path)
				helpers.assert_eq(module.remove(path), false)
				helpers.assert_eq(fixture.remove_calls, 1)
				fixture.remove_mode = "true"
				helpers.assert_true(module.retry_cleanup())
				helpers.assert_eq(fixture.remove_calls, 2)
			end)
		end)
	end

	helpers.it("retains failed-write cleanup when unlink also refuses", function()
		with_fixture({ write_mode = "false", remove_mode = "false" },
			function(fixture, module)
				local path = module.create("compound rollback refusal")
				helpers.assert_eq(path, nil)
				helpers.assert_eq(fixture.remove_calls, 1)
				fixture.remove_mode = "true"
				helpers.assert_true(module.retry_cleanup())
				helpers.assert_eq(fixture.remove_calls, 2)
			end)
	end)
end)
