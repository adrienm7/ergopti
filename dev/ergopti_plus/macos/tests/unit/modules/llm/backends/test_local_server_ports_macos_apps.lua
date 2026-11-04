--- tests/unit/modules/llm/backends/test_local_server_ports_macos_apps.lua

--- ==============================================================================
--- MODULE: Local Server Port Discovery on macOS Installs
--- DESCRIPTION:
--- The shared port corpus describes the new local servers through their Linux
--- installs only. On a Mac, GPT4All runs as gpt4all.app/Contents/MacOS/gpt4all
--- (its CMake target is renamed on Apple) and Lemonade keeps its config.json in
--- ~/.config/lemonade or, for a system install, in
--- /Library/Application Support/lemonade/.config: replay the shipped catalogue
--- against those macOS readings.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local Ports = require("llm.local_server_ports")

--- Reads the shipped local server catalogue.
--- @return table
local function catalogue()
	local file = assert(io.open(Paths.shared("modules/llm/local_servers.json"), "rb"))
	local root = assert(Json.decode(file:read("*a")))
	file:close()
	return root
end

--- Resolves one server against a modelled Mac.
--- @param id string Catalogue server id.
--- @param ps string "pid command line" rows.
--- @param files table Path to content.
--- @param lsof string|nil lsof -F pcn output.
--- @return table result
local function resolve(id, ps, files, lsof)
	local server = assert(catalogue().servers[id], "catalogue server " .. id)
	local descriptor = assert(Ports.descriptor(id, server.discovery))
	local context = {
		os = "macos", home = "/Users/u", decode_json = Json.decode,
		read_file = function(path) return files[path] end,
	}
	local result = Ports.resolve(id, descriptor, server.base_url, Ports.parse_processes(ps), context)
	if result.needs_listeners then Ports.apply_listeners(result, Ports.parse_lsof(lsof or "")) end
	return result
end

helpers.describe("Local server port discovery on macOS installs (local-server-ports-macos)", function()
	helpers.it("the GPT4All app executable makes GPT4All run", function()
		local result = resolve("gpt4all", "812 /Applications/gpt4all/bin/gpt4all.app/Contents/MacOS/gpt4all", {},
			"p812\ncgpt4all\nn127.0.0.1:4891\n")
		helpers.assert_eq(result.running, true)
		helpers.assert_eq(table.concat(result.pids, ","), "812")
		helpers.assert_eq(result.port, 4891)
	end)

	helpers.it("a gpt4all folder alone does not make GPT4All run", function()
		local result = resolve("gpt4all", "90 /Users/u/gpt4all/tools/convert --port 4891", {})
		helpers.assert_eq(result.running, false)
	end)

	helpers.it("Lemonade on a Mac reads its user config.json", function()
		local result = resolve("lemonade", "700 /usr/local/bin/lemond", {
			["/Users/u/.config/lemonade/config.json"] = "{\"port\":13400}",
		})
		helpers.assert_eq(result.running, true)
		helpers.assert_eq(result.source, "config")
		helpers.assert_eq(result.port, 13400)
		helpers.assert_eq(result.base_url, "http://127.0.0.1:13400/v1")
	end)

	helpers.it("Lemonade's macOS system install reads its Application Support config.json", function()
		local result = resolve("lemonade", "701 /Applications/Lemonade.app/Contents/MacOS/lemond", {
			["/Library/Application Support/lemonade/.config/config.json"] = "{\"port\":13500}",
		})
		helpers.assert_eq(result.source, "config")
		helpers.assert_eq(result.port, 13500)
	end)

	helpers.it("the Linux packaged-service folder is not read on a Mac", function()
		local result = resolve("lemonade", "702 lemond", {
			["/var/lib/lemonade/config.json"] = "{\"port\":13600}",
		}, "p702\nclemond\nn127.0.0.1:13305\n")
		helpers.assert_eq(result.port, 13305)
		helpers.assert_true(result.source ~= "config", "the /var/lib folder belongs to the Linux service")
	end)
end)
