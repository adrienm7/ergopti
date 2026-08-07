--- tests/unit/meta/test_top_level_order_is_the_manifest.lua

--- ==============================================================================
--- MODULE: The Tray Root Follows the Manifest (Linux)
--- DESCRIPTION:
--- `top_level` in the shared manifest declares which entries the tray holds and
--- in what order. Windows has read that array through its own loader all along.
--- This driver wrote the sequence out as a list of calls in `M.build`, and a
--- sequence that exists only as code cannot be compared with the declaration by
--- anything.
---
--- It had already drifted. The debug submenu sat between "reload" and "quit"
--- here while the manifest declares it last, and nothing reported the
--- difference — there was nothing to report it to.
---
--- WHAT THIS PINS:
---   1. The entries this driver builds appear in the manifest's order, with the
---      rows it may not see filtered out.
---   2. Every top-level row declared for linux has a builder. A declared row
---      with no builder is an entry the user was promised and will not see, and
---      the handler-bijection gate cannot catch it: top_level rows carry no
---      behaviour type for it to key on.
---   3. The order is READ, not repeated. A future edit that goes back to a fixed
---      sequence of calls fails here rather than drifting quietly.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the menu builder's source. This driver's helpers expose a root path
--- rather than a source reader, so the path is resolved here — from that root,
--- not from the test's own location, which moves when a test does.
--- @return string File contents.
local function builder_source()
	local path = helpers.driver_root() .. "/ui/menu/menu_builder.lua"
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "ui/menu/menu_builder.lua must be readable at " .. path)
	local src = fh:read("*a")
	fh:close()
	return src
end

--- The top-level ids the manifest declares for this driver, in order.
--- @return table Ordered list of ids, separators included as "---".
local function declared_ids()
	local ManifestMenu = helpers.load_module("infra.manifest_menu")
	local rows = ManifestMenu.get_array("top_level")
	helpers.assert_true(type(rows) == "table" and #rows > 0,
		"the manifest must declare a non-empty top_level array")

	local ids = {}
	for _, row in ipairs(rows) do
		local visible = true
		if type(row.platforms) == "table" then
			visible = false
			for _, p in ipairs(row.platforms) do
				if p == "linux" then visible = true; break end
			end
		end
		if visible then ids[#ids + 1] = row.id end
	end
	return ids
end




helpers.describe("the tray root follows the manifest (Linux)", function()

	helpers.it("every top-level row declared for this driver has a builder", function()
		local src = builder_source()
		local block = src:match("local builders = {(.-)\n\t}")
		helpers.assert_true(block ~= nil, "M.build must map top-level ids to builders")

		local missing = {}
		local checked = 0
		for _, id in ipairs(declared_ids()) do
			if id ~= "---" then
				checked = checked + 1
				if not block:find('%["' .. id .. '"%]') then
					missing[#missing + 1] = id
				end
			end
		end
		-- Floors the scan: an empty id list would make every assertion below
		-- vacuous, and this driver's tray is not two entries long.
		helpers.assert_true(checked >= 10,
			"the manifest must declare at least ten top-level rows for linux — found " .. checked)
		helpers.assert_eq(#missing, 0,
			"these top-level rows are declared for linux and have no builder: " ..
			table.concat(missing, ", ") .. ". The user is promised an entry that will not appear, " ..
			"and no other gate can see it: top_level rows carry no behaviour type to key on")
	end)

	helpers.it("the order is read from the manifest, not written out here", function()
		local src = builder_source()
		helpers.assert_true(src:find('ManifestMenu%.get_array%("top_level"%)') ~= nil,
			"M.build must read top_level from the manifest — a sequence of calls cannot be " ..
			"compared with the declaration, which is how the debug submenu came to sit in a " ..
			"different place here than the manifest says")

		-- The old shape: one call per entry, in a fixed order. If it comes back,
		-- the manifest stops deciding what the tray looks like on this driver.
		local build_body = src:match("function M%.build%(ctx%)(.-)\nend")
		helpers.assert_true(build_body ~= nil, "M.build must exist")
		local hardcoded = 0
		for _ in build_body:gmatch("items%[#items %+ 1%] = _build_") do
			hardcoded = hardcoded + 1
		end
		-- The header is legitimately outside the manifest: it is a version string
		-- no declaration can carry.
		helpers.assert_true(hardcoded <= 1,
			"M.build appends " .. hardcoded .. " entries by hand. Only the version header may be " ..
			"built outside the manifest's order; everything else is dispatched from the declared ids")
	end)
end)
