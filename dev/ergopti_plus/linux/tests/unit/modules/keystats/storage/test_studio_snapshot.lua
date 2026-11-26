--- tests/unit/modules/keystats/storage/test_studio_snapshot.lua

--- ==============================================================================
--- MODULE: Ergopti Studio Saved Read File Tests (Linux)
--- DESCRIPTION:
--- The saved « My typing » read on a real folder: it is written atomically and
--- private (0600) under the process's ordinary umask, as metrics.sqlite is,
--- read back with its absence told apart, and retired by the dashboard's
--- metrics purge and cache reset.
--- ==============================================================================

local helpers = require("tests.helpers")
local StudioNgrams = require("metrics.engine.view.studio_ngrams")

--- The permission bits of a path, from stat(1).
--- @param path string
--- @return string|nil mode Octal digits.
local function mode_of(path)
	local probe = io.popen("stat -c %a '" .. path .. "' 2>/dev/null")
	local mode = probe and probe:read("*l") or nil
	if probe then probe:close() end
	return mode
end

helpers.describe("Ergopti Studio saved read file (Linux)", function()
	helpers.it("writes the saved read atomically and private like the store (studio-saved-read-private)", function()
		local Snapshot = helpers.fresh_module("modules.keystats.studio_snapshot")
		local dir = os.tmpname()
		os.remove(dir)
		helpers.assert_true(os.execute("mkdir -m 755 '" .. dir .. "'") ~= false)
		local ok, err = pcall(function()
			local store = dir .. "/metrics.sqlite"
			local path = StudioNgrams.snapshot_path(store)
			helpers.assert_eq(select(2, Snapshot.read(path)), "absent", "no saved read yet")
			-- A file left by another writer with the umask's mode is replaced, not reused.
			local loose = assert(io.open(path, "wb"))
			loose:write("old")
			loose:close()
			os.execute("chmod 644 '" .. path .. "'")
			local text = StudioNgrams.encode_snapshot("42", StudioNgrams.project({ c = { e = { c = 3 } } }))
			helpers.assert_true(Snapshot.write(path, text), "the read is saved")
			helpers.assert_eq(mode_of(path), "600", "only the recording account reads the saved counts")
			local content, status = Snapshot.read(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(content, text)
			helpers.assert_nil(io.open(path .. ".tmp", "rb"), "no staging file is left")
			helpers.assert_eq(StudioNgrams.decode_snapshot(content).ngrams.chars, { e = 3 })
			helpers.assert_true(Snapshot.retire(store), "the saved read is retired")
			helpers.assert_eq(select(2, Snapshot.read(path)), "absent")
			helpers.assert_true(Snapshot.retire(store), "retiring an absent read succeeds")
		end)
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("the metrics purge and the dashboard reset retire the saved read (studio-saved-read-purge)", function()
		local source = assert(helpers.read_module_source("modules.keystats.keystats"))
		local advance = source:match("function _maintenance%.advance%(%)(.-)\nend\n")
		helpers.assert_true(advance ~= nil, "_maintenance.advance must be found")
		local committed = advance:find("if _last_flush_committed ~= true then return _maintenance.finish(request, false) end", 1, true)
		local retire = advance:find('require("modules.keystats.studio_snapshot").retire(_sqlite_path)', 1, true)
		local done = advance:find("return _maintenance.finish(request, true)", 1, true)
		helpers.assert_true(committed ~= nil and retire ~= nil and done ~= nil and committed < retire and retire < done,
			"a committed purge retires the saved read before it reports success")
		local reset = source:match("function M%.clear_cache%(%)(.-)\nend\n")
		helpers.assert_true(reset ~= nil, "clear_cache must be found")
		helpers.assert_contains(reset, 'require("modules.keystats.studio_snapshot").retire(_sqlite_path)')
		local category = source:match("function M%.set_app_category%(.-\nend\n")
		helpers.assert_true(category ~= nil and not category:find("M.clear_cache()", 1, true),
			"a category edit keeps the Studio's saved read, which holds no category")
	end)
end)
