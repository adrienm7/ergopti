--- adapters/input_source_switch.lua

--- ==============================================================================
--- MODULE: Input Source Switch (Linux)
--- DESCRIPTION:
--- Lists the desktop session's keyboard layouts and makes one of them active,
--- for the automatic layout switch on a pause, a resume and a quit
--- (_shared/lua/layout/pause_switch_policy.lua decides which).
---
--- FEATURES & RATIONALE:
--- 1. Three backends, one id per backend. GNOME (X11 or Wayland) keeps its
---    input sources in gsettings, an id there is "<kind>:<name>"
---    ("xkb:fr+ergopti"). KDE Plasma (X11 or Wayland) owns its layouts in the
---    keyboard daemon (D-Bus org.kde.keyboard /Layouts, Plasma 5.21 and later),
---    and another X11 session takes them from setxkbmap; an id there is the XKB
---    "layout(variant)" spelling. The KDE daemon's reply names no variant (its
---    middle field is the user's display label: empty on Wayland, the short
---    name on X11 when unset), so the variants come from kxkbrc, the setting
---    both Plasma session types read: the same layout keeps one id on both. Other Wayland compositors expose no common
---    interface to change the active layout, so they list nothing and a switch
---    is refused with the reason logged.
--- 2. GNOME Shell (checked on 46) reads `mru-sources` only when it starts and
---    ignores `current`: on a `sources` change it keeps its in-memory recent
---    list and activates its first entry. Switching therefore writes `sources`
---    as the target alone, which the shell must activate, waits for the shell
---    to read it, then writes the user's list back with the target first (as
---    desktop_activation.py places an installed layout) and `mru-sources` for
---    the next start. Writes the shell coalesces end on no switch, never on
---    another layout. KDE switching asks the daemon
---    for the layout's index (setLayout), which answers whether it switched.
---    X11 switching moves the layout to the first group: setxkbmap keeps the
---    components it is not given.
--- 5. Each choice says whether it is active: GNOME's first recent source, the
---    KDE daemon's current index. X11 reports none: the active group is not
---    the first one after a group hotkey, and no tick beats a wrong one.
--- 3. Every child is asynchronous and owned (adapters/owned_process): the
---    daemon owns the keyboard and never waits on gsettings. Commands run in
---    order, and a switch asked for while one runs replaces the queued one, so
---    a quick pause then resume ends on the resume layout.
--- 4. The native side is a port: tests replace `backend` and `run` and replay
---    every command without a desktop session.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TextUtils = require("text_utils")

local LOG = "adapters.input_source_switch"

M.GNOME = "gnome"
M.KDE = "kde"
M.X11 = "x11"

local GNOME_SCHEMA = "org.gnome.desktop.input-sources"
local GNOME_EMPTY = "@a(ss) []"
-- The Plasma keyboard daemon (kded keyboard module, Plasma 5.21 and later).
local KDE_CALL = { "call", "--session", "--dest", "org.kde.keyboard", "--object-path", "/Layouts", "--method" }
local KDE_INTERFACE = "org.kde.KeyboardLayouts."





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
	local body = TextUtils.trim(text)
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

--- Reads one GVariant string literal at pos: '…' or "…", backslash escapes.
--- @param text string
--- @param pos integer Index of the opening quote.
--- @return string|nil value
--- @return integer|nil next Index after the closing quote.
local function read_gvariant_string(text, pos)
	local quote = text:sub(pos, pos)
	if quote ~= "'" and quote ~= '"' then return nil end
	local parts, index = {}, pos + 1
	while index <= #text do
		local char = text:sub(index, index)
		if char == "\\" then
			local escaped = text:sub(index + 1, index + 1)
			if escaped == "" then return nil end
			parts[#parts + 1] = escaped
			index = index + 2
		elseif char == quote then
			return table.concat(parts), index + 1
		else
			parts[#parts + 1] = char
			index = index + 1
		end
	end
	return nil
end

--- Parses the KDE daemon's getLayoutsList reply, e.g.
--- `([('fr', '', 'French (BEPO)'), ('us', 'us', 'English (US)')],)`: the
--- layout, the user's display label (Plasma's LayoutNames.displayName, the
--- short name on X11 when unset) and the description.
--- @param text string gdbus call output.
--- @return table|nil layouts Array of { layout, label, name }, nil when unreadable.
function M.parse_kde_layouts(text)
	if type(text) ~= "string" then return nil end
	local body = TextUtils.trim(text):match("^%(%[(.*)%],%)$")
	if body == nil then return nil end
	local layouts, pos = {}, 1
	while true do
		pos = body:find("%S", pos)
		if pos == nil then break end
		if body:sub(pos, pos) ~= "(" then return nil end
		local fields = {}
		pos = pos + 1
		for field = 1, 3 do
			pos = body:find("%S", pos)
			if pos == nil then return nil end
			local value, after = read_gvariant_string(body, pos)
			if value == nil then return nil end
			fields[field] = value
			pos = body:find("%S", after)
			if pos == nil then return nil end
			local separator = body:sub(pos, pos)
			if field < 3 and separator ~= "," then return nil end
			if field == 3 and separator ~= ")" then return nil end
			pos = pos + 1
		end
		-- The id is written back to the daemon by index only, but it names an
		-- XKB layout: refuse a name outside XKB's alphabet like setxkbmap's.
		if not fields[1]:match("^[%w_%-]+$") then return nil end
		layouts[#layouts + 1] = { layout = fields[1], label = fields[2], name = fields[3] }
		pos = body:find("%S", pos)
		if pos == nil then break end
		if body:sub(pos, pos) ~= "," then return nil end
		pos = pos + 1
	end
	return layouts
end

--- Reads the [Layout] LayoutList and VariantList of kxkbrc.
--- @param text string|nil The file's content, nil when it does not exist.
--- @return table|nil config { layouts, variants } index-aligned, or nil when no
---   layout list is configured (the daemon then serves the session default).
--- @return string|nil reason Why a present file cannot be used.
function M.parse_kxkbrc(text)
	if text == nil then return nil end
	if type(text) ~= "string" then return nil, "kxkbrc is unreadable" end
	local group, values = nil, {}
	for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local name = line:match("^%s*%[([^%]]+)%]%s*$")
		if name then
			group = name
		elseif group == "Layout" then
			local key, value = line:match("^%s*([%w]+)%s*=%s*(.-)%s*$")
			if key then values[key] = value end
		end
	end
	if values.LayoutList == nil or values.LayoutList == "" then return nil end
	local function split(list)
		local items = {}
		for item in ((list or "") .. ","):gmatch("([^,]*),") do items[#items + 1] = item end
		return items
	end
	local layouts, variants = split(values.LayoutList), split(values.VariantList)
	for index, layout in ipairs(layouts) do
		local variant = variants[index] or ""
		if not layout:match("^[%w_%-]+$") or (variant ~= "" and not variant:match("^[%w_%-]+$")) then
			return nil, "kxkbrc names a layout outside XKB's alphabet"
		end
		variants[index] = variant
	end
	if #variants > #layouts then return nil, "kxkbrc lists more variants than layouts" end
	return { layouts = layouts, variants = variants }
end

--- The variant of each daemon layout, from kxkbrc.
--- @param layouts table parse_kde_layouts result.
--- @param config table|nil parse_kxkbrc result.
--- @return table|nil variants Index-aligned with layouts.
--- @return string|nil reason
function M.kde_variants(layouts, config)
	local variants = {}
	if config == nil then
		for index in ipairs(layouts) do variants[index] = "" end
		return variants
	end
	if #config.layouts ~= #layouts then
		return nil, "the KDE keyboard daemon and kxkbrc list different layouts"
	end
	for index, entry in ipairs(layouts) do
		if config.layouts[index] ~= entry.layout then
			return nil, "the KDE keyboard daemon and kxkbrc list different layouts"
		end
		variants[index] = config.variants[index]
	end
	return variants
end

--- Parses the KDE daemon's getLayout reply, `(uint32 1,)`.
--- @param text string
--- @return integer|nil index Zero-based.
function M.parse_kde_index(text)
	if type(text) ~= "string" then return nil end
	local digits = TextUtils.trim(text):match("^%(uint32 (%d+),%)$")
	return digits and tonumber(digits) or nil
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
		local recent = listing.mru[1] and M.gnome_id(listing.mru[1])
		for _, pair in ipairs(listing.sources) do
			local id = M.gnome_id(pair)
			choices[#choices + 1] = { id = id, label = pair.name, active = id == recent }
		end
	elseif listing.backend == M.KDE then
		for index, entry in ipairs(listing.layouts) do
			local id = M.x11_id(entry.layout, listing.variants[index])
			local label = entry.name ~= "" and entry.name or id
			choices[#choices + 1] = { id = id, label = label, active = index - 1 == listing.current }
		end
	else
		for index, layout in ipairs(listing.query.layouts) do
			local id = M.x11_id(layout, listing.query.variants[index])
			choices[#choices + 1] = { id = id, label = id, active = false }
		end
	end
	return choices
end

--- The commands that make one listed id active, in order.
--- @param listing table Backend reading.
--- @param id string Target id.
--- @return table|nil steps Array of { program, args, expect?, undo? }: a step with
---   `expect` fails unless its trimmed output is exactly that text; a step's
---   `undo` { program, args } runs when a later step fails.
--- @return string|nil reason Why no plan exists.
function M.plan(listing, id)
	if listing.backend == M.GNOME then
		local index
		for position, pair in ipairs(listing.sources) do
			if M.gnome_id(pair) == id then index = position; break end
		end
		if index == nil then return nil, "the input source '" .. id .. "' is not configured on this desktop" end
		local target = listing.sources[index]
		local sources, mru = { target }, { target }
		for _, pair in ipairs(listing.sources) do
			if M.gnome_id(pair) ~= id then sources[#sources + 1] = pair end
		end
		for _, pair in ipairs(listing.mru) do
			if M.gnome_id(pair) ~= id then mru[#mru + 1] = pair end
		end
		local settle = string.format("%.3f", require("infra.timings").ms("ui", "gnome_input_source_settle_ms") / 1000)
		return {
			{ program = "gsettings", args = { "set", GNOME_SCHEMA, "sources", M.format_gnome_sources({ target }) },
				undo = { program = "gsettings",
					args = { "set", GNOME_SCHEMA, "sources", M.format_gnome_sources(listing.sources) } } },
			{ program = "sleep", args = { settle } },
			{ program = "gsettings", args = { "set", GNOME_SCHEMA, "sources", M.format_gnome_sources(sources) } },
			{ program = "gsettings", args = { "set", GNOME_SCHEMA, "mru-sources", M.format_gnome_sources(mru) } },
		}
	end
	if listing.backend == M.KDE then
		for index, entry in ipairs(listing.layouts) do
			if M.x11_id(entry.layout, listing.variants[index]) == id then
				local args = {}
				for position, arg in ipairs(KDE_CALL) do args[position] = arg end
				args[#args + 1] = KDE_INTERFACE .. "setLayout"
				args[#args + 1] = tostring(index - 1)
				return { { program = "gdbus", args = args, expect = "(true,)" } }
			end
		end
		return nil, "the layout '" .. id .. "' is not configured in this KDE session"
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
--- @param port table { backend = fn() -> "gnome"|"kde"|"x11"|nil,
---   kde_config = fn() -> kxkbrc text, or nil when the file does not exist,
---   run = fn(program, args, on_done(result)) -> boolean started,
---   on_done receives { ok, stdout, error } exactly once when started }.
--- @return table switcher { refresh, choices, backend, select, is_settled, when_settled }
function M.new(port)
	if type(port) ~= "table" or type(port.backend) ~= "function" or type(port.run) ~= "function"
		or type(port.kde_config) ~= "function" then
		error("the input source switch needs a port with backend, run and kde_config", 2)
	end
	local switcher = {}
	local choices = {}
	local listing_epoch = 0
	local refreshing = 0
	local refresh_waiters = {}
	local draining_refreshes = 0
	local busy, queued = false, nil
	local listeners, delivering = {}, false

	local function settle_listeners()
		if delivering then return end
		delivering = true
		while not busy and queued == nil and refreshing == 0 and draining_refreshes == 0
			and #refresh_waiters == 0 and #listeners > 0 do
			local listener = table.remove(listeners, 1)
			local ok, err = pcall(listener)
			if not ok then Logger.error(LOG, "A switch settlement listener failed: %s.", tostring(err)) end
		end
		delivering = false
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
		elseif backend == M.KDE then
			local list_args, index_args = {}, {}
			for position, arg in ipairs(KDE_CALL) do list_args[position], index_args[position] = arg, arg end
			list_args[#list_args + 1] = KDE_INTERFACE .. "getLayoutsList"
			index_args[#index_args + 1] = KDE_INTERFACE .. "getLayout"
			run("gdbus", list_args, function(list_text, reason)
				if list_text == nil then return on_done(nil, reason) end
				local layouts = M.parse_kde_layouts(list_text)
				if layouts == nil then return on_done(nil, "the KDE keyboard layouts are unreadable") end
				local config, config_reason = M.parse_kxkbrc(port.kde_config())
				if config_reason then return on_done(nil, config_reason) end
				local variants, variants_reason = M.kde_variants(layouts, config)
				if variants == nil then return on_done(nil, variants_reason) end
				run("gdbus", index_args, function(index_text, index_reason)
					if index_text == nil then return on_done(nil, index_reason) end
					local current = M.parse_kde_index(index_text)
					if current == nil then return on_done(nil, "the active KDE keyboard layout is unreadable") end
					on_done({ backend = backend, layouts = layouts, variants = variants, current = current })
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
	--- A step's `undo` runs when a later step fails, newest first, so a
	--- partial switch puts back what it changed; the failure names the undo's
	--- outcome too.
	local function run_steps(steps, index, on_done, undos)
		undos = undos or {}
		local step = steps[index]
		if step == nil then return on_done(true) end
		local function fail(reason)
			local pending = {}
			for position = #undos, 1, -1 do pending[#pending + 1] = undos[position] end
			if #pending == 0 then return on_done(false, reason) end
			run_steps(pending, 1, function(undone, undo_reason)
				on_done(false, reason .. (undone and " (the earlier change was put back)"
					or ("; putting the earlier change back failed: " .. tostring(undo_reason))))
			end)
		end
		run(step.program, step.args, function(output, reason)
			if output == nil then return fail(reason) end
			if step.expect ~= nil and TextUtils.trim(output) ~= step.expect then
				return fail(step.program .. " refused the switch: " .. TextUtils.trim(output))
			end
			if step.undo ~= nil then undos[#undos + 1] = step.undo end
			run_steps(steps, index + 1, on_done, undos)
		end)
	end

	--- The backend this session would switch through, nil when unsupported.
	--- @return string|nil
	function switcher.backend() return port.backend() end

	--- The layouts last read, as { id, label, active } copies, in the desktop's order.
	--- @return table
	function switcher.choices()
		local copy = {}
		for index, choice in ipairs(choices) do
			copy[index] = { id = choice.id, label = choice.label, active = choice.active == true }
		end
		return copy
	end

	--- Re-reads the layouts. on_done(changed) runs once the reading settles;
	--- a refused reading keeps the previous list and reports changed = false.
	--- @param on_done function|nil
	function switcher.refresh(on_done)
		-- A menu repaint must not supersede a pause/quit switch already reading
		-- the desktop. Read the choices after the queued switches have finished.
		if busy then
			refresh_waiters[#refresh_waiters + 1] = type(on_done) == "function" and on_done or false
			return
		end
		listing_epoch = listing_epoch + 1
		local epoch = listing_epoch
		refreshing = refreshing + 1
		read_listing(function(listing, reason)
			local changed = false
			if epoch ~= listing_epoch then
				listing = nil
			elseif listing then
				local fresh = choices_of(listing)
				changed = #fresh ~= #choices
				for index, choice in ipairs(fresh) do
					local old = choices[index]
					if not old or old.id ~= choice.id or old.label ~= choice.label or old.active ~= choice.active then
						changed = true
					end
				end
				choices = fresh
			elseif epoch == listing_epoch then
				Logger.warn(LOG, "Keyboard layouts not listed: %s.", tostring(reason))
			end
			if type(on_done) == "function" then
				local called, err = pcall(on_done, changed)
				if not called then Logger.error(LOG, "A layout refresh callback failed: %s.", tostring(err)) end
			end
			refreshing = refreshing - 1
			settle_listeners()
		end)
	end

	local function start(id, on_done)
		busy = true
		listing_epoch = listing_epoch + 1
		local epoch = listing_epoch
		read_listing(function(listing, reason)
			local function done(ok, detail)
				-- Keep the slot occupied during delivery: a reentrant selection must
				-- replace the queued request, not start alongside it.
				local ran, err = pcall(on_done, ok, detail)
				if not ran then Logger.error(LOG, "A switch completion callback failed: %s.", tostring(err)) end
				busy = false
				if queued ~= nil then
					local next_request = queued
					queued = nil
					return start(next_request.id, next_request.on_done)
				end
				local waiting = refresh_waiters
				refresh_waiters = {}
				draining_refreshes = draining_refreshes + 1
				for _, callback in ipairs(waiting) do switcher.refresh(callback or nil) end
				draining_refreshes = draining_refreshes - 1
				settle_listeners()
			end
			if listing == nil then return done(false, reason) end
			if epoch ~= listing_epoch then return done(false, "the keyboard layout listing was superseded") end
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

	--- Whether no switch or layout-listing operation remains in flight.
	--- @return boolean
	function switcher.is_settled()
		return not busy and queued == nil and refreshing == 0 and draining_refreshes == 0 and #refresh_waiters == 0
	end

	--- Calls listener once switches and layout listings have settled.
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
		kde_config = function()
			local base = os.getenv("XDG_CONFIG_HOME")
			if base == nil or base == "" then base = (os.getenv("HOME") or "") .. "/.config" end
			local handle = io.open(base .. "/kxkbrc", "rb")
			if handle == nil then return nil end
			local text = handle:read("*a")
			handle:close()
			return text or false
		end,
		backend = function()
			if DisplayServer.desktop_is("gnome") then return M.GNOME end
			if DisplayServer.desktop_is("kde") then return M.KDE end
			if DisplayServer.is_x11() then return M.X11 end
			return nil
		end,
		run = function(program, args, on_done)
			sequence = sequence + 1
			local owner = "input_source_switch:" .. sequence
			local needs_group = program == "setxkbmap" and args[1] == "-layout"
			local delivered = false
			local phase = "layout"
			local function finish(result)
				if delivered then return end
				delivered = true
				on_done(result)
			end
			local operation = OwnedProcess.start(program, args, {
				owner = owner, timeout_ms = timeout_ms,
			}, function(result)
				if phase ~= "layout" then return end
				phase = "group"
				if not needs_group or type(result) ~= "table" or result.ok ~= true then return finish(result) end
				local loaded, uv = pcall(require, "luv")
				if not loaded or type(uv.os_getpid) ~= "function" or type(uv.exepath) ~= "function" then
					return finish({ ok = false, error = "X11 group worker unavailable" })
				end
				local prepared, executable, arguments = pcall(function()
					local Paths = require("infra.paths")
					local Runtime = require("_generated.native_runtime")
					assert(type(Runtime.x11) == "string" and Runtime.x11:match("^[%w_+%.%-]+$"), "invalid X11 soname")
					return uv.exepath(), {
						Paths.driver_root() .. "/adapters/input_source_group_worker.lua",
						string.format("%.0f", uv.os_getpid()), Runtime.x11,
					}
				end)
				if not prepared then return finish({ ok = false, error = "X11 group worker could not start" }) end
				local child = OwnedProcess.start(executable, arguments,
					{ owner = owner .. ":group", timeout_ms = timeout_ms }, finish)
				-- A returned owner may still owe pipe/timer retirement even if its
				-- dispatch was refused. Only a missing owner completes here.
				if type(child) ~= "table" then
					finish({ ok = false, error = "X11 group worker could not start" })
				end
			end)
			-- Even refused dispatch can own pipes or timers until the operation's
			-- completion callback acknowledges their physical retirement.
			return type(operation) == "table"
		end,
	}
end

return M
