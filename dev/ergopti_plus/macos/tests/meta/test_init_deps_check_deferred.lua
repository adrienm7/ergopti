--- tests/meta/test_init_deps_check_deferred.lua

--- ==============================================================================
--- MODULE: Boot deps check is deferred off the critical path (regression)
--- DESCRIPTION:
--- init.lua bootstrapped the LLM backend by calling check_and_install_deps()
--- SYNCHRONOUSLY between the "LLM backend bootstrap" Boot.mark and the rest of
--- boot. Although the dependency script itself runs in an hs.task, its setup
--- (resolving the script path, writing the PTY wrapper file, chmod via
--- os.execute, hs.task.new) executes synchronously and cost hundreds of ms on
--- the critical path. Nothing on the boot path needs the venv ready
--- synchronously — the backend server start is itself lazy.
---
--- Fix: wrap the mlx/ollama check_and_install_deps() dispatch in
--- hs.timer.doAfter(0, …) so it runs on the next event-loop tick, after boot
--- completes — mirroring start_background_network_bootstrap. This is a source
--- assertion: the boot path is not exercised by the headless harness, so the
--- structural invariant (the deps dispatch is inside a doAfter, not a bare call)
--- is what we pin.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("boot: LLM deps check is deferred via hs.timer.doAfter(0)", function()
	local function read_init()
		local path = helpers.driver_root() .. "init.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open init.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("dispatches mlx/ollama deps checks inside a doAfter(0) tick", function()
		local src = read_init()

		-- Locate the deferral and the deps dispatch it must wrap.
		local defer_pos = src:find("hs.timer.doAfter(0, function()", 1, true)
		helpers.assert_true(defer_pos ~= nil,
			"the boot deps check must be wrapped in hs.timer.doAfter(0, function() … end)")

		local mlx_pos    = src:find("mlx_deps_checker.check_and_install_deps", defer_pos, true)
		local ollama_pos = src:find("ollama_deps_checker.check_and_install_deps", defer_pos, true)
		helpers.assert_true(mlx_pos ~= nil and ollama_pos ~= nil,
			"both backend deps dispatches must appear after the deferral opens")

		-- The closing of the doAfter must come AFTER both dispatches: they are inside it.
		local close_pos = src:find("end)", ollama_pos, true)
		helpers.assert_true(close_pos ~= nil and mlx_pos < close_pos and ollama_pos < close_pos,
			"both deps dispatches must sit inside the deferred closure")
	end)

	helpers.it("does not call check_and_install_deps synchronously on the boot path", function()
		local src = read_init()
		-- A bare, unindented-into-doAfter synchronous call would look like
		-- "\n\t\tmlx_deps_checker.check_and_install_deps()" at the old call site. The
		-- only legitimate occurrences now are the pcall-wrapped ones inside doAfter.
		helpers.assert_true(src:find("\t\tmlx_deps_checker.check_and_install_deps()", 1, true) == nil,
			"the MLX deps check must not be a bare synchronous call on the boot path")
		helpers.assert_true(src:find("\t\tollama_deps_checker.check_and_install_deps()", 1, true) == nil,
			"the Ollama deps check must not be a bare synchronous call on the boot path")
	end)
end)
