--- tests/unit/infra/test_display_server.lua

--- ==============================================================================
--- MODULE: Display Server Detection
--- DESCRIPTION:
--- Which server the driver decides is running, for every combination of the
--- three environment variables that carry the answer.
---
--- WHY THIS IS THE ASSERTION:
--- One ordering mistake here mislabels every Wayland session in existence.
--- XWayland sets DISPLAY, so a probe that checks DISPLAY before WAYLAND_DISPLAY
--- classifies every modern desktop as X11 and then reaches for xdotool, which
--- answers for X11 clients only — the failure looks like "hotstrings work in
--- some apps", which is the hardest kind of report to act on.
---
--- The second ordering rule is subtler. XDG_SESSION_TYPE is a label a login
--- manager writes, and more than one writes "tty" for a perfectly good graphical
--- session; WAYLAND_DISPLAY is a socket that exists or does not. A positive fact
--- outranks a label, and the cases below pin that even when the two disagree.
---
--- No case here asserts "does not crash". Every one names the answer, because
--- the failure mode is a confident wrong answer rather than an error.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a body with a controlled environment, restoring it afterwards.
---
--- os.getenv cannot be set from Lua, so the module's own reader is what gets
--- replaced. Stubbing os.getenv globally is the only seam that exercises the
--- real probe rather than a parallel copy of its rules.
--- @param vars table Name → value; anything absent reads as unset.
--- @param body function Receives the freshly loaded module.
local function with_env(vars, body)
	local real_getenv = os.getenv
	os.getenv = function(name) return vars[name] end
	local ok, err = pcall(function()
		local ds = helpers.load_module("infra.display_server")
		ds._set_for_test(nil, nil)
		body(ds)
	end)
	os.getenv = real_getenv
	if not ok then error(err, 0) end
end





-- =================================================================
-- =================================================================
-- ======= 1/ Wayland ==============================================
-- =================================================================
-- =================================================================

helpers.describe("display_server: Wayland", function()

	helpers.it("a Wayland socket means Wayland", function()
		with_env({ WAYLAND_DISPLAY = "wayland-0" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.WAYLAND, "WAYLAND_DISPLAY is the socket itself")
			helpers.assert_eq(ds.is_wayland(), true, "and the predicate must agree")
			helpers.assert_eq(ds.is_x11(), false, "and the other predicate must not")
		end)
	end)

	helpers.it("beats DISPLAY, because XWayland sets DISPLAY too", function()
		-- THE regression. Every Wayland desktop with XWayland running has both set.
		-- Checking DISPLAY first labels all of them X11 and sends the driver to
		-- xdotool, which answers only for X11 clients — so window rules would work
		-- in some applications and silently not in others.
		with_env({ WAYLAND_DISPLAY = "wayland-0", DISPLAY = ":0" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.WAYLAND,
				"a Wayland socket outranks the XWayland display it implies")
		end)
	end)

	helpers.it("beats a session label that says otherwise", function()
		-- More than one display manager writes XDG_SESSION_TYPE=tty for a graphical
		-- session. A socket is a fact; the label is a claim.
		with_env({ WAYLAND_DISPLAY = "wayland-0", XDG_SESSION_TYPE = "tty" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.WAYLAND, "the socket outranks the label")
		end)
	end)

	helpers.it("is believed from the session label alone when there is no socket", function()
		with_env({ XDG_SESSION_TYPE = "wayland" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.WAYLAND,
				"a service started before WAYLAND_DISPLAY is exported still has the label")
		end)
	end)

	helpers.it("reads the label case-insensitively", function()
		with_env({ XDG_SESSION_TYPE = "Wayland" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.WAYLAND, "the label's casing is not ours to depend on")
		end)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ X11 and nothing ======================================
-- =================================================================
-- =================================================================

helpers.describe("display_server: X11 and unknown", function()

	helpers.it("DISPLAY with no Wayland socket means X11", function()
		with_env({ DISPLAY = ":0" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.X11, "a bare X display is X11")
			helpers.assert_eq(ds.is_x11(), true, "and the predicate must agree")
		end)
	end)

	helpers.it("the session label alone is enough", function()
		with_env({ XDG_SESSION_TYPE = "x11" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.X11, "a labelled X11 session with no DISPLAY exported yet")
		end)
	end)

	helpers.it("an empty variable is not a set variable", function()
		-- systemd unit files routinely export empty strings. Treating "" as present
		-- is how a TTY service decides it has a display.
		with_env({ WAYLAND_DISPLAY = "", DISPLAY = "" }, function(ds)
			helpers.assert_eq(ds.kind(), ds.UNKNOWN,
				"an exported-but-empty variable carries no session")
		end)
	end)

	helpers.it("answers unknown rather than guessing", function()
		with_env({}, function(ds)
			helpers.assert_eq(ds.kind(), ds.UNKNOWN,
				"a TTY or a headless service has no display server, and guessing X11 "
					.. "here would send every query to a tool that cannot answer")
			helpers.assert_eq(ds.is_wayland(), false, "neither predicate may claim it")
			helpers.assert_eq(ds.is_x11(), false, "neither predicate may claim it")
		end)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ Caching and the session switch =======================
-- =================================================================
-- =================================================================

helpers.describe("display_server: caching", function()

	helpers.it("probes once and keeps the answer", function()
		local reads = 0
		local real_getenv = os.getenv
		os.getenv = function(name)
			reads = reads + 1
			return ({ WAYLAND_DISPLAY = "wayland-0" })[name]
		end
		local ok, err = pcall(function()
			local ds = helpers.load_module("infra.display_server")
			ds._set_for_test(nil, nil)
			ds.kind()
			local after_first = reads
			for _ = 1, 20 do ds.kind() end
			helpers.assert_eq(reads, after_first,
				"the answer cannot change under a running process, and this is read "
					.. "from the window-focus poll four times a second")
		end)
		os.getenv = real_getenv
		if not ok then error(err, 0) end
	end)

	helpers.it("re-probes on demand, so the answer is not fixed at process start", function()
		local vars = { DISPLAY = ":0" }
		local real_getenv = os.getenv
		os.getenv = function(name) return vars[name] end
		local ok, err = pcall(function()
			local ds = helpers.load_module("infra.display_server")
			ds._set_for_test(nil, nil)
			helpers.assert_eq(ds.kind(), ds.X11, "starts on X11")

			-- Logging out of X11 and back in under Wayland is a supported
			-- transition. The user unit restarts on it today, which makes this
			-- belt and braces — but a value that can only be established at
			-- process start makes the requirement a property of systemd rather
			-- than of the driver.
			vars.DISPLAY = nil
			vars.WAYLAND_DISPLAY = "wayland-0"
			helpers.assert_eq(ds.kind(), ds.X11, "and does not notice on its own")
			helpers.assert_eq(ds.refresh(), ds.WAYLAND, "until asked to look again")
			helpers.assert_eq(ds.kind(), ds.WAYLAND, "after which the new answer sticks")
		end)
		os.getenv = real_getenv
		if not ok then error(err, 0) end
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ The compositor identity ==============================
-- =================================================================
-- =================================================================

helpers.describe("display_server: desktop identity", function()

	helpers.it("reports the desktop, lowercased", function()
		with_env({ WAYLAND_DISPLAY = "wayland-0", XDG_CURRENT_DESKTOP = "sway" }, function(ds)
			helpers.assert_eq(ds.desktop(), "sway", "the name comes back as given, in lower case")
			helpers.assert_eq(ds.desktop_is("sway"), true, "and the predicate matches it")
		end)
	end)

	helpers.it("normalises the casing the desktops actually use", function()
		with_env({ WAYLAND_DISPLAY = "wayland-0", XDG_CURRENT_DESKTOP = "GNOME" }, function(ds)
			-- GNOME, KDE and Hyprland all capitalise differently, and every consumer
			-- would otherwise carry its own :lower().
			helpers.assert_eq(ds.desktop(), "gnome", "GNOME writes its name in capitals")
			helpers.assert_eq(ds.desktop_is("gnome"), true, "so the predicate must fold case")
		end)
	end)

	helpers.it("falls back to DESKTOP_SESSION when XDG_CURRENT_DESKTOP is absent", function()
		with_env({ DISPLAY = ":0", DESKTOP_SESSION = "plasma" }, function(ds)
			helpers.assert_eq(ds.desktop(), "plasma", "older sessions only export the second one")
		end)
	end)

	helpers.it("answers empty rather than nil when nothing says", function()
		with_env({ DISPLAY = ":0" }, function(ds)
			helpers.assert_eq(ds.desktop(), "", "callers concatenate this into log lines")
			helpers.assert_eq(ds.desktop_is("gnome"), false, "and an unknown desktop is not any desktop")
			helpers.assert_eq(ds.desktop_is(""), false, "nor does an empty needle match everything")
		end)
	end)

end)
