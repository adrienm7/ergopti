--- static/ergopti_plus/linux/tests/unit/ui/test_managed_document_retirement.lua

--- ==============================================================================
--- MODULE: Managed Document Native Retirement Join
--- DESCRIPTION:
--- Uses actual manager/document owners over explicit controlled native receipts.
--- These receiving controls provide no actual GTK/WebKit/native timer proof.
--- ==============================================================================
local helpers = require("tests.helpers")
local Fixture = require("tests.support.document_fixture")
local function run(body)
	local c = Fixture.new("changelog", { bridge_name = "changelog_bridge", on_message = function() return {} end }, {})
	local called, failure = pcall(body, c)
	local closed, cleanup = pcall(c.close)
	if not called then error(failure, 0) end
	if not closed then error(cleanup, 0) end
	helpers.assert_eq(cleanup, true, "actual captured manager must observe final cleanup")
end
helpers.describe("managed document and native retirement join", function()
	helpers.it("revokes old leased effects before a refused native close", function()
		run(function(c)
			c.handshake()
			local view, owner = c.view(), c.manager.capture_document_owner("changelog")
			local epoch = c.manager.current_epoch("changelog")
			helpers.assert_true(c.manager.document_owner_current(owner))
			local destroy = view.destroy
			view.destroy = function()
				helpers.assert_nil(c.manager.capture_document_owner("changelog"))
				helpers.assert_eq(c.manager.document_owner_current(owner), false)
				helpers.assert_eq(c.manager.document_owner_retained(owner), false)
				helpers.assert_eq(c.manager.eval_owned_js("changelog", owner, "oldPrivateEffect()"), false)
				helpers.assert_nil(c.send("ready", view))
				return false
			end
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			helpers.assert_eq(c.manager.show("changelog"), false)
			helpers.assert_eq(c.manager.shutdown(), false)
			helpers.assert_eq(#c.views, 1)
			view.destroy = destroy
			helpers.assert_true(c.manager.hide("changelog", epoch))
		end)
	end)
	helpers.it("holds timer-close reentry until exact native retirement succeeds", function()
		run(function(c)
			local view = c.start_load()
			local epoch, destroy, closes = c.manager.current_epoch("changelog"), view.destroy, 0
			c.on_cancel = function() c.on_cancel = nil; closes = closes + 1 end
			view.destroy = function() return false end
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			helpers.assert_eq(closes, 0)
			helpers.assert_eq(c.manager.show("changelog"), false)
			helpers.assert_eq(c.manager.shutdown(), false)
			helpers.assert_eq(closes, 0)
			view.destroy = destroy
			helpers.assert_true(c.manager.hide("changelog", epoch))
			helpers.assert_eq(closes, 1)
		end)
	end)
	helpers.it("retains deferred close across refused input release and admits only a fresh successor", function()
		run(function(c)
			local old = c.start_load()
			local epoch, admitted, closes = c.manager.current_epoch("changelog"), false, 0
			c.state.input_capture_gate = { release = function(app, supplied_epoch)
				helpers.assert_eq(app, "changelog")
				helpers.assert_eq(supplied_epoch, epoch)
				return admitted
			end }
			c.on_cancel = function()
				c.on_cancel = nil
				closes = closes + 1
				helpers.assert_true(old.destroyed)
				helpers.assert_nil(c.manager.webview_for("changelog"))
				helpers.assert_true(c.manager.show("changelog"))
			end
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			helpers.assert_true(old.destroyed)
			helpers.assert_eq(closes, 0)
			helpers.assert_eq(c.manager.shutdown(), false)
			helpers.assert_eq(closes, 0)
			admitted = true
			helpers.assert_true(c.manager.hide("changelog", epoch))
			helpers.assert_eq(closes, 1)
			helpers.assert_true(c.manager.current_epoch("changelog") ~= epoch)
			helpers.assert_true(c.manager.is_visible("changelog"))
			c.state.input_capture_gate = nil
		end)
	end)
	helpers.it("late old timer ACK cannot clear the admitted replacement", function()
		run(function(c)
			c.start_load()
			local epoch, timer = c.manager.current_epoch("changelog"), c.timers[1]
			c.on_cancel = function() c.on_cancel = nil; helpers.assert_true(c.manager.show("changelog")) end
			helpers.assert_true(c.manager.hide("changelog", epoch))
			local replacement = c.manager.current_epoch("changelog")
			timer:ack_close()
			helpers.assert_eq(c.manager.current_epoch("changelog"), replacement)
			helpers.assert_true(c.manager.is_visible("changelog"))
			helpers.assert_eq(#c.views, 2)
		end)
	end)
	helpers.it("retired native load hooks cannot allocate a new document timer", function()
		run(function(c)
			local view = c.start_load()
			local epoch, destroy = c.manager.current_epoch("changelog"), view.destroy
			view.destroy = function() return false end
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			local timers, scripts = #c.timers, #c.scripts
			view.on_load_changed(view, "STARTED")
			view.on_load_changed(view, "FINISHED")
			helpers.assert_eq(#c.timers, timers)
			helpers.assert_eq(#c.scripts, scripts)
			view.destroy = destroy
			helpers.assert_true(c.manager.hide("changelog", epoch))
		end)
	end)
	helpers.it("outer debt recovery preserves a successor created during final document close", function()
		run(function(c)
			local view = c.start_load()
			local epoch, destroy = c.manager.current_epoch("changelog"), view.destroy
			view.destroy = function() return false end
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			view.destroy = destroy
			c.on_cancel = function() c.on_cancel = nil; helpers.assert_true(c.manager.show("changelog")) end
			helpers.assert_true(c.manager.show("changelog"))
			helpers.assert_true(c.manager.current_epoch("changelog") ~= epoch)
			helpers.assert_true(c.manager.is_visible("changelog"))
			helpers.assert_eq(#c.views, 2, "outer show must retain the already acquired successor")
		end)
	end)
	helpers.it("shutdown retains the original timer close debt until its explicit ACK", function()
		run(function(c)
			c.start_load()
			local epoch, timer = c.manager.current_epoch("changelog"), c.timers[1]
			helpers.assert_true(c.manager.hide("changelog", epoch))
			helpers.assert_eq(c.manager.shutdown(), false)
			timer:ack_close()
			helpers.assert_true(c.manager.shutdown())
		end)
	end)

	helpers.it("external view destruction retains timer close across native and input refusals", function()
		run(function(c)
			local view = c.start_load()
			local window, epoch = c.windows[1], c.manager.current_epoch("changelog")
			local destroy, admitted, closes = window.destroy, false, 0
			c.state.input_capture_gate = { release = function() return admitted end }
			c.on_cancel = function() c.on_cancel = nil; closes = closes + 1 end
			window.destroy = function() return false end
			view:destroy()
			helpers.assert_true(view.destroyed)
			helpers.assert_nil(c.manager.capture_document_owner("changelog"))
			helpers.assert_eq(closes, 0)
			helpers.assert_eq(c.manager.current_epoch("changelog"), epoch)
			helpers.assert_eq(c.manager.show("changelog"), false)
			helpers.assert_eq(c.manager.shutdown(), false)
			helpers.assert_eq(closes, 0)
			window.destroy = destroy
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			helpers.assert_eq(closes, 0, "native ACK alone cannot release input ownership")
			admitted = true
			helpers.assert_true(c.manager.hide("changelog", epoch))
			helpers.assert_eq(closes, 1)
			c.state.input_capture_gate = nil
		end)
	end)
	helpers.it("external window destruction retains timer close until the exact child and input ACKs", function()
		run(function(c)
			local view = c.start_load()
			local window, epoch = c.windows[1], c.manager.current_epoch("changelog")
			local destroy, admitted, closes = view.destroy, false, 0
			c.state.input_capture_gate = { release = function() return admitted end }
			c.on_cancel = function() c.on_cancel = nil; closes = closes + 1 end
			view.destroy = function() return false end
			window:destroy()
			helpers.assert_eq(view.destroyed, nil)
			helpers.assert_nil(c.manager.capture_document_owner("changelog"))
			helpers.assert_eq(closes, 0)
			helpers.assert_eq(c.manager.current_epoch("changelog"), epoch)
			helpers.assert_eq(c.manager.show("changelog"), false)
			helpers.assert_eq(c.manager.shutdown(), false)
			helpers.assert_eq(closes, 0)
			view.destroy = destroy
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			helpers.assert_true(view.destroyed)
			helpers.assert_eq(closes, 0, "child ACK alone cannot release input ownership")
			admitted = true
			helpers.assert_true(c.manager.hide("changelog", epoch))
			helpers.assert_eq(closes, 1)
			c.state.input_capture_gate = nil
		end)
	end)
	helpers.it("renderer crash revokes consent without manufacturing native or input retirement", function()
		run(function(c)
			local view = c.start_load()
			local epoch, destroy = c.manager.current_epoch("changelog"), view.destroy
			local admitted, closes = false, 0
			c.state.input_capture_gate = { release = function() return admitted end }
			c.on_cancel = function() c.on_cancel = nil; closes = closes + 1 end
			view.destroy = function() return false end
			view.on_web_process_terminated()
			helpers.assert_eq(view.destroyed, nil)
			helpers.assert_nil(c.manager.capture_document_owner("changelog"))
			helpers.assert_eq(closes, 0)
			helpers.assert_eq(c.manager.current_epoch("changelog"), epoch)
			helpers.assert_eq(c.manager.show("changelog"), false)
			helpers.assert_eq(c.manager.shutdown(), false)
			helpers.assert_eq(closes, 0)
			view.destroy = destroy
			helpers.assert_eq(c.manager.hide("changelog", epoch), false)
			helpers.assert_true(view.destroyed)
			helpers.assert_eq(closes, 0, "crash cleanup still needs the original input ACK")
			admitted = true
			helpers.assert_true(c.manager.hide("changelog", epoch))
			helpers.assert_eq(closes, 1)
			c.state.input_capture_gate = nil
		end)
	end)

end)
