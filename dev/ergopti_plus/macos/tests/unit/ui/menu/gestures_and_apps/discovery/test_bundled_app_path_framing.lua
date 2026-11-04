--- tests/unit/ui/menu/gestures_and_apps/discovery/test_bundled_app_path_framing.lua

--- ==============================================================================
--- MODULE: Bundled App Pathname Framing
--- DESCRIPTION:
--- Actual shell/find output and scratch pathnames exercise bundled-app and icon
--- discovery. Metadata/image ports only record arguments; no app is launched.
--- Hammerspoon 1.1.1 _coresetup.lua:250-259 uses io.popen plus read('*a'), which
--- preserves NUL. Apple BSD find/function.c f_print0 emits path followed by NUL.
--- ==============================================================================

local helpers = require("tests.helpers")
local OWNED = {
	"ui.menu.menu_apps", "infra.logger", "infra.paths", "infra.i18n",
	"infra.manifest_menu", "adapters.task_lifecycle", "infra.text_utils", "text_utils", "compat.utf8", "lfs",
}

--- Runs the native hs.execute transport shape without a login shell or conversion.
local function execute(command)
	local child = assert(io.popen(command, "r"))
	local output = child:read("*a")
	local ok, kind, code = child:close()
	return output, ok, kind, code
end

--- Owns only named scratch files and directories, restoring cold native imports.
local function with_apps(newline, scenario)
	local previous_lfs = rawget(_G, "lfs")
	local fs, files, directories = nil, {}, {}
	local ok, detail = xpcall(function()
		helpers.with_stub_scope(OWNED, function()
			fs = require("lfs")
			local root = os.tmpname()
			assert(os.remove(root)); assert(fs.mkdir(root)); directories[#directories + 1] = root
			local base = root .. "/Ergopti é O'Brien spaces" .. (newline and "\ncontinued" or "")
			assert(fs.mkdir(base)); directories[#directories + 1] = base
			assert(fs.mkdir(base .. "/apps")); directories[#directories + 1] = base .. "/apps"
			local f = { metadata = {}, images = {}, commands = {}, warnings = {} }
			function f.app(name, icon)
				local path = base .. "/apps/" .. name .. ".app"
				for _, directory in ipairs({ path, path .. "/Contents", path .. "/Contents/Resources" }) do
					assert(fs.mkdir(directory)); directories[#directories + 1] = directory
				end
				if icon then
					local filename = path .. "/Contents/Resources/" .. icon
					local file = assert(io.open(filename, "wb"))
					assert(file:write("recorded image boundary only")); assert(file:close())
					files[#files + 1] = filename
				end
				return path
			end
			local logger = helpers.make_logger_stub()
			logger.warn = function(_, format, ...) f.warnings[#f.warnings + 1] = string.format(format, ...) end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.paths"] = {}
			package.loaded["infra.i18n"] = {}
			package.loaded["infra.manifest_menu"] = {}
			package.loaded["adapters.task_lifecycle"] = { native = function() error("application launch forbidden") end }
			local menu = helpers.load_with_stubs("ui.menu.menu_apps", {
				fs = { attributes = fs.attributes },
				application = { infoForBundlePath = function(path)
					f.metadata[#f.metadata + 1] = path
					return nil -- Real native metadata may be unavailable; discovery keeps the basename.
				end },
				image = { imageFromPath = function(path) f.images[#f.images + 1] = path; return nil end },
				execute = function(command)
					f.commands[#f.commands + 1] = command
					local app_scan = command:find("-name '*.app'", 1, true) ~= nil
					local output, succeeded, kind, code = execute(command .. (app_scan and f.exit_failure and "; exit 9" or ""))
					if app_scan and f.output_transform then output = f.output_transform(output) end
					return output, succeeded, kind, code
				end,
			})
			function f.prime() menu.prime({ base_dir = base }) end
			scenario(f)
		end)
	end, debug.traceback)
	rawset(_G, "lfs", previous_lfs)
	local cleaned, cleanup_error = pcall(function()
		for index = #files, 1, -1 do assert(os.remove(files[index])) end
		for index = #directories, 1, -1 do assert(fs.rmdir(directories[index])) end
	end)
	assert(cleaned, cleanup_error)
	if not ok then error(detail, 0) end
end

helpers.describe("bundled application discovery preserves native pathname boundaries", function()
	for _, newline in ipairs({ false, true }) do
		helpers.it("preserves spaces, Unicode, apostrophe and newline=" .. tostring(newline), function()
			with_apps(newline, function(f)
				local path = f.app("App Cloner")
				f.prime()
				helpers.assert_eq(f.metadata, { path })
				helpers.assert_eq(#f.warnings, 0)
			end)
		end)
	end

	helpers.it("sorts several complete application paths and caches the successful discovery", function()
		with_apps(true, function(f)
			local last, first = f.app("Encryptor"), f.app("App Cloner")
			f.prime()
			helpers.assert_eq(f.metadata, { first, last })
			local count = #f.commands
			f.prime()
			helpers.assert_eq(f.metadata, { first, last })
			helpers.assert_eq(#f.commands, count, "cache hit must not enumerate again")
		end)
	end)

	helpers.it("preserves the exact icon pathname in a directory containing newline", function()
		with_apps(true, function(f)
			local path = f.app("App Cloner", "App\nIcon.icns")
			f.prime()
			helpers.assert_eq(f.metadata, { path })
			helpers.assert_eq(f.images[#f.images], path .. "/Contents/Resources/App\nIcon.icns")
		end)
	end)

	helpers.it("caches a genuinely empty successful enumeration", function()
		with_apps(false, function(f)
			f.prime(); f.prime()
			helpers.assert_eq(f.metadata, {})
			helpers.assert_eq(#f.commands, 1)
			helpers.assert_eq(#f.warnings, 0)
		end)
	end)

	for _, mode in ipairs({ "missing terminator", "partial second path", "leading empty", "interior empty", "read nil" }) do
		helpers.it("rejects " .. mode .. " before metadata and permits a complete retry", function()
			with_apps(false, function(f)
				local first = f.app("App Cloner")
				local second = mode == "partial second path" and f.app("Encryptor") or nil
				f.output_transform = function(output)
					if mode == "read nil" then return nil end
					if mode == "leading empty" then return "\0" .. output end
					if mode == "interior empty" then return output .. "\0" end
					return output:sub(1, -2)
				end
				f.prime()
				helpers.assert_eq(f.metadata, {}, "an incomplete stream cannot hydrate even its complete prefix")
				helpers.assert_eq(#f.warnings, 1)
				f.output_transform = nil
				f.prime()
				helpers.assert_eq(f.metadata, second and { first, second } or { first })
			end)
		end)
	end

	helpers.it("rejects real nonzero exit with output and retries without poisoning the cache", function()
		with_apps(false, function(f)
			local path = f.app("App Cloner")
			f.exit_failure = true
			f.prime(); f.prime()
			helpers.assert_eq(f.metadata, {})
			helpers.assert_eq(#f.commands, 2)
			helpers.assert_eq(#f.warnings, 1, "repeat operational refusals remain bounded")
			f.exit_failure = false
			f.prime()
			helpers.assert_eq(f.metadata, { path })
		end)
	end)
end)
