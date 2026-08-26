--- tests/unit/infra/test_factory_reset_journal.lua

--- ==============================================================================
--- MODULE: Durable Factory-Reset Journal
--- DESCRIPTION:
--- A factory reset moves configuration files immediately before handing off a
--- process reload. This regression drives the durable owner through a simulated
--- process death and proves that the next boot can distinguish an uncommitted
--- reset from an accepted one without guessing from backup filenames.
--- ==============================================================================

local helpers = require("tests.helpers")
local JsonCodec = require("adapters.json_codec")
local FactoryResetJournal = require("infra.factory_reset_journal")

local function memory_file_system()
	local nodes = {}
	local next_inode = 10
	local function publish(path, content)
		next_inode = next_inode + 1
		nodes[path] = { content = content, dev = 1, ino = next_inode }
	end
	local fs = {}
	function fs.seed(path, content) publish(path, content) end
	function fs.identity(path)
		local node = nodes[path]
		return node and { dev = node.dev, ino = node.ino } or nil
	end
	function fs.content(path) return nodes[path] and nodes[path].content or nil end
	function fs.read_with_status(path)
		local node = nodes[path]
		if node then return node.content, "ok" end
		return nil, "absent"
	end
	function fs.create_if_absent(path, content)
		if nodes[path] then return false, "destination exists" end
		publish(path, content)
		return true
	end
	function fs.write_if_unchanged(path, content, expected)
		helpers.assert_type(expected, "table", "CAS proof must mirror the production adapter")
		helpers.assert_eq(expected.status, "ok", "journal transitions replace a present file")
		local node = nodes[path]
		if not node or node.content ~= expected.content then return false, "source changed" end
		publish(path, content)
		return true
	end
	function fs.classify_no_follow(path)
		local node = nodes[path]
		if not node then return nil, "absent" end
		return { mode = "file", dev = node.dev, ino = node.ino }, "ok"
	end
	function fs.acquire_write_locks(paths)
		local resolved = {}
		for _, path in ipairs(paths) do resolved[path] = path end
		return { resolved_paths = resolved }, true
	end
	function fs.release_write_locks(_owner) return true end
	function fs.hard_link_create_only(source, destination)
		if not nodes[source] or nodes[destination] then return false, "link precondition" end
		nodes[destination] = nodes[source]
		return true
	end
	function fs.remove_exact(path)
		if not nodes[path] then return false, "path absent" end
		nodes[path] = nil
		return true
	end
	function fs.move_to_backup(source, backup)
		helpers.assert_true(fs.hard_link_create_only(source, backup))
		helpers.assert_true(fs.remove_exact(source))
	end
	return fs
end

local function new_owner(fs, journal_path)
	local owner, detail = FactoryResetJournal.create(journal_path, {
		file_system = fs,
		json_codec = JsonCodec,
	})
	helpers.assert_true(type(owner) == "table", "journal owner must be constructed: " .. tostring(detail))
	return owner
end

local function captured_entry(fs, source, backup)
	return {
		path = source,
		backup = backup,
		existed = true,
		identity = fs.identity(source),
	}
end

helpers.describe("factory-reset journal survives process death", function()
	helpers.it("restores a prepared move before boot reads the configuration", function()
		local fs = memory_file_system()
		local source = "/config/config.toml"
		local backup = source .. ".ergopti-reset-backup-100-1"
		local untouched_source = "/config/config_karabiner.toml"
		local untouched_backup = untouched_source .. ".ergopti-reset-backup-100-2"
		local absent_source = "/config/optional.toml"
		local absent_backup = absent_source .. ".ergopti-reset-backup-100-3"
		local journal_path = FactoryResetJournal.path_for(source)
		fs.seed(source, "user bytes")
		fs.seed(untouched_source, "karabiner bytes")

		local first = new_owner(fs, journal_path)
		helpers.assert_eq(true, first:prepare({
			captured_entry(fs, source, backup),
			captured_entry(fs, untouched_source, untouched_backup),
			{ path = absent_source, backup = absent_backup, existed = false },
		}))
		local persisted = JsonCodec.decode(fs.content(journal_path))
		helpers.assert_type(persisted.entries[1].identity.dev, "string",
			"inode values must avoid lossy JSON number encoding")
		helpers.assert_type(persisted.entries[1].identity.ino, "string",
			"inode values must avoid lossy JSON number encoding")
		fs.move_to_backup(source, backup)

		local next_boot = new_owner(fs, journal_path)
		helpers.assert_eq(true, next_boot:reconcile())
		helpers.assert_eq("user bytes", fs.content(source), "prepared bytes must return to the canonical path")
		helpers.assert_eq(nil, fs.content(backup), "the recovery shadow must be consumed exactly once")
		helpers.assert_eq("karabiner bytes", fs.content(untouched_source),
			"an entry not yet moved when the process died must remain unchanged")
		helpers.assert_eq(nil, fs.content(untouched_backup),
			"reconciliation must not fabricate a shadow for an untouched entry")
		helpers.assert_eq(nil, fs.content(absent_source),
			"a path absent before reset must remain absent")
		helpers.assert_eq(nil, fs.content(absent_backup),
			"an absent path must not gain a recovery shadow")
		helpers.assert_eq("cleared", next_boot:phase(), "boot recovery must durably settle the journal")
	end)

	helpers.it("finalizes an accepted reset instead of undoing it", function()
		local fs = memory_file_system()
		local source = "/config/config.toml"
		local backup = source .. ".ergopti-reset-backup-200-1"
		local journal_path = FactoryResetJournal.path_for(source)
		fs.seed(source, "user bytes")

		local first = new_owner(fs, journal_path)
		helpers.assert_eq(true, first:prepare({ captured_entry(fs, source, backup) }))
		fs.move_to_backup(source, backup)
		helpers.assert_eq(true, first:mark_commit())

		local next_boot = new_owner(fs, journal_path)
		helpers.assert_eq(true, next_boot:reconcile())
		helpers.assert_eq(nil, fs.content(source), "a committed reset must keep the canonical path absent")
		helpers.assert_eq(nil, fs.content(backup), "committed user bytes must not remain as an orphan shadow")
		helpers.assert_eq("cleared", next_boot:phase(), "commit cleanup must durably settle the journal")
	end)

	helpers.it("refuses a replaced recovery shadow without overwriting either path", function()
		local fs = memory_file_system()
		local source = "/config/config.toml"
		local backup = source .. ".ergopti-reset-backup-300-1"
		local journal_path = FactoryResetJournal.path_for(source)
		fs.seed(source, "user bytes")

		local first = new_owner(fs, journal_path)
		helpers.assert_eq(true, first:prepare({ captured_entry(fs, source, backup) }))
		fs.move_to_backup(source, backup)
		fs.seed(backup, "replacement bytes")

		local next_boot = new_owner(fs, journal_path)
		helpers.assert_eq(false, next_boot:reconcile())
		helpers.assert_eq(nil, fs.content(source), "an untrusted replacement must not be restored")
		helpers.assert_eq("replacement bytes", fs.content(backup), "conflicting bytes must remain inspectable")
		helpers.assert_eq("prepared", next_boot:phase(), "the unresolved durable decision must remain owned")
	end)
end)
