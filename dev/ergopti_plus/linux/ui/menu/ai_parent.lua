--- ui/menu/ai_parent.lua

--- ==============================================================================
--- MODULE: Linux AI Parent Source Admission
--- DESCRIPTION:
--- Binds the two AI parents to actual shared declarations around their finished
--- native children, preserving the context, source and callback cohort.
--- ==============================================================================

local M = {}

local declarations = {
	llm = { frame = "llm_native_parent_linux", id = "llm_parent_linux", child = "llm_menu" },
	agent = { frame = "agent_native_parent", id = "agent_parent_linux", child = "agent_menu" },
}

--- Captures plain source records and arrays without invoking metamethods.
--- @param value table Source or completed child.
--- @param seen table|nil Objects already captured.
--- @return table|nil snapshot
local function capture(value, seen, shallow)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local snapshot = { object = value, fields = {}, children = {} }
	seen[value] = snapshot
	for key, field in next, value do
		snapshot.fields[key] = field
		if type(field) == "table" and not shallow then
			local child = capture(field, seen)
			if not child then return nil end
			snapshot.children[key] = child
		end
	end
	return snapshot
end

--- Rechecks direct source values and retained native callback identities.
--- @param snapshot table
--- @param seen table|nil Captures already checked.
--- @return boolean
local function unchanged(snapshot, seen)
	local value = snapshot.object
	if getmetatable(value) ~= nil then return false end
	seen = seen or {}
	if seen[snapshot] then return true end
	seen[snapshot] = true
	for key, field in next, value do
		if not rawequal(field, rawget(snapshot.fields, key)) then return false end
	end
	for key, field in next, snapshot.fields do
		if not rawequal(field, rawget(value, key)) then return false end
		if snapshot.children[key] and not unchanged(snapshot.children[key], seen) then return false end
	end
	return true
end

--- Resolves only direct methods or a plain inherited renderer table, without foreign lookup.
--- @param renderer table Actual shared renderer or a facade retaining its genuine owner.
--- @param name string Method name.
--- @return any method
local function api_method(renderer, name)
	local direct = rawget(renderer, name)
	if direct ~= nil then return direct end
	local meta = getmetatable(renderer)
	if type(meta) ~= "table" or getmetatable(meta) ~= nil then return nil end
	for key in next, meta do if key ~= "__index" then return nil end end
	local owner = rawget(meta, "__index")
	if type(owner) ~= "table" or getmetatable(owner) ~= nil then return nil end
	return rawget(owner, name)
end

--- Captures the exact direct renderer facade and its plain inherited owner.
--- @param renderer table
--- @return table|nil snapshot
local function capture_api(renderer)
	local meta = getmetatable(renderer)
	local owner
	if meta ~= nil then
		if type(meta) ~= "table" or getmetatable(meta) ~= nil then return nil end
		for key in next, meta do if key ~= "__index" then return nil end end
		owner = rawget(meta, "__index")
		if type(owner) ~= "table" or getmetatable(owner) ~= nil then return nil end
	end
	local fields = {}
	for key, field in next, renderer do fields[key] = field end
	return { object = renderer, fields = fields, meta = meta,
		meta_snapshot = meta and capture(meta, nil, true),
		owner_snapshot = owner and capture(owner, nil, true) }
end

--- Rechecks facade fields, metatable and inherited method owners by raw identity.
--- @param snapshot table
--- @return boolean
local function unchanged_api(snapshot)
	if not rawequal(getmetatable(snapshot.object), snapshot.meta) then return false end
	for key, field in next, snapshot.object do
		if not rawequal(field, rawget(snapshot.fields, key)) then return false end
	end
	for key, field in next, snapshot.fields do
		if not rawequal(field, rawget(snapshot.object, key)) then return false end
	end
	return (not snapshot.meta_snapshot or unchanged(snapshot.meta_snapshot))
		and (not snapshot.owner_snapshot or unchanged(snapshot.owner_snapshot))
end

--- Requires a nonempty dense array of direct records.
--- @param value any
--- @return boolean
local function rows(value)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local count, maximum = 0, 0
	for index, row in next, value do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1
			or type(row) ~= "table" or getmetatable(row) ~= nil then return false end
		count, maximum = count + 1, math.max(maximum, index)
	end
	return count > 0 and count == maximum
end

--- Reads native state without claiming an unreadable value is enabled.
--- @param ticket table Captured native owners.
--- @return boolean|nil
local function enabled(ticket)
	if ticket.kind == "llm" then
		local getter = ticket.native and rawget(ticket.native, "is_enabled")
		if type(getter) ~= "function" then return nil end
		local ok, value = pcall(getter)
		if ok and type(value) == "boolean" then return value end
		return nil
	end
	local getter = ticket.settings and rawget(ticket.settings, "get_mode")
	if type(getter) ~= "function" then return nil end
	local ok, value = pcall(getter)
	if not ok or (value ~= "off" and value ~= "action" and value ~= "auto") then return nil end
	return value ~= "off"
end

--- Checks the current native pause reader without changing its owner.
--- @param ctx table Actual menu context.
--- @return boolean
local function unpaused(ctx)
	if rawget(ctx, "paused") == true then return false end
	local getter = rawget(ctx, "is_paused")
	if getter == nil then return true end
	if type(getter) ~= "function" then return false end
	local ok, value = pcall(getter)
	return ok and value == false
end

--- Captures the genuine source before either AI child starts building.
--- @param renderer table|nil Actual shared renderer binding.
--- @param kind string "llm" or "agent".
--- @param ctx table Actual menu context.
--- @param settings table|nil Actual AgentSettings owner for the agent.
--- @return table|nil ticket
function M.begin(renderer, kind, ctx, settings)
	local declaration = declarations[kind]
	if not declaration or type(renderer) ~= "table"
		or type(ctx) ~= "table" or getmetatable(ctx) ~= nil then return nil end
	local renderer_snapshot = capture_api(renderer)
	if not renderer_snapshot then return nil end
	for _, method in ipairs({ "get_root", "group_row", "build", "render_rows", "template_rows" }) do
		if type(api_method(renderer, method)) ~= "function" then return nil end
	end
	local ok, root = pcall(api_method(renderer, "get_root"))
	if not ok or type(root) ~= "table" or getmetatable(root) ~= nil then return nil end
	local top, frame, child = rawget(root, "top_level"), rawget(root, declaration.frame), rawget(root, declaration.child)
	if not rows(top) or not rows(frame) or not rows(child) then return nil end
	local parent, position
	for index, row in next, top do
		if rawget(row, "id") == kind then
			if position then return nil end
			position = index
		end
	end
	for _, row in next, frame do
		if rawget(row, "id") == declaration.id then
			if parent then return nil end
			parent = row
		end
	end
	if not position or not parent or rawget(parent, "type") ~= "group"
		or type(rawget(parent, "i18n")) ~= "string" or rawget(parent, "i18n") == "" then return nil end
	local platforms = rawget(parent, "platforms")
	if type(platforms) ~= "table" or getmetatable(platforms) ~= nil then return nil end
	local visible = false
	for _, platform in next, platforms do
		if platform == "linux" then visible = true end
	end
	if not visible then return nil end
	local frame_snapshot, child_snapshot, top_snapshot = capture(frame), capture(child), capture(top)
	if not frame_snapshot or not child_snapshot or not top_snapshot then return nil end
	local snapshots = { frame_snapshot, child_snapshot, top_snapshot }
	local ticket = { renderer = renderer, root = root, top = top, frame = frame, child = child,
		position = position, top_parent = top[position], declaration = declaration, kind = kind,
		ctx = ctx, context = { llm = rawget(ctx, "llm"), paused = rawget(ctx, "paused"),
			is_paused = rawget(ctx, "is_paused"), changed = rawget(ctx, "on_menu_changed") },
		native = rawget(ctx, "llm"), settings = settings, snapshots = snapshots, methods = {},
		renderer_snapshot = renderer_snapshot }
	for _, method in ipairs({ "get_root", "group_row", "build", "render_rows", "template_rows" }) do
		ticket.methods[method] = api_method(renderer, method)
	end
	if ticket.native ~= nil then
		ticket.native_snapshot = capture(ticket.native, nil, true)
		if not ticket.native_snapshot then return nil end
	end
	if settings ~= nil then
		ticket.settings_snapshot = capture(settings, nil, true)
		if not ticket.settings_snapshot then return nil end
	end
	ticket.enabled = enabled(ticket)
	return ticket
end

--- Rechecks the native and shared source cohort before and after projection.
--- @param ticket table
--- @return boolean
local function current(ticket)
	-- Native state and source readers can withdraw the cohort while answering.
	-- Complete both reads before the final pure checks, including after projection.
	local current_enabled = enabled(ticket)
	local ok, root = pcall(ticket.methods.get_root)
	local renderer, ctx = ticket.renderer, ticket.ctx
	for method, owner in next, ticket.methods do
		if not rawequal(api_method(renderer, method), owner) then return false end
	end
	if not ok or not rawequal(root, ticket.root) or not rawequal(rawget(root, "top_level"), ticket.top)
		or not rawequal(rawget(root, ticket.declaration.frame), ticket.frame)
		or not rawequal(rawget(root, ticket.declaration.child), ticket.child)
		or not rawequal(rawget(ticket.top, ticket.position), ticket.top_parent)
		or not rawequal(rawget(ctx, "llm"), ticket.context.llm)
		or not rawequal(rawget(ctx, "paused"), ticket.context.paused)
		or not rawequal(rawget(ctx, "is_paused"), ticket.context.is_paused)
		or not rawequal(rawget(ctx, "on_menu_changed"), ticket.context.changed) then return false end
	if not unchanged_api(ticket.renderer_snapshot) then return false end
	for _, snapshot in ipairs(ticket.snapshots) do if not unchanged(snapshot) then return false end end
	if ticket.native_snapshot and not unchanged(ticket.native_snapshot) then return false end
	if ticket.settings_snapshot and not unchanged(ticket.settings_snapshot) then return false end
	return current_enabled == ticket.enabled
end

--- Projects only a whole completed child with its original callbacks retained.
--- @param ticket table|nil Captured genuine source and native owners.
--- @param children table Finished native subtree.
--- @return table|nil parent
function M.finish(ticket, children)
	if not ticket or not rows(children) or not current(ticket) then return nil end
	local native_children = capture(children)
	if not native_children then return nil end
	local ready = ticket.enabled ~= nil and type(ticket.native) == "table"
		and unpaused(ticket.ctx)
	local getters = ticket.kind == "llm" and {
		llm_parent_enabled = function() return ticket.enabled end,
		llm_parent_ready = function() return ready end,
	} or {
		agent_parent_enabled = function() return ticket.enabled end,
		agent_parent_ready = function() return ready end,
	}
	local getter_snapshot = capture(getters)
	local row = ticket.methods.group_row(ticket.declaration.frame, ticket.declaration.id, children, getters)
	if not current(ticket) or not unchanged(native_children) or not unchanged(getter_snapshot)
		or type(row) ~= "table" or not rawequal(rawget(row, "submenu"), children) then return nil end
	return row
end

return M
