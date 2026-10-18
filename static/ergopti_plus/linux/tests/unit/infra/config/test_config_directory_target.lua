--- tests/unit/infra/config/test_config_directory_target.lua

--- ==============================================================================
--- MODULE: Configuration Directory Target Admission
--- DESCRIPTION:
--- A valid absolute string is not evidence of a usable directory. Real child
--- processes must refuse non-directory targets before changing the locator.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell, Json = require("adapters.shell_runner"), require("json")

--- Runs actual persistence in a process with private XDG roots and inherited HOME.
--- @param entry string Single setter, batch setter or paths editor.
--- @param mode string Native target shape.
--- @return table observation
local function observe(entry, mode)
	local root = os.tmpname(); assert(os.remove(root))
	assert(Shell.run("mkdir -p -- " .. Shell.quote(root)))
	local okay, result = pcall(function()
		local driver = helpers.driver_root()
		local command = "XDG_CONFIG_HOME=" .. Shell.quote(root .. "/xdg config")
			.. " XDG_DATA_HOME=" .. Shell.quote(root .. "/xdg data")
			.. " XDG_STATE_HOME=" .. Shell.quote(root .. "/xdg state")
			.. " " .. Shell.quote(assert(require("luv").exepath())) .. " "
			.. Shell.quote(driver .. "/tests/fixtures/config_directory_target.lua") .. " "
			.. Shell.quote(driver) .. " " .. Shell.quote(root) .. " " .. Shell.quote(entry) .. " " .. Shell.quote(mode) .. " 2>&1"
		local pipe = assert(io.popen(command, "r")); local output = assert(pipe:read("*a"))
		local success, _, code = pipe:close()
		helpers.assert_true(success == 0 or success == true and (code == nil or code == 0), output)
		local encoded = assert(output:match("DIRECTORY_TARGET_RESULT ([^\r\n]+)"), output)
		return assert(Json.decode(encoded))
	end)
	assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
	if not okay then error(result, 0) end
	return result
end

helpers.describe("configuration directory admission (config-directory-target)", function()
	for _, entry in ipairs({ "single", "batch", "editor" }) do
		for _, mode in ipairs({ "file", "parent_file", "broken_link" }) do
			helpers.it("config-directory-target refuses " .. mode .. " through " .. entry, function()
				local observed = observe(entry, mode)
				helpers.assert_eq(observed.saved, false, "an absolute string is not a directory acknowledgement")
				helpers.assert_true(observed.previous_choice_preserved and observed.store_bytes_preserved and observed.logs_preserved,
					"neither bootstrap setting nor its exact source bytes may change on target refusal")
				helpers.assert_eq(observed.hides, 0); helpers.assert_eq(observed.reloads, 0)
				helpers.assert_true(observed.sentinel_preserved)
				helpers.assert_eq(observed.loader_status, "ok", "the previous usable configuration remains selected")
			end)
		end
		for _, mode in ipairs({ "existing", "symlink", "create", "default" }) do
			helpers.it("config-directory-target accepts " .. mode .. " through " .. entry, function()
				local observed = observe(entry, mode)
				helpers.assert_eq(observed.saved, true)
				helpers.assert_true(observed.directory_exists and observed.sentinel_preserved)
				helpers.assert_eq(observed.loader_status, (mode == "create" or mode == "default") and "absent" or "ok")
				if entry == "editor" then
					helpers.assert_eq(observed.hidden, true); helpers.assert_eq(observed.reloaded, true)
					helpers.assert_eq(observed.hides, 1); helpers.assert_eq(observed.reloads, 1)
				end
				if entry ~= "batch" then helpers.assert_true(observed.logs_preserved) end
				if mode == "default" then helpers.assert_true(observed.default_selected) end
			end)
		end
	end
end)
