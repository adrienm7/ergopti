--- tests/hardware/run_shell_command_nul_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Shell Command Byte Receipts
--- DESCRIPTION:
--- Production system/popen calls cannot carry raw NUL in their implicit sh -c
--- argument. Actual shell prefixes must not execute or alter retained files.
--- Textual stdin facades obey the same boundary, while valid Unicode/newline
--- commands, binary stdout and the existing asynchronous argv guard remain valid.
--- No shell, process, file or native exit API is simulated.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
assert(uv.getuid() ~= 0, "native shell byte checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-shell-command-nul-XXXXXX"))
local target = root .. "/retained"
local retained = "Caller-owned native bytes"
local checks, failures = 0, 0

local function write(bytes)
	local file = assert(io.open(target, "wb"))
	assert(file:write(bytes) and file:close())
end

local function read()
	local file = assert(io.open(target, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local function execute(method, command, input)
	if method == "exec_stdin" or method == "exec_exact_stdin" then return Shell[method](command, input or "valid stdin\n") end
	return Shell[method](command)
end

local function refused(method, value)
	if method == "run" or method == "exec_checked" then assert(value == false, "native command refusal reported success")
	elseif method == "exec_line" then assert(value == nil, "native command refusal returned a prefix line")
	else assert(value == "", "native command refusal returned prefix stdout") end
end

local prefix = "printf '%s' 'Shortened native command executed' > " .. Shell.quote(target)
	.. "; printf '%s' 'Shortened native result'"
for _, method in ipairs({ "run", "exec", "exec_line", "exec_stdin", "exec_exact_stdin", "exec_checked" }) do
	for _, suffix in ipairs({ "\0private-suffix", "\0" }) do
		check(method .. " refuses NUL before its shorter shell prefix can execute", function()
			write(retained)
			local value, output, reason = execute(method, prefix .. suffix)
			assert(read() == retained, "system/popen executed the shorter C-string command and replaced caller bytes")
			refused(method, value)
			if method == "exec_checked" then
				assert(output == "" and type(reason) == "string" and #reason < 200)
				assert(not reason:find("private-suffix", 1, true))
			end
		end)
	end
end

for _, method in ipairs({ "exec_stdin", "exec_exact_stdin" }) do
	check(method .. " refuses NUL in its composed stdin script", function()
		write(retained)
		refused(method, execute(method, "cat > " .. Shell.quote(target), "prefix\0private-suffix"))
		assert(read() == retained, "a truncated heredoc still executed and wrote only the payload prefix")
	end)
end

check("leading NUL cannot turn an invalid run into empty-shell success", function()
	write(retained)
	assert(Shell.run("\0" .. prefix) == false and read() == retained)
end)

for _, method in ipairs({ "run", "exec", "exec_line", "exec_stdin", "exec_exact_stdin", "exec_checked" }) do
	check(method .. " retains actual literal Unicode and newline data", function()
		write(retained)
		local bytes = "Literal native é'漢\nnext\n"
		local command = "printf '%s' " .. Shell.quote(bytes) .. " > " .. Shell.quote(target)
		if method ~= "run" then command = command .. "; cat " .. Shell.quote(target) end
		if method == "exec_stdin" or method == "exec_exact_stdin" then command = "tee " .. Shell.quote(target) end
		local value, output, reason = execute(method, command, bytes)
		assert(read() == bytes)
		if method == "run" then assert(value == true)
		elseif method == "exec_checked" then assert(value == true and output == bytes and reason == nil)
		elseif method == "exec_line" then assert(value == "Literal native é'漢")
		else assert(value == bytes) end
	end)
end

for _, method in ipairs({ "exec", "exec_checked" }) do
	check(method .. " keeps binary stdout distinct from the shell command", function()
		local value, output, reason = Shell[method]("printf 'A\\000B'")
		if method == "exec_checked" then assert(value == true and output == "A\0B" and reason == nil)
		else assert(value == "A\0B") end
	end)
end

check("existing native async argv guard also refuses the composed command", function()
	write(retained)
	local callbacks = 0
	local handle, reason = Shell.run_async("sh", { "-c", prefix .. "\0private-suffix" },
		{ timeout_ms = 1000 }, function() callbacks = callbacks + 1 end)
	assert(handle == nil and callbacks == 0 and type(reason) == "string")
	assert(read() == retained and not reason:find("private-suffix", 1, true))
end)

uv.run()
assert(not uv.loop_alive(), "native shell checks retained process ownership")
assert(uv.fs_unlink(target))
assert(uv.fs_rmdir(root))
print(string.format("Native shell command byte receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
