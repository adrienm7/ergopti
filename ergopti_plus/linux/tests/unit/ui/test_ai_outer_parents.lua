--- tests/unit/ui/test_ai_outer_parents.lua

--- ==============================================================================
--- MODULE: Genuine Linux AI Outer Parents
--- DESCRIPTION:
--- Exercises the actual prediction engine, AgentSettings, shared renderer and
--- completed native children under the published available Agent declaration.
--- Separately checks the current disabled public Agent policy; the component
--- fixture never represents current public availability. Source withdrawal
--- never retains a literal parent.
--- ==============================================================================

local helpers = require("tests.helpers")
local Preferences = require("tests.support.llm_preferences_fixture")

--- Isolates genuine owners with the independently published available Agent source.
--- The public-policy cases retain the current top declaration without replacement.
--- @param body function Test body accepting the actual context and renderer.
--- @param public_policy boolean|nil Keep the current public declaration when true.
local function with_world(body, public_policy)
	local names = { "modules.llm.prediction_engine", "modules.llm.agent_settings",
		"ui.menu.menu_builder", "ui.menu.agent_rows", "ui.menu.ai_parent" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local renderer, build, group_row, top, agent_index, public_agent
	local ok, err = xpcall(function()
		for _, name in ipairs(names) do package.loaded[name] = nil end
		renderer = require("infra.manifest_menu")
		build, group_row = renderer.build, renderer.group_row
		local root = renderer.get_root()
		top = root and root.top_level
		helpers.assert_type(top, "table", "the genuine top-level source must exist")
		for index, row in ipairs(top) do
			if row.id == "agent" then
				helpers.assert_nil(agent_index, "the genuine public Agent declaration must be unique")
				agent_index, public_agent = index, row
			end
		end
		helpers.assert_type(public_agent, "table", "the actual Agent declaration must be present")
		if not public_policy then
			-- Exact source input from published 1028f6bd, before public unavailability.
			-- Only the declaration is historical; renderer, engine, child and callbacks
			-- are the genuine current owners exercised by every original assertion.
			local file = assert(io.open(helpers.driver_root()
				.. "/tests/support/fixtures/agent_available_top_level_published_1028.json", "r"))
			local contents = file:read("*a")
			assert(file:close())
			local available = require("json").decode(contents)
			helpers.assert_type(available, "table", "the recorded published declaration must decode")
			helpers.assert_eq(available.id, "agent", "the historical source owns only Agent")
			helpers.assert_eq(available.greyed_when_paused, true, "the historical pause policy is retained")
			local fields = 0
			for key in pairs(available) do
				helpers.assert_true(key == "id" or key == "greyed_when_paused",
					"no invented readiness, owner or availability fields enter the fixture")
				fields = fields + 1
			end
			helpers.assert_eq(fields, 2, "the exact published declaration has two fields")
			top[agent_index] = available
		end
		Preferences.with(function()
			local engine = require("modules.llm.prediction_engine")
			local ctx = { llm = engine, paused = false, on_quit = function() end,
				on_menu_changed = function() end }
			ctx.is_paused = function() return ctx.paused end
			engine.init({ is_paused = ctx.is_paused })
			body(ctx, renderer)
		end)
	end, debug.traceback)
	if top and agent_index and public_agent then top[agent_index] = public_agent end
	if renderer then renderer.build, renderer.group_row = build, group_row end
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

helpers.describe("Linux shared AI outer parents with published available component source", function()
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
	for _, state in ipairs({ "present", "paused", "absent" }) do
		helpers.it("keeps the current public Agent unavailable with its engine " .. state, function()
			with_world(function(ctx, renderer)
				if state == "paused" then ctx.paused = true
				elseif state == "absent" then ctx.llm = nil end
				local root = renderer.get_root()
				local declaration, position
				for index, row in ipairs(root.top_level) do if row.id == "agent" then declaration, position = row, index end end
				helpers.assert_type(declaration, "table", "the current public source remains genuine")
				helpers.assert_eq(declaration.disabled, true, "the public policy declares Agent unavailable")
				helpers.assert_eq(declaration.i18n, "menu.agent.title")
				helpers.assert_eq(declaration.reason_key, "menu.agent.not_ready")
				local native_build, native_group = renderer.build, renderer.group_row
				local child_calls, group_calls = 0, 0
				renderer.build = function(key, ...)
					if key == "agent_menu" then child_calls = child_calls + 1 end
					return native_build(key, ...)
				end
				renderer.group_row = function(frame, id, ...)
					if id == "agent_parent_linux" then group_calls = group_calls + 1 end
					return native_group(frame, id, ...)
				end
				local row = parent(ctx, "agent")
				helpers.assert_type(row, "table", "the current reasoned unavailable parent reaches the public tray")
				local i18n = require("infra.i18n")
				helpers.assert_eq(row.title, i18n.get("menu.agent.title") .. " — " .. i18n.get("menu.agent.not_ready"),
					"the public title retains the exact current translated reason")
				helpers.assert_eq(row.disabled, true)
				helpers.assert_nil(row.menu, "public unavailability exposes no native child")
				helpers.assert_nil(row.fn, "public unavailability has no command")
				helpers.assert_eq(child_calls, 0, "the public policy never constructs the unavailable Agent child")
				helpers.assert_eq(group_calls, 0, "the public policy never publishes an available native Agent group")
				helpers.assert_true(rawequal(declaration, root.top_level[position]),
					"the current public declaration retains its original identity")
			end, true)
		end)
	end

	helpers.it("restores the exact current Agent source after published component coverage", function()
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local original, position
		for index, row in ipairs(root.top_level) do
			if row.id == "agent" then original, position = row, index end
		end
		helpers.assert_type(original, "table")
		helpers.assert_eq(original.disabled, true)
		with_world(function(_, component_renderer)
			helpers.assert_true(rawequal(component_renderer, renderer), "the fixture retains the genuine renderer owner")
			local recorded = component_renderer.get_root().top_level[position]
			helpers.assert_true(not rawequal(recorded, original), "the component case uses the recorded source object")
			helpers.assert_nil(recorded.disabled, "the historical source is explicitly available")
			helpers.assert_eq(recorded.id, original.id)
		end)
		helpers.assert_true(rawequal(root.top_level[position], original), "the exact current declaration is restored")
		helpers.assert_eq(original.disabled, true, "component coverage cannot change public availability")
	end)

	helpers.it("restores every actual fixture owner when the component body refuses", function()
		local renderer = require("infra.manifest_menu")
		local root, original, position = renderer.get_root()
		for index, row in ipairs(root.top_level) do if row.id == "agent" then original, position = row, index end end
		local build, group_row = renderer.build, renderer.group_row
		local names = { "modules.llm.prediction_engine", "modules.llm.agent_settings",
			"ui.menu.menu_builder", "ui.menu.agent_rows", "ui.menu.ai_parent" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local replaced = false
		local refusal = "owned published component body refusal"
		local ok, err = pcall(function()
			with_world(function(_, actual_renderer)
				helpers.assert_true(rawequal(actual_renderer, renderer), "the throwing case retains the real renderer")
				local recorded = actual_renderer.get_root().top_level[position]
				helpers.assert_true(not rawequal(recorded, original), "the refusal follows real historical replacement")
				helpers.assert_nil(recorded.disabled)
				replaced = true
				renderer.build = function(...) return build(...) end
				renderer.group_row = function(...) return group_row(...) end
				error(refusal, 0)
			end)
		end)
		helpers.assert_true(replaced, "the body must execute after genuine fixture replacement")
		helpers.assert_eq(ok, false, "the deliberate component refusal must propagate")
		helpers.assert_true(tostring(err):find(refusal, 1, true) ~= nil, "the original refusal is retained")
		helpers.assert_true(rawequal(root.top_level[position], original), "the exact current source is restored after refusal")
		helpers.assert_true(rawequal(renderer.build, build), "the real build owner is restored after refusal")
		helpers.assert_true(rawequal(renderer.group_row, group_row), "the real group owner is restored after refusal")
		for _, name in ipairs(names) do
			helpers.assert_true(rawequal(package.loaded[name], previous[name]), "the original module identity or absence is restored: " .. name)
		end
	end)

end)
