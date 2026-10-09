--- _shared/lua/test/document_lease_contract.lua

--- Independent causal controls for real document initialization lease logic.
--- Native ports are controlled; these do not qualify GTK, entropy or timer FFI.
local M = {}
function M.register(helpers)
	local Lease = require("webview.document_lease")
	local function fixture()
		local s = { now = 100, uri = "file:///", loading = false, live = true,
			reads = {}, challenges = {}, confirmations = {}, works = {}, nonce_serial = 0 }
		local owner
		local ports = {
			timeout_ms = 5000, uri = "file:///",
			clock = function() if s.on_clock then s.on_clock() end; return s.now end,
			current = function() if s.on_current then s.on_current() end; return s.live end,
			read_document = function() if s.on_read then s.on_read() end; return s.uri, s.loading end,
			nonce = function()
				s.nonce_serial = s.nonce_serial + 1
				if s.on_nonce then return s.on_nonce() end
				return string.rep("A", 20) .. string.format("%04d", s.nonce_serial)
			end,
			deadline = function(deadline, expire)
				local w = { started = true, settled = false, deadline = deadline, expire = expire, listeners = {}, cancellations = 0 }
				function w:is_settled() return self.settled end
				function w:on_settled(callback) self.listeners[#self.listeners + 1] = callback; return true end
				function w:cancel()
					self.cancellations = self.cancellations + 1
					if s.on_cancel then s.on_cancel() end
					return true
				end
				function w:ack_close()
					self.settled = true
					local callbacks = self.listeners; self.listeners = {}
					for _, callback in ipairs(callbacks) do callback() end
				end
				s.works[#s.works + 1] = w
				return w
			end,
			read_nonce = function(done) s.reads[#s.reads + 1] = done; return true end,
			challenge = function(generation, token, page_nonce)
				s.challenges[#s.challenges + 1] = { generation = generation, token = token, page_nonce = page_nonce }
				return true
			end,
			confirm = function(generation, token, page_nonce)
				s.confirmations[#s.confirmations + 1] = { generation = generation, token = token, page_nonce = page_nonce }
				if s.on_confirm then return s.on_confirm() end
				return true
			end,
		}
		owner = Lease.new(ports); s.owner, s.ports = owner, ports
		function s.challenge()
			helpers.assert_eq(owner.start_load(), true)
			helpers.assert_eq(owner.finished_load(), true)
			s.reads[#s.reads](string.rep("a", 36))
			return s.challenges[#s.challenges]
		end
		function s.ready()
			local metadata = s.challenge()
			helpers.assert_eq(owner.ack(metadata), true)
			s.works[#s.works]:ack_close()
			local lease = owner.admit(metadata, "ready")
			helpers.assert_eq(type(lease), "table")
			return metadata, lease
		end
		return s
	end
	helpers.describe("Actual document lease causal ownership", function()
		helpers.it("requires actual ACK, physical timer closure and fresh ready", function()
			local s = fixture(); local m = s.challenge()
			helpers.assert_eq(s.owner.admit(m, "install"), nil)
			helpers.assert_eq(s.owner.ack(m), true)
			helpers.assert_eq(#s.confirmations, 0)
			helpers.assert_eq(s.owner.admit(m, "ready"), nil)
			s.works[1]:ack_close(); helpers.assert_eq(#s.confirmations, 1)
			helpers.assert_eq(s.owner.admit(m, "install"), nil)
			helpers.assert_eq(type(s.owner.admit(m, "ready")), "table")
		end)
		helpers.it("rejects same-URI successor reuse of old actions and ACK", function()
			local s = fixture(); local m, lease = s.ready()
			helpers.assert_eq(s.owner.start_load(), true)
			helpers.assert_eq(s.owner.current(lease), false)
			helpers.assert_eq(s.owner.admit(m, "install"), nil)
			helpers.assert_eq(s.owner.ack(m), false)
		end)
		helpers.it("rejects old asynchronous nonce result after same-URI reload", function()
			local s = fixture(); s.owner.start_load(); s.owner.finished_load()
			local old_result = s.reads[1]; s.owner.start_load(); s.owner.finished_load()
			old_result(string.rep("a", 36)); helpers.assert_eq(#s.challenges, 0)
			s.reads[2](string.rep("b", 36)); helpers.assert_eq(#s.challenges, 1)
			helpers.assert_eq(s.challenges[1].page_nonce, string.rep("b", 36))
		end)
		helpers.it("rejects guessed challenge token without touching owned deadline", function()
			local s = fixture(); local m = s.challenge()
			helpers.assert_eq(s.owner.ack({ generation = m.generation, token = string.rep("Z", 24), page_nonce = m.page_nonce }), false)
			helpers.assert_eq(s.works[1].cancellations, 0)
		end)
		helpers.it("rejects wrong intrinsic page nonce", function()
			local s = fixture(); local m = s.challenge()
			helpers.assert_eq(s.owner.ack({ generation = m.generation, token = m.token, page_nonce = string.rep("b", 36) }), false)
			helpers.assert_eq(#s.confirmations, 0)
		end)
		helpers.it("retires missing ACK at the original deadline", function()
			local s = fixture(); local m = s.challenge(); s.now = 5100; s.owner.poll()
			helpers.assert_eq(s.owner.ack(m), false); helpers.assert_eq(s.owner.capture(), nil)
			helpers.assert_eq(s.works[1].cancellations, 1)
		end)
		helpers.it("rejects ACK after elapsed deadline even before timer dispatch", function()
			local s = fixture(); local m = s.challenge(); s.now = 5100
			helpers.assert_eq(s.owner.ack(m), false); helpers.assert_eq(#s.confirmations, 0)
		end)
		helpers.it("does not restart the budget while physical close is pending", function()
			local s = fixture(); local m = s.challenge(); s.now = 5099; s.owner.ack(m)
			s.now = 5100; s.works[1]:ack_close()
			helpers.assert_eq(#s.confirmations, 0); helpers.assert_eq(s.owner.admit(m, "ready"), nil)
		end)
		helpers.it("rejects late ready after confirmation without restarting budget", function()
			local s = fixture(); local m = s.challenge(); s.owner.ack(m); s.works[1]:ack_close()
			s.now = 5100; helpers.assert_eq(s.owner.admit(m, "ready"), nil)
		end)
		helpers.it("rejects late physical close after replacement without confirming successor", function()
			local s = fixture(); local m = s.challenge(); s.owner.ack(m)
			s.owner.start_load(); s.works[1]:ack_close()
			helpers.assert_eq(#s.confirmations, 0); helpers.assert_eq(s.owner.capture(), nil)
		end)
		helpers.it("fences reentrant load replacement during actual native document read", function()
			local s = fixture(); local m, lease = s.ready()
			s.on_read = function() s.on_read = nil; s.owner.start_load() end
			helpers.assert_eq(s.owner.current(lease), false)
			helpers.assert_eq(s.owner.admit(m, "install"), nil)
		end)
		helpers.it("retirement precedes reentrant cancellation and never revives closed owner", function()
			local s = fixture(); local m = s.challenge(); local replacement
			s.on_cancel = function() replacement = s.owner.start_load() end
			helpers.assert_eq(s.owner.close(), false)
			helpers.assert_eq(replacement, false); helpers.assert_eq(s.owner.ack(m), false)
			helpers.assert_eq(s.owner.is_settled(), false)
			s.works[1]:ack_close(); helpers.assert_eq(s.owner.is_settled(), true)
		end)
		helpers.it("keeps cleanup debt until actual native close ACK", function()
			local s = fixture(); s.challenge(); local notified = 0
			s.owner.on_settled(function() notified = notified + 1 end)
			s.owner.close(); helpers.assert_eq(notified, 0)
			s.works[1]:ack_close(); helpers.assert_eq(notified, 1)
		end)
		helpers.it("refuses reused native entropy without borrowing previous consent", function()
			local s = fixture()
		s.on_nonce = function() return string.rep("A", 24) end
			s.ready(); helpers.assert_eq(s.owner.start_load(), false)
			helpers.assert_eq(s.owner.capture(), nil)
		end)
		helpers.it("refuses missing native entropy and malformed page nonce", function()
			local s = fixture()
		s.on_nonce = function() return nil end
			helpers.assert_eq(s.owner.start_load(), false)
			local t = fixture(); t.owner.start_load(); t.owner.finished_load(); t.reads[1]("not a page nonce")
			helpers.assert_eq(#t.challenges, 0); helpers.assert_eq(t.owner.capture(), nil)
		end)
		helpers.it("refuses foreign URI, loading or lost actual window ownership", function()
			for _, mutation in ipairs({ function(s) s.uri = "https://foreign.invalid/" end,
				function(s) s.loading = true end, function(s) s.live = false end }) do
				local s = fixture(); local m, lease = s.ready(); mutation(s)
				helpers.assert_eq(s.owner.current(lease), false); helpers.assert_eq(s.owner.admit(m, "retry"), nil)
			end
		end)
		helpers.it("rejects fractional, unbounded and nonfinite timeout policy", function()
			for _, value in ipairs({ 0, -1, 0.5, 2147483648, math.huge }) do
				local s = fixture(); s.ports.timeout_ms = value
				helpers.assert_eq(pcall(Lease.new, s.ports), false)
			end
		end)
		helpers.it("rejects negative-clock drift before admitting ACK", function()
			local s = fixture(); local m = s.challenge(); s.now = 99
			helpers.assert_eq(s.owner.ack(m), false); helpers.assert_eq(#s.confirmations, 0)
		end)
	end)
end
return M
