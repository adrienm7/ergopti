--- tests/unit/infra/config/test_stage_owner.lua

--- ==============================================================================
--- MODULE: Atomic-Write Stage Ownership Tests
--- DESCRIPTION:
--- CFD-1 (decided by the maintainer on 2026-11-11): Linux names each staging
--- file after its process (pid and kernel start tick), so a stage a killed
--- process left never blocks a later write, and reaps at start the stages of
--- a dead Ergopti process, as Windows does; a foreign stage is never touched.
--- ==============================================================================

local helpers = require("tests.helpers")

local SELF_STAT = "4242 (luajit) S 1 4242 4242 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 987654 0 0\n"

--- A /proc reader over fixed stat texts.
--- @param stats table path -> text
local function reader(stats)
	return function(path) return stats[path] end
end

--- Builds a stat line for a pid, state and start tick.
local function stat_of(pid, state, start)
	return string.format("%d (ergopti (lua)) %s 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %d 0 0\n", pid, state, start)
end

helpers.describe("CFD-1: per-process stages and their reaping (cfd1-stage-owner)", function()
	helpers.it("names the stage after the pid and the kernel start tick (cfd1-stage-owner)", function()
		local Owner = require("core.lifecycle.engine.stage_owner")
		Owner._set_reader_for_test(reader({ ["/proc/self/stat"] = SELF_STAT }))
		helpers.assert_eq(Owner.stage_path("/cfg/config.toml"), "/cfg/config.toml.ergopti-4242-987654.tmp")
		Owner._set_reader_for_test(nil)
	end)

	helpers.it("tells a dead or reused owner from a live one (cfd1-stage-owner)", function()
		local Owner = require("core.lifecycle.engine.stage_owner")
		Owner._set_reader_for_test(reader({
			["/proc/self/stat"] = SELF_STAT,
			["/proc/100/stat"] = stat_of(100, "S", 555),
			["/proc/101/stat"] = stat_of(101, "Z", 777),
		}))
		helpers.assert_eq(Owner.owner_gone("4242", "987654"), false, "this process is never gone")
		helpers.assert_eq(Owner.owner_gone("100", "555"), false, "a live owner keeps its stage")
		helpers.assert_eq(Owner.owner_gone("100", "554"), true, "a reused pid is another process")
		helpers.assert_eq(Owner.owner_gone("101", "777"), true, "a zombie has exited")
		helpers.assert_eq(Owner.owner_gone("102", "1"), true, "no such process")
		Owner._set_reader_for_test(nil)
	end)

	helpers.it("reaps only old stages of a dead Ergopti process (cfd1-stage-owner)", function()
		local Owner = require("core.lifecycle.engine.stage_owner")
		Owner._set_reader_for_test(reader({
			["/proc/self/stat"] = SELF_STAT,
			["/proc/100/stat"] = stat_of(100, "S", 555),
		}))
		local names = {
			"config.toml.ergopti-200-9.tmp",      -- dead, old: removed
			"storage.json.ergopti-201-9.tmp",     -- dead, old: removed
			"config.toml.ergopti-202-9.tmp",      -- dead, young: kept
			"config.toml.ergopti-100-555.tmp",    -- live owner: kept
			"config.toml.ergopti-4242-987654.tmp", -- this process: kept
			"config.toml.tmp",                    -- foreign: kept
			"notes.txt",                          -- unrelated: kept
		}
		local entries, stats, removed = {}, {}, {}
		for _, name in ipairs(names) do
			entries[#entries + 1] = { name = name, type = "file" }
			stats["/cfg/" .. name] = { kind = "file", modified = name:find("202", 1, true) and 995 or 0 }
		end
		local directory = {
			entries = function() return entries end,
			join = function(parent, name) return parent .. "/" .. name end,
			stat = function(path) return stats[path] end,
		}
		local real_remove = os.remove
		os.remove = function(path) removed[#removed + 1] = path; return true end
		local ok, count, kept = pcall(Owner.reap, "/cfg", { directory = directory, now = 1000, max_age_ms = 60000 })
		os.remove = real_remove
		Owner._set_reader_for_test(nil)
		if not ok then error(count, 0) end
		table.sort(removed)
		helpers.assert_eq(removed, { "/cfg/config.toml.ergopti-200-9.tmp", "/cfg/storage.json.ergopti-201-9.tmp" })
		helpers.assert_eq({ count, kept }, { 2, 3 })
	end)

	helpers.it("publishes past a stage a killed process left (cfd1-stage-owner)", function()
		local Writer = require("core.text.engine.toml_codec.writer")
		local dir = os.tmpname()
		os.remove(dir)
		assert(os.execute("mkdir -p '" .. dir .. "'"))
		local path = dir .. "/config.toml"
		local function write(candidate, bytes)
			local fh = assert(io.open(candidate, "wb")); assert(fh:write(bytes)); assert(fh:close())
		end
		write(path, "[shortcuts]\nenabled = false\n")
		-- What the driver left at a kill before CFD-1, and what a dead process leaves now.
		write(path .. ".tmp", "half a write")
		write(path .. ".ergopti-1-1.tmp", "half a write")
		local committed, detail = Writer.batch_write(path,
			{ { section = "shortcuts", key = "enabled", value = true } })
		local fh = io.open(path, "rb"); local after = fh and fh:read("*a"); if fh then fh:close() end
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_eq(committed, true, "a leftover stage blocked the write: " .. tostring(detail))
		helpers.assert_true(after:find("enabled = true", 1, true) ~= nil)
	end)
end)
