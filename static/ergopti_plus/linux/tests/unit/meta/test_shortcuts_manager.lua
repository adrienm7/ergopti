--- tests/unit/meta/test_shortcuts_manager.lua

--- ==============================================================================
--- MODULE: Shortcuts Manager Tests
--- Tests the Linux shortcuts module — wrap pairs, CapsWord, text transforms,
--- enable/disable, menu integration.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("modules/shortcuts/manager.lua", function()

  -- ==========================================================================
  -- 1. Module structural
  -- ==========================================================================

  helpers.it("module loads without error", function()
    local ok, mod = pcall(require, "modules.shortcuts.manager")
    helpers.assert_true(ok, "require should succeed")
    helpers.assert_true(type(mod) == "table", "should return a table")
  end)

  local M = helpers.load_module("modules.shortcuts.manager")

  helpers.it("exports public API surface", function()
    helpers.assert_true(type(M.is_enabled) == "function", "is_enabled")
    helpers.assert_true(type(M.enable) == "function", "enable")
    helpers.assert_true(type(M.disable) == "function", "disable")
    helpers.assert_true(type(M.toggle) == "function", "toggle")
    helpers.assert_true(type(M.get_wrap_pair) == "function", "get_wrap_pair")
    helpers.assert_true(type(M.get_wrap_pairs) == "function", "get_wrap_pairs")
    helpers.assert_true(type(M.wrap_selection) == "function", "wrap_selection")
    helpers.assert_true(type(M.is_caps_word_active) == "function", "is_caps_word_active")
    helpers.assert_true(type(M.toggle_caps_word) == "function", "toggle_caps_word")
    helpers.assert_true(type(M.process_caps_word) == "function", "process_caps_word")
    helpers.assert_true(type(M.transform_uppercase) == "function", "transform_uppercase")
    helpers.assert_true(type(M.transform_lowercase) == "function", "transform_lowercase")
    helpers.assert_true(type(M.transform_titlecase) == "function", "transform_titlecase")
    helpers.assert_true(type(M.select_word) == "function", "select_word")
    helpers.assert_true(type(M.select_line) == "function", "select_line")
    helpers.assert_true(type(M.paste_plain) == "function", "paste_plain")
    helpers.assert_true(type(M.init) == "function", "init")
  end)

  -- ==========================================================================
  -- 2. Wrap pairs
  -- ==========================================================================

  helpers.it("get_wrap_pair returns pair for '('", function()
    local pair = M.get_wrap_pair("(")
    helpers.assert_true(type(pair) == "table")
    helpers.assert_eq(pair.left, "(")
    helpers.assert_eq(pair.right, ")")
  end)

  helpers.it("get_wrap_pair returns pair for closing ')'", function()
    local pair = M.get_wrap_pair(")")
    helpers.assert_true(type(pair) == "table")
    helpers.assert_eq(pair.left, "(")
    helpers.assert_eq(pair.right, ")")
  end)

  helpers.it("get_wrap_pair returns nil for non-wrap char", function()
    helpers.assert_eq(M.get_wrap_pair("a"), nil)
    helpers.assert_eq(M.get_wrap_pair("1"), nil)
  end)

  helpers.it("get_wrap_pair returns nil for empty string", function()
    helpers.assert_eq(M.get_wrap_pair(""), nil)
  end)

  helpers.it("get_wrap_pairs returns the catalogue", function()
    local pairs = M.get_wrap_pairs()
    helpers.assert_true(type(pairs) == "table")
    helpers.assert_true(pairs["("] ~= nil, "has paren")
    helpers.assert_true(pairs['"'] ~= nil, "has double quote")
    helpers.assert_true(pairs["["] ~= nil, "has bracket")
    -- The guillemet opener key carries a trailing space in the shared SSoT.
    helpers.assert_true(pairs["« "] ~= nil, "has guillemet opener from the shared SSoT")
  end)

  -- Regression + SSoT guard: the wrap catalogue must be derived from the shared
  -- JSON (_shared/modules/wrap_symbols/wrap_symbols.json), never hardcoded. Build
  -- the expected flattened lookup straight from the canonical JSON and deep-equal
  -- it against the module's catalogue, so any drift — or a revert to a hardcoded
  -- subset — fails here.
  helpers.it("wrap catalogue matches the shared wrap_symbols.json SSoT", function()
    local json = require("json")
    local path = helpers.driver_root() .. "/../_shared/modules/wrap_symbols/wrap_symbols.json"
    local fh = assert(io.open(path, "r"), "shared wrap_symbols.json must be readable")
    local raw = fh:read("*a")
    fh:close()
    local data = json.decode(raw)
    helpers.assert_true(type(data) == "table" and type(data.groups) == "table",
      "shared catalogue parses into groups")

    local expected = {}
    for _, group in ipairs(data.groups) do
      for _, pair in ipairs(group.pairs or {}) do
        expected[pair.left] = { left = pair.left, right = pair.right }
        if pair.right ~= pair.left then
          expected[pair.right] = { left = pair.left, right = pair.right }
        end
      end
    end

    helpers.assert_eq(M.get_wrap_pairs(), expected)
  end)

  -- ==========================================================================
  -- 3. CapsWord
  -- ==========================================================================

  -- Reset CapsWord state before this block so tests don't leak between runs.
  M.init({})

  helpers.it("is_caps_word_active returns false initially", function()
    helpers.assert_eq(M.is_caps_word_active(), false)
  end)

  helpers.it("toggle_caps_word flips state", function()
    -- Start from known state (off).
    if M.is_caps_word_active() then M.toggle_caps_word() end
    M.toggle_caps_word()
    helpers.assert_true(M.is_caps_word_active())
    M.toggle_caps_word()
    helpers.assert_eq(M.is_caps_word_active(), false)
  end)

  helpers.it("process_caps_word returns nil when inactive", function()
    -- Ensure CapsWord is off.
    if M.is_caps_word_active() then M.toggle_caps_word() end
    helpers.assert_eq(M.process_caps_word("a"), nil)
  end)

  helpers.it("process_caps_word capitalizes first letter of word", function()
    -- Toggle off-then-on so _caps_word_triggered is clean (toggle_caps_word resets it).
    if M.is_caps_word_active() then M.toggle_caps_word() end
    M.toggle_caps_word()
    helpers.assert_eq(M.process_caps_word("a"), "A")
    -- CapsWord auto-disengages after first letter; next letter passes through.
    helpers.assert_eq(M.process_caps_word("b"), nil)
  end)

  helpers.it("process_caps_word only capitalizes first letter", function()
    if M.is_caps_word_active() then M.toggle_caps_word() end
    M.toggle_caps_word()
    M.process_caps_word("h") -- first letter → "H"
    -- Second letter of same word should pass through.
    helpers.assert_eq(M.process_caps_word("e"), nil)
    helpers.assert_eq(M.process_caps_word("l"), nil)
  end)

  helpers.it("process_caps_word resets on word boundary", function()
    if M.is_caps_word_active() then M.toggle_caps_word() end
    M.toggle_caps_word()
    M.process_caps_word("h") -- capitalize → "H"
    -- Space resets the word boundary.
    helpers.assert_eq(M.process_caps_word(" "), nil) -- boundary
    -- Next word: first letter capitalized again.
    helpers.assert_eq(M.process_caps_word("w"), "W")
  end)

  helpers.it("process_caps_word resets on punctuation", function()
    if M.is_caps_word_active() then M.toggle_caps_word() end
    M.toggle_caps_word()
    M.process_caps_word("t") -- capitalize → "T"
    helpers.assert_eq(M.process_caps_word("."), nil) -- boundary
    helpers.assert_eq(M.process_caps_word("n"), "N") -- new word
  end)

  helpers.it("process_caps_word passes already-uppercase through", function()
    if M.is_caps_word_active() then M.toggle_caps_word() end
    M.toggle_caps_word()
    -- Already uppercase — no change needed, but still marks as triggered.
    helpers.assert_eq(M.process_caps_word("A"), nil)
  end)

  helpers.it("disable clears CapsWord state", function()
    M.toggle_caps_word() -- on
    M.disable()
    helpers.assert_eq(M.is_caps_word_active(), false)
    helpers.assert_eq(M.process_caps_word("a"), nil)
  end)

  -- ==========================================================================
  -- 4. Enable / disable / toggle
  -- ==========================================================================

  helpers.it("is_enabled returns false initially", function()
    M.disable()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  helpers.it("enable/disable round-trip", function()
    M.enable()
    helpers.assert_true(M.is_enabled())
    M.disable()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  helpers.it("toggle flips state", function()
    M.disable()
    M.toggle()
    helpers.assert_true(M.is_enabled())
    M.toggle()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  -- ==========================================================================
  -- 5. Text transforms (no-op without xclip — safe to call)
  -- ==========================================================================

  helpers.it("transform_uppercase does not crash", function()
    local ok = pcall(M.transform_uppercase)
    helpers.assert_true(ok, "transform_uppercase should not crash")
  end)

  helpers.it("transform_lowercase does not crash", function()
    local ok = pcall(M.transform_lowercase)
    helpers.assert_true(ok, "transform_lowercase should not crash")
  end)

  helpers.it("transform_titlecase does not crash", function()
    local ok = pcall(M.transform_titlecase)
    helpers.assert_true(ok, "transform_titlecase should not crash")
  end)

  helpers.it("select_word does not crash", function()
    local ok = pcall(M.select_word)
    helpers.assert_true(ok, "select_word should not crash")
  end)

  helpers.it("select_line does not crash", function()
    local ok = pcall(M.select_line)
    helpers.assert_true(ok, "select_line should not crash")
  end)

  helpers.it("paste_plain does not crash", function()
    local ok = pcall(M.paste_plain)
    helpers.assert_true(ok, "paste_plain should not crash")
  end)

  -- ==========================================================================
  -- 6. Init
  -- ==========================================================================

  helpers.it("init with empty opts does not crash", function()
    local ok = pcall(function() M.init({}) end)
    helpers.assert_true(ok)
  end)

  helpers.it("init with enabled=true enables", function()
    M.init({ enabled = true })
    helpers.assert_true(M.is_enabled())
    M.disable()
  end)

  -- ==========================================================================
  -- 7. Menu builder integration
  -- ==========================================================================

  helpers.it("menu_builder renders shortcuts section when context present", function()
    local ok_mb, menu_builder = pcall(require, "ui.menu.menu_builder")
    -- Asserted, not skipped. ui/menu/menu_builder.lua ships with this driver, so
    -- "not available" can only mean it stopped loading — and the skip made that
    -- indistinguishable from a pass in six cases across three files.
    helpers.assert_true(ok_mb and menu_builder ~= nil,
      "ui.menu.menu_builder must load: " .. tostring(menu_builder))

    M.enable()
    local items = menu_builder.build({
      _version  = "3.0.0",
      shortcuts = M,
    })

    local found = false
    for _, item in ipairs(items) do
      if type(item) == "table" and item.title and item.title:find("Raccourcis") then
        found = true
        helpers.assert_true(type(item.menu) == "table", "shortcuts should have a submenu")
        helpers.assert_true(#item.menu > 0, "shortcuts submenu should have items")
        break
      end
    end
    helpers.assert_true(found, "menu should contain a shortcuts section")
    M.disable()
  end)

  helpers.it("menu_builder handles nil shortcuts gracefully", function()
    local ok_mb, menu_builder = pcall(require, "ui.menu.menu_builder")
    -- Asserted, not skipped. ui/menu/menu_builder.lua ships with this driver, so
    -- "not available" can only mean it stopped loading — and the skip made that
    -- indistinguishable from a pass in six cases across three files.
    helpers.assert_true(ok_mb and menu_builder ~= nil,
      "ui.menu.menu_builder must load: " .. tostring(menu_builder))

    local items = menu_builder.build({
      _version  = "3.0.0",
      shortcuts = nil,
    })

    local found = false
    for _, item in ipairs(items) do
      if type(item) == "table" and item.title and item.title:find("Raccourcis") then
        found = true
        break
      end
    end
    helpers.assert_true(found, "menu should contain a shortcuts stub when module absent")
  end)

end)
