--- tests/meta/test_lazy_require_targets_exist.lua

--- ==============================================================================
--- MODULE: Meta — every lazily required module and method must exist
--- DESCRIPTION:
--- Four gesture actions (open_metrics_typing, open_metrics_apps,
--- open_hotstrings_editor, open_paths_editor) and two menu entries were dead: they
--- required "ui.metrics_overlay", "ui.hotstrings_editor" and "ui.paths_editor",
--- none of which have ever existed, or called a toggle() the target module does
--- not export. The user picked the action, nothing happened, and nothing was
--- logged.
---
--- ROOT CAUSE ENCODED:
--- The idiom `pcall(function() require("mod").method() end)` and its sibling
--- `local ok, m = pcall(require, "mod"); if ok and type(m.method) == "function"`
--- collapse three distinct failures — module absent, method absent, method raised
--- — into one indistinguishable silent no-op. A module rename therefore breaks
--- callers invisibly: nothing throws, nothing logs, the gesture simply does
--- nothing forever.
---
--- WHY A SOURCE SCAN:
--- Behavioural coverage would need every UI module loadable under the harness,
--- which pulls in WebViews and Accessibility. What is both decidable and
--- sufficient is static: the module named must resolve on package.path, and the
--- method named must be exported by it. Both were false at six call sites.
---
--- This is a CLASS guard, not a site guard: it scans the whole driver tree, so a
--- future rename that orphans any lazy require fails CI at the rename.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Driver subtrees to scan, matching the sibling meta guards.
local SOURCE_DIRS = { "adapters", "lib", "modules", "ui" }

-- package.path roots the driver injects at boot (init.lua:14-28), in search
-- order. "../_shared/lua" is the module root shared with the Windows and Linux
-- drivers, so a shared module resolves from the macOS tree too.
local REQUIRE_ROOTS = { "", "modules/", "lib/", "ui/", "adapters/", "../_shared/lua/" }

-- Provided by the Hammerspoon runtime rather than this repository, so their
-- absence from the tree is expected and must not fail the scan.
local RUNTIME_MODULES = { socket = true, hs = true }





-- ==========================================
-- ==========================================
-- ======= 1/ Walking The Driver Tree =======
-- ==========================================
-- ==========================================

--- Lists every driver .lua file under the given subtree.
--- @param dir string Absolute directory.
--- @param out table Accumulator.
local function collect(dir, out)
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then walk(full)
					elseif entry:match("%.lua$") then out[#out + 1] = full end
				end
			end
		end
		walk(dir)
		return
	end
	local cmd = (package.config:sub(1, 1) == "\\")
		and ('cmd /c dir /b /s /a-d "' .. dir:gsub("/", "\\") .. '\\*.lua"')
		or ("find '" .. dir .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return end
	for line in pipe:lines() do
		local t = line:gsub("%s+$", ""):gsub("\\", "/")
		if t:match("%.lua$") then out[#out + 1] = t end
	end
	pipe:close()
end

--- Reads a file whole, returning nil when it cannot be opened.
--- @param path string Absolute path.
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	return src
end

--- Resolves a Lua module name to a file inside the driver tree.
--- @param root string Driver root, with a trailing slash.
--- @param mod string Dotted module name.
--- @return string|nil Absolute path, or nil when the name resolves nowhere.
local function resolve_module(root, mod)
	if RUNTIME_MODULES[mod] or mod:match("^hs%.") then return mod end
	local rel = mod:gsub("%.", "/")
	for _, base in ipairs(REQUIRE_ROOTS) do
		for _, candidate in ipairs({ root .. base .. rel .. ".lua", root .. base .. rel .. "/init.lua" }) do
			local fh = io.open(candidate, "r")
			if fh then fh:close() ; return candidate end
		end
	end
	return nil
end

--- Collects the names a module exports on its M table.
--- @param path string Absolute module path.
--- @return table<string, boolean> Set of exported names.
local function exports_of(path)
	local set = {}
	local src = read_file(path)
	if not src then return set end
	for name in src:gmatch("function%s+M[%.:]([%w_]+)") do set[name] = true end
	for name in src:gmatch("M%.([%w_]+)%s*=") do set[name] = true end
	return set
end





-- ===============================================
-- ===============================================
-- ======= 2/ Every Lazy Require Must Land =======
-- ===============================================
-- ===============================================

helpers.describe("lazily required modules and methods exist", function()
	--- Gathers the driver source files once per test case.
	--- @return string, table Root with trailing slash, list of absolute paths.
	local function driver_sources()
		local root, files = helpers.driver_root(), {}
		for _, d in ipairs(SOURCE_DIRS) do collect(root .. d, files) end
		return root, files
	end

	helpers.it("resolves every require() target to a file on package.path", function()
		local root, files = driver_sources()
		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		local unresolved = {}
		local seen_requires = 0
		for _, path in ipairs(files) do
			local src = read_file(path)
			if src then
				local rel = path:sub(#root + 1)
				for mod in src:gmatch('require%s*%(%s*"([%w_.]+)"') do
					seen_requires = seen_requires + 1
					if not resolve_module(root, mod) then
						unresolved[#unresolved + 1] = rel .. " -> " .. mod
					end
				end
				for mod in src:gmatch('pcall%s*%(%s*require%s*,%s*"([%w_.]+)"') do
					if not resolve_module(root, mod) then
						unresolved[#unresolved + 1] = rel .. " -> " .. mod
					end
				end
			end
		end

		-- This check passes on an empty result, so a pattern that stops matching
		-- retires it instead of failing it. The driver has hundreds of requires;
		-- finding none means the scan is broken, not that the code is.
		helpers.assert_true(seen_requires > 100,
			"the require() scan matched only " .. seen_requires .. " call(s) across the driver — "
			.. "the pattern no longer finds them, so an empty unresolved list proves nothing")

		helpers.assert_true(#unresolved == 0, string.format(
			"%d require() target(s) resolve to no file on package.path: %s. "
			.. "Every one is a permanently dead branch — pcall(require, …) returns "
			.. "false forever, so the guarded call is a silent no-op that never logs",
			#unresolved, table.concat(unresolved, ", ")))
	end)

	helpers.it("only type-guards methods the target module actually exports", function()
		local root, files = driver_sources()
		local missing = {}
		local seen_sites = 0
		for _, path in ipairs(files) do
			local src = read_file(path)
			if src then
				local rel = path:sub(#root + 1)
				-- Walk each `local ok, VAR = pcall(require, "MOD")` and inspect only
				-- the text up to the point VAR is re-bound (by any assignment form,
				-- not just another pcall-require). lib/ui_restore.lua is why: its
				-- list entries all name their module `m`, and the next entry rebinds
				-- it via `local m = package.loaded[…]`. A window bounded only by the
				-- next pcall-require swallows that entry's own guard and blames it on
				-- the previous module — a false positive that would have this test
				-- demand a "fix" to correct code.
				local sites = {}
				for pos, var, mod in src:gmatch('()([%w_]+)%s*=%s*pcall%s*%(%s*require%s*,%s*"([%w_.]+)"%s*%)') do
					sites[#sites + 1] = { pos = pos, var = var, mod = mod }
					seen_sites = seen_sites + 1
				end
				for i, site in ipairs(sites) do
					local stop = sites[i + 1] and (sites[i + 1].pos - 1) or #src
					-- Cut the window short if VAR is reassigned before that.
					local rebind = src:find("%f[%w_]" .. site.var .. "%s*=", site.pos + #site.var)
					if rebind and rebind - 1 < stop then stop = rebind - 1 end
					local window = src:sub(site.pos, stop)
					local target = resolve_module(root, site.mod)
					if target and not RUNTIME_MODULES[site.mod] then
						local ex = exports_of(target)
						-- Only assert when the module exposes an M table at all;
						-- table-literal modules are outside this pattern's scope.
						if next(ex) then
							local pat = 'type%s*%(%s*' .. site.var .. '%.([%w_]+)%s*%)%s*==%s*"function"'
							for meth in window:gmatch(pat) do
								if not ex[meth] then
									missing[#missing + 1] = rel .. " -> " .. site.mod .. "." .. meth
								end
							end
						end
					end
				end
			end
		end

		-- Same floor as above: an empty `missing` must mean the guards are correct,
		-- not that the pcall-require pattern found no call sites to check.
		helpers.assert_true(seen_sites > 10,
			"the pcall(require, …) scan matched only " .. seen_sites .. " site(s) — the pattern "
			.. "no longer finds them, so an empty result proves nothing")

		helpers.assert_true(#missing == 0, string.format(
			"%d guarded call(s) name a method the module does not export: %s. "
			.. "The type() guard is false forever, so the branch never runs and the "
			.. "action is a silent no-op — the exact shape that left the metrics "
			.. "overlays unopenable from both the menu and a gesture",
			#missing, table.concat(missing, ", ")))
	end)
end)
