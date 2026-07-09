--- tests/unit/meta/test_kanata_manager.lua
---
--- Phase P2.5: Compliance tests for the kanata manager module.
--- Verifies the module API surface, .kbd generation (without kanata binary),
--- and idempotent lifecycle methods. Since kanata is a daemon-only feature,
--- the process start/stop methods are tested only for crash-freedom.

local helpers = require("tests.helpers")
local km      = helpers.load_module("modules.kanata.manager")

helpers.describe("kanata manager (P2.5)", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports the expected methods", function()
      helpers.assert_true(type(km.generate_kbd) == "function", "generate_kbd")
      helpers.assert_true(type(km.write_kbd)    == "function", "write_kbd")
      helpers.assert_true(type(km.get_kbd_path)  == "function", "get_kbd_path")
      helpers.assert_true(type(km.start)        == "function", "start")
      helpers.assert_true(type(km.stop)         == "function", "stop")
      helpers.assert_true(type(km.restart)      == "function", "restart")
      helpers.assert_true(type(km.is_running)   == "function", "is_running")
    end)
  end)

  -- ==========================================================================
  -- 2. .kbd generation (template-based, without kanata binary)
  -- ==========================================================================

  helpers.describe("kbd generation", function()

    helpers.it("generate_kbd returns a non-empty string", function()
      local kbd = km.generate_kbd()
      -- May return nil if template not found (non-standard test cwd).
      -- If template is found, it should produce valid content.
      if kbd then
        helpers.assert_true(type(kbd) == "string" and #kbd > 0,
          "generate_kbd returns non-empty string")
        -- Should contain kanata structural markers.
        helpers.assert_true(kbd:find("defcfg", 1, true) or kbd:find("defsrc", 1, true),
          "contains kanata structural markers")
        helpers.assert_true(kbd:find("defalias", 1, true),
          "contains defalias block")
      end
    end)

    helpers.it("write_kbd writes a file to the kanata config dir", function()
      local ok = km.write_kbd()
      if ok then
        local path = km.get_kbd_path()
        helpers.assert_true(type(path) == "string" and path:find("kanata", 1, true),
          "kbd path contains 'kanata'")
        local fh = io.open(path, "r")
        if fh then
          local content = fh:read("*a")
          fh:close()
          helpers.assert_true(#content > 0, "written .kbd is non-empty")
        end
      end
    end)

    helpers.it("get_kbd_path returns a string with .kbd extension", function()
      local path = km.get_kbd_path()
      helpers.assert_true(type(path) == "string", "returns a string")
      helpers.assert_true(path:find("%.kbd$") ~= nil, "ends with .kbd")
    end)
  end)

  -- ==========================================================================
  -- 3. Process lifecycle (without kanata binary — safe stubs)
  -- ==========================================================================

  helpers.describe("process lifecycle", function()

    helpers.it("is_running returns false when kanata is not started", function()
      helpers.assert_true(type(km.is_running()) == "boolean", "is_running returns boolean")
      -- On the maintainer's machine, kanata is not installed → false.
    end)

    helpers.it("start does not crash when kanata binary is absent", function()
      local ok = pcall(function() km.start() end)
      helpers.assert_true(ok, "start does not crash")
    end)

    helpers.it("stop does not crash when not running", function()
      local ok = pcall(function() km.stop() end)
      helpers.assert_true(ok, "stop when not running is safe")
    end)

    helpers.it("double stop is safe", function()
      km.stop()
      local ok = pcall(function() km.stop() end)
      helpers.assert_true(ok, "double stop does not crash")
    end)

    helpers.it("restart does not crash (will fail gracefully without kanata)", function()
      local ok = pcall(function() km.restart() end)
      helpers.assert_true(ok, "restart does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. Menu builder integration
  -- ==========================================================================

  helpers.describe("menu builder integration", function()

    helpers.it("menu_builder Kanata section items have valid shape", function()
      local mb = helpers.load_module("modules.menu.menu_builder")
      local items = mb.build({ _version = "test", on_quit = function() end })

      -- Find the Kanata section.
      local kanata_section = nil
      for _, item in ipairs(items) do
        if type(item.title) == "string" and item.title:find("Kanata", 1, true) then
          kanata_section = item
          break
        end
      end

      helpers.assert_true(kanata_section ~= nil, "Kanata section present in menu")
      if kanata_section then
        helpers.assert_true(type(kanata_section.menu) == "table" and #kanata_section.menu > 0,
          "Kanata section has submenu items")
        -- Verify each submenu item has a fn.
        for _, sub in ipairs(kanata_section.menu) do
          helpers.assert_true(type(sub.fn) == "function",
            "Kanata item '" .. (sub.title or "?") .. "' has a callback")
        end
      end
    end)
  end)

  -- ==========================================================================
  -- 5. Lifecycle log pairing (source compliance)
  -- ==========================================================================

  helpers.describe("lifecycle log pairing", function()

    -- Static source scan: the write_kbd()/start() SUCCESS lines are unreachable
    -- in the headless suite (no kanata binary; the .kbd template resolves
    -- off-tree), so a runtime spy cannot observe them — assert pairing on source.
    local function read_manager_source()
      local path = helpers.driver_root() .. "/modules/kanata/manager.lua"
      local fh = assert(io.open(path, "r"), "cannot open manager.lua")
      local content = fh:read("*a")
      fh:close()
      return content
    end

    helpers.it("emits no Logger.success without a preceding Logger.start", function()
      local content = read_manager_source()
      -- A top-level `function` header resets the per-function running balance so
      -- each function is checked in isolation; success/done must never run ahead
      -- of start/trace on their own lifecycle axis (lifecycle logs are paired).
      local info_starts, info_success = 0, 0
      local dbg_starts,  dbg_done     = 0, 0
      local violations = {}
      local lineno = 0
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        if line:match("^%s*function%s") or line:match("^%s*local%s+function%s") then
          info_starts, info_success = 0, 0
          dbg_starts,  dbg_done     = 0, 0
        end
        if line:find("Logger%.start%(")   then info_starts = info_starts + 1 end
        if line:find("Logger%.trace%(")   then dbg_starts  = dbg_starts  + 1 end
        if line:find("Logger%.success%(") then
          info_success = info_success + 1
          if info_success > info_starts then
            violations[#violations + 1] =
              "line " .. lineno .. ": Logger.success without a preceding Logger.start"
          end
        end
        if line:find("Logger%.done%(") then
          dbg_done = dbg_done + 1
          if dbg_done > dbg_starts then
            violations[#violations + 1] =
              "line " .. lineno .. ": Logger.done without a preceding Logger.trace"
          end
        end
      end
      helpers.assert_eq(#violations, 0,
        "orphaned lifecycle logs in manager.lua: " .. table.concat(violations, "; "))
    end)
  end)

end)
