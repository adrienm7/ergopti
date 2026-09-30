--- tests/meta/test_legacy_cleanup_presenter_registered.lua

--- ==============================================================================
--- MODULE: The boot registers the legacy rules cleanup (karabiner-legacy-cleanup)
--- DESCRIPTION:
--- Rules an older ErgoptiPlus left in karabiner.json refused every deploy and
--- the user had nothing to click. The remap bridge offers their removal
--- through the one presenter the boot registers; the unit suite never runs
--- init.lua, so this registration is pinned here: before the boot deploy that
--- can meet those rules, through the dialog module, and guarded so a failure
--- costs the dialog, never the boot.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Returns source text with every line comment removed.
--- @param src string Source text.
--- @return string code
local function without_comments(src)
	local lines = {}
	for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = (line:gsub("%-%-.*$", "")) end
	return table.concat(lines, "\n")
end

helpers.describe("the boot registers the legacy rules cleanup (karabiner-legacy-cleanup)", function()
	helpers.it("registers the dialog before the boot deploy, guarded (karabiner-legacy-cleanup)", function()
		local unit, err = helpers.read_driver_unit("karabiner.set_legacy_cleanup_presenter(")
		helpers.assert_true(unit ~= nil, tostring(err))
		local body = without_comments(unit)
		local init_at = body:find("karabiner.init(file_system)", 1, true)
		local register_at = body:find("karabiner.set_legacy_cleanup_presenter(function()", 1, true)
		local deploy_at = body:find("karabiner.regenerate()", 1, true)
		helpers.assert_true(init_at ~= nil and register_at ~= nil and deploy_at ~= nil,
			"the bridge init, the registration and the boot deploy must all be found")
		helpers.assert_true(init_at < register_at and register_at < deploy_at,
			"the presenter must exist before the boot deploy can be refused")
		local registration = body:sub(register_at, body:find("\nend\n", register_at, true))
		helpers.assert_true(registration:find('require("ui.legacy_rules_cleanup").offer(karabiner)', 1, true) ~= nil,
			"the presenter must offer the removal through the dialog module")
		local guarded = body:sub(1, register_at):match(".*()xpcall%(function%(%)")
		helpers.assert_true(guarded ~= nil and guarded > init_at,
			"a registration failure must cost the dialog, never the boot")
	end)
end)
