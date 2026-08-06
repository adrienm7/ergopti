--- tests/unit/infra/test_paths_shared_root_layouts.lua

--- ==============================================================================
--- MODULE: The Resolver Finds The Shared Tree In Both Shipped Layouts
--- DESCRIPTION:
--- infra/paths.lua answers exactly one question — where is `_shared`? — and
--- every locale, keycode table, hotstring pack, tooltip config and defaults file
--- the driver reads is built on that answer. This pins it against BOTH layouts
--- that actually ship.
---
--- THE DEFECT THIS PINS:
--- The resolver probed a single candidate, `<driver root>/../_shared`, the
--- SIBLING. That is correct in the checkout (static/ergopti_plus/{linux,_shared})
--- and correct in the release tarball, which unpacks `linux/` and `_shared/`
--- side by side — so every developer, every CI run and the entire test suite
--- agreed it worked.
---
--- The system packages do not use that layout and cannot. build-linux-deb.sh,
--- build-linux-rpm.sh and PKGBUILD each stage the driver flat into
--- /usr/lib/ergopti and nest the shared tree INSIDE it, because a sibling would
--- land at /usr/lib/_shared — a directory no package may own. On an installed
--- .deb the probe therefore addressed /usr/lib/_shared/data/locales/en.json,
--- shared_root() returned nil, and every Paths.shared(…) call went nil with it.
---
--- WHY IT WAS INVISIBLE:
--- The wrapper exports LUA_PATH, so `require` kept resolving and the daemon
--- started normally. Only the DATA reads failed, and a nil path does not raise:
--- it flows into io.open, comes back nil, and lands in a fallback that reads
--- like a deliberate one. A broken install looked like a working install.
---
--- WHY THE FIXTURES ARE REAL DIRECTORIES:
--- The resolver locates itself with debug.getinfo on its own file and then opens
--- a real file to decide. Stubbing io.open would test the stub's idea of the
--- layout — which is precisely the assumption that was wrong. So each case
--- copies the real infra/paths.lua into a throwaway root, exactly as an
--- installed package relocates it, writes the file the probe looks for, and
--- loads that copy. The copy is also the seam: a freshly loaded chunk carries
--- its own memo cell, so the module needs no production reset hook.
--- ==============================================================================

local helpers = require("tests.helpers")

local ok_lfs, lfs = pcall(require, "lfs")

-- The one file a candidate directory must carry to BE the shared tree. It
-- mirrors SHARED_PROBE_FILE in infra/paths.lua; a fixture carrying anything else
-- would prove nothing about what the resolver actually looks for.
local PROBE_REL = "data/locales/en.json"

-- Fixtures live under the system temp directory, inside a per-run directory: a
-- leftover from a crashed run and a concurrent run must not share a tree, or one
-- run's cleanup silently deletes the other's fixture mid-probe.
local TMP_BASE = (os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp")
	:gsub("\\", "/"):gsub("/$", "")
local FIXTURE_BASE = TMP_BASE .. "/ergopti_paths_layouts_" .. os.time()
	.. "_" .. (tostring({}):gsub("%W", ""))





-- ============================================
-- ============================================
-- ======= 1/ Building a layout on disk =======
-- ============================================
-- ============================================

--- Creates one directory level, tolerating "already exists".
--- The result is deliberately not inspected: every fixture proves its
--- directories by writing a file into them and asserting the handle, which is
--- the only evidence that survives an lfs-less runner and a quiet mkdir.
--- @param dir string Absolute path, forward slashes.
local function mkdir_one(dir)
	if ok_lfs and lfs and lfs.mkdir then
		lfs.mkdir(dir)
		return
	end
	if package.config:sub(1, 1) == "\\" then
		os.execute(string.format("cmd /c md \"%s\" 2>nul", (dir:gsub("/", "\\"))))
	else
		os.execute(string.format("mkdir -p '%s'", dir))
	end
end

--- Creates a chain of directory levels under an already existing base.
--- Only the levels the fixture itself owns are created, so this never walks an
--- absolute path it did not build.
--- @param base string Existing directory, forward slashes, no trailing slash.
--- @param ... string Level names, outermost first.
--- @return string The deepest directory created.
local function mkdir_chain(base, ...)
	local current = base
	mkdir_one(current)
	for i = 1, select("#", ...) do
		current = current .. "/" .. (select(i, ...))
		mkdir_one(current)
	end
	return current
end

--- Copies a file byte-for-byte.
--- @param src string Source path.
--- @param dst string Destination path.
--- @return boolean True when a non-empty copy was written.
local function copy_file(src, dst)
	local fin = io.open(src, "rb")
	if not fin then return false end
	local data = fin:read("*a")
	fin:close()
	if not data or #data == 0 then return false end
	local fout = io.open(dst, "wb")
	if not fout then return false end
	fout:write(data)
	fout:close()
	return true
end

--- Writes the file the resolver probes for into a shared-tree fixture.
--- @param shared_dir string Absolute path of the fixture's _shared directory.
--- @return boolean True when the file was created.
local function write_probe(shared_dir)
	mkdir_chain(shared_dir, "data", "locales")
	local fh = io.open(shared_dir .. "/" .. PROBE_REL, "w")
	if not fh then return false end
	-- The contents are irrelevant: the probe only asks whether the file opens.
	fh:write([[{"probe.only": "layout fixture"}]])
	fh:close()
	return true
end

--- Absolute path of the real infra/paths.lua, asked of Lua rather than written
--- down: deriving it from the loaded function keeps this test attached to the
--- resolver across a `git mv` instead of breaking on a stale string.
--- @return string Absolute path with forward slashes.
local function resolver_source()
	local Paths = helpers.load_module("infra.paths")
	local src = debug.getinfo(Paths.shared_root, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	return (src:gsub("\\", "/"))
end

--- Stages a throwaway driver root holding a copy of the real resolver, plus
--- whichever shared trees the requested layout calls for, and loads that copy.
--- @param case string Fixture sub-directory; each case owns its own tree.
--- @param layout string|nil "sibling", "child", "both", or nil to stage no tree.
--- @return table resolver The loaded module, with its own memo cell.
--- @return string root Absolute path of the staged driver root.
--- @return table staged Absolute paths of the staged shared trees.
local function stage(case, layout)
	local base = FIXTURE_BASE .. "/" .. case
	local root = base .. "/ergopti"
	mkdir_chain(FIXTURE_BASE, case, "ergopti", "infra")

	if not copy_file(resolver_source(), root .. "/infra/paths.lua") then
		error("could not stage a copy of infra/paths.lua under " .. root, 0)
	end

	local staged = {}
	if layout == "sibling" or layout == "both" then staged[#staged + 1] = base .. "/_shared" end
	if layout == "child" or layout == "both" then staged[#staged + 1] = root .. "/_shared" end
	for _, dir in ipairs(staged) do
		if not write_probe(dir) then
			error("could not write " .. PROBE_REL .. " under " .. dir, 0)
		end
	end

	local chunk, err = loadfile(root .. "/infra/paths.lua")
	if not chunk then error("could not load the staged resolver — " .. tostring(err), 0) end
	return chunk(), root, staged
end

--- Removes one EMPTY directory.
--- os.remove unlinks an empty directory on POSIX but refuses directories
--- outright on Windows, where a run would otherwise leave the whole fixture
--- skeleton behind every time. Best-effort either way: a leftover directory is
--- noise, never a wrong result, because every run builds its own base.
--- @param dir string Absolute path, forward slashes.
local function rmdir_one(dir)
	if os.remove(dir) then return end
	if ok_lfs and lfs and lfs.rmdir then
		lfs.rmdir(dir)
		return
	end
	if package.config:sub(1, 1) == "\\" then
		os.execute(string.format("cmd /c rd \"%s\" 2>nul", (dir:gsub("/", "\\"))))
	end
end

--- Removes a fixture, deepest path first.
--- @param root string Driver root returned by stage().
--- @param staged table Shared trees returned by stage().
local function unstage(root, staged)
	for _, dir in ipairs(staged) do
		os.remove(dir .. "/" .. PROBE_REL)
		rmdir_one(dir .. "/data/locales")
		rmdir_one(dir .. "/data")
		rmdir_one(dir)
	end
	os.remove(root .. "/infra/paths.lua")
	rmdir_one(root .. "/infra")
	rmdir_one(root)
	rmdir_one(root:match("^(.*)/[^/]+$") or root)
end





-- ===============================================
-- ===============================================
-- ======= 2/ Both shipped layouts resolve =======
-- ===============================================
-- ===============================================

helpers.describe("infra.paths: shared_root resolves both shipped layouts", function()

	helpers.it("finds the tree beside the driver — the checkout and the tarball", function()
		local Paths, root, staged = stage("checkout", "sibling")
		local resolved  = Paths.shared_root()
		local reachable = Paths.shared(PROBE_REL)
		local fh = reachable and io.open(reachable, "r")
		if fh then fh:close() end
		unstage(root, staged)

		helpers.assert_eq(resolved, root .. "/../_shared",
			"the sibling layout is what the checkout, the whole test suite and the "
				.. "release tarball run against — teaching the resolver the packaged "
				.. "layout must not cost it the common one")
		helpers.assert_true(fh ~= nil,
			"a root that does not open the file it was probed for is the failure the "
				.. "probe exists to prevent: every read downstream comes back nil")
	end)

	helpers.it("finds the tree inside the driver — the .deb, .rpm and PKGBUILD layout", function()
		local Paths, root, staged = stage("installed", "child")
		local resolved  = Paths.shared_root()
		local reachable = Paths.shared(PROBE_REL)
		local fh = reachable and io.open(reachable, "r")
		if fh then fh:close() end
		unstage(root, staged)

		helpers.assert_eq(resolved, root .. "/_shared",
			"the packagers stage the driver flat into /usr/lib/ergopti and nest the "
				.. "shared tree inside it, so a sibling-only probe addressed "
				.. "/usr/lib/_shared/data/locales/en.json, found nothing, and handed "
				.. "nil to every module asking for a locale, a keycode table, a "
				.. "hotstring pack or a defaults file")
		helpers.assert_true(fh ~= nil,
			"an installed package could not open one shared data file, and the "
				.. "wrapper's LUA_PATH hid the breadth of it — require kept resolving, "
				.. "so the daemon started and only the data was gone")
	end)

	helpers.it("prefers the sibling when a tree sits in both places", function()
		local Paths, root, staged = stage("ambiguous", "both")
		local resolved = Paths.shared_root()
		unstage(root, staged)

		helpers.assert_eq(resolved, root .. "/../_shared",
			"a stale nested copy left by an interrupted build must not quietly take "
				.. "precedence over the tree the driver was built against; the order "
				.. "is documented in shared_root(), so it is pinned here")
	end)

end)





-- ==========================================
-- ==========================================
-- ======= 3/ A miss names both paths =======
-- ==========================================
-- ==========================================

helpers.describe("infra.paths: an unresolvable tree is named, not guessed", function()

	helpers.it("returns nil and reports both candidates when neither carries the tree", function()
		local logger = require("logger.shim")
		local original = logger.error
		local messages = {}
		logger.error = function(_tag, fmt, ...)
			local ok, line = pcall(string.format, fmt, ...)
			messages[#messages + 1] = ok and line or tostring(fmt)
		end

		local Paths, root, staged = stage("empty", nil)
		local resolved = Paths.shared_root()
		logger.error = original
		unstage(root, staged)

		helpers.assert_nil(resolved,
			"inventing a root turns every missing file into a silent fallback — how "
				.. "the language menu came to offer 2 locales out of the 21 that ship")
		helpers.assert_eq(#messages, 1,
			"a broken install must be reported, and reported once")
		helpers.assert_contains(messages[1] or "", root .. "/../_shared",
			"a message naming one candidate answers half the reader's question, "
				.. "because the other half is which layout was assumed")
		helpers.assert_contains(messages[1] or "", root .. "/_shared",
			"the nested candidate is the one a packager needs to see, and it is "
				.. "exactly the one the message never mentioned")
	end)

end)





-- ============================================
-- ============================================
-- ======= 4/ The root is resolved once =======
-- ============================================
-- ============================================

helpers.describe("infra.paths: the resolved root is memoised", function()

	helpers.it("resolves once and keeps the answer", function()
		local Paths, root, staged = stage("memoised", "sibling")
		local first = Paths.shared_root()
		-- Delete the file the resolver just probed: a second call that re-probes
		-- now matches neither candidate, so an equal answer proves the memo cell
		-- rather than a lucky repeat of the same work.
		os.remove(staged[1] .. "/" .. PROBE_REL)
		local second = Paths.shared_root()
		unstage(root, staged)

		helpers.assert_not_nil(first,
			"the fixture has to resolve before anything can be said about caching it")
		helpers.assert_eq(second, first,
			"shared_root() sits under nearly every read in the driver; dropping the "
				.. "memo would put an io.open in front of each of them")
	end)

end)

-- The per-run base is the one level unstage() leaves behind, and removing it
-- keeps the temp directory from collecting an empty directory per run.
rmdir_one(FIXTURE_BASE)
