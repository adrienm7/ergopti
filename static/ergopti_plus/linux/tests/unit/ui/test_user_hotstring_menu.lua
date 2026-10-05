--- tests/unit/ui/test_user_hotstring_menu.lua

--- Registers independent shared programmable-menu checks with the Linux renderer.
require("test.user_hotstring_menu_contract").run(require("tests.helpers"), require("infra.manifest_menu"), require("logger.shim"))
