--- _shared/lua/test/menu_off_platform.lua

--- ==============================================================================
--- MODULE: Off-Platform Rows Never Reach The Menu
--- DESCRIPTION:
--- Shared by the macOS and Linux suites. Renders every menu of the real shared
--- manifest for one platform, with every i18n key resolving to a marked string,
--- and reports each rendered title that carries a `platform_reason.*` text.
---
--- The renderer used to show a row another driver has as a greyed stand-in
--- carrying its `reason_key` explanation ("… — Linux only", the Windows registry
--- options under Gestures on macOS). Those long explanations made the tray wide
--- and filled it with rows the user cannot use. A row this platform does not
--- have is now dropped; the explanations are read in the health check instead.
--- ==============================================================================

local check = require("test.menu_separators")

local M = {}

-- Every key resolves to itself between these marks, so a rendered title shows
-- which keys built it and an unresolved key cannot be mistaken for a hidden row.
local OPEN, CLOSE = "<<", ">>"

--- Walks rendered menu items depth-first, calling visit(title) for each titled row.
--- @param items table
--- @param visit function
local function walk(items, visit)
	for _, item in ipairs(items or {}) do
		if type(item) == "table" then
			if type(item.title) == "string" then visit(item.title) end
			if type(item.menu) == "table" then walk(item.menu, visit) end
		end
	end
end

--- Returns every rendered row, across all manifest menus, whose title carries an
--- off-platform explanation, as "<menu key>: <title>" strings.
--- @param Renderer table The shared renderer module (menu.renderer).
--- @param opts table { platform, manifest_path, json_decode, logger }.
--- @return table leaks, number menus_rendered
function M.reason_leaks(Renderer, opts)
	local leaks = {}
	local marked = function(key) return OPEN .. tostring(key) .. CLOSE end
	local _, count = check.render_every_menu(Renderer, {
		platform      = opts.platform,
		manifest_path = opts.manifest_path,
		json_decode   = opts.json_decode,
		logger        = opts.logger,
		i18n          = { get = marked, section = marked },
		on_rendered   = function(key, rendered)
			walk(rendered, function(title)
				if title:find(OPEN .. "platform_reason.", 1, true) then
					leaks[#leaks + 1] = key .. ": " .. title
				end
			end)
		end,
	})
	return leaks, count
end

--- Returns how many rows of the manifest are restricted to other platforms and
--- carry a reason_key: the rows the old renderer would have shown greyed.
--- @param root table Decoded menu manifest.
--- @param platform string
--- @return number
function M.explained_off_platform_count(root, platform)
	local count = 0
	for _, value in pairs(root) do
		if type(value) == "table" and type(value[1]) == "table" and value[1].type ~= nil then
			for _, entry in ipairs(value) do
				if type(entry.platforms) == "table" and type(entry.reason_key) == "string" then
					local here = false
					for _, p in ipairs(entry.platforms) do
						if p == platform then here = true end
					end
					if not here then count = count + 1 end
				end
			end
		end
	end
	return count
end

return M
