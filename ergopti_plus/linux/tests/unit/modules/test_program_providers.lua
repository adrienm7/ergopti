--- tests/unit/modules/test_program_providers.lua

--- Shared discovery admission uses only bounded scalar native receipts.
local helpers = require("tests.helpers")
local Shared = require("program_providers")
local Json = require("json")
local Parameter = require("program_parameter")
local Paths = require("infra.paths")
local file = assert(io.open(Paths.shared("modules/actions/program_providers.json"), "rb"))
local RAW = file:read("*a"); assert(file:close())
local ROOT = "/configuration/scripts"

local function fixture()
	local f = { root = ROOT, names = { "écho.sh", "calc.py", "native", "nested", "link.sh" }, identities = {}, closes = 0 }
	f.identities[ROOT] = { kind = "directory", token = "directory:1" }
	for _, command in ipairs({ "sh", "bash", "python3" }) do
		f.identities["/native/" .. command] = { kind = "file", token = "interpreter:" .. command, readable = true, executable = true }
	end
	for _, name in ipairs({ "écho.sh", "calc.py", "native" }) do
		f.identities[ROOT .. "/" .. name] = { kind = "file", token = "file:" .. name, readable = true, executable = name == "native" }
	end
	f.identities[ROOT .. "/nested"] = { kind = "directory", token = "nested:1" }
	f.identities[ROOT .. "/link.sh"] = { kind = "other", token = "link:1" }
	f.ports = {
		route = function() return f.root end,
		list = function(path, limit)
			helpers.assert_eq(path, ROOT); helpers.assert_eq(limit, Shared.MAX_SCAN)
			if f.on_list then f.on_list() end
			return { names = f.names, truncated = false }
		end,
		identity = function(path)
			if f.on_identity then f.on_identity(path) end
			return f.identities[path], f.identities[path] == nil and "missing" or nil
		end,
		interpreter = function(commands)
			if f.on_interpreter then f.on_interpreter() end
			if f.unavailable then return nil, "unavailable" end
			local target = "/native/" .. commands[1]
			return { executable = target, token = f.identities[target].token }
		end,
		retire = function()
			f.closes = f.closes + 1
			if f.close_throw then error("private native refusal") end
			return f.closed
		end,
	}
	f.closed = true
	f.owner = assert(Shared.new("linux", RAW, f.ports))
	function f.key(label)
		local packet = assert(f.owner.discover())
		for _, choice in ipairs(packet.choices) do if choice.label == label then return choice.key, packet end end
		error("expected fixture choice")
	end
	return f
end

helpers.describe("shared private program discovery", function()
	helpers.it("preserves the POSIX catalogue while validating Windows-only provider metadata", function()
		for _, platform in ipairs({ "linux", "hs" }) do
			local providers = assert(Shared.catalogue(RAW, platform))
			helpers.assert_eq(#providers, 4)
			for index, id in ipairs({ "shell", "bash", "python", "executable" }) do
				helpers.assert_eq(providers[index].id, id)
				helpers.assert_eq(#providers[index].prefix, 0)
			end
			helpers.assert_eq(providers[3].commands[platform][1], "python3")
		end
		local data = Json.decode_lossless(RAW)
		local by_id = {}; for _, provider in ipairs(data.providers) do by_id[provider.id] = provider end
		helpers.assert_eq(by_id.python.commands.ahk[1], "python3.exe")
		helpers.assert_eq(by_id.python.commands.ahk[2], "python.exe")
		helpers.assert_eq(by_id.powershell.extensions[1], "ps1")
		helpers.assert_eq(by_id.powershell.commands.ahk[1], "pwsh.exe")
		helpers.assert_eq(by_id.powershell.commands.ahk[2], "powershell.exe")
		for index, value in ipairs({ "-NoProfile", "-NonInteractive", "-File" }) do
			helpers.assert_eq(by_id.powershell.prefix[index], value)
		end
		helpers.assert_eq(by_id.autohotkey.extensions[1], "ahk")
		helpers.assert_eq(by_id.autohotkey.prefix[1], "/ErrorStdOut=UTF-8")
		helpers.assert_eq(#by_id.executable.commands.ahk, 0)
		helpers.assert_eq(Shared.catalogue(RAW, "ahk"), nil)
	end)

	helpers.it("rejects malformed Windows metadata before allocating a POSIX discovery session", function()
		for _, kind in ipairs({ "unknown_platform", "command_type", "command_injection", "empty_script_commands", "prefix_nul" }) do
			local data = Json.decode_lossless(RAW)
			local provider
			for _, value in ipairs(data.providers) do if value.id == "powershell" then provider = value end end
			assert(provider)
			if kind == "unknown_platform" then provider.commands.other = Json.array({ "shell" })
			elseif kind == "command_type" then provider.commands.ahk = "powershell.exe"
			elseif kind == "command_injection" then provider.commands.ahk[1] = "powershell.exe;exit"
			elseif kind == "empty_script_commands" then provider.commands.ahk = Json.array({})
			else provider.prefix[1] = "\0" end
			local f = fixture()
			local owner, reason = Shared.new("linux", assert(Json.encode(data)), f.ports)
			helpers.assert_eq(owner, nil); helpers.assert_eq(reason, "invalid_catalogue")
			helpers.assert_eq(f.closes, 0)
		end
	end)

	helpers.it("lowers known scripts and executables to literal argv without leaking paths into choices", function()
		local f = fixture()
		local key, packet = f.key("écho.sh")
		helpers.assert_eq(#packet.choices, 3)
		helpers.assert_eq(packet.providers[3].id, "python")
		for _, choice in ipairs(packet.choices) do
			local fields = 0; for name in pairs(choice) do
				helpers.assert_eq(name == "key" or name == "label" or name == "provider", true); fields = fields + 1
			end
			helpers.assert_eq(fields, 3)
		end
		local args = { "", "quote'\"", "$(not-run)`literal`", "%PATH%", "e\204\129\n" }
		local parsed = assert(Parameter.parse(assert(f.owner.resolve(key, args)), "linux"))
		helpers.assert_eq(parsed.executable, "/native/sh")
		helpers.assert_eq(parsed.arguments[1], ROOT .. "/écho.sh")
		for index, value in ipairs(args) do helpers.assert_eq(parsed.arguments[index + 1], value) end
		key = f.key("native")
		parsed = assert(Parameter.parse(assert(f.owner.resolve(key, {})), "linux"))
		helpers.assert_eq(parsed.executable, ROOT .. "/native")
		helpers.assert_eq(#parsed.arguments, 0)
	end)

	helpers.it("rejects substituted files, interpreter receipts, directory receipts and routes at confirmation", function()
		for _, kind in ipairs({ "file", "interpreter", "directory", "route", "path" }) do
			local f = fixture(); local key = f.key("écho.sh")
			if kind == "file" then f.identities[ROOT .. "/écho.sh"].token = "replacement"
			elseif kind == "interpreter" then f.identities["/native/sh"].token = "replacement"
			elseif kind == "directory" then f.identities[ROOT].token = "replacement"
			elseif kind == "path" then f.unavailable = true
			else f.root = "/other/scripts" end
			local value, reason = f.owner.resolve(key, {})
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "stale_discovery")
		end
	end)

	helpers.it("skips ordinary directories and symlinks, and inventories unavailable interpreters honestly", function()
		local f = fixture(); f.unavailable = true
		local packet = assert(f.owner.discover())
		helpers.assert_eq(#packet.choices, 1); helpers.assert_eq(packet.choices[1].provider, "executable")
		helpers.assert_eq(packet.providers[1].available, false)
		helpers.assert_eq(packet.providers[1].reason, "interpreter_unavailable")
		f.identities[ROOT] = nil
		packet = assert(f.owner.discover())
		helpers.assert_eq(#packet.choices, 0); helpers.assert_eq(packet.truncated, false)
		f.identities[ROOT] = { kind = "other", token = "symlink" }
		helpers.assert_eq(f.owner.discover(), nil)
	end)

	helpers.it("rejects sparse, keyed, invalid UTF-8, NUL and over-budget arguments", function()
		local f = fixture(); local key = f.key("écho.sh")
		for _, args in ipairs({ { [2] = "hole" }, { extra = "key" }, { "\255" }, { "\0" }, { string.rep("x", Shared.MAX_ARGUMENT_BYTES + 1) } }) do
			local value, reason = f.owner.resolve(key, args)
			helpers.assert_eq(value, nil); helpers.assert_eq(reason, "invalid_arguments")
		end
	end)

	helpers.it("bounds choices without fabricating missing catalogue entries", function()
		local f = fixture(); f.names = {}
		for index = 1, Shared.MAX_CHOICES + 1 do
			local name = string.format("%03d.sh", index)
			f.names[index] = name
			f.identities[ROOT .. "/" .. name] = { kind = "file", token = name, readable = true, executable = false }
		end
		local packet = assert(f.owner.discover())
		helpers.assert_eq(#packet.choices, Shared.MAX_CHOICES); helpers.assert_eq(packet.truncated, true)
		f.names = { "../escape.sh" }
		helpers.assert_eq(f.owner.discover(), nil)
		f.names = { "écho.sh", "écho.sh" }
		helpers.assert_eq(f.owner.discover(), nil)
	end)

	helpers.it("invalidates acquisition and confirmation reentrancy without admitting a successor", function()
		local f = fixture()
		f.on_interpreter = function()
			helpers.assert_eq(f.owner.discover(), nil)
			helpers.assert_eq(f.owner.invalidate(), true)
		end
		local packet, reason = f.owner.discover()
		helpers.assert_eq(packet, nil); helpers.assert_eq(reason, "stale_discovery")
		f.on_interpreter = nil
		local key = f.key("écho.sh")
		f.on_identity = function(path)
			if path == ROOT .. "/écho.sh" then f.owner.invalidate() end
		end
		helpers.assert_eq(f.owner.resolve(key, {}), nil)
	end)

	helpers.it("requires literal native close receipts and retains retryable refusal", function()
		local f = fixture(); local key = f.key("écho.sh")
		f.closed = nil; helpers.assert_eq(f.owner.invalidate(), false)
		helpers.assert_eq(f.owner.resolve(key, {}), nil)
		f.close_throw = true; helpers.assert_eq(f.owner.invalidate(), false)
		f.close_throw = false; f.closed = true
		helpers.assert_eq(f.owner.invalidate(), true); helpers.assert_eq(f.closes, 3)
	end)

	helpers.it("refuses corrupted catalogues before acquiring any native resource", function()
		local f = fixture()
		for _, raw in ipairs({ "null", "{}", RAW:gsub('"version": 1', '"version": 2'), RAW:gsub('"python3"', '"python3;evil"') }) do
			helpers.assert_eq(Shared.new("linux", raw, f.ports), nil)
		end
		helpers.assert_eq(f.closes, 0)
		helpers.assert_eq(Json.decode_lossless(RAW).version, 1)
	end)
end)
