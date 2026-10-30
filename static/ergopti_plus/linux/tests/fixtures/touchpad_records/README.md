<!-- static/ergopti_plus/linux/tests/fixtures/touchpad_records/README.md -->

# Touchpad traces

Captures of real touchpads in `libinput record` format, one `.yml` file per
recording, each declaring its gestures with `# ergopti-expect:` lines.
`tests/unit/modules/gestures/engine/test_touchpad_record.lua` replays every one
into the gesture decoder; `HARDWARE.md` section 13 says how to record one.
None is here yet: that needs a physical touchpad on a Linux machine.
