--- tests/unit/ui/test_ai_outer_parents.lua

--- ==============================================================================
--- MODULE: Genuine Linux AI Outer Parents
--- DESCRIPTION:
--- Exercises the actual prediction engine, AgentSettings, shared renderer and
--- completed native children. Source withdrawal never retains a literal parent.
--- ==============================================================================

local helpers = require("tests.helpers")
local Preferences = require("tests.support.llm_preferences_fixture")

--- Isolates the genuine native owners and restores every intercepted seam.
--- @param body function Test body accepting the actual context and renderer.
local function with_world(body)
	local names = { "modules.llm.prediction_engine", "modules.llm.agent_settings",
		"ui.menu.menu_builder", "ui.menu.agent_rows", "ui.menu.ai_parent" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local renderer = require("infra.manifest_menu")
	local build, group_row = renderer.build, renderer.group_row
	local ok, err = xpcall(function()
		Preferences.with(function()
			local engine = require("modules.llm.prediction_engine")
			local ctx = { llm = engine, paused = false, on_quit = function() end,
				on_menu_changed = function() end }
			ctx.is_paused = function() return ctx.paused end
			engine.init({ is_paused = ctx.is_paused })
			body(ctx, renderer)
		end)
	end, debug.traceback)
	renderer.build, renderer.group_row = build, group_row
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

--- Builds the actual whole tray and selects the translated outer parent.
--- @param ctx table
--- @param kind string
--- @return table|nil parent
local function parent(ctx, kind)
	local title = require("infra.i18n").get("menu." .. kind .. ".title")
	local found
	for _, row in ipairs(require("ui.menu.menu_builder").build(ctx)) do
		if type(row.title) == "string" and row.title:sub(1, #title) == title then
			helpers.assert_nil(found, "the actual outer parent must be unique")
			found = row
		end
	end
	return found
end

helpers.describe("Linux shared AI outer parents", function()
	for _, kind in ipairs({ "llm", "agent" }) do
		helpers.it("retains the genuine completed " .. kind .. " child and its callbacks", function()
			with_world(function(ctx, renderer)
				local original = renderer.group_row
				local completed, calls
				renderer.group_row = function(frame, id, children, getters)
					if id == kind .. "_parent_linux" then
						calls = (calls or 0) + 1
						completed = children
						helpers.assert_true(#children > 1, "the real child must be nonempty and complete")
					end
					return original(frame, id, children, getters)
				end
				local row = parent(ctx, kind)
				helpers.assert_type(row, "table", "the actual native parent must reach the tray")
				helpers.assert_eq(calls, 1, "the shared source must own this parent exactly once")
				helpers.assert_true(rawequal(row.menu, completed), "the renderer retains the whole native child by identity")
				local callback
				if kind == "agent" then
					-- The genuine native Agent commands are inside its mode choice,
					-- followed by native system/application submenus, never flat commands.
					local modes = completed[1].menu
					helpers.assert_type(modes, "table", "the actual mode choice must retain its native command body")
					helpers.assert_eq(#modes, 3, "Off, Action and Auto remain in the complete native choice")
					for index, mode in ipairs(modes) do
						helpers.assert_type(mode.fn, "function", "every genuine mode command remains executable")
						helpers.assert_true(rawequal(row.menu[1].menu[index].fn, mode.fn),
							"projection retains every native nested command by identity")
					end
					callback = modes[1].fn
				else
					for _, child in ipairs(completed) do if type(child.fn) == "function" then callback = child.fn; break end end
				end
				helpers.assert_type(callback, "function", "the old native command route survives projection")
				if kind == "llm" then helpers.assert_eq(row.checked, ctx.llm.is_enabled())
				else helpers.assert_eq(row.checked, require("modules.llm.agent_settings").get_mode() ~= "off") end
				if kind == "agent" then
					local settings = require("modules.llm.agent_settings")
					helpers.assert_eq(settings.get_mode(), "off", "the genuine initial mode gives the callback a real transition")
					local refreshes = 0
					ctx.on_menu_changed = function() refreshes = refreshes + 1 end
					row.menu[1].menu[2].fn()
					helpers.assert_eq(settings.get_mode(), "action", "the retained Action callback reaches the genuine engine and settings owner")
					helpers.assert_eq(refreshes, 1, "an acknowledged native command rebuilds exactly once")
				end
			end)
		end)

		helpers.it("keeps the present " .. kind .. " submenu navigable without its action capability", function()
			with_world(function(ctx)
				local engine = ctx.llm
				local method = kind == "llm" and "toggle" or "set_agent_mode"
				local original = engine[method]
				local settings = require("modules.llm.agent_settings")
				local enabled, mode, refreshes = engine.is_enabled(), settings.get_mode(), 0
				ctx.on_menu_changed = function() refreshes = refreshes + 1 end
				engine[method] = nil
				local ok, err = xpcall(function()
					local row = parent(ctx, kind)
					helpers.assert_type(row, "table", "a present engine retains its real submenu")
					helpers.assert_true(row.disabled ~= true, "opening a submenu does not require unrelated action capability")
					helpers.assert_type(row.menu, "table", "the complete native child stays navigable")
					local command
					if kind == "agent" then command = row.menu[1].menu[2]
					else
						local title = require("infra.i18n").get("menu.llm.enable")
						for _, child in ipairs(row.menu) do if child.title == title then command = child end end
					end
					helpers.assert_type(command, "table", "the genuine action row remains visible")
					local disabled = kind == "agent" and row.menu[1].disabled or command.disabled
					helpers.assert_eq(disabled, true, "the unavailable child action must refuse")
					helpers.assert_type(command.fn, "function", "the original guarded native callback stays owned")
					command.fn()
					helpers.assert_eq(engine.is_enabled(), enabled, "missing toggle cannot change native activation")
					helpers.assert_eq(settings.get_mode(), mode, "missing mode capability cannot commit")
					helpers.assert_eq(refreshes, 0, "a refused native command never rebuilds")
				end, debug.traceback)
				engine[method] = original
				if not ok then error(err, 0) end
			end)
		end)

		helpers.it("withdraws the actual " .. kind .. " source instead of retaining a literal parent", function()
			with_world(function(ctx, renderer)
				local root = renderer.get_root()
				local frame = kind == "llm" and "llm_native_parent_linux" or "agent_native_parent"
				local old = root[frame]
				root[frame] = nil
				local ok, err = xpcall(function() helpers.assert_nil(parent(ctx, kind)) end, debug.traceback)
				root[frame] = old
				if not ok then error(err, 0) end
			end)
		end)

		helpers.it("refuses duplicate actual " .. kind .. " parent declarations", function()
			with_world(function(ctx, renderer)
				local root = renderer.get_root()
				local frame = root[kind == "llm" and "llm_native_parent_linux" or "agent_native_parent"]
				helpers.assert_type(frame, "table", "the positive source must exist")
				local declaration
				for _, row in ipairs(frame) do if row.id == kind .. "_parent_linux" then declaration = row end end
				helpers.assert_type(declaration, "table", "the actual declared subject must exist")
				frame[#frame + 1] = declaration
				local ok, err = xpcall(function() helpers.assert_nil(parent(ctx, kind)) end, debug.traceback)
				frame[#frame] = nil
				if not ok then error(err, 0) end
			end)
		end)

		helpers.it("refuses a " .. kind .. " native callback replaced during child construction", function()
			with_world(function(ctx, renderer)
				local engine, native_build = ctx.llm, renderer.build
				local method = kind == "llm" and "toggle" or "set_agent_mode"
				local old, changed = engine[method], false
				renderer.build = function(key, ...)
					local result = native_build(key, ...)
					if key == kind .. "_menu" then engine[method] = function() return false end; changed = true end
					return result
				end
				local ok, err = xpcall(function()
					helpers.assert_nil(parent(ctx, kind))
					helpers.assert_true(changed, "the real completed child must execute the mutation seam")
				end, debug.traceback)
				engine[method] = old
				if not ok then error(err, 0) end
			end)
		end)

		helpers.it("refuses a " .. kind .. " context withdrawn during child construction", function()
			with_world(function(ctx, renderer)
				local native_build, engine, changed = renderer.build, ctx.llm, false
				renderer.build = function(key, ...)
					local result = native_build(key, ...)
					if key == kind .. "_menu" then ctx.llm = nil; changed = true end
					return result
				end
				local ok, err = xpcall(function()
					helpers.assert_nil(parent(ctx, kind))
					helpers.assert_true(changed, "the genuine current context must be withdrawn")
				end, debug.traceback)
				ctx.llm = engine
				if not ok then error(err, 0) end
			end)
		end)

		helpers.it("preserves the native paused " .. kind .. " parent without an executable child", function()
			with_world(function(ctx)
				ctx.paused = true
				local row = parent(ctx, kind)
				helpers.assert_type(row, "table", "the paused feature remains visible")
				helpers.assert_eq(row.disabled, true)
				helpers.assert_nil(row.menu, "the original pause owner removes every executable child")
				helpers.assert_nil(row.fn, "the original parent still has no click action")
			end)
		end)

		helpers.it("disables the shared " .. kind .. " parent when its native engine is absent", function()
			with_world(function(ctx)
				ctx.llm = nil
				local row = parent(ctx, kind)
				helpers.assert_type(row, "table", "the shared unavailable policy must reach the tray")
				helpers.assert_eq(row.disabled, true)
				helpers.assert_true(row.title:find(require("infra.i18n").get("menu.llm.unavailable"), 1, true) ~= nil,
					"the unavailable reason comes from the existing translated shared declaration")
			end)
		end)

		for _, withdrawal in ipairs({ "context", "native callback", "frame" }) do
			helpers.it("refuses final " .. kind .. " getter withdrawal of the " .. withdrawal, function()
				with_world(function(ctx, renderer)
					local engine = ctx.llm
					local owner = kind == "llm" and engine or require("modules.llm.agent_settings")
					local getter = kind == "llm" and "is_enabled" or "get_mode"
					local command = kind == "llm" and "toggle" or "set_agent_mode"
					local native_getter, native_command = owner[getter], engine[command]
					local native_group = renderer.group_row
					local root = renderer.get_root()
					local frame = kind == "llm" and "llm_native_parent_linux" or "agent_native_parent"
					local declaration = root[frame]
					local armed, changed, projected = false, false, false
					owner[getter] = function(...)
						local value = native_getter(...)
						if armed and not changed then
							changed = true
							if withdrawal == "context" then ctx.llm = nil
							elseif withdrawal == "native callback" then engine[command] = function() return false end
							else root[frame] = nil end
						end
						return value
					end
					renderer.group_row = function(key, id, children, getters)
						local row = native_group(key, id, children, getters)
						if id == kind .. "_parent_linux" then
							helpers.assert_type(row, "table", "the genuine shared parent must succeed before withdrawal")
							helpers.assert_true(rawequal(row.submenu, children), "the genuine result retains the completed child")
							projected, armed = true, true
						end
						return row
					end
					local ok, err = xpcall(function()
						helpers.assert_nil(parent(ctx, kind), "a final state read must not publish a stale native parent")
						helpers.assert_true(projected, "the actual renderer must produce the positive premise")
						helpers.assert_true(changed, "the final actual native getter must execute the withdrawal")
					end, debug.traceback)
					owner[getter], engine[command], ctx.llm, root[frame] = native_getter, native_command, engine, declaration
					if not ok then error(err, 0) end
				end)
			end)
		end
	end
end)
