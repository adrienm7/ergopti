--- tests/unit/platform/remap/runtime_manifest/test_runtime_manifest.lua

--- ==============================================================================
--- MODULE: Owned Runtime Artifact Pin
--- DESCRIPTION:
--- Pins platform/remap/runtime_manifest.lua: a manifest is pinned only when
--- every field of M.FIELDS has its shape, the shipped manifest is honestly
--- unpinned until the hosted build exists, and an unpinned manifest produces a
--- named refusal instead of a version guess.
---
--- ROOT CAUSE ENCODED: the digest of the runtime and the designated requirement
--- cannot be known before the hosted build signs the artifact. A loader that
--- accepted a null digest, a short digest or an address for another file would
--- install bytes nobody pinned.
--- ==============================================================================

local helpers = require("tests.helpers")

local DIGEST = string.rep("ab", 32)

--- A complete, valid manifest.
--- @return table manifest
local function complete()
	return {
		schema = 1,
		runtime = {
			upstream_repository = "pqrs-org/Karabiner-Elements",
			upstream_revision = string.rep("1a", 20),
			version = "16.3.0-ergopti.1",
			file_name = "ErgoptiPlus-Remap-Runtime.tar.gz",
			source_url = "https://github.com/adrienm7/ergopti/releases/download/runtime-1/ErgoptiPlus-Remap-Runtime.tar.gz",
			sha256 = DIGEST,
			size = 123456,
		},
		virtual_hid_device = {
			version = "8.5.0",
			team_identifier = "G43BCU2T37",
			file_name = "Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg",
			source_url = "https://example.test/dl/v8.5.0/Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg",
			sha256 = string.rep("cd", 32),
			size = 2089117,
		},
		capture = { requirement = 'identifier "com.ergoptiplus.app"', batch_limit = 64, frame_limit = 65536,
			history_capacity = 4096 },
	}
end

--- Loads a fresh module.
--- @return table module
local function load_module()
	package.loaded["platform.remap.runtime_manifest"] = nil
	return require("platform.remap.runtime_manifest")
end

--- Reads the shipped manifest.
--- @return table manifest
local function shipped()
	local file = assert(io.open(helpers.driver_root() .. "/vendor/remap-runtime/manifest.json", "rb"))
	local bytes = file:read("*a")
	file:close()
	return require("json").decode(bytes)
end

--- Sets one dotted path.
--- @param manifest table Manifest.
--- @param path string Dotted path.
--- @param value any Replacement; nil clears it.
local function set(manifest, path, value)
	local group, key = path:match("^([^.]+)%.(.+)$")
	manifest[group][key] = value
end





-- ==================================
-- ==================================
-- ======= 1/ The Shipped Pin =======
-- ==================================
-- ==================================

helpers.describe("owned runtime manifest: what ships", function()
	helpers.it("pins the VirtualHIDDevice and the capture limits but not the unbuilt runtime", function()
		local Manifest = load_module()
		helpers.assert_eq(Manifest.unpinned(shipped()), {
			"runtime.version", "runtime.file_name", "runtime.source_url", "runtime.sha256", "runtime.size",
			"capture.requirement",
		})
	end)

	helpers.it("refuses the shipped manifest with a sentence naming the first missing field", function()
		local pinned, reason = load_module().pinned(shipped())
		helpers.assert_nil(pinned)
		helpers.assert_contains(reason, "runtime.version")
		helpers.assert_contains(reason, "5 more")
	end)

	helpers.it("names the upstream revision the plan anchors the fork on", function()
		helpers.assert_eq(shipped().runtime.upstream_revision, "9312593e1a3bf72b94c63c524ebabe2637442e8a")
	end)
end)





-- ======================================
-- ======================================
-- ======= 2/ A Complete Manifest =======
-- ======================================
-- ======================================

helpers.describe("owned runtime manifest: a complete pin", function()
	helpers.it("is pinned and hands the owner the driver version and the capture declaration", function()
		local Manifest = load_module()
		helpers.assert_eq(Manifest.unpinned(complete()), {})
		local pinned, reason = Manifest.pinned(complete())
		helpers.assert_nil(reason)
		helpers.assert_eq(pinned, {
			virtual_hid_version = "8.5.0",
			capture = { requirement = 'identifier "com.ergoptiplus.app"', batch_limit = 64, frame_limit = 65536,
				history_capacity = 4096 },
		})
	end)

	helpers.it("treats every field as required: removing or nulling any one unpins the manifest", function()
		local Manifest = load_module()
		for _, field in ipairs(Manifest.FIELDS) do
			local manifest = complete()
			set(manifest, field[1], nil)
			helpers.assert_eq(Manifest.unpinned(manifest)[1], field[1], field[1])
			helpers.assert_nil((Manifest.pinned(manifest)))
		end
	end)

	helpers.it("rejects values of the wrong shape", function()
		local Manifest = load_module()
		local cases = {
			{ "runtime.sha256", string.rep("AB", 32) },
			{ "runtime.sha256", string.rep("ab", 31) },
			{ "runtime.sha256", string.rep("zz", 32) },
			{ "runtime.size", 0 },
			{ "runtime.size", 1.5 },
			{ "runtime.size", "123" },
			{ "runtime.version", "latest" },
			{ "runtime.file_name", "../runtime.tar.gz" },
			{ "runtime.file_name", "a b.tar.gz" },
			{ "runtime.upstream_revision", "main" },
			{ "runtime.upstream_revision", string.rep("a", 39) },
			{ "virtual_hid_device.team_identifier", "g43bcu2t37" },
			{ "virtual_hid_device.team_identifier", "G43" },
			{ "capture.requirement", "" },
			{ "capture.requirement", "a\nb" },
			{ "capture.batch_limit", -1 },
			{ "capture.history_capacity", 0 },
		}
		for _, case in ipairs(cases) do
			local manifest = complete()
			set(manifest, case[1], case[2])
			helpers.assert_eq(Manifest.unpinned(manifest), { case[1] }, case[1] .. " = " .. tostring(case[2]))
		end
	end)

	helpers.it("accepts only plain https addresses that end in the pinned file name", function()
		local Manifest = load_module()
		local base = "https://example.test/dl/"
		local cases = {
			"http://example.test/dl/ErgoptiPlus-Remap-Runtime.tar.gz",
			"https://user:pass@example.test/dl/ErgoptiPlus-Remap-Runtime.tar.gz",
			base .. "ErgoptiPlus-Remap-Runtime.tar.gz#fragment",
			base .. "Other-Runtime.tar.gz",
			base .. "ErgoptiPlus-Remap-Runtime.tar.gz ",
			"file:///tmp/ErgoptiPlus-Remap-Runtime.tar.gz",
			"",
		}
		for _, url in ipairs(cases) do
			local manifest = complete()
			manifest.runtime.source_url = url
			helpers.assert_eq(Manifest.unpinned(manifest), { "runtime.source_url" }, url)
		end
		local good = complete()
		good.runtime.source_url = base .. "ErgoptiPlus-Remap-Runtime.tar.gz"
		helpers.assert_eq(Manifest.unpinned(good), {})
	end)

	helpers.it("leaves every field unpinned for something that is not a manifest of this schema", function()
		local Manifest = load_module()
		for _, candidate in ipairs({ "text", 5, false }) do
			helpers.assert_eq(#Manifest.unpinned(candidate), #Manifest.FIELDS)
		end
		local future = complete()
		future.schema = 2
		helpers.assert_eq(#Manifest.unpinned(future), #Manifest.FIELDS)
		helpers.assert_eq(#Manifest.unpinned(nil), #Manifest.FIELDS)
	end)
end)
