--- tests/unit/adapters/test_program_providers.lua

--- Real bounded filesystem discovery never executes a discovered program.
local helpers = require("tests.helpers")
local Native = require("luv")
local Shared = require("program_providers")
local Parameter = require("program_parameter")
local Paths = require("infra.paths")
local file = assert(io.open(Paths.shared("modules/actions/program_providers.json"), "rb"))
local RAW = file:read("*a"); assert(file:close())

local function adapter()
	-- Prior suites replace native dependency tables; pin this adapter's declared
	-- filesystem boundary while restoring the prior cached module afterward.
	local old = package.loaded["adapters.program_providers"]
	package.loaded["adapters.program_providers"] = nil
	local module = require("adapters.program_providers")
	package.loaded["adapters.program_providers"] = old
	return module
end

local function fixture(body)
	local root = assert(Native.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-provider-XXXXXX"))
	local owned_files, owned_dirs, owners = {}, {}, {}
	local f = { root = root, scripts = root .. "/scripts", bin = root .. "/bin", interpreters = {} }
	function f.directory(path)
		assert(Native.fs_mkdir(path, 448)); owned_dirs[#owned_dirs + 1] = path
	end
	function f.write(path, text, mode)
		local fd = assert(Native.fs_open(path, "w", mode or 384))
		assert(Native.fs_write(fd, text, 0)); assert(Native.fs_close(fd))
		assert(Native.fs_chmod(path, mode or 384))
		owned_files[path] = true
	end
	function f.link(target, path)
		assert(Native.fs_symlink(target, path)); owned_files[path] = true
	end
	function f.owner(native, path)
		local owner = assert(adapter().create({ native = native or Native, catalogue = RAW,
			route = function() return f.scripts end, path = function() return path or f.bin end }))
		owners[#owners + 1] = owner
		return owner
	end
	function f.key(owner, label)
		local packet = assert(owner.discover())
		for _, choice in ipairs(packet.choices) do if choice.label == label then return choice.key, packet end end
		error("missing expected private choice")
	end
	local ok, failure = xpcall(function()
		f.directory(f.scripts); f.directory(f.bin)
		for _, command in ipairs({ "sh", "bash", "python3" }) do
			local interpreter = Native.fs_realpath(command == "python3" and "/usr/bin/python3" or "/bin/" .. command)
			assert(interpreter, "required Linux interpreter missing")
			-- Cloud overlay system inode values are not exactly representable by
			-- Lua doubles. Copy actual interpreter bytes into this owned tmpfs,
			-- preserving strict native identity admission rather than rounding it.
			local input = assert(io.open(interpreter, "rb"))
			local bytes = input:read("*a"); assert(input:close())
			local target = f.bin .. "/real-" .. command
			f.write(target, bytes, 448); f.interpreters[command] = target
			f.link(target, f.bin .. "/" .. command)
		end
		body(f)
	end, debug.traceback)
	if f.cleanup then f.cleanup() end
	for _, owner in ipairs(owners) do assert(owner.invalidate()) end
	-- Only this invocation's created names are removed, without recursive scans.
	for path in pairs(owned_files) do if Native.fs_lstat(path) then assert(Native.fs_unlink(path)) end end
	for index = #owned_dirs, 1, -1 do assert(Native.fs_rmdir(owned_dirs[index])) end
	assert(Native.fs_rmdir(root))
	if not ok then error(failure) end
end

local function wrapped(overrides)
	local native = {}; for name, port in pairs(Native) do native[name] = port end
	for name, port in pairs(overrides) do native[name] = port end
	return native
end

helpers.describe("Linux native program provider discovery", function()
	helpers.it("uses real sh/python Unicode script receipts and literal existing program scalars", function()
		fixture(function(f)
			f.write(f.scripts .. "/écho.sh", "#!/bin/sh\nexit 37\n")
			f.write(f.scripts .. "/calcul.py", "raise SystemExit(37)\n")
			f.write(f.scripts .. "/native", "#!/bin/sh\nexit 37\n", 448)
			f.directory(f.scripts .. "/nested")
			f.link(f.scripts .. "/écho.sh", f.scripts .. "/linked.sh")
			local owner = f.owner()
			local key, packet = f.key(owner, "écho.sh")
			helpers.assert_eq(#packet.choices, 3)
			local parsed = assert(Parameter.parse(assert(owner.resolve(key, { "", "$(literal)'\"", "e\204\129\n" })), "linux"))
			helpers.assert_eq(parsed.executable, f.interpreters.sh)
			helpers.assert_eq(parsed.arguments, { f.scripts .. "/écho.sh", "", "$(literal)'\"", "e\204\129\n" })
			key = f.key(owner, "calcul.py")
			parsed = assert(Parameter.parse(assert(owner.resolve(key, {})), "linux"))
			helpers.assert_eq(parsed.executable, f.interpreters.python3)
			helpers.assert_eq(parsed.arguments, { f.scripts .. "/calcul.py" })
			helpers.assert_eq(owner.invalidate(), true)
		end)
	end)

	helpers.it("refuses real file and interpreter substitutions after discovery", function()
		fixture(function(f)
			local script = f.scripts .. "/private.sh"
			f.write(script, "exit 37\n")
			local owner = f.owner(); local key = f.key(owner, "private.sh")
			f.write(script, "exit 0\n# changed source\n")
			helpers.assert_eq(owner.resolve(key, {}), nil)
			key = f.key(owner, "private.sh")
			local real = assert(f.interpreters.sh)
			local original = Native.fs_stat
			local changed = wrapped({ fs_stat = function(path)
				local stat = original(path)
				if path == real and stat then stat.ino = stat.ino + 1 end
				return stat
			end })
			local raced = f.owner(changed)
			helpers.assert_eq(assert(raced.discover()).providers[1].available, false)
			-- The successful owner's original scalar is independent of a new
			-- adapter's refused candidate, and still must validate its own file.
			helpers.assert_eq(type(owner.resolve(key, {})), "string")
			assert(Native.fs_unlink(f.bin .. "/sh"))
			assert(Native.fs_symlink(f.interpreters.bash, f.bin .. "/sh"))
			-- Both real targets remain executable and unchanged; the exact PATH
			-- selection changed, so an old picker key must refuse confirmation.
			helpers.assert_eq(owner.resolve(key, {}), nil)
			helpers.assert_eq(owner.invalidate(), true); helpers.assert_eq(raced.invalidate(), true)
		end)
	end)

	helpers.it("treats absent scripts neutrally without creating them and refuses symlink roots", function()
		fixture(function(f)
			local owner = f.owner()
			assert(Native.fs_rmdir(f.scripts))
			local packet = assert(owner.discover())
			helpers.assert_eq(#packet.choices, 0); helpers.assert_eq(Native.fs_lstat(f.scripts), nil)
			assert(Native.fs_mkdir(f.scripts, 448))
			assert(Native.fs_rmdir(f.scripts))
			assert(Native.fs_symlink(f.bin, f.scripts))
			helpers.assert_eq(owner.discover(), nil)
			assert(Native.fs_unlink(f.scripts)); assert(Native.fs_mkdir(f.scripts, 448))
			helpers.assert_eq(owner.invalidate(), true)
		end)
	end)

	helpers.it("bounds real directory traversal and acknowledges physical directory closure", function()
		fixture(function(f)
			for index = 1, Shared.MAX_SCAN + 1 do f.write(f.scripts .. "/" .. string.format("%03d.sh", index), "exit 37\n") end
			local pulls, opens, closes = 0, 0, 0
			local native = wrapped({
				fs_opendir = function(...) opens = opens + 1; return Native.fs_opendir(...) end,
				fs_readdir = function(...) pulls = pulls + 1; return Native.fs_readdir(...) end,
				fs_closedir = function(...) closes = closes + 1; return Native.fs_closedir(...) end,
			})
			local owner = f.owner(native)
			local packet = assert(owner.discover())
			helpers.assert_eq(packet.truncated, true); helpers.assert_eq(#packet.choices, Shared.MAX_CHOICES)
			helpers.assert_eq(pulls, Shared.MAX_SCAN + 1); helpers.assert_eq(opens, 1); helpers.assert_eq(closes, 1)
			helpers.assert_eq(owner.invalidate(), true); helpers.assert_eq(closes, 1)
		end)
	end)

	helpers.it("retains exact real directory capabilities across refused and throwing close until retry", function()
		fixture(function(f)
			f.write(f.scripts .. "/private.sh", "exit 37\n")
			local pending, opens, closes, mode = nil, 0, 0, "false"
			local native = wrapped({
				fs_opendir = function(...)
					helpers.assert_eq(pending, nil)
					opens = opens + 1; pending = assert(Native.fs_opendir(...)); return pending
				end,
				fs_closedir = function(handle)
					helpers.assert_eq(handle, pending); closes = closes + 1
					if mode == "false" then return false end
					if mode == "throw" then error("private close refusal") end
					local result = Native.fs_closedir(handle); if result == true then pending = nil end; return result
				end,
			})
			local owner = f.owner(native)
			f.cleanup = function() mode = "accepted"; assert(owner.invalidate()) end
			helpers.assert_eq(owner.discover(), nil); helpers.assert_eq(opens, 1)
			helpers.assert_eq(owner.invalidate(), false)
			mode = "throw"; helpers.assert_eq(owner.invalidate(), false)
			helpers.assert_eq(owner.discover(), nil); helpers.assert_eq(opens, 1)
			mode = "accepted"; helpers.assert_eq(owner.invalidate(), true)
			helpers.assert_eq(pending, nil); helpers.assert_eq(closes, 5)
			helpers.assert_eq(#assert(owner.discover()).choices, 1); helpers.assert_eq(opens, 2)
			helpers.assert_eq(owner.invalidate(), true)
		end)
	end)

	helpers.it("contains constructor catalogue read/close refusal without losing the acquired descriptor", function()
		local module = adapter()
		local mode, descriptor, opens, closes, reads = "false", nil, 0, 0, 0
		local native = wrapped({
			fs_open = function(path, flags)
				helpers.assert_eq(flags, 2048); helpers.assert_eq(descriptor, nil)
				opens = opens + 1; descriptor = assert(Native.fs_open(path, flags, 0)); return descriptor
			end,
			fs_read = function(fd, size, offset)
				helpers.assert_eq(fd, descriptor); helpers.assert_eq(size, Shared.MAX_CATALOGUE_BYTES + 1)
				reads = reads + 1; return Native.fs_read(fd, size, offset)
			end,
			fs_close = function(fd)
				helpers.assert_eq(fd, descriptor); closes = closes + 1
				if mode == "false" then return false end
				if mode == "throw" then error("private read descriptor close refusal") end
				local result = Native.fs_close(fd); if result == true then descriptor = nil end; return result
			end,
		})
		local ok, failure = xpcall(function()
			helpers.assert_eq(module.create({ native = native }), nil)
			helpers.assert_eq(opens, 1); helpers.assert_eq(reads, 1)
			local owner, reason = module.create({ native = native })
			helpers.assert_eq(owner, nil); helpers.assert_eq(reason, "reader_refused")
			mode = "throw"; helpers.assert_eq(module.create({ native = native }), nil)
			helpers.assert_eq(opens, 1)
			mode = "accepted"; owner = assert(module.create({ native = native }))
			helpers.assert_eq(opens, 2); helpers.assert_eq(reads, 2)
			helpers.assert_eq(closes, 5); helpers.assert_eq(descriptor, nil)
			helpers.assert_eq(owner.invalidate(), true)
		end, debug.traceback)
		mode = "accepted"
		-- Retry through the same module lease before releasing the test dependency.
		local cleanup = assert(module.create({ native = native, catalogue = RAW }))
		assert(cleanup.invalidate())
		if not ok then error(failure) end
	end)

	helpers.it("ignores relative PATH entries and reports unknown candidates as unavailable", function()
		fixture(function(f)
			f.write(f.scripts .. "/private.sh", "exit 37\n")
			local owner = f.owner(nil, ".:relative:")
			helpers.assert_eq(#assert(owner.discover()).choices, 0)
			local refused = wrapped({ fs_lstat = function(path)
				if path:sub(1, #f.bin + 1) == f.bin .. "/" then return nil, "private native refusal", "EACCES" end
				return Native.fs_lstat(path)
			end })
			owner = f.owner(refused)
			local packet = assert(owner.discover())
			helpers.assert_eq(packet.providers[1].available, false); helpers.assert_eq(#packet.choices, 0)
			helpers.assert_eq(owner.invalidate(), true)
		end)
	end)
end)
