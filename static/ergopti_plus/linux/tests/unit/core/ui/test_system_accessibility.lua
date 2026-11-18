--- tests/unit/core/ui/test_system_accessibility.lua

--- ==============================================================================
--- MODULE: Desktop accessibility settings and the preview window (Linux)
--- DESCRIPTION:
--- The cairo-drawn preview had no text for AT-SPI and stayed translucent under
--- the desktop's high contrast. These cases pin the background reading of the
--- GNOME settings (never on the keystroke path, never before the daemon starts
--- it), the window's accessible name and role (a notification Orca speaks while
--- the screen reader is on, a tooltip otherwise), and the opaque panel high
--- contrast asks for (a11y-linux-settings).
--- ==============================================================================

local h = require("tests.helpers")

local restore_loaded = h.keep_loaded({ "core.process.adapters.shell_runner", "core.ui.adapters.system_accessibility" })

--- Loads the settings adapter over a controlled gsettings.
--- @param answers table Output per "schema key", or false for a failed read.
--- @param installed boolean|nil False when gsettings is missing.
--- @return table module, table log, function done
local function load_settings(answers, installed)
	local ShellRunner = require("core.process.adapters.shell_runner")
	local log = { spawned = {}, callbacks = {} }
	local has_command = ShellRunner.has_command
	ShellRunner.has_command = function(binary) return binary == "gsettings" and installed ~= false end
	ShellRunner._set_async_runner(function(executable, args, _options, callback)
		log.spawned[#log.spawned + 1] = executable .. " " .. table.concat(args, " ")
		log.callbacks[#log.callbacks + 1] = function()
			local answer = answers[args[2] .. " " .. args[3]]
			callback({ ok = answer ~= nil and answer ~= false, stdout = answer or "" })
		end
		return { cancel = function() end }
	end)
	package.loaded["core.ui.adapters.system_accessibility"] = nil
	local module = require("core.ui.adapters.system_accessibility")
	return module, log, function()
		ShellRunner._reset_async_runner()
		ShellRunner.has_command = has_command
	end
end

--- Delivers every pending gsettings answer.
--- @param log table
local function settle(log)
	local callbacks = log.callbacks
	log.callbacks = {}
	for _, callback in ipairs(callbacks) do callback() end
end

h.describe("desktop accessibility settings (a11y-linux-settings)", function()
	h.it("(a11y-linux-settings) reads nothing until the daemon starts it", function()
		local module, log, done = load_settings({})
		local settings = module.settings(100)
		h.assert_eq(#log.spawned, 0, "a test or an import must never start gsettings")
		h.assert_eq(settings, { screen_reader = false, high_contrast = false, reduce_motion = false })
		done()
	end)

	h.it("(a11y-linux-settings) reads the screen reader, high contrast and animations in the background", function()
		local module, log, done = load_settings({
			["org.gnome.desktop.a11y.applications screen-reader-enabled"] = "true\n",
			["org.gnome.desktop.a11y.interface high-contrast"] = "true\n",
			["org.gnome.desktop.interface enable-animations"] = "false\n",
		})
		h.assert_true(module.start(100))
		h.assert_eq(#log.spawned, 3)
		h.assert_eq(log.spawned[1], "gsettings get org.gnome.desktop.a11y.applications screen-reader-enabled")
		h.assert_eq(module.settings(100).screen_reader, false, "answered from the cache until the read lands")
		settle(log)
		h.assert_eq(module.settings(100), { screen_reader = true, high_contrast = true, reduce_motion = true })
		h.assert_eq(module.start(), false, "a second start is refused")
		done()
	end)

	h.it("(a11y-linux-drawn) the first drawn surface starts the reading, the others reuse it", function()
		local module, log, done = load_settings({})
		h.assert_true(module.ensure_started(100), "the first surface to bind GTK starts it")
		local spawned = #log.spawned
		h.assert_eq(module.ensure_started(100), false, "a second surface starts nothing")
		h.assert_eq(#log.spawned, spawned)
		done()
	end)

	h.it("(a11y-linux-settings) refreshes a stale cache, never a fresh one", function()
		local module, log, done = load_settings({})
		module.start(100)
		settle(log)
		module.settings(101)
		h.assert_eq(#log.spawned, 3, "a preview per keystroke must not start a child each time")
		module.settings(200)
		h.assert_eq(#log.spawned, 6)
		done()
	end)

	h.it("(a11y-linux-settings) a desktop without a schema reads that setting as off", function()
		local module, log, done = load_settings({
			["org.gnome.desktop.a11y.applications screen-reader-enabled"] = "true\n",
			["org.gnome.desktop.a11y.interface high-contrast"] = false,
			["org.gnome.desktop.interface enable-animations"] = "No such schema\n",
		})
		module.start(100)
		settle(log)
		h.assert_eq(module.settings(100), { screen_reader = true, high_contrast = false, reduce_motion = false })
		done()
	end)

	h.it("(a11y-linux-settings) without gsettings, every setting reads as off and nothing starts", function()
		local module, log, done = load_settings({}, false)
		h.assert_true(module.start(100))
		module.settings(200)
		h.assert_eq(#log.spawned, 0)
		h.assert_eq(module.settings(300), { screen_reader = false, high_contrast = false, reduce_motion = false })
		done()
	end)

	h.it("(a11y-linux-settings) parses only a gsettings boolean", function()
		local module, _, done = load_settings({})
		h.assert_eq(module.parse_boolean("true\n"), "true")
		h.assert_eq(module.parse_boolean(" false "), "false")
		h.assert_nil(module.parse_boolean("'true'"))
		h.assert_nil(module.parse_boolean(nil))
		done()
	end)
end)

h.describe("the preview window for AT-SPI (a11y-linux-preview)", function()
	local Renderer = h.load_module("core.ui.adapters.graphics_renderer")
	local Atk = { Role = { NOTIFICATION = "notification", TOOL_TIP = "tool-tip" } }

	--- A window double recording its accessible's role and name.
	--- @return table window, table accessible
	local function window_double()
		local accessible = {}
		function accessible:set_role(role) self.role = role end
		function accessible:set_name(name) self.name = name end
		return { get_accessible = function() return accessible end }, accessible
	end

	h.it("(a11y-linux-preview) names the window by the rows that will be sent", function()
		h.assert_eq(Renderer.accessible_text({
			{ text = "bonjour", label = "★" },
			{ text = "bonsoir", dimmed = true },
			{ text = "salut", struck = true },
			{ text = "coucou" },
		}), "bonjour ★; coucou")
	end)

	h.it("(a11y-linux-preview) a tooltip, or a notification Orca speaks while the screen reader is on", function()
		local window, accessible = window_double()
		h.assert_true(Renderer.describe_window(window, Atk, { { text = "bonjour" } }, false))
		h.assert_eq(accessible.role, "tool-tip")
		h.assert_eq(accessible.name, "bonjour")
		h.assert_true(Renderer.describe_window(window, Atk, { { text = "salut" } }, true))
		h.assert_eq(accessible.role, "notification")
		h.assert_eq(accessible.name, "salut")
	end)

	h.it("(a11y-linux-preview) without Atk, or a window that refuses, the preview still draws", function()
		local window = window_double()
		h.assert_eq(Renderer.describe_window(window, nil, {}, true), false)
		h.assert_eq(Renderer.describe_window({}, Atk, {}, true), false)
	end)

	h.it("(a11y-linux-preview) high contrast draws the panel opaque", function()
		local panel = { red = 0.1, green = 0.2, blue = 0.3, alpha = 0.85 }
		h.assert_true(rawequal(Renderer.contrast_background(panel, false), panel))
		h.assert_eq(Renderer.contrast_background(panel, true), { red = 0.1, green = 0.2, blue = 0.3, alpha = 1 })
		h.assert_eq(panel.alpha, 0.85, "the shared style is never mutated")
	end)
end)

restore_loaded()
