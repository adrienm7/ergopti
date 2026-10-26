--- tests/unit/modules/llm/streaming/test_stream_tmpfile_no_orphan.lua

--- ==============================================================================
--- MODULE: Private Streaming Payload Ownership
--- DESCRIPTION:
--- The allocator already creates a private file. Preserve that exact pathname
--- through writing and transport admission, rather than orphaning or replacing
--- its inode with a second file whose permissions depend on the ambient umask.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.streaming_payload_fixture")
local with_stream = Fixture.with_stream
local CommandLines = require("tests.support.command_lines")
local shell_quote = require("text_utils").shell_quote
local Json = require("json")

helpers.describe("streaming retains its private temporary file", function()
	for _, backend in ipairs({ "mlx", "ollama" }) do
		helpers.it(backend .. " retains the allocated inode through transport (stream-private-payload-case)", function()
			Fixture.assert_private_payload(backend)
		end)
		for _, refusal in ipairs({ "nil", "false", "empty" }) do
			helpers.it(backend .. " refuses allocation " .. refusal .. " before writing (stream-private-allocation)", function()
				with_stream(backend, function(h)
					h.allocation_refusal = true
					if refusal == "false" then h.allocation_result = false end
					if refusal == "empty" then h.allocation_result = "" end
					helpers.assert_true(h.request(), "allocation failures must reach the failure callback")
					helpers.assert_eq(h.failures, 1)
					helpers.assert_eq(h.writes, 0)
					helpers.assert_eq(h.closes, 0)
					helpers.assert_eq(h.spawns, 0)
					helpers.assert_eq(h.timers, 0)
				end)
			end)
		end
	end

	helpers.it("checks native private modes under an explicit child umask (stream-private-native-receipt)", function()
		local root = helpers.driver_root() .. "../../.."
		local lines = CommandLines.read("python3 " .. shell_quote(root .. "/tools/diagnostics/macos_stream_payload_mode_test.py")
			.. " " .. shell_quote(helpers.driver_root()) .. " 2>&1")
		local receipt = assert(Json.decode(table.concat(lines, "\n")))
		helpers.assert_eq(receipt.passed, 2, "both backend payload paths must run inside the native control")
		helpers.assert_eq(receipt.umask, "0022")
		helpers.assert_eq(receipt.parent_umask_preserved, true)
	end)

	for _, control in ipairs({ "absolute", "name", "missing", "empty" }) do
		helpers.it("honors configured Lua " .. control .. " without bare fallback (stream-private-interpreter)", function()
			local root = helpers.driver_root() .. "../../.."
			local fixture = helpers.driver_root() .. "tests/support/modules/llm/stream_payload_interpreter_fixture.py"
			local lines = CommandLines.read("python3 " .. shell_quote(fixture)
				.. " " .. shell_quote(root .. "/tools/diagnostics/macos_stream_payload_mode_test.py")
				.. " " .. shell_quote(helpers.driver_root())
				.. " " .. shell_quote(os.getenv("LUA") or "lua")
				.. " " .. shell_quote(control) .. " " .. shell_quote(helpers.temp_dir()) .. " 2>&1")
			local receipt = assert(Json.decode(table.concat(lines, "\n")))
			helpers.assert_eq(receipt.control, control)
			helpers.assert_eq(receipt.passed, true)
			helpers.assert_eq(receipt.native_cases, (control == "absolute" or control == "name") and 2 or 0)
		end)
	end
end)
