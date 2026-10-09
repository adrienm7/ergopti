--- tests/unit/meta/test_keyboard_hook_adapter.lua
---
--- Integration tests for the keyboard_hook adapter.
--- Now tests the full implementation: subprocess management, pump(), context
--- tracking, event parsing, control key dispatch, dual mode (observe/intercept).
---
--- Real evdev reading requires a Linux machine with:
---   libinput debug-events (observe, no root needed)
---   evtest --grab (intercept, needs root)
---   /dev/input/eventN device

local helpers = require("tests.helpers")
local hook    = helpers.load_module("adapters.keyboard_hook")

helpers.describe("keyboard_hook adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports start", function()
      helpers.assert_true(type(hook.start) == "function", "start is a function")
    end)
    helpers.it("exports stop", function()
      helpers.assert_true(type(hook.stop) == "function", "stop is a function")
    end)
    helpers.it("exports isRunning", function()
      helpers.assert_true(type(hook.isRunning) == "function", "isRunning is a function")
    end)
    helpers.it("exports refreshContext", function()
      helpers.assert_true(type(hook.refreshContext) == "function", "refreshContext is a function")
    end)
    helpers.it("exports getContext", function()
      helpers.assert_true(type(hook.getContext) == "function", "getContext is a function")
    end)
    helpers.it("exports pump", function()
      helpers.assert_true(type(hook.pump) == "function", "pump is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. Lifecycle: start / stop / isRunning
  -- ==========================================================================

  helpers.describe("lifecycle", function()
    helpers.it("isRunning is false before start", function()
      helpers.assert_eq(hook.isRunning(), false, "not running initially")
    end)

    -- isRunning() is the state start/stop exist to move, and only one case
    -- asserted it. The rest checked a pcall status, which reads the same whether
    -- the hook attached to a device or failed and left the driver deaf. A hook
    -- that silently does not run means no hotstring, no layer and no metric ever
    -- fires again — the loudest possible failure, reported as a pass.
    helpers.it("start with nil opts leaves a definite running state", function()
      hook.start(nil)
      helpers.assert_eq(type(hook.isRunning()), "boolean",
        "start must resolve to a definite state, not leave isRunning nil")
      hook.stop()
      helpers.assert_eq(hook.isRunning(), false, "and stop must clear it")
    end)

    helpers.it("start on a device that is not a keyboard does not report running", function()
      hook.start({ device = "/dev/null" })
      helpers.assert_eq(hook.isRunning(), false,
        "/dev/null is not a keyboard — claiming to run would make the driver wait "
          .. "forever for events that cannot arrive")
      hook.stop()
    end)

    helpers.it("a second start does not leave a stale running flag", function()
      hook.start({ device = "/dev/null" })
      hook.start({ device = "/dev/null" })
      helpers.assert_eq(hook.isRunning(), false,
        "two failed starts must still leave isRunning false — a flag set by the "
          .. "second attempt would mask the failure of both")
      hook.stop()
      helpers.assert_eq(hook.isRunning(), false, "and stop after a double start clears it")
    end)

    helpers.it("stop when not running leaves it not running", function()
      hook.stop()
      helpers.assert_eq(hook.isRunning(), false,
        "stopping an idle hook must be a no-op, not a state flip")
    end)

    helpers.it("stop after a failed start clears the state and stays usable", function()
      hook.start({ device = "/dev/null" })
      hook.stop()
      helpers.assert_eq(hook.isRunning(), false, "the failed start must leave nothing behind")
      -- And the adapter must accept another attempt: the driver retries when a
      -- device appears.
      hook.start({ device = "/dev/null" })
      helpers.assert_eq(type(hook.isRunning()), "boolean",
        "a retry after a failed start must still resolve to a definite state")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 3. pump() — event loop polling
  -- ==========================================================================

  -- pump() runs on every event-loop tick. Its contract when stopped is that it
  -- dispatches nothing and does not start anything — a pump that woke the hook
  -- up would capture keystrokes after the user asked for them to stop.
  helpers.describe("pump()", function()
    helpers.it("pumping while stopped dispatches nothing and starts nothing", function()
      local chars = 0
      hook.stop()
      hook.start({ device = "/dev/null", onChar = function() chars = chars + 1 end })
      hook.stop()
      hook.pump()
      helpers.assert_eq(chars, 0, "a stopped hook must deliver no characters")
      helpers.assert_eq(hook.isRunning(), false, "and must not restart itself")
    end)

    helpers.it("a hundred polls while stopped stay inert", function()
      local chars = 0
      hook.stop()
      hook.start({ device = "/dev/null", onChar = function() chars = chars + 1 end })
      hook.stop()
      for _ = 1, 100 do hook.pump() end
      helpers.assert_eq(chars, 0,
        "repeated polling must not accumulate a spurious keystroke — this runs "
          .. "thousands of times a minute")
      helpers.assert_eq(hook.isRunning(), false, "and must still be stopped afterwards")
    end)
  end)

  -- ==========================================================================
  -- 4. Callback registration
  -- ==========================================================================

  helpers.describe("callbacks", function()
    -- A registered callback that is never delivered to is the failure mode here,
    -- and it looks exactly like a successful start from outside. The assertion is
    -- that a FAILED start delivers nothing — the driver must not believe it is
    -- receiving keystrokes it will never get.
    helpers.it("an onChar callback is accepted and never fires on a failed start", function()
      local chars = 0
      hook.start({ device = "/dev/null", onChar = function() chars = chars + 1 end })
      hook.pump()
      helpers.assert_eq(chars, 0,
        "a hook that never attached must deliver no characters, so the caller can "
          .. "tell it is deaf instead of assuming a quiet keyboard")
      hook.stop()
    end)

    helpers.it("an onKey callback is accepted and never fires on a failed start", function()
      local keys = 0
      hook.start({ device = "/dev/null", onKey = function() keys = keys + 1 end })
      hook.pump()
      helpers.assert_eq(keys, 0, "the same holds for raw key events")
      hook.stop()
    end)

    helpers.it("both callbacks together leave a definite state", function()
      local chars, keys = 0, 0
      hook.start({
        device = "/dev/null",
        onChar = function() chars = chars + 1 end,
        onKey  = function() keys = keys + 1 end,
      })
      hook.pump()
      helpers.assert_eq(chars + keys, 0, "neither callback fires without a real device")
      helpers.assert_eq(hook.isRunning(), false, "and the hook does not claim to run")
      hook.stop()
    end)

    helpers.it("non-function callbacks are ignored rather than stored and called", function()
      -- The hazard is storing them: a later dispatch would call a string.
      hook.start({ device = "/dev/null", onChar = "not a function", onKey = 42 })
      hook.pump()
      helpers.assert_eq(hook.isRunning(), false,
        "a bad callback must not be treated as a working one")
      hook.stop()
      helpers.assert_eq(hook.isRunning(), false, "and stop must still clear the state")
    end)
  end)

  -- ==========================================================================
  -- 5. Intercept mode
  -- ==========================================================================

  helpers.describe("intercept mode", function()
    helpers.it("exports get_mode", function()
      helpers.assert_true(type(hook.get_mode) == "function", "get_mode is a function")
    end)

    helpers.it("defaults to observe mode before any start", function()
      -- A freshly loaded hook has not grabbed the device. Race-free hotstring
      -- replacement requires "intercept"; "observe" is the current safe default.
      local fresh = helpers.load_module("adapters.keyboard_hook")
      helpers.assert_eq(fresh.get_mode(), "observe", "default mode is observe (no grab)")
    end)

    helpers.it("get_mode reports intercept after start with intercept=true", function()
      -- start() resolves the intercept flag before device resolution, so even a
      -- failed launch on /dev/null records the requested capture mode.
      hook.start({ device = "/dev/null", intercept = true })
      helpers.assert_eq(hook.get_mode(), "intercept",
        "get_mode must report the requested grab/intercept mode")
      hook.stop()
    end)

    helpers.it("get_mode reports observe after start with intercept=false", function()
      hook.start({ device = "/dev/null", intercept = false })
      helpers.assert_eq(hook.get_mode(), "observe",
        "get_mode must report observe when grab was not requested")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 6. Layout selection
  -- ==========================================================================

  -- The layout decides which character a scancode becomes, so a silently ignored
  -- layout option types the wrong letters. get_mode-style state is not exposed
  -- for it, but a failed start must at least not claim to be running under a
  -- layout it never applied.
  helpers.describe("layout", function()
    helpers.it("an explicit qwerty layout is accepted", function()
      hook.start({ device = "/dev/null", layout = "qwerty" })
      helpers.assert_eq(hook.isRunning(), false,
        "the start still fails on /dev/null — the layout must not make it claim success")
      hook.stop()
    end)

    helpers.it("an explicit azerty layout is accepted", function()
      hook.start({ device = "/dev/null", layout = "azerty" })
      helpers.assert_eq(hook.isRunning(), false, "same for the other supported layout")
      hook.stop()
    end)

    helpers.it("an unsupported layout does not prevent a later valid start", function()
      hook.start({ device = "/dev/null", layout = "dvorak" })
      hook.stop()
      hook.start({ device = "/dev/null", layout = "azerty" })
      helpers.assert_eq(type(hook.isRunning()), "boolean",
        "an unknown layout must fall back rather than poison the adapter for the "
          .. "next start")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 7. Context tracking
  -- ==========================================================================

  helpers.describe("context", function()
    helpers.it("getContext returns table with expected fields", function()
      local ctx = hook.getContext()
      helpers.assert_true(type(ctx) == "table", "getContext returns a table")
      helpers.assert_true(ctx.appId ~= nil, "ctx has appId")
      helpers.assert_true(ctx.windowTitle ~= nil, "ctx has windowTitle")
    end)

    helpers.it("getContext defaults to empty strings", function()
      local ctx = hook.getContext()
      helpers.assert_eq(ctx.appId, "", "appId defaults to ''")
      helpers.assert_eq(ctx.windowTitle, "", "windowTitle defaults to ''")
    end)

    -- refreshContext shells out to xdotool. When it is absent the context must
    -- stay at its documented empty default rather than become nil — every
    -- consumer indexes ctx.appId, and the keylogger writes it into a row.
    helpers.it("refreshContext leaves a usable context when xdotool is absent", function()
      hook.refreshContext()
      local ctx = hook.getContext()
      helpers.assert_eq(type(ctx), "table", "the context must survive a failed refresh")
      helpers.assert_eq(type(ctx.appId), "string",
        "appId must stay a string — a nil here reaches the metrics row and the "
          .. "privacy filters that key on it")
      helpers.assert_eq(type(ctx.windowTitle), "string", "and so must windowTitle")
    end)
  end)

  -- ==========================================================================
  -- 8. Event parsing (unit tests for parser functions via pump)
  -- ==========================================================================

  helpers.describe("event parsing", function()
    helpers.it("pumping a hook whose pipe never opened delivers nothing", function()
      local chars, keys = 0, 0
      hook.start({
        device = "/dev/null",
        onChar = function() chars = chars + 1 end,
        onKey  = function() keys = keys + 1 end,
      })
      for _ = 1, 20 do hook.pump() end
      helpers.assert_eq(chars + keys, 0,
        "with no subprocess pipe there are no events to parse, so a delivered "
          .. "callback would mean the parser invented one")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 9. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("start-stop-start-stop rapid cycle", function()
      for _ = 1, 5 do
        hook.start({ device = "/dev/null" })
        hook.stop()
      end
      helpers.assert_eq(hook.isRunning(), false, "stable after rapid cycle")
    end)

    -- Every option is the wrong type. The contract is that each is dropped
    -- individually: a string intercept must not be read as truthy and grab the
    -- keyboard, and a table onChar must not be stored as a callable.
    helpers.it("a fully malformed options table is dropped field by field", function()
      hook.start({
        intercept = "yes",
        layout    = 42,
        onChar    = { also = "wrong" },
      })
      helpers.assert_eq(hook.get_mode(), "observe",
        "intercept='yes' is a string, not true — reading it as truthy would GRAB the "
          .. "keyboard, and a grab that the driver then fails to release leaves the "
          .. "machine unable to type")
      helpers.assert_eq(hook.isRunning(), false, "and the malformed start must not claim to run")
      hook.stop()
    end)
  end)

end)
