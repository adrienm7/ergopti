--- tests/support/mlx_truststore_fixture.lua

--- ==============================================================================
--- MODULE: Actual MLX Downloader Receiver
--- DESCRIPTION:
--- Captures production-emitted Python and independent owner session metadata
--- through the unchanged download fixture, without executing a child process.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local Json = require("json")
local M = {}

--- Receives the emitted source and its exact independently published exit path.
--- @return table packet
function M.capture()
	local packet
	fixture_support.with_fixture({}, function(fixture)
		helpers.assert_true(fixture.controls.pull())
		local session = Json.decode(assert(fixture.controls.files["/tmp/hs_mlx_active_download.json"]))
		helpers.assert_type(session, "table")
		helpers.assert_type(session.script_path, "string")
		helpers.assert_type(session.log_path, "string")
		helpers.assert_eq(session.exit_path, session.log_path .. ".exit")
		helpers.assert_eq(fixture.controls.window.terminal_cmd, "tail -f '" .. session.log_path .. "'")
		local source = fixture.controls.files[session.script_path]
		helpers.assert_type(source, "string", "source comes from the original owner's exact file")
		packet = { source = source, expected_exit_path = session.exit_path, log_path = session.log_path }
	end)
	return packet
end

return M
