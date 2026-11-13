--- tests/unit/ai/engine/runtime/test_ollama_install_state_first_install.lua

--- ==============================================================================
--- MODULE: Model Page Install State After a First Install (Linux)
--- DESCRIPTION:
--- The model page observes the owned Ollama runtime through a read-only
--- resolver. The real resolver records the absence of missing ancestors as part
--- of its witness, which is right for one operation and wrong for an observer
--- kept across the install that creates those ancestors.
---
--- ROOT CAUSE ENCODED: the page cached its first resolver forever, so after a
--- successful first install the new parents read as an ancestor substitution
--- and the runtime stayed "absent" until a restart (audit LRT-001).
--- ==============================================================================

local helpers = require("tests.helpers")

local restore = helpers.keep_loaded({ "ai.engine.ollama.install_resolver",
	"ai.engine.ollama.installed_runtime", "ai.engine.ollama.install_state" })

helpers.describe("model page install state after a first install", function()
	helpers.it("sees the runtime a first install published, without a reset (lrt-001)", function()
		local ok, err = pcall(function()
			local home, uid = "/home/first-install-user", 1000
			-- The XDG data tree under HOME is absent until the install creates it.
			local present = { ["/"] = true, ["/home"] = true, [home] = true }
			local native = { getuid = function() return uid end, os_uname = function() return { machine = "x86_64" } end,
				fs_access = function() return true end, fs_mkdir = function() return true end,
				fs_lstat = function(path)
					if not present[path] then return nil, "ENOENT: absent", "ENOENT" end
					return { type = "directory", uid = (path == "/" or path == "/home") and 0 or uid, mode = 16877,
						dev = 1, ino = #path }
				end }
			local Resolver = helpers.load_module("ai.engine.ollama.install_resolver")
			local built = 0
			package.loaded["ai.engine.ollama.install_resolver"] = { new = function()
				built = built + 1
				return Resolver.new({ native = native, environment = { HOME = home } })
			end }
			local installed = false
			-- The real capture refuses a resolver that is no longer current before
			-- reading the tree; the tree itself is the install's published runtime.
			package.loaded["ai.engine.ollama.installed_runtime"] = { capture = function(resolver)
				if resolver.current() ~= true then return { status = "unavailable" } end
				return { status = installed and "installed" or "missing" }
			end }
			local State = helpers.load_module("ai.engine.ollama.install_state")
			State._reset()
			local llm = { get_cached_models = function() return {} end,
				get_base_url = function() return "http://127.0.0.1:1" end }
			local _, _, before = State.capture(llm)
			helpers.assert_eq(before, "absent", "the page offers the install before it runs")

			-- The install creates every missing parent and publishes the runtime.
			local planner, refusal = Resolver.new({ native = native, environment = { HOME = home } })
			helpers.assert_type(planner, "table", "the real resolver must admit this home: " .. tostring(refusal))
			local plan = planner.plan()
			local path = ""
			for part in plan.parent:gmatch("[^/]+") do path = path .. "/" .. part; present[path] = true end
			installed = true
			State.note_repair({ ok = true, origin = "http://127.0.0.1:1" })

			local available, reason, after = State.capture(llm)
			helpers.assert_eq(after, "installed", "a first install must not leave the page on a stale absence")
			helpers.assert_eq(available, true)
			helpers.assert_nil(reason)
			helpers.assert_true(built >= 2, "each observation builds its own read-only resolver")
			State._reset()
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)
