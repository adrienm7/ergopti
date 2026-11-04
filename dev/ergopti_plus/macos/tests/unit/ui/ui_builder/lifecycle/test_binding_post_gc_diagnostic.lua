--- tests/unit/ui/ui_builder/lifecycle/test_binding_post_gc_diagnostic.lua

--- ==============================================================================
--- MODULE: Binding Diagnostic Post-GC Delivery
--- DESCRIPTION:
--- Runs the actual diagnostic and factory through independently delivered native
--- messages and JavaScript completions. No portable case qualifies Cocoa.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.webview_binding_diagnostic_fixture")

--- Reaches the fresh post boundary without accepting earlier observations.
--- @param h table Execution fixture.
--- @return table fresh Native post awaiting its independent outcomes.
local function fresh_post(h)
	h.until_condition(function() return h.posts["current-b-after-a-gc"] or h.result() end)
	assert(not h.result(), "earlier B observations must not publish diagnostic success")
	local post = assert(h.posts["current-b-after-a-gc"], "fresh B post was never issued")
	assert(getmetatable(h.views[3]) == nil, "A must be consumed before the new post")
	assert(post.view == h.views[4], "the new post must originate from exact B")
	return post
end

helpers.describe("binding diagnostic requires B after A native GC", function()
	helpers.it("preserves the healthy existing factory and shared-controller controls", function()
		Fixture(function(h)
			h.until_condition(function() return h.posts["current-b"] or h.result() end)
			assert(not h.result(), "real initial phases must reach the shared-controller boundary")
			assert(h.states[h.views[3]].controller == h.states[h.views[4]].controller)
			h.until_condition(function() return h.posts["current-b-after-a-gc"] or h.result() end)
			local post = h.posts["current-b-after-a-gc"]
			if post then h.deliver(post); h.complete(post) end
			h.until_condition(function() return h.result() end)
			assert(h.result().status == "ok", tostring(h.result().error))
			assert(h.result().features.callback_release.collected_after_detach)
			assert(h.result().features.message_identity.a_closes == 1)
			assert(h.result().features.message_identity.b_closes == 1)
		end)
	end)

	for _, first in ipairs({ "native", "javascript" }) do
		helpers.it("withholds success until both outcomes arrive, first " .. first, function()
			Fixture(function(h)
				local post = fresh_post(h)
				for _ = 1, 3 do h.step() end
				assert(not h.result(), "unobserved post must remain pending")
				if first == "native" then h.deliver(post) else h.complete(post) end
				for _ = 1, 3 do h.step() end
				assert(not h.result(), "one observed outcome must remain pending")
				if first == "native" then h.complete(post) else h.deliver(post) end
				h.until_condition(function() return h.result() end)
				local result = h.result()
				assert(result.status == "ok", tostring(result.error))
				assert(result.schema_version == 3)
				local identity = result.features.message_identity
				assert(identity.b_after_a_gc_source_exact and identity.b_after_a_gc_accepted and identity.b_after_a_gc_evaluated)
				assert(identity.a_closes == 1 and identity.b_closes == 1)
				assert(#h.probe.evaluations == 4, "each actual post needs its own JavaScript completion")
				assert(getmetatable(h.views[4]) == nil, "B retirement must complete before success")
			end)
		end)
	end

	helpers.it("does not borrow the earlier B kind or its completed evaluation", function()
		Fixture(function(h)
			fresh_post(h)
			h.deliver(h.posts["current-b"]); h.complete(h.posts["current-b"])
			for _ = 1, 3 do h.step() end
			assert(not h.result(), "old B delivery cannot satisfy the fresh kind")
			h.until_condition(function() return h.result() end)
			assert(h.result().status == "error", "missing fresh delivery must fail its deadline")
		end)
	end)

	helpers.it("refuses a forged body source from consumed A after B completion", function()
		Fixture(function(h)
			local post = fresh_post(h)
			post.payload.webView = post.view
			h.deliver(post, h.views[3]); h.complete(post)
			for _ = 1, 3 do h.step() end
			assert(not h.result(), "body fields cannot borrow native B authority")
			h.until_condition(function() return h.result() end)
			assert(h.result().status == "error", "foreign native source cannot qualify")
		end)
	end)

	helpers.it("refuses the fresh kind before exact A consumption", function()
		Fixture(function(h)
			h.until_condition(function() return h.posts["current-b"] or h.result() end)
			assert(not h.result())
			local post = h.posts["current-b"]
			post.payload.kind = "current-b-after-a-gc"
			h.deliver(post)
			assert(h.result() and h.result().status == "error", "early phase must fail before native cleanup")
			assert(h.result().error:find("before exact A consumption", 1, true))
		end)
	end)

	helpers.it("refuses an unsupported completion after a healthy native message", function()
		Fixture(function(h)
			local post = fresh_post(h)
			h.deliver(post); h.complete(post, {})
			assert(h.result() and h.result().status == "error")
			assert(h.result().error:find("primitive true", 1, true))
		end)
	end)
end)
