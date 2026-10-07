--- platform/remap/owned_configuration.lua

--- Binds complete diagnostic publication to an actual private directory and process.
local Publication = require("remap.owned_configuration_publication")
local Lifetime = require("keylogger.physical_subscription_lifetime")
local FileSystem = require("adapters.file_system")
local Generator = require("platform.remap.generator")
local M = {}

--- Binds a private diagnostic file; it grants no installed runtime or remapping authority.
---@param owner table Exact private subscriber.
---@param root string Existing canonical private ErgoptiPlus parent directory.
---@param expected_uid number Actual creating process UID observed by its Python owner.
---@param expected_pid number Actual scripting process PID observed by its Python owner.
---@return table|nil publisher Complete private document publisher.
---@return string|nil reason Closed refusal boundary.
function M.bind_private(owner, root, expected_uid, expected_pid)
	if type(owner) ~= "table" or type(root) ~= "string" or root:sub(1, 1) ~= "/"
		or root:sub(-1) == "/" or root:find("//", 1, true) or root:find("\0", 1, true)
		or root:match("/%.[./]?") or type(expected_uid) ~= "number" or expected_uid < 0
		or expected_uid % 1 ~= 0 or type(expected_pid) ~= "number" or expected_pid <= 0
		or expected_pid % 1 ~= 0 then return nil, "owned_private_binding_refused" end
	local host = hs
	local fs, json, process = host and host.fs, host and host.json, host and host.processInfo
	if type(fs) ~= "table" or type(json) ~= "table" or type(process) ~= "table" then
		return nil, "owned_private_binding_refused"
	end
	local attributes, absolute, encoder = fs.symlinkAttributes, fs.pathToAbsolute, json.encode
	local builder = Generator.build_karabiner_json
	local reader, writer, receipt_view = FileSystem.read_with_status,
		FileSystem.write_if_unchanged, FileSystem.publication_receipt_view
	if type(attributes) ~= "function" or type(absolute) ~= "function" or type(encoder) ~= "function"
		or type(builder) ~= "function" or type(reader) ~= "function" or type(writer) ~= "function"
		or type(receipt_view) ~= "function" then return nil, "owned_private_binding_refused" end
	local token, snapshots, errors = {}, {}, {}
	local life = Lifetime.new(owner, token)
	local capability = life.capability()
	local destination = root .. "/karabiner/karabiner.json"
	local function whole()
		return rawequal(hs, host) and rawequal(host.fs, fs) and rawequal(host.json, json)
			and rawequal(host.processInfo, process) and process.processID == expected_pid
			and rawequal(fs.symlinkAttributes, attributes) and rawequal(fs.pathToAbsolute, absolute)
			and rawequal(json.encode, encoder) and rawequal(Generator.build_karabiner_json, builder)
			and rawequal(FileSystem.read_with_status, reader) and rawequal(FileSystem.write_if_unchanged, writer)
			and rawequal(FileSystem.publication_receipt_view, receipt_view)
	end
	local function shape(value)
		return type(value) == "table" and value.mode == "directory" and type(value.uid) == "number"
			and value.uid % 1 == 0 and type(value.dev) == "number" and value.dev % 1 == 0
			and type(value.ino) == "number" and value.ino % 1 == 0 and type(value.permissions) == "string"
	end
	local function inspect(path, private, initial)
		if not whole() then return false end
		local metadata = attributes(path)
		if not whole() or not shape(metadata) or (private and
			(metadata.uid ~= expected_uid or metadata.permissions ~= "rwx------")) then return false end
		local original = snapshots[path]
		if initial then
			snapshots[path] = { dev = metadata.dev, ino = metadata.ino, uid = metadata.uid,
				mode = metadata.mode, permissions = metadata.permissions }
			return true
		end
		return original ~= nil and original.dev == metadata.dev and original.ino == metadata.ino
			and original.uid == metadata.uid and original.mode == metadata.mode
			and original.permissions == metadata.permissions
	end
	local paths = { "/" }
	local cursor = ""
	for component in root:gmatch("[^/]+") do
		cursor = cursor .. "/" .. component
		paths[#paths + 1] = cursor
	end
	paths[#paths + 1] = root .. "/karabiner"
	local function route_current(initial)
		if not whole() or absolute(root) ~= root or not whole() then return false end
		for _, path in ipairs(paths) do
			if not inspect(path, path == root or path == root .. "/karabiner", initial) then return false end
		end
		local final = attributes(destination)
		if not whole() then return false end
		return final == nil or (type(final) == "table" and final.mode == "file" and final.uid == expected_uid)
	end
	local called, ready = pcall(life.run, route_current, true)
	if not called or ready ~= true then life.revoke(); life.detach(); return nil, "owned_private_binding_refused" end
	life.bind_detach(function() life.detach(); return true end)
	local source = {}
	function source.identity(candidate_owner)
		return capability.identity(candidate_owner)
	end
	function source.current(candidate_owner, candidate_token)
		if not capability.current(candidate_owner, candidate_token) then return false end
		local ok, current = pcall(life.run, route_current, false)
		return ok and current == true and capability.current(candidate_owner, candidate_token)
	end
	function source.route(candidate_owner, candidate_token)
		if source.current(candidate_owner, candidate_token) then return destination end
	end
	function source.detach(candidate_owner, candidate_token)
		return capability.detach(candidate_owner, candidate_token)
	end
	function source.retired(candidate_owner, candidate_token)
		return capability.retired(candidate_owner, candidate_token)
	end
	local ports = {}
	function ports.build(input)
		if type(input) ~= "table" then return nil, "owned_private_input_refused" end
		return builder(input.state, input.actions, input.keys, input.combos, input.non_canonical,
			input.data, input.lease_token)
	end
	function ports.encode(document) return encoder(document, true) end
	function ports.prepare(path)
		return path == destination and route_current(false)
	end
	function ports.read(path)
		local content, status = reader(path, ports.on_error)
		return { status = status, content = content }
	end
	ports.write, ports.receipt_view = writer, receipt_view
	function ports.on_error(category) errors[#errors + 1] = category end
	return Publication.new(owner, source, ports)
end

return M
