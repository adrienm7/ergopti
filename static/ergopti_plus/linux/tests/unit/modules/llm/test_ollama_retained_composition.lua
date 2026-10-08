--- static/ergopti_plus/linux/tests/unit/modules/llm/test_ollama_retained_composition.lua
--- Receives the actual composition's live installation ports and canonical plan.
local helpers = require("tests.helpers")
local original_composition = package.loaded["modules.llm.runtime_composition"]
helpers.describe("Retained Ollama runtime composition", function()
 helpers.it("live repair forwards canonical resolver asset and native archive factory without updater metadata", function()
  local captured
  local Compose = helpers.load_module_with_dependency("modules.llm.runtime_composition", "llm.runtime_repair", {
   new = function(ports) captured = ports; return {} end,
  })
  local asset = { key = "linux-amd64", version = "0.24.0", name = "ollama-linux-amd64.tar.zst", bytes = 3,
   url = "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst",
   sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" }
  local archive, budget, files, result = {}, {}, {}, {}
  local function yes() return true end
  Compose.new({ source = { current = yes, publish = yes, app_capture = yes, app_current = yes },
   timings = { ms = function() return 100 end }, resolver = { plan = function() return { asset = asset } end, current = yes },
   installed = { capture = function() return {} end }, file_factory = {}, archive_factory = archive,
   admission = { new = function() return files end }, install_phase = { start = function(ports, options)
    assert(ports.archive_factory == archive and ports.files == files and options.asset == asset and options.budget == budget)
    assert(options.asset.tag == nil and options.asset.checksum_url == nil and options.explicit_consent == true)
    return result
   end }, process = { start_service = function() end }, http = { get_owned = function() end },
   owned_timer = { after = function() end, now_ms = function() return 0 end }, environment = function() return {} end })
  assert(captured.install({}, budget, yes, function() end) == result)
 end)
end)
package.loaded["modules.llm.runtime_composition"] = original_composition
