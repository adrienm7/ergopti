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
	helpers.assert_true(type(M.set_enabled) == "function", "set_enabled")
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
  -- 5. Text transforms (safe to call without a desktop clipboard)
  -- ==========================================================================

  helpers.it("transform_uppercase is a no-op without a clipboard tool, and says so", function()
    -- Called directly: a raise fails with the real error. The claim is that the
    -- action REPORTS its refusal — these are bound to user keystrokes, and one
    -- that silently returned success would leave the shortcut looking broken
    -- with nothing in the logs to say the clipboard tool is missing.
    local ok = M.transform_uppercase()
    helpers.assert_true(ok == nil or type(ok) == "boolean",
      "transform_uppercase must answer nil or a boolean, never a half-value the caller branches on")
  end)

  helpers.it("transform_lowercase is a no-op without a clipboard tool, and says so", function()
    -- Called directly: a raise fails with the real error. The claim is that the
    -- action REPORTS its refusal — these are bound to user keystrokes, and one
    -- that silently returned success would leave the shortcut looking broken
    -- with nothing in the logs to say the clipboard tool is missing.
    local ok = M.transform_lowercase()
    helpers.assert_true(ok == nil or type(ok) == "boolean",
      "transform_lowercase must answer nil or a boolean, never a half-value the caller branches on")
  end)

  helpers.it("transform_titlecase is a no-op without a clipboard tool, and says so", function()
    -- Called directly: a raise fails with the real error. The claim is that the
    -- action REPORTS its refusal — these are bound to user keystrokes, and one
    -- that silently returned success would leave the shortcut looking broken
    -- with nothing in the logs to say the clipboard tool is missing.
    local ok = M.transform_titlecase()
    helpers.assert_true(ok == nil or type(ok) == "boolean",
      "transform_titlecase must answer nil or a boolean, never a half-value the caller branches on")
  end)

  helpers.it("select_word is a no-op without a clipboard tool, and says so", function()
    -- Called directly: a raise fails with the real error. The claim is that the
    -- action REPORTS its refusal — these are bound to user keystrokes, and one
    -- that silently returned success would leave the shortcut looking broken
    -- with nothing in the logs to say the clipboard tool is missing.
    local ok = M.select_word()
    helpers.assert_true(ok == nil or type(ok) == "boolean",
      "select_word must answer nil or a boolean, never a half-value the caller branches on")
  end)

  helpers.it("select_line is a no-op without a clipboard tool, and says so", function()
    -- Called directly: a raise fails with the real error. The claim is that the
    -- action REPORTS its refusal — these are bound to user keystrokes, and one
    -- that silently returned success would leave the shortcut looking broken
    -- with nothing in the logs to say the clipboard tool is missing.
    local ok = M.select_line()
    helpers.assert_true(ok == nil or type(ok) == "boolean",
      "select_line must answer nil or a boolean, never a half-value the caller branches on")
  end)

  helpers.it("paste_plain is a no-op without a clipboard tool, and says so", function()
    -- Called directly: a raise fails with the real error. The claim is that the
    -- action REPORTS its refusal — these are bound to user keystrokes, and one
    -- that silently returned success would leave the shortcut looking broken
    -- with nothing in the logs to say the clipboard tool is missing.
    local ok = M.paste_plain()
    helpers.assert_true(ok == nil or type(ok) == "boolean",
      "paste_plain must answer nil or a boolean, never a half-value the caller branches on")
  end)

  helpers.it("routes desktop interaction through portable adapters", function()
	local path = helpers.driver_root() .. "/modules/shortcuts/manager.lua"
	local file = assert(io.open(path, "r"))
	local source = file:read("*a")
	file:close()
	for _, forbidden in ipairs({ "xdotool", "xclip", "io.popen", "os.execute" }) do
		helpers.assert_true(source:find(forbidden, 1, true) == nil,
			"the shortcuts manager must not bypass adapters with " .. forbidden)
	end
  end)

  -- ==========================================================================
  -- 6. Init
  -- ==========================================================================

	helpers.it("init with empty opts applies the shared enabled default", function()
		M.init({})
		helpers.assert_eq(M.is_enabled(), false,
			"Linux must apply the same shared shortcut default as macOS")
	end)

	helpers.it("an explicit init override wins for tests and controlled launches", function()
		M.init({ enabled = false })
		helpers.assert_eq(M.is_enabled(), false)
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

helpers.describe("Shortcuts master publication: exact acknowledgement", function()
	--- Keeps each real manager and private canonical file independent of prior cases.
	--- @param enabled boolean Initial durable/runtime master state.
	--- @param body function Uses the fresh native owner and exact source.
	local function with_master(enabled, body)
		local path = os.tmpname()
		local source = '# independent future shortcut preferences\n[shortcuts]\nenabled = '
			.. tostring(enabled) .. '\nfuture_mode = "kept" # preserve this comment\n[future]\nvalues = ["a", "b"]\n'
		local file = assert(io.open(path, "wb"));assert(file:write(source));assert(file:close())
		local prior = package.loaded["modules.shortcuts.manager"]
		local writer, rename = require("toml_codec.writer"), os.rename
		local batch = writer.batch_write
		local called, failure = pcall(function()
			local manager = helpers.load_module("modules.shortcuts.manager")
			manager.init({ persist = true, config_path = path })
			body(manager, path, source, writer)
		end)
		writer.batch_write, os.rename = batch, rename
		package.loaded["modules.shortcuts.manager"] = prior
		os.remove(path .. ".tmp")
		local removed = os.remove(path)
		assert(removed, "the owned master fixture is physically retired")
		if not called then error(failure, 0) end
	end
	--- Reads the actual canonical image after its writer has returned.
	--- @param path string Owned private config path.
	--- @return string source Exact bytes.
	local function read(path)
		local file = assert(io.open(path, "rb"));local source = file:read("*a");assert(file:close());return source
	end

	for _, initial in ipairs({ true, false }) do
		for _, outcome in ipairs({ "committed", "rename-false", "rename-nil", "rename-number", "rename-throw", "ack-number", "ack-text", "ack-throw" }) do
			helpers.it("requires exact durable master acknowledgement " .. outcome .. " from " .. tostring(initial), function()
				with_master(initial, function(manager, path, source, writer)
					local renamed, published = os.rename, 0
					if outcome:match("^rename%-") then
						os.rename = function(from, to)
							if from == path .. ".tmp" and to == path then
								published = published + 1
								if outcome == "rename-throw" then error("controlled publication refusal") end
								if outcome == "rename-nil" then return nil, "controlled publication refusal" end
								if outcome == "rename-number" then return 2 end
								return false, "controlled publication refusal"
							end
							return renamed(from, to)
						end
					elseif outcome:match("^ack%-") then
						writer.batch_write = function()
							if outcome == "ack-number" then return 2 end
							if outcome == "ack-throw" then error("controlled writer refusal") end
							return "true"
						end
					end
					local called, committed = pcall(manager.set_enabled, not initial)
					os.rename = renamed
					helpers.assert_true(called, "the public master owner returns a refused acknowledgement")
					helpers.assert_eq(committed, outcome == "committed")
					local expected = initial
					if outcome == "committed" then expected = not initial end
					helpers.assert_eq(manager.is_enabled(), expected)
					if outcome == "committed" then
						helpers.assert_eq(read(path), source:gsub("enabled = " .. tostring(initial), "enabled = " .. tostring(not initial), 1))
						manager.init({ persist = true, config_path = path })
						helpers.assert_eq(manager.is_enabled(), not initial, "a native reload reads the durable target")
					else
						helpers.assert_eq(read(path), source, "refusal retains all prior bytes and future fields")
						if outcome:match("^rename%-") then helpers.assert_eq(published, 1) end
					end
				end)
			end)
		end
		helpers.it("keeps the historical toggle posture ABI from " .. tostring(initial), function()
			with_master(initial, function(manager, path, source, writer)
				local batch = writer.batch_write
				writer.batch_write = function() return false, "controlled refusal" end
				local refused = manager.toggle()
				writer.batch_write = batch
				helpers.assert_eq(refused, initial, "toggle returns posture rather than a commit receipt")
				helpers.assert_eq(read(path), source)
				helpers.assert_eq(manager.toggle(), not initial)
				helpers.assert_eq(manager.is_enabled(), not initial)
			end)
		end)
		for _, outcome in ipairs({ "committed", "false", "nil", "number", "throw" }) do
			helpers.it("ties the real menu to durable master publication " .. outcome .. " from " .. tostring(initial), function()
				with_master(initial, function(manager, path, source)
					local builder = helpers.load_module("ui.menu.menu_builder")
					local redraws, attempts, notices, releases = 0, 0, {}, 0
					local tree = builder.build({ shortcuts = manager, _version = "9.9.9",
						on_menu_changed = function() redraws = redraws + 1 end })
					local title = require("infra.i18n").get("menu.shortcuts.enable")
					local action, matches = nil, 0
					for _, group in ipairs(tree) do
						for _, row in ipairs(group.menu or {}) do
							if row.title == title then action = row.fn; matches = matches + 1 end
						end
					end
					helpers.assert_eq(matches, 1)
					helpers.assert_eq(type(action), "function")
					local rename, execute, modal = os.rename, os.execute, require("ui.modal")
					local run = modal.run
					os.rename = function(from, to)
						if from == path .. ".tmp" and to == path then
							attempts = attempts + 1
							if outcome == "throw" then error("controlled publication refusal") end
							if outcome == "false" then return false end
							if outcome == "nil" then return nil end
							if outcome == "number" then return 2 end
						end
						return rename(from, to)
					end
					modal.run = function(callback) releases = releases + 1; return callback() end
					os.execute = function(command)
						if command:find("zenity", 1, true) then notices[#notices + 1] = command; return 0 end
						return execute(command)
					end
					local called, receipt = pcall(action)
					os.rename, os.execute, modal.run = rename, execute, run
					helpers.assert_true(called)
					helpers.assert_eq(attempts, 1)
					helpers.assert_eq(receipt, outcome == "committed")
					helpers.assert_eq(redraws, outcome == "committed" and 1 or 0)
					helpers.assert_eq(#notices, outcome == "committed" and 0 or 1)
					helpers.assert_eq(releases, #notices)
					local expected = initial
					if outcome == "committed" then expected = not initial end
					helpers.assert_eq(manager.is_enabled(), expected)
					local expected_source = source
					if outcome == "committed" then
						expected_source = source:gsub("enabled = " .. tostring(initial), "enabled = " .. tostring(expected), 1)
					end
					helpers.assert_eq(read(path), expected_source, "the real canonical owner preserves unrelated future data")
				end)
			end)
		end

	end
end)
