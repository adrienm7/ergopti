--- tests/unit/ui/menu/menu_llm/activation/test_llm_menu_config_parents.lua

--- ==============================================================================
--- MODULE: Regression - the AI submenus that write config.toml name their cause
--- DESCRIPTION:
--- The switch and the restore row grey with « Saved by a newer version » when
--- config.toml refuses writes, but the backend (servers), API-entry and profile
--- parents only knew about the pause: they stayed live over a file every click
--- of theirs was going to be refused on, and a menu kept open across a reload
--- onto a newer file ran the click anyway (ai-submenus-newer-config-2026-10-23).
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")
local ConfigGuard = require("ui.menu.menu_llm.config_guard")

--- Finds the first row whose title starts with a caption.
--- @param rows table Native rows.
--- @param prefix string Caption prefix.
--- @return table|nil row
local function find_row(rows, prefix)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

helpers.describe("AI submenu configuration guard (ai-submenus-newer-config-2026-10-23)", function()
	helpers.it("names the cause: newer, generic, or none", function()
		local function migrate(reason, status)
			return { read_only_reason = function() return reason end, read_only_status = function() return status end }
		end
		helpers.assert_eq(ConfigGuard.reason_key("/c.toml", migrate(nil, nil)), nil)
		helpers.assert_eq(ConfigGuard.reason_key("/c.toml", migrate("x", "newer")), "menu.read_only.newer_schema")
		helpers.assert_eq(ConfigGuard.reason_key("/c.toml", migrate("x", "invalid")), "menu.llm.save_unavailable")
		helpers.assert_eq(ConfigGuard.reason_key("", migrate(nil, nil)), "menu.llm.save_unavailable",
			"an unknown path is not a writable path")
	end)

	helpers.it("wraps every retained action in place and refuses it once the file is protected", function()
		local reason, ran = nil, 0
		local leaf = { title = "leaf", fn = function() ran = ran + 1; return true end }
		local inner = { leaf }
		local tree = { { title = "parent", menu = inner }, { title = "-" } }
		ConfigGuard.protect(tree, function() return reason end)
		helpers.assert_true(rawequal(tree[1].menu, inner), "the submenu keeps its identity")
		helpers.assert_eq(inner[1].fn(), true)
		helpers.assert_eq(ran, 1)
		reason = "menu.read_only.newer_schema"
		helpers.assert_eq(inner[1].fn(), false, "a retained click rechecks the cause")
		helpers.assert_eq(ran, 1, "the refused click never reaches its action")
	end)

	--- Builds the AI menu and collects what each declared dynamic row places.
	--- @param newer boolean Whether config.toml is protected by a newer version.
	--- @param callback function Receives { rows = id -> native rows, calls = fixture calls }.
	local function with_rows(newer, callback)
		with_activation("ollama", { true }, nil, function(_action, state, calls)
			state.llm_enabled = true
			local protected = newer
			package.loaded["config_migrate"] = {
				read_only_reason = function() return protected and "newer schema" or nil end,
				read_only_status = function() return protected and "newer" or nil end,
			}
			local handlers
			-- The fixture declares no dynamic row and stubs both panels with empty
			-- submenus: declare the two parents and give each submenu a live leaf.
			package.loaded["ui.menu.menu_llm.menu_layout"].row_ids = function()
				return { "llm_backend", "llm_profile" }
			end
			package.loaded["ui.menu.menu_llm.backend_panel"].build = function()
				return "backend", { { title = "Ollama", fn = function() return true end } }
			end
			package.loaded["ui.menu.menu_llm.api_panel"].build = function()
				return "API", { { title = "Entry", fn = function() return true end } }
			end
			package.loaded["infra.manifest_menu"].build = function(_key, _category, built_handlers)
				handlers = built_handlers
				return {}
			end
			calls.handler.build_item()
			local placed = {}
			for id, handler in pairs(handlers) do
				local items = {}
				handler(items)
				placed[id] = items
			end
			callback({ rows = placed, calls = calls, protect = function(value) protected = value end })
		end)
	end

	helpers.it("greys the servers, API and profile parents with the newer-version cause", function()
		with_rows(true, function(built)
			local backend = built.rows.llm_backend
			helpers.assert_eq(#backend, 2, "the servers and the API parents are both placed")
			for index, label in ipairs({ "backend", "API", "profile" }) do
				local row = index < 3 and backend[index] or built.rows.llm_profile[1]
				helpers.assert_true(row.title:find(" — menu.read_only.newer_schema", 1, true) ~= nil,
					label .. " parent names the newer configuration: " .. tostring(row.title))
				helpers.assert_eq(row.disabled, true, label .. " parent is greyed")
				helpers.assert_nil(row.fn, label .. " parent has nothing to run")
			end
		end)
	end)

	helpers.it("leaves the parents live and unsuffixed on a writable configuration", function()
		with_rows(false, function(built)
			for _, row in ipairs({ built.rows.llm_backend[1], built.rows.llm_backend[2], built.rows.llm_profile[1] }) do
				helpers.assert_nil(row.title:find("menu.read_only", 1, true), tostring(row.title))
				helpers.assert_true(row.disabled ~= true, tostring(row.title) .. " stays live")
			end
		end)
	end)

	helpers.it("refuses a retained submenu click once the file turns read-only", function()
		with_rows(false, function(built)
			local leaves = {}
			local function walk(items)
				for _, item in ipairs(items or {}) do
					if type(item.fn) == "function" then leaves[#leaves + 1] = item end
					walk(item.menu)
				end
			end
			walk(built.rows.llm_backend[1].menu)
			walk(built.rows.llm_backend[2].menu)
			walk(built.rows.llm_profile[1].menu)
			helpers.assert_true(#leaves >= 3, "each of the three submenus must offer a live row")
			built.protect(true)
			for _, leaf in ipairs(leaves) do
				helpers.assert_eq(leaf.fn(), false, tostring(leaf.title) .. " rechecks the configuration")
			end
		end)
	end)
end)
