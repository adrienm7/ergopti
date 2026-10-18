--- tests/unit/modules/llm/runtime/test_runtime_source_snapshot.lua

--- ==============================================================================
--- MODULE: Fresh Runtime Source Snapshot Admission
--- DESCRIPTION:
--- Keeps every runtime chunk tied to fresh source bytes without repeatedly
--- decoding the same source merely to check its acknowledged revision.
--- ==============================================================================

local helpers = require("tests.helpers")
local Source = helpers.load_module("modules.llm.runtime_source")

local function world()
	local w = { revision = 1, bytes = "original", reads = 0, generation_reads = 0, allowed = true,
		state = { backend = "ollama", model = "fixture", origin = "http://127.0.0.1:11434",
			revision = 4, app_epoch = 3, enabled = false, paused = false, blocked = false } }
	local function invoke(name)
		local callback = w[name]
		if callback then w[name] = nil; callback() end
	end
	local preferences = {}
	function preferences.get_many()
		w.reads = w.reads + 1
		local revision, bytes = w.revision, w.bytes
		local values = { ["llm.models.selected"] = "ollama", ["llm.models.ollama"] = "fixture", ["llm.enabled"] = false }
		invoke("on_lookup")
		if w.missing_revision then revision = nil end
		return values, { status = "ok", content = bytes }, revision
	end
	function preferences.generation() w.generation_reads = w.generation_reads + 1; return w.revision end
	function preferences.is_current_revision(revision) return w.allowed and revision == w.revision end
	function preferences.admit() invoke("on_admit"); return w.allowed end
	local profiles = { enable = function() return false end, disable = function() return false end }
	function profiles.is_enabled() invoke("on_enabled"); return false end
	local engine = { publish_enabled = function() return false end, restore_disabled = function() return false end,
		admit_write = function() return false end }
	function engine.state()
		invoke("on_native")
		local copy = {}; for key, value in pairs(w.state) do copy[key] = value end
		return copy
	end
	w.source = Source.new({ backend_key = "llm.models.selected", path = "/fixture/config.toml",
		preferences = preferences, profiles = profiles, engine = engine,
		writer = { prepare_batch = function() return false end },
		manifest = { find_entry_by_path = function() return {} end, sparse_operation = function() return {} end } })
	w.handle = assert(w.source.capture())
	w.reads, w.generation_reads = 0, 0
	function w.write_same_bytes() w.revision = w.revision + 1 end
	return w
end

helpers.describe("fresh runtime source snapshot", function()
	helpers.it("reads fresh bytes once per admission without generation rereads", function()
		local w = world()
		helpers.assert_true(w.source.current(w.handle))
		helpers.assert_eq(w.reads, 1)
		helpers.assert_eq(w.generation_reads, 0)
		w.bytes = "external source edit"
		w.revision = w.revision + 1
		helpers.assert_eq(w.source.current(w.handle), false)
	end)
	for _, phase in ipairs({ "on_lookup", "on_native", "on_enabled", "on_admit" }) do
		helpers.it("refuses an acknowledged same-byte write during " .. phase, function()
			local w = world(); w[phase] = w.write_same_bytes
			helpers.assert_eq(w.source.current(w.handle), false)
		end)
		helpers.it("refuses acquired source ownership during " .. phase, function()
			local w = world(); w[phase] = function() w.allowed = false end
			helpers.assert_eq(w.source.current(w.handle), false)
		end)
	end
	helpers.it("refuses a native epoch ABA during the profile callback", function()
		local w = world()
		w.on_enabled = function() w.state.app_epoch = w.state.app_epoch + 2 end
		helpers.assert_eq(w.source.current(w.handle), false)
	end)
	helpers.it("keeps the original native model and origin after lookup callbacks", function()
		for _, field in ipairs({ "model", "origin", "backend" }) do
			local w = world(); w.on_lookup = function() w.state[field] = "replacement" end
			helpers.assert_eq(w.source.current(w.handle), false)
		end
	end)
	helpers.it("refuses a preference port that omits its exact snapshot revision", function()
		local w = world(); w.missing_revision = true
		helpers.assert_eq(w.source.current(w.handle), false)
	end)
end)
