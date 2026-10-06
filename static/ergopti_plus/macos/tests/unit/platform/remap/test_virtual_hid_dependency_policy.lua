--- tests/unit/platform/remap/test_virtual_hid_dependency_policy.lua

--- Portable bound-fact decisions over real callback lifetimes; native ports remain absent.
local helpers = require("tests.helpers")
--- Models qualified receipts over real exact subscription frames; no native proof.
local function policy_fixture(options)
	options = options or {}
	local Policy = require("remap.virtual_hid_dependency_policy")
	local Lifetime = require("keylogger.physical_subscription_lifetime")
	local owner, reference, connection = {}, {}, {}
	local d = { bindings = {}, revisions = {}, queries = {}, refused = {}, effects = 0 }
	local sources = {}
	for _, name in ipairs({ "installed", "broker", "client", "intent" }) do
		local source_owner, token = {}, {}
		local life = Lifetime.new(source_owner, token)
		life.bind_detach(function()
			if d.detach_refused == name then return false end
			life.detach(); return true
		end)
		local scope = life.capability()
		local actual_current = scope.current
		scope.current = function(a, b)
			d.queries[#d.queries + 1] = name
			if options.current then options.current(name, d) end
			return actual_current(a, b)
		end
		local binding = { owner = source_owner, token = token, scope = scope, life = life }
		d.bindings[name], sources[name], d.revisions[name] = binding, binding, 0
	end
	d.policy = Policy.new(owner, sources, function(reason)
		d.refused[#d.refused + 1] = reason
		if options.refusal then options.refusal(d) end
	end)
	local values = {
		installed = { reference = reference, package_version = "8.5.0", driver_version = "1.8.0", client_protocol = 7,
			signature_valid = true, ordinary_root_owned = true, bundle_identity_valid = true, reference_qualified = true,
			extension_approved = true },
		broker = { reference = reference, connection = connection, connected = true,
			socket_peer_verified = true, dynamic_reference_valid = true },
		client = { connection = connection, stage = "status", driver_activated = true, driver_connected = true,
			driver_version_mismatched = false, keyboard_ready = true },
		intent = { mode = "owned", tap_hold = true, close_other_instances = true, runtime_pin_enabled = true,
			signed_exact_runtime = true, root_owned_install = true, owned_runtime_installable = true,
			owned_peer_bootstrap_complete = true, owned_peer_stream_qualified = true, foreign_grabber_active = false,
			stock_quit_requested = false, stock_quit_native_settled = true, cleanup_pending = false,
			second_vhid_job_planned = false },
	}
	function d.record(name, change)
		local record = { kind = name, revision = d.revisions[name] + 1, generation = 1 }
		for k, v in pairs(values[name]) do record[k] = v end
		if change then change(record) end
		return record
	end
	function d.send(name, record, token)
		record = record or d.record(name)
		local binding = d.bindings[name]
		local accepted, reason = binding.life.run(d.policy.receive, record, token or binding.token)
		if accepted == true then d.revisions[name] = record.revision end
		return accepted, reason
	end
	function d.ready()
		for _, name in ipairs({ "installed", "broker", "intent" }) do assert(d.send(name) == true) end
		assert(d.send("client", { kind = "client", revision = 1, generation = 1, connection = connection, stage = "connection" }) == true)
		assert(d.send("client", { kind = "client", revision = 2, generation = 1, connection = connection,
			stage = "initialize", initializer_issued = true }) == true)
		assert(d.send("client") == true)
	end
	function d.initialize(candidate_connection, generation)
		assert(d.send("client", { kind = "client", revision = d.revisions.client + 1, generation = generation or 1,
			connection = candidate_connection or connection, stage = "initialize", initializer_issued = true }) == true)
	end
	function d.retire()
		d.policy.stop()
		return d.policy.retired()
	end
	d.reference, d.connection, d.values = reference, connection, values
	return d
end

helpers.describe("virtual HID bound dependency classifications", function()
	helpers.it("starts unknown without constructing native commands or reading foreign sources", function()
		local d = policy_fixture()
		helpers.assert_eq(#d.queries, 0)
		helpers.assert_eq(d.policy.decision().state, "unverified-vhid-state")
		helpers.assert_eq(d.policy.install, nil); helpers.assert_eq(d.policy.confirm, nil)
		helpers.assert_eq(d.policy.start, nil); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("keeps shared and disabled TapHold inactive", function()
		for _, mutate in ipairs({ function(r) r.mode = "shared" end, function(r) r.tap_hold = false end }) do
			local d = policy_fixture(); d.ready()
			helpers.assert_eq(d.send("intent", d.record("intent", mutate)), true)
			helpers.assert_eq(d.policy.decision().state, "inactive"); helpers.assert_eq(d.policy.decision().admit, false)
			helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("never derives incompatibility from disconnected mismatchfalse", function()
		local d = policy_fixture(); d.ready()
		d.send("client", d.record("client", function(r) r.driver_connected = false end))
		helpers.assert_eq(d.policy.decision().state, "unverified-vhid-state"); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("explains a qualified connected mismatch without an installer capability", function()
		local d = policy_fixture(); d.ready()
		d.send("client", d.record("client", function(r) r.driver_version_mismatched = true end))
		local result = d.policy.decision()
		helpers.assert_eq(result.state, "incompatible-vhid"); helpers.assert_eq(result.reason, "incompatible-vhid")
		helpers.assert_eq(result.admit, false); helpers.assert_eq(type(result.detail), "string")
		helpers.assert_eq(d.policy.update, nil); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("distinguishes explicit approvalfalse from an unknown approval observation", function()
		for _, row in ipairs({ { value = false, state = "awaiting-extension-approval" }, { state = "unverified-vhid-state" } }) do
			local d = policy_fixture(); d.ready()
			d.send("installed", d.record("installed", function(r) r.extension_approved = row.value end))
			helpers.assert_eq(d.policy.decision().state, row.state); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("preserves a foreign grabber with closure disabled or already settled", function()
		for _, close in ipairs({ false, true }) do
			local d = policy_fixture(); d.ready()
			d.send("intent", d.record("intent", function(r)
				r.close_other_instances = close; r.foreign_grabber_active = true
				r.stock_quit_requested = close; r.stock_quit_native_settled = true
			end))
			helpers.assert_eq(d.policy.decision().state, "other-karabiner-active")
			helpers.assert_eq(d.policy.quit, nil); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("retains an actual requested stock closure with no settlement acknowledgement", function()
		local d = policy_fixture(); d.ready()
		d.send("intent", d.record("intent", function(r) r.stock_quit_requested = true; r.stock_quit_native_settled = false end))
		helpers.assert_eq(d.policy.decision().state, "cleanup-pending"); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("refuses a second shared VHD broker ownership plan", function()
		local d = policy_fixture(); d.ready()
		d.send("intent", d.record("intent", function(r) r.second_vhid_job_planned = true end))
		local result = d.policy.decision()
		helpers.assert_eq(result.state, "unverified-vhid-state")
		helpers.assert_eq(result.reason, "vhid-broker-ownership-unresolved"); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("requires every signed installed runtime and actual owned peer fact", function()
		for _, field in ipairs({ "runtime_pin_enabled", "signed_exact_runtime", "root_owned_install",
			"owned_runtime_installable", "owned_peer_bootstrap_complete", "owned_peer_stream_qualified" }) do
			local d = policy_fixture(); d.ready(); helpers.assert_eq(d.policy.decision().admit, true)
			d.send("intent", d.record("intent", function(r) r[field] = false end))
			helpers.assert_eq(d.policy.decision().state, "unverified-vhid-state"); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("never silently admits or downgrades an unqualified newer package or protocol", function()
		for _, mutate in ipairs({ function(r) r.package_version = "9.0.0" end,
			function(r) r.driver_version = "1.9.0" end, function(r) r.client_protocol = 8 end }) do
			local d = policy_fixture(); d.ready(); d.send("installed", d.record("installed", mutate))
			helpers.assert_eq(d.policy.decision().state, "unverified-vhid-state"); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("requires dynamic live reference and never substitutes verified static origin", function()
		for _, mutate in ipairs({ function(r) r.dynamic_reference_valid = nil end,
			function(r) r.dynamic_reference_valid = false end, function(r) r.socket_peer_verified = nil end,
			function(r) r.reference = {} end }) do
			local d = policy_fixture(); d.ready(); d.send("broker", d.record("broker", mutate))
			helpers.assert_eq(d.policy.decision().state, "unverified-vhid-state"); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("requires fresh operating facts and does not equate activation or empty ACK with readiness", function()
		for _, field in ipairs({ "keyboard_ready", "driver_activated", "driver_connected", "driver_version_mismatched" }) do
			local d = policy_fixture(); d.ready(); d.send("client", d.record("client", function(r) r[field] = nil end))
			helpers.assert_eq(d.policy.decision().state, "unverified-vhid-state"); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("copies accepted scalar facts before the native source mutates its record", function()
		local d = policy_fixture(); d.ready(); local receipt = d.record("client")
		helpers.assert_eq(d.send("client", receipt), true); receipt.keyboard_ready = false; receipt.generation = 90
		helpers.assert_eq(d.policy.decision().admit, true); helpers.assert_eq(d.retire(), true)
	end)
end)
helpers.describe("virtual HID policy exact lifecycle fences", function()
	helpers.it("permanently refuses gaps replay and source generation regression", function()
		for _, mutate in ipairs({ function(r) r.revision = r.revision + 1 end,
			function(r) r.revision = r.revision - 1 end, function(r) r.generation = 0 end }) do
			local d = policy_fixture(); d.ready()
			helpers.assert_eq(d.send("client", d.record("client", mutate)), false)
			helpers.assert_eq(d.policy.decision().admit, false); helpers.assert_eq(#d.refused, 1)
			helpers.assert_eq(d.send("client"), false); helpers.assert_eq(#d.refused, 1); helpers.assert_eq(d.retire(), true)
		end
	end)
	helpers.it("revokes reentry before the foreign current port can return positive facts", function()
		local armed = false
		local d = policy_fixture({ current = function(_, c)
			if armed then armed = false; c.policy.decision() end
		end }); d.ready(); armed = true
		helpers.assert_eq(d.policy.decision().admit, false); helpers.assert_eq(#d.refused, 1)
		helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("revokes a source that stops the policy inside a captured readonly current query", function()
		local armed = false
		local d = policy_fixture({ current = function(_, c)
			if armed then armed = false; c.policy.stop() end
		end }); d.ready(); armed = true
		helpers.assert_eq(d.policy.decision().admit, false); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("fails closed on a foreign getter exception without publishing its raw error", function()
		local armed, marker = false, {}
		local d = policy_fixture({ current = function() if armed then error(marker) end end }); d.ready(); armed = true
		local result = d.policy.decision()
		helpers.assert_eq(result.admit, false); helpers.assert_eq(#d.refused, 1)
		helpers.assert_eq(type(d.refused[1]), "string"); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("retains refused detach independently of other sources acknowledging retirement", function()
		local d = policy_fixture(); d.ready(); d.detach_refused = "broker"
		d.policy.stop(); helpers.assert_eq(d.policy.retired(), false)
		d.detach_refused = nil; helpers.assert_eq(d.policy.retired(), true)
	end)
end)

-- Independent frozen expectations retain their exact lexical body.
do
local it = helpers.it
-- Frozen software policy controls. Canonical lifetimes are real; no native identity proof.
local Policy = require("remap.virtual_hid_dependency_policy")
local Lifetime = require("keylogger.physical_subscription_lifetime")

local function vhd_fixture(callback)
    local owner, sources, life, scope, tokens = {}, {}, {}, {}, {}
    local reference, connection = {}, {}
    local queries = 0
    for _, kind in ipairs({ "installed", "broker", "client", "intent" }) do
        local source_owner, token = {}, {}
        local actual = Lifetime.new(source_owner, token)
        actual.bind_detach(function() actual.detach(); return true end)
        local cap = actual.capability()
        local original_current = cap.current
        cap.current = function(...)
            queries = queries + 1
            return original_current(...)
        end
        sources[kind] = { owner = source_owner, token = token, scope = cap }
        life[kind], scope[kind], tokens[kind] = actual, cap, token
    end
    local refused = 0
    local policy
    policy = assert(Policy.new(owner, sources, function(...)
        refused = refused + 1
        if callback then callback(policy, ...) end
    end))
    local function emit(kind, record)
        record.kind = kind
        return policy.receive(record, tokens[kind])
    end
    local function installed(revision)
        return emit("installed", { revision=revision or 1, generation=1, reference=reference,
            package_version="8.5.0", driver_version="1.8.0", client_protocol=7,
            signature_valid=true, ordinary_root_owned=true, bundle_identity_valid=true,
            reference_qualified=true, extension_approved=true })
    end
    local function broker(revision)
        return emit("broker", { revision=revision or 1, generation=1, reference=reference,
            connection=connection, connected=true, socket_peer_verified=true,
            dynamic_reference_valid=true })
    end
    local function client(stage, revision, overrides)
        local record={revision=revision,generation=1,connection=connection,stage=stage}
        if stage=="initialize" then record.initializer_issued=true end
        if stage=="status" then
            record.driver_activated=true;record.driver_connected=true
            record.driver_version_mismatched=false;record.keyboard_ready=true
        end
        if overrides then overrides(record) end
        return emit("client",record)
    end
    local function intent(revision)
        return emit("intent", { revision=revision or 1,generation=1,mode="owned",tap_hold=true,
            close_other_instances=false,runtime_pin_enabled=true,signed_exact_runtime=true,
            root_owned_install=true,owned_runtime_installable=true,owned_peer_bootstrap_complete=true,
            owned_peer_stream_qualified=true,foreign_grabber_active=false,stock_quit_requested=false,
            stock_quit_native_settled=false,cleanup_pending=false,second_vhid_job_planned=false })
    end
    local function ready()
        assert(installed()); assert(broker()); assert(client("connection",1))
        assert(client("initialize",2)); assert(client("status",3)); assert(intent())
    end
    return {policy=policy, owner=owner,sources=sources,life=life,scope=scope,tokens=tokens,
        reference=reference,connection=connection,emit=emit,installed=installed,broker=broker,
        client=client,intent=intent,ready=ready,queries=function() return queries end,
        refused=function() return refused end}
end

it("independent VHD policy constructor is dormant and genuine typed conjunction admits", function()
    local f=vhd_fixture(); assert(f.queries()==0); f.ready()
    local d=f.policy.decision(); assert(d.state=="ready" and d.admit==true)
    assert(f.refused()==0)
end)

it("independent VHD policy status before initializer cannot admit", function()
    local f=vhd_fixture(); assert(f.installed());assert(f.broker());assert(f.intent())
    assert(f.client("connection",1));assert(f.client("status",2))
    assert(f.policy.decision().admit==false)
    assert(f.client("initialize",3));assert(f.policy.decision().admit==false)
    assert(f.client("status",4));assert(f.policy.decision().admit==true)
end)

it("independent VHD policy a replacement connection needs its own initializer", function()
    local f=vhd_fixture(); f.ready(); assert(f.policy.decision().admit==true)
    local connection2={}
    assert(f.emit("broker",{revision=2,generation=1,reference=f.reference,connection=connection2,
        connected=true,socket_peer_verified=true,dynamic_reference_valid=true}))
    assert(f.client("connection",4,function(r) r.connection=connection2 end))
    assert(f.client("status",5,function(r) r.connection=connection2 end))
    assert(f.policy.decision().admit==false)
    assert(f.client("initialize",6,function(r) r.connection=connection2 end))
    assert(f.client("status",7,function(r) r.connection=connection2 end))
    assert(f.policy.decision().admit==true)
end)

it("independent VHD policy qualified mismatch blocks without performing update", function()
    local f=vhd_fixture(); f.ready()
    assert(f.client("status",4,function(r) r.driver_version_mismatched=true end))
    local d=f.policy.decision();assert(d.state=="incompatible-vhid" and d.admit==false)
    assert(type(d.detail)=="string" and #d.detail>0);assert(f.refused()==0)
end)

it("independent VHD policy unknown approval cannot be promoted by public decision mutation", function()
    local f=vhd_fixture();f.ready()
    assert(f.emit("installed",{revision=2,generation=1,reference=f.reference,
        package_version="8.5.0",driver_version="1.8.0",client_protocol=7,
        signature_valid=true,ordinary_root_owned=true,bundle_identity_valid=true,
        reference_qualified=true}))
    local d=f.policy.decision();assert(d.admit==false)
    d.state="ready";d.admit=true
    assert(f.policy.decision().admit==false and f.refused()==0)
end)

it("independent VHD policy malformed known scalar permanently revokes once", function()
    local f=vhd_fixture();f.ready()
    local ok=f.client("status",4,function(r) r.keyboard_ready="true" end)
    assert(ok==false);assert(f.refused()==1);assert(f.policy.decision().admit==false)
    assert(f.client("status",5)==false);assert(f.refused()==1)
end)

it("independent VHD policy does not accept mutable public scope aliases", function()
    local f=vhd_fixture();f.ready();assert(f.policy.decision().admit==true)
    f.scope.installed.current=function() return true end
    f.life.installed.revoke()
    assert(f.policy.decision().admit==false and f.refused()==1)
end)

it("independent VHD policy wrong exact token refuses with framed callback", function()
    local callback_seen=false
    local f=vhd_fixture(function(policy)
        callback_seen=true;assert(policy.retired()==false)
    end)
    f.ready()
    local ok=f.policy.receive({kind="client",revision=4,generation=1,stage="status",
        connection=f.connection,driver_activated=true,driver_connected=true,
        driver_version_mismatched=false,keyboard_ready=true},{})
    assert(ok==false);assert(callback_seen and f.refused()==1)
    assert(f.policy.decision().admit==false)
end)

it("independent VHD policy retirement waits actual canonical held source frame", function()
    local f=vhd_fixture();f.ready();local frame=assert(f.life.broker.enter())
    assert(f.policy.stop()==true);assert(f.policy.retired()==false)
    assert(f.life.broker.leave(frame)==true);assert(f.policy.retired()==true)
end)

it("independent VHD policy legitimate repeated status observations have no event-count exhaustion", function()
    local f=vhd_fixture();f.ready()
    for revision=4,600 do assert(f.client("status",revision)) end
    assert(f.policy.decision().state=="ready" and f.policy.decision().admit==true)
    assert(f.refused()==0)
end)

end

helpers.describe("virtual HID post-call and unknown ownership controls", function()
	helpers.it("keeps unknown second broker ownership denied rather than assuming none", function()
		local d = policy_fixture(); d.ready(); helpers.assert_eq(d.policy.decision().admit, true)
		d.send("intent", d.record("intent", function(r) r.second_vhid_job_planned = nil end))
		helpers.assert_eq(d.policy.decision().admit, false); helpers.assert_eq(d.retire(), true)
	end)
	helpers.it("checks true current again after a foreign port returns its old positive sample", function()
		local Policy = require("remap.virtual_hid_dependency_policy")
		local Lifetime = require("keylogger.physical_subscription_lifetime")
		local bindings, calls, armed, reference, connection = {}, 0, false, {}, {}
		for _, name in ipairs({ "installed", "broker", "client", "intent" }) do
			local owner, token = {}, {}
			local life = Lifetime.new(owner, token)
			life.bind_detach(function() life.detach(); return true end)
			local source = { owner = owner, token = token, scope = life.capability() }
			if name == "intent" then
				local actual = source.scope.current
				source.scope.current = function(...)
					local current = actual(...)
					if armed then calls = calls + 1; if calls == 2 then life.revoke() end end
					return current
				end
			end
			bindings[name] = source
		end
		local values = {
			installed = { reference = reference, package_version = "8.5.0", driver_version = "1.8.0", client_protocol = 7,
				signature_valid = true, ordinary_root_owned = true, bundle_identity_valid = true,
				reference_qualified = true, extension_approved = true },
			broker = { reference = reference, connection = connection, connected = true,
				socket_peer_verified = true, dynamic_reference_valid = true },
			intent = { mode = "owned", tap_hold = true, close_other_instances = false, runtime_pin_enabled = true,
				signed_exact_runtime = true, root_owned_install = true, owned_runtime_installable = true,
				owned_peer_bootstrap_complete = true, owned_peer_stream_qualified = true, foreign_grabber_active = false,
				stock_quit_requested = false, stock_quit_native_settled = false, cleanup_pending = false,
				second_vhid_job_planned = false },
			client = { connection = connection, stage = "status", driver_activated = true, driver_connected = true,
				driver_version_mismatched = false, keyboard_ready = true },
		}
		local refused = 0
		local p = Policy.new({}, bindings, function() refused = refused + 1 end)
		for _, kind in ipairs({ "installed", "broker", "intent" }) do
			local record = { kind = kind, revision = 1, generation = 1 }
			for k, v in pairs(values[kind]) do record[k] = v end
			helpers.assert_eq(p.receive(record, bindings[kind].token), true)
		end
		for revision, stage in ipairs({ "connection", "initialize", "status" }) do
			local record = { kind = "client", revision = revision, generation = 1, connection = connection, stage = stage }
			if stage == "initialize" then record.initializer_issued = true end
			if stage == "status" then for k, v in pairs(values.client) do record[k] = v end end
			helpers.assert_eq(p.receive(record, bindings.client.token), true)
		end
		helpers.assert_eq(p.decision().admit, true); armed = true
		helpers.assert_eq(p.decision().admit, false); helpers.assert_eq(refused, 1)
		p.stop(); helpers.assert_eq(p.retired(), true)
	end)
end)

helpers.describe("virtual HID exact source counter representation", function()
	helpers.it("preserves native integer generations while refusing unsafe double counters", function()
		local d = policy_fixture()
		local number_type = math.type
		if type(number_type) == "function" then
			local receipt = d.record("installed", function(r) r.generation = 9007199254740993 end)
			helpers.assert_eq(d.send("installed", receipt), true)
			local other = policy_fixture()
			helpers.assert_eq(other.send("installed", other.record("installed", function(r) r.generation = 9007199254740993.0 end)), false)
			helpers.assert_eq(other.retire(), true)
		else
			helpers.assert_eq(d.send("installed", d.record("installed", function(r) r.generation = 9007199254740992 end)), false)
		end
		helpers.assert_eq(d.retire(), true)
	end)
end)


do
local it = helpers.it
-- Frozen software policy controls. Canonical lifetimes are real; no native identity proof.
local Policy = require("remap.virtual_hid_dependency_policy")
local Lifetime = require("keylogger.physical_subscription_lifetime")

local function vhd_fixture(callback)
    local owner, sources, life, scope, tokens = {}, {}, {}, {}, {}
    local reference, connection = {}, {}
    local queries = 0
    for _, kind in ipairs({ "installed", "broker", "client", "intent" }) do
        local source_owner, token = {}, {}
        local actual = Lifetime.new(source_owner, token)
        actual.bind_detach(function() actual.detach(); return true end)
        local cap = actual.capability()
        local original_current = cap.current
        cap.current = function(...)
            queries = queries + 1
            return original_current(...)
        end
        sources[kind] = { owner = source_owner, token = token, scope = cap }
        life[kind], scope[kind], tokens[kind] = actual, cap, token
    end
    local refused = 0
    local policy
    policy = assert(Policy.new(owner, sources, function(...)
        refused = refused + 1
        if callback then callback(policy, ...) end
    end))
    local function emit(kind, record)
        record.kind = kind
        return policy.receive(record, tokens[kind])
    end
    local function installed(revision)
        return emit("installed", { revision=revision or 1, generation=1, reference=reference,
            package_version="8.5.0", driver_version="1.8.0", client_protocol=7,
            signature_valid=true, ordinary_root_owned=true, bundle_identity_valid=true,
            reference_qualified=true, extension_approved=true })
    end
    local function broker(revision)
        return emit("broker", { revision=revision or 1, generation=1, reference=reference,
            connection=connection, connected=true, socket_peer_verified=true,
            dynamic_reference_valid=true })
    end
    local function client(stage, revision, overrides)
        local record={revision=revision,generation=1,connection=connection,stage=stage}
        if stage=="initialize" then record.initializer_issued=true end
        if stage=="status" then
            record.driver_activated=true;record.driver_connected=true
            record.driver_version_mismatched=false;record.keyboard_ready=true
        end
        if overrides then overrides(record) end
        return emit("client",record)
    end
    local function intent(revision)
        return emit("intent", { revision=revision or 1,generation=1,mode="owned",tap_hold=true,
            close_other_instances=false,runtime_pin_enabled=true,signed_exact_runtime=true,
            root_owned_install=true,owned_runtime_installable=true,owned_peer_bootstrap_complete=true,
            owned_peer_stream_qualified=true,foreign_grabber_active=false,stock_quit_requested=false,
            stock_quit_native_settled=false,cleanup_pending=false,second_vhid_job_planned=false })
    end
    local function ready()
        assert(installed()); assert(broker()); assert(client("connection",1))
        assert(client("initialize",2)); assert(client("status",3)); assert(intent())
    end
    return {policy=policy, owner=owner,sources=sources,life=life,scope=scope,tokens=tokens,
        reference=reference,connection=connection,emit=emit,installed=installed,broker=broker,
        client=client,intent=intent,ready=ready,queries=function() return queries end,
        refused=function() return refused end}
end

it("independent refusal observer retains real callback and source frames outside protected calls", function()
    local inside, callbacks
    callbacks=0
    local f=vhd_fixture(function(policy)
        callbacks=callbacks+1
        inside=policy.retired()
    end)
    f.ready()
    local frame=assert(f.life.broker.enter())
    assert(f.policy.receive({kind="client",revision=4,generation=1,stage="status",
        connection=f.connection,driver_connected=true,driver_activated=true,
        driver_version_mismatched=false,keyboard_ready=true},{})==false)
    assert(callbacks==1 and inside==false)
    assert(f.policy.retired()==false)
    assert(f.life.broker.leave(frame)==true)
    assert(f.policy.retired()==true)
end)

it("independent retirement refuses a public alias while actual source frame remains held", function()
    local f=vhd_fixture();f.ready()
    local frame=assert(f.life.client.enter())
    f.scope.client.retired=function() return true end
    assert(f.policy.stop()==true)
    assert(f.policy.retired()==false)
    assert(f.life.client.leave(frame)==true)
    assert(f.policy.retired()==true)
end)

it("independent healthy ownership uses captured identity and current methods after alias replacement", function()
    local f=vhd_fixture();f.ready()
    f.scope.installed.identity=function() return {} end
    f.scope.installed.current=function() return false end
    local decision=f.policy.decision()
    assert(decision.state=="ready" and decision.admit==true and f.refused()==0)
    assert(f.policy.stop()==true and f.policy.retired()==true)
end)

it("independent stop inside an actual source frame denies until genuine frame retirement", function()
    local f=vhd_fixture();f.ready()
    local result_seen, inside_retired, callbacks= nil,nil,0
    local policy=f.policy
    -- A genuine call made from a retained source event is bounded by that lifetime.
    local outcome=f.life.intent.run(function()
        policy.stop()
        result_seen=policy.decision()
        inside_retired=policy.retired()
        callbacks=callbacks+1
    end)
    assert(result_seen.admit==false and callbacks==1 and inside_retired==false)
    assert(policy.retired()==true and f.refused()==0)
end)

it("independent actual foreign-source refusal retains its callback frame during operation", function()
    local observed, callbacks=nil,0
    local f=vhd_fixture(function(policy)
        observed=policy.retired()
        callbacks=callbacks+1
    end)
    f.ready()
    f.life.installed.revoke()
    local decision=f.policy.decision()
    assert(decision.admit==false and callbacks==1 and observed==false)
    assert(f.policy.retired()==true)
end)

end
