-- static/ergopti_plus/macos/tests/unit/ui/menu/test_config_unused_source_shapes.lua

--- Source-bound receipt forwarding keeps historical two-argument readers valid.
local helpers = require("tests.helpers")
helpers.describe("unused-key scanner source shape receipt", function()
	helpers.it("forwards the receipt of its exact decode with scalar and array ownership", function()
		local source = '[sample]\nlist=[]\ndictionary={}\nunowned=7\n'
		local observed
		local scan = require("config_unused_keys").find_in_source(source, function(document, mark, shapes)
			observed = { document = document, shapes = shapes }
			mark("sample", "list")
			mark("sample", "dictionary")
		end)
		helpers.assert_true(rawequal(observed.shapes.document, observed.document), "same decode owns receipt")
		helpers.assert_eq(observed.shapes.arrays[observed.document.sample.list], true)
		helpers.assert_nil(observed.shapes.arrays[observed.document.sample.dictionary])
		helpers.assert_eq(scan.status, "ok")
		helpers.assert_eq(#scan.keys, 1)
		helpers.assert_eq(scan.keys[1].path, { "sample", "unowned" })
	end)
	helpers.it("retains historical two-argument reader behavior", function()
		local calls = 0
		local scan = require("config_unused_keys").find_in_source('[sample]\nowned=false\nunowned=true\n', function(document, mark)
			calls = calls + 1
			helpers.assert_eq(document.sample.owned, false)
			mark("sample", "owned")
		end)
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(scan.status, "ok")
		helpers.assert_eq(#scan.keys, 1)
		helpers.assert_eq(scan.keys[1].key, "unowned")
	end)
	helpers.it("does not call a reader or expose partial receipts for rejected source", function()
		local calls = 0
		local scan = require("config_unused_keys").find_in_source('[sample]\nlist=[\n', function() calls = calls + 1 end)
		helpers.assert_eq(scan.status, "malformed")
		helpers.assert_eq(scan.keys, {})
		helpers.assert_eq(calls, 0)
	end)
end)

local model_records = require("test.user_model_records_contract")
model_records.register_pure(helpers)
model_records.register_native(helpers)
