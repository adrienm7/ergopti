--- tests/unit/ui/menu/test_recoverable_file_moves_capability.lua

--- ==============================================================================
--- MODULE: Recoverable File Move Capability Regression
--- DESCRIPTION:
--- Exercises the production hard-link/unlink state machine through faithful
--- inode, lock, collision, symlink, and mutate-before-refusal doubles.
---
--- FEATURES & RATIONALE:
--- 1. Exact Target: A destination directory is a collision, never a move target.
--- 2. Owned Identity: Both path locks survive until reload handoff or exact inverse.
--- 3. Retry Debt: Every false, nil, and throw retains the observed inode phase.
--- ==============================================================================

local helpers = require("tests.helpers")

local SOURCE = "/config.toml"
local BACKUP = "/config.toml.backup"

local function node(mode, ino, content)
	return { mode = mode, dev = 7, ino = ino, content = content }
end

local function count_keys(values)
	local count = 0
	for _ in pairs(values) do count = count + 1 end
	return count
end

local function result_for_mode(mode, mutate)
	local after = type(mode) == "string" and mode:find("%-after$", 1, false) ~= nil
	if after then mutate() end
	if mode == "throw" or mode == "throw-after" then error("synthetic native throw") end
	if mode == "nil" or mode == "nil-after" then return nil, "synthetic nil" end
	if mode == "false" or mode == "false-after" then return false, "synthetic false" end
	if not after then mutate() end
	return true
end

local function make_fixture(initial_nodes)
	local fixture = {
		nodes = initial_nodes or { [SOURCE] = node("file", 101, "old bytes") },
		locks = {},
		link_calls = 0,
		remove_calls = 0,
		release_calls = 0,
		writer_attempts = 0,
	}

	local function clone_attributes(value)
		if type(value) ~= "table" then return nil end
		return {
			mode = value.mode,
			dev = value.dev,
			ino = value.ino,
			size = type(value.content) == "string" and #value.content or 0,
		}
	end

	function fixture.acquire_write_locks(paths)
		local ordered = {}
		for index, path in ipairs(paths) do ordered[index] = path end
		table.sort(ordered)
		for _, path in ipairs(ordered) do
			if fixture.locks[path] then return nil, false, "locked" end
		end
		local group = { paths = ordered, resolved_paths = {} }
		for _, path in ipairs(ordered) do
			fixture.locks[path] = group
			group.resolved_paths[path] = path
		end
		return group, true
	end

	function fixture.release_write_locks(group)
		fixture.release_calls = fixture.release_calls + 1
		local mode = fixture.next_release_mode
		fixture.next_release_mode = nil
		return result_for_mode(mode, function()
			for _, path in ipairs(group.paths or {}) do
				if fixture.locks[path] == group then fixture.locks[path] = nil end
			end
		end)
	end

	function fixture.classify_no_follow(path)
		if fixture.identity_hook then fixture.identity_hook(path, fixture) end
		local current = fixture.nodes[path]
		if current == nil then return nil, "absent" end
		return clone_attributes(current), "ok"
	end

	function fixture.read_with_status(path)
		local current = fixture.nodes[path]
		if current == nil then return nil, "absent" end
		if current.mode ~= "file" then return nil, "error", "not a regular file" end
		return current.content, "ok"
	end

	function fixture.hard_link_create_only(source, destination)
		fixture.link_calls = fixture.link_calls + 1
		if fixture.link_hook then
			local handled, result, detail = fixture.link_hook(source, destination, fixture)
			if handled then return result, detail end
		end
		local mode = fixture.next_link_mode
		fixture.next_link_mode = nil
		return result_for_mode(mode, function()
			local source_node = fixture.nodes[source]
			if type(source_node) ~= "table" or source_node.mode ~= "file"
				or fixture.nodes[destination] ~= nil then return end
			fixture.nodes[destination] = node(
				"file", source_node.ino, source_node.content)
		end)
	end

	function fixture.remove_exact(path)
		fixture.remove_calls = fixture.remove_calls + 1
		local mode = fixture.next_remove_mode
		fixture.next_remove_mode = nil
		return result_for_mode(mode, function() fixture.nodes[path] = nil end)
	end

	function fixture.try_writer(path, content)
		fixture.writer_attempts = fixture.writer_attempts + 1
		if fixture.locks[path] ~= nil then return false end
		fixture.nodes[path] = node("file", 900 + fixture.writer_attempts, content)
		return true
	end

	local module = helpers.load_with_stubs("ui.menu.recoverable_file_moves")
	fixture.mover = module.create({
		read_with_status = fixture.read_with_status,
		classify_no_follow = fixture.classify_no_follow,
		acquire_write_locks = fixture.acquire_write_locks,
		release_write_locks = fixture.release_write_locks,
		hard_link_create_only = fixture.hard_link_create_only,
		remove_exact = fixture.remove_exact,
		backup_path = function() return BACKUP end,
	})
	return fixture
end

helpers.describe("recoverable file moves: owned hard-link capability", function()
	helpers.it("retains both ordered locks through the forward move and exact inverse", function()
		local fixture = make_fixture()
		local entry = fixture.mover.capture(SOURCE)
		helpers.assert_type(entry, "table")
		helpers.assert_eq(entry.capture_valid, true)
		helpers.assert_eq(count_keys(fixture.locks), 2)
		helpers.assert_eq(entry.locks.paths[1], SOURCE)
		helpers.assert_eq(entry.locks.paths[2], BACKUP)

		helpers.assert_eq(fixture.mover.move(entry), true)
		helpers.assert_nil(fixture.nodes[SOURCE])
		helpers.assert_eq(fixture.nodes[BACKUP].content, "old bytes")
		helpers.assert_eq(fixture.try_writer(SOURCE, "nested writer"), false)
		helpers.assert_eq(fixture.mover.restore(entry), true)
		helpers.assert_eq(fixture.nodes[SOURCE].content, "old bytes")
		helpers.assert_nil(fixture.nodes[BACKUP])
		helpers.assert_eq(count_keys(fixture.locks), 0)
	end)

	helpers.it("rejects a final symlink before hard-link publication", function()
		local fixture = make_fixture({
			[SOURCE] = node("link", 201),
			["/target.toml"] = node("file", 202, "target bytes"),
		})
		local entry = fixture.mover.capture(SOURCE)
		helpers.assert_type(entry, "table",
			"the retained lock capability must remain journalable on capture refusal")
		helpers.assert_eq(entry.capture_valid, false)
		helpers.assert_eq(fixture.mover.move(entry), false)
		helpers.assert_eq(fixture.link_calls, 0)
		helpers.assert_eq(fixture.nodes["/target.toml"].content, "target bytes")
		helpers.assert_eq(fixture.mover.restore(entry), true)
		helpers.assert_eq(count_keys(fixture.locks), 0)
	end)

	helpers.it("treats a destination directory created at the link boundary as an exact collision", function()
		local fixture = make_fixture()
		fixture.link_hook = function(_source, destination, state)
			state.nodes[destination] = node("directory", 303)
			return true, false, "destination appeared"
		end
		local entry = fixture.mover.capture(SOURCE)
		helpers.assert_eq(fixture.mover.move(entry), false)
		helpers.assert_eq(fixture.nodes[SOURCE].content, "old bytes")
		helpers.assert_eq(fixture.nodes[BACKUP].mode, "directory")
		helpers.assert_nil(fixture.nodes[BACKUP .. "/config.toml"],
			"an exact hard-link target cannot reinterpret the destination as a directory")
		helpers.assert_eq(fixture.mover.restore(entry), false,
			"the foreign directory remains untouched and the capability remains fenced")
	end)

	for _, mode in ipairs({ "false", "nil", "throw", "false-after", "nil-after", "throw-after" }) do
		helpers.it("retains exact link phase after " .. mode, function()
			local fixture = make_fixture()
			fixture.next_link_mode = mode
			local entry = fixture.mover.capture(SOURCE)
			helpers.assert_eq(fixture.mover.move(entry), false)
			helpers.assert_eq(fixture.nodes[SOURCE].content, "old bytes")
			helpers.assert_eq(fixture.mover.restore(entry), true)
			helpers.assert_eq(fixture.nodes[SOURCE].content, "old bytes")
			helpers.assert_nil(fixture.nodes[BACKUP])
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw", "false-after", "nil-after", "throw-after" }) do
		helpers.it("retains exact source-unlink phase after " .. mode, function()
			local fixture = make_fixture()
			fixture.next_remove_mode = mode
			local entry = fixture.mover.capture(SOURCE)
			helpers.assert_eq(fixture.mover.move(entry), false)
			helpers.assert_eq(fixture.mover.restore(entry), true)
			helpers.assert_eq(fixture.nodes[SOURCE].content, "old bytes")
			helpers.assert_nil(fixture.nodes[BACKUP])
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw", "false-after", "nil-after", "throw-after" }) do
		helpers.it("retries inverse hard-link debt after " .. mode, function()
			local fixture = make_fixture()
			local entry = fixture.mover.capture(SOURCE)
			helpers.assert_eq(fixture.mover.move(entry), true)
			fixture.next_link_mode = mode
			helpers.assert_eq(fixture.mover.restore(entry), false)
			helpers.assert_eq(fixture.mover.restore(entry), true)
			helpers.assert_eq(fixture.nodes[SOURCE].content, "old bytes")
			helpers.assert_nil(fixture.nodes[BACKUP])
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw", "false-after", "nil-after", "throw-after" }) do
		helpers.it("retries inverse-unlink debt after " .. mode, function()
			local fixture = make_fixture()
			local entry = fixture.mover.capture(SOURCE)
			helpers.assert_eq(fixture.mover.move(entry), true)
			fixture.next_remove_mode = mode
			helpers.assert_eq(fixture.mover.restore(entry), false)
			helpers.assert_eq(fixture.mover.restore(entry), true)
			helpers.assert_eq(fixture.nodes[SOURCE].content, "old bytes")
			helpers.assert_nil(fixture.nodes[BACKUP])
		end)
	end

	helpers.it("never overwrites a regular-file or directory source collision during inverse", function()
		for _, collision_mode in ipairs({ "file", "directory" }) do
			local fixture = make_fixture()
			local entry = fixture.mover.capture(SOURCE)
			helpers.assert_eq(fixture.mover.move(entry), true)
			fixture.nodes[SOURCE] = node(collision_mode, 404, "foreign")
			helpers.assert_eq(fixture.mover.restore(entry), false)
			helpers.assert_eq(fixture.nodes[SOURCE].ino, 404)
			helpers.assert_eq(fixture.nodes[BACKUP].ino, 101)
		end
	end)

	for _, mode in ipairs({ "false", "nil", "throw", "false-after", "nil-after", "throw-after" }) do
		helpers.it("retains lock-release debt after " .. mode, function()
			local fixture = make_fixture()
			local entry = fixture.mover.capture(SOURCE)
			helpers.assert_eq(fixture.mover.move(entry), true)
			fixture.next_release_mode = mode
			helpers.assert_eq(fixture.mover.restore(entry), false)
			helpers.assert_eq(fixture.mover.restore(entry), true)
			helpers.assert_eq(count_keys(fixture.locks), 0)
		end)
	end

	helpers.it("refuses a same-bytes ABA inode replacement", function()
		local fixture = make_fixture()
		local entry = fixture.mover.capture(SOURCE)
		fixture.nodes[SOURCE] = node("file", 777, "old bytes")
		helpers.assert_eq(fixture.mover.move(entry), false)
		helpers.assert_eq(fixture.link_calls, 0)
		helpers.assert_eq(fixture.nodes[SOURCE].ino, 777)
		helpers.assert_eq(fixture.mover.restore(entry), false,
			"foreign identity must never become rollback fodder")
	end)

	helpers.it("blocks a cooperating writer from the terminal identity-probe tail", function()
		local fixture = make_fixture()
		local entry = fixture.mover.capture(SOURCE)
		local attempted = false
		fixture.identity_hook = function(path, state)
			if not attempted and state.remove_calls > 0 and path == SOURCE then
				attempted = true
				state.nested_writer_result = state.try_writer(SOURCE, "late writer")
			end
		end
		helpers.assert_eq(fixture.mover.move(entry), true)
		helpers.assert_true(attempted)
		helpers.assert_eq(fixture.nested_writer_result, false)
		helpers.assert_nil(fixture.nodes[SOURCE])
		helpers.assert_eq(fixture.nodes[BACKUP].content, "old bytes")
	end)
end)

return true
