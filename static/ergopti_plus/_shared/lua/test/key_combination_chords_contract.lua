--- _shared/lua/test/key_combination_chords_contract.lua

--- Pure chord selection and fresh document planning; no native input delivery.
local M = {}
local Policy = require("tap_hold.key_combinations")
local Codec = require("toml_codec")
local pairs_catalogue = {
 { id = "caps_lock_then_tab", first = "caps_lock", second = "tab" },
 { id = "tab_then_caps_lock", first = "tab", second = "caps_lock" },
}
local entries = { { id = "caps_lock_then_tab" }, { id = "tab_then_caps_lock" } }
local function plan(source)
 return Policy.plan_chord_copy(source, { entries = entries,
  settings = { simultaneous_threshold_ms = 100, combo_symmetric = false },
  is_action = function(action) return action == "copy" or action == "paste" or action == "ctrl" end })
end
function M.register(h)
 local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
 local root = assert(here:match("^(.*)/lua/test/key_combination_chords_contract%.lua$"))
 local file = assert(io.open(root .. "/tests/corpus/tap_hold/key_combination_chords.json", "rb"))
 local corpus = require("json").decode(file:read("*a")); file:close()
 h.describe("shared third-slot policy with native engine unavailable", function()
  for _, case in ipairs(corpus.cases) do
   h.it(case.name, function()
    local policy = Policy.chord_policy({ pairs = pairs_catalogue,
     chords = { caps_lock_then_tab = "copy", tab_then_caps_lock = "paste" },
     settings = { simultaneous_threshold_ms = 100, combo_symmetric = case.symmetric } })
    local chosen = policy.choose(case.first, case.second, case.elapsed)
    if case.expected == false then h.assert_eq(chosen, nil)
    else h.assert_eq(chosen.action, case.expected); h.assert_eq(chosen.pair_id, case.pair)
     h.assert_eq(chosen.binding, "combination__" .. case.pair) end
   end)
  end
  h.it("requires positive finite delay and an exact symmetry boolean", function()
   for _, delay in ipairs({ 0, -1, math.huge, -math.huge, 0/0, "100" }) do
    h.assert_eq(pcall(Policy.chord_settings, { simultaneous_threshold_ms = delay, combo_symmetric = false }), false)
   end
   for _, symmetry in ipairs({ 0, "false", {} }) do
    h.assert_eq(pcall(Policy.chord_settings, { simultaneous_threshold_ms = 100, combo_symmetric = symmetry }), false)
   end
  end)
  h.it("keeps none neutral and uses declared catalogue order for symmetry", function()
   local policy = Policy.chord_policy({ pairs = { pairs_catalogue[2], pairs_catalogue[1] },
    chords = { caps_lock_then_tab = "copy", tab_then_caps_lock = "none" },
    settings = { simultaneous_threshold_ms = 80, combo_symmetric = true } })
   h.assert_eq(policy.canonical_pair("caps_lock_then_tab"), "tab_then_caps_lock")
   h.assert_eq(policy.choose("caps_lock", "tab", 1), nil)
   h.assert_eq(policy.choose("caps_lock", "tab", 0/0), nil)
   h.assert_eq(policy.choose("caps_lock", "tab", math.huge), nil)
  end)
  h.it("plans independent third slots from fresh bytes without ordered-slot effects", function()
   local source = '[mod_combos]\nsymmetric = true\nsimultaneous_threshold_ms = 87\nenabled = false\n[mod_combos.config.caps_lock_then_tab]\ntap = "copy"\nhold = "ctrl"\ncombo = "paste"\nfuture = { token = "kept" }\n[mod_combos.config.tab_then_caps_lock]\ncombo = "paste"\n[mod_combos.config.future_pair]\ntap = "unavailable_future_action"\n'
   local candidate = plan(source)
   h.assert_eq(candidate.source, source); h.assert_eq(candidate.changes, 2)
   h.assert_eq(candidate.mod_combos_config.caps_lock_then_tab, { tap = "copy", hold = "ctrl", combo = "copy" })
   h.assert_eq(candidate.mod_combos_config.tab_then_caps_lock, { tap = "none", hold = "none", combo = "none" })
   h.assert_eq(candidate.rows[1].value, "copy"); h.assert_eq(candidate.rows[2].delete, true)
   h.assert_eq(candidate.mod_combos_enabled, false); h.assert_eq(candidate.settings.combo_symmetric, true)
   h.assert_eq(candidate.settings.simultaneous_threshold_ms, 87)
   h.assert_eq(Codec.decode(source).mod_combos.config.caps_lock_then_tab.combo, "paste")
  end)
  h.it("refuses every known malformed slot or occupied namespace before a plan", function()
   for _, source in ipairs({ 'mod_combos = 1', 'mod_combos = []', '[mod_combos]\nconfig = 1',
    '[mod_combos.config]\ncaps_lock_then_tab = "copy"',
    '[mod_combos.config.caps_lock_then_tab]\ntap = 1',
    '[mod_combos.config.tab_then_caps_lock]\nhold = "unknown"',
    '[mod_combos]\nsymmetric = "false"', '[mod_combos]\nsimultaneous_threshold_ms = 0',
    '[mod_combos]\nenabled = "false"', '[mod_combos' }) do
    h.assert_eq(pcall(plan, source), false, source)
   end
  end)
  h.it("neutral document and already copied slots require no owned row", function()
   local empty = plan(""); h.assert_eq(empty.changes, 0); h.assert_eq(empty.settings.combo_symmetric, false)
   h.assert_eq(empty.settings.simultaneous_threshold_ms, 100)
   h.assert_eq(plan('[mod_combos.config.caps_lock_then_tab]\ntap = "copy"\ncombo = "copy"\n').changes, 0)
  end)
 end)
end
return M
