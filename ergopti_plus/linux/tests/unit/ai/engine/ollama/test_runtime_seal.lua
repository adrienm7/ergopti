--- tests/unit/ai/engine/ollama/test_runtime_seal.lua

--- ==============================================================================
--- MODULE: Managed Ollama Runtime Seal Regression Cases
--- DESCRIPTION:
--- The seal binds every file of the installed tree to the pinned archive, and
--- its retention removes only Ergopti's own earlier release folders.
---
--- ROOT CAUSE ENCODED:
--- OLL-08: Linux admitted an installed runtime on its metadata alone and never
--- re-hashed it, while Windows re-hashes every file and macOS its binary.
--- OLL-07: a runtime update installed beside the earlier release and nothing
--- removed the earlier one (about 1.4 GB per update).
--- ==============================================================================

local helpers = require("tests.helpers")
local Seal = helpers.load_module("ai.engine.ollama.runtime_seal")
local Retention = helpers.load_module("ai.engine.ollama.runtime_retention")

local ROOT = "/data/runtimes/ollama/0.40.6-linux-amd64-" .. string.rep("c", 64) .. "/ollama"
local FILES = { ROOT .. "/bin/ollama", ROOT .. "/lib/ollama/libggml.so" }
local SHA = string.rep("c", 64)

local function receipt(digests)
	local rows = {}
	for index, path in ipairs(FILES) do rows[#rows + 1] = digests[index] .. "  " .. path .. "\0" end
	return { ok = true, exit_code = 0, stdout = table.concat(rows) }
end
local DIGESTS = { string.rep("1", 64), string.rep("2", 64) }

helpers.describe("Managed Ollama runtime seal (oll-08)", function()
	helpers.it("(oll-08) hashes every file in one shell-free sha256sum child", function()
		local program, args = Seal.command(FILES)
		helpers.assert_eq(program, "sha256sum")
		helpers.assert_eq(table.concat(args, " "), "--zero -- " .. table.concat(FILES, " "))
	end)

	helpers.it("(oll-08) a receipt must name exactly the hashed files, each once", function()
		local digests = assert(Seal.digests(receipt(DIGESTS), FILES))
		helpers.assert_eq(digests[FILES[2]], DIGESTS[2])
		local short = receipt(DIGESTS); short.stdout = short.stdout:match("^[^%z]*%z")
		helpers.assert_eq(select(2, Seal.digests(short, FILES)), "runtime_seal_hash_failed")
		local foreign = { ok = true, exit_code = 0, stdout = DIGESTS[1] .. "  /elsewhere\0" .. DIGESTS[2] .. "  " .. FILES[2] .. "\0" }
		helpers.assert_nil(Seal.digests(foreign, FILES))
		helpers.assert_nil(Seal.digests({ ok = false, exit_code = 1, stdout = "" }, FILES))
	end)

	helpers.it("(oll-08) a seal matches only the same bytes of the same archive", function()
		local digests = assert(Seal.digests(receipt(DIGESTS), FILES))
		local text = assert(Seal.encode(ROOT, digests, SHA))
		helpers.assert_eq(Seal.matches(text, ROOT, digests, SHA), true)
		local changed = assert(Seal.digests(receipt({ DIGESTS[1], string.rep("3", 64) }), FILES))
		helpers.assert_eq(select(2, Seal.matches(text, ROOT, changed, SHA)), "runtime_seal_mismatch")
		helpers.assert_eq(select(2, Seal.matches(text, ROOT, digests, string.rep("d", 64))), "runtime_seal_foreign")
		local fewer = { [FILES[1]] = DIGESTS[1] }
		helpers.assert_eq(select(2, Seal.matches(text, ROOT, fewer, SHA)), "runtime_seal_mismatch")
		helpers.assert_eq(select(2, Seal.matches("not json", ROOT, digests, SHA)), "runtime_seal_unreadable")
	end)

	helpers.it("(oll-08) the seal is read and written through its own file port", function()
		local stored
		local fs = { read = function() return stored end, write = function(_, text) stored = text; return true end }
		helpers.assert_true(Seal.write("/x/" .. Seal.NAME, "seal", fs))
		helpers.assert_eq(Seal.read("/x/" .. Seal.NAME, fs), "seal")
		helpers.assert_eq(Seal.write("/x", "seal", { write = function() error("disk") end }), false)
	end)
end)

helpers.describe("Managed Ollama runtime retention (oll-07)", function()
	local plan = { runtime = "/data/runtimes/ollama", parent = "/data/runtimes/ollama/0.40.6-linux-amd64-" .. SHA, uid = 1000 }
	local function fs(entries)
		local names = {}
		for name in pairs(entries) do names[#names + 1] = name end
		table.sort(names)
		local index = 0
		return {
			fs_scandir = function() return {} end,
			fs_scandir_next = function() index = index + 1; return names[index] end,
			fs_lstat = function(path) return entries[path:match("[^/]+$")] end,
		}
	end

	helpers.it("(oll-07) lists only Ergopti's own earlier release folders, never the pinned one", function()
		local old = "0.24.0-linux-amd64-" .. string.rep("a", 64)
		local paths = assert(Retention.stale(plan, fs({
			[old] = { type = "directory", uid = 1000 },
			["0.40.6-linux-amd64-" .. SHA] = { type = "directory", uid = 1000 },
			["0.30.0-linux-amd64-" .. string.rep("b", 64)] = { type = "link", uid = 1000 },
			["0.31.0-linux-amd64-" .. string.rep("e", 64)] = { type = "directory", uid = 0 },
			["notes"] = { type = "directory", uid = 1000 },
			["0.32.0-linux-amd64-abc"] = { type = "directory", uid = 1000 },
		})))
		helpers.assert_eq(#paths, 1)
		helpers.assert_eq(paths[1], plan.runtime .. "/" .. old)
	end)

	helpers.it("(oll-07) an unreadable runtime folder is reported, not taken for an empty one", function()
		local paths, reason = Retention.stale(plan, { fs_scandir = function() return nil end })
		helpers.assert_nil(paths)
		helpers.assert_eq(reason, "runtime_retention_scan_refused")
	end)

	helpers.it("(oll-07) removes through one rm child that never follows links, and reports a refusal", function()
		local calls = {}
		local process = { start = function(program, args, options, done)
			calls[#calls + 1] = { program = program, args = args, options = options, done = done }
			return { is_settled = function() return false end }
		end }
		local outcome
		helpers.assert_true(Retention.remove({ "/data/runtimes/ollama/old" }, process, 50, "the earlier runtimes",
			function(removed) outcome = removed end) ~= nil)
		helpers.assert_eq(calls[1].program, "rm")
		helpers.assert_eq(table.concat(calls[1].args, " "), "-r --one-file-system -- /data/runtimes/ollama/old")
		helpers.assert_eq(calls[1].options.timeout_ms, 50)
		calls[1].done({ ok = false, exit_code = 1, stderr = "Permission denied" })
		helpers.assert_eq(outcome, false)
		helpers.assert_nil(Retention.remove({}, process, 50, "nothing"))
		helpers.assert_eq(#calls, 1)
	end)
end)

return true
