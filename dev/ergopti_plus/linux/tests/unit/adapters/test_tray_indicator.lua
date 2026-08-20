--- tests/unit/adapters/test_tray_indicator.lua

--- ==============================================================================
--- MODULE: Tray — the widget tree an indicator is actually given
--- DESCRIPTION:
--- What the tray backend builds, recorded from a stand-in for GTK and
--- libayatana.
---
--- WHY THIS IS THE FIRST REAL TEST OF THIS SURFACE:
--- The tray had a suite before. It asserted that setIcon did not raise, that
--- destroy was idempotent, and that getBackend returned "a valid mode string" —
--- against an implementation in which the bus name was released the instant it
--- was acquired, the menu XML was written to a file nothing read, the icon
--- resolved to "" and was assigned to an unused local, and pump() blocked on a
--- pipe from the daemon's idle callback. Every one of those tests passed. None
--- of them could distinguish a working tray from a tray that had never existed,
--- because none of them looked at what was BUILT.
---
--- The backend is replaceable wholesale here, so the assertions are on the calls
--- themselves: which widget kind per row, which label, which parent, in which
--- order. That is the only level at which "the submenu is attached to its item"
--- is a statement rather than a hope — and the previous tray lost every submenu
--- to a shape mismatch between its builder and its serialiser.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A stand-in for GTK, GObject and libayatana that records every call.
--- @return table binding, table log
local function fake_binding()
	local log = { widgets = {}, calls = {}, appends = {}, submenus = {}, signals = {} }
	local next_id = 0

	--- Creates a recorded widget handle.
	--- @param kind string
	--- @param label string|nil
	--- @return table
	local function widget(kind, label)
		next_id = next_id + 1
		local w = { id = next_id, kind = kind, label = label }
		log.widgets[#log.widgets + 1] = w
		return w
	end

	local gtk = {
		gtk_menu_new = function() return widget("menu") end,
		gtk_menu_item_new_with_label = function(label) return widget("item", label) end,
		gtk_check_menu_item_new_with_label = function(label) return widget("check", label) end,
		gtk_separator_menu_item_new = function() return widget("separator") end,
		gtk_check_menu_item_set_active = function(w, active) w.active = active end,
		gtk_menu_item_set_submenu = function(item, submenu)
			log.submenus[#log.submenus + 1] = { item = item, submenu = submenu }
			item.submenu = submenu
		end,
		gtk_menu_shell_append = function(shell, child)
			log.appends[#log.appends + 1] = { shell = shell, child = child }
			shell.children = shell.children or {}
			shell.children[#shell.children + 1] = child
		end,
		gtk_widget_set_sensitive = function(w, sensitive) w.sensitive = sensitive end,
		gtk_widget_show_all = function() log.calls[#log.calls + 1] = "show_all" end,
		gtk_init_check = function() return 1 end,
		gtk_events_pending = function()
			log.pending_polls = (log.pending_polls or 0) + 1
			-- Two events then quiet, so the drain both runs and terminates.
			return (log.pending_polls <= 2) and 1 or 0
		end,
		gtk_main_iteration_do = function(blocking)
			log.iterations = (log.iterations or 0) + 1
			log.last_blocking = blocking
			return 0
		end,
	}

	local gobject = {
		g_signal_connect_data = function(instance, signal, handler)
			log.signals[#log.signals + 1] = { widget = instance, signal = signal, handler = handler }
			return 1
		end,
	}

	local indicator = {
		app_indicator_new = function(id, icon, category)
			log.created = { id = id, icon = icon, category = category }
			return { indicator = true }
		end,
		app_indicator_set_status = function(_, status)
			log.status = status
		end,
		app_indicator_set_menu = function(_, menu) log.menu = menu end,
		app_indicator_set_icon_full = function(_, icon) log.icon = icon end,
		app_indicator_set_title = function(_, title) log.title = title end,
	}

	-- The only FFI facility the module uses is cast(), and a recorded callback
	-- is just the function itself.
	local ffi = { cast = function(_, fn) return fn end }

	return { ffi = ffi, gtk = gtk, gobject = gobject, indicator = indicator }, log
end

--- Loads the indicator with a recording backend.
--- @return table indicator, table log
local function with_fake()
	local ind = helpers.load_module("platform.tray.appindicator")
	local binding, log = fake_binding()
	ind._set_binding_for_test(binding)
	return ind, log
end

--- Finds the recorded widget for a label.
--- @param log table
--- @param label string
--- @return table|nil
local function widget_named(log, label)
	for _, w in ipairs(log.widgets) do
		if w.label == label then return w end
	end
	return nil
end





-- =================================================================
-- =================================================================
-- ======= 1/ Creating the icon ====================================
-- =================================================================
-- =================================================================

helpers.describe("tray indicator: creation", function()

	helpers.it("creates the item and makes it visible", function()
		local ind, log = with_fake()
		helpers.assert_eq(ind.create("ergopti-plus", "input-keyboard", "Ergopti+"), true,
			"creation must report success")
		helpers.assert_eq(log.created.id, "ergopti-plus",
			"the id is how a panel remembers the icon's position between sessions")
		helpers.assert_eq(log.created.icon, "input-keyboard", "and the icon it draws")
		helpers.assert_eq(log.status, 1,
			"an indicator left PASSIVE is registered and not displayed, which looks "
				.. "exactly like a tray that failed to start")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("attaches a menu immediately, because an empty one is not shown", function()
		local ind, log = with_fake()
		ind.create("ergopti-plus", "input-keyboard", "Ergopti+")
		helpers.assert_true(log.menu ~= nil,
			"most panels hide an indicator with no menu, so waiting for the first "
				.. "setMenu() means the icon appears late or not at all")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("is idempotent", function()
		local ind, log = with_fake()
		ind.create("ergopti-plus", "input-keyboard", "Ergopti+")
		local first = log.created
		ind.create("ergopti-plus", "input-keyboard", "Ergopti+")
		helpers.assert_eq(log.created, first, "a second create must not make a second icon")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("reports unavailability instead of pretending", function()
		local ind = helpers.load_module("platform.tray.appindicator")
		ind._set_binding_for_test(false)
		helpers.assert_eq(ind.is_available(), false, "no library means no tray")
		helpers.assert_eq(ind.create("x", "y", "z"), false,
			"and create must say so, so the caller can log the package to install "
				.. "rather than leaving the user with a missing icon and no reason")
		helpers.assert_eq(ind.is_live(), false, "and nothing may be marked live")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ The menu tree ========================================
-- =================================================================
-- =================================================================

helpers.describe("tray indicator: the widget tree", function()

	helpers.it("builds one widget per row, in order", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.set_menu({
			{ title = "Ergopti 3.0" },
			{ separator = true },
			{ title = "Quitter", fn = function() end },
		})

		local root = log.menu
		helpers.assert_eq(#root.children, 3, "three rows in, three widgets out")
		helpers.assert_eq(root.children[1].label, "Ergopti 3.0", "in the order given")
		helpers.assert_eq(root.children[2].kind, "separator", "a separator is its own widget kind")
		helpers.assert_eq(root.children[3].label, "Quitter", "and the last is last")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("attaches a submenu to its own item", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.set_menu({
			{ title = "Hotstrings", menu = {
				{ title = "Rolls", checked = true },
				{ title = "Autocorrection", checked = false },
			} },
		})

		-- The defect this replaces lost every submenu to a shape mismatch: the
		-- builder emitted `item.menu` and the serialiser read `item.items`, so a
		-- nested tree serialised to nothing and no test could see it.
		helpers.assert_eq(#log.submenus, 1, "exactly one submenu was attached")
		local pair = log.submenus[1]
		helpers.assert_eq(pair.item.label, "Hotstrings", "to the row that declared it")
		helpers.assert_eq(#pair.submenu.children, 2, "carrying both of its rows")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("nests to any depth", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.set_menu({
			{ title = "A", menu = { { title = "B", menu = { { title = "C" } } } } },
		})
		helpers.assert_eq(#log.submenus, 2,
			"categories contain sections; a builder that only handled one level "
				.. "would drop every section row")
		helpers.assert_true(widget_named(log, "C") ~= nil, "including the deepest one")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("uses a check item when the row carries a checked state", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.set_menu({
			{ title = "On",  checked = true },
			{ title = "Off", checked = false },
			{ title = "Plain" },
		})
		helpers.assert_eq(widget_named(log, "On").kind, "check",
			"a togglable row must be drawn as a checkbox, or the user cannot see "
				.. "which categories are active")
		helpers.assert_eq(widget_named(log, "On").active, 1, "and reflect its state")
		helpers.assert_eq(widget_named(log, "Off").active, 0, "in both directions")
		helpers.assert_eq(widget_named(log, "Plain").kind, "item",
			"a row with no checked field is an action, not an unchecked box")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("greys a disabled row instead of hiding it", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.set_menu({ { title = "Unavailable", disabled = true } })
		helpers.assert_eq(widget_named(log, "Unavailable").sensitive, 0,
			"a feature absent on this platform is shown greyed with a reason; "
				.. "hiding it makes the menus differ between drivers silently")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("connects a callback only where there is one", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.set_menu({
			{ title = "Acts", fn = function() end },
			{ title = "Inert" },
			{ title = "Parent", menu = { { title = "Child", fn = function() end } } },
		})
		helpers.assert_eq(#log.signals, 2,
			"one per actionable row; a parent row opens its submenu and must not "
				.. "also fire an action")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("runs the row's function when the signal fires", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		local fired = 0
		ind.set_menu({ { title = "Reload", fn = function() fired = fired + 1 end } })
		log.signals[1].handler()
		helpers.assert_eq(fired, 1, "the handler must reach the row's own function")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("survives a handler that raises, and keeps working afterwards", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		local after = 0
		ind.set_menu({
			{ title = "Broken", fn = function() error("boom") end },
			{ title = "Fine",   fn = function() after = after + 1 end },
		})

		-- Called directly, not through pcall: an exception escaping here IS the
		-- failure, and wrapping it would turn the assertion into "pcall reported
		-- something", which is true of every possible implementation.
		log.signals[1].handler()

		-- The claim is not that nothing crashed — it is that the tray is still a
		-- tray. An exception escaping into GTK takes the icon down and the user
		-- loses the menu for the rest of the session over one broken row.
		log.signals[2].handler()
		helpers.assert_eq(after, 1,
			"the row after the broken one must still fire")
		ind.set_menu({ { title = "Rebuilt" } })
		helpers.assert_true(widget_named(log, "Rebuilt") ~= nil,
			"and the menu must still be rebuildable")
		ind._set_binding_for_test(nil)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ Pumping ==============================================
-- =================================================================
-- =================================================================

helpers.describe("tray indicator: pump", function()

	helpers.it("never blocks", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.pump()
		-- THE defect. The previous tray read a pipe from the daemon's idle
		-- callback, so the keystroke path stalled until someone clicked the icon.
		helpers.assert_eq(log.last_blocking, 0,
			"gtk_main_iteration_do must be called with blocking = FALSE; a blocking "
				.. "drain on the idle callback stops the daemon between keystrokes")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("stops when there is nothing pending", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		local done = ind.pump()
		helpers.assert_eq(done, 2,
			"the fake has two events; a drain that kept iterating past them would "
				.. "spin the loop forever")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("is bounded even when events never stop arriving", function()
		local ind = helpers.load_module("platform.tray.appindicator")
		local binding, log = fake_binding()
		binding.gtk.gtk_events_pending = function() return 1 end
		ind._set_binding_for_test(binding)
		ind.create("id", "icon", "title")
		helpers.assert_eq(ind.pump(5), 5,
			"a busy tray must not starve the keystroke path; the budget is the bound")
		helpers.assert_true(log ~= nil, "and the recording backend was in use")
		ind._set_binding_for_test(nil)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ Teardown =============================================
-- =================================================================
-- =================================================================

helpers.describe("tray indicator: destroy", function()

	helpers.it("sets the item passive, which is what removes it", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.destroy()
		helpers.assert_eq(log.status, 0,
			"there is no destroy call in the library; dropping the reference alone "
				.. "leaves the icon on the panel until the process exits")
		helpers.assert_eq(ind.is_live(), false, "and nothing is live afterwards")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("can be created again after being destroyed", function()
		local ind, log = with_fake()
		ind.create("id", "icon", "title")
		ind.destroy()
		helpers.assert_eq(ind.create("id", "icon", "title"), true,
			"the reload path tears the tray down and rebuilds it; a destroy that "
				.. "poisoned the module would leave the menu gone until restart")
		helpers.assert_eq(log.status, 1, "and the new one is active")
		ind._set_binding_for_test(nil)
	end)

	helpers.it("is safe to call twice", function()
		local ind = with_fake()
		ind.create("id", "icon", "title")
		ind.destroy()
		ind.destroy()
		helpers.assert_eq(ind.is_live(), false, "a second teardown is a no-op")
		ind._set_binding_for_test(nil)
	end)

end)
