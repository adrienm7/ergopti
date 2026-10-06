--- tests/unit/adapters/test_program_providers.lua

--- Native boundary fixtures model stat, realpath and Lua 5.4's four-value
--- directory iterator. They do not qualify actual Hammerspoon or native exec.
local helpers = require("tests.helpers")
local RAW = [[{"version":1,"providers":[
{"id":"shell","mode":"script","extensions":["sh"],"commands":{"hs":["sh"]},"prefix":[]},
{"id":"bash","mode":"script","extensions":["bash"],"commands":{"hs":["bash"]},"prefix":[]},
{"id":"python","mode":"script","extensions":["py"],"commands":{"hs":["python3"]},"prefix":[]},
{"id":"executable","mode":"executable","extensions":[],"commands":{"hs":[]},"prefix":[]}
]}]]
local CONFIG = "/Users/élise/ErgoptiPlus"
local ROOT = CONFIG .. "/scripts"

local function with_native(body)
	local saved, old_hs, old_open, old_getenv = {}, _G.hs, io.open, os.getenv
	for name, value in pairs(package.loaded) do saved[name] = value end
	local native = { files = {}, directories = {}, links = {}, logs = {}, closes = 0, pulls = 0, opened = {}, close_handles = {}, config = CONFIG }
	local inode = 10
	function native.file(path, mode, permissions)
		inode = inode + 1
		native.files[path] = { mode = mode or "file", permissions = permissions or "rw-------", dev = 1, ino = inode,
			uid = 501, gid = 20, size = 17, modification = 1700000000, change = 1700000001 }
	end
	native.file(CONFIG, "directory", "rwx------")
	native.file(ROOT, "directory", "rwx------")
	native.file("/shared/modules/actions/program_providers.json")
	native.directories[CONFIG] = { "scripts" }
	native.directories[ROOT] = {}
	native.file("/bin", "directory", "rwxr-xr-x")
	native.directories["/bin"] = { "sh", "bash", "python3" }
	for _, command in ipairs(native.directories["/bin"]) do native.file("/bin/" .. command, "file", "rwxr-xr-x") end
	local ok, failure = xpcall(function()
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "error", "warn", "debug" }) do
			logger[level] = function(...) native.logs[#native.logs + 1] = { ... } end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.config_paths"] = { get_config_dir = function() return native.config end }
		package.loaded["infra.paths"] = { shared = function(relative) return "/shared/" .. relative end }
		_G.hs = { fs = {
			symlinkAttributes = function(path)
				if native.on_lstat then native.on_lstat(path) end
				local value = native.files[path]
				if not value then return nil, "PRIVATE native failure " .. path end
				local copy = {}; for key, item in pairs(value) do copy[key] = item end; return copy
			end,
			attributes = function(path)
				local value = native.files[native.links[path] or path]
				if not value then return nil, "PRIVATE referent failure " .. path end
				local copy = {}; for key, item in pairs(value) do copy[key] = item end
				if native.after_attributes then native.after_attributes(path) end
				return copy
			end,
			pathToAbsolute = function(path) return native.links[path] or (native.files[path] and path) end,
			dir = function(path)
				if native.factory_throw then error("PRIVATE iterator constructor") end
				local names = native.directories[path]
				if not names then error("PRIVATE unreadable " .. path) end
				local state = setmetatable({ index = 0 }, { __close = function()
					native.closes = native.closes + 1
				end })
				local function next_name(actual)
					assert(actual == state, "native iterator state must be retained")
					native.pulls = native.pulls + 1
					state.index = state.index + 1
					if native.pull_throw == state.index then error("PRIVATE iterator failure") end
					return names[state.index]
				end
				return next_name, state, nil, state
			end,
		}, task = { new = function() error("discovery must never create a native task") end },
			execute = function() error("discovery must never execute a command") end }
		io.open = function(path, mode)
			helpers.assert_eq(mode, "rb")
			native.opened[#native.opened + 1] = path
			if path == "/shared/modules/actions/program_providers.json" then
				local handle = { read = function() return RAW end }
				function handle:close()
					native.close_handles[#native.close_handles + 1] = self
					if native.on_close then native.on_close(path) end
					if native.catalog_close_throw then error("PRIVATE catalogue close") end
					return not native.catalog_close_refused
				end
				return handle
			end
			error("user and interpreter files must never be opened during inventory", 0)
		end
		os.getenv = function(name) if name == "PATH" then return native.path or "/bin" end; return old_getenv(name) end
		package.loaded["infra.fs_dir"] = nil
		package.loaded["adapters.program_providers"] = nil
		local adapter = require("adapters.program_providers")
		body(adapter, native, require("infra.fs_dir"))
		helpers.assert_eq(#native.logs, 0, "native private errors and names must never be logged")
	end, debug.traceback)
	_G.hs, io.open, os.getenv = old_hs, old_open, old_getenv
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

helpers.describe("private native provider directory boundary", function()
	helpers.it("retains iterator state and closes on truncation", function()
		with_native(function(_, native, directories)
			native.directories[ROOT] = { ".", "..", "日本\n.sh", "e\204\129.py", "third" }
			local result = directories.collect_private(ROOT, 2)
			helpers.assert_eq(result, { names = { "日本\n.sh", "e\204\129.py" }, truncated = true })
			helpers.assert_eq(native.closes, 1)
			helpers.assert_eq(native.pulls, 5)
		end)
	end)

	helpers.it("closes the exact state on iterator failure without returning partial names", function()
		with_native(function(_, native, directories)
			native.directories[ROOT] = { "one", "two" }; native.pull_throw = 2
			local value, reason = directories.collect_private(ROOT, 2)
			helpers.assert_nil(value); helpers.assert_eq(reason, "listing_refused")
			helpers.assert_eq(native.closes, 1)
		end)
	end)

	helpers.it("closes on invalid native names and contains constructor refusal", function()
		with_native(function(_, native, directories)
			native.directories[ROOT] = { "bad/name" }
			helpers.assert_nil(directories.collect_private(ROOT, 2)); helpers.assert_eq(native.closes, 1)
			native.factory_throw = true
			helpers.assert_nil(directories.collect_private(ROOT, 2)); helpers.assert_eq(native.closes, 1)
		end)
	end)
end)

helpers.describe("native provider inventory through shared policy", function()
	helpers.it("preserves Unicode, newline and decomposed literal script paths and arguments", function()
		with_native(function(adapter, native)
			local name = "日本 e\204\129\n%PATH%.sh"
			native.directories[ROOT] = { name }; native.file(ROOT .. "/" .. name)
			native.file("/bin", "directory", "rwxr-xr-x"); native.file("/bin/sh", "file", "rwxr-xr-x")
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			helpers.assert_eq(#result.choices, 1)
			local scalar = assert(owner.resolve(result.choices[1].key, { "", "$(touch PRIVATE)", "'`\"\n", "e\204\129" }))
			local descriptor = require("json").decode_lossless(scalar)
			helpers.assert_eq(descriptor.executable, "/bin/sh")
			helpers.assert_eq(descriptor.arguments, { ROOT .. "/" .. name, "", "$(touch PRIVATE)", "'`\"\n", "e\204\129" })
		end)
	end)

	helpers.it("treats a proven missing scripts directory as neutral and access failure as refusal", function()
		with_native(function(adapter, native)
			native.files[ROOT] = nil; native.directories[CONFIG] = {}
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			helpers.assert_eq(#result.choices, 0)
			native.directories[CONFIG] = { "scripts" }
			helpers.assert_nil(owner.discover())
		end)
	end)

	helpers.it("skips script symlinks and ordinary subdirectories without claiming an interpreter", function()
		with_native(function(adapter, native)
			native.directories[ROOT] = { "linked.sh", "folder", "denied.sh" }
			native.file(ROOT .. "/linked.sh", "link", "rwxrwxrwx")
			native.file(ROOT .. "/folder", "directory", "rwx------")
			native.file(ROOT .. "/denied.sh", "file", "---------")
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			helpers.assert_eq(#result.choices, 0)
		end)
	end)

	helpers.it("refuses a script root symlink and ambiguous inode metadata", function()
		with_native(function(adapter, native)
			native.files[ROOT].mode = "link"
			local owner = assert(adapter.create()); helpers.assert_nil(owner.discover())
			native.files[ROOT].mode = "directory"; native.files[ROOT].ino = 9007199254740992.0
			helpers.assert_nil(owner.discover())
		end)
	end)

	helpers.it("revalidates physical script identity and configured route before resolving", function()
		with_native(function(adapter, native)
			local path = ROOT .. "/tool"; native.file(path, "file", "rwx------"); native.directories[ROOT] = { "tool" }
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			native.files[path].ino = native.files[path].ino + 1
			helpers.assert_nil(owner.resolve(result.choices[1].key, {}))
			result = assert(owner.discover()); native.config = "/Users/other"
			helpers.assert_nil(owner.resolve(result.choices[1].key, {}))
		end)
	end)

	helpers.it("resolves interpreter symlinks to a regular executable and rejects later target replacement", function()
		with_native(function(adapter, native)
			native.directories[ROOT] = { "tool.py" }; native.file(ROOT .. "/tool.py")
			native.path = "relative::/usr/local/bin"
			native.file("/usr/local/bin", "directory", "rwxr-xr-x")
			native.directories["/usr/local/bin"] = { "python3" }
			native.file("/usr/local/bin/python3", "link", "rwxrwxrwx")
			native.links["/usr/local/bin/python3"] = "/opt/Python/bin/python3"
			native.file("/opt/Python/bin/python3", "file", "rwxr-xr-x")
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			local descriptor = require("json").decode_lossless(assert(owner.resolve(result.choices[1].key, {})))
			helpers.assert_eq(descriptor.executable, "/opt/Python/bin/python3")
			native.files[descriptor.executable].ino = native.files[descriptor.executable].ino + 1
			helpers.assert_nil(owner.resolve(result.choices[1].key, {}))
		end)
	end)

	helpers.it("skips absent PATH directories and does not advertise the system Python install shim", function()
		with_native(function(adapter, native)
			native.path = "/never/installed:/usr/bin:/bin"
			native.file("/usr/bin", "directory", "rwxr-xr-x")
			native.file("/usr/bin/python3", "file", "rwxr-xr-x")
			native.files["/bin/python3"] = nil
			native.directories[ROOT] = { "tool.py", "tool.sh" }
			native.file(ROOT .. "/tool.py"); native.file(ROOT .. "/tool.sh")
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			helpers.assert_eq(#result.choices, 1)
			helpers.assert_eq(result.choices[1].provider, "shell")
			for _, provider in ipairs(result.providers) do
				if provider.id == "python" then helpers.assert_eq(provider.available, false) end
			end
		end)
	end)

	for _, fault in ipairs({ "refused", "throw" }) do
		helpers.it("retains exact catalogue close debt after " .. fault .. " and retries before opening a successor", function()
			with_native(function(adapter, native)
				native["catalog_close_" .. fault] = true
				helpers.assert_nil(adapter.create())
				local first = native.close_handles[1]
				helpers.assert_eq(#native.opened, 1)
				helpers.assert_nil(adapter.create())
				helpers.assert_eq(#native.opened, 1)
				helpers.assert_true(native.close_handles[2] == first)
				native["catalog_close_" .. fault] = false
				helpers.assert_true(adapter.create() ~= nil)
				helpers.assert_true(native.close_handles[3] == first)
				helpers.assert_eq(#native.opened, 2)
			end)
		end)
	end

	for _, fault in ipairs({ "refused", "throw" }) do
	helpers.it("retains catalogue close " .. fault .. " across an existing owner and recovers only the same handle", function()
		with_native(function(adapter, native)
			local path = ROOT .. "/tool"; native.file(path, "file", "rwx------"); native.directories[ROOT] = { "tool" }
			local owner = assert(adapter.create()); native["catalog_close_" .. fault] = true
			helpers.assert_nil(adapter.create())
			helpers.assert_nil(owner.discover())
			local first = native.close_handles[#native.close_handles]
			local opened = #native.opened
			helpers.assert_eq(owner.invalidate(), false)
			helpers.assert_nil(adapter.create())
			helpers.assert_eq(#native.opened, opened)
			helpers.assert_true(native.close_handles[#native.close_handles] == first)
			native["catalog_close_" .. fault] = false
			helpers.assert_eq(owner.invalidate(), true)
			helpers.assert_true(native.close_handles[#native.close_handles] == first)
			helpers.assert_eq(#assert(owner.discover()).choices, 1)
		end)
	end)
	end

	helpers.it("never opens user files when a regular script changes to a FIFO between stat observations", function()
		with_native(function(adapter, native)
			local path = ROOT .. "/race.sh"
			native.file(path); native.directories[ROOT] = { "race.sh" }
			local owner = assert(adapter.create())
			native.after_attributes = function(observed)
				if observed == path then native.files[path].mode = "named pipe" end
			end
			helpers.assert_nil(owner.discover())
			helpers.assert_eq(native.opened, { "/shared/modules/actions/program_providers.json" })
		end)
	end)

	helpers.it("keeps neighbouring exact native 64-bit inode identities distinct", function()
		with_native(function(adapter, native)
			local path = ROOT .. "/tool"; native.file(path, "file", "rwx------"); native.directories[ROOT] = { "tool" }
			native.files[path].ino = 9007199254740992
			helpers.assert_eq(math.type(native.files[path].ino), "integer")
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			helpers.assert_true(owner.resolve(result.choices[1].key, {}) ~= nil)
			native.files[path].ino = 9007199254740993
			helpers.assert_nil(owner.resolve(result.choices[1].key, {}))
		end)
	end)

	helpers.it("keeps neighbouring exact native 64-bit timestamp receipts distinct", function()
		with_native(function(adapter, native)
			local path = ROOT .. "/tool"; native.file(path, "file", "rwx------"); native.directories[ROOT] = { "tool" }
			native.files[path].modification = 9007199254740992
			local owner = assert(adapter.create()); local result = assert(owner.discover())
			native.files[path].modification = 9007199254740993
			helpers.assert_nil(owner.resolve(result.choices[1].key, {}))
		end)
	end)

	helpers.it("refuses a neighbouring exact inode replacement during post-stat verification", function()
		with_native(function(adapter, native)
			local path = ROOT .. "/tool"; native.file(path, "file", "rwx------"); native.directories[ROOT] = { "tool" }
			native.files[path].ino = 9007199254740992
			local owner = assert(adapter.create())
			native.after_attributes = function(observed)
				if observed == path then native.files[path].ino = 9007199254740993 end
			end
			helpers.assert_nil(owner.discover())
			helpers.assert_eq(native.files[path].ino, 9007199254740993)
		end)
	end)

	helpers.it("rejects negative, nonfinite and unsafe floating native metadata without replacing source", function()
		with_native(function(adapter, native)
			local owner = assert(adapter.create())
			for _, value in ipairs({ -1, 0 / 0, math.huge, 9007199254740992.0 }) do
				native.files[ROOT].ino = value
				helpers.assert_nil(owner.discover())
				helpers.assert_eq(native.files[ROOT].ino == value or value ~= value, true)
			end
		end)
	end)

	helpers.it("refuses nested acquisition while its exact reader is closing", function()
		with_native(function(adapter, native)
			local nested = 0
			native.on_close = function()
				nested = nested + 1
				helpers.assert_nil(adapter.create())
			end
			helpers.assert_true(adapter.create() ~= nil)
			helpers.assert_eq(nested, 1)
			helpers.assert_eq(#native.opened, 1)
		end)
	end)
end)

helpers.describe("native provider fixture scalar boundary", function()
	helpers.it("forwards one scalar from actual shared resolution to the strict SDK arity mirror", function()
		-- This executes the native case body, not the native JSON implementation.
		local fixture = helpers.driver_root() .. "../../../tools/diagnostics/native_hs_program_providers/fixture.lua"
		local handle = assert(io.open(fixture, "rb"))
		local source = assert(handle:read("*a")); helpers.assert_true(handle:close() == true)
		local body = assert(source:match('case%("real_interpreter_symlink", function%(%)\n(.-)\nend%)\ncase%("interpreter_link_retarget_is_stale"'))
		local observer = assert(source:match("local function observe_scalar%(%.%.%.%)\n.-\nend"))
		with_native(function()
			local shared, json = require("program_providers"), require("json")
			local input = { config = "/fixture", expected_python = "/fixture/python3" }
			local owner = assert(shared.new("hs", RAW, {
				route = function() return "/fixture/scripts" end,
				list = function() return { names = { "literal.py" }, truncated = false } end,
				identity = function(path)
					if path == "/fixture/scripts" then return { kind = "directory", token = "owned-directory" } end
					if path == "/fixture/scripts/literal.py" or path == "/fixture/python3" then
						return { kind = "file", token = path, readable = true, executable = true }
					end
					return nil, "missing"
				end,
				interpreter = function(commands)
					if commands[1] == "python3" then return { executable = "/fixture/python3", token = "/fixture/python3" } end
					return nil, "unavailable"
				end,
			}))
			local initial = assert(owner.discover())
			helpers.assert_eq(#initial.choices, 1)
			helpers.assert_eq(initial.choices[1].label, "literal.py")
			helpers.assert_eq(select("#", owner.resolve(initial.choices[1].key, {})), 2,
				"the actual shared owner returns a scalar and an explicit nil reason")
			local checks, decoded, resolved = 0, 0, 0
			local resolve = owner.resolve
			owner.resolve = function(...) resolved = resolved + 1; return resolve(...) end
			local facts = {}
			local environment = setmetatable({
				owner = owner, initial = initial, input = input, interpreter_facts = facts,
				check = function(value) checks = checks + 1; helpers.assert_true(value) end,
				choices_by_name = function(result)
					local values = {}; for _, choice in ipairs(result.choices) do values[choice.label] = choice end; return values
				end,
				hs = { json = { decode = function(...)
					decoded = decoded + 1
					-- Independent mirror of official LS_TSTRING, LS_TBREAK: exactly one string.
					helpers.assert_eq(select("#", ...), 1, "strict SDK decoder argument count")
					helpers.assert_eq(type((...)), "string")
					return json.decode((...))
				end } },
			}, { __index = _G })
			local chunk = observer .. "\nreturn function()\n" .. body .. "\nend"
			local loader
			if loadstring then loader = assert(loadstring(chunk, "@native-provider-scalar-control")); setfenv(loader, environment)
			else loader = assert(load(chunk, "@native-provider-scalar-control", "t", environment)) end
			loader()()
			helpers.assert_eq(checks, 2, "both original native predicates execute")
			helpers.assert_eq(decoded, 1)
			helpers.assert_eq(resolved, 1)
			helpers.assert_eq(facts, { resolved_scalar_observed = true, interpreter_equal = true,
				argv_count_equal = true, script_argument_equal = true })
		end)
	end)
end)
