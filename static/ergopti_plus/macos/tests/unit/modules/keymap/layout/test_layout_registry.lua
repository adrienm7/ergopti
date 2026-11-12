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
		read_bounded = function(path, max_bytes)
			local text = state.files[path]
			if text == nil then return nil, "absent" end
			if #text > max_bytes then return nil, "too_large" end
			return text, "ok"
		end,
		write = function(path, content) state.files[path] = content; return true end,
		create = function(path, content)
			if state.files[path] ~= nil then return false, "exists" end
			state.files[path] = content
			return true, "created"
		end,
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
	deps.inspect_file = function(path)
		if not deps.exists(path) then return nil, "absent" end
		return { mode = "file" }, "ok"
	end
	deps.read_status = function(path)
		local content = deps.read(path)
		if content == nil then return nil, "absent" end
		return content, "ok"
	end
	deps.digest = function(text)
		local digest
		deps.transport.sha256(text, function(value) digest = value end)
		return digest
	end
	deps.replace_exact = function(path, content, expected)
		local current, status = deps.read_status(path)
		if expected.status == "absent" then
			if status ~= "absent" then return false, "source changed" end
		elseif status ~= "ok" or current ~= expected.content then
			return false, "source changed"
		end
		return deps.write(path, content)
	end
	deps.remove_exact = function(path, expected)
		if state.files[path] ~= expected.content then return false, "source changed" end
		return deps.delete(path)
	end
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
	helpers.it("refuses update after an installed copy is edited", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local path = LAYOUTS_DIR .. "ergol.keylayout"
		state.files[path] = "personal edit"
		local result = run(function(done) registry.install("ergol", done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(state.files[path], "personal edit")
	end)

	helpers.it("rolls back an update after the second copy or record refuses, then retries", function()
		for _, failure in ipairs({ "second", "record", "missing_local", "throw" }) do
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local local_path, installed_path = LOCAL_DIR .. "ergol.keylayout", LAYOUTS_DIR .. "ergol.keylayout"
			local record_path = LOCAL_DIR .. "installed.json"
			local old_local, old_installed, old_record = state.files[local_path], state.files[installed_path], state.files[record_path]
			if failure == "missing_local" then state.files[local_path] = nil; old_local = nil end
			local entry = Json.decode(Json.encode(entry_of("ergol")))
			local candidate = "verified replacement layout"
			entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
			local replace, fail_once = deps.replace_exact, true
			deps.replace_exact = function(path, content, expected)
				if fail_once and ((failure ~= "record" and path == installed_path) or (failure == "record" and path == record_path)) then
					fail_once = false
					if failure == "throw" then error("simulated native refusal") end
					return false, "simulated publication refusal"
				end
				return replace(path, content, expected)
			end
			local first = run(function(done) registry.install_local(entry, candidate, done, deps) end)
			helpers.assert_eq(first.ok, false)
			helpers.assert_eq(state.files[local_path], old_local)
			helpers.assert_eq(state.files[installed_path], old_installed)
			helpers.assert_eq(state.files[record_path], old_record)
			local retried = run(function(done) registry.install_local(entry, candidate, done, deps) end)
			helpers.assert_true(retried.ok, tostring(retried.extra))
			helpers.assert_eq(state.files[local_path], candidate)
			helpers.assert_eq(state.files[installed_path], candidate)
			helpers.assert_eq(record(state).layouts.ergol.sha256, entry.sha256)
		end
	end)

	helpers.it("repairs a candidate copy left before a restart, but refuses a different candidate", function()
		for _, both in ipairs({ false, true }) do
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local entry = Json.decode(Json.encode(entry_of("ergol")))
			local candidate = "verified replacement layout"
			local other = "another verified layout"
			local sha256 = deps.transport.sha256
			deps.transport.sha256 = function(value, done)
				if value == candidate then done(string.rep("a", 64), nil)
				elseif value == other then done(string.rep("b", 64), nil)
				else sha256(value, done) end
			end
			entry.size, entry.sha256, entry.version = #candidate, string.rep("a", 64), "replacement"
			local local_path, installed_path = LOCAL_DIR .. "ergol.keylayout", LAYOUTS_DIR .. "ergol.keylayout"
			state.files[local_path] = candidate
			if both then state.files[installed_path] = candidate end
			registry = helpers.load_with_stubs("modules.keymap.layout_registry") -- no in-memory transaction survives a restart
			local newer = Json.decode(Json.encode(entry))
			newer.size, newer.sha256 = #other, string.rep("b", 64)
			local refused = run(function(done) registry.install_local(newer, other, done, deps) end)
			helpers.assert_eq(refused.ok, false, "a different later candidate cannot authorize the earlier bytes")
			helpers.assert_eq(state.files[local_path], candidate)
			local repaired = run(function(done) registry.install_local(entry, candidate, done, deps) end)
			helpers.assert_true(repaired.ok, tostring(repaired.extra))
			helpers.assert_eq(state.files[local_path], candidate)
			helpers.assert_eq(state.files[installed_path], candidate)
		end
	end)

	helpers.it("restores real files after a refused second update and then retries", function()
		require("tests.support.file_system_transaction_fixture").with_fixture(function(host)
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local root = os.tmpname(); os.remove(root)
			assert(os.execute("mkdir -p '" .. root .. "/local' '" .. root .. "/installed'"))
			local function write(path, value)
				local handle = assert(io.open(path, "wb")); assert(handle:write(value)); assert(handle:close())
			end
			local function read(path)
				local handle = assert(io.open(path, "rb")); local value = handle:read("*a"); assert(handle:close()); return value
			end
			local ok, err = xpcall(function()
				local local_dir, installed_dir = root .. "/local/", root .. "/installed/"
				local local_path, installed_path = local_dir .. "ergol.keylayout", installed_dir .. "ergol.keylayout"
				local record_path = local_dir .. "installed.json"
				local old_local, old_installed, old_record = state.files[LOCAL_DIR .. "ergol.keylayout"],
					state.files[LAYOUTS_DIR .. "ergol.keylayout"], state.files[LOCAL_DIR .. "installed.json"]
				write(local_path, old_local); write(installed_path, old_installed); write(record_path, old_record)
				local original_read, original_exists = deps.read, deps.exists
				deps.local_dir, deps.layouts_dir = local_dir, installed_dir
				deps.read = function(path) if path == record_path then return read(path) end; return original_read(path) end
				deps.exists = function(path)
					if path == record_path or path == local_path or path == installed_path then
						local handle = io.open(path, "rb"); if not handle then return false end; handle:close(); return true
					end
					return original_exists(path)
				end
				local adapter, refuse = host.make_adapter(), true
				deps.inspect_file, deps.read_status = adapter.classify_no_follow, adapter.read_with_status
				deps.remove_exact = adapter.remove_if_unchanged
				deps.replace_exact = function(path, value, expected)
					if refuse and path == installed_path then refuse = false; return false, "second copy refused" end
					return adapter.write_if_unchanged(path, value, expected)
				end
				local entry = Json.decode(Json.encode(entry_of("ergol")))
				local candidate = "verified replacement layout"
				entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
				helpers.assert_eq(run(function(done) registry.install_local(entry, candidate, done, deps) end).ok, false)
				helpers.assert_eq(read(local_path), old_local)
				helpers.assert_eq(read(installed_path), old_installed)
				helpers.assert_eq(read(record_path), old_record)
				local retried = run(function(done) registry.install_local(entry, candidate, done, deps) end)
				helpers.assert_true(retried.ok, tostring(retried.extra))
				helpers.assert_eq(read(local_path), candidate)
				helpers.assert_eq(read(installed_path), candidate)
			end, debug.traceback)
			os.execute("rm -rf '" .. root .. "'")
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("retains update cleanup until the publication effect is known", function()
		for _, scenario in ipairs({ { "second", false }, { "second", true }, { "record", false }, { "record", true } }) do
			local failure, published = scenario[1], scenario[2]
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local entry = Json.decode(Json.encode(entry_of("ergol")))
			local candidate = "verified replacement layout"
			entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
			local path, record_path = LAYOUTS_DIR .. "ergol.keylayout", LOCAL_DIR .. "installed.json"
			local old_record, replace, allow, once = state.files[record_path], deps.replace_exact, false, true
			local restored_before_retry = false
			deps.replace_exact = function(target, content, expected)
				if not once and allow and target == LOCAL_DIR .. "ergol.keylayout" and content == candidate then
					restored_before_retry = state.files[record_path] == old_record
				end
				if once and target == (failure == "record" and record_path or path) then
					once = false
					if published then state.files[target] = content end
					return false, "release refused", function() return allow, nil, published end
				end
				return replace(target, content, expected)
			end
			helpers.assert_eq(run(function(done) registry.install_local(entry, candidate, done, deps) end).ok, false)
			if failure ~= "record" or not published then helpers.assert_eq(state.files[record_path], old_record) end
			helpers.assert_eq(run(function(done) registry.install_local(entry, candidate, done, deps) end).ok, false)
			allow = true
			local retried = run(function(done) registry.install_local(entry, candidate, done, deps) end)
			helpers.assert_true(retried.ok, tostring(retried.extra))
			helpers.assert_true(restored_before_retry, "record compensation must finish before the retry")
			helpers.assert_eq(state.files[path], candidate)
		end
	end)

	helpers.it("retries the inverse after an exception during rollback", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local entry = Json.decode(Json.encode(entry_of("ergol")))
		local candidate = "verified replacement layout"
		entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
		local local_path, installed_path = LOCAL_DIR .. "ergol.keylayout", LAYOUTS_DIR .. "ergol.keylayout"
		local original, replace, failed, threw = state.files[local_path], deps.replace_exact, false, false
		deps.replace_exact = function(path, value, expected)
			if path == installed_path and not failed then failed = true; return false, "second copy refused" end
			if path == local_path and value == original and not threw then threw = true; error("inverse raised") end
			return replace(path, value, expected)
		end
		local first = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_eq(first.ok, false)
		helpers.assert_eq(state.files[local_path], candidate, "failed inverse retains its exact debt")
		local retried = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_true(retried.ok, tostring(retried.extra))
	end)

	helpers.it("retains an unacknowledged candidate after a throwing publisher", function()
		for _, failed in ipairs({ "copy", "record" }) do
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local entry = Json.decode(Json.encode(entry_of("ergol")))
			local candidate = "verified replacement layout"
			entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
			local path = failed == "record" and (LOCAL_DIR .. "installed.json") or (LAYOUTS_DIR .. "ergol.keylayout")
			local replace, once = deps.replace_exact, true
			deps.replace_exact = function(target, value, expected)
				if target == path and once then
					once = false
					state.files[target] = value
					error("publisher stopped after mutation")
				end
				return replace(target, value, expected)
			end
			local first = run(function(done) registry.install_local(entry, candidate, done, deps) end)
			helpers.assert_eq(first.ok, false)
			helpers.assert_contains(first.extra, "publication was not confirmed at " .. path)
			helpers.assert_eq(state.files[LAYOUTS_DIR .. "ergol.keylayout"], candidate)
			local retried = run(function(done) registry.install_local(entry, candidate, done, deps) end)
			helpers.assert_true(retried.ok, tostring(retried.extra))
		end
	end)

	helpers.it("retains a competing edit rather than overwriting it during rollback", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local entry = Json.decode(Json.encode(entry_of("ergol")))
		local candidate = "verified replacement layout"
		entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
		local local_path, installed_path = LOCAL_DIR .. "ergol.keylayout", LAYOUTS_DIR .. "ergol.keylayout"
		local replace, once = deps.replace_exact, true
		deps.replace_exact = function(path, content, expected)
			if once and path == installed_path then
				once = false
				state.files[local_path] = "competing edit"
				return false, "publication refused"
			end
			return replace(path, content, expected)
		end
		helpers.assert_eq(run(function(done) registry.install_local(entry, candidate, done, deps) end).ok, false)
		helpers.assert_eq(state.files[local_path], "competing edit")
		helpers.assert_eq(run(function(done) registry.install_local(entry, candidate, done, deps) end).ok, false)
		helpers.assert_eq(state.files[local_path], "competing edit")
		state.files[local_path] = candidate -- explicit repair of the retained precondition
		local retried = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_true(retried.ok, tostring(retried.extra))
	end)

	helpers.it("preserves a competing record edit and retains unconfirmed copies", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local entry = Json.decode(Json.encode(entry_of("ergol")))
		local candidate = "verified replacement layout"
		entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
		local local_path, installed_path, record_path = LOCAL_DIR .. "ergol.keylayout",
			LAYOUTS_DIR .. "ergol.keylayout", LOCAL_DIR .. "installed.json"
		local replace, once = deps.replace_exact, true
		deps.replace_exact = function(path, content, expected)
			if once and path == record_path then
				once = false
				state.files[record_path] = '{"foreign":true}'
			end
			return replace(path, content, expected)
		end
		local result = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(state.files[record_path], '{"foreign":true}')
		helpers.assert_eq(state.files[local_path], candidate)
		helpers.assert_eq(state.files[installed_path], candidate)
	end)

	helpers.it("refuses a link observed after the update preflight", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local entry = Json.decode(Json.encode(entry_of("ergol")))
		local candidate = "verified replacement layout"
		entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
		local path, inspect, count = LOCAL_DIR .. "ergol.keylayout", deps.inspect_file, 0
		local original = state.files[path]
		deps.inspect_file = function(target)
			if target == path then
				count = count + 1
				if count >= 2 then return { mode = "link" }, "ok" end
			end
			return inspect(target)
		end
		local result = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(state.files[path], original)
		helpers.assert_eq(record(state).layouts.ergol.sha256, entry_of("ergol").sha256)
	end)

	helpers.it("retains rollback when the conditional writer owner changes", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local entry = Json.decode(Json.encode(entry_of("ergol")))
		local candidate = "verified replacement layout"
		entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
		local original, changed = deps.replace_exact, false
		local owned
		owned = function(path, value, expected)
			local ok, detail = original(path, value, expected)
			if ok and not changed then changed = true; deps.replace_exact = function() error("foreign writer") end end
			return ok, detail
		end
		deps.replace_exact = owned
		local before = state.files[LOCAL_DIR .. "installed.json"]
		local refused = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_eq(refused.ok, false)
		helpers.assert_eq(state.files[LOCAL_DIR .. "installed.json"], before)
		local blocked = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_eq(blocked.ok, false)
		deps.replace_exact = owned
		local retried = run(function(done) registry.install_local(entry, candidate, done, deps) end)
		helpers.assert_true(retried.ok, tostring(retried.extra))
		helpers.assert_eq(state.files[LOCAL_DIR .. "ergol.keylayout"], candidate)
	end)

	helpers.it("refuses an update when the inverse owner cannot be constructed", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local entry = Json.decode(Json.encode(entry_of("ergol")))
		local candidate = "verified replacement layout"
		entry.size, entry.sha256, entry.version = #candidate, string.rep("0", 64), "replacement"
		local before = state.files[LOCAL_DIR .. "ergol.keylayout"]
		local original = package.loaded["config_file_inverse"]
		package.loaded["config_file_inverse"] = { for_current_writer = function() error("owner unavailable") end }
		local ok, err = xpcall(function()
			local refused = run(function(done) registry.install_local(entry, candidate, done, deps) end)
			helpers.assert_eq(refused.ok, false)
			helpers.assert_eq(state.files[LOCAL_DIR .. "ergol.keylayout"], before)
			helpers.assert_nil(registry.snapshot(deps).busy)
		end, debug.traceback)
		package.loaded["config_file_inverse"] = original
		if not ok then error(err, 0) end
	end)
	helpers.it("preserves a real edited layout during uninstall", function()
		require("tests.support.file_system_transaction_fixture").with_fixture(function(host)
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local root = os.tmpname(); os.remove(root)
			assert(os.execute("mkdir -p '" .. root .. "/local' '" .. root .. "/installed'"))
			local ok, err = xpcall(function()
				local local_dir, installed_dir = root .. "/local/", root .. "/installed/"
				local old_record = state.files[LOCAL_DIR .. "installed.json"]
				state.files[local_dir .. "installed.json"] = old_record
				for _, pair in ipairs({ { LOCAL_DIR, local_dir }, { LAYOUTS_DIR, installed_dir } }) do
					local handle = assert(io.open(pair[2] .. "ergol.keylayout", "wb"))
					assert(handle:write(state.files[pair[1] .. "ergol.keylayout"])); assert(handle:close())
				end
				local edited = assert(io.open(installed_dir .. "ergol.keylayout", "wb"))
				assert(edited:write("personal modification")); assert(edited:close())
				deps.local_dir, deps.layouts_dir = local_dir, installed_dir
				local adapter = host.make_adapter()
				deps.inspect_file, deps.read_status = adapter.classify_no_follow, adapter.read_with_status
				deps.remove_exact = adapter.remove_if_unchanged
				local result = run(function(done) registry.uninstall("ergol", done, deps) end)
				helpers.assert_eq(result.ok, false)
				local live = assert(io.open(installed_dir .. "ergol.keylayout", "rb"))
				helpers.assert_eq(live:read("*a"), "personal modification"); assert(live:close())
				helpers.assert_eq(state.files[local_dir .. "installed.json"], old_record)
				local restored = assert(io.open(installed_dir .. "ergol.keylayout", "wb"))
				assert(restored:write(state.files[LAYOUTS_DIR .. "ergol.keylayout"])); assert(restored:close())
				local retried = run(function(done) registry.uninstall("ergol", done, deps) end)
				helpers.assert_true(retried.ok, tostring(retried.extra))
				helpers.assert_nil(io.open(installed_dir .. "ergol.keylayout", "rb"))
				helpers.assert_nil(io.open(local_dir .. "ergol.keylayout", "rb"))
			end, debug.traceback)
			os.execute("rm -rf '" .. root .. "'")
			if not ok then error(err, 0) end
		end)
	end)
	helpers.it("refuses uninstall after either installed copy is edited", function()
		for _, directory in ipairs({ LOCAL_DIR, LAYOUTS_DIR }) do
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local path = directory .. "ergol.keylayout"
			state.files[path] = "user edited layout"
			local removed = run(function(done) registry.uninstall("ergol", done, deps) end)
			helpers.assert_eq(removed.ok, false, "uninstall must not delete edited files")
			helpers.assert_eq(state.files[path], "user edited layout")
		end
	end)

	helpers.it("refuses uninstall when an installed copy is unreadable or not regular", function()
		for _, mode in ipairs({ "unreadable", "link", "inspect_error" }) do
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local path = LAYOUTS_DIR .. "ergol.keylayout"
			local inspect, read = deps.inspect_file, deps.read_status
			deps.inspect_file = function(candidate)
				if candidate == path and mode == "link" then return { mode = "link" }, "ok" end
				if candidate == path and mode == "inspect_error" then return nil, "error" end
				return inspect(candidate)
			end
			deps.read_status = function(candidate)
				if candidate == path and mode == "unreadable" then return nil, "error" end
				return read(candidate)
			end
			local result = run(function(done) registry.uninstall("ergol", done, deps) end)
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(#state.disabled, 0, "refusal happens before disabling the input source")
			helpers.assert_not_nil(state.files[path])
			helpers.assert_not_nil(record(state).layouts.ergol)
		end
	end)

	helpers.it("retains removal cleanup whether or not the first unlink happened", function()
		for _, removed in ipairs({ false, true }) do
			local registry, deps, state = manager({ served = "offline", files = shipped_files() })
			helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
			local remove, allow, calls = deps.remove_exact, false, 0
			deps.remove_exact = function(path, expected)
				calls = calls + 1
				if calls == 1 then
					if removed then state.files[path] = nil end
					return false, "release refused", { removed = removed }, function() return allow end
				end
				return remove(path, expected)
			end
			local first = run(function(done) registry.uninstall("ergol", done, deps) end)
			helpers.assert_eq(first.ok, false)
			helpers.assert_not_nil(record(state).layouts.ergol, "a refused native result keeps the record")
			local blocked = run(function(done) registry.uninstall("ergol", done, deps) end)
			helpers.assert_eq(blocked.ok, false)
			helpers.assert_eq(calls, 1, "pending release cannot repeat unlink")
			allow = true
			local retried = run(function(done) registry.uninstall("ergol", done, deps) end)
			helpers.assert_true(retried.ok, tostring(retried.extra))
			helpers.assert_nil(record(state).layouts.ergol)
		end
	end)

	helpers.it("refuses an installed copy changed after preflight", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local remove = deps.remove_exact
		deps.remove_exact = function(path, expected)
			state.files[path] = "concurrent change"
			return remove(path, expected)
		end
		local result = run(function(done) registry.uninstall("ergol", done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(state.files[LAYOUTS_DIR .. "ergol.keylayout"], "concurrent change")
		helpers.assert_not_nil(state.files[LOCAL_DIR .. "ergol.keylayout"])
		helpers.assert_not_nil(record(state).layouts.ergol)
	end)

	helpers.it("preserves the record when an absent copy reappears while disabling", function()
		local registry, deps, state = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local local_path = LOCAL_DIR .. "ergol.keylayout"
		state.files[local_path] = nil
		deps.disable_source = function(_, _, done)
			state.files[local_path] = "foreign replacement"
			done(true, "", nil)
			return true
		end
		local result = run(function(done) registry.uninstall("ergol", done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(state.files[local_path], "foreign replacement")
		helpers.assert_not_nil(state.files[LAYOUTS_DIR .. "ergol.keylayout"])
		helpers.assert_not_nil(record(state).layouts.ergol)
	end)

	helpers.it("holds the operation slot while retrying a removal release", function()
		local registry, deps = manager({ served = "offline", files = shipped_files() })
		helpers.assert_true(run(function(done) registry.install("ergol", done, deps) end).ok)
		local remove, entered = deps.remove_exact, false
		local nested
		deps.remove_exact = function(path, expected)
			deps.remove_exact = remove
			return false, "release refused", { removed = false }, function()
				if not entered then
					entered = true
					nested = run(function(done) registry.uninstall("ergol", done, deps) end)
				end
				return true
			end
		end
		helpers.assert_eq(run(function(done) registry.uninstall("ergol", done, deps) end).ok, false)
		helpers.assert_true(run(function(done) registry.uninstall("ergol", done, deps) end).ok)
		helpers.assert_eq(nested.ok, false)
		helpers.assert_eq(nested.detail, registry.FAILURE_BUSY)
	end)
	helpers.it("rereads a modified checkout catalogue without HTTP or stale cache (layout-catalogue-local)", function()
		local registry, deps, state = manager({ files = shipped_files() })
		deps.local_source = true
		deps.registry_changes = function(_, callback) callback(" M index.json\n", nil) end
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
		local digest = deps.digest
		deps.digest = function(text) return text == "old bytes" and string.rep("1", 64) or digest(text) end
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

	helpers.it("refuses installation when bundle discovery fails", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files() })
		deps.bundle_names = function() error("listing refused") end
		local result = run(function(done) LayoutRegistry.install("ergopti", done, deps) end)
		helpers.assert_true(result.ok == false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_BUNDLE_SCAN)
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergopti.keylayout"])
		helpers.assert_eq(#state.enabled, 0)
		local local_result = run(function(done) LayoutRegistry.install_local(entry_of("ergopti"), "layout", done, deps) end)
		helpers.assert_true(local_result.ok == false)
		helpers.assert_eq(local_result.detail, LayoutRegistry.FAILURE_BUNDLE_SCAN)
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergopti.keylayout"])
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

	helpers.it("never overwrites an unregistered local layout copy", function()
		local files = shipped_files()
		files[LOCAL_DIR .. "ergol.keylayout"] = "personal data"
		local LayoutRegistry, deps, state = manager({ served = "offline", files = files })
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_FOREIGN_FILE)
		helpers.assert_eq(state.files[LOCAL_DIR .. "ergol.keylayout"], "personal data")
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergol.keylayout"])
		local entry = entry_of("ergol")
		local local_result = run(function(done) LayoutRegistry.install_local(entry, registry_file(entry.file), done, deps) end)
		helpers.assert_eq(local_result.ok, false)
		helpers.assert_eq(local_result.detail, LayoutRegistry.FAILURE_FOREIGN_FILE)
		helpers.assert_eq(state.files[LOCAL_DIR .. "ergol.keylayout"], "personal data")
	end)

	helpers.it("preserves an installed-path collision that appears before publication", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files() })
		local create = deps.create
		deps.create = function(path, text)
			if path == LAYOUTS_DIR .. "ergol.keylayout" then state.files[path] = "concurrent file" end
			return create(path, text)
		end
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_FOREIGN_FILE)
		helpers.assert_eq(state.files[LAYOUTS_DIR .. "ergol.keylayout"], "concurrent file")
		helpers.assert_not_nil(state.files[LOCAL_DIR .. "ergol.keylayout"], "the earlier created copy is retained")
		helpers.assert_contains(result.extra, LOCAL_DIR .. "ergol.keylayout")
	end)

	helpers.it("refuses a new layout when exclusive creation is unavailable", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files() })
		deps.create = nil
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.detail, LayoutRegistry.FAILURE_WRITE)
		helpers.assert_nil(state.files[LOCAL_DIR .. "ergol.keylayout"])
		helpers.assert_nil(state.files[LAYOUTS_DIR .. "ergol.keylayout"])
		helpers.assert_nil(LayoutRegistry.snapshot(deps).busy)
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

	helpers.it("does not claim a pending activation when its record is refused", function()
		local LayoutRegistry, deps, state = manager({ served = "offline", files = shipped_files(), pending_logout = true })
		deps.pending.record = function() return false end
		local result = run(function(done) LayoutRegistry.install("ergol", done, deps) end)
		helpers.assert_true(result.ok, "the layout files were installed")
		helpers.assert_eq(result.detail.enabled, false)
		helpers.assert_eq(result.detail.pending_activation, false, "a refused record cannot promise a later retry")
		helpers.assert_eq(result.detail.reason, "pending_record_failed")
		helpers.assert_nil(state.pending.ergol)
		local entry = entry_of("ergol")
		local local_result = run(function(done) LayoutRegistry.install_local(entry, registry_file(entry.file), done, deps) end)
		helpers.assert_true(local_result.ok)
		helpers.assert_eq(local_result.detail.pending_activation, false)
		helpers.assert_eq(local_result.detail.reason, "pending_record_failed")
	end)

	-- The macOS 26 TIS probe showed the preference turns the layout on at once, seen by
	-- a process started after the write, and that a rewritten enabled file applies once registered again.
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
	-- Explicitly repair both controlled copies left by the refused publication.
	repair_partial_copy = function(state)
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
		state.files[LOCAL_DIR .. "ergol.keylayout"] = nil
	end,
})

require("test.layout_installed_update_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	-- Explicitly repair both controlled copies left by the refused publication.
	repair_partial_copy = function(state)
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
		state.files[LOCAL_DIR .. "ergol.keylayout"] = nil
	end,
})

require("test.layout_installed_extension_manager_contract")(helpers, Json, {
	manager = manager,
	run = run,
	entry = entry_of("ergol"),
	files = shipped_files,
	local_dir = LOCAL_DIR,
	-- Explicitly repair both controlled copies left by the refused publication.
	repair_partial_copy = function(state)
		state.files[LAYOUTS_DIR .. "ergol.keylayout"] = nil
		state.files[LOCAL_DIR .. "ergol.keylayout"] = nil
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

helpers.describe("layout editor files (macOS): the registry stores what the editor saves", function()
	helpers.it("saves a source in the store folder and reopens it as the last one", function()
		local LayoutRegistry, deps, state = manager({ files = shipped_files() })
		deps.config_dir = "/cfg/"
		local saved
		helpers.assert_true(LayoutRegistry.source_save({ filename = "mine.toml", text = "a = 1\n" },
			function(...) saved = { ... } end, deps))
		helpers.assert_true(saved[1], tostring(saved[2]) .. " " .. tostring(saved[3]))
		helpers.assert_eq(state.files["/cfg/layout_sources/mine.toml"], "a = 1\n")
		local opened
		helpers.assert_true(LayoutRegistry.source_open(function(data) opened = data end, deps))
		helpers.assert_eq(opened.filename, "mine.toml")
		helpers.assert_eq(opened.text, "a = 1\n")
		local refused
		LayoutRegistry.source_save({ filename = "../escape.toml", text = "x" }, function(...) refused = { ... } end, deps)
		helpers.assert_eq(refused[1], false)
		helpers.assert_eq(refused[2], "source_invalid_file")
	end)
end)
