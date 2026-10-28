--- _shared/lua/test/menu_personal_info_source_contract.lua

--- ==============================================================================
--- MODULE: Menu Personal Information Source Contract
--- DESCRIPTION:
--- Hand-written manifests pin what the shared personal-information editor
--- admission accepts, what it refuses, and which later change of the retained
--- declaration or of the renderer facade makes `current` report false. Both
--- drivers replay it against the one shared body.
--- ==============================================================================

local M = {}

--- Builds a plain renderer whose root declares the single editor row.
--- @return table renderer, table root, table source, table declaration
local function plain_renderer()
	local declaration = {
		type = "command", id = "personal_info_editor_open", i18n = "menu.shortcuts.edit_personal_info",
		platforms = { "hs", "linux" }, unavailable = "hide",
	}
	local source = { declaration }
	local root = { personal_info_editor_frame = source }
	local renderer = {
		template_rows = function() return {} end,
		get_root = function() return root end,
		get_array = function(name) return root[name] end,
	}
	return renderer, root, source, declaration
end

--- Runs body(renderer, root, source, declaration) with the renderer registered
--- as `infra.manifest_menu`, then restores the previous registration.
--- @param body function
local function with_registered(body)
	local renderer, root, source, declaration = plain_renderer()
	local modules = package.loaded
	local previous = modules["infra.manifest_menu"]
	modules["infra.manifest_menu"] = renderer
	local ok, err = pcall(body, renderer, root, source, declaration)
	modules["infra.manifest_menu"] = previous
	if not ok then error(err, 0) end
end

--- Registers the shared pure admission contract in the actual driver suites.
--- @param helpers table The registered driver assertion owner.
function M.register(helpers)
	local PersonalInfoSource = require("menu.frames.personal_info_source")
	helpers.describe("the personal information editor source admission", function()
		helpers.it("admits the registered plain renderer and returns its own template owner", function()
			with_registered(function(renderer)
				local current, template = PersonalInfoSource.read(renderer)
				helpers.assert_eq(type(current), "function")
				helpers.assert_true(template == renderer.template_rows)
				helpers.assert_eq(current(), true)
			end)
		end)

		helpers.it("refuses a renderer that is not the registered infra.manifest_menu", function()
			with_registered(function(renderer)
				package.loaded["infra.manifest_menu"] = {}
				helpers.assert_nil((PersonalInfoSource.read(renderer)))
				helpers.assert_nil((PersonalInfoSource.read(nil)))
			end)
		end)

		helpers.it("refuses a renderer with a metatable or a missing owner", function()
			with_registered(function(renderer)
				for _, missing in ipairs({ "template_rows", "get_root", "get_array" }) do
					local saved = renderer[missing]
					renderer[missing] = nil
					helpers.assert_nil((PersonalInfoSource.read(renderer)))
					renderer[missing] = saved
				end
				setmetatable(renderer, {})
				helpers.assert_nil((PersonalInfoSource.read(renderer)))
			end)
		end)

		helpers.it("refuses a declaration that is not the single plain editor command", function()
			local function refused(mutate)
				local result
				with_registered(function(renderer, root, source, declaration)
					mutate(root, source, declaration)
					result = PersonalInfoSource.read(renderer) == nil
				end)
				return result
			end
			helpers.assert_eq(refused(function(root) root.personal_info_editor_frame = nil end), true)
			helpers.assert_eq(refused(function(_, source) source[2] = {} end), true)
			helpers.assert_eq(refused(function(_, source) source[1] = nil end), true)
			helpers.assert_eq(refused(function(_, _, declaration) declaration.id = "other" end), true)
			helpers.assert_eq(refused(function(_, _, declaration) declaration.type = "group" end), true)
			helpers.assert_eq(refused(function(_, _, declaration) declaration.i18n = "" end), true)
			helpers.assert_eq(refused(function(_, _, declaration) declaration.unavailable = nil end), true)
			helpers.assert_eq(refused(function(_, _, declaration) declaration.extra = true end), true)
			helpers.assert_eq(refused(function(_, _, declaration) declaration.platforms = { "hs" } end), true)
			helpers.assert_eq(refused(function(_, _, declaration) declaration.platforms = { "hs", "linux", "x" } end), true)
			helpers.assert_eq(refused(function(_, _, declaration) setmetatable(declaration, {}) end), true)
			helpers.assert_eq(refused(function(root) setmetatable(root, {}) end), true)
		end)

		helpers.it("reports false once the retained declaration or the facade changed", function()
			local function changed(mutate)
				local result
				with_registered(function(renderer, root, source, declaration)
					local current = PersonalInfoSource.read(renderer)
					mutate(renderer, root, source, declaration)
					result = current()
				end)
				return result
			end
			helpers.assert_eq(changed(function() end), true)
			helpers.assert_eq(changed(function(_, _, _, declaration) declaration.i18n = "menu.other" end), false)
			helpers.assert_eq(changed(function(_, _, _, declaration) declaration.platforms[2] = "macos" end), false)
			helpers.assert_eq(changed(function(_, _, _, declaration) declaration.extra = true end), false)
			helpers.assert_eq(changed(function(_, _, source) source[1] = { type = "command" } end), false)
			helpers.assert_eq(changed(function(_, _, source) source[2] = {} end), false)
			helpers.assert_eq(changed(function(_, root) root.personal_info_editor_frame = { {} } end), false)
			helpers.assert_eq(changed(function(renderer) renderer.template_rows = function() end end), false)
			helpers.assert_eq(changed(function(renderer) renderer.get_root = function() return {} end end), false)
			helpers.assert_eq(changed(function(renderer) setmetatable(renderer, {}) end), false)
			helpers.assert_eq(changed(function() package.loaded["infra.manifest_menu"] = {} end), false)
		end)
	end)
end

return M
