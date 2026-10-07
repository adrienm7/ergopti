--- tests/unit/platform/remap/test_virtual_hid_update_consent.lua

--- Real dependency/Lifetime composition; target, retirement and replacement ports are modeled.
local helpers = require("tests.helpers")
local function fixture(options)
	options = options or {}
	local Consent = require("remap.virtual_hid_update_consent")
	local Lifetime = require("keylogger.physical_subscription_lifetime")
	local d = { owner = {}, sources = {}, revisions = {}, queries = 0, effects = 0, retire_calls = 0,
		replace_ack = true, retire_ack = true, reference = {}, connection = {} }
	for _, name in ipairs({ "installed", "broker", "client", "intent", "target", "effect" }) do
		local owner, token = {}, {}
		local life = Lifetime.new(owner, token)
		life.bind_detach(function()
			if d.detach_refused == name then return false end
			life.detach(); return true
		end)
		local scope = life.capability()
		local exact_identity, exact_current = scope.identity, scope.current
		scope.identity = function(a)
			d.queries = d.queries + 1
			if d.identity_callback then d.identity_callback(name, d) end
			if name == "target" and d.target_replaced then return {} end
			return exact_identity(a)
		end
		scope.current = function(a, b)
			d.queries = d.queries + 1
			if d.current_callback then d.current_callback(name, d) end
			return exact_current(a, b)
		end
		local binding = { owner = owner, token = token, scope = scope, life = life }
		if name == "target" or name == "effect" then d[name] = binding else
			d.sources[name], d.revisions[name] = binding, 0
		end
	end
	d.effect.scope.retire = function(...)
		d.retire_calls = d.retire_calls + 1; d.retire_arguments = { ... }
		if d.retire_callback then d.retire_callback(d) end
		if options.pending_retire then
			d.retirement_nonce, d.retirement_callback = d.retire_arguments[9], d.retire_arguments[10]
			if options.sync_retirement then
				d.effects_before_port_return = d.effects
				d.retirement_callback(d.effect.owner, d.effect.token, d.retirement_nonce, true, true)
				d.effects_inside_completion = d.effects
			end
			if options.throw_handoff then error({}) end
			if options.bad_handoff then return false end
			return "pending", options.wrong_nonce and {} or d.retirement_nonce
		end
		return d.retire_ack
	end
	d.effect.scope.replace = function(...)
		d.effects = d.effects + 1; d.effect_arguments = { ... }
		if d.effect_callback then d.effect_callback(d) end
		local acknowledgement = d.replace_ack
		if options.after_replace_ack then options.after_replace_ack(d, acknowledgement) end
		if options.pending_replace then
			d.replacement_nonce, d.replacement_callback = d.effect_arguments[9], d.effect_arguments[10]
			return "pending", d.replacement_nonce
		end
		return acknowledgement
	end
	d.policy = Consent.new(d.owner, d.sources, d.target, d.effect)
	d.values = {
		installed = { reference = d.reference, package_version = "8.5.0", driver_version = "1.8.0", client_protocol = 7,
			signature_valid = true, ordinary_root_owned = true, bundle_identity_valid = true, reference_qualified = true,
			extension_approved = true },
		broker = { reference = d.reference, connection = d.connection, connected = true,
			socket_peer_verified = true, dynamic_reference_valid = true },
		client = { connection = d.connection, stage = "status", driver_activated = true, driver_connected = true,
			driver_version_mismatched = true, keyboard_ready = false },
		intent = { mode = "owned", tap_hold = true, close_other_instances = true, runtime_pin_enabled = true,
			signed_exact_runtime = true, root_owned_install = true, owned_runtime_installable = true,
			owned_peer_bootstrap_complete = true, owned_peer_stream_qualified = true, foreign_grabber_active = false,
			stock_quit_requested = false, stock_quit_native_settled = true, cleanup_pending = false,
			second_vhid_job_planned = false },
	}
	function d.record(name, change)
		local record = { kind = name, revision = d.revisions[name] + 1, generation = 1 }
		for key, value in pairs(d.values[name]) do record[key] = value end
		if change then change(record) end
		return record
	end
	function d.send(name, record)
		record = record or d.record(name)
		local accepted = d.sources[name].life.run(d.policy.receive, record, d.sources[name].token)
		if accepted == true then d.revisions[name] = record.revision end
		return accepted
	end
	function d.mismatch()
		for _, name in ipairs({ "installed", "broker", "intent" }) do helpers.assert_eq(d.send(name), true) end
		helpers.assert_eq(d.send("client"), true)
	end
	function d.offer() return d.policy.offer(d.owner) end
	function d.confirm(token, value) return d.policy.confirm(d.owner, token, value) end
	function d.complete(kind, completed, accepted, owner, token, nonce)
		return d[kind .. "_callback"](owner or d.effect.owner, token or d.effect.token,
			nonce or d[kind .. "_nonce"], completed, accepted)
	end
	function d.retire() d.policy.stop(); return d.policy.retired() end
	return d
end

helpers.describe("confirmed virtual HID replacement policy", function()
	helpers.it("constructs without querying sources or starting update work", function()
		local d = fixture(); helpers.assert_eq(d.queries, 0); helpers.assert_eq(d.effects, 0)
		helpers.assert_eq(d.policy.status().admit, false); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("unknown observations mint no offer and invoke no retirement or replacement", function()
		local d = fixture(); helpers.assert_eq(d.offer(), nil)
		helpers.assert_eq(d.retire_calls, 0); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("unverified references and unsupported versions are never called mismatches", function()
		for _, change in ipairs({ function(r) r.reference_qualified = false end,
			function(r) r.package_version = "8.6.0" end, function(r) r.signature_valid = false end,
			function(r) r.extension_approved = false end }) do
			local d = fixture(); d.mismatch(); d.send("installed", d.record("installed", change))
			helpers.assert_eq(d.offer(), nil); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("compatible readiness has no automatic update or user offer", function()
		local d = fixture(); d.mismatch()
		d.send("client", { kind = "client", revision = 2, generation = 1, stage = "initialize", connection = d.connection, initializer_issued = true })
		d.send("client", d.record("client", function(r) r.driver_version_mismatched = false; r.keyboard_ready = true end))
		helpers.assert_eq(d.offer(), nil); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("shared mode and TapHold off cannot offer replacement", function()
		for _, change in ipairs({ function(r) r.mode = "shared" end, function(r) r.tap_hold = false end }) do
			local d = fixture(); d.mismatch(); d.send("intent", d.record("intent", change))
			helpers.assert_eq(d.offer(), nil); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("one current mismatch mints one opaque offer with zero effects", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		helpers.assert_eq(type(offer), "table"); helpers.assert_eq(d.offer(), nil)
		helpers.assert_eq(d.retire_calls, 0); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("only literal true confirms and every other response consumes without effects", function()
		for _, value in ipairs({ false, "true", 1, {} }) do
			local d = fixture(); d.mismatch(); local offer = d.offer()
			helpers.assert_eq(d.confirm(offer, value), false); helpers.assert_eq(d.confirm(offer, true), false)
			helpers.assert_eq(d.retire_calls, 0); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
		local d = fixture(); d.mismatch(); local offer = d.offer()
		helpers.assert_eq(d.confirm(offer, nil), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("closing a user offer grants zero download installer or Manager effects", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		helpers.assert_eq(d.policy.close(d.owner, offer), false); helpers.assert_eq(d.confirm(offer, true), false)
		helpers.assert_eq(d.retire_calls, 0); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("wrong owner and wrong token have zero queries and cannot spend the real offer", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); local before = d.queries
		helpers.assert_eq(d.policy.confirm({}, offer, true), false); helpers.assert_eq(d.confirm({}, true), false)
		helpers.assert_eq(d.queries, before); helpers.assert_eq(d.confirm(offer, true), true)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("confirmation retires before one fixed effect and never returns ready", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); local retirement_before_effect
		d.effect_callback = function(x) retirement_before_effect = x.retire_calls end
		local accepted, reason = d.confirm(offer, true)
		helpers.assert_eq(accepted, true); helpers.assert_eq(reason, "requalification-pending")
		helpers.assert_eq(retirement_before_effect, 1); helpers.assert_eq(d.effects, 1)
		helpers.assert_eq(d.policy.status().state, "requalification-pending"); helpers.assert_eq(d.policy.status().admit, false)
		helpers.assert_eq(d.effect_arguments[1], d.effect.owner); helpers.assert_eq(d.effect_arguments[2], d.effect.token)
		helpers.assert_eq(d.effect_arguments[3], d.target.owner); helpers.assert_eq(d.effect_arguments[4], d.target.token)
		helpers.assert_eq(d.effect_arguments[5], offer); helpers.assert_eq(d.retire_arguments[6], d.sources.intent.owner)
		helpers.assert_eq(d.retire_arguments[7], d.sources.intent.token); helpers.assert_eq(d.retire_arguments[8], 1)
		helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("duplicate literal confirmations cannot execute a second effect", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		helpers.assert_eq(d.confirm(offer, true), true); helpers.assert_eq(d.confirm(offer, true), false)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.retire_calls, 1); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("every accepted source revision expires an offer even if values are unchanged", function()
		for _, name in ipairs({ "installed", "broker", "client", "intent" }) do
			local d = fixture(); d.mismatch(); local offer = d.offer(); helpers.assert_eq(d.send(name), true)
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0)
			helpers.assert_eq(d.retire_calls, 0); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("a new runtime intent generation requires a fresh diagnosis and user offer", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		d.send("intent", d.record("intent", function(r) r.generation = 2 end))
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("new installed reference and broker connection identities expire consent", function()
		for _, name in ipairs({ "installed", "broker" }) do
			local d = fixture(); d.mismatch(); local offer = d.offer()
			d.send(name, d.record(name, function(r) if name == "installed" then r.reference = {} else r.connection = {} end end))
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("revoked original observation sources grant zero effects", function()
		for _, name in ipairs({ "installed", "broker", "client", "intent" }) do
			local d = fixture(); d.mismatch(); local offer = d.offer(); d.sources[name].life.revoke()
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("revoked verified target and fixed effect owners cannot grant work", function()
		for _, name in ipairs({ "target", "effect" }) do
			local d = fixture(); d.mismatch(); local offer = d.offer(); d[name].life.revoke()
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.retire_calls, 0)
			helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("retirement requires literal true before any replacement effect", function()
		for _, value in ipairs({ false, 1, "true", {} }) do
			local d = fixture(); d.mismatch(); local offer = d.offer(); d.retire_ack = value
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
		local d = fixture(); d.mismatch(); local offer = d.offer(); d.retire_ack = nil
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("a throwing retirement port refuses and does not reach the installer", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		d.retire_callback = function() error({ private = "not a public reason" }) end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("a source receipt during retirement is reentrant and prevents replacement", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); local accepted
		d.retire_callback = function(x) accepted = x.send("intent") end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(accepted, false)
		helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("source revocation inside retirement is fenced before the effect port", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		d.retire_callback = function(x) x.sources.installed.life.revoke() end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("target replacement during retirement refuses before package effects", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		d.retire_callback = function(x) x.target_replaced = true end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("reentrant confirmation during retirement consumes no extra effect", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); local nested
		d.retire_callback = function(x) nested = x.confirm(offer, true) end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(nested, false)
		helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("effect callback reentry refuses the outcome and cannot replay the one use", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); local nested
		d.effect_callback = function(x) nested = x.confirm(offer, true) end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(nested, false)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.policy.status().admit, false); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("stop during the effect retains callback debt until actual unwind", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); local inside
		d.effect_callback = function(x) x.policy.stop(); inside = x.policy.retired() end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(inside, false)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.policy.retired(), true)
	end)
	helpers.it("false and throwing installer acknowledgements are never readiness", function()
		for _, throwing in ipairs({ false, true }) do
			local d = fixture(); d.mismatch(); local offer = d.offer(); d.replace_ack = false
			if throwing then d.effect_callback = function() error({}) end end
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 1)
			helpers.assert_eq(d.policy.status().admit, false); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("mutable public capability aliases cannot revive revoked target authority", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); d.target.life.revoke()
		d.target.scope.current = function() return true end
		d.effect.scope.replace = function() d.effects = d.effects + 100; return true end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("offer contents are opaque and cannot change the held revision", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); d.send("intent")
		offer.revision = d.revisions.intent; offer.confirmed = true; offer.target = d.target.token
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("records are copied before source queries can mutate the caller table", function()
		local d = fixture(); d.mismatch(); local record = d.record("client")
		d.current_callback = function() record.driver_version_mismatched = false end
		helpers.assert_eq(d.send("client", record), true); d.current_callback = nil
		helpers.assert_eq(type(d.offer()), "table"); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("refused source detach keeps actual dependency retirement pending", function()
		local d = fixture(); d.mismatch(); local offer = d.offer(); d.detach_refused = "broker"
		d.policy.stop(); helpers.assert_eq(d.policy.retired(), false)
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0)
		d.detach_refused = nil; helpers.assert_eq(d.policy.retired(), true)
	end)
	helpers.it("a real source callback frame prevents an early complete retirement", function()
		local d = fixture(); d.mismatch(); local inside
		d.sources.client.life.run(function() d.policy.stop(); inside = d.policy.retired() end)
		helpers.assert_eq(inside, false); helpers.assert_eq(d.policy.retired(), true); helpers.assert_eq(d.effects, 0)
	end)
end)

helpers.describe("confirmed replacement native phase and asynchronous handoff", function()
	helpers.it("planned exact broker and client retirement permits one fixed replacement", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		d.retire_callback = function(x)
			for _, name in ipairs({ "broker", "client" }) do
				local b = x.sources[name]; b.scope.detach(b.owner, b.token)
			end
		end
		helpers.assert_eq(d.confirm(offer, true), true); helpers.assert_eq(d.effects, 1)
		helpers.assert_eq(d.policy.status().state, "requalification-pending"); helpers.assert_eq(d.policy.status().admit, false)
		helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("revocation without genuine original subscription retirement does not permit replacement", function()
		local d = fixture(); d.mismatch(); local offer = d.offer()
		d.retire_callback = function(x) x.sources.broker.life.revoke(); x.sources.client.life.revoke() end
		helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("installed reference invalidation after exact replacement ACK is pending requalification", function()
		local d = fixture({ after_replace_ack = function(x, accepted)
			if accepted == true then x.sources.installed.life.revoke() end
		end }); d.mismatch(); local offer = d.offer()
		helpers.assert_eq(d.confirm(offer, true), true); helpers.assert_eq(d.effects, 1)
		helpers.assert_eq(d.policy.status().state, "requalification-pending"); helpers.assert_eq(d.policy.status().admit, false)
		helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("unrelated intent revocation after replacement ACK grants no acceptance", function()
		local d = fixture({ after_replace_ack = function(x) x.sources.intent.life.revoke() end })
		d.mismatch(); local offer = d.offer(); helpers.assert_eq(d.confirm(offer, true), false)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.policy.status().admit, false); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("accepted asynchronous retirement is a pending request until physical completion", function()
		local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer()
		local accepted, reason = d.confirm(offer, true)
		helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "retirement-pending"); helpers.assert_eq(d.effects, 0)
		helpers.assert_eq(d.complete("retirement", true, true), true); helpers.assert_eq(d.effects, 1)
		helpers.assert_eq(d.policy.status().state, "requalification-pending"); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("wrong completion identities have zero queries and cannot release pending debt", function()
		local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); d.confirm(offer, true)
		local before = d.queries
		helpers.assert_eq(d.complete("retirement", true, true, {}), false)
		helpers.assert_eq(d.complete("retirement", true, true, nil, {}), false)
		helpers.assert_eq(d.complete("retirement", true, true, nil, nil, {}), false)
		helpers.assert_eq(d.queries, before); d.policy.stop(); helpers.assert_eq(d.policy.retired(), false)
		helpers.assert_eq(d.complete("retirement", true, true), true); helpers.assert_eq(d.effects, 0)
		helpers.assert_eq(d.policy.retired(), true)
	end)
	helpers.it("a pending operation survives stop and refuses logical completion as physical ACK", function()
		local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); d.confirm(offer, true)
		d.policy.stop(); helpers.assert_eq(d.policy.retired(), false)
		helpers.assert_eq(d.complete("retirement", false, true), false); helpers.assert_eq(d.policy.retired(), false)
		helpers.assert_eq(d.complete("retirement", true, true), true)
		helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.policy.retired(), true)
	end)
	helpers.it("genuine terminal retirement with failed outcome releases debt but never installs", function()
		local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); d.confirm(offer, true)
		helpers.assert_eq(d.complete("retirement", true, false), true); helpers.assert_eq(d.effects, 0)
		helpers.assert_eq(d.policy.status().admit, false); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("synchronous completion waits for exact pending handoff and foreign return", function()
		local d = fixture({ pending_retire = true, sync_retirement = true }); d.mismatch(); local offer = d.offer()
		helpers.assert_eq(d.confirm(offer, true), true)
		helpers.assert_eq(d.effects_before_port_return, 0); helpers.assert_eq(d.effects_inside_completion, 0)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("false and nonmatching handoffs cannot be revived by buffered or late completion", function()
		for _, options in ipairs({ { pending_retire = true, sync_retirement = true, bad_handoff = true },
			{ pending_retire = true, wrong_nonce = true } }) do
			local d = fixture(options); d.mismatch(); local offer = d.offer()
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(d.effects, 0)
			helpers.assert_eq(d.complete("retirement", true, true), false); helpers.assert_eq(d.effects, 0)
			helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("target expiry during asynchronous retirement cannot reach replacement", function()
		local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); d.confirm(offer, true)
		d.target.life.revoke(); helpers.assert_eq(d.complete("retirement", true, true), true)
		helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.policy.status().admit, false); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("installer handoff remains pending and requires genuine closure separate from outcome", function()
		local d = fixture({ pending_replace = true }); d.mismatch(); local offer = d.offer()
		local accepted, reason = d.confirm(offer, true)
		helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "replacement-pending"); helpers.assert_eq(d.effects, 1)
		helpers.assert_eq(d.complete("replacement", false, true), false)
		helpers.assert_eq(d.complete("replacement", true, false), true)
		helpers.assert_eq(d.policy.status().admit, false); helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("completed retirement nonce cannot be reused for a successor installer phase", function()
		local d = fixture({ pending_retire = true, pending_replace = true }); d.mismatch(); local offer = d.offer()
		d.confirm(offer, true); helpers.assert_eq(d.complete("retirement", true, true), true)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.complete("retirement", true, true), false)
		d.policy.stop(); helpers.assert_eq(d.policy.retired(), false)
		helpers.assert_eq(d.complete("replacement", true, true), true)
		helpers.assert_eq(d.effects, 1); helpers.assert_eq(d.policy.retired(), true)
	end)
end)

helpers.describe("planned original connection closure", function()
	helpers.it("same-generation close observations during pending retirement do not reopen consent", function()
		local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); d.confirm(offer, true)
		helpers.assert_eq(d.send("broker", d.record("broker", function(r) r.connected = false end)), true)
		helpers.assert_eq(d.send("client", d.record("client", function(r) r.driver_connected = false end)), true)
		helpers.assert_eq(d.complete("retirement", true, true), true); helpers.assert_eq(d.effects, 1)
		helpers.assert_eq(d.policy.status().state, "requalification-pending"); helpers.assert_eq(d.policy.status().admit, false)
		helpers.assert_eq(d.retire(), true)
	end)
end)

helpers.describe("completion callback ownership boundaries", function()
	helpers.it("stop or confirmation reentry during retirement completion cannot invoke replacement", function()
		for _, reentry in ipairs({ false, true }) do
			local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); d.confirm(offer, true)
			local inside, nested, called = nil, nil, false
			d.current_callback = function(name, x)
				if name == "effect" and not called then
					called = true
					if reentry then nested = x.confirm(offer, true) else x.policy.stop() end
					inside = x.policy.retired()
				end
			end
			helpers.assert_eq(d.complete("retirement", true, true), true)
			helpers.assert_eq(called, true); helpers.assert_eq(inside, false)
			if reentry then helpers.assert_eq(nested, false) end
			helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.policy.status().admit, false)
			helpers.assert_eq(d.policy.retired(), true)
		end
	end)
	helpers.it("buffered completion cannot survive throwing or mismatched pending handoff", function()
		for _, options in ipairs({ { pending_retire = true, sync_retirement = true, throw_handoff = true },
			{ pending_retire = true, sync_retirement = true, wrong_nonce = true } }) do
			local d = fixture(options); d.mismatch(); local offer = d.offer()
			helpers.assert_eq(d.confirm(offer, true), false)
			helpers.assert_eq(d.effects_inside_completion, 0); helpers.assert_eq(d.effects, 0)
			helpers.assert_eq(d.complete("retirement", true, true), false)
			helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("broker and client receipts inside retirement invocation are busy refusals", function()
		for _, name in ipairs({ "broker", "client" }) do
			local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); local nested
			d.retire_callback = function(x)
				nested = x.send(name, x.record(name, function(r)
					if name == "broker" then r.connected = false else r.driver_connected = false end
				end))
			end
			helpers.assert_eq(d.confirm(offer, true), false); helpers.assert_eq(nested, false)
			helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.policy.retired(), false)
			helpers.assert_eq(d.complete("retirement", true, true), true)
			helpers.assert_eq(d.effects, 0); helpers.assert_eq(d.policy.retired(), true)
		end
	end)
	helpers.it("wrong successor settlement cannot release replacement debt inside retirement completion", function()
		local d = fixture({ pending_retire = true, pending_replace = true }); d.mismatch(); local offer = d.offer()
		d.confirm(offer, true); local inside, duplicate
		d.effect_callback = function(x)
			x.policy.stop(); inside = x.policy.retired()
			duplicate = x.complete("retirement", true, true)
		end
		helpers.assert_eq(d.complete("retirement", true, true), true)
		helpers.assert_eq(inside, false); helpers.assert_eq(duplicate, false); helpers.assert_eq(d.effects, 1)
		helpers.assert_eq(d.policy.retired(), false)
		helpers.assert_eq(d.complete("replacement", true, true, nil, nil, d.retirement_nonce), false)
		helpers.assert_eq(d.policy.retired(), false)
		helpers.assert_eq(d.complete("replacement", true, true), true); helpers.assert_eq(d.policy.retired(), true)
	end)
	helpers.it("exact completion reentry from effect identity refuses progression and preserves unwind debt", function()
		local d = fixture({ pending_retire = true }); d.mismatch(); local offer = d.offer(); d.confirm(offer, true)
		local entered, nested, inside = false, nil, nil
		d.identity_callback = function(name, x)
			if name == "effect" and not entered then
				entered = true; nested = x.complete("retirement", true, true); inside = x.policy.retired()
			end
		end
		local ok, receipt = pcall(d.complete, "retirement", true, true)
		helpers.assert_eq(ok, true); helpers.assert_eq(receipt, true); helpers.assert_eq(nested, false)
		helpers.assert_eq(inside, false); helpers.assert_eq(d.effects, 0)
		helpers.assert_eq(d.policy.retired(), true)
	end)
end)
