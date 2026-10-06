--- _shared/lua/cursor_window_policy.lua

--- Strict cursor-display snapshot decoding and centre placement policy.
local M = {}
M.TRANSPORT_NAMES = { "initial", "acknowledged", "request", "permit", "digest" }

local function integer(value)
	if type(value) ~= "string" or not value:match("^%-?%d+$") then return nil end
	local number = tonumber(value)
	if not number or math.abs(number) > 2147483647 then return nil end
	return number
end

local function window_id(value)
	if type(value) ~= "string" then return nil end
	local digits = value:match("^0x([%da-fA-F]+)$")
	local id = digits and tonumber(digits, 16) or integer(value)
	if not id or id < 1 or id > 4294967295 then return nil end
	return id
end

--- Decodes the fixed snapshot packet, refusing partial or ambiguous answers.
--- @param text string Native stdout packet, with no client titles.
--- @return table|nil snapshot
function M.parse_snapshot(text)
	if type(text) ~= "string" then return nil end
	local lines = {}
	for line in text:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	if #lines == 0 or text:sub(-1) ~= "\n" then return nil end
	local index = 1
	local function take(expected)
		local line = lines[index]
		index = index + 1
		if expected and line ~= expected then error("invalid snapshot", 0) end
		return line
	end
	local function fields(stop, allowed)
		local values = {}
		while lines[index] and lines[index] ~= stop do
			local key, value = take():match("^([A-Z_]+)=(%-?%d+)$")
			if not key or not allowed[key] or values[key] ~= nil then error("invalid fields", 0) end
			values[key] = value
		end
		return values
	end
	local ok, snapshot = pcall(function()
		local root = nil
		if lines[index] == "source" then
			take("source")
			root = window_id((take() or ""):match("^ROOT=(%d+)$"))
			if not root then error("invalid native root", 0) end
		end
		take("pointer")
		local pointer = fields("monitors", { X = true, Y = true, SCREEN = true, WINDOW = true })
		local x, y, screen = integer(pointer.X), integer(pointer.Y), integer(pointer.SCREEN)
		if not x or not y or not screen or screen < 0 then error("invalid pointer", 0) end
		take("monitors")
		local count = integer((take() or ""):match("^Monitors: (%d+)$"))
		if not count or count < 1 or count > #lines then error("invalid monitors", 0) end
		local monitors, selected = {}, nil
		for row = 1, count do
			local line = take() or ""
			local id, name, width, height, left, top, outputs = line:match("^%s*(%d+):%s+(%S+)%s+(%d+)/%d+x(%d+)/%d+([+-]%d+)([+-]%d+)%s*(.-)%s*$")
			if not outputs or outputs:find("[^%w_.:%- ]") then error("invalid monitor outputs", 0) end
			width, height = integer(width), integer(height)
			left, top = integer(left and left:gsub("^%+", "")), integer(top and top:gsub("^%+", ""))
			if id ~= tostring(row - 1) or not width or not height or not left or not top or width < 1 or height < 1 or monitors[id] then
				error("invalid monitor", 0)
			end
			local monitor = { id = id, name = name, outputs = outputs, x = left, y = top, width = width, height = height }
			monitors[id] = monitor
			if x >= left and x < left + width and y >= top and y < top + height then
				if selected then error("ambiguous pointer display", 0) end
				selected = monitor
			end
		end
		if not selected then error("pointer outside displays", 0) end
		take("active")
		local active = window_id(take())
		local focus_chain = {}
		if lines[index] == "focus" then
			take("focus")
			local seen = {}
			while lines[index] and lines[index] ~= "end_focus" do
				local id = window_id(take())
				if not id or seen[id] or #focus_chain >= 65 then error("invalid native focus ancestry", 0) end
				seen[id], focus_chain[#focus_chain + 1] = true, id
			end
			take("end_focus")
			if not root or #focus_chain == 0 or focus_chain[#focus_chain] ~= root then error("unowned native focus root", 0) end
		end
		take("desktop")
		local desktop = integer(take())
		if not active or not desktop or desktop < 0 then error("invalid desktop", 0) end
		take("stacking")
		local order, known = {}, {}
		local raw = take() or ""
		if raw:match("^%s*,") or raw:match(",%s*$") or raw:match(",%s*,") then error("invalid stacking separators", 0) end
		for token in raw:gmatch("[^, ]+") do
			local id = window_id(token)
			if not id or known[id] then error("invalid stacking", 0) end
			known[id] = true
			order[#order + 1] = id
		end
		if #order == 0 or not known[active] then error("incomplete stacking", 0) end
		local windows = {}
		for _, id in ipairs(order) do
			if window_id((take() or ""):match("^window (.+)$")) ~= id then error("invalid window", 0) end
			local values = fields("end_window", { WINDOW = true, X = true, Y = true, WIDTH = true, HEIGHT = true,
				SCREEN = true, DESKTOP = true, ELIGIBLE = true, UNAVAILABLE = true })
			take("end_window")
			if values.UNAVAILABLE ~= nil then
				if values.UNAVAILABLE ~= "1" then error("invalid unavailable window", 0) end
				for key in pairs(values) do
					if key ~= "UNAVAILABLE" then error("mixed unavailable window", 0) end
				end
			end
			if values.UNAVAILABLE ~= "1" then
				local wx, wy, width, height = integer(values.X), integer(values.Y), integer(values.WIDTH), integer(values.HEIGHT)
				local window_screen = integer(values.SCREEN)
				local wd = values.DESKTOP == "4294967295" and -1 or integer(values.DESKTOP)
				if window_id(values.WINDOW) ~= id or not wx or not wy or not width or not height
					or width < 1 or height < 1 or not wd or wd < -1 or not window_screen or window_screen < 0
					or (values.ELIGIBLE ~= "0" and values.ELIGIBLE ~= "1") then
					error("invalid geometry", 0)
				end
				windows[id] = { x = wx, y = wy, width = width, height = height,
					desktop = wd, eligible = values.ELIGIBLE == "1", screen = window_screen }
			end
		end
		take("end_snapshot")
		if index ~= #lines + 1 then error("unexpected tail", 0) end
		return { root = root, pointer = { x = x, y = y, screen = screen }, monitor = selected, active = active, focus_chain = focus_chain, desktop = desktop, order = order, windows = windows }
	end)
	return ok and snapshot or nil
end

function M.candidate(snapshot)
	local monitor = snapshot.monitor
	for index = #snapshot.order, 1, -1 do
		local id = snapshot.order[index]
		local window = snapshot.windows[id]
		if id ~= snapshot.active and window and window.eligible
			and window.screen == snapshot.pointer.screen
			and (window.desktop == snapshot.desktop or window.desktop == -1) then
			local x, y = window.x + window.width / 2, window.y + window.height / 2
			if x >= monitor.x and x < monitor.x + monitor.width
				and y >= monitor.y and y < monitor.y + monitor.height then return id end
		end
	end
	return nil
end

--- Checks the exact native screen/root and captured logical display.
--- @param first table Captured snapshot.
--- @param current table Fresh native snapshot.
--- @return boolean same Native display lease still holds.
function M.same_source(first, current)
	if not first or not current or not first.root or first.root ~= current.root
		or first.pointer.screen ~= current.pointer.screen or first.desktop ~= current.desktop then return false end
	for _, key in ipairs({ "id", "name", "outputs", "x", "y", "width", "height" }) do
		if first.monitor[key] ~= current.monitor[key] then return false end
	end
	local active = current.windows[current.active]
	return active ~= nil and active.screen == current.pointer.screen
end

--- Revalidates the captured target immediately before native activation.
--- @param first table Captured snapshot and native source lease.
--- @param current table Fresh native eligibility snapshot.
--- @param target number Captured target.
--- @return boolean admitted Source, active window and exact target still hold.
function M.revalidated(first, current, target)
	return M.same_source(first, current) and current.active == first.active and M.candidate(current) == target
end

--- Refuses stale eligibility or a different independently observed focus.
--- @param first table Captured lease.
--- @param current table Fresh native snapshot.
--- @param target number Captured eligible native window.
--- @return boolean acknowledged Exact native focus and placement hold.
function M.acknowledged(first, current, target)
	if not M.same_source(first, current) or current.active ~= target then return false end
	local focused = false
	for _, ancestor in ipairs(current.focus_chain or {}) do if ancestor == target then focused = true end end
	if not focused then return false end
	local window, monitor = current.windows[target], current.monitor
	if not window or not window.eligible or window.screen ~= current.pointer.screen
		or (window.desktop ~= current.desktop and window.desktop ~= -1) then return false end
	local x, y = window.x + window.width / 2, window.y + window.height / 2
	return x >= monitor.x and x < monitor.x + monitor.width and y >= monitor.y and y < monitor.y + monitor.height
end

return M
