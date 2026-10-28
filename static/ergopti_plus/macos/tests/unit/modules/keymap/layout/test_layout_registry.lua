--- tests/unit/modules/keymap/layout/test_layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Manager (macOS client)
--- DESCRIPTION:
--- macOS installs a registry layout by placing its verified .keylayout,
--- unchanged, in ~/Library/Keyboard Layouts and adding it to the enabled input
--- sources (layout-registry-install). These tests replay the layout manager's
--- operations through injected collaborators with the real registry files: an
--- in-memory file system, a registry served from a table, and input-source
--- calls that only record what they were asked. They pin installation,
--- update, uninstallation, the refusal of a file that does not match its
--- index, the offline installation of the Ergopti shipped with the app, and
--- the refusal to install a layout an Ergopti bundle already provides.
--- The digest collaborator answers from a table of known contents: the real
--- SHA-256 is the crypto adapter's job, the refusal of a mismatch is this one.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"
local CHANNEL = require("modules.updater").installed_channel()
local INDEX_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/" .. CHANNEL .. "/static/layouts/registry/index.json"
local ERGOL_URL = "https://raw.githubusercontent.com/adrienm7/ergopti/" .. CHANNEL .. "/static/layouts/registry/ergol/ergol.keylayout"
local LOCAL_DIR = "/cfg/layouts/"
local LAYOUTS_DIR = "/home/Library/Keyboard Layouts/"
local SHIPPED_DIR = "/app/static/layouts/registry/"

--- Reads a file of the repository registry byte for byte.
--- @param rel string
--- @return string
local function registry_file(rel)
	local handle = assert(io.open(REGISTRY_DIR .. rel, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Replaces the first literal occurrence of old in text.
--- @param text string
--- @param old string
--- @param new string
--- @return string
local function tamper(text, old, new)
	local first, last = text:find(old, 1, true)
	assert(first, "tamper target not found: " .. old)
	return text:sub(1, first - 1) .. new .. text:sub(last + 1)
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

--- Builds the layout manager with in-memory collaborators.
--- @param options table { served, files, bundle_names, active }
--- @return table module, table deps, table state
local function manager(options)
	options = options or {}
	local LayoutRegistry = helpers.load_with_stubs("modules.keymap.layout_registry")
	LayoutRegistry._reset()
	local settings = assert(LayoutRegistry.settings())
	local digests = {}
	for _, entry in ipairs(INDEX.layouts) do
		digests[registry_file(entry.file)] = entry.sha256
		for _, file in ipairs(entry.extension.files) do digests[registry_file(file.file)] = file.sha256 end
	end
	local state = { requests = {}, files = {}, enabled = {}, disabled = {}, selected = {}, deleted = {},
		live_reads = {}, confirms = {}, pending = {} }
	for path, text in pairs(options.files or {}) do state.files[path] = text end
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
				if served == "offline" then callback(0, "", "could not connect", nil) return end
				local body = served[url]
				if body then callback(200, body, nil, { ETag = '"e1"' }) else callback(404, "", "HTTP 404", {}) end
			end,
			sha256 = function(text, callback) callback(digests[text] or string.rep("0", 64), nil) end,
		},
		decode_json = Json.decode,
		encode_json = Json.encode,
		read = function(path) return state.files[path] end,
		write = function(path, content) state.files[path] = content; return true end,
		delete = function(path) state.files[path] = nil; state.deleted[#state.deleted + 1] = path; return true end,
		exists = function(path) return state.files[path] ~= nil end,
		prepare_parent = function() return true end,
		local_dir = LOCAL_DIR,
		layouts_dir = LAYOUTS_DIR,
		bundled_dir = SHIPPED_DIR,
		enable_source = function(path, label, on_done)
			state.enabled[#state.enabled + 1] = { path = path, label = label }
			on_done(options.enable_fails ~= true, "OK", options.enable_fails and "process_failed" or nil)
			return true
		end,
		disable_source = function(name, label, on_done)
			state.disabled[#state.disabled + 1] = { name = name, label = label }
			on_done(true, "OK", nil)
			return true
		end,
		select_source = function(localised, name, on_done)
			state.selected[#state.selected + 1] = { localised = localised, name = name }
			on_done(true, "OK", nil)
			return true
		end,
		active_sources = function() return options.active or {} end,
		-- A fresh process sees a listed layout on at once (probe v5, P5) unless
		-- the case says otherwise.
		confirm_source = function(name, confirm_options, on_done)
			state.live_reads[#state.live_reads + 1] = name
			state.confirms[#state.confirms + 1] = confirm_options
			if options.live_unreadable then on_done(false, nil, "live_state_unreadable") return true end
			on_done(true, { listed = true, enabled = options.pending_logout ~= true }, nil)
			return true
		end,
		pending = {
			record = function(id, name) state.pending[id] = { keyboard_name = name, select = false }; return true end,
			request_select = function(id)
				if state.pending[id] == nil then return false end
				state.pending[id].select = true
				return true
			end,
			forget = function(id) state.pending[id] = nil; return true end,
		},
		bundle_names = function() return options.bundle_names or {} end,
	}
	return LayoutRegistry, deps, state
end

--- Runs one operation and returns its single terminal result.
--- @param call function call(on_done)
--- @return table { ok, detail, extra, calls }
local function run(call)
	local result = { calls = 0 }
	call(function(ok, detail, extra)
		result.calls = result.calls + 1
		result.ok, result.detail, result.extra = ok, detail, extra
	end)
	helpers.assert_eq(result.calls, 1, "on_done must be called exactly once")
	return result
end

--- The shipped registry: its index and every layout file, under SHIPPED_DIR.
--- @return table
local function shipped_files()
	local files = { [SHIPPED_DIR .. "index.json"] = INDEX_TEXT }
	for _, entry in ipairs(INDEX.layouts) do
		for _, file in ipairs(entry.extension.files) do files[SHIPPED_DIR .. file.file] = registry_file(file.file) end
	end
	return files
end

--- The installed record as the module wrote it.
--- @param state table
--- @return table
local function record(state)
	return Json.decode(state.files[LOCAL_DIR .. "installed.json"])
end

helpers.describe("layout manager (macOS): installing", function()
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

	helpers.it("keeps extension content unavailable after a publication failure (layout-extension)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files() })
		local write = deps.write
		deps.write = function(path, text)
			if path:find("/extensions/", 1, true) then return false, "disk full" end
			return write(path, text)
		end
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(not result.ok)
		helpers.assert_eq(#LayoutRegistry.extension_roots(deps), 0)
		helpers.assert_nil(state.files[LOCAL_DIR .. "installed.json"])
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergol.keylayout"])
	end)

	helpers.it("installs a downloaded layout, enables it and records it last (layout-registry-install)", function()
		local LayoutRegistry, deps, state = manager({
			served = { [INDEX_URL] = INDEX_TEXT, [ERGOL_URL] = registry_file("ergol/ergol.keylayout") },
		})
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, "the installation must succeed: " .. tostring(result.extra))
		helpers.assert_eq(result.detail.path, LAYOUTS_DIR .. "ergol.keylayout")
		helpers.assert_eq(result.detail.source, "network")
		helpers.assert_true(result.detail.enabled)
		helpers.assert_eq(#state.requests, 2 + #entry_of("ergol").extension.files, "the index, layout and verified extension")
		helpers.assert_true(state.files[LAYOUTS_DIR .. "ergol.keylayout"] == registry_file("ergol/ergol.keylayout"),
			"the installed file is the registry file byte for byte")
		helpers.assert_true(state.files[LOCAL_DIR .. "ergol.keylayout"] == registry_file("ergol/ergol.keylayout"))
		helpers.assert_eq(state.files[LOCAL_DIR .. "index.json"], INDEX_TEXT, "the refreshed index is cached")
		helpers.assert_eq(state.files[LOCAL_DIR .. "index.etag"], '"e1"', "with the ETag it was served with")
		helpers.assert_eq(record(state).layouts.ergol.sha256, entry_of("ergol").sha256)
		local roots = LayoutRegistry.extension_roots(deps)
		helpers.assert_eq(#roots, 1)
		helpers.assert_eq(state.files[roots[1] .. "/ergol/manifest.toml"], registry_file("ergol/manifest.toml"))
		helpers.assert_nil(state.files["/cfg/config.toml"], "installation does not persist enable preferences")
		helpers.assert_eq(state.enabled[1].path, LAYOUTS_DIR .. "ergol.keylayout")
		local snapshot = LayoutRegistry.snapshot(deps)
		helpers.assert_eq(snapshot.installed.ergol.version, entry_of("ergol").version)
		helpers.assert_nil(snapshot.busy, "the operation slot is released")
	end)

	helpers.it("installs the Ergopti shipped with the app while offline (layout-registry-install)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files() })
		local result = run(function(done) LayoutRegistry.install("ergopti_plus", done, deps) end)
		helpers.assert_true(result.ok, "the shipped Ergopti must install offline: " .. tostring(result.extra))
		helpers.assert_eq(result.detail.source, "bundled")
		helpers.assert_eq(#state.requests, 1, "only the index refresh is attempted")
		helpers.assert_true(state.files[LAYOUTS_DIR .. "ergopti_plus.keylayout"]
			== registry_file("ergopti_plus/ergopti_plus.keylayout"))
		local snapshot = LayoutRegistry.snapshot(deps)
		helpers.assert_eq(snapshot.source, "bundled")
		helpers.assert_eq(snapshot.error.code, "offline", "the snapshot says why the registry was not read")
	end)

	helpers.it("updates an installed layout to the version the index describes (layout-registry-install)", function()
		local old = Json.decode(Json.encode(entry_of("ergol")))
		old.version, old.sha256 = "1.0.0", string.rep("1", 64)
		local installed = Json.encode({ schema_version = 1, layouts = { ergol = old } })
		local LayoutRegistry, deps, state = manager({
			served = { [INDEX_URL] = INDEX_TEXT, [ERGOL_URL] = registry_file("ergol/ergol.keylayout") },
			files = {
				[LOCAL_DIR .. "installed.json"] = installed,
				[LAYOUTS_DIR .. "ergol.keylayout"] = "old bytes",
			},
		})
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_eq(record(state).layouts.ergol.version, entry_of("ergol").version)
		helpers.assert_eq(record(state).layouts.ergol.sha256, entry_of("ergol").sha256)
		helpers.assert_true(state.files[LAYOUTS_DIR .. "ergol.keylayout"] == registry_file("ergol/ergol.keylayout"))
	end)

	helpers.it("refuses a layout that does not match its index and writes nothing (layout-registry-install)", function()
		local LayoutRegistry, deps, state = manager({
			served = {
				[INDEX_URL] = INDEX_TEXT,
				[ERGOL_URL] = tamper(registry_file("ergol/ergol.keylayout"), 'output="q"', 'output="z"'),
			},
		})
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_DOWNLOAD)
		helpers.assert_contains(result.extra, "checksum")
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergol.keylayout"], "an unverified layout never reaches the disk")
		helpers.assert_nil(state.files[LOCAL_DIR .. "installed.json"], "nor the record")
		helpers.assert_eq(#state.enabled, 0)
	end)

	helpers.it("reports an offline download it cannot serve from the app (layout-registry-install)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline" })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_DOWNLOAD)
		helpers.assert_contains(result.extra, "could not connect")
		helpers.assert_eq(#state.enabled, 0)
	end)

	helpers.it("refuses a layout an installed Ergopti bundle already provides (layout-registry-install)", function()
		local LayoutRegistry, deps, state = manager({
			served = "offline",
			files = shipped_files(),
			bundle_names = { [entry_of("ergopti").keyboard_name] = true },
		})
		local result = run(function(done) LayoutRegistry.install("ergopti", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_PROVIDED_BY_BUNDLE)
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergopti.keylayout"])
		helpers.assert_eq(LayoutRegistry.snapshot(deps).provided.ergopti, "bundle")
	end)

	helpers.it("never overwrites a layout file it did not install (layout-registry-install)", function()
		local files = shipped_files()
		files[LAYOUTS_DIR .. "ergol.keylayout"] = "my own layout"
		local LayoutRegistry, deps, state = manager({ served = "offline", files = files })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_FOREIGN_FILE)
		helpers.assert_eq(state.files[LAYOUTS_DIR .. "ergol.keylayout"], "my own layout")
	end)

	helpers.it("writes nothing while the installed record is unreadable (layout-install-record-first)", function()
		-- A layout written before the record fails stays unrecorded in the
		-- user's layouts folder: every later installation then refuses it as a
		-- foreign file and uninstall does not know it.
		local files = shipped_files()
		files[LOCAL_DIR .. "installed.json"] = "{ damaged"
		local LayoutRegistry, deps, state = manager({ served = "offline", files = files })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_RECORD)
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergol.keylayout"], "no layout reaches the user's layouts folder")
		helpers.assert_nil(state.files[LOCAL_DIR .. "ergol.keylayout"], "nor the local folder")
		helpers.assert_eq(state.files[LOCAL_DIR .. "installed.json"], "{ damaged", "the damaged record is left as it is")
		helpers.assert_eq(#state.enabled, 0)
		helpers.assert_nil(LayoutRegistry.snapshot(deps).busy, "the operation slot is released")
	end)

	helpers.it("reports an installed layout it could not enable (layout-registry-install)", function()
		local LayoutRegistry, deps = manager({ served = "offline", files = shipped_files(), enable_fails = true })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_true(result.detail.enabled == false)
	end)

	-- macOS 26 lists a layout written to the enabled-sources preference at once
	-- but turns it on only at the next login (field probe, L25 and L52): the
	-- install must say so, not claim it enabled, and remember it for the boot.
	helpers.it("reports a listed layout macOS turns on at the next login as pending (composer-macos26)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files(), pending_logout = true })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_eq(result.detail.enabled, false, "a layout macOS has not turned on is not enabled")
		helpers.assert_eq(result.detail.pending_activation, true)
		helpers.assert_eq(state.live_reads[1], entry_of("ergol").keyboard_name, "the live list decides, by keyboard name")
		helpers.assert_not_nil(state.pending.ergol, "the boot checks it again")
		run(function(done) LayoutRegistry.uninstall("ergol", done, deps) end)
		helpers.assert_nil(state.pending.ergol, "an uninstalled layout is no longer pending")
	end)

	-- Probe v5 (P5): the preference turns the layout on at once, seen by a process
	-- started after the write; P8 a: a rewritten enabled file applies once registered again.
	helpers.it("confirms a new layout from a fresh process and asks the user to expect the consent (composer-macos26)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files() })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(result.detail.enabled, true)
		helpers.assert_eq(result.detail.pending_activation, false)
		helpers.assert_eq(result.detail.consent, true, "macOS asks to allow a keyboard it has not seen")
		helpers.assert_eq(state.confirms[1].register_path, LAYOUTS_DIR .. "ergol.keylayout")
		helpers.assert_eq(state.confirms[1].refresh, false)
		local update = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(update.detail.enabled, true)
		helpers.assert_eq(update.detail.consent, false, "an update of an allowed keyboard asks nothing")
		helpers.assert_eq(state.confirms[2].refresh, true, "an update re-registers and reselects the rewritten file")
		helpers.assert_nil(state.pending.ergol)
	end)

	helpers.it("neither enables nor records a layout whose live state cannot be read (composer-macos26)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files(), live_unreadable = true })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_eq(result.detail.enabled, false)
		helpers.assert_eq(result.detail.pending_activation, false)
		helpers.assert_nil(state.pending.ergol)
	end)

	helpers.it("does not read the live list when the preference could not be written (composer-macos26)", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files(), enable_fails = true })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(result.detail.pending_activation, false)
		helpers.assert_eq(#state.live_reads, 0)
	end)

	helpers.it("refuses a second operation while one is running (layout-registry-install)", function()
		local LayoutRegistry, deps = manager({ served = {} })
		local pending
		deps.transport.get = function(_, _, _, callback) pending = callback end
		local first = { calls = 0 }
		LayoutRegistry.install("ergol", function() first.calls = first.calls + 1 end, deps)
		local second = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(second.ok == false)
		helpers.assert_eq(second.detail, LayoutRegistry.FAILURE_BUSY)
		pending(0, "", "offline", nil)
		helpers.assert_eq(first.calls, 1)
		helpers.assert_nil(LayoutRegistry.snapshot(deps).busy)
	end)
end)

helpers.describe("layout manager (macOS): uninstalling and selecting", function()
	--- A manager with Ergo-L installed.
	local function with_ergol()
		local installed = Json.encode({ schema_version = 1, layouts = { ergol = entry_of("ergol") } })
		return manager({
			files = {
				[LOCAL_DIR .. "installed.json"] = installed,
				[LOCAL_DIR .. "ergol.keylayout"] = registry_file("ergol/ergol.keylayout"),
				[LAYOUTS_DIR .. "ergol.keylayout"] = registry_file("ergol/ergol.keylayout"),
			},
			active = { { id = entry_of("ergol").keyboard_name, name = "French (Ergo-L)", selected = true } },
		})
	end

	helpers.it("removes the input source, the files and the record (layout-registry-install)", function()
		local LayoutRegistry, deps, state = with_ergol()
		helpers.assert_eq(LayoutRegistry.snapshot(deps).active, "ergol", "the current input source is recognised")
		local result = run(function(done) LayoutRegistry.uninstall("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_eq(state.disabled[1].name, entry_of("ergol").keyboard_name)
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergol.keylayout"])
		helpers.assert_nil(state.files[LOCAL_DIR .. "ergol.keylayout"])
		helpers.assert_nil(record(state).layouts.ergol)
		helpers.assert_nil(LayoutRegistry.snapshot(deps).installed.ergol)
	end)

	helpers.it("refuses to uninstall what it did not install (layout-registry-install)", function()
		local LayoutRegistry, deps, state = with_ergol()
		local result = run(function(done) LayoutRegistry.uninstall("ergopti", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_NOT_INSTALLED)
		helpers.assert_eq(#state.deleted, 0)
	end)

	helpers.it("selects an installed layout by the name its file declares (layout-registry-install)", function()
		local LayoutRegistry, deps, state = with_ergol()
		local result = run(function(done) LayoutRegistry.select("ergol", done, deps) end)
		helpers.assert_true(result.ok, tostring(result.extra))
		helpers.assert_eq(state.selected[1].name, entry_of("ergol").keyboard_name)
		result = run(function(done) LayoutRegistry.select("ergopti", done, deps) end)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_NOT_INSTALLED)
	end)

	helpers.it("gives the menu picker the installed layouts and the active one (layout-registry-install)", function()
		local LayoutRegistry, deps, state = with_ergol()
		local bundle_scans = 0
		deps.bundle_names = function() bundle_scans = bundle_scans + 1; return {} end
		local picker = LayoutRegistry.picker(deps)
		helpers.assert_eq(#picker.layouts, 1)
		helpers.assert_eq(picker.layouts[1].id, "ergol")
		helpers.assert_eq(picker.active, "ergol")
		helpers.assert_eq(bundle_scans, 0, "opening the menu scans no bundle")
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
		helpers.assert_eq(#LayoutRegistry.picker(deps).layouts, 0, "a layout whose file is gone is not offered")
	end)

	helpers.it("shows the shipped catalogue as such before the first refresh (layout-manager-shipped-first)", function()
		local LayoutRegistry, deps = manager({ files = shipped_files() })
		local snapshot = LayoutRegistry.snapshot(deps)
		helpers.assert_true(type(snapshot.index) == "table", "the index shipped with the app is listed before any refresh")
		helpers.assert_eq(snapshot.source, "bundled", "the page must not call the shipped catalogue no catalogue")
	end)

	helpers.it("does not list a recorded layout whose file is gone (layout-registry-install)", function()
		local LayoutRegistry, deps, state = with_ergol()
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
		helpers.assert_nil(LayoutRegistry.snapshot(deps).installed.ergol)
	end)
end)

helpers.describe("layout manager: cold input-source conventions (iso-typing-convention)", function()
	helpers.it("recognizes declared localized and formatted source names before the TIS cache is ready", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		local cases = {
			{ id = "Ergopti", expected = "ergopti", form = "iso" },
			{ id = "Ergopti+", expected = "ergopti_plus", form = "iso" },
			{ id = "Ergopti ANSI", expected = "ergopti_ansi", form = "iso" },
			{ id = "Ergopti+ ANSI", expected = "ergopti_plus_ansi", form = "iso" },
			{ id = "Ergopti v2.2.2", expected = "ergopti", form = "iso" },
			{ id = "Ergo-L", expected = "ergol", form = "ansi" },
			{ id = "native-opaque-id", name = "Ergopti+", expected = "ergopti_plus", form = "iso" },
		}
		for _, source in ipairs(cases) do
			local LayoutRegistry, deps = manager({ files = shipped_files(), active = {
				{ id = source.id, name = source.name, selected = true },
			} })
			local snapshot = LayoutRegistry.snapshot(deps)
			helpers.assert_eq(snapshot.active, source.expected, source.id)
			helpers.assert_nil(snapshot.active_error)
			helpers.assert_eq(Layout.keyboard_form(snapshot), source.form)
		end
	end)

	helpers.it("refuses ambiguous declared display names while giving exact raw identifiers precedence", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		for _, source in ipairs({
			{ id = "Shared display", selected = true },
			{ id = "Ergopti_v2_2_2", name = "Shared display", selected = true },
		}) do
			local LayoutRegistry, deps = manager({ active = { source } })
			local index = Json.decode(INDEX_TEXT)
			for _, entry in ipairs(index.layouts) do
				if entry.id == "ergopti" or entry.id == "ergopti_plus" then entry.name = "Shared display" end
			end
			deps.bundled_index = index
			local snapshot = LayoutRegistry.snapshot(deps)
			if source.id == "Shared display" then
				helpers.assert_eq(snapshot.active, "")
				helpers.assert_eq(snapshot.active_error, "ambiguous_input_source")
				helpers.assert_throws(function() Layout.keyboard_form(snapshot) end,
					"ambiguous known ownership must not masquerade as unregistered ANSI")
			else
				helpers.assert_eq(snapshot.active, "ergopti")
				helpers.assert_nil(snapshot.active_error)
				helpers.assert_eq(Layout.keyboard_form(snapshot), "iso")
			end
		end
	end)

	helpers.it("keeps genuinely unregistered sources on ANSI and refuses conflicting selected known owners", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		local LayoutRegistry, deps = manager({ files = shipped_files(), active = {
			{ id = "U.S.", name = "U.S.", selected = true },
		} })
		local snapshot = LayoutRegistry.snapshot(deps)
		helpers.assert_eq(snapshot.active, "")
		helpers.assert_nil(snapshot.active_error)
		helpers.assert_eq(Layout.keyboard_form(snapshot), "ansi")
		LayoutRegistry, deps = manager({ files = shipped_files(), active = {
			{ id = "Ergopti", selected = true }, { id = "Ergopti+", selected = true },
		} })
		snapshot = LayoutRegistry.snapshot(deps)
		helpers.assert_eq(snapshot.active_error, "ambiguous_input_source")
		helpers.assert_throws(function() Layout.keyboard_form(snapshot) end)
	end)
end)


require("test.layout_installed_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	-- Explicitly repair only the earlier controlled native-port copy. The
	-- production foreign-file policy and the actual private record stay strict.
	repair_partial_copy = function(state)
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
	end,
})

require("test.layout_installed_update_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	-- Explicitly repair only the earlier controlled native-port copy. The
	-- production foreign-file policy and the actual private record stay strict.
	repair_partial_copy = function(state)
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
	end,
})

require("test.layout_installed_extension_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	-- Explicitly repair only the earlier controlled native-port copy. The
	-- production foreign-file policy and the actual private record stay strict.
	repair_partial_copy = function(state)
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
	end,
})

require("test.layout_composer_contract")(helpers, Json, {
	name = "macOS",
	platform = "macos",
	shortcuts = "full",
	manager = manager,
	files = shipped_files,
	config_dir = "/cfg/",
	local_dir = LOCAL_DIR,
	installed_copy = LAYOUTS_DIR .. "composed.keylayout",
	registry_text = registry_file,
	selections = function(state) return #state.selected end,
})

require("test.composer_check_contract")(helpers, Json, {
	name = "macOS",
	manager = manager,
	files = shipped_files,
	config_dir = "/cfg/",
	local_dir = LOCAL_DIR,
	installed_copy = LAYOUTS_DIR .. "composed.keylayout",
	-- The system lists the composition among its enabled keyboard layouts.
	manager_options = { active = { { id = "Composer Check", name = "Composer Check", selected = false } } },
	env = function(overrides)
		return helpers.load_with_stubs("modules.keymap.composer_check").env(overrides)
	end,
	selections = function(state) return #state.selected end,
	ready_step = "composer_ready=pass:enabled",
	existing_ready_step = "composer_ready=pass:enabled",
	-- The input source cannot be enabled: the install works, the host is not ready.
	readiness_failure = function(fresh) return fresh({ enable_fails = true }) end,
	readiness_failure_step = "composer_ready=fail:not_enabled",
	-- macOS 26 lists the composition in the enabled sources and turns it on at
	-- the next login; a stored one is listed there too, not live yet.
	pending_activation = function(fresh)
		return fresh({ pending_logout = true })
	end,
	pending_activation_step = "composer_ready=info:pending_logout",
})

helpers.describe("layout composer (macOS): a layout macOS turns on at the next login", function()
	local fixture_dir = helpers.driver_root() .. "/../_shared/modules/layouts/composer_check/"
	local function shipped(name)
		local handle = assert(io.open(fixture_dir .. name, "rb"))
		local text = handle:read("*a")
		handle:close()
		return text
	end

	-- Selecting a source macOS has not turned on answers paramErr (-50): the
	-- save must not try, nor fail, and the boot selects it after the login.
	helpers.it("defers « save and use » to the next login instead of failing the selection (composer-macos26)", function()
		local LayoutRegistry, deps, state = manager({ files = shipped_files(), pending_logout = true })
		deps.config_dir = "/cfg/"
		local result = {}
		LayoutRegistry.composer_save({ declaration = shipped("composition.json"), keylayout = shipped("composed.keylayout"),
			use = true }, function(ok, code, detail, used, installed)
			result = { ok = ok, code = code, detail = detail, used = used, installed = installed }
		end, deps)
		helpers.assert_true(result.ok, tostring(result.code) .. " " .. tostring(result.detail))
		helpers.assert_eq(result.used, false, "nothing is in use before the login")
		helpers.assert_eq(result.installed.pending_activation, true)
		helpers.assert_eq(#state.selected, 0, "no selection is attempted")
		local id = assert(LayoutRegistry.composer_settings()).id
		helpers.assert_true(state.pending[id] ~= nil and state.pending[id].select == true,
			"the boot after the login selects it")
	end)
end)
