--- tests/unit/ui/test_changelog_contract.lua

local helpers = require("tests.helpers")

helpers.describe("Changelog Bridge Contract", function()
    helpers.it("correctly handles open_url messages from JavaScript", function()
        -- base_dir is used to find index.html
        _G.base_dir = helpers.driver_root()
        
        -- Setup global hs mock BEFORE loading anything
        _G.hs = _G.hs or {}
        
        -- Mock screen and its methods used by ui_builder.lua
        _G.hs.screen = {
            mainScreen = function() 
                return {
                    frame = function() return {x=0, y=0, w=1920, h=1080} end,
                    fullFrame = function() return {x=0, y=0, w=1920, h=1080} end
                }
            end,
            primaryScreen = function() 
                return hs.screen.mainScreen()
            end
        }

        -- Mock webview and usercontent
        _G.hs.webview = _G.hs.webview or {}
        local bridge_callback = nil
        _G.hs.webview.usercontent = {
            new = function(name)
                return {
                    setCallback = function(self, fn) bridge_callback = fn end
                }
            end
        }
        
        _G.hs.webview.new = function()
            return {
                windowStyle = function(self) return self end,
                closeOnEscape = function(self) return self end,
                level = function(self) return self end,
                shadow = function(self) return self end,
                html = function(self) return self end,
                show = function(self) return self end,
                delete = function(self) return self end,
                hswWindow = function(self) return self end,
                frame = function(self) return {x=0, y=0, w=800, h=600} end,
            }
        end
        
        -- Mock urlevent
        local opened_url = nil
        _G.hs.urlevent = _G.hs.urlevent or {}
        _G.hs.urlevent.openURL = function(url)
            opened_url = url
            return true
        end

        -- Mock json
        _G.hs.json = _G.hs.json or {}
        _G.hs.json.decode = function(s)
            -- Minimal mock for the test payload
            if s:find("open_url") then
                return { action = "open_url", url = s:match('url":"(.-)"') }
            end
            return {}
        end
        _G.hs.json.encode = function(t) return "mock_json" end

        -- Manually clear the module and its dependencies to force a fresh load with our global hs
        package.loaded["ui.changelog.init"] = nil
        package.loaded["ui.ui_builder"] = nil
        
        -- Load the module
        local changelog = require("ui.changelog.init")
        local mock_url = "https://github.com/adrienm7/ergopti/releases/tag/v1.0.0"

        -- Call a dummy open to trigger ensure_ucc (which calls usercontent.new)
        changelog.open()

        helpers.assert_true(type(bridge_callback) == "function", "Bridge callback should be registered")

        -- 3. Simulate the message from script.js
        -- The bridge expects a table with a 'body' field
        local mock_msg = {
            body = '{"action":"open_url","url":"' .. mock_url .. '"}'
        }

        bridge_callback(mock_msg)

        -- 4. Verify the URL was dispatched to the OS
        helpers.assert_eq(opened_url, mock_url, "The bridge should have opened the correct URL")
    end)
end)
