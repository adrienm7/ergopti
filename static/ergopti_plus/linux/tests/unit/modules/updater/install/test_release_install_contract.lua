--- linux/tests/unit/modules/updater/install/test_release_install_contract.lua

--- ==============================================================================
--- MODULE: Release Install and Configuration Backup Contracts (Linux)
--- DESCRIPTION:
--- Runs the shared one-click release install and configuration backup
--- contracts with the real shared updater defaults, decoded by the decoder
--- this driver uses in production. The macOS suite runs the same contracts.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/updater/defaults.json", "rb"))
local defaults = assert(Json.decode(handle:read("*a")), "defaults.json must decode")
handle:close()

require("test.config_backup_contract").register(helpers, { defaults = defaults })

--- Lists a real temporary folder through the Linux listing port.
--- @param entries table { { name, kind } } with kind file, dir, link_file, link_dir, fifo, link_fifo or link_dangling
--- @param body function fn(list, root)
local function real_listing(entries, body)
	local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
	local root = os.tmpname()
	os.remove(root)
	assert(os.execute("mkdir -p " .. quote(root .. "/cfg") .. " " .. quote(root .. "/elsewhere")))
	assert(os.execute("mkdir -p " .. quote(root .. "/elsewhere/folder") .. " && : > " .. quote(root .. "/elsewhere/file.toml")))
	for _, entry in ipairs(entries) do
		local path = quote(root .. "/cfg/" .. entry.name)
		local command = ({
			file = ": > " .. path,
			dir = "mkdir " .. path,
			link_file = "ln -s " .. quote(root .. "/elsewhere/file.toml") .. " " .. path,
			link_dir = "ln -s " .. quote(root .. "/elsewhere/folder") .. " " .. path,
			fifo = "mkfifo " .. path,
			link_fifo = "mkfifo " .. quote(root .. "/elsewhere/pipe") .. " && ln -s " .. quote(root .. "/elsewhere/pipe") .. " " .. path,
			link_dangling = "ln -s " .. quote(root .. "/elsewhere/missing.toml") .. " " .. path,
			link_loop = "ln -s " .. path .. " " .. path,
		})[entry.kind]
		assert(os.execute(command))
	end
	local ok, err = pcall(body, helpers.load_module("modules.updater.config_backup")._list, root .. "/cfg")
	os.execute("rm -rf " .. quote(root))
	if not ok then error(err, 0) end
end

require("test.config_backup_binding_contract").register(helpers, { defaults = defaults, listing = real_listing })
require("test.release_install_contract").register(helpers)

helpers.describe("configuration backup listing of special files (config-backup-special-nodes)", function()
	helpers.it("(config-backup-special-nodes) reports a FIFO, a socket and a link to a FIFO as other and never opens them", function()
		local uv = require("luv")
		local root = os.tmpname()
		os.remove(root)
		assert(os.execute("mkdir -p '" .. root .. "'"))
		assert(os.execute("mkfifo '" .. root .. "/pipe.toml'"))
		assert(os.execute("ln -s '" .. root .. "/pipe.toml' '" .. root .. "/linked_pipe.toml'"))
		assert(os.execute("ln -s '" .. root .. "/missing.toml' '" .. root .. "/dangling.toml'"))
		assert(os.execute(": > '" .. root .. "/plain.toml'"))
		local server = uv.new_pipe(false)
		assert(server:bind(root .. "/socket.toml"))
		local kinds
		local ok, err = pcall(function()
			-- The listing must classify by stat alone: opening the FIFO would block forever.
			local list = helpers.load_module("modules.updater.config_backup")._list
			kinds = {}
			for _, entry in ipairs(assert(list(root))) do kinds[entry.name] = entry.kind end
		end)
		server:close()
		os.execute("rm -rf '" .. root .. "'")
		if not ok then error(err, 0) end
		helpers.assert_eq(kinds["pipe.toml"], "other")
		helpers.assert_eq(kinds["socket.toml"], "other")
		helpers.assert_eq(kinds["linked_pipe.toml"], "other")
		helpers.assert_eq(kinds["dangling.toml"], "other")
		helpers.assert_eq(kinds["plain.toml"], "file")
	end)
end)

local policy_handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/network/managed_network.json", "rb"))
local policy = assert(Json.decode(policy_handle:read("*a")), "managed network policy must decode")
policy_handle:close()
require("test.release_install_network_contract").register(helpers, policy)
