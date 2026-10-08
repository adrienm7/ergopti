--- static/ergopti_plus/linux/tests/unit/modules/llm/test_ollama_retained_phase.lua
--- Actual shared facade forwards the original captured budget to retained delivery.
local helpers = require("tests.helpers")
local Phase = require("llm.ollama_install_phase")
local fixture = require("tests.support.ollama_retained_fixture")
helpers.describe("Retained Ollama installation phase", function()
 local function start(f)
  f.operation = Phase.start(f.ports, f.options, function(result) f.completions[#f.completions + 1] = result end)
  return f.operation
 end
 helpers.it("actual facade delivers retained target with original absolute deadline and shrinking helper bound", function()
  local f = fixture(); local op = start(f); f.remaining = 17; f.through(9)
  assert(f.calls[5].program == "HTTP" and f.calls[5].options.absolute_deadline_ms == 700 and f.calls[5].options.timeout_ms == 17)
  assert(op:is_settled() and op.result.ok and op.result.installed and #f.completions == 1)
 end)
 helpers.it("original master withdrawal cancels exact download and preserves physical stage debt", function()
  local f = fixture(); local op = start(f); f.through(4)
  f.current = false; for _, callback in ipairs(f.cancellation) do callback() end
  assert(not op:is_settled() and f.cleanup == 0 and f.calls[5].signals > 0)
  f.calls[5].retire(); assert(op:is_settled() and f.cleanup == 1 and #f.completions == 0 and #f.calls == 5)
 end)
 helpers.it("missing retained download capability refuses live phase without legacy fallback", function()
  local f = fixture(); f.ports.http.download_output_owned = nil; local op = start(f)
  assert(op:is_settled() and op.started == false and #f.calls == 0 and f.prepares == 0)
  assert(op.result.error == "install_retained_port_unavailable")
 end)
end)
