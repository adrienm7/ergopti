--- macos/tests/unit/modules/updater/test_config_backup_binding.lua

--- ==============================================================================
--- MODULE: Configuration Backup Binding (macOS)
--- DESCRIPTION:
--- The shared backup owner is proven over an in-memory tree by its contract;
--- this pins the macOS binding (modules/updater/config_backup.lua): the shared
--- binding contract replayed over the FileSystem adapter's classified entries
--- (a link to a folder is reported and never walked) and that the owner reads
--- its rules from the shared updater defaults and backs up the configuration
--- folder.
--- ==============================================================================

local helpers = require("tests.helpers")

local Json = require("json")

local DEFAULTS = helpers.shared("modules/updater/defaults.json")

--- Loads the binding over stubbed file ports.
--- @param tree table path -> "file" | "dir" | "link_file" | "link_dir"
--- @param body function fn(Binding)
local function with_binding(tree, body)
	helpers.with_fresh_modules({
		"modules.updater.config_backup",
		"adapters.file_system",
		"infra.fs_dir",
		"infra.config_paths",
		"infra.paths",
	}, function()
		package.loaded["adapters.file_system"] = {
			path_status = function(path)
				local kind = tree[path]
				if not kind then return "absent" end
				local mode = (kind == "link_file" or kind == "link_dir") and "link" or (kind == "dir" and "directory" or "file")
				return "present", { mode = mode }
			end,
			directory_status = function(path)
				local kind = tree[path]
				if not kind then return "absent" end
				if kind == "dir" or kind == "link_dir" then return "present", {} end
				return "error", "not a folder"
			end,
			read = function(path)
				local handle = io.open(path, "rb")
				if not handle then return nil end
				local text = handle:read("*a")
				handle:close()
				return text
			end,
		}
		package.loaded["infra.fs_dir"] = {
			try_entries = function(dir)
				local names = {}
				for path in pairs(tree) do
					local name = path:sub(#dir + 2)
					if path:sub(1, #dir + 1) == dir .. "/" and name ~= "" and not name:find("/", 1, true) then
						names[#names + 1] = name
					end
				end
				return names, true
			end,
		}
		package.loaded["infra.config_paths"] = {
			get_config_dir = function() return "/Users/me/.config/ergopti_plus/" end,
			ensure_dir = function() return true end,
		}
		package.loaded["infra.paths"] = {
			shared = function(relative)
				if relative == "modules/updater/defaults.json" then return DEFAULTS end
				return nil
			end,
		}
		body(require("modules.updater.config_backup"))
	end)
end

helpers.describe("config_backup binding (macOS)", function()
	helpers.it("backs up the configuration folder under the shared rules", function()
		with_binding({}, function(Binding)
			local owner = assert(Binding.owner())
			helpers.assert_eq(owner.folder, "/Users/me/.config/ergopti_plus/backups")
		end)
	end)
end)

--- Lists a stubbed tree through the macOS listing port (the FileSystem adapter).
--- @param entries table { { name, kind } } with kind file, dir, link_file or link_dir
--- @param body function fn(list, root)
local function stub_listing(entries, body)
	local root = "/cfg"
	local tree = { [root] = "dir" }
	for _, entry in ipairs(entries) do tree[root .. "/" .. entry.name] = entry.kind end
	with_binding(tree, function(Binding) body(Binding._list, root) end)
end

local handle = assert(io.open(DEFAULTS, "rb"))
local defaults = assert(Json.decode(handle:read("*a")), "defaults.json must decode")
handle:close()

require("test.config_backup_binding_contract").register(helpers, { defaults = defaults, listing = stub_listing })
