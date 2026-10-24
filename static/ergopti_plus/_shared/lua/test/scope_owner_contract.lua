--- _shared/lua/test/scope_owner_contract.lua

--- ==============================================================================
--- MODULE: Scope Owner Protocol Contract
--- DESCRIPTION:
--- Pins the one scope-field protocol every macOS and Linux runtime owner
--- installs (scope_owner.lua) against a modelled owner, and checks that each
--- driver's real owners publish the shared methods rather than a retyped copy.
--- ==============================================================================

local M = {}
local ScopeOwner = require("scope_owner")

local SUBJECT = "tests.virtual.scope_owner_subject"
local METHODS = { "scope_acquire", "scope_release", "scope_capture", "scope_apply", "scope_restore", "scope_forget" }

--- Builds one modelled owner: a published value, a stable field and hooks.
--- @return table subject Module table registered under SUBJECT.
--- @return table world Mutable state and hook switches.
local function build()
	local subject = {}
	local world = { value = "a", stable = 1, ready = true, live = true, refuse = false, throw_after = false }
	world.scope = ScopeOwner.new({ name = SUBJECT, module = subject })
	world.scope.install({
		state = function() return { value = world.value, stable = world.stable } end,
		stable = { "stable" },
		published = { "value" },
		ready = function() return world.ready end,
		live = function() return world.live end,
		accept = function(value)
			if value ~= "a" and value ~= "b" then return nil end
			return { value = value }
		end,
		publish = function(target)
			if world.on_publish then world.on_publish() end
			if world.refuse then error("modelled native refusal") end
			world.value = target.value
			if world.throw_after then error("modelled interrupted acknowledgement") end
		end,
	})
	return subject, world
end

--- Runs body with the modelled owner loaded, restoring package.loaded after.
--- @param body function Receives subject, world and a token factory.
local function with_subject(body)
	local previous = package.loaded[SUBJECT]
	local subject, world = build()
	package.loaded[SUBJECT] = subject
	local function token(pending)
		return { pending = function() return pending == true end }
	end
	local ok, failure = xpcall(body, debug.traceback, subject, world, token)
	package.loaded[SUBJECT] = previous
	if not ok then error(failure, 0) end
end

--- Registers the protocol vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	helpers.describe("shared scope owner protocol (scope-owner-protocol)", function()
		helpers.it("refuses an invalid declaration and a second install", function()
			helpers.assert_throws(function() ScopeOwner.new({ name = "", module = {} }) end, "empty name")
			helpers.assert_throws(function() ScopeOwner.new({ name = SUBJECT }) end, "missing module")
			helpers.assert_throws(function() ScopeOwner.new({ name = SUBJECT, module = {}, extra = true }) end,
				"unknown option")
			local function install(spec)
				return function() ScopeOwner.new({ name = SUBJECT, module = {} }).install(spec) end
			end
			local function base()
				return { state = function() return {} end, published = { "value" },
					accept = function() return nil end, publish = function() end }
			end
			helpers.assert_throws(install({ state = function() return {} end, published = { "value" },
				accept = function() end }), "missing publish")
			local empty = base(); empty.published = {}
			helpers.assert_throws(install(empty), "nothing published")
			local reserved = base(); reserved.stable = { "module" }
			helpers.assert_throws(install(reserved), "the module field is the protocol's")
			local twice = base(); twice.stable = { "value" }
			helpers.assert_throws(install(twice), "a field declared twice")
			local unknown = base(); unknown.extra = true
			helpers.assert_throws(install(unknown), "unknown spec field")
			local scope = ScopeOwner.new({ name = SUBJECT, module = {} })
			scope.install(base())
			helpers.assert_throws(function() scope.install(base()) end, "second install")
			helpers.assert_throws(function()
				ScopeOwner.new({ name = SUBJECT, module = { scope_acquire = function() end } }).install(base())
			end, "a module that already defines a scope method")
		end)

		helpers.it("admits one token at a time and releases only after its compensation settles", function()
			with_subject(function(subject, world, token)
				helpers.assert_eq(subject.scope_acquire("token"), false, "a non-table token")
				helpers.assert_eq(subject.scope_acquire({}), false, "a token without pending()")
				local busy, owner, other = token(true), token(false), token(false)
				helpers.assert_eq(subject.scope_acquire(busy), true)
				helpers.assert_eq(world.scope.idle(), false)
				helpers.assert_eq(subject.scope_acquire(other), false, "one holder at a time")
				helpers.assert_eq(subject.scope_release(other), false, "a foreign release")
				helpers.assert_eq(subject.scope_release(busy), false, "pending compensation keeps the claim")
				busy.pending = function() return false end
				helpers.assert_eq(subject.scope_release(busy), true)
				helpers.assert_eq(world.scope.idle(), true)
				world.ready = false
				helpers.assert_eq(subject.scope_acquire(owner), false, "ready() gates acquisition")
				world.ready = true
				helpers.assert_eq(subject.scope_acquire(owner), true)
				world.ready = false
				helpers.assert_type(subject.scope_capture(owner), "table", "ready() gates acquisition only")
			end)
		end)

		helpers.it("refuses an ordinary change while held and invalidates older receipts", function()
			with_subject(function(subject, world, token)
				local owner = token(false)
				local generation = world.scope.generation()
				helpers.assert_eq(world.scope.admit_change(), true)
				helpers.assert_eq(world.scope.generation(), generation + 1)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				helpers.assert_eq(world.scope.admit_change(), false, "held by a transaction")
				local receipt = subject.scope_capture(owner)
				helpers.assert_eq(subject.scope_release(owner), true)
				helpers.assert_eq(world.scope.admit_change(), true)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				helpers.assert_eq(subject.scope_apply(owner, receipt, "b"), false, "a receipt older than a change")
				helpers.assert_eq(world.value, "a")
			end)
		end)

		helpers.it("applies once, refuses an undeclared value and restores the captured value", function()
			with_subject(function(subject, world, token)
				local owner = token(false)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				local receipt = subject.scope_capture(owner)
				helpers.assert_type(receipt, "table")
				helpers.assert_eq(subject.scope_capture(token(false)), nil, "a foreign capture")
				helpers.assert_eq(subject.scope_apply(owner, receipt, "z"), false, "an undeclared value")
				helpers.assert_eq(subject.scope_apply(owner, {}, "b"), false, "a forged receipt")
				helpers.assert_eq(subject.scope_apply(owner, receipt, "b"), true)
				helpers.assert_eq(world.value, "b")
				helpers.assert_eq(subject.scope_apply(owner, receipt, "a"), false, "one apply per receipt")
				helpers.assert_eq(subject.scope_release(owner), true)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				helpers.assert_eq(subject.scope_restore(owner, receipt), true)
				helpers.assert_eq(world.value, "a")
				helpers.assert_eq(subject.scope_restore(owner, receipt), true, "a restored receipt stays restored")
			end)
		end)

		helpers.it("restores only while undeclared fields are exactly as captured", function()
			with_subject(function(subject, world, token)
				local owner = token(false)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				local receipt = subject.scope_capture(owner)
				helpers.assert_eq(subject.scope_apply(owner, receipt, "b"), true)
				world.stable = 2
				helpers.assert_eq(subject.scope_restore(owner, receipt), false, "a stable field moved")
				helpers.assert_eq(world.value, "b")
				world.stable = 1
				world.value = "c"
				helpers.assert_eq(subject.scope_restore(owner, receipt), false, "a third-party value")
				world.value = "b"
				helpers.assert_eq(subject.scope_restore(owner, receipt), true)
				helpers.assert_eq(world.value, "a")
			end)
		end)

		helpers.it("answers false for a refused or interrupted publication and restores it", function()
			with_subject(function(subject, world, token)
				local owner = token(false)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				local refused = subject.scope_capture(owner)
				world.refuse = true
				helpers.assert_eq(subject.scope_apply(owner, refused, "b"), false)
				helpers.assert_eq(world.value, "a")
				world.refuse = false
				helpers.assert_eq(subject.scope_restore(owner, refused), true, "nothing was published")
				local interrupted = subject.scope_capture(owner)
				world.throw_after = true
				helpers.assert_eq(subject.scope_apply(owner, interrupted, "b"), false)
				helpers.assert_eq(world.value, "b", "the modelled native write landed")
				world.throw_after = false
				helpers.assert_eq(subject.scope_restore(owner, interrupted), true)
				helpers.assert_eq(world.value, "a")
			end)
		end)

		helpers.it("refuses reentry from the owner's own callback", function()
			with_subject(function(subject, world, token)
				local owner = token(false)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				local receipt, observed = subject.scope_capture(owner), {}
				world.on_publish = function()
					observed.idle = world.scope.idle()
					observed.change = world.scope.admit_change()
					observed.capture = subject.scope_capture(owner)
					observed.restore = subject.scope_restore(owner, receipt)
				end
				helpers.assert_eq(subject.scope_apply(owner, receipt, "b"), true)
				helpers.assert_eq(observed.idle, false)
				helpers.assert_eq(observed.change, false)
				helpers.assert_nil(observed.capture)
				helpers.assert_eq(observed.restore, false)
			end)
		end)

		helpers.it("refuses every step once the module is replaced or its backend is not live", function()
			with_subject(function(subject, world, token)
				local owner = token(false)
				package.loaded[SUBJECT] = {}
				helpers.assert_eq(subject.scope_acquire(owner), false, "a replaced module")
				package.loaded[SUBJECT] = subject
				world.live = false
				helpers.assert_eq(subject.scope_acquire(owner), false, "a dead backend")
				world.live = true
				helpers.assert_eq(subject.scope_acquire(owner), true)
				local receipt = subject.scope_capture(owner)
				world.live = false
				helpers.assert_nil(subject.scope_capture(owner))
				helpers.assert_eq(subject.scope_apply(owner, receipt, "b"), false)
				world.live = true
				helpers.assert_eq(subject.scope_apply(owner, receipt, "b"), true)
				world.live = false
				helpers.assert_eq(subject.scope_restore(owner, receipt), false)
				world.live = true
				package.loaded[SUBJECT] = {}
				helpers.assert_eq(subject.scope_restore(owner, receipt), false)
				package.loaded[SUBJECT] = subject
				helpers.assert_eq(subject.scope_restore(owner, receipt), true)
			end)
		end)

		helpers.it("forgets only a released receipt whose compensation settled", function()
			with_subject(function(subject, _, token)
				local owner = token(false)
				helpers.assert_eq(subject.scope_acquire(owner), true)
				local receipt = subject.scope_capture(owner)
				helpers.assert_eq(subject.scope_forget(owner, receipt), false, "still held")
				helpers.assert_eq(subject.scope_release(owner), true)
				helpers.assert_eq(subject.scope_forget(token(false), receipt), false, "a foreign owner")
				helpers.assert_eq(subject.scope_forget(owner, receipt), true)
				helpers.assert_eq(subject.scope_forget(owner, receipt), true, "idempotent")
				helpers.assert_eq(subject.scope_acquire(owner), true)
				helpers.assert_eq(subject.scope_apply(owner, receipt, "b"), false, "a forgotten receipt")
				helpers.assert_eq(subject.scope_restore(owner, receipt), false)
			end)
		end)
	end)
end

--- Checks that each real driver owner publishes the shared protocol's methods.
--- A retyped copy is how one fix reached one owner out of six.
--- @param helpers table Driver test API.
--- @param names table Module names of the driver's scope-field owners.
function M.register_owners(helpers, names)
	helpers.describe("driver scope owners use the shared protocol (scope-owner-protocol)", function()
		for _, name in ipairs(names) do
			helpers.it(name .. " installs the shared scope methods", function()
				local owner = require(name)
				for _, method in ipairs(METHODS) do
					local fn = rawget(owner, method)
					helpers.assert_type(fn, "function", name .. "." .. method)
					local source = debug.getinfo(fn, "S").source
					helpers.assert_true(source:find("scope_owner.lua", 1, true) ~= nil,
						name .. "." .. method .. " must come from scope_owner.lua, not " .. source)
				end
			end)
		end
	end)
end

return M
