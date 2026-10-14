--- tests/unit/modules/keylogger/test_physical_lifecycle_conjunction.lua

--- Independent aggregate facts controls; ports are modeled unless explicitly actual.
local helpers = require("tests.helpers")
local function module() return require("keylogger.physical_lifecycle_conjunction") end
local function record(domain, revision, source, stage)
	local r = { kind = "physical_lifecycle", domain = domain, revision = revision, at = revision * 10,
		source = source, stage = stage or "boundary", fields_complete = false, complete = false, allowed = false }
	if r.stage == "complete" then
		r.fields_complete, r.complete, r.enabled, r.paused = true, true, true, false
		if domain == "engine" then r.runtime_generation = 1
		else r.hardware_committed, r.hardware_generation, r.context_refresh_generation = true, 1, 1 end
	end
	return r
end
local function setup(capacity, receive, refusal)
	local sources, calls = {}, {}
	for _, domain in ipairs({ "engine", "system" }) do
		local owner, token = {}, {}; local scope = { available = true, done = false, detached = false }
		calls[domain] = { current = 0, detach = 0, retired = 0 }
		function scope.identity(exact) if rawequal(exact, owner) then return token end end
		function scope.current(exact, observed)
			calls[domain].current = calls[domain].current + 1
			return rawequal(exact, owner) and rawequal(observed, token) and scope.available and not scope.detached
		end
		function scope.detach(exact, observed)
			calls[domain].detach = calls[domain].detach + 1
			if not rawequal(exact, owner) or not rawequal(observed, token) then return false end
			scope.detached = true; return true
		end
		function scope.retired(exact, observed)
			calls[domain].retired = calls[domain].retired + 1
			return rawequal(exact, owner) and rawequal(observed, token) and scope.detached and scope.done
		end
		sources[domain] = { owner = owner, token = token, scope = scope }
	end
	local output = {}; local denied = 0
	local o = module().new(sources, capacity or 20, receive or function(facts) output[#output + 1] = facts; return true end,
		refusal or function() denied = denied + 1 end)
	local function send(domain, r)
		local s = sources[domain]; return o.accept(domain, s.owner, s.token, r)
	end
	return o, sources, send, output, calls, function() return denied end
end

helpers.describe("two-source lifecycle facts and exact retirement", function()
	helpers.it("does no foreign work during construction", function()
		local _, _, _, _, calls = setup()
		helpers.assert_eq(calls.engine.current, 0); helpers.assert_eq(calls.system.current, 0)
	end)
	helpers.it("keeps independent revisions and initial posture unknown", function()
		local _, _, send, output = setup()
		helpers.assert_eq(send("engine", record("engine", 1, "binding")), true)
		helpers.assert_eq(send("system", record("system", 1, "binding")), true)
		local facts = output[2]; helpers.assert_eq(facts.kind, "physical_lifecycle_facts")
		helpers.assert_eq(facts.engine.revision, 1); helpers.assert_eq(facts.system.revision, 1)
		helpers.assert_eq(facts.allowed, nil); helpers.assert_eq(facts.at, nil)
		for _, name in ipairs({ "system_awake", "screen_awake", "unlocked" }) do
			helpers.assert_eq(facts.posture[name].qualification, "unknown"); helpers.assert_eq(facts.posture[name].value, nil)
		end
	end)
	helpers.it("retains writer completion without promoting permission", function()
		local _, _, send, output = setup()
		send("engine", record("engine", 1, "start")); helpers.assert_eq(send("engine", record("engine", 2, "start", "complete")), true)
		helpers.assert_eq(output[2].engine.writer_complete, true); helpers.assert_eq(output[2].engine.paused, false)
		helpers.assert_eq(output[2].allowed, nil); helpers.assert_eq(output[2].system.writer_complete, false)
	end)
	helpers.it("records one completed native notification as observed-only evidence", function()
		local _, _, send, output = setup()
		local first = record("system", 1, "unlock"); first.event, first.component, first.value = 11, "unlocked", true
		local last = record("system", 2, "unlock", "complete"); last.event, last.component, last.value = 11, "unlocked", true
		send("system", first); helpers.assert_eq(send("system", last), true)
		helpers.assert_eq(output[2].posture.unlocked.qualification, "observed_only")
		helpers.assert_eq(output[2].posture.unlocked.value, true)
		helpers.assert_eq(output[2].posture.unlocked.observed_at, 20)
		helpers.assert_eq(output[2].posture.screen_awake.qualification, "unknown")
	end)
	helpers.it("hardware start never infers initial posture", function()
		local _, _, send, output = setup()
		send("system", record("system", 1, "hardware_start")); send("system", record("system", 2, "hardware_start", "complete"))
		helpers.assert_eq(output[2].system.hardware_committed, true)
		helpers.assert_eq(output[2].posture.unlocked.qualification, "unknown")
	end)
	helpers.it("unknown incomplete fields stay unknown", function()
		local _, _, send, output = setup()
		send("engine", record("engine", 1, "stop")); send("engine", record("engine", 2, "stop", "incomplete"))
		helpers.assert_eq(output[2].engine.writer_complete, false); helpers.assert_eq(output[2].engine.paused, nil)
	end)
	helpers.it("rejects a completion without its exact source boundary", function()
		local _, _, send = setup(); helpers.assert_eq(send("engine", record("engine", 1, "start", "complete")), false)
	end)
	helpers.it("rejects a wrong owner before querying foreign sources", function()
		local o, sources, _, _, calls = setup()
		helpers.assert_eq(o.accept("engine", {}, sources.engine.token, record("engine", 1, "binding")), false)
		helpers.assert_eq(calls.engine.current, 0)
	end)
	helpers.it("rejects a stale callback token", function()
		local o, sources = setup(); helpers.assert_eq(o.accept("engine", sources.engine.owner, {}, record("engine", 1, "binding")), false)
	end)
	helpers.it("refuses a source replacement before notification", function()
		local o, sources, send, _, _, refusals = setup(); sources.system.scope.available = false
		helpers.assert_eq(send("engine", record("engine", 1, "binding")), false); helpers.assert_eq(refusals(), 1)
		helpers.assert_eq(o.accept("engine", sources.engine.owner, sources.engine.token, record("engine", 2, "start")), false)
	end)
	helpers.it("rejects revision gaps without rebuilding a prefix", function()
		local _, _, send = setup(); helpers.assert_eq(send("engine", record("engine", 2, "binding")), false)
	end)
	helpers.it("does not mutate aliased input or retain aliased outputs", function()
		local _, _, send, output = setup(); local first = record("engine", 1, "start")
		send("engine", first); first.source = "shutdown"; output[1].engine.source = "forged"
		helpers.assert_eq(send("engine", record("engine", 2, "start", "complete")), true)
		helpers.assert_eq(output[2].engine.source, "start")
	end)
	helpers.it("rejects source records claiming permission", function()
		local _, _, send = setup(); local r = record("engine", 1, "binding"); r.allowed = true
		helpers.assert_eq(send("engine", r), false)
	end)
	helpers.it("source capacity exhaustion is terminal", function()
		local _, _, send, output = setup(1)
		send("engine", record("engine", 1, "binding")); helpers.assert_eq(send("engine", record("engine", 2, "start")), false)
		helpers.assert_eq(#output, 1)
	end)
	helpers.it("checks publication revocation outside protected receiver", function()
		local sources, observed; local o, s, send = setup(20, function() sources.system.scope.available = false; observed = true; return true end)
		sources = s; helpers.assert_eq(send("engine", record("engine", 1, "binding")), false); helpers.assert_eq(observed, true)
		helpers.assert_eq(o.retired(), false)
	end)
	helpers.it("makes receiver reentry terminal before its nested notification", function()
		local o, send, nested, count; local outputs = 0
		o, _, send = setup(20, function() outputs = outputs + 1; nested = send("system", record("system", 1, "binding")); return true end,
			function() count = (count or 0) + 1 end)
		helpers.assert_eq(send("engine", record("engine", 1, "binding")), false)
		helpers.assert_eq(nested, false); helpers.assert_eq(count, 1); helpers.assert_eq(outputs, 1)
	end)
	helpers.it("retains both exact retirement obligations after stop", function()
		local o, sources = setup(); helpers.assert_eq(o.stop(), true); helpers.assert_eq(o.detach(), true)
		sources.engine.scope.done = true; helpers.assert_eq(o.retired(), false)
		sources.system.scope.done = true; helpers.assert_eq(o.retired(), true)
	end)
	helpers.it("captures actual source methods before public table mutation", function()
		local o, sources = setup()
		for _, s in pairs(sources) do s.scope.current = function() return true end; s.scope.retired = function() return true end; s.scope.detach = function() return true end end
		sources.engine.scope.available = false
		helpers.assert_eq(o.accept("engine", sources.engine.owner, sources.engine.token, record("engine", 1, "binding")), false)
		o.stop(); helpers.assert_eq(o.detach(), true); helpers.assert_eq(o.retired(), false)
	end)
	helpers.it("does not credit retirement reentry hidden in a foreign port", function()
		local o, sources, _, _, _, _ = setup(); local nested
		-- Replace BEFORE constructing a second owner so it captures this real test port.
		local original = sources.engine.scope.retired
		sources.engine.scope.retired = function(...) nested = o.retired(); return original(...) end
		o = module().new(sources, 20, function() return true end, function() end)
		o.stop(); o.detach(); sources.engine.scope.done, sources.system.scope.done = true, true
		helpers.assert_eq(o.retired(), false); helpers.assert_eq(nested, false)
	end)
end)

helpers.describe("source-derived conjunction boundary controls", function()
	helpers.it("retains observed-only independent notification prefixes", function()
		local _, _, send, output = setup(); local revision = 0
		for _, fact in ipairs({ { "system_wake", 0, "system_awake" }, { "screens_wake", 4, "screen_awake" }, { "unlock", 11, "unlocked" } }) do
			for _, stage in ipairs({ "boundary", "complete" }) do
				revision = revision + 1; local r = record("system", revision, fact[1], stage)
				r.event, r.component, r.value = fact[2], fact[3], true; send("system", r)
			end
		end
		for _, name in ipairs({ "system_awake", "screen_awake", "unlocked" }) do
			helpers.assert_eq(output[6].posture[name].qualification, "observed_only")
		end
		helpers.assert_eq(output[6].allowed, nil)
	end)
	helpers.it("invalidates older notification evidence on hardware generation replacement", function()
		local _, _, send, output = setup()
		for revision = 1, 2 do
			local r = record("system", revision, "unlock", revision == 1 and "boundary" or "complete")
			r.event, r.component, r.value = 11, "unlocked", true; send("system", r)
		end
		for revision = 3, 4 do
			local r = record("system", revision, "system_wake", revision == 3 and "boundary" or "complete")
			r.event, r.component, r.value = 0, "system_awake", true
			if revision == 4 then r.hardware_generation = 2 end
			send("system", r)
		end
		helpers.assert_eq(output[4].posture.unlocked.qualification, "unknown")
		helpers.assert_eq(output[4].posture.system_awake.qualification, "observed_only")
	end)
	helpers.it("refusal notification retains its own source frame debt", function()
		local o, sources, nested, observed
		o, sources = setup(20, nil, function()
			for _, s in pairs(sources) do s.scope.detach(s.owner, s.token); s.scope.done = true end
			nested = o.retired(); observed = true
		end)
		helpers.assert_eq(o.accept("engine", {}, sources.engine.token, record("engine", 1, "binding")), false)
		helpers.assert_eq(observed, true); helpers.assert_eq(nested, false)
		helpers.assert_eq(o.retired(), true)
	end)
	helpers.it("copies actual input fields before foreign current checks", function()
		local _, sources = setup(); local incoming = record("engine", 1, "start")
		local original = sources.system.scope.current
		sources.system.scope.current = function(...) incoming.source = "shutdown"; return original(...) end
		local output = {}; local o = module().new(sources, 20, function(f) output[#output + 1] = f; return true end, function() end)
		helpers.assert_eq(o.accept("engine", sources.engine.owner, sources.engine.token, incoming), true)
		helpers.assert_eq(output[1].engine.source, "start")
		helpers.assert_eq(o.accept("engine", sources.engine.owner, sources.engine.token, record("engine", 2, "start", "complete")), true)
	end)
	helpers.it("routes exact actual shared actor receipts and waits for writer unwinding", function()
		local Actor = require("keylogger.physical_lifecycle_observation")
		local source, actors, bootstrap, revisions = {}, {}, {}, 0
		for _, domain in ipairs({ "engine", "system" }) do
			local actor = Actor.new(domain, function() revisions = revisions + 1; return revisions end, function() end)
			local owner = {}; local token, _, scope = actor.bind(owner, 20, function(r, exact)
				bootstrap[#bootstrap + 1] = { domain = domain, record = r, token = exact }; return true
			end)
			actors[domain] = actor; source[domain] = { owner = owner, token = token, scope = scope }
		end
		local output = {}; local o = module().new(source, 20, function(f) output[#output + 1] = f; return true end, function() end)
		for _, b in ipairs(bootstrap) do helpers.assert_eq(o.accept(b.domain, source[b.domain].owner, b.token, b.record), true) end
		helpers.assert_eq(#output, 2); o.stop(); helpers.assert_eq(o.detach(), true); helpers.assert_eq(o.retired(), true)
	end)
end)

helpers.describe("actual shared lifecycle source-frame integration", function()
	helpers.it("waits for the actual source writer after in-writer detach", function()
		local Actor = require("keylogger.physical_lifecycle_observation")
		local sources, actors, queue, now, conjunction = {}, {}, {}, 0, nil
		for _, domain in ipairs({ "engine", "system" }) do
			local source_owner = {}; local actor = Actor.new(domain, function() now = now + 1; return now end, function() end)
			local token, _, scope = actor.bind(source_owner, 20, function(r, exact)
				if conjunction then return conjunction.accept(domain, source_owner, exact, r) end
				queue[#queue + 1] = { domain = domain, record = r, token = exact }; return true
			end)
			actors[domain] = actor; sources[domain] = { owner = source_owner, token = token, scope = scope }
		end
		conjunction = module().new(sources, 20, function() return true end, function() end)
		for _, b in ipairs(queue) do helpers.assert_eq(conjunction.accept(b.domain, sources[b.domain].owner, b.token, b.record), true) end
		local detached, inside_retired
		local result = actors.engine.run("start", function()
			conjunction.stop(); detached = conjunction.detach(); inside_retired = conjunction.retired(); return true
		end, function() error("Detached source cannot poll snapshot") end)
		helpers.assert_eq(result, true); helpers.assert_eq(detached, true); helpers.assert_eq(inside_retired, false)
		helpers.assert_eq(conjunction.retired(), true)
	end)
end)

helpers.describe("independent actor-prefix and callback fences", function()
	helpers.it("rejects an intervening source revision gap after valid bootstrap", function()
		local _, _, send = setup(); helpers.assert_eq(send("engine", record("engine", 1, "binding")), true)
		helpers.assert_eq(send("engine", record("engine", 3, "start")), false)
	end)
	helpers.it("requires the captured source identity even when a current port says true", function()
		local _, sources = setup(); sources.engine.scope.identity = function() return {} end
		local o = module().new(sources, 20, function() return true end, function() end)
		helpers.assert_eq(o.accept("engine", sources.engine.owner, sources.engine.token, record("engine", 1, "binding")), false)
	end)
	helpers.it("revokes reentry from a foreign current port before publication", function()
		local _, sources = setup(); local o, nested, published = nil, nil, 0
		local original = sources.engine.scope.current
		sources.engine.scope.current = function(...)
			nested = o.accept("system", sources.system.owner, sources.system.token, record("system", 1, "binding"))
			return original(...)
		end
		o = module().new(sources, 20, function() published = published + 1; return true end, function() end)
		helpers.assert_eq(o.accept("engine", sources.engine.owner, sources.engine.token, record("engine", 1, "binding")), false)
		helpers.assert_eq(nested, false); helpers.assert_eq(published, 0)
	end)
end)
