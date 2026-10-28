--- tests/hardware/run_sqlite_private_no_luv.lua
--- ==============================================================================
--- MODULE: Public SQLite Privacy Without Luv
--- DESCRIPTION:
--- Removes native module search paths in a fresh interpreter. LuaJIT must retain
--- its genuine FFI synchronous backend; stock Lua must refuse without an API.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
package.cpath = ""
assert(package.loaded.luv == nil and not pcall(require, "luv"), "the native luv provider must actually be unavailable")
local Shell = require("adapters.shell_runner")
assert(Shell.run("false") == false, "a real failed shell command must never satisfy fixture setup")
local database = os.tmpname()
local ok, failure = xpcall(function()
	local writer = require("modules.keystats.sqlite_writer")
	local opened, admitted = pcall(writer.open_db, database)
	assert(opened, "missing descriptor APIs must refuse explicitly rather than throw during import: "
		.. require("error_description").describe(admitted))
	if rawget(_G, "jit") then
		assert(admitted == true and writer.is_available(), "the public synchronous FFI writer must remain available")
		assert(writer.exec_sql("CREATE TABLE private_no_luv_fixture(value); INSERT INTO private_no_luv_fixture VALUES ('retained');"))
		assert(writer.query_rows("SELECT value FROM private_no_luv_fixture;")[1] == "retained")
		assert(writer.flush_transport_available() == false, "synchronous admission cannot fabricate an async transport")
		local quote = require("text_utils").shell_quote
		assert(Shell.run("chmod 644 -- " .. quote(database)))
		assert(require("infra.private_sqlite_file").admit(database))
		local pipe = assert(io.popen("stat -c %a -- " .. quote(database), "r"))
		assert(pipe:read("*a") == "600\n" and pipe:close())
		assert(writer.query_rows("SELECT value FROM private_no_luv_fixture;")[1] == "retained")
		writer.close_db()
		local alias = database .. ".alias"
		assert(Shell.run("ln -s -- " .. quote(database) .. " " .. quote(alias)))
		assert(writer.open_db(alias) and writer.query_rows("SELECT value FROM private_no_luv_fixture;")[1] == "retained")
		writer.close_db()
		assert(os.remove(alias))
		assert(Shell.run("chmod 400 -- " .. quote(database)))
		assert(require("infra.private_sqlite_file").admit(database) == false, "FFI cannot silently grant write access to a read-only owner")
		assert(Shell.run("chmod 600 -- " .. quote(database)))
	else
		assert(admitted == false and not writer.is_available(), "stock Lua without a descriptor API must not admit plaintext storage")
	end
	writer.close_db()
end, debug.traceback)
os.remove(database)
assert(ok, failure)
print("PASS public SQLite without luv: " .. (rawget(_G, "jit") and "genuine FFI open/query/private repair" or "explicit unavailable-API refusal"))
