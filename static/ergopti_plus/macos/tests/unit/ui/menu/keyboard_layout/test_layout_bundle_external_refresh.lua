--- tests/unit/ui/menu/keyboard_layout/test_layout_bundle_external_refresh.lua

--- ==============================================================================
--- MODULE: Keyboard Layout External Bundle Refresh Regression
--- DESCRIPTION:
--- Rebuilds the real layout menu around externally changing directory listings.
--- Session memoisation must retain the fast path only while the corresponding
--- directory identity is unchanged.
--- ==============================================================================

local helpers = require("tests.helpers")
local LayoutFixture = require("tests.support.layout_legacy_caption_fixture")





-- ============================================
-- ============================================
-- ======= 1/ External Bundle Mutations =======
-- ============================================
-- ============================================

helpers.describe("menu_keyboard_layout: external bundle mutations invalidate discovery", LayoutFixture.scoped(function()
	helpers.it("reflects an install, delete, and bundled-version addition on rebuild", function()
		local saved_hs = rawget(_G, "hs")
		local saved_popen = io.popen
		local ok, err = xpcall(function()
			helpers.with_fresh_modules({
				"modules.keymap.layout_install",
				"core.fs.engine.dir",
				"modules.keymap.input_sources",
				"ui.menu.menu_keyboard_layout",
				"infra.logger",
				"infra.text_utils",
				"core.i18n.engine.i18n",
				"infra.notifications",
				"core.fs.adapters.storage",
				"infra.deferred_work",
				"infra.timings",
				"ui.menu.keymap_lifecycle",
				"infra.manifest_menu",
				"core.fs.engine.paths",
				"hs",
				"tests.stubs.hs",
			}, function()
				local hs_stub = require("tests.stubs.hs")
				hs_stub.__reset()
				_G.hs = hs_stub
				package.loaded["hs"] = hs_stub
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["core.fs.engine.paths"] = { shared = helpers.shared }
				package.loaded["infra.text_utils"] = {
					shell_quote = function(value) return "'" .. tostring(value) .. "'" end,
					applescript_format = function(template) return template end,
				}
				local labels = {
					["menu.layout.installed_version"] = "%s installed v%s",
					["menu.layout.update_version"] = "%s update v%s to v%s",
					["menu.layout.install_version"] = "%s install %s v%s",
					["menu.layout.scope_system"] = "system",
					["menu.layout.scope_user"] = "user",
				}
				package.loaded["core.i18n.engine.i18n"] = {
					get = function(key) return labels[key] or key end,
					section = function(key) return key end,
				}
				package.loaded["infra.notifications"] = { notify = function() return true end }

				local bundles_dir = "/fixture/driver/../../ergopti/macos/bundles/"
				local user_dir = (os.getenv("HOME") or "~") .. "/Library/Keyboard Layouts/"
				local system_dir = "/Library/Keyboard Layouts/"
				local available = { "Ergopti_v2.2.2.bundle" }
				local installed_user = { "Ergopti_v2.2.1.bundle" }
				local plist_present = true
				local revisions = { bundles = 1, user = 1, system = 1 }
				local scans = { bundles = 0, user = 0, system = 0 }

				local function directory_attrs(revision, size, inode)
					return {
						mode = "directory",
						device = 7,
						inode = inode,
						size = size,
						modification = revision,
						change = revision,
					}
				end
				hs_stub.fs.attributes = function(path)
					if path == bundles_dir then
						return directory_attrs(revisions.bundles, #available, 11)
					end
					if path == user_dir then
						return directory_attrs(revisions.user, #installed_user, 12)
					end
					if path == system_dir then
						return directory_attrs(revisions.system, 0, 13)
					end
					for _, name in ipairs(installed_user) do
						if path == user_dir .. name .. "/Contents/Info.plist" then
							return plist_present and { mode = "file" } or nil
						end
					end
					return nil
				end

				hs_stub.fs.dir = function(path)
					local rows
					if path == bundles_dir then rows = available
					elseif path == user_dir then rows = installed_user
					elseif path == system_dir then rows = {}
					else error("unexpected directory") end
					local index = 0
					return function() index = index + 1; return rows[index] end
				end

				local function pipe_for(rows)
					local index = 0
					return {
						lines = function()
							return function()
								index = index + 1
								return rows[index]
							end
						end,
						close = function() return true end,
					}
				end
				io.popen = function(command)
					local function mentions(path)
						return command:find(path, 1, true) ~= nil
							or command:find(path:gsub("/", "\\"), 1, true) ~= nil
					end
					if mentions(bundles_dir) then
						scans.bundles = scans.bundles + 1
						return pipe_for(available)
					end
					if mentions(user_dir) then
						scans.user = scans.user + 1
						return pipe_for(installed_user)
					end
					if mentions(system_dir) then
						scans.system = scans.system + 1
						return pipe_for({})
					end
					return pipe_for({})
				end

				local install = require("modules.keymap.layout_install")
				-- Each reader of the installed bundles gets the build's one snapshot.
				local snapshots = {}
				package.loaded["modules.keymap.input_sources"] = {
					list_active_keyboard_layouts = function() return {} end,
					build_kl_name_to_tis_id = function(installed) snapshots.map = installed; return {} end,
					resolve_installed_ergopti_version = function(installed) snapshots.version = installed; return nil end,
					ergopti_in_active_layouts = function(_, installed) snapshots.active = installed; return false end,
					set_active_layouts_cache = function() end,
				}
				local user_listings = 0
				local list_directory = hs_stub.fs.dir
				hs_stub.fs.dir = function(path)
					if path == user_dir then user_listings = user_listings + 1 end
					return list_directory(path)
				end
				package.loaded["core.fs.adapters.storage"] = {
					get = function() return nil end,
					set = function() return true end,
				}
				package.loaded["infra.deferred_work"] = { after = function() return true end }
				package.loaded["infra.timings"] = { sec = function() return 0.1 end }
				package.loaded["ui.menu.keymap_lifecycle"] = { ensure_started = function() return true end }
				local actual_manifest = LayoutFixture.install(package.loaded["core.i18n.engine.i18n"])
				package.loaded["infra.manifest_menu"] = {
					template_rows = actual_manifest.template_rows,
					group_row = actual_manifest.group_row,
					status_rows = actual_manifest.status_rows,
					build = function(_, _, _, _, _, providers)
						return providers.layout_bundle()
					end,
				}
				package.loaded["ui.menu.menu_keyboard_layout"] = nil
				local Menu = require("ui.menu.menu_keyboard_layout")

				local function user_row()
					local built = Menu.build({
						base_dir = "/fixture/driver/",
						updateMenu = function() end,
					})
					local labels_seen = {}
					for _, item in ipairs(built.submenu) do
						labels_seen[#labels_seen + 1] = tostring(item.label)
						if type(item.label) == "string"
							and item.label:find("user", 1, true) ~= nil then
							return item
						end
					end
					error("the user-scope bundle row is missing: " .. table.concat(labels_seen, ", "))
				end

				local row = user_row()
				helpers.assert_eq(row.label, "user update v2.2.1 to v2.2.2")
				helpers.assert_true(row.disabled ~= true)
				helpers.assert_true(type(snapshots.map) == "table" and snapshots.map.user ~= nil,
					"the input-source map reads the build's snapshot")
				helpers.assert_true(snapshots.version == snapshots.map and snapshots.active == snapshots.map,
					"every reader shares one snapshot instead of listing both scopes again")
				helpers.assert_eq(snapshots.map.user.name, "Ergopti_v2.2.1.bundle")
				helpers.assert_eq(user_listings, 1, "one listing of the user scope per build")

				installed_user = { "Ergopti_v2.2.2.bundle" }
				revisions.user = revisions.user + 1
				row = user_row()
				helpers.assert_eq(row.label, "user installed v2.2.2")
				helpers.assert_true(row.disabled == true)

				installed_user = {}
				revisions.user = revisions.user + 1
				row = user_row()
				helpers.assert_eq(row.label, "📥 install user v2.2.2")
				helpers.assert_true(row.disabled ~= true)

				installed_user = { "Ergopti_v2.2.2.bundle" }
				revisions.user = revisions.user + 1
				available = { "Ergopti_v2.2.2.bundle", "Ergopti_v2.2.3.bundle" }
				revisions.bundles = revisions.bundles + 1
				row = user_row()
				helpers.assert_eq(row.label, "user update v2.2.2 to v2.2.3")
				helpers.assert_true(row.disabled ~= true)

				-- Repeated native listings do not spawn directory-listing processes.
				local scans_before = {
					bundles = scans.bundles,
					user = scans.user,
					system = scans.system,
				}
				row = user_row()
				helpers.assert_eq(row.label, "user update v2.2.2 to v2.2.3")
				helpers.assert_eq(scans, scans_before)
				helpers.assert_eq(install.pick_latest_bundle(bundles_dir), "Ergopti_v2.2.3.bundle")

				-- A same-length replacement in the same second keeps the same root
				-- metadata, but the next native listing must see the new name.
				installed_user = { "Ergopti_v2.2.3.bundle" }
				helpers.assert_eq(install.highest_installed(user_dir).name, "Ergopti_v2.2.3.bundle")
				installed_user = { "Ergopti_v2.2.2.bundle" }
				available = { "Ergopti_v2.2.4.bundle" }
				helpers.assert_eq(install.pick_latest_bundle(bundles_dir), "Ergopti_v2.2.4.bundle")

				-- Mutating a bundle's contents does not change its parent's revision.
				-- The cached names must still be checked against the current plist.
				plist_present = false
				hs_stub.execute = function() return "", false end
				helpers.assert_eq(install.highest_installed(user_dir), nil)
				plist_present = true
				helpers.assert_eq(install.highest_installed(user_dir).name, "Ergopti_v2.2.2.bundle")
				helpers.assert_eq(scans.user, scans_before.user,
					"nested plist changes must not require another parent listing")
			end)
		end, debug.traceback)
		_G.hs = saved_hs
		io.popen = saved_popen
		if not ok then error(err, 0) end
	end)
end))
