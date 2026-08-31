--- tests/unit/ui/menu/test_layout_bundle_external_refresh.lua

--- ==============================================================================
--- MODULE: Keyboard Layout External Bundle Refresh Regression
--- DESCRIPTION:
--- Rebuilds the real layout menu around externally changing directory listings.
--- Session memoisation must retain the fast path only while the corresponding
--- directory identity is unchanged.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ============================================
-- ============================================
-- ======= 1/ External Bundle Mutations =======
-- ============================================
-- ============================================

helpers.describe("menu_keyboard_layout: external bundle mutations invalidate discovery", function()
	helpers.it("reflects an install, delete, and bundled-version addition on rebuild", function()
		local saved_hs = rawget(_G, "hs")
		local saved_popen = io.popen
		local ok, err = xpcall(function()
			helpers.with_fresh_modules({
				"modules.keymap.layout_install",
				"modules.keymap.input_sources",
				"ui.menu.menu_keyboard_layout",
				"infra.logger",
				"infra.text_utils",
				"infra.i18n",
				"infra.notifications",
				"adapters.storage",
				"infra.deferred_work",
				"infra.timings",
				"ui.menu.keymap_lifecycle",
				"infra.manifest_menu",
				"hs",
				"tests.stubs.hs",
			}, function()
				local hs_stub = require("tests.stubs.hs")
				hs_stub.__reset()
				_G.hs = hs_stub
				package.loaded["hs"] = hs_stub
				package.loaded["infra.logger"] = helpers.make_logger_stub()
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
				package.loaded["infra.i18n"] = {
					get = function(key) return labels[key] or key end,
				}
				package.loaded["infra.notifications"] = { notify = function() return true end }

				local bundles_dir = "/fixture/driver/../../ergopti/macos/bundles/"
				local user_dir = (os.getenv("HOME") or "~") .. "/Library/Keyboard Layouts/"
				local system_dir = "/Library/Keyboard Layouts/"
				local available = { "Ergopti_v2.2.2.bundle" }
				local installed_user = { "Ergopti_v2.2.1.bundle" }
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
							return { mode = "file" }
						end
					end
					return nil
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
					if command:find(bundles_dir:gsub("/", "\\"), 1, true) then
						scans.bundles = scans.bundles + 1
						return pipe_for(available)
					end
					if command:find(user_dir, 1, true) then
						scans.user = scans.user + 1
						return pipe_for(installed_user)
					end
					if command:find(system_dir, 1, true) then
						scans.system = scans.system + 1
						return pipe_for({})
					end
					return pipe_for({})
				end

				local install = require("modules.keymap.layout_install")
				package.loaded["modules.keymap.input_sources"] = {
					ERGOPTI_VARIANTS = {},
					list_active_keyboard_layouts = function() return {} end,
					build_kl_name_to_tis_id = function() return {} end,
					resolve_installed_ergopti_version = function() return nil end,
					ergopti_in_active_layouts = function() return false end,
					set_active_layouts_cache = function() end,
				}
				package.loaded["adapters.storage"] = {
					get = function() return nil end,
					set = function() return true end,
				}
				package.loaded["infra.deferred_work"] = { after = function() return true end }
				package.loaded["infra.timings"] = { sec = function() return 0.1 end }
				package.loaded["ui.menu.keymap_lifecycle"] = { ensure_started = function() return true end }
				package.loaded["infra.manifest_menu"] = {
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
					return built.items[2]
				end

				local row = user_row()
				helpers.assert_eq(row.label, "user update v2.2.1 to v2.2.2")
				helpers.assert_true(row.disabled ~= true)

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

				-- Positive cache control: unchanged directories keep the same discoveries
				-- without paying for another directory listing.
				local scans_before = {
					bundles = scans.bundles,
					user = scans.user,
					system = scans.system,
				}
				row = user_row()
				helpers.assert_eq(row.label, "user update v2.2.2 to v2.2.3")
				helpers.assert_eq(scans, scans_before)
				helpers.assert_eq(install.pick_latest_bundle(bundles_dir), "Ergopti_v2.2.3.bundle")
			end)
		end, debug.traceback)
		_G.hs = saved_hs
		io.popen = saved_popen
		if not ok then error(err, 0) end
	end)
end)
