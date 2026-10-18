--- tests/unit/infra/text_and_paths/paths/test_shared_root_kind.lua

--- ==============================================================================
--- MODULE: Shared Resource Root Kind Admission
--- DESCRIPTION:
--- Real temporary files and LuaFileSystem stat exercise the same mode and
--- followed-link contract as pinned hs.fs.attributes. Only native stat errors
--- and visibility outside the private tree are controlled; no Cocoa claim.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a fresh resolver over real private filesystem entries with exact cleanup.
--- @param scenario function Receives Paths and the private filesystem owner.
local function with_tree(scenario)
	local previous_lfs = rawget(_G, "lfs")
	local previous_hs = rawget(_G, "hs")
	rawset(_G, "lfs", nil)
	local okay, failure = xpcall(function()
		helpers.with_fresh_modules({ "infra.paths", "infra.logger", "lfs" }, function()
			local fs = require("lfs")
			local script_shared = helpers.driver_root():gsub("[/\\]$", ""):gsub("/macos$", "/_shared")
			local base = os.tmpname():gsub("\\", "/")
			assert(os.remove(base))
			local directories, files = {}, {}
			local state = { root = base, stats = 0, allow_script = false }
			function state.mkdir(path)
				assert(fs.mkdir(path)); directories[#directories + 1] = path
			end
			function state.write(path, content)
				local file = assert(io.open(path, "wb"))
				assert(file:write(content)); assert(file:close())
				files[#files + 1] = path
			end
			function state.link(target, path)
				assert(fs.link(target, path, true)); files[#files + 1] = path
			end
			local function clean()
				for index = #files, 1, -1 do assert(os.remove(files[index])) end
				for index = #directories, 1, -1 do assert(fs.rmdir(directories[index])) end
			end
			local ran, err = xpcall(function()
				state.mkdir(base)
				state.mkdir(base .. "/checkout")
				state.mkdir(base .. "/checkout/macos")
				state.parent = base .. "/checkout/_shared"
				state.nearest = base .. "/checkout/macos/_shared"
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				_G.hs = {
					configdir = base .. "/checkout/macos",
					fs = { attributes = function(path)
						state.stats = state.stats + 1
						if state.stat_error and path == state.nearest then return state.stat_error(path) end
						if path:sub(1, #base + 1) ~= base .. "/"
							and not (state.allow_script and path == script_shared) then
							return nil, "outside the private filesystem observation"
						end
						return fs.attributes(path)
					end },
				}
				scenario(require("infra.paths"), state)
			end, debug.traceback)
			local cleaned, cleanup_error = xpcall(clean, debug.traceback)
			if not ran then error(err, 0) end
			assert(cleaned, cleanup_error)
		end)
	end, debug.traceback)
	rawset(_G, "lfs", previous_lfs)
	rawset(_G, "hs", previous_hs)
	if not okay then error(failure, 0) end
end

helpers.describe("shared root requires an actual followed directory", function()
	for _, linked in ipairs({ false, true }) do
		helpers.it("rejects a file shadow and caches its healthy parent, linked=" .. tostring(linked), function()
			with_tree(function(paths, state)
				state.mkdir(state.parent)
				state.write(state.parent .. "/asset.txt", "shipped asset")
				if linked then
					state.write(state.root .. "/plain-file", "not a directory")
					state.link(state.root .. "/plain-file", state.nearest)
				else state.write(state.nearest, "not a directory") end
				helpers.assert_eq(paths.shared_root(), state.parent)
				local stats = state.stats
				helpers.assert_eq(paths.shared_root(), state.parent)
				helpers.assert_eq(state.stats, stats, "only the admitted parent directory may be cached")
				local file = assert(io.open(paths.shared("asset.txt"), "rb"))
				local content = file:read("*a"); assert(file:close())
				helpers.assert_eq(content, "shipped asset")
			end)
		end)
	end
	for _, linked in ipairs({ false, true }) do
		helpers.it("retains the nearest healthy directory, linked=" .. tostring(linked), function()
			with_tree(function(paths, state)
				state.mkdir(state.parent)
				if linked then state.link(state.parent, state.nearest)
				else state.mkdir(state.nearest) end
				helpers.assert_eq(paths.shared_root(), state.nearest)
			end)
		end)
	end
	for _, throwing in ipairs({ false, true }) do
		helpers.it("does not turn stat failure into a directory, throwing=" .. tostring(throwing), function()
			with_tree(function(paths, state)
				state.mkdir(state.parent)
				state.mkdir(state.nearest)
				state.stat_error = function()
					if throwing then error("native stat refused") end
					return nil, "native stat refused"
				end
				helpers.assert_eq(paths.shared_root(), state.parent)
			end)
		end)
	end
	for _, shadow in ipairs({ false, true }) do
		helpers.it("refuses an absent real root without caching a file, shadow=" .. tostring(shadow), function()
			with_tree(function(paths, state)
				if shadow then state.write(state.nearest, "not a directory") end
				helpers.assert_nil(paths.shared_root())
				helpers.assert_nil(paths.shared("asset.txt"))
				state.mkdir(state.parent)
				helpers.assert_eq(paths.shared_root(), state.parent, "a failed search must remain retryable")
			end)
		end)
	end
	helpers.it("keeps generic upward searches able to find regular files", function()
		with_tree(function(paths, state)
			state.write(state.nearest, "a legitimate generic file target")
			helpers.assert_eq(paths.find_upward(hs.configdir, "_shared"), state.nearest)
			helpers.assert_eq(paths.find_from_configdir("_shared"), state.nearest)
		end)
	end)
	helpers.it("reaches the real script-relative directory when configdir contains a file shadow", function()
		with_tree(function(paths, state)
			state.write(state.nearest, "not a directory")
			state.allow_script = true
			local expected = helpers.driver_root():gsub("[/\\]$", ""):gsub("/macos$", "/_shared")
			helpers.assert_eq(paths.shared_root(), expected)
		end)
	end)
end)
