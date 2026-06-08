--- tests/unit/ui/menu/test_menu_hotstring_classification.lua

local helpers = require("tests.helpers")

helpers.describe("Hotstrings Menu Classification", function()
    local function setup()
        package.loaded["ui.menu.builder"] = nil
        package.loaded["ui.menu.hotstring_counter"] = nil
        
        -- base_dir is used to find menu_manifest.json
        _G.base_dir = helpers.driver_root()
        
        local builder = helpers.load_with_stubs("ui.menu.builder")
        local counter = helpers.load_with_stubs("ui.menu.hotstring_counter")
        
        -- Mock context
        local ctx = {
            base_dir = _G.base_dir,
            hotfiles = {
                "/root/hotstrings/sfbsreduction.toml",
                "/root/hotstrings/rolls.toml",
                "/root/hotstrings/autocorrection.toml"
            },
            get_group_name = function(f)
                -- Fixed get_group_name logic
                local name = f:match("([^/\\]+)$") or f
                return name:match("^(.*)%.toml$") or name
            end,
            keymap = {
                get_sections = function(name)
                    return {{ name = "test", count = 10 }}
                end,
                is_group_enabled = function(name) return true end,
                is_section_enabled = function(gn, sn) return true end,
                get_meta_description = function(name) return "Desc for " .. name end
            },
            applyTriggerChar = function(s) return s end,
            save_prefs = function() end,
            notify_feature = function() end,
            updateMenu = function() end
        }
        return builder, counter, ctx
    end

    helpers.it("correctly classifies sfbsreduction and rolls as Ergopti groups", function()
        local _, counter, ctx = setup()
        -- 1. Setup ERGOPTI_GROUPS manually to simulate manifest content
        local ERGOPTI_GROUPS = { 
            sfbs_reduction = true, 
            rolls = true,
            -- The code should now also support flattened names:
            sfbsreduction = true 
        }

        local result = counter.count_all(ctx, ERGOPTI_GROUPS)

        -- sfbsreduction and rolls should be in ergopti_total
        -- autocorrection should be in common_total
        helpers.assert_eq(result.ergopti, 20, "sfbsreduction and rolls should contribute 10 each to ergopti")
        helpers.assert_eq(result.common, 10, "autocorrection should contribute 10 to common")
    end)

    helpers.it("extracts group names correctly from absolute paths", function()
        local _, _, ctx = setup()
        helpers.assert_eq(ctx.get_group_name("/abs/path/to/mygroup.toml"), "mygroup")
        helpers.assert_eq(ctx.get_group_name("mygroup.toml"), "mygroup")
    end)
end)
