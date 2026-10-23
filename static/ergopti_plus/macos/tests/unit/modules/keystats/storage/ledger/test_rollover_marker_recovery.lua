--- tests/unit/modules/keystats/storage/ledger/test_rollover_marker_recovery.lua

--- ==============================================================================
--- MODULE: Rollover Marker Recovery Through Public Storage
--- DESCRIPTION:
--- The real manager/rotation/writer/walker run in isolated native Lua processes.
--- Actual Python SQLite owns transactions and a real second reader refuses the
--- reset COMMIT. The canonical journal survives loss of its disposable cache.
--- ==============================================================================

if arg and arg[0] and arg[0]:match("test_rollover_marker_recovery%.lua$") then
	local driver = assert(arg[3]) .. "/static/ergopti_plus/macos"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. package.path
	require("tests.support.keystats.rollover_marker_process")(); return
end

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote
local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")

local function verify(case, strategy, cache)
	local python = [[
import subprocess,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
controller=root/"static/ergopti_plus/macos/tests/support/keystats/rollover_marker_campaign.py"
with tempfile.TemporaryDirectory(prefix="ergopti-rollover-marker-") as temporary:
    subprocess.run([sys.executable,str(controller),"--root",str(root),"--lua",sys.argv[2],
        "--fixture",sys.argv[3],"--case",sys.argv[4],"--strategy",sys.argv[5],"--cache",sys.argv[6],
        "--execution-directory",str(Path(temporary)/"execution")],check=True)
assert not Path(temporary).exists(),"owned rollover process directory leaked"
print("PASS: rollover marker "+sys.argv[4]+" "+sys.argv[5]+" "+sys.argv[6])
]]
	local executable = os.getenv("LUA") or arg[-1]
	helpers.assert_true(type(executable) == "string" and executable ~= "")
	local command = "python3 -c " .. quote(python) .. " " .. quote(helpers.driver_root() .. "../../..")
		.. " " .. quote(executable) .. " " .. quote(source) .. " " .. quote(case)
		.. " " .. quote(strategy) .. " " .. quote(cache) .. " 2>&1"
	local pipe = assert(io.popen(command, "r")); local output = assert(pipe:read("*a"))
	local ok, kind, status = pipe:close()
	helpers.assert_eq(ok, true, output); helpers.assert_eq(kind, "exit", output); helpers.assert_eq(status, 0, output)
	helpers.assert_eq(output, "PASS: rollover marker " .. case .. " " .. strategy .. " " .. cache .. "\n")
end

helpers.describe("public rollover preserves durable generation ownership", function()
	for _, case in ipairs({ "healthy", "marker_open_refused", "marker_partial_write",
		"marker_close_refused_after_close", "old_stream_close_error_after_close", "unlink_refused",
		"pending_publication_refused", "reset_commit_refused", "terminal_publication_refused",
		"release_refused_after_terminal" }) do
		helpers.it("retains FIFO and recovers " .. case, function() verify(case, "runtime", "cold") end)
	end
	for _, case in ipairs({ "old_identity_replaced", "old_identity_grown", "old_path_symlink",
		"nonprefix_marker_tail", "ordinary_pending_append" }) do
		helpers.it("preserves source on " .. case, function() verify(case, "restart", "cold") end)
	end
	for _, strategy in ipairs({ "authority_absent", "authority_unrelated" }) do
		helpers.it("rejects unrelated terminal authority " .. strategy,
			function() verify("release_refused_after_terminal", strategy, "cold") end)
	end
	helpers.it("fences the writer when actual SQLite open fails with pending retirement",
		function() verify("unlink_refused", "sqlite_open_refusal", "warm") end)
	for _, case in ipairs({ "unlink_refused", "marker_open_refused", "marker_partial_write",
		"marker_close_refused_after_close", "terminal_publication_refused", "release_refused_after_terminal" }) do
		helpers.it("resumes warm process boundary " .. case, function() verify(case, "restart", "warm") end)
	end
end)
