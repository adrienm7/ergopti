--- tests/unit/platform/remap/lease/test_lease_helper_identity.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Helper Identity Regression Tests
--- DESCRIPTION:
--- Proves that only the exact launcher executable derived from the application
--- bundle containing the Lua driver can become a native lease process. An
--- executable wrapper or stock Karabiner binary is rejected even when renamed
--- `ErgoptiPlus` or supplied through the inherited environment.
--- ==============================================================================

local helpers = require("tests.helpers")

local HELPER_ENV = "ERGOPTI_LAUNCHER_EXECUTABLE"
local HELPER_DEVICE_ENV = "ERGOPTI_LAUNCHER_DEVICE"
local HELPER_INODE_ENV = "ERGOPTI_LAUNCHER_INODE"
local DRIVER_ROOT = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos"
local EXPECTED_HELPER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
local EXPECTED_DEVICE = "16777234"
local EXPECTED_INODE = "987654321"

--- Resolves one candidate against deterministic file identity observations.
--- @param override string|nil Inherited launcher export.
--- @param options table|nil Attribute and resolution overrides.
--- @return string|nil resolved
--- @return string|nil error_message
local function resolve_candidate(override, options)
	options = options or {}
	package.loaded["platform.remap.lease_helper"] = nil
	local previous_dev_source = package.loaded["core.lifecycle.engine.dev_source"]
	if options.dev_source then package.loaded["core.lifecycle.engine.dev_source"] = options.dev_source end
	local helper = helpers.load_with_stubs("platform.remap.lease_helper", {
		processInfo = options.process_info,
		fs = {
			symlinkAttributes = function(path)
				if path ~= EXPECTED_HELPER then return nil end
				return options.link_attributes
					or {
						mode = "file",
						permissions = "rwxr-xr-x",
						dev = options.observed_device or tonumber(EXPECTED_DEVICE),
						ino = options.observed_inode or tonumber(EXPECTED_INODE),
					}
			end,
			attributes = function(path)
				if path ~= EXPECTED_HELPER then return nil end
				return options.attributes
					or {
						mode = "file",
						permissions = "rwxr-xr-x",
						dev = options.observed_device or tonumber(EXPECTED_DEVICE),
						ino = options.observed_inode or tonumber(EXPECTED_INODE),
					}
			end,
			pathToAbsolute = function(path)
				return options.resolved_path or path
			end,
		},
	})
	local original_getenv = os.getenv
	os.getenv = function(name)
		if name == HELPER_ENV then return override end
		if name == HELPER_DEVICE_ENV then
			if options.exported_device == false then return nil end
			return options.exported_device or EXPECTED_DEVICE
		end
		if name == HELPER_INODE_ENV then
			if options.exported_inode == false then return nil end
			return options.exported_inode or EXPECTED_INODE
		end
		return original_getenv(name)
	end
	local call_ok, resolved, resolve_err, environment = pcall(helper.resolve, options.no_override_root ~= true
		and DRIVER_ROOT or nil)
	os.getenv = original_getenv
	package.loaded["core.lifecycle.engine.dev_source"] = previous_dev_source
	if not call_ok then error(resolved) end
	return resolved, resolve_err, environment
end





-- ============================================
-- ============================================
-- ======= 1/ Exact Native Helper Identity ====
-- ============================================
-- ============================================

helpers.describe("karabiner lease helper: bundle-owned identity", function()
	helpers.it("accepts the exact regular executable owned by the running launcher", function()
		local resolved = resolve_candidate(EXPECTED_HELPER)
		helpers.assert_eq(resolved, EXPECTED_HELPER)
	end)

	helpers.it("returns the exact verified identity for this child environment", function()
		local resolved, detail, environment = resolve_candidate(EXPECTED_HELPER)
		helpers.assert_eq(resolved, EXPECTED_HELPER)
		helpers.assert_nil(detail)
		helpers.assert_not_nil(environment)
		helpers.assert_eq(environment[HELPER_ENV], EXPECTED_HELPER)
		helpers.assert_eq(environment[HELPER_DEVICE_ENV], EXPECTED_DEVICE)
		helpers.assert_eq(environment[HELPER_INODE_ENV], EXPECTED_INODE)
	end)

	-- The developer app runs a clone, not its bundled Lua: start at login asks
	-- this resolver for its launcher, so a source run on macOS reaches the
	-- login-item worker of the developer app's own bundle (SAD-1).
	helpers.it("resolves the developer app's own launcher for a clone (login-source-run)", function()
		local asked = nil
		local dev_source = {
			root = function() return "/Users/dev/ergopti" end,
			launcher_executable = function(bundle)
				asked = bundle
				return bundle == "/Users/dev/ergopti/build/macos/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app"
					and EXPECTED_HELPER or nil
			end,
		}
		local ok, resolved, detail = pcall(resolve_candidate, EXPECTED_HELPER, { dev_source = dev_source,
			no_override_root = true,
			process_info = { bundlePath = "/Users/dev/ergopti/build/macos/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app" } })
		assert(ok, resolved)
		helpers.assert_eq(asked, "/Users/dev/ergopti/build/macos/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app")
		helpers.assert_eq(resolved, EXPECTED_HELPER, detail)
	end)

	helpers.it("preserves a 64-bit integer inode without floating-point rounding", function()
		local large_inode = 9007199254740993
		local resolved = resolve_candidate(EXPECTED_HELPER, {
			exported_inode = "9007199254740993",
			observed_inode = large_inode,
		})
		helpers.assert_eq(resolved, EXPECTED_HELPER,
			"the exact launcher must not be rejected merely because its inode exceeds 2^53")
	end)

	helpers.it("fails closed without the running launcher's path and file identity", function()
		local missing_path = resolve_candidate(nil)
		helpers.assert_nil(missing_path)
		local missing_device = resolve_candidate(EXPECTED_HELPER, { exported_device = false })
		helpers.assert_nil(missing_device)
		local malformed_inode = resolve_candidate(EXPECTED_HELPER, { exported_inode = "01" })
		helpers.assert_nil(malformed_inode)
	end)

	helpers.it("rejects an executable wrapper renamed ErgoptiPlus", function()
		local resolved, resolve_err = resolve_candidate("/tmp/dev-build/ErgoptiPlus")
		helpers.assert_nil(resolved,
			"basename equality must never authorize an arbitrary helper process")
		helpers.assert_true(type(resolve_err) == "string" and resolve_err ~= "")
	end)

	helpers.it("rejects every executable whose path belongs to stock Karabiner", function()
		local stock_paths = {
			"/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements",
			"/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service",
			"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_console_user_server",
			"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_grabber",
		}
		for _, path in ipairs(stock_paths) do
			local resolved, resolve_err = resolve_candidate(path)
			helpers.assert_nil(resolved,
				"the helper resolver must never auto-spawn shared process " .. path)
			helpers.assert_true(type(resolve_err) == "string" and resolve_err ~= "")
		end
	end)

	helpers.it("rejects a symlink or resolver alias at the exact bundle path", function()
		local linked, linked_err = resolve_candidate(EXPECTED_HELPER, {
			link_attributes = { mode = "link", permissions = "rwxr-xr-x" },
		})
		helpers.assert_nil(linked)
		helpers.assert_true(type(linked_err) == "string" and linked_err ~= "")

		local aliased, aliased_err = resolve_candidate(EXPECTED_HELPER, {
			resolved_path = "/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements",
		})
		helpers.assert_nil(aliased)
		helpers.assert_true(type(aliased_err) == "string" and aliased_err ~= "")
	end)

	helpers.it("rejects a same-path executable whose file identity changed after launch", function()
		local replaced, replaced_err = resolve_candidate(EXPECTED_HELPER, {
			observed_inode = tonumber(EXPECTED_INODE) + 1,
		})
		helpers.assert_nil(replaced,
			"path equality must not authorize a replacement executable or hardlink")
		helpers.assert_true(type(replaced_err) == "string" and replaced_err ~= "")
	end)

	helpers.it("rejects the exact path when it is not executable", function()
		local resolved, resolve_err = resolve_candidate(EXPECTED_HELPER, {
			attributes = {
				mode = "file",
				permissions = "rw-r--r--",
				dev = tonumber(EXPECTED_DEVICE),
				ino = tonumber(EXPECTED_INODE),
			},
		})
		helpers.assert_nil(resolved)
		helpers.assert_true(type(resolve_err) == "string" and resolve_err ~= "")
	end)
end)
