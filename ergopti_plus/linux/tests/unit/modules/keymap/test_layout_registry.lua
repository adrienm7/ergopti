--- tests/unit/modules/keymap/test_layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Manager (Linux client)
--- DESCRIPTION:
--- Linux installs a registry layout by converting its verified .keylayout on
--- the device and installing the result in the user XKB tree
--- (layout-registry-convert). These tests replay the layout manager's
--- operations through injected collaborators with the real registry files: an
--- in-memory file system, a registry served from a table, and Python children
--- that only record their argument vectors and answer scripted results. They
--- pin installation, update, uninstallation, activation, the refusal of a file
--- that does not match its index, the offline installation of the Ergopti
--- shipped with the package, and the translated explanation of a missing
--- python3. The digest collaborator answers from a table of known contents.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"
local CHANNEL = require("modules.updater.manager").installed_channel()
local INDEX_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/" .. CHANNEL .. "/static/layouts/registry/index.json"
local ERGOL_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/" .. CHANNEL .. "/static/layouts/registry/ergol/ergol.keylayout"
local PYTHON_MESSAGE = "translated: layouts.linux_needs_python"
local LOCAL_DIR = "/cfg/layouts/"
local SHIPPED_DIR = "/pkg/linux/static/layouts/registry/"
local CONVERTER = "/pkg/linux/xkb_generation/keylayout_to_xkb.py"
local INSTALLER = "/pkg/linux/xkb_installation/user_layout_installer.py"

--- Reads a file of the repository registry byte for byte.
--- @param rel string
--- @return string
local function registry_file(rel)
	local handle = assert(io.open(REGISTRY_DIR .. rel, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local INDEX_TEXT = registry_file("index.json")
local INDEX = Json.decode(INDEX_TEXT)

--- The index entry of one layout.
--- @param id string
--- @return table
local function entry_of(id)
	for _, entry in ipairs(INDEX.layouts) do
		if entry.id == id then return entry end
	end
	error("no entry " .. id)
end

local OK_RUN = { exit_code = 0, stdout = "", stderr = "" }
local INSTALLED_RUN = { exit_code = 0, stdout = '{"ok": true, "verified": true, "detail": "installed"}\n', stderr = "" }

--- Builds the layout manager with in-memory collaborators.
--- @param options table { served, files, runs }
--- @return table module, table deps, table state
local function manager(options)
	options = options or {}
	local LayoutRegistry = helpers.load_module("modules.keymap.layout_registry")
	LayoutRegistry._reset()
	local settings = assert(LayoutRegistry.settings())
	local digests = {}
	for _, entry in ipairs(INDEX.layouts) do
		digests[registry_file(entry.file)] = entry.sha256
		for _, file in ipairs(entry.extension.files) do digests[registry_file(file.file)] = file.sha256 end
	end
	local state = { requests = {}, files = {}, runs = {}, deleted = {} }
	for path, text in pairs(options.files or {}) do state.files[path] = text end
	local runs = options.runs or {}
	local served = options.served or {}
	if type(served) == "table" and served[INDEX_URL] then
		for _, entry in ipairs(INDEX.layouts) do
			for _, file in ipairs(entry.extension.files) do
				local url = INDEX_URL:gsub("index%.json$", "") .. file.file
				if served[url] == nil then served[url] = registry_file(file.file) end
			end
		end
	end
	local deps = {
		settings = settings,
		transport = {
			get = function(url, headers, _timeout_ms, callback)
				state.requests[#state.requests + 1] = { url = url, headers = headers }
				if served == "offline" then callback(0, "", "could not resolve host", nil) return end
				if served[url] then callback(200, served[url], nil, { etag = '"e1"' }) else callback(404, "", "HTTP 404", {}) end
			end,
			sha256 = function(text, callback) callback(digests[text] or string.rep("0", 64), nil) end,
		},
		decode_json = Json.decode,
		encode_json = Json.encode,
		read = function(path) return state.files[path] end,
		write = function(path, content) state.files[path] = content; return true end,
		delete = function(path) state.files[path] = nil; state.deleted[#state.deleted + 1] = path; return true end,
		exists = function(path) return state.files[path] ~= nil end,
		ensure_dir = function() return true end,
		run = function(program, args, run_options, callback)
			state.runs[#state.runs + 1] = { program = program, args = args, timeout_ms = run_options.timeout_ms }
			callback(assert(table.remove(runs, 1), "unexpected process run"))
			return true
		end,
		local_dir = LOCAL_DIR,
		bundled_dir = options.no_shipped and nil or SHIPPED_DIR,
		converter = CONVERTER,
		installer = INSTALLER,
		keycodes = "/pkg/_shared/modules/layouts/mac_keycodes.json",
		translate = function(key) return "translated: " .. key end,
	}
	return LayoutRegistry, deps, state
end

--- Runs one operation and returns its single terminal result.
--- @param call function call(on_done)
--- @return table { ok, detail, extra, user_message }
local function run(call)
	local result = { calls = 0 }
	call(function(ok, detail, extra, user_message)
		result.calls = result.calls + 1
		result.ok, result.detail, result.extra, result.user_message = ok, detail, extra, user_message
	end)
	helpers.assert_eq(result.calls, 1, "on_done must be called exactly once")
	return result
end

--- The value following a flag in an argument vector.
--- @param args table
--- @param flag string
--- @return string|nil
local function arg_value(args, flag)
	for index, value in ipairs(args) do
		if value == flag then return args[index + 1] end
	end
	return nil
end

--- The shipped registry: its index and every layout, under SHIPPED_DIR.
--- @return table
local function shipped_files()
	local files = { [SHIPPED_DIR .. "index.json"] = INDEX_TEXT }
	for _, entry in ipairs(INDEX.layouts) do
		files[SHIPPED_DIR .. entry.file] = registry_file(entry.file)
		for _, file in ipairs(entry.extension.files) do files[SHIPPED_DIR .. file.file] = registry_file(file.file) end
	end
	return files
end

helpers.describe("layout manager (Linux): installing", function()
	helpers.it("makes committed layout packs visible before user overrides", function()
		local Paths = require("infra.paths")
		local saved_registry = package.loaded["modules.keymap.layout_registry"]
		local saved_config = package.loaded["infra.config_paths"]
		package.loaded["modules.keymap.layout_registry"] = {
			extension_roots = function() return { "/committed/layout/generation" } end,
			shipped_extension_root = function() return { pack = "/driver/layouts/registry/ergopti" } end,
		}
		package.loaded["infra.config_paths"] = {
			home = function() return "/private/user" end,
			get_config_dir = function() return "/private/xdg/ergopti" end,
		}
		local ok, roots = pcall(Paths.extension_roots)
		package.loaded["modules.keymap.layout_registry"] = saved_registry
		package.loaded["infra.config_paths"] = saved_config
		helpers.assert_true(ok, tostring(roots))
		helpers.assert_eq(roots[#roots - 2], "/committed/layout/generation")
		helpers.assert_eq(roots[#roots - 1], { pack = "/driver/layouts/registry/ergopti" },
			"the shipped Ergopti extension follows the installed generations (ergopti-hotstrings-ext)")
		helpers.assert_eq(roots[#roots], "/private/xdg/ergopti/extensions",
			"the user root follows the effective configuration folder, as on macOS and Windows")
	end)

	helpers.it("still starts with the other packs when the installed record is damaged (config-outdated-installed)", function()
		local Paths = require("infra.paths")
		local saved_registry = package.loaded["modules.keymap.layout_registry"]
		local saved_config = package.loaded["infra.config_paths"]
		local saved_logger = package.loaded["logger.shim"]
		local errors = {}
		local recorder = helpers.make_logger_stub()
		recorder.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["modules.keymap.layout_registry"] = {
			extension_roots = function() error("the installed-layouts record is not valid JSON", 0) end,
			shipped_extension_root = function() return { pack = "/driver/layouts/registry/ergopti" } end,
		}
		package.loaded["infra.config_paths"] = {
			home = function() return "/private/user" end,
			get_config_dir = function() return "/private/xdg/ergopti" end,
		}
		package.loaded["logger.shim"] = recorder
		local Fresh = helpers.load_module("infra.paths")
		local ok, roots = pcall(function()
			Fresh.extension_roots()
			return Fresh.extension_roots()
		end)
		package.loaded["modules.keymap.layout_registry"] = saved_registry
		package.loaded["infra.config_paths"] = saved_config
		package.loaded["logger.shim"] = saved_logger
		package.loaded["infra.paths"] = Paths
		helpers.assert_true(ok, "a damaged record never stops the daemon: " .. tostring(roots))
		helpers.assert_eq(roots[#roots - 1], { pack = "/driver/layouts/registry/ergopti" })
		helpers.assert_eq(roots[#roots], "/private/xdg/ergopti/extensions")
		helpers.assert_eq(#errors, 1, "the skipped record is reported once, never a silent success")
		helpers.assert_true(errors[1]:find("not valid JSON", 1, true) ~= nil, errors[1])
	end)

	helpers.it("rereads the checkout catalogue without HTTP or stale cache (layout-catalogue-local)", function()
		local registry, deps, state = manager({ files = shipped_files() })
		deps.local_source = true
		local outcomes = {}
		local function refreshed(outcome) outcomes[#outcomes + 1] = outcome end
		registry.refresh(refreshed, deps)
		helpers.assert_eq(outcomes[1].source, "bundled")
		helpers.assert_eq(outcomes[1].error, nil)
		state.files[SHIPPED_DIR .. "index.json"] = '{"layouts":[]}'
		registry.refresh(refreshed, deps)
		helpers.assert_eq(#outcomes[2].index.layouts, 0, "refresh must reread the edited local index")
		state.files[SHIPPED_DIR .. "index.json"] = "invalid"
		registry.refresh(refreshed, deps)
		helpers.assert_eq(#outcomes, 3)
		helpers.assert_eq(outcomes[3].source, "none")
		helpers.assert_eq(outcomes[3].error.code, "invalid_index")
		helpers.assert_eq(#state.requests, 0, "a local index must not request the unpublished remote registry")
		helpers.assert_eq(state.files[LOCAL_DIR .. "index.json"], nil)
	end)

	helpers.it("names the shared defaults file it cannot decode (layout-registry-convert)", function()
		-- The shared json.lua answers nil to invalid JSON instead of raising, so a
		-- reader that only checks the pcall status loses the reason.
		local FileSystem = require("adapters.file_system")
		local LayoutRegistry = helpers.load_module("modules.keymap.layout_registry")
		local original_read = FileSystem.read
		local served = 0
		FileSystem.read = function(path)
			if type(path) == "string" and path:find("modules/layouts/defaults.json", 1, true) then
				served = served + 1
				return "{ not json"
			end
			return original_read(path)
		end
		local called, settings, err = pcall(LayoutRegistry.settings)
		FileSystem.read = original_read
		helpers.assert_true(called, "settings() must report, not raise: " .. tostring(settings))
		helpers.assert_eq(served, 1, "the malformed defaults file must be the one read")
		helpers.assert_nil(settings)
		helpers.assert_contains(tostring(err), "modules/layouts/defaults.json is not valid JSON")
	end)

	helpers.it("converts, installs and records a downloaded layout (layout-registry-convert)", function()
		local layout = registry_file("ergol/ergol.keylayout")
		local LayoutRegistry, deps, state = manager({
			served = { [INDEX_URL] = INDEX_TEXT, [ERGOL_URL] = layout },
			runs = { OK_RUN, OK_RUN, OK_RUN, INSTALLED_RUN },
		})
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, "the installation must succeed: " .. tostring(result.extra))
		helpers.assert_eq(result.detail.source, "network")
		helpers.assert_true(result.detail.verified)
		helpers.assert_eq(#state.requests, 2 + #entry_of("ergol").extension.files, "the index, layout and complete extension")
		helpers.assert_eq(state.files[LOCAL_DIR .. "index.json"], INDEX_TEXT, "the refreshed index is cached")
		helpers.assert_eq(state.files[LOCAL_DIR .. "index.etag"], '"e1"')
		helpers.assert_true(state.files[LOCAL_DIR .. "ergol.keylayout"] == layout, "the verified bytes are converted")
		helpers.assert_eq(#state.runs, 4, "a version probe and the conversion, then a probe and the installer")
		local convert = state.runs[2]
		helpers.assert_eq(convert.args[1], CONVERTER)
		helpers.assert_eq(arg_value(convert.args, "--keylayout"), LOCAL_DIR .. "ergol.keylayout")
		helpers.assert_eq(arg_value(convert.args, "--convention"), "ansi", "Ergo-L numbers its keys the ANSI way")
		helpers.assert_eq(arg_value(convert.args, "--index"), LOCAL_DIR .. "index.json")
		helpers.assert_eq(arg_value(convert.args, "--out"), LOCAL_DIR .. "ergol")
		local install = state.runs[4]
		helpers.assert_eq(install.args[1], INSTALLER)
		helpers.assert_eq(install.args[2], "install")
		helpers.assert_eq(arg_value(install.args, "--layout-id"), "ergol")
		helpers.assert_eq(arg_value(install.args, "--display-name"), entry_of("ergol").name)
		helpers.assert_eq(arg_value(install.args, "--source-dir"), LOCAL_DIR .. "ergol")
		helpers.assert_eq(arg_value(install.args, "--language"), "fr")
		for _, child in ipairs(state.runs) do
			for index, value in ipairs(child.args) do
				helpers.assert_type(value, "string", "argument " .. index .. " must be a string")
			end
		end
		local record = Json.decode(state.files[LOCAL_DIR .. "installed.json"])
		helpers.assert_eq(record.layouts.ergol.sha256, entry_of("ergol").sha256)
		helpers.assert_eq(LayoutRegistry.snapshot(deps).installed.ergol.version, entry_of("ergol").version)
	end)

	helpers.it("installs the Ergopti shipped with the package while offline (layout-registry-convert)", function()
		local LayoutRegistry, deps, state = manager({
			served = "offline",
			files = shipped_files(),
			runs = { OK_RUN, OK_RUN, OK_RUN, INSTALLED_RUN },
		})
		local directories = {}
		deps.ensure_dir = function(path) directories[path] = true return true end
		deps.write = function(path, content)
			if not directories[path:match("^(.*)/[^/]+$")] then return false, "parent missing" end
			state.files[path] = content
			return true
		end
		local result = run(function(done) LayoutRegistry.install("ergopti", done, deps) end)
		helpers.assert_true(result.ok, "the shipped Ergopti must install offline: " .. tostring(result.extra))
		helpers.assert_eq(result.detail.source, "bundled")
		helpers.assert_eq(#state.requests, 1, "only the index refresh is attempted")
		helpers.assert_eq(arg_value(state.runs[2].args, "--index"), SHIPPED_DIR .. "index.json",
			"the XKB hints come from the index the entry was taken from")
		local snapshot = LayoutRegistry.snapshot(deps)
		helpers.assert_eq(snapshot.source, "bundled")
		helpers.assert_eq(snapshot.error.code, "offline")
	end)

	helpers.it("updates an installed layout to the version the index describes (layout-registry-convert)", function()
		local old = Json.decode(Json.encode(entry_of("ergol")))
		old.version, old.sha256 = "1.0.0", string.rep("1", 64)
		local LayoutRegistry, deps, state = manager({
			served = { [INDEX_URL] = INDEX_TEXT, [ERGOL_URL] = registry_file("ergol/ergol.keylayout") },
			files = {
				[LOCAL_DIR .. "installed.json"] = Json.encode({ schema_version = 1, layouts = { ergol = old } }),
				[LOCAL_DIR .. "ergol.keylayout"] = "old bytes",
			},
			runs = { OK_RUN, OK_RUN, OK_RUN, INSTALLED_RUN },
		})
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		local record = Json.decode(state.files[LOCAL_DIR .. "installed.json"])
		helpers.assert_eq(record.layouts.ergol.version, entry_of("ergol").version)
	end)

	helpers.it("writes and runs nothing for a layout that does not match its index (layout-registry-convert)", function()
		local tampered = registry_file("ergol/ergol.keylayout"):gsub('output="q"', 'output="z"', 1)
		local LayoutRegistry, deps, state = manager({
			served = { [INDEX_URL] = INDEX_TEXT, [ERGOL_URL] = tampered },
		})
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_DOWNLOAD)
		helpers.assert_contains(result.extra, "checksum")
		helpers.assert_nil(state.files[LOCAL_DIR .. "ergol.keylayout"])
		helpers.assert_eq(#state.runs, 0)
	end)

	helpers.it("reports an offline download it cannot serve from the package (layout-registry-convert)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", no_shipped = true })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_DOWNLOAD)
		helpers.assert_contains(result.extra, "could not resolve host")
		helpers.assert_eq(#state.runs, 0)
	end)

	helpers.it("explains a missing or too old python3 in the user's language (layout-registry-convert)", function()
		for _, probe in ipairs({
			{ exit_code = -1, stdout = "", stderr = "", error = "cannot start python3: ENOENT", not_found = true },
			{ exit_code = 3, stdout = "", stderr = "", error = "python3 exited with code 3" },
		}) do
			local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files(), runs = { probe } })
			local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
			helpers.assert_true(result.ok == false)
			helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_PYTHON)
			helpers.assert_eq(result.user_message, PYTHON_MESSAGE)
			helpers.assert_eq(#state.runs, 1, "nothing runs without an interpreter")
			helpers.assert_nil(state.files[LOCAL_DIR .. "installed.json"])
		end
	end)

	helpers.it("writes and runs nothing while the installed record is unreadable (layout-install-record-first)", function()
		-- A layout installed before the record fails is in the user XKB tree
		-- with no record: the layout manager then neither lists nor removes it.
		local files = shipped_files()
		files[LOCAL_DIR .. "installed.json"] = "{ damaged"
		local LayoutRegistry, deps, state = manager({ served = "offline", files = files })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_RECORD)
		helpers.assert_eq(#state.runs, 0, "nothing is converted or installed")
		helpers.assert_nil(state.files[LOCAL_DIR .. "ergol.keylayout"], "no local copy is written")
		helpers.assert_eq(state.files[LOCAL_DIR .. "installed.json"], "{ damaged", "the damaged record is left as it is")
		helpers.assert_nil(LayoutRegistry.snapshot(deps).busy, "the operation slot is released")
	end)

	helpers.it("reports the installer's own refusal and records nothing (layout-registry-convert)", function()
		local LayoutRegistry, deps, state = manager({
			served = "offline",
			files = shipped_files(),
			runs = { OK_RUN, OK_RUN, OK_RUN, { exit_code = 3, error = "exit 3", stderr = "",
				stdout = '{"ok": false, "verified": null, "detail": "rules/evdev is your own file", "code": "conflict"}\n' } },
		})
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_FOREIGN_FILE, "a file the user owns is a conflict")
		helpers.assert_contains(result.extra, "rules/evdev is your own file")
		helpers.assert_nil(state.files[LOCAL_DIR .. "installed.json"])
	end)
end)

helpers.describe("layout manager (Linux): uninstalling and activating", function()
	--- A manager with Ergo-L installed.
	local function with_ergol(runs)
		return manager({
			files = {
				[LOCAL_DIR .. "installed.json"] = Json.encode({ schema_version = 1, layouts = { ergol = entry_of("ergol") } }),
				[LOCAL_DIR .. "ergol.keylayout"] = registry_file("ergol/ergol.keylayout"),
				[LOCAL_DIR .. "ergol/ergol.xkb"] = "symbols",
			},
			runs = runs,
		})
	end

	helpers.it("removes the layout from the user tree, then its files and record (layout-registry-convert)", function()
		local LayoutRegistry, deps, state = with_ergol({ OK_RUN, INSTALLED_RUN })
		local result = run(function(done) LayoutRegistry.uninstall("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_eq(state.runs[2].args[2], "uninstall")
		helpers.assert_eq(arg_value(state.runs[2].args, "--layout-id"), "ergol")
		helpers.assert_nil(state.files[LOCAL_DIR .. "ergol.keylayout"])
		helpers.assert_nil(state.files[LOCAL_DIR .. "ergol/ergol.xkb"])
		helpers.assert_nil(Json.decode(state.files[LOCAL_DIR .. "installed.json"]).layouts.ergol)
	end)

	helpers.it("refuses to uninstall what it did not install (layout-registry-convert)", function()
		local LayoutRegistry, deps, state = with_ergol({})
		local result = run(function(done) LayoutRegistry.uninstall("ergopti", done, deps) end)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_NOT_INSTALLED)
		helpers.assert_eq(#state.runs, 0)
	end)

	helpers.it("shows the shipped catalogue as such before the first refresh (layout-manager-shipped-first)", function()
		local LayoutRegistry, deps = manager({ files = shipped_files() })
		local snapshot = LayoutRegistry.snapshot(deps)
		helpers.assert_true(type(snapshot.index) == "table", "the index shipped with the package is listed before any refresh")
		helpers.assert_eq(snapshot.source, "bundled", "the page must not call the shipped catalogue no catalogue")
	end)

	helpers.it("activates an installed layout through the installer (layout-registry-convert)", function()
		local LayoutRegistry, deps, state = with_ergol({ OK_RUN, INSTALLED_RUN })
		local result = run(function(done) LayoutRegistry.select("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_eq(state.runs[2].args[2], "activate")
		helpers.assert_eq(LayoutRegistry.snapshot(deps).active, "ergol")
	end)

	helpers.it("keeps the other layouts when one installed entry is outdated (config-outdated-installed)", function()
		local stale = { id = "ergopti_v1", version = "1.0" }
		local LayoutRegistry, deps, state = manager({
			files = {
				[LOCAL_DIR .. "installed.json"] = Json.encode({ schema_version = 1,
					layouts = { ergol = entry_of("ergol"), ergopti_v1 = stale } }),
				[LOCAL_DIR .. "ergol.keylayout"] = registry_file("ergol/ergol.keylayout"),
			},
			runs = { OK_RUN, INSTALLED_RUN },
		})
		local warnings = {}
		local recorder = helpers.make_logger_stub()
		recorder.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local previous_logger = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = recorder
		require("config_outdated").reset_for_tests()
		local ok, err = pcall(function()
			local roots = LayoutRegistry.extension_roots(deps)
			helpers.assert_eq(#roots, 1, "the valid layout's extension still loads at startup")
			helpers.assert_true(LayoutRegistry.snapshot(deps).installed.ergol ~= nil, "the valid layout stays installed")
			helpers.assert_eq(#warnings, 1, table.concat(warnings, "\n"))
			helpers.assert_true(warnings[1]:find("'layouts.ergopti_v1' in '" .. LOCAL_DIR .. "installed.json'", 1, true)
				~= nil, warnings[1])
			local result = run(function(done) LayoutRegistry.uninstall("ergol", done, deps) end)
			helpers.assert_true(result.ok, tostring(result.extra))
			helpers.assert_eq(Json.decode(state.files[LOCAL_DIR .. "installed.json"]).layouts.ergopti_v1, stale,
				"a write keeps the entry the user was told to fix")
		end)
		package.loaded["logger.shim"] = previous_logger
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("layout manager (Linux): what the package ships", function()
	helpers.it("finds the converter, the installer and the registry where package and checkout put them (layout-registry-convert)", function()
		local LayoutRegistry = helpers.load_module("modules.keymap.layout_registry")
		local settings = assert(LayoutRegistry.settings())
		local present = {
			["/pkg/linux/xkb_generation/keylayout_to_xkb.py"] = true,
			["/pkg/linux/xkb_installation/user_layout_installer.py"] = true,
			["/pkg/linux/static/layouts/registry/index.json"] = true,
		}
		local function exists(path) return present[path] == true end
		helpers.assert_eq(LayoutRegistry.converter_path("/pkg/linux", exists), CONVERTER)
		helpers.assert_eq(LayoutRegistry.installer_path("/pkg/linux", exists), INSTALLER)
		helpers.assert_eq(LayoutRegistry.bundled_dir("/pkg/linux", settings, exists), SHIPPED_DIR)
		local checkout = {
			["/repo/static/ergopti_plus/linux/../../ergopti/linux/xkb_installation/user_layout_installer.py"] = true,
			["/repo/static/ergopti_plus/linux/../../../static/layouts/registry/index.json"] = true,
		}
		local function in_checkout(path) return checkout[path] == true end
		helpers.assert_contains(LayoutRegistry.installer_path("/repo/static/ergopti_plus/linux", in_checkout),
			"/ergopti/linux/xkb_installation/user_layout_installer.py")
		helpers.assert_contains(LayoutRegistry.bundled_dir("/repo/static/ergopti_plus/linux", settings, in_checkout),
			"/static/layouts/registry/")
		helpers.assert_nil(LayoutRegistry.installer_path("/nowhere", function() return false end))
	end)
end)

require("test.layout_installed_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	probe_receipt = OK_RUN,
	install_receipt = INSTALLED_RUN,
})

require("test.layout_installed_update_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	probe_receipt = OK_RUN,
	install_receipt = INSTALLED_RUN,
})

require("test.layout_installed_extension_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	probe_receipt = OK_RUN,
	install_receipt = INSTALLED_RUN,
})
