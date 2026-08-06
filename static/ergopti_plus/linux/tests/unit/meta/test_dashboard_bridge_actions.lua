--- tests/unit/meta/test_dashboard_bridge_actions.lua

--- ==============================================================================
--- MODULE: Every Action The Page Sends Has A Handler That Can Run
--- DESCRIPTION:
--- Two invariants over the dashboard bridges: they answer the actions the shared
--- pages actually send, and every keylogger function they name exists.
---
--- THE THREE DEFECTS THIS PINS:
--- The typing bridge had no `clear_cache` branch. That message is what the
--- dashboard\'s reset control sends: it clears the filters in the page and asks
--- the backend to drop its caches so the next payload is a clean rebuild. With
--- no handler the page reset itself and the backend kept serving the manifest it
--- already had, so the single observable effect of pressing reset was that
--- nothing changed.
---
--- The apps bridge had no `edit` branch, and `edit` is the only control on that
--- page that WRITES anything: the user picks a category, the modal closes, and
--- the choice went nowhere. `category` is a real column on agg_app_day and the
--- dashboard groups by it.
---
--- And its `app_detail` branch called `keylogger.get_app_detail`, a function
--- that has never existed on this driver, behind a `type(…) == "function"`
--- guard. The guard read as defensive while making the branch permanently
--- unreachable — the same shape as the forty-one bridge calls that passed the
--- module table as `self` and were each swallowed by a type check.
---
--- WHY THE ACTION LIST IS READ FROM THE PAGE:
--- Naming the expected actions here would let the page and the handlers drift
--- apart again in the direction that has already happened twice. The source of
--- truth is what the shared JavaScript posts, so that is what is read. The file
--- list is explicit rather than globbed because this suite runs under LuaJIT
--- with no lfs, and shelling out to `find` works on the CI runner and not on the
--- maintainer\'s machine — a scan that finds nothing agrees with every handler.
--- ==============================================================================

local helpers = require("tests.helpers")

local Paths = helpers.load_module("infra.paths")

-- Which files of each shared page can carry a postMessage. Listed rather than
-- discovered, and asserted non-empty below so a rename cannot silently empty
-- the scan.
local PAGE_FILES = {
	metrics_typing = { "index.html", "data.js", "filters.js", "main.js", "script.js", "state.js" },
	metrics_apps = { "index.html", "main.js", "script.js", "helpers.js", "modal.js", "state.js" },
}

--- Every action string a shared page posts to its bridge.
--- @param app string Directory name under _shared/ui/.
--- @return table Sorted array of action names.
local function actions_sent_by(app)
	local root = Paths.shared_root()
	helpers.assert_not_nil(root, "the shared tree must be findable")
	local seen = {}
	for _, name in ipairs(PAGE_FILES[app]) do
		local handle = io.open(root .. "/ui/" .. app .. "/" .. name, "r")
		if handle then
			local content = handle:read("*a") or ""
			handle:close()
			for action in content:gmatch("action:%s*'([%a_]+)'") do seen[action] = true end
			for action in content:gmatch('action:%s*"([%a_]+)"') do seen[action] = true end
		end
	end
	local out = {}
	for name in pairs(seen) do out[#out + 1] = name end
	table.sort(out)
	return out
end

--- Reads one of the driver\'s bridge sources.
--- @param relative string Path under the driver root.
--- @return string
local function bridge_source(relative)
	local handle = assert(io.open(helpers.driver_root() .. "/" .. relative, "r"))
	local content = handle:read("*a")
	handle:close()
	return content
end




-- =================================================================
-- =================================================================
-- ======= 1/ Nothing the page sends falls through =================
-- =================================================================
-- =================================================================

helpers.describe("dashboard bridges: coverage of what the pages send", function()

	helpers.it("handles every action the typing dashboard posts", function()
		local sent = actions_sent_by("metrics_typing")
		local source = bridge_source("ui/metrics_typing/bridge.lua")
		helpers.assert_true(#sent > 0,
			"no actions were found in the shared page — the file list above went "
				.. "stale, and a scan that finds nothing agrees with every handler")
		for _, name in ipairs(sent) do
			helpers.assert_true(source:find('"' .. name .. '"', 1, true) ~= nil,
				"the typing page sends '" .. name .. "' and the bridge never names it. "
					.. "For clear_cache that meant the reset control re-rendered the page "
					.. "against the cache it had just asked to drop, so pressing reset "
					.. "changed nothing at all.")
		end
	end)

	helpers.it("handles every action the apps dashboard posts", function()
		local sent = actions_sent_by("metrics_apps")
		local source = bridge_source("ui/metrics_apps/bridge.lua")
		helpers.assert_true(#sent > 0, "the scan must find the page's actions")
		for _, name in ipairs(sent) do
			helpers.assert_true(source:find('"' .. name .. '"', 1, true) ~= nil,
				"the apps page sends '" .. name .. "' and the bridge never names it. "
					.. "'edit' is the only control on that page that writes anything: the "
					.. "user picks a category, the modal closes, and the choice went "
					.. "nowhere.")
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Every function they call exists ======================
-- =================================================================
-- =================================================================

helpers.describe("dashboard bridges: no call to a function that is not there", function()

	local Keylogger = helpers.load_module("modules.keylogger.keylogger")

	for _, relative in ipairs({ "ui/metrics_apps/bridge.lua", "ui/metrics_typing/bridge.lua" }) do
		helpers.it(relative .. " names only keylogger functions that exist", function()
			local source = bridge_source(relative)
			local checked = 0
			for name in source:gmatch("state%.keylogger%.([%a_]+)") do
				checked = checked + 1
				helpers.assert_eq(type(Keylogger[name]), "function",
					"'" .. name .. "' is called on the keylogger and does not exist. Behind "
						.. "a `type(…) == \"function\"` guard that reads as defensive, a "
						.. "missing function becomes a silent nil and the branch is "
						.. "permanently unreachable — which is exactly how get_app_detail "
						.. "survived, and how forty-one bridge calls before it did.")
			end
			helpers.assert_true(checked > 0,
				"no keylogger calls were found in " .. relative .. " — the pattern broke, "
					.. "and a scan that matches nothing passes for any source at all")
		end)
	end

end)
