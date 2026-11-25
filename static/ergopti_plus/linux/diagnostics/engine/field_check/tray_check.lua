--- diagnostics/engine/field_check/tray_check.lua

--- ==============================================================================
--- MODULE: Tray Check Steps (Linux)
--- DESCRIPTION:
--- The steps of the field run's « tray » check: the live tray menu read back
--- over the session bus as a panel reads it. libayatana exports the menu as
--- com.canonical.dbusmenu; the check asks GetLayout, GetGroupProperties,
--- AboutToShow and Event of it from a child process (busctl), so the rows, their
--- order, separators, radio or checkmark kind, state, greying and labels are the
--- ones KDE Plasma or GNOME draw, not the ones the builder meant to draw.
---
--- FEATURES & RATIONALE:
--- 1. The TODO points about the tray (« Suspendre » above « Recharger », the
---    shortcut hints, the Configuration titles, the Débogage logs rows) were
---    marked not testable because no run drove the desktop's menu. The menu is
---    a D-Bus object: reading it is what the panel does.
--- 2. The regression of 2026-11-25 is replayed: a panel's hover sends
---    hovered, opened and AboutToShow to a checkable submenu row (Hotstrings,
---    Shortcuts), which libdbusmenu-gtk turned into a GTK activate that
---    unticked it. The row's exported toggle-state must not change.
--- 3. « Layout to emulate » must be one radio group with one ticked row, and a
---    click on another row must change the running emulation at once. The
---    choice is put back by the same click on the original row, and
---    config.toml is restored byte for byte if the writer reordered it, so the
---    configuration guard of the field run sees no change.
--- 4. « Suspendre » is clicked and clicked again: ticked, header changed, then
---    unticked and the header back. Nothing else is clicked: no row that opens
---    a window, changes a setting or quits.
--- 5. Pure: the bus, the clock, the expectations (labels in the user's language,
---    the shortcut hints, the problem rows the daemon holds) and the emulation
---    state are ports, so every step runs in the unit suite.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")
local Timings = require("core.timing.engine.timings")

local M = {}

M.MENU_INTERFACE = require("core.text.engine.identifiers").linux_desktop.dbusmenu_interface
M.ITEM_INTERFACE = "org.kde.StatusNotifierItem"
M.WATCHER_NAME = "org.kde.StatusNotifierWatcher"
M.WATCHER_PATH = "/StatusNotifierWatcher"
-- The path an item registered by bus name alone is served at (SNI spec).
M.DEFAULT_ITEM_PATH = "/StatusNotifierItem"

-- A clicked row rebuilds the menu on a later turn: the check reads it again
-- this many times, this far apart, before it gives up (constants.toml [adapters]).
M.SETTLE_ATTEMPTS = Timings.count("adapters", "field_tray_settle_attempts")
M.SETTLE_INTERVAL_MS = Timings.ms("adapters", "field_tray_settle_ms")

-- The panel events a hover sends to a submenu row, in the order Plasma sends them.
M.HOVER_EVENTS = { "hovered", "opened" }

-- How deep the check looks under a top-level group for a row.
local MAX_SEARCH_DEPTH = Timings.count("adapters", "field_tray_search_depth")





-- ======================================
-- ======================================
-- ======= 1/ Reading the menu ==========
-- ======================================
-- ======================================

--- The value of one busctl JSON variant ({ type, data }), or the value itself.
local function unwrap(value)
	if type(value) == "table" and type(value.type) == "string" and value.data ~= nil then return value.data end
	return value
end

--- A dbusmenu label as text: libdbusmenu marks a mnemonic with « _ » and
--- doubles a literal one, and the check compares labels on both sides through
--- this one reading.
--- @param label string|nil
--- @return string
function M.plain_label(label)
	if type(label) ~= "string" then return "" end
	return (label:gsub("__", "\1"):gsub("_", ""):gsub("\1", "_"))
end

--- Decodes one dbusmenu node of busctl's JSON ([id, {props}, [children]]).
--- Defaults follow the dbusmenu specification: a property the exporter left
--- out has its default value (enabled, visible, no toggle).
--- @param raw table
--- @return table|nil node { id, label, kind, enabled, visible, toggle_type, toggle_state, submenu, children }
function M.decode_node(raw)
	raw = unwrap(raw)
	if type(raw) ~= "table" or type(raw[1]) ~= "number" then return nil end
	local props = type(raw[2]) == "table" and raw[2] or {}
	local function prop(name) return unwrap(props[name]) end
	local node = {
		id = raw[1],
		label = M.plain_label(prop("label")),
		kind = prop("type") == "separator" and "separator" or "standard",
		enabled = prop("enabled") ~= false,
		visible = prop("visible") ~= false,
		toggle_type = type(prop("toggle-type")) == "string" and prop("toggle-type") or "",
		toggle_state = tonumber(prop("toggle-state")) or 0,
		submenu = prop("children-display") == "submenu",
		children = {},
	}
	for _, child in ipairs(type(raw[3]) == "table" and raw[3] or {}) do
		local decoded = M.decode_node(child)
		if decoded then node.children[#node.children + 1] = decoded end
	end
	return node
end

--- The rows a panel draws under a node: the visible ones, in order.
--- @param node table
--- @return table rows
function M.visible_rows(node)
	local rows = {}
	for _, child in ipairs(node and node.children or {}) do
		if child.visible then rows[#rows + 1] = child end
	end
	return rows
end

--- Whether a row's label starts with an expected text (a group label may
--- carry a count or a health dot after its caption).
local function starts_with(row, text)
	local expected = M.plain_label(text)
	return expected ~= "" and row.label:sub(1, #expected) == expected
end

--- The first visible row under a node whose label starts with a text, else
--- the first that holds it (a row may put an icon before its caption).
--- @return table|nil row, integer|nil index
function M.find_row(node, text)
	local rows, expected = M.visible_rows(node), M.plain_label(text)
	for index, row in ipairs(rows) do
		if row.kind ~= "separator" and starts_with(row, text) then return row, index end
	end
	if expected == "" then return nil end
	for index, row in ipairs(rows) do
		if row.kind ~= "separator" and row.label:find(expected, 1, true) then return row, index end
	end
	return nil
end

--- Whether a row is drawn with a check or a radio.
local function is_toggle(row)
	return row.toggle_type == "checkmark" or row.toggle_type == "radio"
end





-- ======================================
-- ======================================
-- ======= 2/ Bus calls =================
-- ======================================
-- ======================================

--- The bus calls of one check run, bound to the item it found.
--- @param ports table
--- @return table bus
local function new_bus(ports)
	local bus = { name = nil, menu = nil }

	--- Runs one busctl request; done(data|nil, why).
	function bus.request(args, done)
		local handle, why = ports.bus(args, done)
		if handle == nil then done(nil, why or "error") end
	end

	--- One method call of the menu; done(values|nil, why), values being the reply's list.
	function bus.menu_call(method, signature, args, done)
		local argv = { "call", bus.name, bus.menu, M.MENU_INTERFACE, method, signature }
		for _, value in ipairs(args) do argv[#argv + 1] = tostring(value) end
		bus.request(argv, function(reply, why)
			if type(reply) ~= "table" or type(reply.data) ~= "table" then return done(nil, why or "bad_reply") end
			done(reply.data)
		end)
	end

	--- The subtree under a row; done(node|nil, why).
	function bus.layout(parent, done)
		bus.menu_call("GetLayout", "iias", { parent, -1, 0 }, function(values, why)
			local node = values and M.decode_node(values[2]) or nil
			if node == nil then return done(nil, why or "bad_reply") end
			done(node)
		end)
	end

	--- Sends one panel event to a row; done(ok, why).
	function bus.event(id, kind, done)
		bus.menu_call("Event", "isvu", { id, kind, "i", 0, 0 }, function(values, why)
			done(values ~= nil, why)
		end)
	end

	--- Asks a row to fill its submenu, as a panel does before showing it.
	function bus.about_to_show(id, done)
		bus.menu_call("AboutToShow", "i", { id }, function(values, why)
			done(values ~= nil, why)
		end)
	end

	--- The exported toggle-state of one row; done(state|nil, why).
	function bus.toggle_state(id, done)
		bus.menu_call("GetGroupProperties", "aias", { 1, id, 1, "toggle-state" }, function(values, why)
			local entries = values and values[1]
			local entry = type(entries) == "table" and entries[1] or nil
			if type(entry) ~= "table" or entry[1] ~= id then return done(nil, why or "bad_reply") end
			local props = type(entry[2]) == "table" and entry[2] or {}
			done(tonumber(unwrap(props["toggle-state"])) or 0)
		end)
	end

	--- Opens a row's submenu and reads it; done(node|nil, why). An empty
	--- answer is read again: the rows are built while the request is served.
	function bus.open(row, done)
		local attempts = 0
		local function read()
			attempts = attempts + 1
			bus.layout(row.id, function(node, why)
				if node == nil then return done(nil, why) end
				if #M.visible_rows(node) > 0 or attempts >= M.SETTLE_ATTEMPTS then return done(node) end
				ports.after(M.SETTLE_INTERVAL_MS, read)
			end)
		end
		bus.about_to_show(row.id, function(ok, why)
			if not ok then return done(nil, why) end
			read()
		end)
	end

	return bus
end

--- Finds this daemon's item among the watcher's and its menu path.
--- @param ports table
--- @param bus table
--- @param expect table
--- @param done function done(ok, code)
local function locate(ports, bus, expect, done)
	local name, why = ports.bus_name()
	if type(name) ~= "string" then return done(false, "no_bus_name", why) end
	bus.name = name
	bus.request({ "get-property", M.WATCHER_NAME, M.WATCHER_PATH, M.WATCHER_NAME, "RegisteredStatusNotifierItems" },
		function(reply, failure)
			local items = reply and unwrap(reply)
			if type(items) ~= "table" then return done(false, failure == "exit" and "no_watcher" or (failure or "no_watcher")) end
			local paths = {}
			for _, entry in ipairs(items) do
				if type(entry) == "string" then
					if entry == name then paths[#paths + 1] = M.DEFAULT_ITEM_PATH
					elseif entry:sub(1, #name + 1) == name .. "/" then paths[#paths + 1] = entry:sub(#name + 1) end
				end
			end
			if #paths == 0 then return done(false, "not_registered") end
			local index = 0
			local function next_path()
				index = index + 1
				local path = paths[index]
				if path == nil then return done(false, "not_registered") end
				bus.request({ "get-property", name, path, M.ITEM_INTERFACE, "Id" }, function(id_reply)
					if unwrap(id_reply) ~= expect.indicator_id then return next_path() end
					bus.request({ "get-property", name, path, M.ITEM_INTERFACE, "Menu" }, function(menu_reply, menu_why)
						local menu = unwrap(menu_reply)
						if type(menu) ~= "string" or menu:sub(1, 1) ~= "/" then return done(false, menu_why or "no_menu") end
						bus.menu = menu
						done(true)
					end)
				end)
			end
			next_path()
		end)
end





-- ======================================
-- ======================================
-- ======= 3/ Read-only steps ===========
-- ======================================
-- ======================================

--- The problem rows: as many red rows as the daemon holds problems.
local function problem_rows(root, expect, report)
	local shown = 0
	for _, row in ipairs(M.visible_rows(root)) do
		if type(expect.problem_dot) == "string" and expect.problem_dot ~= "" and starts_with(row, expect.problem_dot) then
			shown = shown + 1
		end
	end
	report.step("problem_rows", shown == expect.problem_count and Report.STATE_PASS or Report.STATE_FAIL,
		shown == expect.problem_count and tostring(shown) or ("shown:" .. shown .. "+held:" .. expect.problem_count))
end

--- « Suspendre » right above « Recharger », and the chord beside each of the three.
local function script_rows(root, expect, report)
	local suspend, at_suspend = M.find_row(root, expect.suspend.base)
	local reload, at_reload = M.find_row(root, expect.reload.base)
	local quit = M.find_row(root, expect.quit.base)
	if not suspend or not reload then
		report.step("suspend_before_reload", Report.STATE_FAIL, not suspend and "no_suspend_row" or "no_reload_row")
	else
		local adjacent = at_suspend + 1 == at_reload
		report.step("suspend_before_reload", adjacent and Report.STATE_PASS or Report.STATE_FAIL,
			not adjacent and "not_adjacent" or nil)
	end
	local hinted, wrong = 0, nil
	for _, pair in ipairs({ { suspend, expect.suspend }, { reload, expect.reload }, { quit, expect.quit } }) do
		local row, want = pair[1], pair[2]
		if not row or row.label ~= M.plain_label(want.label) then wrong = wrong or want.id
		elseif want.label ~= want.base then hinted = hinted + 1 end
	end
	report.step("shortcut_hints", wrong and Report.STATE_FAIL or Report.STATE_PASS,
		wrong and ("wrong_label:" .. wrong) or tostring(hinted))
end

--- The section titles of a submenu: present, greyed, in order, each after the
--- first set apart by exactly one separator.
--- @return string|nil problem
local function titles_problem(node, titles)
	local rows = M.visible_rows(node)
	local last = 0
	for number, title in ipairs(titles) do
		local found = nil
		for index = last + 1, #rows do
			if rows[index].kind ~= "separator" and rows[index].label == M.plain_label(title) then found = index; break end
		end
		if not found then return "missing_title:" .. number end
		if rows[found].enabled then return "not_greyed:" .. number end
		if number > 1 then
			local before, earlier = rows[found - 1], rows[found - 2]
			if not before or before.kind ~= "separator" or (earlier and earlier.kind == "separator") then
				return "no_separator_before:" .. number
			end
		end
		last = found
	end
	return nil
end

--- Configuration's titles, and its reading-font row.
local function configuration_steps(bus, root, expect, report, done)
	local row = M.find_row(root, expect.configuration)
	if not row then
		report.step("configuration_titles", Report.STATE_FAIL, "no_configuration_row")
		report.step("reading_font_row", Report.STATE_SKIP, "no_configuration_row")
		return done()
	end
	bus.open(row, function(node, why)
		if not node then
			report.step("configuration_titles", Report.STATE_FAIL, why or "unreadable")
			report.step("reading_font_row", Report.STATE_SKIP, "unreadable")
			return done()
		end
		local problem = titles_problem(node, expect.configuration_titles)
		report.step("configuration_titles", problem and Report.STATE_FAIL or Report.STATE_PASS, problem
			or tostring(#expect.configuration_titles))
		local font = M.find_row(node, expect.reading_font)
		report.step("reading_font_row", font and Report.STATE_PASS or Report.STATE_FAIL, not font and "missing" or nil)
		done()
	end)
end

--- Débogage: no console row; the Logs section opens with its two switches,
--- then a separator, and « Journal détaillé » shows the stored level.
local function debug_steps(bus, root, expect, report, done)
	local row = M.find_row(root, expect.debug)
	if not row then
		report.step("debug_logs_rows", Report.STATE_FAIL, "no_debug_row")
		return done()
	end
	bus.open(row, function(node, why)
		if not node then
			report.step("debug_logs_rows", Report.STATE_FAIL, why or "unreadable")
			return done()
		end
		local rows = M.visible_rows(node)
		local problem = nil
		if M.find_row(node, expect.console) then problem = "console_row" end
		local header = nil
		for index, item in ipairs(rows) do
			if item.label == M.plain_label(expect.logs_title) then header = index; break end
		end
		if not problem and not header then problem = "no_logs_title" end
		if not problem then
			for offset, label in ipairs(expect.logs_switches) do
				local item = rows[header + offset]
				if not item or item.label ~= M.plain_label(label) or item.toggle_type ~= "checkmark" then
					problem = "wrong_switch:" .. offset
					break
				end
			end
		end
		if not problem then
			local after = rows[header + #expect.logs_switches + 1]
			if not after or after.kind ~= "separator" then problem = "no_separator" end
		end
		if not problem then
			local detailed = rows[header + 1]
			if (detailed.toggle_state == 1) ~= (expect.detailed_log == true) then problem = "detailed_state" end
		end
		report.step("debug_logs_rows", problem and Report.STATE_FAIL or Report.STATE_PASS,
			problem or (expect.detailed_log and "ticked" or "unticked"))
		done()
	end)
end





-- ======================================
-- ======================================
-- ======= 4/ Hover and clicks ==========
-- ======================================
-- ======================================

--- A panel's hover on the Hotstrings and Shortcuts rows keeps their tick.
local function hover_step(bus, root, expect, report, done)
	local rows = {}
	for _, caption in ipairs(expect.checkable_groups) do
		local row = M.find_row(root, caption)
		if row and is_toggle(row) and row.submenu then rows[#rows + 1] = row end
	end
	if #rows == 0 then
		report.step("hover_keeps_checks", Report.STATE_SKIP, "no_checkable_group")
		return done()
	end
	local index, changed = 0, nil
	local function next_row()
		index = index + 1
		local row = rows[index]
		if row == nil then
			report.step("hover_keeps_checks", changed and Report.STATE_FAIL or Report.STATE_PASS,
				changed and ("changed:" .. changed) or tostring(#rows))
			return done()
		end
		local function after_events(event)
			event = event + 1
			if event > #M.HOVER_EVENTS then
				return bus.about_to_show(row.id, function()
					bus.toggle_state(row.id, function(state)
						if state ~= row.toggle_state then changed = changed or tostring(index) end
						bus.event(row.id, "closed", function() next_row() end)
					end)
				end)
			end
			bus.event(row.id, M.HOVER_EVENTS[event], function() after_events(event) end)
		end
		after_events(0)
	end
	next_row()
end

--- Reads the menu again until a condition on the root holds; done(root|nil).
local function settle(bus, ports, holds, done)
	local attempts = 0
	local function read()
		attempts = attempts + 1
		bus.layout(0, function(root)
			if root and holds(root) then return done(root) end
			if attempts >= M.SETTLE_ATTEMPTS then return done(nil) end
			ports.after(M.SETTLE_INTERVAL_MS, read)
		end)
	end
	read()
end

--- The « Layout to emulate » row, searched under the layout group.
--- @param done function done(row|nil, children node|nil, code|nil)
local function find_emulation(bus, root, expect, done)
	local group = M.find_row(root, expect.layout_group)
	if not group then return done(nil, nil, "no_layout_group") end
	local queue = { { row = group, depth = 1 } }
	local function step()
		local item = table.remove(queue, 1)
		if item == nil then return done(nil, nil, "no_emulation_row") end
		bus.open(item.row, function(node)
			if node == nil then return step() end
			local row = M.find_row(node, expect.emulated)
			if row then
				return bus.open(row, function(choices, why)
					if choices == nil then return done(nil, nil, why or "unreadable") end
					done(row, choices)
				end)
			end
			if item.depth < MAX_SEARCH_DEPTH then
				for _, child in ipairs(M.visible_rows(node)) do
					if child.submenu then queue[#queue + 1] = { row = child, depth = item.depth + 1 } end
				end
			end
			step()
		end)
	end
	step()
end

--- Whether a row is one of the commands drawn after the choices (« Others… »).
local function is_emulation_command(row, expect)
	for _, label in ipairs(expect.emulation_commands or {}) do
		if row.label == M.plain_label(label) then return true end
	end
	return false
end

--- The ticked rows of a choice group, and whether every choice is a radio.
--- The commands after the choices (expect.emulation_commands) are no choice:
--- since the menu decision of 2026-11-25 the group is « None », the quick
--- choices and « Others… », and counting that command row as a choice failed
--- every run as not_radio (Arch Linux field report, 2026-11-25).
local function radio_state(choices, expect)
	local ticked, all_radio, rows = {}, true, {}
	for _, row in ipairs(M.visible_rows(choices)) do
		if row.kind ~= "separator" and not is_emulation_command(row, expect) then
			rows[#rows + 1] = row
			if row.toggle_type ~= "radio" then all_radio = false end
			if row.toggle_state == 1 then ticked[#ticked + 1] = row end
		end
	end
	return ticked, all_radio, rows
end

--- Clicks a choice by label and waits until the menu ticks it; done(ok).
local function choose(bus, ports, expect, label, done)
	bus.layout(0, function(root)
		if not root then return done(false) end
		find_emulation(bus, root, expect, function(_, choices)
			local target = nil
			for _, row in ipairs(choices and M.visible_rows(choices) or {}) do
				if row.label == label then target = row end
			end
			if not target then return done(false) end
			bus.event(target.id, "clicked", function(sent)
				if not sent then return done(false) end
				local attempts = 0
				local function confirm()
					attempts = attempts + 1
					bus.layout(0, function(fresh)
						if not fresh then return done(false) end
						find_emulation(bus, fresh, expect, function(_, now)
							local ticked = now and radio_state(now, expect) or {}
							if #ticked == 1 and ticked[1].label == label then return done(true) end
							if attempts >= M.SETTLE_ATTEMPTS then return done(false) end
							ports.after(M.SETTLE_INTERVAL_MS, confirm)
						end)
					end)
				end
				confirm()
			end)
		end)
	end)
end

--- One radio group with one tick, a live change, then the choice put back.
local function emulation_steps(bus, ports, root, expect, report, done)
	find_emulation(bus, root, expect, function(row, choices, code)
		if not row then
			report.step("emulation_radio", Report.STATE_FAIL, code)
			report.step("emulation_live", Report.STATE_SKIP, code)
			return done()
		end
		local ticked, all_radio, rows = radio_state(choices, expect)
		local radio_ok = all_radio and #ticked == 1
		report.step("emulation_radio", radio_ok and Report.STATE_PASS or Report.STATE_FAIL,
			not all_radio and "not_radio" or (#ticked ~= 1 and ("ticked:" .. #ticked)) or tostring(#rows))
		if not radio_ok or #rows < 2 then
			report.step("emulation_live", Report.STATE_SKIP, not radio_ok and "no_single_choice" or "one_choice")
			return done()
		end
		local original = ticked[1].label
		local target = nil
		for _, candidate in ipairs(rows) do
			if candidate.label ~= original and candidate.enabled then target = candidate.label; break end
		end
		if not target then
			report.step("emulation_live", Report.STATE_SKIP, "one_choice")
			return done()
		end
		local before, snapshot = ports.emulation_state(), ports.config_snapshot()
		choose(bus, ports, expect, target, function(moved)
			local during = ports.emulation_state()
			choose(bus, ports, expect, original, function(back)
				local after = ports.emulation_state()
				local restored = ports.config_restore(snapshot)
				local live = moved and during ~= before
				local value = not moved and "not_ticked" or (during == before and "not_applied")
					or (not back or after ~= before) and "not_put_back" or (restored ~= true and "config_not_restored")
					or nil
				report.step("emulation_live", (live and value == nil) and Report.STATE_PASS or Report.STATE_FAIL, value)
				done()
			end)
		end)
	end)
end

--- The labels of the root rows but « Suspendre »: the header row is the one
--- a pause changes, wherever the problem rows put it.
local function header_signature(root, expect)
	local labels = {}
	for _, row in ipairs(M.visible_rows(root)) do
		if row.kind ~= "separator" and not starts_with(row, expect.suspend.base) then labels[#labels + 1] = row.label end
	end
	return table.concat(labels, "\n")
end

--- « Suspendre » ticks and changes the header, then unticks and gives it back.
local function suspend_step(bus, ports, root, expect, report, done)
	local row = M.find_row(root, expect.suspend.base)
	if not row then
		report.step("suspend_toggle", Report.STATE_SKIP, "no_suspend_row")
		return done()
	end
	local header = header_signature(root, expect)
	local initial = row.toggle_state
	local function click(want, then_fn)
		bus.layout(0, function(fresh)
			local current = fresh and M.find_row(fresh, expect.suspend.base)
			if not current then return then_fn(nil) end
			bus.event(current.id, "clicked", function()
				settle(bus, ports, function(now)
					local suspend = M.find_row(now, expect.suspend.base)
					return suspend ~= nil and suspend.toggle_state == want
				end, then_fn)
			end)
		end)
	end
	local paused_want = initial == 1 and 0 or 1
	click(paused_want, function(paused)
		local changed_header = paused ~= nil and header_signature(paused, expect) ~= header
		click(initial, function(back)
			local same_header = back ~= nil and header_signature(back, expect) == header
			local value = paused == nil and "not_ticked" or (not changed_header and "header_unchanged")
				or (back == nil and "not_unticked") or (not same_header and "header_not_back") or nil
			report.step("suspend_toggle", value and Report.STATE_FAIL or Report.STATE_PASS, value)
			done()
		end)
	end)
end





-- ======================================
-- ======================================
-- ======= 5/ Run =======================
-- ======================================
-- ======================================

--- Runs the steps, then calls finish once.
--- @param ports table {
---   bus_name = function() -> string|nil, why  this process's unique name on the session bus,
---   bus = function(args, done(data|nil, why)) -> handle|nil, why: one busctl request
---     (args after `busctl --user --json=short`), done once with the decoded reply,
---     or nil and "not_found" (no busctl), "exit", "timeout", "bad_reply" or "error",
---   after = function(ms, fn) -> handle   a timer,
---   expect = function() -> table         the labels and states the menu must show,
---   emulation_state = function() -> string  the running emulation ("none" or its id),
---   config_snapshot = function() -> table   config.toml as it is,
---   config_restore = function(snapshot) -> boolean  puts those bytes back when they changed }
--- @param report table field check report.
--- @param finish function
function M.run(ports, report, finish)
	local expect = ports.expect()
	local bus = new_bus(ports)
	locate(ports, bus, expect, function(found, code)
		if not found then
			if code == "not_found" then
				report.not_run("no_busctl")
				report.step("tray_exported", Report.STATE_SKIP, "no_busctl")
			else
				report.step("tray_exported", Report.STATE_FAIL, code)
			end
			return finish()
		end
		report.step("tray_exported", Report.STATE_PASS)
		bus.layout(0, function(root, why)
			if not root then
				report.step("tray_layout", Report.STATE_FAIL, why or "unreadable")
				return finish()
			end
			report.step("tray_layout", Report.STATE_INFO, tostring(#M.visible_rows(root)))
			problem_rows(root, expect, report)
			script_rows(root, expect, report)
			hover_step(bus, root, expect, report, function()
				configuration_steps(bus, root, expect, report, function()
					debug_steps(bus, root, expect, report, function()
						bus.layout(0, function(fresh)
							emulation_steps(bus, ports, fresh or root, expect, report, function()
								bus.layout(0, function(latest)
									suspend_step(bus, ports, latest or root, expect, report, finish)
								end)
							end)
						end)
					end)
				end)
			end)
		end)
	end)
end

return M
