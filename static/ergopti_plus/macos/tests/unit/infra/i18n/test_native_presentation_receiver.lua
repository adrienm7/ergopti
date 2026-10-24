--- tests/unit/infra/i18n/test_native_presentation_receiver.lua

--- Replays the shared native presentation receiver and checks this driver uses it.
local helpers = require("tests.helpers")
local Contract = require("test.native_presentation_receiver_contract")
Contract.register(helpers)
Contract.register_driver(helpers)
