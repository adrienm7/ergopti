--- infra/extension_packs.lua

--- ==============================================================================
--- MODULE: Extension Pack Discovery (macOS)
--- DESCRIPTION:
--- Supplies the shared extension scanner (_shared/lua/hotstrings/extensions.lua)
--- with this driver's filesystem and roots, then registers the discovered packs
--- through the existing keymap TOML loader. Linux (infra/paths.extension_roots)
--- and Windows (infra/hotstrings/extension_packs.ahk) discover the same roots in
--- the same order.
---
--- FEATURES & RATIONALE:
--- 1. One catalogue per boot: discover() runs once, before the resolver, the
---    loader and the menu read it, so all three describe the same committed
---    extension generation. A second discovery is refused rather than letting
---    a later reader see a different set of packs than the loader registered.
--- 2. Roots in overlay order: the bundled extensions shipped next to _shared,
---    the committed generations of installed layouts, the Ergopti extension the
---    app ships (installed by shipping), then the user's folder, whose copy of
---    an id wins, as the hotstring packs' own overlay rule does.
--- 3. Installing is not enabling: registration never writes a preference. The
---    canonical projection gives every new group and section the manifest's
---    dynamic default, which is off, until the user turns it on.
--- 4. One broken pack never stops the boot: a pack whose manifest, listing or
---    hotstring file cannot be read, a root that cannot be listed and an
---    unreadable installed-layouts record are each logged as an error and left
---    out, so a stray third-party folder costs that pack, not the keymap, the
---    menubar and every bundled hotstring. The scanner itself still refuses a
---    child whose absence it cannot prove, so the log names every lost pack.
--- 5. Bound geometry files are routed at discovery: a layout extension may bind
---    a bundled category, or some of its sections, to its own file. A pack that
---    claims a source another pack already owns is refused and left out, before
---    anything loads, so no reader ever sees two owners.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local Extensions = require("hotstrings.extensions")

local LOG = "extension_packs"

-- The packs discovered at boot and the bundled sources they bind; nil until
-- discover() commits.
local _catalogue = nil
local _routes = nil





-- =================================
-- =================================
-- ======= 1/ Filesystem I/O =======
-- =================================
-- =================================

--- Lists the children of one kind, proving the absence of anything unreadable.
--- A missing directory is an empty listing: no extension installed there.
--- @param path string Directory to inspect.
--- @param kind string Expected attribute mode, "directory" or "file".
--- @return table Sorted absolute paths.
local function children(path, kind)
	local FsDir = require("infra.fs_dir")
	local FileSystem = require("adapters.file_system")
	local ok_root, root_attributes = pcall(hs.fs.attributes, path)
	if not ok_root then error("Extension directory inspection did not commit", 0) end
	if root_attributes == nil then
		local _, status = FileSystem.classify_no_follow(path)
		if status == "absent" then return {} end
		error("Extension directory inspection did not commit", 0)
	end
	if root_attributes.mode ~= "directory" then error("An extension root is not a directory", 0) end
	local names, listed = FsDir.try_entries(path)
	if listed ~= true then error("Extension directory enumeration did not commit", 0) end
	local out = {}
	for _, name in ipairs(names) do
		if name ~= "." and name ~= ".." then
			local full = path:gsub("/+$", "") .. "/" .. name
			-- Followed so a user may link an extension folder into place; only a
			-- proven absence (the entry vanished between listing and stat) skips.
			local ok_child, attributes = pcall(hs.fs.attributes, full)
			if not ok_child then error("Extension child inspection did not commit", 0) end
			if attributes == nil then
				local link, status = FileSystem.classify_no_follow(full)
				if status == "ok" and type(link) == "table" and link.mode == "link" then
					-- A linked pack folder whose target moved or sits on an unmounted
					-- drive: that entry is proven unusable, its siblings are not.
					Logger.error(LOG, "Extension entry '%s' links to a target that no longer exists; it is skipped.", full)
				elseif status ~= "absent" then
					error("Extension child inspection did not commit", 0)
				end
			elseif attributes.mode == kind then
				out[#out + 1] = full
			end
		end
	end
	table.sort(out)
	return out
end

--- Reads one manifest, keeping proven absence distinct from an unreadable file.
--- @param path string Manifest path.
--- @return string|nil Contents, or nil when the pack ships no manifest.
local function read_manifest(path)
	local content, status = require("adapters.file_system").read_with_status(path)
	if status == "absent" then return nil end
	if status ~= "ok" or type(content) ~= "string" then
		error("Extension manifest read did not commit", 0)
	end
	return content
end





-- ============================
-- ============================
-- ======= 2/ Discovery =======
-- ============================
-- ============================

--- Roots in overlay order, the user's copy last so it wins on a repeated id.
--- The Ergopti extension the app ships follows the installed generations: it is
--- installed by shipping (layouts/extension.shipped_root).
--- @return table Absolute extension roots, and the shipped { pack = dir } root.
function M.roots()
	local shared = require("infra.paths").shared_root()
	if not shared then error("The shared extension directory cannot be resolved", 0) end
	local LayoutRegistry = require("modules.keymap.layout_registry")
	local roots = { shared .. "/../extensions" }
	-- The installed-layouts record may have been written by another build or cut
	-- short by a crash or a sync tool. Its layouts' packs are then missing from
	-- this boot, reported, while the bundled and the user's packs still load.
	local ok_installed, installed = pcall(function()
		return LayoutRegistry.extension_roots()
	end)
	if ok_installed then
		for _, root in ipairs(installed) do roots[#roots + 1] = root end
	else
		Logger.error(LOG, "The installed layouts' extensions are skipped this boot: %s.", tostring(installed))
	end
	roots[#roots + 1] = LayoutRegistry.shipped_extension_root()
	roots[#roots + 1] = require("infra.config_paths").get_config_dir() .. "extensions"
	return roots
end

--- This driver's filesystem, as the shared scanner's collaborators.
--- @return table { list_dirs, list_files, read_file }
local function default_io()
	return {
		list_dirs  = function(path) return children(path, "directory") end,
		list_files = function(path) return children(path, "file") end,
		read_file  = read_manifest,
	}
end

--- Discovers packs in canonical precedence order, without changing any state.
--- @param roots table|nil Extension roots; defaults to M.roots().
--- @param io_fns table|nil Scanner collaborators; defaults to this driver's filesystem.
--- @return table Shared extension records.
function M.scan(roots, io_fns)
	return Extensions.scan(roots or M.roots(), io_fns or default_io())
end

--- Resolves every bound file of the given packs through the shared owner, which
--- raises on two owners of one category or section.
--- @param packs table Shared extension records.
local function check_bound_owners(packs)
	for _, pack in ipairs(packs) do
		for _, file in ipairs(pack.bound_files) do
			local binding = file.binding
			if binding.sections == nil then
				Extensions.bound_source(packs, binding.category)
			else
				for _, section in ipairs(binding.sections) do
					Extensions.bound_source(packs, binding.category, section)
				end
			end
		end
	end
end

--- Keeps the packs, in catalogue order, whose bound sources no earlier pack owns.
--- The accepted set never holds two owners, so a conflict always involves the
--- pack under test, and every later reader of the catalogue resolves without one.
--- @param packs table Shared extension records.
--- @param report function Receives ({ id, dir }, err) for each refused pack.
--- @return table Accepted records.
local function accept_bound_owners(packs, report)
	local accepted = {}
	for _, pack in ipairs(packs) do
		local candidate = { pack }
		for _, kept in ipairs(accepted) do candidate[#candidate + 1] = kept end
		local ok, err = pcall(check_bound_owners, candidate)
		if ok then
			accepted[#accepted + 1] = pack
		else
			report({ id = pack.id, dir = pack.dir }, err)
		end
	end
	return accepted
end

--- Routes every bound file through the shared owner, which refuses two owners of
--- one category or section.
--- @param packs table Shared extension records.
--- @return table Map of category to { path, section_sources }.
local function route_bound_files(packs)
	local routes = {}
	for _, pack in ipairs(packs) do
		for _, file in ipairs(pack.bound_files) do
			local binding = file.binding
			local route = routes[binding.category] or {}
			routes[binding.category] = route
			if binding.sections == nil then
				route.path = Extensions.bound_source(packs, binding.category)
			else
				for _, section in ipairs(binding.sections) do
					Extensions.bound_source(packs, binding.category, section)
				end
				route.section_sources = route.section_sources or {}
				route.section_sources[#route.section_sources + 1] = { path = file.path, sections = binding.sections }
			end
		end
	end
	return routes
end

--- Names the root or pack a discovery failure belongs to, for the log.
--- @param where table { root, dir, id, path } as the scanner reports it.
--- @return string
local function describe_failure(where)
	if where.path then return string.format("file '%s' of pack '%s'", where.path, tostring(where.id)) end
	if where.id then return string.format("pack '%s' (%s)", where.id, tostring(where.dir)) end
	if where.root then return string.format("root '%s'", where.root) end
	return "roots"
end

--- Discovers this boot's catalogue once; every later reader gets the same packs.
--- A root, a pack or a bound source that cannot be read or owned is logged and
--- left out; the rest of the catalogue still commits, so the boot goes on.
--- @param roots table|nil Extension roots; defaults to M.roots().
--- @param io_fns table|nil Scanner collaborators; defaults to this driver's filesystem.
--- @return table Shared extension records.
function M.discover(roots, io_fns)
	if _catalogue ~= nil then error("Extension packs were already discovered for this boot", 0) end
	Logger.start(LOG, "Discovering extension packs…")
	local skipped = 0
	local function report(where, err)
		skipped = skipped + 1
		Logger.error(LOG, "Extension %s is left out of this boot: %s.", describe_failure(where), tostring(err))
	end
	local collaborators = {}
	for key, value in pairs(io_fns or default_io()) do collaborators[key] = value end
	collaborators.on_error = report
	local ok, found = pcall(function() return Extensions.scan(roots or M.roots(), collaborators) end)
	if not ok then
		report({}, found)
		found = {}
	end
	local packs = accept_bound_owners(found, report)
	local routes = route_bound_files(packs)
	local files, bound = 0, 0
	for _, pack in ipairs(packs) do
		files = files + #pack.toml_files
		bound = bound + #pack.bound_files
	end
	_catalogue, _routes = packs, routes
	if skipped > 0 then
		Logger.warn(LOG, "Discovered %d extension(s): %d hotstring pack(s), %d bound geometry file(s); %d left out.",
			#packs, files, bound, skipped)
	else
		Logger.success(LOG, "Discovered %d extension(s): %d hotstring pack(s), %d bound geometry file(s).",
			#packs, files, bound)
	end
	return packs
end

--- The catalogue discover() committed.
--- @return table Shared extension records.
function M.catalogue()
	if _catalogue == nil then error("Extension packs were read before discovery", 0) end
	return _catalogue
end

--- The bundled categories this boot's extensions bind to their own files.
--- @return table Map of category to { path, section_sources }: path replaces the
---   bundled file (whole-category binding), section_sources lists { path,
---   sections } records the registry loads over it (section bindings).
function M.routes()
	if _routes == nil then error("Extension routes were read before discovery", 0) end
	return _routes
end

--- The section sources a user's copy of a category leaves to the extensions:
--- the bound sections it does not declare itself. An unreadable copy declares
--- none; the loader then reports that file.
--- @param section_sources table|nil Array of { path, sections }.
--- @param path string The user's copy.
--- @return table|nil
local function sections_left_by(section_sources, path)
	if section_sources == nil then return nil end
	local ok, data, committed = pcall(require("infra.toml.reader").parse, path)
	local declared = (ok and committed == true and type(data) == "table" and type(data.sections) == "table")
		and data.sections or {}
	local left = {}
	for _, source in ipairs(section_sources) do
		local sections = {}
		for _, name in ipairs(source.sections) do
			if declared[name] == nil then sections[#sections + 1] = name end
		end
		if #sections > 0 then left[#left + 1] = { path = source.path, sections = sections } end
	end
	return #left > 0 and left or nil
end

--- Where one bundled category loads from this boot.
---
--- An extension binding replaces the driver's own file of a category, never the
--- user's copy of it: the configured hotstrings folder holds explicit overrides,
--- which keep the whole category, or each bound section they declare themselves.
--- @param category string Runtime category.
--- @param bundled_path string|nil The driver's own file for it, or the user's copy.
--- @param user_copy boolean|nil True when bundled_path is the user's copy.
--- @return string|nil path The file load_toml reads.
--- @return table|nil section_sources The { path, sections } records it merges over it.
function M.route(category, bundled_path, user_copy)
	local route = M.routes()[category]
	if route == nil then return bundled_path, nil end
	if user_copy ~= true or bundled_path == nil then return route.path or bundled_path, route.section_sources end
	if route.path then
		Logger.info(LOG, "The user's copy of '%s' overrides the file an extension binds.", category)
	end
	return bundled_path, sections_left_by(route.section_sources, bundled_path)
end

--- The bound categories no bundled file carries, in a stable order.
--- A whole binding is the category's only file, so it still loads. Sections
--- bound into a category this driver does not carry have no metadata to join:
--- their entry has no path and the caller reports them instead of guessing one.
--- @param carried table Set of the categories the driver loaded from its own files.
--- @return table Array of { category, path, section_sources }.
function M.unbundled_routes(carried)
	local routes = M.routes()
	local names = {}
	for category in pairs(routes) do
		if not carried[category] then names[#names + 1] = category end
	end
	table.sort(names)
	local out = {}
	for _, category in ipairs(names) do
		local route = routes[category]
		out[#out + 1] = { category = category, path = route.path, section_sources = route.section_sources }
	end
	return out
end

--- The file that supplies a namespaced pack or a bound historical source.
--- @param category string Runtime category.
--- @param section string|nil Section name, or nil for the category itself.
--- @return string|nil Bound path; nil when the bundled source applies.
function M.source(category, section)
	return Extensions.bound_source(M.catalogue(), category, section)
end





-- ===============================
-- ===============================
-- ======= 3/ Registration =======
-- ===============================
-- ===============================

--- Registers every namespaced pack with the existing loader, activating none.
--- A file the loader refuses (a TOML error in a pack that is off by default) is
--- logged and dropped from its pack's toml_files, so the catalogue the menu reads
--- offers only groups the keymap holds and the boot goes on without it.
--- @param packs table Shared extension records.
--- @param keymap table Keymap owner exposing load_toml(name, path).
--- @return table Registered { name, path, extension } entries in load order.
function M.load(packs, keymap)
	local loaded = {}
	for _, extension in ipairs(packs) do
		local registered = {}
		for _, file in ipairs(extension.toml_files) do
			local category = Extensions.category_key(extension.id, file.stem)
			local ok, committed = pcall(keymap.load_toml, category, file.path)
			if ok and committed == true then
				registered[#registered + 1] = file
				loaded[#loaded + 1] = { name = category, path = file.path, extension = extension.id }
			else
				Logger.error(LOG, "Extension hotstring file '%s' could not be registered and is left out: %s.",
					category, ok and file.path or tostring(committed))
			end
		end
		extension.toml_files = registered
	end
	Logger.debug(LOG, "Registered %d extension hotstring pack(s).", #loaded)
	return loaded
end

--- Test seam: forgets the boot catalogue.
function M._reset()
	_catalogue, _routes = nil, nil
end

return M
