--- tests/unit/modules/llm/test_agent_connectors.lua

--- ==============================================================================
--- MODULE: AI Agent Connectors (Linux)
--- DESCRIPTION:
--- Each accepted action becomes one program run with an argument vector: the
--- calendar and reminder files opened with xdg-open, the mail draft through
--- xdg-email or a mailto: link, the user's tool from the agent_tools folder.
--- The OS boundaries are scripted; the payloads are the shared agent.lua's.
---
--- ROOT CAUSE ENCODED:
--- A connector that built a shell string would execute the model's text, and a
--- mail connector that sent would act without the user reviewing the draft.
--- ==============================================================================

local helpers = require("tests.helpers")
local Agent = require("llm.agent")
local Json = require("json")

local TOOLS_DIR = "/home/user/.config/ergopti/agent_tools"
local PRIVATE_DIR = "/run/user/1000/ergopti-agent.TEST"

--- @return table config Decoded agent.json.
local function config()
	local fh = assert(io.open(helpers.driver_root() .. "/../_shared/modules/llm/agent.json", "r"))
	local text = fh:read("*a")
	fh:close()
	return assert(Json.decode(text))
end

--- Runs body with scripted boundaries.
--- @param opts table { has_xdg_email?, tools?, write_fails? }
--- @param body function body(connectors, world)
local function with_connectors(opts, body)
	local previous = package.loaded["modules.llm.agent_connectors"]
	package.loaded["modules.llm.agent_connectors"] = nil
	local Connectors = require("modules.llm.agent_connectors")
	local world = { runs = {}, written = {}, removed = {}, listed = 0, outcomes = {} }
	Connectors._set_deps_for_test({
		run = function(executable, args, options, callback)
			world.runs[#world.runs + 1] = { executable = executable, args = args, timeout_ms = options.timeout_ms,
				callback = callback }
			return { cancel = function() end }
		end,
		has_command = function(name) return name == "xdg-email" and opts.has_xdg_email == true end,
		private_dir = function() return PRIVATE_DIR end,
		write_file = function(path, content)
			if opts.write_fails then return false end
			world.written[#world.written + 1] = { path = path, content = content }
			return true
		end,
		remove = function(path)
			world.removed[#world.removed + 1] = path
			return true
		end,
		utc_stamp = function() return "20260929T120500Z" end,
		random_hex = function() return "00ff" end,
		tools_dir = function() return TOOLS_DIR end,
		list_executables = function()
			world.listed = world.listed + 1
			return opts.tools or {}
		end,
		clock = function() return world.clock or 0 end,
	})
	local function done(ok, reason) world.outcomes[#world.outcomes + 1] = { ok = ok, reason = reason } end
	local ok, err = pcall(body, Connectors, world, done)
	Connectors._set_deps_for_test(nil)
	package.loaded["modules.llm.agent_connectors"] = previous
	if not ok then error(err, 0) end
end

helpers.describe("AI agent connectors: one program per action, never a shell", function()

	helpers.it("a calendar event is an .ics file in a private folder, opened with xdg-open", function()
		with_connectors({}, function(Connectors, world, done)
			local cfg = config()
			local action = { type = "calendar", title = "Devis; avec Paul", start = "2026-10-01T14:00",
				["end"] = "2026-10-01T15:00", location = "Café, Lyon", attendees = { "paul@example.com" } }
			helpers.assert_eq(Connectors.run(cfg, action, done), true)
			helpers.assert_eq(world.written[1].path, PRIVATE_DIR .. "/event.ics")
			helpers.assert_eq(world.written[1].content, Agent.ics(cfg, action, "00ff@ergopti", "20260929T120500Z"))
			helpers.assert_eq(world.runs[1].executable, "xdg-open")
			helpers.assert_eq(#world.runs[1].args, 1)
			helpers.assert_eq(world.runs[1].args[1], PRIVATE_DIR .. "/event.ics")
			helpers.assert_eq(#world.removed, 0, "not deleted before the calendar read it")
			world.runs[1].callback({ ok = true, code = 0 })
			helpers.assert_eq(world.outcomes[1].ok, true)
		end)
	end)

	helpers.it("a reminder is a VTODO in task.ics; the previous file goes at the next run and at stop", function()
		with_connectors({}, function(Connectors, world, done)
			local cfg = config()
			Connectors.run(cfg, { type = "reminder", title = "Rappeler Paul", due = "2026-10-02T09:00" }, done)
			helpers.assert_eq(world.written[1].path, PRIVATE_DIR .. "/task.ics")
			helpers.assert_contains(world.written[1].content, "BEGIN:VTODO")
			Connectors.run(cfg, { type = "reminder", title = "Encore" }, done)
			helpers.assert_eq(table.concat(world.removed, "|"), PRIVATE_DIR .. "/task.ics|" .. PRIVATE_DIR,
				"the first file and its folder go when the second is written")
			Connectors.cleanup()
			helpers.assert_eq(#world.removed, 4, "the second goes at stop")
		end)
	end)

	helpers.it("a file that cannot be written fails without running anything", function()
		with_connectors({ write_fails = true }, function(Connectors, world, done)
			helpers.assert_eq(Connectors.run(config(), { type = "reminder", title = "x" }, done), false)
			helpers.assert_eq(#world.runs, 0)
			helpers.assert_eq(world.outcomes[1].ok, false)
		end)
	end)

	helpers.it("a mail is a draft through xdg-email, with every value its own argument", function()
		with_connectors({ has_xdg_email = true }, function(Connectors, world, done)
			local action = { type = "mail", to = { "a@example.com", "b@example.com" }, subject = "$(rm -rf ~)",
				body = "Bonjour;\nÀ jeudi" }
			Connectors.run(config(), action, done)
			helpers.assert_eq(world.runs[1].executable, "xdg-email")
			helpers.assert_eq(table.concat(world.runs[1].args, "\0"), table.concat({ "--utf8", "--subject",
				"$(rm -rf ~)", "--body", "Bonjour;\nÀ jeudi", "a@example.com", "b@example.com" }, "\0"))
			for _, arg in ipairs(world.runs[1].args) do
				helpers.assert_true(not arg:lower():find("send"), "nothing asks to send")
			end
		end)
	end)

	helpers.it("without xdg-email, a mail is the mailto: link opened with xdg-open", function()
		with_connectors({}, function(Connectors, world, done)
			local action = { type = "mail", body = "Bonjour" }
			Connectors.run(config(), action, done)
			helpers.assert_eq(world.runs[1].executable, "xdg-open")
			helpers.assert_eq(world.runs[1].args[1], Agent.mailto(action))
		end)
	end)

	helpers.it("a shortcut runs the user's tool with the input as its only argument", function()
		with_connectors({ tools = { "zz-last", "Envoyer la facture", "../escape" } }, function(Connectors, world, done)
			local cfg = config()
			helpers.assert_eq(table.concat(Connectors.tools(cfg), "|"), "Envoyer la facture|zz-last",
				"sorted, and a name with a slash is not a tool")
			Connectors.run(cfg, { type = "shortcut", name = "Envoyer la facture", input = "Client; Dupont" }, done)
			helpers.assert_eq(world.runs[1].executable, TOOLS_DIR .. "/Envoyer la facture")
			helpers.assert_eq(#world.runs[1].args, 1)
			helpers.assert_eq(world.runs[1].args[1], "Client; Dupont")
			Connectors.run(cfg, { type = "shortcut", name = "zz-last" }, done)
			helpers.assert_eq(#world.runs[2].args, 0, "no input, no argument")
			Connectors.run(cfg, { type = "shortcut", name = "gone" }, done)
			helpers.assert_eq(#world.runs, 2, "a tool no longer in the folder does not run")
			helpers.assert_eq(world.outcomes[1].ok, false)
		end)
	end)

	helpers.it("the tools list is capped, and read again after ten minutes or a refresh", function()
		local names = {}
		for index = 1, 60 do names[index] = string.format("tool%02d", index) end
		with_connectors({ tools = names }, function(Connectors, world)
			local cfg = config()
			helpers.assert_eq(#Connectors.tools(cfg), cfg.max_tools)
			Connectors.tools(cfg)
			helpers.assert_eq(world.listed, 1, "cached")
			world.clock = 601
			Connectors.tools(cfg)
			helpers.assert_eq(world.listed, 2, "read again after ten minutes")
			Connectors.refresh_tools()
			Connectors.tools(cfg)
			helpers.assert_eq(world.listed, 3, "and on refresh")
		end)
	end)
end)
