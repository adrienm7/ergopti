--- adapters/input_source_switch.lua

--- ==============================================================================
--- MODULE: Input Source Switch (Linux)
--- DESCRIPTION:
--- Lists the desktop session's keyboard layouts and makes one of them active,
--- for the automatic layout switch on a pause, a resume and a quit
--- (_shared/lua/layout/pause_switch_policy.lua decides which).
---
--- FEATURES & RATIONALE:
--- 1. Two backends, one id per backend. GNOME (X11 or Wayland) keeps its input
---    sources in gsettings, an id there is "<kind>:<name>" ("xkb:fr+ergopti").
---    Another X11 session takes its layouts from setxkbmap, an id there is the
---    XKB "layout(variant)" spelling. Other Wayland compositors expose no
---    common interface to change the active layout, so they list nothing and a
---    switch is refused with the reason logged.
--- 2. GNOME switching writes the source first in `mru-sources`, which current
---    GNOME Shell releases read the active source from (desktop_activation.py
---    does the same when it activates an installed layout), then the deprecated
---    `current` index older releases still read. X11 switching moves the layout
---    to the first group: setxkbmap keeps the components it is not given.
--- 3. Every child is asynchronous and owned (adapters/owned_process): the
---    daemon owns the keyboard and never waits on gsettings. Commands run in
---    order, and a switch asked for while one runs replaces the queued one, so
---    a quick pause then resume ends on the resume layout.
--- 4. The native side is a port: tests replace `backend` and `run` and replay
---    every command without a desktop session.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.input_source_switch"

M.GNOME = "gnome"
M.X11 = "x11"

local GNOME_SCHEMA = "org.gnome.desktop.input-sources"
local GNOME_EMPTY = "@a(ss) []"





-- ======================================
-- ======================================
-- ======= 1/ Parsers and formats =======
-- ======================================
-- ======================================

--- Parses a GVariant `a(ss)` print, e.g. `[('xkb', 'fr'), ('ibus', 'mozc')]`.
--- @param text string gsettings get output.
--- @return table|nil pairs Array of { kind, name }, nil when the text is not a list.
function M.parse_gnome_sources(text)
	if type(text) ~= "string" then return nil end
	local body = text:gsub("^%s+", ""):gsub("%s+$", "")
	if body == GNOME_EMPTY then return {} end
	local inner = body:match("^%[(.*)%]$")
	if inner == nil then return nil end
	local pairs_list, rest = {}, inner
	for kind, name in inner:gmatch("%(%s*'([^'\\]*)'%s*,%s*'([^'\\]*)'%s*%)") do
		pairs_list[#pairs_list + 1] = { kind = kind, name = name }
	end
	-- Every tuple must have matched: a quoted quote or an unexpected shape is
	-- not a list this module can write back unchanged.
	rest = rest:gsub("%(%s*'[^'\\]*'%s*,%s*'[^'\\]*'%s*%)", ""):gsub("[%s,]", "")
	if rest ~= "" then return nil end
	return pairs_list
end

--- Formats pairs back into the GVariant print gsettings set accepts.
--- @param pairs_list table Array of { kind, name } parsed by parse_gnome_sources.
--- @return string
function M.format_gnome_sources(pairs_list)
	if #pairs_list == 0 then return GNOME_EMPTY end
	local items = {}
	for index, pair in ipairs(pairs_list) do
		items[index] = string.format("('%s', '%s')", pair.kind, pair.name)
	end
	return "[" .. table.concat(items, ", ") .. "]"
end

--- The id of one GNOME input source.
--- @param pair table { kind, name }
--- @return string
function M.gnome_id(pair) return pair.kind .. ":" .. pair.name end

--- Parses `setxkbmap -query`: its layout and variant lists, index-aligned.
--- @param text string
--- @return table|nil query { layouts, variants }, nil without a layout line.
function M.parse_setxkbmap_query(text)
	if type(text) ~= "string" then return nil end
	local layout_line = text:match("\nlayout:%s*([^\n]*)") or text:match("^layout:%s*([^\n]*)")
	if layout_line == nil then return nil end
	local variant_line = text:match("\nvariant:%s*([^\n]*)") or text:match("^variant:%s*([^\n]*)") or ""
	local function split(line)
		local items = {}
		-- Keeps empty slots: "ergopti,,neo" is three variants, the second none.
		for item in (line:gsub("%s+$", "") .. ","):gmatch("([^,]*),") do items[#items + 1] = item end
		return items
	end
	local layouts, variants = split(layout_line), split(variant_line)
	if #layouts == 0 or layouts[1] == "" then return nil end
	for index = 1, #layouts do
		if not layouts[index]:match("^[%w_%-]+$") then return nil end
		variants[index] = variants[index] or ""
		if variants[index] ~= "" and not variants[index]:match("^[%w_%-]+$") then return nil end
	end
	for index = #layouts + 1, #variants do variants[index] = nil end
	return { layouts = layouts, variants = variants }
end

--- The id of one X11 layout group.
--- @param layout string
--- @param variant string "" for the layout's default variant.
--- @return string
function M.x11_id(layout, variant)
	if variant == "" then return layout end
	return layout .. "(" .. variant .. ")"
end





-- =====================================
-- =====================================
-- ======= 2/ Listings and plans =======
-- =====================================
-- =====================================

--- The choices one backend reading offers, in the desktop's own order.
--- @param listing table Backend reading (see read_listing).
--- @return table Array of { id, label }.
local function choices_of(listing)
	local choices = {}
	if listing.backend == M.GNOME then
		for _, pair in ipairs(listing.sources) do
			choices[#choices + 1] = { id = M.gnome_id(pair), label = pair.name }
		end
	else
		for index, layout in ipairs(listing.query.layouts) do
			local id = M.x11_id(layout, listing.query.variants[index])
			choices[#choices + 1] = { id = id, label = id }
		end
	end
	return choices
end

--- The commands that make one listed id active, in order.
--- @param listing table Backend reading.
--- @param id string Target id.
--- @return table|nil steps Array of { program, args }.
--- @return string|nil reason Why no plan exists.
function M.plan(listing, id)
	if listing.backend == M.GNOME then
		local index
		for position, pair in ipairs(listing.sources) do
			if M.gnome_id(pair) == id then index = position; break end
		end
		if index == nil then return nil, "the input source '" .. id .. "' is not configured on this desktop" end
		local target = listing.sources[index]
		local mru = { target }
		for _, pair in ipairs(listing.mru) do
			if M.gnome_id(pair) ~= id then mru[#mru + 1] = pair end
		end
		return {
			{ program = "gsettings", args = { "set", GNOME_SCHEMA, "mru-sources", M.format_gnome_sources(mru) } },
			{ program = "gsettings", args = { "set", GNOME_SCHEMA, "current", tostring(index - 1) } },
		}
	end
	local query = listing.query
	local first
	for index, layout in ipairs(query.layouts) do
		if M.x11_id(layout, query.variants[index]) == id then first = index; break end
	end
	if first == nil then return nil, "the layout '" .. id .. "' is not configured in this X11 session" end
	local layouts, variants = { query.layouts[first] }, { query.variants[first] }
	for index, layout in ipairs(query.layouts) do
		if index ~= first then
			layouts[#layouts + 1] = layout
			variants[#variants + 1] = query.variants[index]
		end
	end
	return {
		{ program = "setxkbmap", args = { "-layout", table.concat(layouts, ","), "-variant", table.concat(variants, ",") } },
	}
end





-- ===========================
-- ===========================
-- ======= 3/ Switcher =======
-- ===========================
-- ===========================

--- Builds one switcher over a native port.
--- @param port table { backend = fn() -> "gnome"|"x11"|nil,
---   run = fn(program, args, on_done(result)) -> boolean started,
---   on_done receives { ok, stdout, error } exactly once when started }.
--- @return table switcher { refresh, choices, backend, select, is_settled, when_settled }
function M.new(port)
	if type(port) ~= "table" or type(port.backend) ~= "function" or type(port.run) ~= "function" then
		error("the input source switch needs a port with backend and run", 2)
	end
	local switcher = {}
	local choices = {}
	local busy, queued = false, nil
	local listeners = {}

	local function settle_listeners()
		if busy or queued ~= nil then return end
		local captured = listeners
		listeners = {}
		for _, listener in ipairs(captured) do
			local ok, err = pcall(listener)
			if not ok then Logger.error(LOG, "A switch settlement listener failed: %s.", tostring(err)) end
		end
	end

	--- Runs one command and hands its stdout, or nil and the reason, to on_done.
	local function run(program, args, on_done)
		local delivered = false
		local started = port.run(program, args, function(result)
			if delivered then return end
			delivered = true
			if type(result) == "table" and result.ok == true then on_done(result.stdout or "")
			else on_done(nil, program .. " failed: " .. tostring(type(result) == "table" and result.error or result)) end
		end)
		if started ~= true and not delivered then
			delivered = true
			on_done(nil, program .. " could not start")
		end
	end

	--- Reads the backend's current layouts.
	--- @param on_done function fn(listing|nil, reason|nil)
	local function read_listing(on_done)
		local backend = port.backend()
		if backend == M.GNOME then
			run("gsettings", { "get", GNOME_SCHEMA, "sources" }, function(sources_text, reason)
				if sources_text == nil then return on_done(nil, reason) end
				local sources = M.parse_gnome_sources(sources_text)
				if sources == nil then return on_done(nil, "the GNOME input sources are unreadable") end
				run("gsettings", { "get", GNOME_SCHEMA, "mru-sources" }, function(mru_text, mru_reason)
					if mru_text == nil then return on_done(nil, mru_reason) end
					local mru = M.parse_gnome_sources(mru_text)
					if mru == nil then return on_done(nil, "the GNOME recent input sources are unreadable") end
					on_done({ backend = backend, sources = sources, mru = mru })
				end)
			end)
		elseif backend == M.X11 then
			run("setxkbmap", { "-query" }, function(text, reason)
				if text == nil then return on_done(nil, reason) end
				local query = M.parse_setxkbmap_query(text)
				if query == nil then return on_done(nil, "the X11 layouts are unreadable") end
				on_done({ backend = backend, query = query })
			end)
		else
			on_done(nil, "this desktop has no supported way to change the keyboard layout")
		end
	end

	--- Runs steps in order; the first failure ends the sequence.
	local function run_steps(steps, index, on_done)
		local step = steps[index]
		if step == nil then return on_done(true) end
		run(step.program, step.args, function(output, reason)
			if output == nil then return on_done(false, reason) end
			run_steps(steps, index + 1, on_done)
		end)
	end

	--- The backend this session would switch through, nil when unsupported.
	--- @return string|nil
	function switcher.backend() return port.backend() end

	--- The layouts last read, as { id, label } copies, in the desktop's order.
	--- @return table
	function switcher.choices()
		local copy = {}
		for index, choice in ipairs(choices) do copy[index] = { id = choice.id, label = choice.label } end
		return copy
	end

	--- Re-reads the layouts. on_done(changed) runs once the reading settles;
	--- a refused reading keeps the previous list and reports changed = false.
	--- @param on_done function|nil
	function switcher.refresh(on_done)
		read_listing(function(listing, reason)
			local changed = false
			if listing then
				local fresh = choices_of(listing)
				changed = #fresh ~= #choices
				for index, choice in ipairs(fresh) do
					local old = choices[index]
					if not old or old.id ~= choice.id or old.label ~= choice.label then changed = true end
				end
				choices = fresh
			else
				Logger.warn(LOG, "Keyboard layouts not listed: %s.", tostring(reason))
			end
			if type(on_done) == "function" then on_done(changed) end
		end)
	end

	local function start(id, on_done)
		busy = true
		read_listing(function(listing, reason)
			local function done(ok, detail)
				busy = false
				local ran, err = pcall(on_done, ok, detail)
				if not ran then Logger.error(LOG, "A switch completion callback failed: %s.", tostring(err)) end
				if queued ~= nil then
					local next_request = queued
					queued = nil
					return start(next_request.id, next_request.on_done)
				end
				settle_listeners()
			end
			if listing == nil then return done(false, reason) end
			choices = choices_of(listing)
			local steps, plan_reason = M.plan(listing, id)
			if steps == nil then return done(false, plan_reason) end
			run_steps(steps, 1, done)
		end)
	end

	--- Makes one listed layout active. on_done(ok, detail) runs exactly once.
	--- @param id string A choice id.
	--- @param on_done function
	function switcher.select(id, on_done)
		if type(id) ~= "string" or id == "" then error("a layout id is required", 2) end
		if type(on_done) ~= "function" then error("a completion callback is required", 2) end
		if busy then
			if queued ~= nil then
				local superseded = queued.on_done
				queued = { id = id, on_done = on_done }
				pcall(superseded, false, "superseded by a later switch")
				return
			end
			queued = { id = id, on_done = on_done }
			return
		end
		start(id, on_done)
	end

	--- Whether no switch is running or queued.
	--- @return boolean
	function switcher.is_settled() return not busy and queued == nil end

	--- Calls listener once no switch is running or queued (at once if none is).
	--- @param listener function
	function switcher.when_settled(listener)
		if type(listener) ~= "function" then error("a settlement listener is required", 2) end
		listeners[#listeners + 1] = listener
		settle_listeners()
	end

	return switcher
end





-- ==============================
-- ==============================
-- ======= 4/ Native port =======
-- ==============================
-- ==============================

--- The port over this session: the backend from the display server, each
--- command an owned asynchronous child bounded by the shared deadline.
--- @return table port
function M.native_port()
	local DisplayServer = require("infra.display_server")
	local OwnedProcess = require("adapters.owned_process")
	local Timings = require("infra.timings")
	local timeout_ms = Timings.ms("ui", "input_source_operation_timeout_ms")
	local sequence = 0
	return {
		backend = function()
			if DisplayServer.desktop_is("gnome") then return M.GNOME end
			if DisplayServer.is_x11() then return M.X11 end
			return nil
		end,
		run = function(program, args, on_done)
			sequence = sequence + 1
			local operation = OwnedProcess.start(program, args, {
				owner = "input_source_switch:" .. sequence, timeout_ms = timeout_ms,
			}, function(result) on_done(result) end)
			return type(operation) == "table" and operation.started == true and operation.error == nil
		end,
	}
end

return M
