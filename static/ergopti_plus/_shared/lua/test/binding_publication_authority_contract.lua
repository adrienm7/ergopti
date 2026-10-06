--- _shared/lua/test/binding_publication_authority_contract.lua

--- ==============================================================================
--- MODULE: Native Binding Accessor Authority Contract
--- DESCRIPTION:
--- Exercises constructor admission and actual source publication through native
--- gesture consumers. A replaced public function cannot certify retirement;
--- exact source, registered-owner and authentic-accessor repairs restore judgment.
--- ==============================================================================

local M = {}

local function scope(body)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local previous_open = io.open
	local okay, detail = xpcall(body, debug.traceback)
	io.open = previous_open
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not okay then error(detail, 0) end
end

--- Registers pure registry boundaries and genuine native publication controls.
--- @param helpers table Actual native test API.
--- @param driver string macos or linux.
function M.register(helpers, driver)
	local Authority = require("config_binding_publication")
	helpers.describe("binding-publication: authentic accessor authority", function()
		helpers.it("admits each constructor once and refuses mismatched or displaced registration", function()
			scope(function()
				local name = "test.authentic_binding_owner"
				local owner, calls = {}, 0
				local getter = function() calls = calls + 1; return { acknowledged = true } end
				owner.published_binding_catalogue = getter
				package.loaded[name] = nil
				for _, domain in ipairs({ "unknown", false }) do
					local okay = pcall(Authority.register, domain, name, owner, getter)
					helpers.assert_eq(okay, false)
				end
				helpers.assert_eq(pcall(Authority.register, "tap", name, owner, function() end), false)
				Authority.register("tap", name, owner, getter)
				helpers.assert_eq(pcall(Authority.register, "tap", name, owner, getter), false)
				helpers.assert_eq(pcall(Authority.register, "script", name, owner, getter), false)
				helpers.assert_nil(Authority.current("tap", name, owner), "construction is not package publication")
				helpers.assert_eq(calls, 0)
				package.loaded[name] = owner
				helpers.assert_eq(Authority.owner_is_current("tap", name, owner), true)
				helpers.assert_eq(calls, 0, "identity inspection does not call the getter")
				helpers.assert_eq(Authority.current("tap", name, owner), { acknowledged = true })
				helpers.assert_nil(Authority.current("script", name, owner), "families cannot borrow authority")
				local successor = { published_binding_catalogue = getter }
				helpers.assert_eq(pcall(Authority.register, "tap", name, successor, getter), false)
				helpers.assert_eq(calls, 1)
			end)
		end)
		helpers.it("never invokes a missing, changed, inherited or proxy accessor", function()
			scope(function()
				local name = "test.authentic_binding_withdrawal"
				local owner, calls = {}, 0
				local getter = function() calls = calls + 1; return {} end
				owner.published_binding_catalogue = getter
				package.loaded[name] = nil
				Authority.register("script", name, owner, getter)
				package.loaded[name] = owner
				owner.published_binding_catalogue = function() error("public replacement must not run") end
				helpers.assert_nil(Authority.current("script", name, owner))
				owner.published_binding_catalogue = nil
				helpers.assert_nil(Authority.current("script", name, owner))
				local effects = 0
				setmetatable(owner, { __index = function() effects = effects + 1; return getter end })
				helpers.assert_nil(Authority.current("script", name, owner))
				setmetatable(owner, nil)
				owner.published_binding_catalogue = getter
				local successor = setmetatable({}, { __index = owner,
					__eq = function() effects = effects + 1; return true end })
				package.loaded[name] = successor
				helpers.assert_nil(Authority.current("script", name, owner))
				helpers.assert_nil(Authority.current("script", name, successor))
				helpers.assert_eq(effects, 0)
				helpers.assert_eq(calls, 0)
				package.loaded[name] = owner
				collectgarbage("collect")
				helpers.assert_eq(Authority.current("script", name, owner), {})
				helpers.assert_eq(calls, 1, "the live native owner retains its genuine weak-ledger accessor")
			end)
		end)
		helpers.it("supports keyboard authority and releases withdrawn closure cycles on both Lua VMs", function()
			scope(function()
				local name = "test.authentic_keyboard_collection"
				local weak = setmetatable({}, { __mode = "v" })
				local function construct()
					local owner = {}
					owner.published_binding_catalogue = function() return { owner = owner } end
					package.loaded[name] = nil
					Authority.register("keyboard", name, owner, owner.published_binding_catalogue)
					package.loaded[name] = owner
					helpers.assert_true(rawequal(Authority.current("keyboard", name, owner).owner, owner))
					weak[1] = owner
					package.loaded[name] = nil
				end
				construct()
				collectgarbage("collect"); collectgarbage("collect")
				helpers.assert_nil(weak[1], "the weak ledger cannot retain an accessor-owner cycle")
				construct()
			end)
		end)
		for _, domain in ipairs({ "tap", "script" }) do
			local family = domain
			local name = family == "tap" and "modules.shortcuts.tap_keys"
				or driver == "macos" and "infra.script_chord_catalogue" or "modules.shortcuts.script_chords"
			local target = family == "tap" and "number_row_left" or "script_altgr_enter"
			local consumer_name = driver == "macos" and "modules.gestures.actions" or "modules.gestures.manager"
			local function fresh()
				package.loaded[name], package.loaded[consumer_name] = nil, nil
				local owner = require(name)
				local consumer = require(consumer_name)
				return owner, consumer
			end
			local function publish(owner)
				if family == "tap" then owner.keys()
				elseif driver == "macos" then owner.get()
				else owner.catalogue() end
			end
			helpers.it("withdraws " .. family .. " judgment when the genuine module's public getter changes", function()
				scope(function()
					local owner, consumer = fresh()
					publish(owner)
					local getter = owner.published_binding_catalogue
					local publication = getter()
					local binding = publication.prefix .. target
					local other
					for id in pairs(publication.slots) do if id ~= target then other = id; break end end
					assert(other and publication.slots[target] == true)
					helpers.assert_eq(consumer.action_parameter_binding_fits(binding), true)
					local calls = 0
					owner.published_binding_catalogue = function()
						calls = calls + 1
						return { prefix = publication.prefix, slots = { [other] = true } }
					end
					local previous_open = io.open
					io.open = function() error("classification must not load or read") end
					helpers.assert_nil(consumer.action_parameter_binding_fits(binding))
					helpers.assert_nil(getter(), "a retained original getter cannot borrow changed export authority")
					helpers.assert_eq(calls, 0)
					helpers.assert_true(rawequal(package.loaded[name], owner))
					owner.published_binding_catalogue = getter
					helpers.assert_eq(consumer.action_parameter_binding_fits(binding), true)
					helpers.assert_eq(consumer.action_parameter_binding_fits(publication.prefix .. "removed_binding"), false)
					io.open = previous_open
					helpers.assert_eq(getter(), publication)
				end)
			end)
			helpers.it("keeps cold and displaced " .. family .. " constructors unjudged until exact repair", function()
				scope(function()
					local owner, consumer = fresh()
					local prefix = family == "tap" and "tap_key__" or "script__"
					local previous_open = io.open
					io.open = function() error("a cold consumer cannot initialize source publication") end
					helpers.assert_nil(consumer.action_parameter_binding_fits(prefix .. target))
					io.open = previous_open
					publish(owner)
					local getter, effects = owner.published_binding_catalogue, 0
					local successor = setmetatable({}, { __index = owner,
						__eq = function() effects = effects + 1; return true end })
					package.loaded[name] = successor
					io.open = function() error("a displaced publication must not read") end
					helpers.assert_nil(consumer.action_parameter_binding_fits(prefix .. target))
					helpers.assert_nil(getter())
					helpers.assert_eq(effects, 0)
					package.loaded[name] = owner
					helpers.assert_eq(consumer.action_parameter_binding_fits(prefix .. target), true)
					helpers.assert_eq(consumer.action_parameter_binding_fits(prefix .. "removed_binding"), false)
				end)
			end)
		end
	end)
end

return M
