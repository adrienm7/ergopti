--- _shared/tests/lua/category_off_contract.lua

--- ==============================================================================
--- MODULE: Category-Off Contract
--- DESCRIPTION:
--- Asserts the maintainer's rule of 2026-11-02 on one built category submenu,
--- for both Lua drivers. The parent row is never greyed. While the category is
--- off, only the enable row and the rows flagged `readable_when_off` stay live,
--- every other row is greyed with nothing to run. With it on, nothing carries
--- the reason.
--- ==============================================================================

local M = {}

--- The labels of the rows of a menu that stay live while it is off.
--- @param rows table The manifest rows of the category's menu.
--- @param i18n table The translation owner.
--- @return table prefixes
local function live_prefixes(rows, i18n)
	local prefixes = {}
	for _, row in ipairs(rows) do
		if row.submenu_off_reason_key ~= nil or row.readable_when_off == true then
			prefixes[#prefixes + 1] = i18n.get(row.i18n):match("^[^{]*")
		end
	end
	return prefixes
end

--- @param title string
--- @param prefixes table
--- @return boolean
local function starts_with_any(title, prefixes)
	for _, prefix in ipairs(prefixes) do
		if title:sub(1, #prefix) == prefix then return true end
	end
	return false
end

-- Rows whose rendering needs driver modules become a clickable probe list at
-- the same position: what the rule greys depends only on the declarations.
local NEEDS_DRIVER = { feature = true, group = true, letter_picker = true, action = true,
	include = true, native_content = true }

--- Builds one gated manifest menu through the real renderer, its enable row
--- reading off or on, and returns the finished rows.
--- @param renderer table The driver's bound shared renderer.
--- @param key string Manifest menu key.
--- @param enable table Its enable row.
--- @param off boolean
--- @return table rows
local function build_probe(renderer, key, enable, off)
	local root = renderer.get_root()
	local probe, providers, commands, getters = {}, {}, {}, {}
	for index, item in ipairs(root[key]) do
		local copy = item
		if NEEDS_DRIVER[item.type] then
			copy = { type = "list", id = "probe_" .. index, platforms = item.platforms }
		end
		probe[#probe + 1] = copy
		if type(copy.id) == "string" then
			local label = "Probe " .. copy.id
			providers[copy.id] = function() return { { label = label, action = function() end } } end
			commands[copy.command or copy.id] = function() end
		end
		for _, field in ipairs({ "checked_when", "disabled_when" }) do
			for _, state in ipairs(copy[field] or {}) do getters[state] = function() return true end end
		end
		if copy.type == "choice" then getters[copy.path] = function() return "" end end
	end
	if enable.type == "toggle" then
		for _, state in ipairs(enable.checked_when) do getters[state] = function() return not off end end
	else
		getters[enable.path] = function() return off and enable.submenu_off_value or "auto" end
	end
	local PROBE = "_test_category_off_probe"
	root[PROBE] = probe
	local ok, rows = pcall(renderer.build, PROBE, "Probe", nil, nil,
		{ commands = commands, state_getters = getters }, providers)
	root[PROBE] = nil
	if not ok then error(rows, 0) end
	return rows
end

--- Whether a manifest row is drawn on this platform.
--- @param row table
--- @param platform string
--- @return boolean
local function for_platform(row, platform)
	if row.platforms == nil then return true end
	for _, token in ipairs(row.platforms) do if token == platform then return true end end
	return false
end

--- Renders every gated manifest menu shown on `platform`, off then on.
--- @param helpers table The driver's test helpers.
--- @param renderer table The driver's bound shared renderer.
--- @param i18n table The translation owner.
--- @param platform string "hs" or "linux".
function M.assert_every_gated_menu(helpers, renderer, i18n, platform)
	local gated = 0
	for key, rows in pairs(renderer.get_root()) do
		if type(rows) == "table" and key:sub(1, 1) ~= "_" then
			for _, row in ipairs(rows) do
				if type(row) == "table" and row.submenu_off_reason_key ~= nil and for_platform(row, platform) then
					gated = gated + 1
					for _, off in ipairs({ true, false }) do
						M.assert_category(helpers, i18n, rows,
							{ title = key, menu = build_probe(renderer, key, row, off) }, off)
					end
				end
			end
		end
	end
	-- Eight categories; the layout has an off state on Windows only.
	helpers.assert_eq(gated, 7, "every category but the layout is gated on " .. platform)
end

--- Asserts one built category against its posture.
--- @param helpers table The driver's test helpers.
--- @param i18n table The translation owner.
--- @param manifest_rows table The manifest rows of the category's menu.
--- @param parent table The built parent row.
--- @param off boolean Whether the category reads off.
function M.assert_category(helpers, i18n, manifest_rows, parent, off)
	local name = tostring(parent.title)
	helpers.assert_true(parent.disabled ~= true, name .. ": the main-menu row is never greyed")
	helpers.assert_true(type(parent.menu) == "table", name .. ": the row opens its submenu")
	local prefixes = live_prefixes(manifest_rows, i18n)
	local shown = 0
	for _, row in ipairs(manifest_rows) do
		if row.submenu_off_reason_key ~= nil or row.readable_when_off == true then shown = shown + 1 end
	end
	local reason = i18n.get("menu.category_off_reason")
	local cut = reason:find(":", 1, true) or reason:find("\239\188\154", 1, true)
	local head = (cut and reason:sub(1, cut - 1) or reason):match("^%s*(.-)%s*$")
	local live, others = 0, 0
	for _, row in ipairs(parent.menu) do
		if row.title ~= "-" then
			local title = tostring(row.title)
			if starts_with_any(title, prefixes) then
				live = live + 1
				helpers.assert_true(row.disabled ~= true, name .. ": stays live: " .. title)
			elseif off then
				helpers.assert_eq(row.disabled, true, name .. ": greyed while off: " .. title)
				helpers.assert_nil(row.fn, name .. ": runs nothing while off: " .. title)
				helpers.assert_nil(row.menu, name .. ": opens nothing while off: " .. title)
			else
				helpers.assert_nil(title:find(head, 1, true), name .. ": no reason while on: " .. title)
				if row.disabled ~= true then others = others + 1 end
			end
		end
	end
	helpers.assert_eq(live, shown, name .. ": the enable row and the reader rows are drawn live")
	if not off then helpers.assert_true(others > 0, name .. ": the rows are back with the category on") end
end

return M
