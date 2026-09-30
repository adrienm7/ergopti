--- tests/meta/test_permission_guidance_not_alert_banner.lua

--- ==============================================================================
--- MODULE: Permission guidance is never a one-line banner (permission-dialog-native)
--- DESCRIPTION:
--- After an update, the Accessibility wait printed its instructions with
--- hs.alert: one long line along the Dock that could not be clicked. Those
--- instructions now live in ui.permission_dialog. This guard scans the whole
--- driver so no permission or onboarding instruction returns to hs.alert; the
--- only banners left are short transient confirmations, listed below with the
--- exact locale keys they may show.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The only banners allowed: the locale keys of short transient confirmations.
-- Keep-awake confirms a toggle for a moment; it explains nothing.
local ALLOWED_BANNER_KEYS = {
	["shortcuts.keep_awake_on"] = true,
	["shortcuts.keep_awake_off"] = true,
}


--- Returns source text with every line comment removed, as a list of lines.
--- @param src string Source text.
--- @return table lines
local function code_lines(src)
	local lines = {}
	for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = (line:gsub("%-%-.*$", "")) end
	return lines
end

helpers.describe("permission guidance is a dialog, not a banner (permission-dialog-native)", function()
	helpers.it("no permission or onboarding instruction uses hs.alert", function()
		-- Every production file that mentions hs.alert, found by symbol, not path.
		local src = helpers.read_driver_source("hs.alert")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the keep-awake confirmation banner must stay discoverable, or the scan is blind")
		local offenders = {}
		local shown = 0
		for _, line in ipairs(code_lines(src)) do
			if line:find("%f[%w]hs%.alert") and not line:find("hs%.alert%.close") then
				local key = line:match('i18n%.get%("([^"]+)"%)')
				if key ~= nil and ALLOWED_BANNER_KEYS[key] then
					shown = shown + 1
				else
					offenders[#offenders + 1] = line
				end
			end
		end
		helpers.assert_eq(shown, 2, "both keep-awake confirmations must still be found by the scan")
		helpers.assert_eq(#offenders, 0, "hs.alert banner outside the allowlist:\n" .. table.concat(offenders, "\n"))
	end)

	helpers.it("the boot's Accessibility wait opens the permission dialog", function()
		local unit, err = helpers.read_driver_unit("local function show_accessibility_guidance()")
		helpers.assert_true(unit ~= nil, tostring(err))
		local body = table.concat(code_lines(unit), "\n")
		local at = body:find("local function show_accessibility_guidance()", 1, true)
		local stop = body:find("\nend\n", at, true)
		local fn = body:sub(at, stop)
		helpers.assert_true(fn:find('require("ui.permission_dialog").guide_accessibility(AccessibilityPermission)',
			1, true) ~= nil, "the wait must show the native dialog")
		helpers.assert_true(fn:find("xpcall(", 1, true) ~= nil, "a dialog failure must never stop the boot")
		helpers.assert_true(body:find("show_guidance = function() close_guidance = show_accessibility_guidance() end",
			1, true) ~= nil, "the wait must own the dialog it closes on the grant")
	end)

	helpers.it("reopening ErgoptiPlus during the wait shows the steps again", function()
		local unit, err = helpers.read_driver_unit("local function watch_launcher_reopen(on_reopen)")
		helpers.assert_true(unit ~= nil, tostring(err))
		local body = table.concat(code_lines(unit), "\n")
		local at = body:find("local function watch_launcher_reopen(on_reopen)", 1, true)
		local fn = body:sub(at, body:find("\nend\n", at, true))
		helpers.assert_true(fn:find("LauncherGuard.watch_activation(on_reopen)", 1, true) ~= nil,
			"a reopen only activates the launcher; its guard is the one that sees it")
		helpers.assert_true(fn:find("xpcall(", 1, true) ~= nil, "a watch failure must never stop the boot")
		local wait_at = body:find("AccessibilityWait.start({", 1, true)
		helpers.assert_true(wait_at ~= nil and body:find("watch_reopen = watch_launcher_reopen,", wait_at, true) ~= nil,
			"the wait must be given the reopen watch, or a closed dialog cannot come back")
	end)

	-- The unit suite never runs init.lua, so the one registration that makes
	-- the guardian's approval open the Login Items steps is pinned here.
	helpers.it("the boot registers the Login Items steps before its first deploy (guardian-approval-steps)",
		function()
			local unit, err = helpers.read_driver_unit("karabiner.set_approval_presenter(")
			helpers.assert_true(unit ~= nil, tostring(err))
			local body = table.concat(code_lines(unit), "\n")
			local init_at = body:find("karabiner.init(file_system)", 1, true)
			local register_at = body:find("karabiner.set_approval_presenter(function()", 1, true)
			local deploy_at = body:find("karabiner.regenerate()", 1, true)
			helpers.assert_true(init_at ~= nil and register_at ~= nil and deploy_at ~= nil,
				"the bridge init, the registration and the boot deploy must all be found")
			helpers.assert_true(init_at < register_at and register_at < deploy_at,
				"the presenter must exist before the first guardian answer the boot deploy asks for")
			local registration = body:sub(register_at, body:find("\nend\n", register_at, true))
			helpers.assert_true(registration:find(
				'require("ui.permission_dialog.login_items_guide").offer(karabiner)', 1, true) ~= nil,
				"the presenter must offer the steps through the guide, once per launch")
			local guarded = body:sub(1, register_at):match(".*()xpcall%(function%(%)")
			helpers.assert_true(guarded ~= nil and guarded > init_at,
				"a registration failure must cost the steps, never the boot")
		end)
end)
