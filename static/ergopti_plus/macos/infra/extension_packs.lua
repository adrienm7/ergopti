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
---    the committed generations of installed layouts, then the user's folder,
---    whose copy of an id wins, as the hotstring packs' own overlay rule does.
--- 3. Installing is not enabling: registration never writes a preference. The
---    canonical projection gives every new group and section the manifest's
---    dynamic default, which is off, until the user turns it on.
--- 4. Partial discovery is refused: a directory that cannot be listed or a
---    child whose absence cannot be proven raises instead of publishing a
---    catalogue that silently lost an installed pack.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local Extensions = require("hotstrings.extensions")

local LOG = "extension_packs"

-- The packs discovered at boot; nil until discover() commits.
local _catalogue = nil





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
				local _, status = FileSystem.classify_no_follow(full)
				if status ~= "absent" then error("Extension child inspection did not commit", 0) end
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
--- @return table Absolute extension roots.
function M.roots()
	local shared = require("infra.paths").shared_root()
	if not shared then error("The shared extension directory cannot be resolved", 0) end
	local roots = { shared .. "/../extensions" }
	for _, root in ipairs(require("modules.keymap.layout_registry").extension_roots()) do
		roots[#roots + 1] = root
	end
	roots[#roots + 1] = require("infra.config_paths").get_config_dir() .. "extensions"
	return roots
end

--- Discovers packs in canonical precedence order, without changing any state.
--- @param roots table|nil Extension roots; defaults to M.roots().
--- @param io_fns table|nil Scanner collaborators; defaults to this driver's filesystem.
--- @return table Shared extension records.
function M.scan(roots, io_fns)
	return Extensions.scan(roots or M.roots(), io_fns or {
		list_dirs  = function(path) return children(path, "directory") end,
		list_files = function(path) return children(path, "file") end,
		read_file  = read_manifest,
	})
end

--- Discovers this boot's catalogue once; every later reader gets the same packs.
--- @param roots table|nil Extension roots; defaults to M.roots().
--- @param io_fns table|nil Scanner collaborators; defaults to this driver's filesystem.
--- @return table Shared extension records.
function M.discover(roots, io_fns)
	if _catalogue ~= nil then error("Extension packs were already discovered for this boot", 0) end
	Logger.start(LOG, "Discovering extension packs…")
	local ok, packs = pcall(M.scan, roots, io_fns)
	if not ok then
		Logger.error(LOG, "Extension discovery was refused: %s.", tostring(packs))
		error(packs, 0)
	end
	local files, bound = 0, 0
	for _, pack in ipairs(packs) do
		files = files + #pack.toml_files
		bound = bound + #pack.bound_files
	end
	_catalogue = packs
	Logger.success(LOG, "Discovered %d extension(s): %d hotstring pack(s), %d bound geometry file(s).",
		#packs, files, bound)
	return packs
end

--- The catalogue discover() committed.
--- @return table Shared extension records.
function M.catalogue()
	if _catalogue == nil then error("Extension packs were read before discovery", 0) end
	return _catalogue
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
--- @param packs table Shared extension records.
--- @param keymap table Keymap owner exposing load_toml(name, path).
--- @return table Registered { name, path, extension } entries in load order.
function M.load(packs, keymap)
	local loaded = {}
	for _, extension in ipairs(packs) do
		for _, file in ipairs(extension.toml_files) do
			local category = Extensions.category_key(extension.id, file.stem)
			if keymap.load_toml(category, file.path) ~= true then
				error("Extension hotstring registration did not commit: " .. category, 0)
			end
			loaded[#loaded + 1] = { name = category, path = file.path, extension = extension.id }
		end
	end
	Logger.debug(LOG, "Registered %d extension hotstring pack(s).", #loaded)
	return loaded
end

--- Test seam: forgets the boot catalogue.
function M._reset()
	_catalogue = nil
end

return M
