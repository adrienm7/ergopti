--- tests/unit/menu/hotstrings/test_user_hotstring_menu.lua

--- Registers independent shared programmable-menu checks with the Linux renderer.
require("tests.lua.hotstrings.user_hotstring_menu_contract").run(require("tests.helpers"), require("menu.engine.manifest_menu"), require("core.logger.engine.shim"))
