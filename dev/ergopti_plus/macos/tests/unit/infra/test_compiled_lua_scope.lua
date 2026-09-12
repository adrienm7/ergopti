--- tests/unit/infra/test_compiled_lua_scope.lua

--- ==============================================================================
--- MODULE: Scoped Compilation Invalidation Tests
--- DESCRIPTION:
--- Uses real Lua source files to guard freshness and restore searcher ownership
--- before fixture rescue. Every owned temporary file is reclaimed on failure.
--- ==============================================================================

local helpers = require("tests.helpers")
local Scope = require("tests.support.compiled_lua_scope")
local NAME = "compiled_scope_fixture"

local function with_source(callback)
	local paths = {}
	local old_path, old_module, old_preload = package.path, package.loaded[NAME], package.preload[NAME]
	local searchers, searcher, searchpath = package.searchers, package.searchers[2], package.searchpath
	local function write(index, source)
		local file = assert(io.open(paths[index], "wb"))
		local written, reason = file:write(source)
		local closed, close_reason = file:close()
		assert(written, reason)
		assert(closed, close_reason)
	end
	local function reload()
		package.loaded[NAME] = nil
		return require(NAME)
	end
	local outcome = table.pack(pcall(function()
		for index = 1, 2 do paths[index] = assert(os.tmpname()):gsub("\\", "/") end
		write(1, 'return { value = "alpha" }\n')
		write(2, 'return { value = "bravo" }\n')
		package.path, package.preload[NAME] = paths[1], nil
		return callback(paths, write, reload)
	end))
	package.path, package.loaded[NAME], package.preload[NAME] = old_path, old_module, old_preload
	package.searchers, searchers[2], package.searchpath = searchers, searcher, searchpath
	for _, file in ipairs(paths) do
		local removed, reason, code = os.remove(file)
		assert(removed or code == 2, reason)
	end
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

helpers.describe("compiled Lua scope invalidation", function()
	helpers.it("(compiled-lua-scope) reuses code but never mutable module instances", function()
		with_source(function(_, _, reload)
			Scope.with_scope(function(stats)
				local first = reload()
				first.value = "mutated"
				local second = reload()
				helpers.assert_true(not rawequal(first, second), "module instances must remain distinct")
				helpers.assert_eq(second.value, "alpha")
				helpers.assert_eq(stats.hits, 1)
				helpers.assert_eq(stats.misses, 1)
			end)
		end)
	end)

	helpers.it("(compiled-lua-scope) same-length edits invalidate and syntax repair stays visible", function()
		with_source(function(_, write, reload)
			Scope.with_scope(function()
				helpers.assert_eq(reload().value, "alpha")
				write(1, 'return { value = "omega" }\n')
				helpers.assert_eq(reload().value, "omega")
				write(1, 'return { value = }\n')
				local ok, reason = pcall(reload)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(reason):find("unexpected symbol", 1, true) ~= nil)
				write(1, 'return { value = "fixed" }\n')
				helpers.assert_eq(reload().value, "fixed")
			end)
		end)
	end)

	helpers.it("(compiled-lua-scope) path order deletion and new shadowing source invalidate", function()
		with_source(function(paths, write, reload)
			Scope.with_scope(function()
				helpers.assert_eq(reload().value, "alpha")
				package.path = paths[2] .. ";" .. paths[1]
				helpers.assert_eq(reload().value, "bravo")
				assert(os.remove(paths[2]))
				helpers.assert_eq(reload().value, "alpha")
				write(2, 'return { value = "new" }\n')
				helpers.assert_eq(reload().value, "new")
				assert(os.remove(paths[1]))
				assert(os.remove(paths[2]))
				local ok, reason = pcall(reload)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(reason):find("not found", 1, true) ~= nil)
			end)
		end)
	end)

	helpers.it("(compiled-lua-scope) preserves preload priority and fresh environments", function()
		with_source(function(_, write, reload)
			Scope.with_scope(function()
				helpers.assert_eq(reload().value, "alpha")
				package.preload[NAME] = function() return "preload" end
				helpers.assert_eq(reload(), "preload")
				package.preload[NAME] = nil
				write(1, 'local prior = _ENV; _ENV = { marker = (prior.marker or 0) + 1 }; return _ENV.marker\n')
				helpers.assert_eq(reload(), 1)
				helpers.assert_eq(reload(), 1, "executed closures must not retain a replaced environment")
				write(1, '\239\187\191#!/usr/bin/env lua\nreturn { value = "bom" }\n')
				helpers.assert_eq(reload().value, "bom")
				helpers.assert_eq(reload().value, "bom")
			end)
		end)
	end)

	helpers.it("(compiled-lua-scope) restores nested owners return arity and exact errors", function()
		with_source(function(_, _, reload)
			local searchers, original = package.searchers, package.searchers[2]
			local result = table.pack(Scope.with_scope(function()
				local outer = package.searchers[2]
				Scope.with_scope(function() helpers.assert_eq(reload().value, "alpha") end)
				helpers.assert_true(rawequal(package.searchers[2], outer))
				return "first", nil, "last"
			end))
			helpers.assert_eq(result.n, 3)
			helpers.assert_eq(result[1], "first")
			helpers.assert_nil(result[2])
			helpers.assert_eq(result[3], "last")
			local sentinel = {}
			local ok, reason = pcall(Scope.with_scope, function()
				package.searchers = {}
				error(sentinel)
			end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(rawequal(reason, sentinel), "preserve the exact callback error")
			helpers.assert_true(rawequal(package.searchers, searchers), "restore before fixture rescue")
			helpers.assert_true(rawequal(package.searchers[2], original), "restore original searcher before rescue")
		end)
	end)

	for _, mode in ipairs({ "read_throw", "read_refusal", "close_throw", "close_refusal" }) do
		helpers.it("(compiled-lua-scope) propagates " .. mode .. " and closes its source handle", function()
			with_source(function(paths, _, reload)
				local open, original, closes = io.open, package.searchers[2], 0
				io.open = function(file, access)
					local handle, reason = open(file, access)
					if file ~= paths[1] or not handle then return handle, reason end
					return {
						read = function(_, format)
							if mode == "read_throw" then error("controlled read_throw") end
							if mode == "read_refusal" then return nil, "controlled read_refusal" end
							return handle:read(format)
						end,
						close = function()
							closes = closes + 1
							assert(handle:close())
							if mode == "close_throw" then error("controlled close_throw") end
							if mode == "close_refusal" then return nil, "controlled close_refusal" end
							return true
						end,
					}
				end
				local ok, reason = pcall(Scope.with_scope, reload)
				io.open = open
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(reason):find("controlled " .. mode, 1, true) ~= nil)
				helpers.assert_eq(closes, 1, "close the real handle even when read fails")
				helpers.assert_true(rawequal(package.searchers[2], original), "restore searcher before rescue")
			end)
		end)
	end

	helpers.it("(compiled-lua-scope) delegates custom searchers without cloning their upvalues", function()
		with_source(function(_, _, reload)
			local calls = 0
			local custom = function()
				return function()
					calls = calls + 1
					return calls
				end, "custom metadata"
			end
			package.searchers[2] = custom
			Scope.with_scope(function(stats)
				helpers.assert_eq(reload(), 1)
				helpers.assert_eq(reload(), 2)
				helpers.assert_eq(stats.hits, 0)
				helpers.assert_eq(stats.misses, 0)
			end)
			helpers.assert_true(rawequal(package.searchers[2], custom), "restore custom owner before fixture rescue")
		end)
	end)

	helpers.it("(compiled-lua-scope) changed searchpath hooks retain native loader behavior", function()
		with_source(function(_, write, reload)
			Scope.with_scope(function(stats)
				helpers.assert_eq(reload().value, "alpha")
				package.searchpath = function() error("custom searchpath must not replace native loader resolution") end
				write(1, 'return { value = "updated" }\n')
				helpers.assert_eq(reload().value, "updated")
				helpers.assert_eq(stats.hits, 0)
				helpers.assert_eq(stats.misses, 1)
			end)
		end)
	end)
end)
