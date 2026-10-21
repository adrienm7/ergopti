--- tests/unit/modules/keylogger/storage/test_sqlite_reader_readonly_open.lua

--- ==============================================================================
--- MODULE: sqlite_reader read-only open regression tests
--- DESCRIPTION:
--- The dashboard reader opened db.sqlite with hs.sqlite3.open's default flags,
--- READWRITE|CREATE (Hammerspoon's lsqlite3.c: luaL_optinteger(L, 2,
--- SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)), then asked for query_only.
--- A reader called for an absent database therefore created an empty one, and
--- a dangling link's target, before reading (sqlite-reader-readonly-2026-10-21).
--- It now opens with OPEN_READONLY, so an absent source is a refusal.
--- ==============================================================================

local helpers = require("tests.helpers")

local OPEN_READONLY, OPEN_READWRITE, OPEN_CREATE = 0x1, 0x2, 0x4

--- Models hs.sqlite3 over a set of existing files.
--- @param existing table Set of paths that exist.
--- @return table sqlite3, table state
local function native_sqlite(existing)
	local state = { created = {}, opens = {} }
	local sqlite3 = { OK = 0, OPEN_READONLY = OPEN_READONLY, OPEN_READWRITE = OPEN_READWRITE, OPEN_CREATE = OPEN_CREATE }
	function sqlite3.open(path, flags)
		flags = flags or (OPEN_READWRITE | OPEN_CREATE)
		state.opens[#state.opens + 1] = flags
		if not existing[path] then
			if flags & OPEN_CREATE == 0 then return nil, 14, "unable to open database file" end
			existing[path] = true
			state.created[#state.created + 1] = path
		end
		return {
			exec = function() return 0 end,
			close = function() return 0 end,
			nrows = function() return function() return nil end end,
		}
	end
	return sqlite3, state
end

local function load_reader(existing)
	local sqlite3, state = native_sqlite(existing)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("modules.keylogger.sqlite_reader", { sqlite3 = sqlite3 }), state
end


helpers.describe("sqlite_reader opens the cache read-only (sqlite-reader-readonly-2026-10-21)", function()
	for _, call in ipairs({
		{ "read_manifest", function(reader, path) return reader.read_manifest(path) end },
		{ "read_ngrams", function(reader, path) return reader.read_ngrams(path, "2026-10-01", "2026-10-21") end },
		{ "fingerprint", function(reader, path) return reader.fingerprint(path, "2026-10-21") end },
	}) do
		helpers.it(call[1] .. " never creates an absent database", function()
			local reader, state = load_reader({})
			pcall(call[2], reader, "/Users/test/.cache/ergopti/db.sqlite")
			helpers.assert_eq(#state.created, 0, "a reader must not create the cache it reads")
			for _, flags in ipairs(state.opens) do
				helpers.assert_eq(flags, OPEN_READONLY, "every reader open must be read-only")
			end
		end)
	end

	helpers.it("still reads an existing database", function()
		local reader, state = load_reader({ ["/db.sqlite"] = true })
		local manifest = reader.read_manifest("/db.sqlite")
		helpers.assert_type(manifest, "table")
		helpers.assert_true(#state.opens >= 1)
		helpers.assert_eq(#state.created, 0)
	end)
end)
