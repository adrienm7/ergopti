-- Root native-component control: actual libxkbcommon through the original adapter.
local root = assert(arg[1], "Pass the repository root")
package.path = root .. "/static/ergopti_plus/linux/?.lua;"
	.. root .. "/static/ergopti_plus/linux/?/init.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local Capture = require("adapters.xkb_capture")
local keymap = [[
xkb_keymap {
 xkb_keycodes { include "evdev+aliases(qwerty)" };
 xkb_types { include "complete" };
 xkb_compatibility { include "complete" };
 xkb_symbols { include "pc+us+inet(evdev)" };
};
]]
assert(Capture.load(keymap, "C.UTF-8"))
assert(Capture.peek_text(30) == "a")
Capture.process(58, 1); Capture.process(58, 0)
assert(Capture.caps_locked() and Capture.peek_text(30) == "A")
assert(Capture.modifier_role(42) == "shift")
Capture.process(42, 1)
local live = assert(Capture.peek_text(30))
assert(live == "a")
local inverse = assert(Capture.inverse_table(false))
local plan = assert(inverse.A)
assert(plan.keycode == 30 and #plan.mods == 1 and plan.mods[1] == "shift")
assert(Capture.peek_text(plan.keycode) == "a")
Capture.process(42, 0)
assert(Capture.peek_text(plan.keycode) == "A")
Capture.process(58, 1); Capture.process(58, 0)
assert(not Capture.caps_locked() and Capture.peek_text(30) == "a")
Capture.process(42, 1)
assert(Capture.peek_text(plan.keycode) == "A")
Capture.process(42, 0)
Capture.clear()
assert(not Capture.is_ready())
print("NATIVE_INVERSE=" .. assert(require("json").encode({
	live_caps_shift_text = live, requested_title = "A", inverse_plan = plan,
	qualification = "Actual libxkbcommon through original Capture adapter with explicit standard US keymap; no desktop authority, physical device, whole engine or receiving application."
})))
