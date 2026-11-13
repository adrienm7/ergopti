--- tests/unit/layouts/engine/test_managed_python.lua

--- ==============================================================================
--- MODULE: Ergopti's Own Python (Linux)
--- DESCRIPTION:
--- The user XKB installer ran on the host's python3, which the owned-runtimes
--- registry decided to replace with Ergopti's own pinned build, downloaded on
--- consent. These cases replay the whole transaction with injected effects:
--- the pin read from the generated runtime manifest, the consent, the size and
--- SHA-256 checks, the unpack, the publication by rename, and the cleanup of
--- every refused step.
---
--- ROOT CAUSE ENCODED:
--- A versioned folder may only ever hold a verified interpreter, a declined
--- offer writes nothing, and two callers share one download.
--- ==============================================================================

local h = require("tests.helpers")
local Pins = require("_generated.native_runtime").managed_python

local DATA = "/data/ergopti"

--- A fake machine whose effects are recorded.
--- @param options table|nil { machine, musl, confirm, status, bytes, digest, unpack, interpreter, rename }
--- @return table deps, table world
local function machine(options)
	options = options or {}
	local world = { files = {}, removed = {}, renamed = {}, downloads = {}, asked = 0, unpacked = 0 }
	local archive = Pins.archives[(options.machine or "x86_64") .. "-" .. (options.musl and "musl" or "gnu")]
	if options.musl then world.files["/lib/ld-musl-" .. (options.machine or "x86_64") .. ".so.1"] = true end
	local deps = {
		pin = Pins,
		data_dir = DATA,
		machine = function() return options.machine or "x86_64" end,
		exists = function(path) return world.files[path] == true end,
		confirm = function(bytes)
			world.asked, world.offered = world.asked + 1, bytes
			if options.confirm == nil then return true end
			return options.confirm
		end,
		download = function(url, path, bytes, callback)
			world.downloads[#world.downloads + 1] = { url = url, path = path, bytes = bytes }
			local operation = { started = true, closed = false, listeners = {} }
			function operation:is_settled() return self.closed end
			function operation:settled_result() return self.result end
			function operation:on_settled(fn)
				self.listeners[#self.listeners + 1] = fn
				if self.closed then fn() end
				return true
			end
			world.pending = function()
				world.files[path] = true
				operation.result = { ok = (options.status or 200) == 200, status = options.status or 200 }
				callback(operation.result)
				world.retire = function()
					operation.closed = true
					for _, listener in ipairs(operation.listeners) do listener() end
				end
				if not options.hold_physical then world.retire() end
			end
			if not options.hold then world.pending() end
			return true, operation
		end,
		size = function(path) return world.files[path] and (options.bytes or archive.bytes) or nil end,
		sha256 = function(_, callback) callback(options.digest or archive.sha256, nil) end,
		unpack = function(_, into, callback)
			world.unpacked = world.unpacked + 1
			if options.unpack == false then callback(false, "tar refused") return end
			if options.interpreter ~= false then world.files[into .. "/python/bin/python3"] = true end
			callback(true)
		end,
		create_stage = function(root)
			local path = root .. ".staging.fixture"
			return path, function() return true end
		end,
		remove_tree = function(path, callback)
			world.removed[#world.removed + 1] = path
			for file in pairs(world.files) do
				if file:sub(1, #path + 1) == path .. "/" then world.files[file] = nil end
			end
			callback(true)
		end,
		delete = function(path) world.files[path] = nil; return true end,
		rename = function(from, to)
			if options.rename == false then return nil, "EEXIST" end
			world.renamed[#world.renamed + 1] = { from = from, to = to }
			for file in pairs(world.files) do
				if file:sub(1, #from + 1) == from .. "/" then
					world.files[to .. file:sub(#from + 1)] = true
					world.files[file] = nil
				end
			end
			return true
		end,
	}
	return deps, world, archive
end

--- Runs ensure() once and returns its single result.
local function ensure(deps)
	local Managed = h.load_module("layouts.engine.managed_python")
	Managed._reset_for_test()
	local result = { calls = 0 }
	Managed.ensure(deps, function(ok, value, detail)
		result.calls = result.calls + 1
		result.ok, result.value, result.detail = ok, value, detail
	end)
	return result, Managed
end

local ROOT_GNU = DATA .. "/runtime/python/cpython-" .. Pins.version .. "+" .. Pins.build .. "-x86_64-gnu"

h.describe("Ergopti's own Python (managed-python)", function()
	h.it("(managed-python) the pin is the reviewed python-build-standalone release for four Linux archives", function()
		h.assert_eq(Pins.version, "3.11.16")
		for _, key in ipairs({ "x86_64-gnu", "aarch64-gnu", "x86_64-musl", "aarch64-musl" }) do
			local archive = Pins.archives[key]
			h.assert_type(archive, "table", key)
			h.assert_true(archive.url:match("^https://github%.com/astral%-sh/python%-build%-standalone/releases/download/") ~= nil)
			h.assert_true(archive.sha256:match("^%x+$") ~= nil and #archive.sha256 == 64, key)
			h.assert_true(archive.bytes > 0, key)
		end
	end)

	h.it("(managed-python) downloads, checks, unpacks and publishes only a verified interpreter", function()
		local deps, world, archive = machine()
		local result = ensure(deps)
		h.assert_eq(result.calls, 1)
		h.assert_true(result.ok, tostring(result.value) .. " " .. tostring(result.detail))
		h.assert_eq(result.value, ROOT_GNU .. "/python/bin/python3")
		h.assert_eq(world.asked, 1)
		h.assert_eq(world.offered, archive.bytes)
		h.assert_eq(world.downloads[1].url, archive.url)
		h.assert_eq(world.downloads[1].bytes, archive.bytes, "the download is capped at the pinned size")
		h.assert_eq(world.renamed[1], { from = ROOT_GNU .. ".staging.fixture", to = ROOT_GNU })
		h.assert_true(world.files[ROOT_GNU .. "/python/bin/python3"])
		h.assert_nil(world.files[ROOT_GNU .. "/archive.tar.gz"], "the archive is not published")
	end)

	h.it("preserves a pre-existing staging directory owned by another installation", function()
		local deps, world = machine()
		local marker = ROOT_GNU .. ".staging/another-owner"
		world.files[marker] = true
		local result = ensure(deps)
		h.assert_true(result.ok)
		h.assert_true(world.files[marker], "an existing staging directory must never be removed")
	end)

	h.it("does not remove or publish a staging directory replaced during download", function()
		local deps, world = machine({ hold = true })
		local retained = true
		deps.create_stage = function(root) return root .. ".staging.fixture", function() return retained end end
		local result, Managed = ensure(deps)
		retained = false
		world.pending()
		h.assert_eq(result.calls, 1)
		h.assert_eq(result.ok, false)
		h.assert_eq(result.value, Managed.FAILURE_PUBLISH)
		h.assert_eq(#world.removed, 0)
		h.assert_eq(#world.renamed, 0)
	end)

	h.it("(managed-python) an installed interpreter is answered without a question or a download", function()
		local deps, world = machine()
		world.files[ROOT_GNU .. "/python/bin/python3"] = true
		local result = ensure(deps)
		h.assert_true(result.ok)
		h.assert_eq(world.asked, 0)
		h.assert_eq(#world.downloads, 0)
	end)

	h.it("(managed-python) a musl system gets the musl build", function()
		local deps, world = machine({ musl = true })
		local result = ensure(deps)
		h.assert_true(result.ok)
		h.assert_eq(world.downloads[1].url, Pins.archives["x86_64-musl"].url)
		h.assert_true(result.value:find("-x86_64-musl/python/bin/python3", 1, true) ~= nil)
	end)

	h.it("(managed-python) a declined offer writes and downloads nothing", function()
		local deps, world = machine({ confirm = false })
		local result, Managed = ensure(deps)
		h.assert_eq(result.ok, false)
		h.assert_eq(result.value, Managed.FAILURE_DECLINED)
		h.assert_eq(#world.downloads, 0)
		h.assert_eq(#world.removed, 0)
		h.assert_eq(#world.renamed, 0)
	end)

	h.it("(managed-python) an unsupported machine is refused before any question", function()
		local deps, world = machine({ machine = "riscv64" })
		local result, Managed = ensure(deps)
		h.assert_eq(result.value, Managed.FAILURE_UNSUPPORTED)
		h.assert_eq(world.asked, 0)
	end)

	for _, case in ipairs({
		{ "an HTTP failure", { status = 404 }, "FAILURE_DOWNLOAD" },
		{ "a truncated archive", { bytes = 1 }, "FAILURE_DOWNLOAD" },
		{ "a checksum mismatch", { digest = string.rep("0", 64) }, "FAILURE_CHECKSUM" },
		{ "a refused unpack", { unpack = false }, "FAILURE_UNPACK" },
		{ "an archive without the interpreter", { interpreter = false }, "FAILURE_UNPACK" },
		{ "a refused publication", { rename = false }, "FAILURE_PUBLISH" },
	}) do
		h.it("(managed-python) " .. case[1] .. " publishes nothing and removes the staging folder", function()
			local deps, world = machine(case[2])
			local result, Managed = ensure(deps)
			h.assert_eq(result.calls, 1)
			h.assert_eq(result.ok, false)
			h.assert_eq(result.value, Managed[case[3]])
			h.assert_nil(world.files[ROOT_GNU .. "/python/bin/python3"], "no unverified interpreter is published")
			h.assert_eq(world.removed[#world.removed], ROOT_GNU .. ".staging.fixture")
		end)
	end

	h.it("(managed-python) a second caller waits for the same download", function()
		local deps, world = machine({ hold = true })
		local Managed = h.load_module("layouts.engine.managed_python")
		Managed._reset_for_test()
		local outcomes = {}
		Managed.ensure(deps, function(ok, value) outcomes[#outcomes + 1] = { ok, value } end)
		Managed.ensure(deps, function(ok, value) outcomes[#outcomes + 1] = { ok, value } end)
		h.assert_eq(#world.downloads, 1, "one download for both callers")
		h.assert_eq(world.asked, 1, "one question for both callers")
		world.pending()
		h.assert_eq(#outcomes, 2)
		h.assert_eq(outcomes[1], outcomes[2])
		h.assert_true(outcomes[1][1])
	end)
	for _, status in ipairs({ 200, 404 }) do
		h.it("delivers all Python installation waiters when one callback raises (HTTP " .. status .. ")", function()
			local deps, world = machine({ hold = true, status = status })
			local Managed = h.load_module("layouts.engine.managed_python")
			Managed._reset_for_test()
			local answered = 0
			Managed.ensure(deps, function() error("first waiter failed") end)
			Managed.ensure(deps, function(ok) answered = answered + 1; h.assert_eq(ok, status == 200) end)
			local returned = pcall(world.pending)
			h.assert_true(returned, "a waiter cannot interrupt settlement")
			h.assert_eq(answered, 1)
		end)
	end

	h.it("retains a refused download until its physical settlement", function()
		local deps, world = machine()
		local operation = { started = false, closed = false, listeners = {} }
		function operation:is_settled() return self.closed end
		function operation:settled_result() return { ok = false, status = 0, error = "shutdown" } end
		function operation:on_settled(fn) self.listeners[#self.listeners + 1] = fn; if self.closed then fn() end; return true end
		deps.download = function() return false, operation end
		local Managed = h.load_module("layouts.engine.managed_python")
		Managed._reset_for_test()
		local outcomes = {}
		Managed.ensure(deps, function(ok, value) outcomes[#outcomes + 1] = { ok, value } end)
		Managed.ensure(deps, function(ok, value) outcomes[#outcomes + 1] = { ok, value } end)
		h.assert_eq(#outcomes, 0, "refusal does not acknowledge native retirement")
		h.assert_eq(#world.removed, 0, "staging must remain until the transport closes")
		operation.closed = true
		for _, listener in ipairs(operation.listeners) do listener() end
		h.assert_eq(#outcomes, 2)
		h.assert_eq(outcomes[1], { false, Managed.FAILURE_DOWNLOAD })
		h.assert_eq(outcomes[2], outcomes[1])
		h.assert_eq(#world.removed, 1)
	end)

	h.it("answers an already settled refused download without a logical callback", function()
		local deps = machine()
		local operation = { started = false }
		function operation:is_settled() return true end
		function operation:settled_result() return { ok = false, status = 0, error = "shutdown" } end
		function operation:on_settled(fn) fn(); return true end
		deps.download = function() return false, operation end
		local result, Managed = ensure(deps)
		h.assert_eq(result.calls, 1)
		h.assert_eq(result.ok, false)
		h.assert_eq(result.value, Managed.FAILURE_DOWNLOAD)
	end)

	h.it("waits for native HTTP retirement after logical success before unpacking", function()
		local deps, world = machine({ hold = true, hold_physical = true })
		local result = ensure(deps)
		world.pending()
		h.assert_eq(result.calls, 0)
		h.assert_eq(world.unpacked, 0)
		world.retire()
		h.assert_eq(result.calls, 1)
		h.assert_true(result.ok)
		h.assert_eq(world.unpacked, 1)
	end)

	h.it("retains staging if settlement subscription invokes inline then refuses", function()
		local deps, world = machine()
		local operation = { started = false, listener = nil }
		function operation:is_settled() return true end
		function operation:settled_result() return { ok = false, status = 0 } end
		function operation:on_settled(fn) self.listener = fn; fn(); return false end
		deps.download = function() return false, operation end
		local result, Managed = ensure(deps)
		h.assert_eq(result.calls, 0)
		h.assert_eq(#world.removed, 0)
		operation.listener()
		h.assert_eq(result.calls, 0, "a refused subscription cannot later authorize cleanup")
		h.assert_eq(#world.removed, 0)
		Managed._reset_for_test()
	end)

end)
