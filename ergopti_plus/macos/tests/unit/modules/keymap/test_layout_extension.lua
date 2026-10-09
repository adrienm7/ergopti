--- tests/unit/modules/keymap/test_layout_extension.lua

--- ==============================================================================
--- MODULE: Layout Extension Publication Tests
--- DESCRIPTION:
--- Exercises immutable extension staging and record-based discovery with private
--- injected files. A rejected download or stage cannot expose partial content.
--- ==============================================================================

local helpers = require("tests.helpers")
local Extension = require("layouts.extension")

local function fixture()
	local files = {
		{ path = "manifest.toml", file = "sample/manifest.toml", size = 1, sha256 = string.rep("a", 64) },
		{ path = "sample.keylayout", file = "sample/sample.keylayout", size = 1, sha256 = string.rep("b", 64) },
		{ path = "hotstrings/demo.toml", file = "sample/hotstrings/demo.toml", size = 1, sha256 = string.rep("c", 64) },
	}
	return { id = "sample", extension = { id = "sample", name = "Sample", version = "1.0.0",
		sha256 = string.rep("d", 64), files = files } }
end

helpers.describe("Layout extension publication", function()
	helpers.it("verifies every downloaded file and refuses corrupt content without publication", function()
		local entry, requests, result = fixture(), {}, nil
		local settings = { max_file_bytes = 100, timeout_ms = 50,
			url_template = "https://example.test/{path}", owner = "owner", repo = "repo", branch = "dev", folder = "registry" }
		local transport = {
			get = function(url, _, _, callback)
				requests[#requests + 1] = url
				callback(200, url:find("manifest", 1, true) and "a" or "x")
			end,
			sha256 = function(text, callback) callback(string.rep(text, 64)) end,
		}
		Extension.acquire(settings, entry, { transport = transport }, function(ok, detail) result = { ok, detail } end)
		helpers.assert_true(result ~= nil and not result[1])
		helpers.assert_eq(#requests, 2, "stop before fetching later files after corruption")
		local callbacks = 0
		transport.get = function(url, _, _, callback)
			local text = url:find("manifest", 1, true) and "a" or url:find("keylayout", 1, true) and "b" or "c"
			callback(200, text)
			callback(200, text)
		end
		Extension.acquire(settings, entry, { transport = transport }, function(ok, content)
			callbacks = callbacks + 1
			helpers.assert_true(ok)
			helpers.assert_eq(content["hotstrings/demo.toml"], "c")
		end)
		helpers.assert_eq(callbacks, 1)
	end)

	helpers.it("refuses traversal, duplicate files and missing manifests before writing", function()
		local entry = fixture()
		helpers.assert_true(Extension.validate(entry, 100))
		entry.extension.files[3].path = "../config.toml"
		helpers.assert_true(not Extension.validate(entry, 100))
		entry = fixture()
		entry.extension.files[3] = entry.extension.files[1]
		helpers.assert_true(not Extension.validate(entry, 100))
		entry = fixture()
		table.remove(entry.extension.files, 1)
		helpers.assert_true(not Extension.validate(entry, 100))
	end)

	helpers.it("never discovers staged content until its installed record commits", function()
		local entry, writes = fixture(), {}
		local deps = { read = function(path) return writes[path] end,
			write = function(path, text) writes[path] = text return true end }
		local bytes = { ["manifest.toml"] = "a", ["sample.keylayout"] = "b", ["hotstrings/demo.toml"] = "c" }
		local ok = Extension.stage("/private/", entry, bytes, deps)
		helpers.assert_true(ok)
		helpers.assert_eq(#Extension.roots("/private/", { layouts = {} }), 0)
		local roots = Extension.roots("/private/", { layouts = { sample = entry } })
		helpers.assert_eq(#roots, 1)
		helpers.assert_eq(writes[roots[1] .. "/sample/hotstrings/demo.toml"], "c")
		helpers.assert_true(entry.enabled == nil and entry.extension.enabled == nil)
	end)

	helpers.it("failed staging leaves the previous generation discoverable and unmodified", function()
		local old, next_entry = fixture(), fixture()
		next_entry.extension.sha256 = string.rep("e", 64)
		local before = Extension.roots("/private/", { layouts = { sample = old } })[1]
		local writes = 0
		local ok = Extension.stage("/private/", next_entry,
			{ ["manifest.toml"] = "a", ["sample.keylayout"] = "b", ["hotstrings/demo.toml"] = "c" }, {
				read = function() return nil end,
				write = function(path)
					helpers.assert_true(not path:find(before, 1, true))
					writes = writes + 1
					return writes < 2, "disk full"
				end,
			})
		helpers.assert_true(not ok)
		helpers.assert_eq(Extension.roots("/private/", { layouts = { sample = old } })[1], before)
	end)
end)
