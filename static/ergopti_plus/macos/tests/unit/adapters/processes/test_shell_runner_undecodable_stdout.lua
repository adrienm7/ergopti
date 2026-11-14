--- tests/unit/adapters/processes/test_shell_runner_undecodable_stdout.lua

--- The native nil stdout receipt must reach both streaming and terminal clients.
local helpers = require("tests.helpers")

helpers.describe("ShellRunner preserves native undecodable stdout", function()
 helpers.it("forwards nil chunk and terminal output without converting either to empty text", function()
  helpers.with_stub_scope({ "adapters.shell_runner", "adapters.task_environment", "core.logger.engine.logger" }, function()
   local chunk_callback, done_callback, native
   local runner = helpers.load_with_stubs("adapters.shell_runner", {
    task = { new = function(_, done, chunk)
     done_callback, chunk_callback = done, chunk
     native = { start = function() return true end, isRunning = function() return false end }
     return native
    end },
   })
   local chunks, terminals = {}, {}
   local handle = runner.spawn("/usr/bin/curl", {}, function(code, stdout, stderr)
    terminals[#terminals + 1] = { code = code, missing = stdout == nil, stderr = stderr }
   end, function(_, stdout, stderr)
    chunks[#chunks + 1] = { missing = stdout == nil, stderr = stderr }
    return true
   end)
   helpers.assert_eq(handle.start(), true)
   helpers.assert_eq(chunk_callback(native, nil, ""), true)
   helpers.assert_eq(chunks, { { missing = true, stderr = "" } })
   done_callback(0, nil, "")
   helpers.assert_eq(terminals, { { code = 0, missing = true, stderr = "" } })
   helpers.assert_eq(handle.isSettled(), true)
  end)
 end)
end)
