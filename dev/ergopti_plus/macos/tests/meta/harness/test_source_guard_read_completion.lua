--- tests/meta/harness/test_source_guard_read_completion.lua

--- ==============================================================================
--- MODULE: Mandatory Source Guard Read Receipts
--- DESCRIPTION:
--- Replays actual source guards over healthy native files, then refuses exactly
--- one content read discovered in that control. Existence-only probes retain
--- their normal receipts. A real inventory/unlink race protects the forbidden
--- source counterexample without inventing a native file-close lifetime.
--- ==============================================================================

local helpers = require("tests.helpers")
local CommandLines = require("tests.support.command_lines")
local SourceFile = require("tests.support.source_file")
local ModuleIsolation = require("tests.support.module_isolation")
local shell_quote = require("text_utils").shell_quote
local ROOT = helpers.driver_root()
local DIRECTORY = ROOT .. "tests/meta"
local INVENTORY_COMMAND = package.config:sub(1, 1) == "\\"
	and ('cmd /c dir /b /s /a-d "' .. DIRECTORY:gsub("/", "\\") .. '"')
	or ("find " .. shell_quote(DIRECTORY) .. " -type f -name '*.lua'")
local GUARDS = {}
for _, raw_path in ipairs(CommandLines.read(INVENTORY_COMMAND)) do
	local path = raw_path:gsub("\\", "/")
	if path:match("%.lua$") and not path:match("/test_source_guard_read_completion%.lua$")
		and not path:match("/test_meta_inventory_completion%.lua$") then
		local source = SourceFile.read(path)
		local inventory = source:find(" -type f", 1, true) or source:find("/b /s /a-d", 1, true)
			or source:find("lfs.dir", 1, true)
		local content = source:find("SourceFile.read(", 1, true)
			or (source:find("io.open(", 1, true) and source:find(':read("*a")', 1, true))
		if inventory and content then GUARDS[#GUARDS + 1] = path end
	end
end
table.sort(GUARDS)
assert(#GUARDS > 0, "mandatory source guard discovery must not be empty")

--- Executes one complete actual guard while restoring native I/O and module state.
--- @param path string Actual meta-test source.
--- @param fault string|nil One native receipt to refuse.
--- @param target table|nil The exact content-read open observed in its control.
--- @param fixture table|nil Alternate physical source tree and inventory observer.
--- @return table facts Native observations and guard verdict.
local function replay(path, fault, target, fixture)
	local source = SourceFile.read(path)
	local saved, previous_hs = {}, hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	ModuleIsolation.purge(ROOT, helpers.shared("lua"))
	local facts = { accepted = false, opened = {}, closes = 0, faulted = 0 }
	local streams = {}
	local open = io.open
	local stub_helpers = setmetatable({
		driver_root = function() return fixture and fixture.root or ROOT end,
		describe = function(_, callback) callback() end,
		it = function(_, callback) callback() end,
	}, { __index = helpers })
	local environment = setmetatable({ require = function(name)
		if name == "tests.helpers" then return stub_helpers end
		if fixture and name == "lfs" then error("exercise the native command inventory") end
		if fixture and name == "tests.support.command_lines" then
			return { read = function(command)
				local lines = CommandLines.read(command)
				if fixture.inventory then fixture.inventory(lines) end
				return lines
			end }
		end
		return require(name)
	end }, { __index = _G })
	io.open = function(filename, mode, ...)
		local eligible = type(filename) == "string" and (filename:match("%.lua$") or filename:match("%.js$"))
			and (mode == nil or mode:sub(1, 1) == "r")
		if not eligible then return open(filename, mode, ...) end
		facts.opened[filename] = (facts.opened[filename] or 0) + 1
		local ordinal = facts.opened[filename]
		local selected = target and filename == target.path and ordinal == target.ordinal
		if selected and fault == "open" then facts.faulted = facts.faulted + 1; return nil, "controlled source open refusal" end
		local file, reason, errno = open(filename, mode, ...)
		if not file then return nil, reason, errno end
		streams[#streams + 1] = file
		return setmetatable({
			read = function(_, ...)
				if not facts.target then facts.target = { path = filename, ordinal = ordinal } end
				if selected and fault == "read" then facts.faulted = facts.faulted + 1; return nil, "controlled source read refusal" end
				return file:read(...)
			end,
			close = function()
				if selected then facts.closes = facts.closes + 1 end
				local closed, failure, code = file:close()
				if selected and fault == "close" then
					facts.faulted = facts.faulted + 1
					facts.close_settled = io.type(file) == "closed file"
					return nil, "controlled source close refusal"
				end
				return closed, failure, code
			end,
		}, { __index = function(_, key)
			local value = file[key]
			if type(value) == "function" then return function(_, ...) return value(file, ...) end end
			return value
		end })
	end
	local ok, reason = pcall(function() return assert(load(source, "@" .. path, "t", environment))() end)
	facts.accepted, facts.reason = ok, reason
	for _, file in ipairs(streams) do if io.type(file) == "file" then pcall(file.close, file) end end
	io.open = open
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = previous_hs
	return facts
end

--- Creates only an owned temporary source tree and always removes its own files.
--- @param callback function Receives the source root and forbidden file path.
local function with_sources(callback)
	local fs = require("tests.stubs.hs").fs
	local root = assert(os.tmpname()):gsub("\\", "/")
	local removed, reason, errno = os.remove(root)
	assert(removed or errno == 2, reason)
	local directories, files = {}, {}
	local function directory(path)
		assert(fs.attributes(path) == nil, "source fixture must not replace an existing path")
		assert(fs.mkdir(path))
		directories[#directories + 1] = path
	end
	local function write(path, content)
		local file = assert(io.open(path, "w"))
		files[#files + 1] = path
		local written = table.pack(pcall(file.write, file, content))
		local closed = table.pack(pcall(file.close, file))
		assert(written[1] and written[2], tostring(written[3] or written[2]))
		assert(closed[1] and closed[2], tostring(closed[3] or closed[2]))
	end
	local outcome = table.pack(pcall(function()
		directory(root)
		for _, name in ipairs({ "adapters", "infra", "modules", "platform", "ui" }) do
			directory(root .. "/" .. name)
			write(root .. "/" .. name .. "/healthy.lua", "local safe = true\n")
		end
		local forbidden = root .. "/adapters/forbidden.lua"
		write(forbidden, [[hs.execute(string.format("find %q", path))]])
		callback(root .. "/", forbidden)
	end))
	local cleanup = {}
	for _, path in ipairs(files) do
		local ok, failure, code = os.remove(path)
		if not ok and code ~= 2 then cleanup[#cleanup + 1] = tostring(failure) end
	end
	for index = #directories, 1, -1 do
		local ok, failure = fs.rmdir(directories[index])
		if not ok then cleanup[#cleanup + 1] = tostring(failure) end
	end
	if #cleanup > 0 then error(tostring(outcome[2]) .. "; cleanup: " .. table.concat(cleanup, "; "), 0) end
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("mandatory source guard reads", function()
	for _, path in ipairs(GUARDS) do
		helpers.it("(source-guard-read-completion) " .. path:sub(#ROOT + 1), function()
			local control = replay(path)
			helpers.assert_true(control.accepted, tostring(control.reason))
			helpers.assert_type(control.target, "table", "the healthy guard must consume an actual source")
			for _, phase in ipairs({ "open", "read", "close" }) do
				local result = replay(path, phase, control.target)
				helpers.assert_eq(result.faulted, 1, "reach the exact mandatory source " .. phase .. " receipt")
				helpers.assert_eq(result.accepted, false, "a source " .. phase .. " refusal cannot certify the guard")
				helpers.assert_true(tostring(result.reason):find("source " .. phase .. " failed", 1, true) ~= nil,
					"retain the failing source phase and path: " .. tostring(result.reason))
				helpers.assert_eq(result.closes, phase == "open" and 0 or 1, "retire each acquired source handle")
				if phase == "close" then helpers.assert_true(result.close_settled, "a native close error is not a live stream") end
			end
		end)
	end
	local guard = ROOT .. "tests/meta/shell_quoting/test_shell_quoting_not_lua_q.lua"
	helpers.it("(source-guard-native-race) still rejects the readable forbidden source", function()
		with_sources(function(root)
			local result = replay(guard, nil, nil, { root = root })
			helpers.assert_eq(result.accepted, false)
			helpers.assert_true(tostring(result.reason):find("quote a path with Lua's %q", 1, true) ~= nil)
		end)
	end)
	helpers.it("(source-guard-native-race) refuses a real file removed after its complete inventory", function()
		with_sources(function(root, forbidden)
			local vanished = false
			local result = replay(guard, nil, nil, { root = root, inventory = function(lines)
				for _, path in ipairs(lines) do
					if path:gsub("\\", "/") == forbidden then assert(os.remove(forbidden)); vanished = true end
				end
			end })
			helpers.assert_true(vanished, "the real native inventory must have listed the source before removal")
			helpers.assert_eq(result.accepted, false, "native ENOENT cannot erase a listed violation from source evidence")
			helpers.assert_true(tostring(result.reason):find("source open failed", 1, true) ~= nil)
			helpers.assert_true(tostring(result.reason):find(forbidden, 1, true) ~= nil)
		end)
	end)
end)
