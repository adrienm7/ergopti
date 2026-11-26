--- tests/unit/ai/engine/ollama/test_install_admission.lua

--- ==============================================================================
--- MODULE: Owned Ollama Installation Regression Cases
--- DESCRIPTION:
--- Registers independent controlled receipts through the normal Linux helpers.
--- Native archive, HTTP, process and installation acceptance are separate gates.
--- ==============================================================================

local helpers = require("tests.helpers")
local function expect(value, message) assert(value, message) end
local function test(name, body) helpers.it(name .. " (ollama-install)", body) end
local Admission = helpers.load_module("ai.engine.ollama.install_admission")
local function fixture(consent, reuse)
	local f = { source = true, ancestry = true, calls = {}, parent_prepared = false, walks = 0 }
	local resolver = {
		plan = function() return { directory = "/private/release/ollama" } end,
		current = function() f.walks = f.walks + 1; return f.ancestry, "install_ancestor_substituted" end,
		prepare = function(admission)
			f.calls[#f.calls + 1] = "parent"
			assert(admission.explicit_consent == true and admission.authorized() == true)
			f.parent_prepared = true
			if f.after_parent then f.after_parent() end
			return true
		end,
	}
	local files = { directory = "/private/release/ollama", published = false }
	for _, name in ipairs({ "prepare", "admit_size", "hash_command", "admit_checksum", "extract_command", "admit_extraction", "publish_command", "admit_publication", "cleanup" }) do
		local kind = name
		files[name] = function()
			f.calls[#f.calls + 1] = kind
			if kind == "prepare" then assert(f.parent_prepared, "native private files require prepared parent") end
			if f.after_mutation then f.after_mutation() end
			if kind == "prepare" then return { archive = "/private/archive", stage = "/private/stage" } end
			if kind == "hash_command" or kind == "extract_command" or kind == "publish_command" then return "tool", {} end
			if kind == "admit_publication" then files.published = true end
			return true
		end
	end
	f.files, f.resolver = files, resolver
	f.owner = assert(Admission.new(resolver, { new = function(directory) assert(directory == "/private/release/ollama"); return files end }, function() return f.source end, consent ~= false, reuse))
	return f
end
test("construction is read-only and cannot invent download consent", function()
	local f = fixture(false); assert(#f.calls == 0)
	local paths, reason = f.owner.prepare()
	assert(paths == nil and reason == "install_consent_unavailable" and #f.calls == 0)
end)
test("exact parent preparation precedes every private native allocation", function()
	local f = fixture(); local paths = assert(f.owner.prepare())
	assert(paths.archive == "/private/archive" and f.calls[1] == "parent" and f.calls[2] == "prepare")
end)
test("revocation during parent preparation prevents private allocation", function()
	local f = fixture(); f.after_parent = function() f.source = false end
	local paths, reason = f.owner.prepare()
	assert(paths == nil and reason == "install_source_stale" and #f.calls == 1 and f.calls[1] == "parent")
end)
test("stale source blocks every file mutation and helper command admission", function()
	local f = fixture(); f.source = false
	for _, name in ipairs({ "prepare", "admit_size", "hash_command", "admit_checksum", "extract_command", "admit_extraction", "publish_command", "admit_publication" }) do
		local accepted, reason = f.owner[name](); assert(not accepted and reason == "install_source_stale")
	end
	assert(#f.calls == 0)
end)
test("substituted ancestry blocks mutation and pathname cleanup", function()
	local f = fixture(); f.ancestry = false
	assert(f.owner.prepare() == nil and f.owner.admit_extraction() == nil and f.owner.cleanup() == false)
	assert(#f.calls == 0, "no pathname traversal after observed ancestor substitution")
end)
test("mutation receipt cannot publish readiness after source revocation", function()
	local f = fixture(); f.after_mutation = function() f.source = false end
	local accepted, reason = f.owner.admit_extraction()
	assert(accepted == nil and reason == "install_source_stale" and f.calls[1] == "admit_extraction")
end)
test("cancelled source retains exact private cleanup authority", function()
	local f = fixture(); assert(f.owner.prepare()); f.source = false
	assert(f.owner.cleanup() == true and f.calls[#f.calls] == "cleanup", "cleanup independent of expired source")
end)
test("late cancellation preserves actual published runtime receipt", function()
	local f = fixture(); assert(f.owner.admit_publication()); f.source = false
	assert(f.owner.cleanup() == true and f.owner.published == true, "published native tree remains installed")
end)
test("later public function replacement cannot redirect captured native owner", function()
	local f = fixture()
	f.files.cleanup = function() error("replacement cannot acquire cleanup") end
	f.resolver.current = function() error("replacement cannot alter path proof") end
	assert(f.owner.cleanup() == true and f.calls[1] == "cleanup")
end)
-- A 64 KiB archive chunk re-admitted the owner 14 times, each an ancestor walk.
local function reusing()
	local clock = { now = 100 }
	local f = fixture(true, { window_ms = 1, now_ms = function() return clock.now end })
	return f, clock
end
test("one admitted ancestor walk answers current() within the reuse window only", function()
	local f, clock = reusing()
	for _ = 1, 14 do assert(f.owner.current() == true) end
	assert(f.walks == 1, "14 re-admissions inside the window walk once, walked " .. f.walks)
	clock.now = 101
	assert(f.owner.current() == true and f.walks == 1, "the window bound itself is still inside")
	clock.now = 102
	assert(f.owner.current() == true and f.walks == 2, "past the window the ancestors are walked again")
end)
test("a substituted ancestor is seen as soon as the window ends and a refusal is never kept", function()
	local f, clock = reusing()
	assert(f.owner.current() == true); f.ancestry = false
	clock.now = 102
	local admitted, reason = f.owner.current()
	assert(admitted == false and reason == "install_ancestor_substituted")
	f.ancestry = true
	assert(f.owner.current() == true and f.walks == 3, "a refusal is walked again, never served from memory")
end)
test("a source revocation is never served from the reused walk", function()
	local f = reusing()
	assert(f.owner.current() == true); f.source = false
	local admitted, reason = f.owner.current()
	assert(admitted == false and reason == "install_source_stale")
end)
test("every file mutation walks the ancestors before and after it", function()
	local f = reusing()
	assert(f.owner.current() == true and f.walks == 1)
	assert(f.owner.admit_size() == true)
	assert(f.walks == 3, "admit_size walks before and after its mutation, walked " .. f.walks)
end)
test("a clock that goes backwards or fails walks again or refuses", function()
	local f, clock = reusing()
	assert(f.owner.current() == true); clock.now = 50
	assert(f.owner.current() == true and f.walks == 2)
	clock.now = "broken"
	local admitted, reason = f.owner.current()
	assert(admitted == false and reason == "install_ancestry_clock_unavailable")
end)
test("an invalid reuse contract is refused at construction", function()
	for _, reuse in ipairs({ 1, {}, { window_ms = -1, now_ms = function() return 0 end }, { window_ms = 0 / 0, now_ms = function() return 0 end }, { window_ms = 1 } }) do
		local owner, reason = Admission.new({ plan = function() return { directory = "/d" } end, current = function() return true end,
			prepare = function() return true end }, { new = function() return { directory = "/d", cleanup = function() return true end } end },
			function() return true end, true, reuse)
		assert(owner == nil and reason == "install_ancestry_reuse_invalid")
	end
end)
