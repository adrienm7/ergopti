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
local AppDirs = require("core.fs.engine.app_dirs")

local Json = require("core.text.engine.json")

local DEFAULTS = helpers.shared("updater/data/defaults.json")

--- Loads the binding over stubbed file ports.
--- @param tree table path -> "file" | "dir" | "link_file" | "link_dir"
--- @param body function fn(Binding)
local function with_binding(tree, body)
	helpers.with_fresh_modules({
		"modules.updater.config_backup",
		"core.fs.adapters.file_system",
		"core.fs.engine.dir",
		"infra.config_paths",
		"core.fs.engine.paths",
	}, function()
		package.loaded["core.fs.adapters.file_system"] = {
			path_status = function(path)
				local kind = tree[path]
				if not kind then return "absent" end
				if kind == "unreadable" then return "error", "permission denied" end
				if kind == "invalid_attributes" then return "present", nil end
				if kind == "invalid_mode" then return "present", {} end
				local mode = kind:find("^link_") and "link" or (kind == "dir" and "directory" or (kind == "fifo" and "named pipe" or "file"))
				return "present", { mode = mode }
			end,
			followed_mode = function(path)
				local kind = tree[path]
				if kind == "link_dangling" then return "absent" end
				if kind == "link_loop" then return "error", "Too many levels of symbolic links" end
				if kind == "link_dir" then return "present", "directory" end
				if kind == "link_fifo" then return "present", "named pipe" end
				return "present", "file"
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
		package.loaded["core.fs.engine.dir"] = {
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
			get_config_dir = function() return "/Users/me/" .. AppDirs.config.macos_relative .. "/" end,
			ensure_dir = function() return true end,
		}
		package.loaded["core.fs.engine.paths"] = {
			shared = function(relative)
				if relative == "updater/data/defaults.json" then return DEFAULTS end
				return nil
			end,
		}
		body(require("modules.updater.config_backup"))
	end)
end

helpers.describe("config_backup binding (macOS)", function()
	helpers.it("refuses a listing when an entry cannot be classified", function()
		for _, kind in ipairs({ "unreadable", "invalid_attributes", "invalid_mode" }) do
			with_binding({ ["/cfg"] = "dir", ["/cfg/settings.toml"] = kind }, function(Binding)
				local entries, reason = Binding._list("/cfg")
				helpers.assert_nil(entries, "unknown entries must not disappear from a backup")
				helpers.assert_true(type(reason) == "string" and reason ~= "")
				Binding._overrides = { roots = { { id = "config", dir = "/cfg" } },
					clock = function() return { stamp = "20261104-120000", iso = "2026-11-04T12:00:00Z" } end }
				local owner = assert(Binding.owner())
				local backup, detail = owner.create("pre_install", { tag = "v1.0.0" })
				helpers.assert_nil(backup, "an incomplete snapshot must not publish a backup")
				helpers.assert_true(type(detail) == "string" and detail:find("cannot classify", 1, true) ~= nil)
			end)
		end
	end)
	helpers.it("backs up the configuration folder under the shared rules", function()
		with_binding({}, function(Binding)
			local owner = assert(Binding.owner())
			helpers.assert_eq(owner.folder, "/Users/me/" .. AppDirs.config.macos_relative .. "/backups")
		end)
	end)
end)

--- Lists a stubbed tree through the macOS listing port (the FileSystem adapter).
--- @param entries table { { name, kind } } with kind file, dir, link_file, link_dir, fifo, link_fifo or link_dangling
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

require("tests.lua.settings.backup_binding_contract").register(helpers, { defaults = defaults, listing = stub_listing })
