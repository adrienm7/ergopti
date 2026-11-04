--- tests/unit/adapters/synthetic_input/test_loopback_release_ownership.lua

--- ==============================================================================
--- MODULE: Loopback Native Release Ownership
--- DESCRIPTION:
--- Drives the actual loopback emitter and provenance ledger through native-post
--- boundaries modeled by the existing Quartz fixture. A possible Down owns its
--- Up until acknowledgement and exact timer retirement, without claiming native
--- physical keyboard execution from these portable observations.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")
require("logger")

local function with_loopback(callback, options, prepare)
	helpers.with_stub_scope({ "adapters.synthetic_input", "adapters.event_provenance", "adapters.storage",
		"adapters.timer_scheduler", "adapters.json_codec", "infra.logger", "infra.paths", "infra.timings",
		"infra.toml.reader", "json", "toml_codec.basic_string", "toml_codec.bom", "toml_codec.key_path",
		"toml_codec.reader", "toml_codec.record_scanner", "adapters.synthetic_input_loopback_owner" }, function()
		local f = Fixture.make(options)
		if prepare then prepare(f) end
		local input, provenance = f.load()
		f.input, f.provenance = input, provenance
		f.tx = input.begin("unit.loopback-release", "action")
		f.completions = 0
		input.on_complete(f.tx, function(_, status) f.completions = f.completions + 1; f.status = status end)
		f.emit = function()
			local accepted = input.emit_loopback_key_stroke({}, "f16", 0, f.tx)
			input.seal(f.tx)
			return accepted
		end
		f.drain = function()
			for _ = 1, 64 do
				if #f.timers == 0 then return end
				f.fire_next_timer()
			end
			error("loopback timers did not settle")
		end
		callback(f)
	end)
end

local function phases(f, down)
	local count = 0
	for _, event in ipairs(f.key_attempts) do if event.isDown == down then count = count + 1 end end
	return count
end

helpers.describe("loopback release survives uncertain native handoff", function()
	helpers.it("keeps healthy global echo and both native provenance phases", function()
		with_loopback(function(f)
			local observed = {}
			f.key_observer = function(event)
				local consumer = event.isDown and "keymap" or "keymap.loopback_keyup"
				local meta = f.provenance.classify(event, consumer)
				observed[#observed + 1] = { owned = meta and meta.owned, loopback = meta and meta.loopback,
					phase = meta and meta.phase, complete = f.tx.completed }
			end
			helpers.assert_true(f.emit())
			f.drain()
			helpers.assert_eq(phases(f, true), 1)
			helpers.assert_eq(phases(f, false), 1)
			helpers.assert_eq(observed, {
				{ owned = true, loopback = true, phase = "down", complete = false },
				{ owned = true, loopback = true, phase = "up", complete = false },
			})
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "complete")
		end)
	end)

	helpers.it("releases Up after an observed Down post raises without replaying Down", function()
		with_loopback(function(f)
			f.key_observer = function(event)
				if event.isDown then error("native Down post raised after its side effect") end
			end
			helpers.assert_true(f.emit())
			f.drain()
			helpers.assert_eq(phases(f, true), 1)
			helpers.assert_eq(phases(f, false), 1, "a possible native Down keeps its release obligation")
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "failed")
			helpers.assert_eq(f.input.stats().active_transactions, 0)
		end)
	end)

	helpers.it("keeps transaction and Up provenance live across cancellation after Down", function()
		with_loopback(function(f)
			local during, up
			f.key_observer = function(event)
				if event.isDown then
					local cancelled = f.input.cancel(f.tx)
					during = { cancelled = cancelled, completed = f.tx.completed, posts = f.key_posts }
				else up = f.provenance.classify(event, "keymap.loopback_keyup") end
			end
			helpers.assert_true(f.emit())
			f.drain()
			helpers.assert_eq(during, { cancelled = false, completed = false, posts = 1 })
			helpers.assert_true(up and up.loopback and up.enriched,
				"the compensating native Up remains the exact owned loopback phase")
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "cancelled")
		end)
	end)

	helpers.it("retains native Up past the ordinary retry budget", function()
		with_loopback(function(f)
			local refuse = true
			f.key_observer = function(event)
				if not event.isDown and refuse then error("native Up remains uncertain") end
			end
			helpers.assert_true(f.emit())
			for _ = 1, 32 do
				if #f.timers == 0 then break end
				f.fire_next_timer()
				if phases(f, false) > f.input.SERIAL_POST_MAX_ATTEMPTS then break end
			end
			helpers.assert_true(phases(f, false) > f.input.SERIAL_POST_MAX_ATTEMPTS)
			helpers.assert_eq(phases(f, true), 1)
			helpers.assert_eq(f.completions, 0)
			helpers.assert_eq(f.input.stats().active_transactions, 1)
			refuse = false
			f.drain()
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "failed")
			helpers.assert_eq(phases(f, true), 1)
		end)
	end)

	helpers.it("cancels a still-queued loopback at the physical fence without posting", function()
		with_loopback(function(f)
			helpers.assert_true(f.emit())
			local fence = f.input.claim_physical_fence()
			helpers.assert_eq(fence.cancelled_loopbacks, 1)
			helpers.assert_eq(f.input.stats().pending_loopbacks, 0)
			helpers.assert_eq(f.input.stats().records, 0, "cancelled queued pins are retired before the next tick")
			f.drain()
			helpers.assert_eq(f.key_posts, 0)
			helpers.assert_eq(f.input.stats().records, 0)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "cancelled")
		end)
	end)

	helpers.it("waits for exact timer stop acknowledgement after native Up", function()
		with_loopback(function(f)
			helpers.assert_true(f.emit())
			f.fire_next_timer()
			helpers.assert_eq(f.key_posts, 2)
			helpers.assert_eq(f.completions, 0)
			helpers.assert_eq(f.input.stats().active_transactions, 1)
			f.drain()
			helpers.assert_eq(f.key_posts, 2, "cleanup delivery must not replay either phase")
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "complete")
		end, { timer_stop_failures = 2 })
	end)

	helpers.it("does not cancel a handed-off echo at a later physical fence", function()
		with_loopback(function(f)
			local fence, up
			f.key_observer = function(event)
				if event.isDown then fence = f.input.claim_physical_fence()
				else up = f.provenance.classify(event, "keymap.loopback_keyup") end
			end
			helpers.assert_true(f.emit())
			f.drain()
			helpers.assert_nil(fence, "a handed-off loopback is no longer a cancellable queued echo")
			helpers.assert_true(up and up.loopback and up.enriched)
			helpers.assert_eq(f.key_posts, 2)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "complete")
		end)
	end)

	helpers.it("does not finish a refused timer start before its native cleanup", function()
		with_loopback(function(f)
			helpers.assert_eq(f.emit(), false)
			helpers.assert_eq(f.key_posts, 0)
			helpers.assert_eq(f.completions, 0)
			helpers.assert_eq(f.input.stats().active_transactions, 1)
			f.drain()
			helpers.assert_eq(f.key_posts, 0)
			helpers.assert_eq(f.input.stats().records, 0)
			helpers.assert_eq(f.input.stats().active_transactions, 0)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "cancelled")
		end, { timer_start_mode = "false", timer_stop_failures = 3 })
	end)

	helpers.it("never replays an uncertain Down that throws before its observed effect", function()
		with_loopback(function(f)
			helpers.assert_true(f.emit())
			f.drain()
			helpers.assert_eq(phases(f, true), 1)
			helpers.assert_eq(phases(f, false), 1)
			helpers.assert_eq(f.key_posts, 1, "only the compensating Up has an observed effect")
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "failed")
		end, { key_post_throw_at = 1 })
	end)

	helpers.it("does not recursively post Up before a reentrant Down returns", function()
		with_loopback(function(f)
			helpers.assert_true(f.emit())
			local owner_tick = f.timers[1].callback
			local original = f.tx.batches[1].events[1].post
			local sequence = {}
			f.tx.batches[1].events[1].post = function(event)
				owner_tick()
				sequence[#sequence + 1] = "down"
				return original(event)
			end
			f.key_observer = function(event)
				if not event.isDown then
					owner_tick()
					sequence[#sequence + 1] = "up"
				end
			end
			f.drain()
			helpers.assert_eq(sequence, { "down", "up" })
			helpers.assert_eq(f.key_posts, 2)
			helpers.assert_eq(f.completions, 1)
		end)
	end)

	helpers.it("cancels an untouched sibling while retaining a handed-off loopback", function()
		with_loopback(function(f)
			local sibling = f.input.begin_batch(f.tx)
			f.input.keyStroke(sibling, {}, "x")
			local during
			f.key_observer = function(event)
				if event.isDown then
					f.input.cancel(f.tx)
					during = { sibling = sibling.status, complete = f.tx.completed,
						records = f.input.stats().records }
				end
			end
			helpers.assert_true(f.emit())
			f.drain()
			helpers.assert_eq(during, { sibling = "cancelled", complete = false, records = 2 })
			helpers.assert_eq(f.key_posts, 2)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "cancelled")
		end)
	end)

	helpers.it("retires late constructor tags after reentrant cancellation without native posts", function()
		with_loopback(function(f)
			helpers.assert_throws(f.emit)
			f.drain()
			helpers.assert_eq(f.key_posts, 0)
			helpers.assert_eq(f.input.stats().records, 0)
			helpers.assert_eq(f.input.stats().active_transactions, 0)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "cancelled")
		end, nil, function(f)
			local native = f.hs_overrides.eventtap.event.newKeyEvent
			f.hs_overrides.eventtap.event.newKeyEvent = function(...)
				f.input.cancel(f.tx)
				return native(...)
			end
		end)
	end)

	helpers.it("does not admit a cancelled pair after native timer start reenters", function()
		with_loopback(function(f)
			helpers.assert_eq(f.emit(), false)
			helpers.assert_eq(f.completions, 0)
			f.drain()
			helpers.assert_eq(f.key_posts, 0)
			helpers.assert_eq(f.input.stats().records, 0)
			helpers.assert_eq(f.input.stats().active_transactions, 0)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "cancelled")
		end, { timer_stop_failures = 2 }, function(f)
			local construct = f.hs_overrides.timer.new
			f.hs_overrides.timer.new = function(...)
				local handle = construct(...)
				local start = handle.start
				handle.start = function(self)
					f.input.cancel(f.tx)
					return start(self)
				end
				return handle
			end
		end)
	end)

	helpers.it("keeps cached owner factories isolated across SyntheticInput reloads", function()
		with_loopback(function(f)
			helpers.assert_true(f.emit())
			local factory = package.loaded["adapters.synthetic_input_loopback_owner"]
			local next_world = Fixture.make()
			local next_input = next_world.load()
			local next_scheduler, next_logger = package.loaded["adapters.timer_scheduler"],
				package.loaded["infra.logger"]
			helpers.assert_true(next_input.emit_loopback_key_stroke({}, "f16", 0))
			helpers.assert_true(package.loaded["adapters.synthetic_input_loopback_owner"] == factory)
			f.drain()
			helpers.assert_eq(f.key_posts, 2)
			helpers.assert_eq(next_world.key_posts, 0)
			for _ = 1, 16 do
				if #next_world.timers == 0 then break end
				next_world.fire_next_timer()
			end
			helpers.assert_eq(next_world.key_posts, 2)
			helpers.assert_eq(next_input.stats().active_transactions, 0)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_true(package.loaded["adapters.timer_scheduler"] == next_scheduler)
			helpers.assert_true(package.loaded["infra.logger"] == next_logger)
		end)
	end)

	helpers.it("retries only Up when both native phase outcomes were uncertain", function()
		with_loopback(function(f)
			local up_attempts = 0
			f.key_observer = function(event)
				if event.isDown then error("native Down post raised after its effect") end
				up_attempts = up_attempts + 1
				if up_attempts == 1 then error("native Up post raised after its effect") end
			end
			helpers.assert_true(f.emit())
			f.drain()
			helpers.assert_eq(phases(f, true), 1)
			helpers.assert_eq(phases(f, false), 2)
			helpers.assert_eq(f.completions, 1)
			helpers.assert_eq(f.status, "failed")
		end)
	end)

	helpers.it("retains explicit uncertainty when a broken scheduler diagnostic hides its handle", function()
		with_loopback(function(f)
			local original = f.logger.error
			f.logger.error = function(_, format, ...)
				if format:find("cancel():", 1, true) then error("deliberately broken logger hook") end
				return original(_, format, ...)
			end
			helpers.assert_throws(f.emit)
			helpers.assert_true(f.tx.batches[1].loopback_owner.admission_uncertain)
			helpers.assert_true(f.tx.failure:find("deliberately broken logger hook", 1, true) ~= nil)
			f.logger.error = original
			f.drain()
			helpers.assert_eq(f.key_posts, 0)
			helpers.assert_eq(f.input.stats().records, 0)
			helpers.assert_eq(f.input.stats().active_transactions, 1,
				"native cleanup without an exposed exact handle cannot certify this owner's terminal")
			helpers.assert_eq(f.completions, 0)
		end, { timer_start_mode = "false", timer_stop_failures = 1 })
	end)
end)
