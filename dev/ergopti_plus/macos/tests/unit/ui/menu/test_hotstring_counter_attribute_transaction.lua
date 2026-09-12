--- tests/unit/ui/menu/test_hotstring_counter_attribute_transaction.lua

--- ==============================================================================
--- MODULE: Extension Attribute Transaction Tests
--- DESCRIPTION:
--- Failed stat cannot publish partial counts; optional absence needs native proof.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

local function with_attributes(suffix, mode, callback)
	with_counter(function(counter, state, ctx)
		local original = hs.fs.attributes
		local target = ctx.base_dir .. "../extensions/" .. suffix
		local normalized = target:gsub("/+$", "")
		local control = { failing = true, inspections = 0 }
		hs.fs.attributes = function(path)
			control.inspections = control.inspections + 1
			if control.failing and path == target then
				control.stat_failed = mode ~= "valid_link"
				if mode == "throw" then error("PRIVATE_STAT") end
				if mode ~= "valid_link" then return nil, "PRIVATE_STAT" end
			end
			return original(path)
		end
		hs.fs.symlinkAttributes = function(path)
			if control.failing and path:gsub("/+$", "") == normalized then
				if mode == "dangling" or mode == "valid_link" then
					return { mode = "link", target = "/virtual/actual-demo", dev = 1, ino = 4 }
				end
				return nil, "PRIVATE_LSTAT"
			end
			return original(path)
		end
		hs.fs.dir = function(path)
			local parent = normalized:match("^(.*)/[^/]+$")
			if control.failing and path == parent and mode == "parent_error" then error("PRIVATE_DIR") end
			local names
			if control.failing and control.stat_failed and path == parent and mode == "absent" then names = {}
			elseif path:gsub("/+$", ""):match("/extensions$") then names = { "demo" }
			elseif path:gsub("/+$", ""):match("/hotstrings$") then names = { "demo.toml" }
			elseif path:gsub("/+$", ""):match("/demo$") then names = { "hotstrings", "manifest.toml" }
			else names = { "extensions" } end
			local directory = { index = 0 }
			return function(owner)
				helpers.assert_eq(owner, directory, "native directory iterator requires its state")
				owner.index = owner.index + 1
				return names[owner.index]
			end, directory
		end
		local native_listing = assert(loadfile("infra/fs_dir.lua"))()
		package.loaded["infra.fs_dir"].try_entries = native_listing.try_entries
		callback(counter, state, ctx, control)
	end)
end

helpers.describe("Extension attribute transaction", function()
	for _, suffix in ipairs({ "", "demo", "demo/manifest.toml", "demo/hotstrings/" }) do
		for _, mode in ipairs({ "nil", "throw", "parent_error", "dangling" }) do
			helpers.it("(counter-attribute-transaction) rejects " .. mode .. " at " .. suffix .. " and retries", function()
				with_attributes(suffix, mode, function(counter, state, ctx, control)
					for _ = 1, 2 do
						local ok, err = pcall(counter.count_all, ctx, {})
						helpers.assert_eq(ok, false)
						helpers.assert_eq(err, "Extension attribute inspection failed; hotstring counts were not published")
					end
					local diagnostics = 0
					for _, message in ipairs(state.errors) do
						if message:find("Extension attribute inspection failed", 1, true) then
							diagnostics = diagnostics + 1
							helpers.assert_nil(message:find("PRIVATE", 1, true))
							helpers.assert_nil(message:find("/virtual", 1, true))
						end
					end
					helpers.assert_eq(diagnostics, 1)
					control.failing = false
					helpers.assert_eq(counter.count_all(ctx, {}).ext, 1)
					local inspections = control.inspections
					helpers.assert_eq(counter.count_all(ctx, {}).ext, 1)
					helpers.assert_eq(control.inspections, inspections)
				end)
			end)
		end
			helpers.it("(counter-attribute-transaction) caches proven optional absence at " .. suffix, function()
				with_attributes(suffix, "absent", function(counter, state, ctx, control)
					helpers.assert_eq(counter.count_all(ctx, {}).ext, 0)
					local inspections = control.inspections
					helpers.assert_eq(counter.count_all(ctx, {}).ext, 0)
					helpers.assert_eq(control.inspections, inspections)
					helpers.assert_eq(#state.errors, 0)
				end)
			end)
	end
	helpers.it("(counter-attribute-transaction) preserves successful stat through a directory symlink", function()
		with_attributes("demo", "valid_link", function(counter, _, ctx)
			helpers.assert_eq(counter.count_all(ctx, {}).ext, 1)
		end)
	end)
end)
