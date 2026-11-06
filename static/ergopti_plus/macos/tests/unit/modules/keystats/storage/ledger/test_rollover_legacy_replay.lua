--- tests/unit/modules/keystats/storage/ledger/test_rollover_legacy_replay.lua

--- Verifies settlement across a durable rollover process restart.
if arg and arg[0] and arg[0]:match("test_rollover_legacy_replay%.lua$") then
 local driver = assert(arg[3]) .. "/static/ergopti_plus/macos"
 package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. package.path
 require("tests.support.keystats.rollover_marker_process")(); return
end
local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote
local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")
helpers.describe("legacy rollover replays durable source after restart", function()
 for _, case in ipairs({ "legacy_open", "legacy_already_reset" }) do
  helpers.it("settles exactly once after " .. case, function()
   local python = [[
import os,subprocess,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
controller=root/'static/ergopti_plus/macos/tests/support/keystats/rollover_marker_campaign.py'
os.environ['ERGOPTI_ROLLOVER_EXTENSION']=sys.argv[4]
os.environ['ERGOPTI_LEGACY_RESET_MODE']=sys.argv[5]
with tempfile.TemporaryDirectory(prefix='ergopti-settlement-restart-') as tmp:
 subprocess.run([sys.executable,str(controller),'--root',str(root),'--lua',sys.argv[2],
  '--fixture',sys.argv[3],'--case','release_refused_after_terminal','--strategy','restart','--cache','warm',
  '--execution-directory',str(Path(tmp)/'execution')],check=True)
print('PASS: durable rollover settlement '+sys.argv[5])
]]
   local executable = os.getenv("LUA") or arg[-1]
   local extension = helpers.driver_root() .. "tests/support/keystats/rollover_legacy_replay_extension.lua"
   local command = "python3 -c " .. quote(python) .. " " .. quote(helpers.driver_root() .. "../../..")
    .. " " .. quote(executable) .. " " .. quote(source) .. " " .. quote(extension) .. " " .. quote(case) .. " 2>&1"
   local pipe = assert(io.popen(command, "r")); local output = assert(pipe:read("*a"))
   local ok = pipe:close(); helpers.assert_eq(ok, true, output)
   helpers.assert_eq(output, "PASS: durable rollover settlement " .. case .. "\n")
  end)
 end
end)
