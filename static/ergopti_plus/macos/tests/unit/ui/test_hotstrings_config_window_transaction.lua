--- tests/unit/ui/test_hotstrings_config_window_transaction.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Window Transaction Regression Tests
--- DESCRIPTION:
--- Drives the real webview bridge callback and proves failed personal-file
--- publication is returned to the bridge before any UI/runtime notification.
--- It also rejects TOML reader values whose second, committed result is false.
--- ==============================================================================

local helpers = require("tests.helpers")

local SENTINEL = "[_meta]\ndelay = 0.33\n"

--- Installs the minimum faithful hotstrings-config surface used by the window.
--- @return table store
local function install_config_stub()
	local store = { sets = 0, clears = 0 }
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		set_override = function()
			store.sets = store.sets + 1
			return true
		end,
		clear_override = function()
			store.clears = store.clears + 1
			return true
		end,
		get_sections = function() return {} end,
		get_toml_defaults = function() return { delay = 0.5 } end,
		get_user_override = function() return nil end,
		resolve = function() return { delay = 0.5, color = "#000000" } end,
		resolve_ext = function() return { delay = 0.5, color = "#000000" } end,
		get_global_default_delay_ms = function() return 750 end,
	}
	return store
end

--- Returns a unique personal TOML file containing the user's sentinel.
--- @param suffix string Test discriminator.
--- @return string path
local function fixture_path(suffix)
	local path = os.tmpname() .. "_" .. suffix .. ".toml"
	local fh = assert(io.open(path, "w"))
	assert(fh:write(SENTINEL))
	assert(fh:close())
	return path
end

--- Returns a unique personal TOML file containing explicit bytes.
--- @param suffix string Test discriminator.
--- @param content string Fixture bytes.
--- @return string path
local function fixture_path_with_content(suffix, content)
	local path = os.tmpname() .. "_" .. suffix .. ".toml"
	local fh = assert(io.open(path, "w"))
	assert(fh:write(content))
	assert(fh:close())
	return path
end

--- Reads a complete fixture.
--- @param path string Fixture path.
--- @return string content
local function read_fixture(path)
	local fh = assert(io.open(path, "r"))
	local content = assert(fh:read("*a"))
	assert(fh:close())
	return content
end

--- Finds a named closure upvalue recursively from the real bridge handler.
--- @param fn function Closure to inspect.
--- @param wanted string Upvalue name.
--- @param seen table|nil Cycle guard.
--- @return any value
local function find_upvalue(fn, wanted, seen)
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	local index = 1
	while true do
		local name, value = debug.getupvalue(fn, index)
		if not name then return nil end
		if name == wanted then return value end
		if type(value) == "function" then
			local nested = find_upvalue(value, wanted, seen)
			if nested ~= nil then return nested end
		end
		index = index + 1
	end
end





-- ========================================================
-- ========================================================
-- ======= 1/ Personal Bridge Mutation Is Transactional ====
-- ========================================================
-- ========================================================

helpers.describe("hotstrings config window: personal writes are transactional", function()
	for _, failure in ipairs({ "write=nil", "close=false", "rename=false" }) do
		helpers.it(failure .. " returns false and preserves the live UI state", function()
			local path = fixture_path(failure:gsub("[^%w]", "_"))
			install_config_stub()
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return SENTINEL, "ok" end,
				write_if_unchanged = function() return false end,
			}
			local win = helpers.load_with_stubs("ui.hotstrings_config_window")
			local notifications = 0
			win._on_config_changed = function() notifications = notifications + 1 end

			local committed = win._on_message({ body = {
				action = "set_delay",
				group = "personal",
				personal_path = path,
				ms = 420,
			} })

			helpers.assert_eq(committed, false,
				"the bridge must expose the failed file transaction")
			helpers.assert_eq(read_fixture(path), SENTINEL,
				"a failed staged write must never truncate the personal TOML")
			helpers.assert_eq(notifications, 0,
				"the page/menu must not redraw a candidate that never committed")
			os.remove(path)
		end)
	end

	helpers.it("a committed write updates the file and then notifies the UI", function()
		local path = fixture_path("success")
		install_config_stub()
		package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
		local win = helpers.load_with_stubs("ui.hotstrings_config_window")
		local notifications = 0
		win._on_config_changed = function() notifications = notifications + 1 end

		local committed = win._on_message({ body = {
			action = "set_delay",
			group = "personal",
			personal_path = path,
			ms = 420,
		} })

		helpers.assert_eq(committed, true)
		helpers.assert_contains(read_fixture(path), "delay = 0.42")
		helpers.assert_eq(notifications, 1)
		os.remove(path)
	end)

	helpers.it("a nested array cannot hide the existing personal field", function()
		local matrix_record = table.concat({
			"future_matrix = [",
			"  [1, 2],",
			"]",
		}, "\n")
		local initial = "[_meta]\n" .. matrix_record .. "\ndelay = 0.33\n"
		local path = fixture_path_with_content("nested_array", initial)
		install_config_stub()
		package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
		local win = helpers.load_with_stubs("ui.hotstrings_config_window")
		local notifications = 0
		win._on_config_changed = function() notifications = notifications + 1 end

		helpers.assert_eq(win._on_message({ body = {
			action = "set_delay",
			group = "personal",
			personal_path = path,
			ms = 420,
		} }), true)

		local content = read_fixture(path)
		local _, delay_count = content:gsub("delay%s*=", "")
		helpers.assert_eq(delay_count, 1,
			"the continuation line must not create a duplicate owned field")
		helpers.assert_contains(content, matrix_record,
			"the unowned nested record must remain byte-identical")
		local codec = require("infra.toml.codec")
		local decode_ok, decoded = pcall(codec.decode, content)
		helpers.assert_true(decode_ok and type(decoded) == "table",
			"the UI must publish valid TOML after the real bridge action")
		helpers.assert_eq(decoded._meta.future_matrix[1][2], 2)
		helpers.assert_eq(decoded._meta.delay, 0.42)
		helpers.assert_eq(notifications, 1)
		os.remove(path)
	end)

	for _, case in ipairs({
		{ label = "EACCES", status = "error", detail = "permission denied" },
		{ label = "failed source close", status = "error", detail = "close failed" },
		{ label = "dangling symlink", status = "error", detail = "dangling symlink target" },
		{ label = "directory", status = "error", detail = "expected a regular file, got directory" },
		{ label = "absent personal file", status = "absent", detail = "not found" },
	}) do
		helpers.it(case.label .. " returns false without calling the writer", function()
			local path = fixture_path(case.label:gsub("[^%w]", "_"))
			install_config_stub()
			local reads = 0
			local writes = 0
			package.loaded["adapters.file_system"] = {
				read_with_status = function(candidate)
					helpers.assert_eq(candidate, path)
					reads = reads + 1
					return nil, case.status, case.detail
				end,
				write_if_unchanged = function() writes = writes + 1 return true end,
			}
			local win = helpers.load_with_stubs("ui.hotstrings_config_window")
			local committed = win._on_message({ body = {
				action = "set_delay", group = "personal", personal_path = path, ms = 420,
			} })

			helpers.assert_eq(committed, false)
			helpers.assert_eq(reads, 1,
				"the bridge must consume one adapter-classified source snapshot")
			helpers.assert_eq(writes, 0, "unread bytes must never reach publication")
			helpers.assert_eq(read_fixture(path), SENTINEL)
			os.remove(path)
		end)
	end

	helpers.it("a symlink retarget after the read suppresses runtime and UI publication", function()
		local path = fixture_path("retarget")
		install_config_stub()
		local events = {}
		package.loaded["adapters.file_system"] = {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				events[#events + 1] = "read"
				return SENTINEL, "ok"
			end,
			write_if_unchanged = function(candidate)
				helpers.assert_eq(candidate, path)
				events[#events + 1] = "retarget-refused"
				return false
			end,
		}
		local win = helpers.load_with_stubs("ui.hotstrings_config_window")
		local notifications = 0
		win._on_config_changed = function() notifications = notifications + 1 end

		helpers.assert_eq(win._on_message({ body = {
			action = "set_delay", group = "personal", personal_path = path, ms = 420,
		} }), false)
		helpers.assert_eq(events[1], "read")
		helpers.assert_eq(events[2], "retarget-refused")
		helpers.assert_eq(#events, 2)
		helpers.assert_eq(notifications, 0)
		helpers.assert_eq(read_fixture(path), SENTINEL)
		os.remove(path)
	end)

	helpers.it("preserves an external edit that lands after the patch read", function()
		local path = fixture_path("external_winner")
		local external = "[_meta]\ndelay = 0.91\n# external winner\n"
		install_config_stub()
		local publications = 0
		package.loaded["adapters.file_system"] = {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				return SENTINEL, "ok"
			end,
			-- Causal old-code seam: an unconditional publication would erase B.
			write = function(candidate, content)
				publications = publications + 1
				local competitor = assert(io.open(candidate, "w"))
				assert(competitor:write(external))
				assert(competitor:close())
				local stale = assert(io.open(candidate, "w"))
				assert(stale:write(content))
				assert(stale:close())
				return true
			end,
			write_if_unchanged = function(candidate, _content, expected_source)
				publications = publications + 1
				helpers.assert_eq(expected_source,
					{ status = "ok", content = SENTINEL },
					"the exact patch input must cross the publication boundary")
				local competitor = assert(io.open(candidate, "w"))
				assert(competitor:write(external))
				assert(competitor:close())
				return false, "source changed"
			end,
		}
		local win = helpers.load_with_stubs("ui.hotstrings_config_window")
		local notifications = 0
		win._on_config_changed = function() notifications = notifications + 1 end

		helpers.assert_eq(win._on_message({ body = {
			action = "set_delay", group = "personal", personal_path = path, ms = 420,
		} }), false)
		helpers.assert_eq(publications, 1)
		helpers.assert_eq(read_fixture(path), external,
			"the external winner must survive byte-for-byte")
		helpers.assert_eq(notifications, 0,
			"a stale personal patch must publish no runtime/UI state")
		os.remove(path)
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 2/ Reader Commit Bit Is Authoritative =======
-- =====================================================
-- =====================================================

helpers.describe("hotstrings config window: incomplete TOML reads are withheld", function()
	helpers.it("omits personal and extension entries returned with committed=false", function()
		install_config_stub()
		package.loaded["adapters.file_system"] = {
			read_with_status = function() return nil, "absent", "not found" end,
			write = function() return true end,
		}
		package.loaded["infra.toml.reader"] = {
			parse = function()
				return {
					meta = { delay = 0.99, sections = {} },
					sections = {},
					sections_order = {},
				}, false
			end,
		}
		package.loaded["infra.fs_dir"] = {
			entries = function(dir)
				if dir == "/personal" then return { "private.toml" } end
				if dir == "/extensions" then return { "demo" } end
				if dir == "/extensions/demo/hotstrings" then return { "extension.toml" } end
				return {}
			end,
		}

		local win = helpers.load_with_stubs("ui.hotstrings_config_window", {
			fs = {
				attributes = function(path)
					if path == "/extensions/demo" then return { mode = "directory" } end
					return nil
				end,
			},
		})
		win.setup({ personal_dir = "/personal", extensions_dir = "/extensions" })
		local build_state = find_upvalue(win._on_message, "build_state")
		helpers.assert_type(build_state, "function",
			"the real bridge handler must retain its canonical state builder")
		local state = build_state()

		local saw_personal_group = false
		local saw_extension_group = false
		for _, group in ipairs(state.groups) do
			if group.key == "personal" then saw_personal_group = true end
			if group.key == "ext:demo" then saw_extension_group = true end
		end
		helpers.assert_eq(saw_personal_group, false,
			"a discovered file is not readable merely because its directory entry exists")
		helpers.assert_eq(saw_extension_group, false,
			"an extension group with no committed file must be withheld")
		for _, category in ipairs(state.categories) do
			helpers.assert_true(category.name ~= "personal:private",
				"uncommitted personal bytes must not become a fake category")
			helpers.assert_true(category.name ~= "ext:demo:extension",
				"uncommitted extension bytes must not become a fake category")
		end
	end)
end)
