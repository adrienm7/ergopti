--- tests/unit/ui/test_ui_builder_warmup_ownership.lua

--- ==============================================================================
--- MODULE: UI Builder WebKit Warmup Ownership Tests
--- DESCRIPTION:
--- Verifies that the hidden warmup WebView has one exact owner from allocation
--- through deferred native deletion, including cleanup exceptions.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_fixture(callback)
	helpers.with_fresh_modules({
		"ui.ui_builder", "infra.logger", "infra.paths", "infra.deferred_work",
		"hs", "tests.stubs.hs",
	}, function()
		local controls = {delete_throws = false}
		local context = {creates = 0, deletes = {}, scheduled = {}}
		local webview = {}
		function webview:html() return self end
		function webview:hide() return self end
		function webview:delete()
			context.deletes[#context.deletes + 1] = self
			if controls.delete_throws then error("synthetic warmup delete refusal") end
			return self
		end

		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		hs_stub.webview.new = function()
			context.creates = context.creates + 1
			return webview
		end
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = {shared = function() return "shared" end}
		package.loaded["infra.deferred_work"] = {
			after = function(_delay, deferred_callback)
				context.scheduled[#context.scheduled + 1] = deferred_callback
				return true
			end,
		}

		local Builder = require("ui.ui_builder")
		callback({
			builder = Builder,
			context = context,
			controls = controls,
			webview = webview,
		})
	end)
end

helpers.describe("ui_builder WebKit warmup exact ownership", function()
	helpers.it("coalesces a second request while the first warmup is pending", function()
		with_fixture(function(fixture)
			fixture.builder.warmup_webkit()
			fixture.builder.warmup_webkit()
			helpers.assert_eq(fixture.context.creates, 1,
				"one pending warmup must block duplicate native allocation")
			helpers.assert_eq(#fixture.context.scheduled, 1)
		end)
	end)

	helpers.it("retains and retries a refused deferred warmup cleanup", function()
		with_fixture(function(fixture)
			fixture.builder.warmup_webkit()
			fixture.controls.delete_throws = true
			fixture.context.scheduled[1]()
			helpers.assert_eq(#fixture.context.deletes, 1)
			helpers.assert_eq(fixture.context.deletes[1], fixture.webview)

			fixture.builder.warmup_webkit()
			helpers.assert_eq(fixture.context.creates, 1,
				"a refused cleanup debt must block a successor warmup")
			helpers.assert_eq(#fixture.context.deletes, 2)
			helpers.assert_eq(fixture.context.deletes[2], fixture.webview,
				"the next request must retry the same exact warmup WebView")

			fixture.controls.delete_throws = false
			fixture.builder.warmup_webkit()
			helpers.assert_eq(fixture.context.creates, 1,
				"settling an old cleanup debt must not allocate another warmup")
			helpers.assert_eq(#fixture.context.deletes, 3)
			helpers.assert_eq(fixture.context.deletes[3], fixture.webview)
		end)
	end)
end)
