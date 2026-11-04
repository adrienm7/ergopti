--- _shared/lua/test/check_session_contract.lua

--- ==============================================================================
--- MODULE: Update Check Session Vectors Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/updater/check_session_vectors.json on the session
--- behind the update-check window and on the exhausted rate-limit sentence. The
--- Windows host replays the same vectors: a phase rule or a page field that one
--- host changes alone fails here or there.
--- ==============================================================================

return function(helpers, json, shared_root)
	local CheckSession = require("updater.check_session")
	local RateLimit = require("updater.rate_limit")

	local file = assert(io.open(shared_root .. "/tests/corpus/updater/check_session_vectors.json", "rb"))
	local corpus = json.decode(file:read("*a"))
	file:close()

	--- The answer of a phase as the session receives it: the release's JSON object
	--- carries the body the session seeds into the notes.
	local function answer_of(id, check_only)
		local answer = {}
		for key, value in pairs(corpus.answers[id]) do answer[key] = value end
		if answer.body then
			answer.release = json.encode({ tag_name = answer.latest, body = answer.body })
			answer.body = nil
		end
		if check_only then answer.check_only = true end
		return answer
	end

	--- A session over ports that record which effect ran, showing one phase.
	local function session_in(phase)
		local effects = {}
		local function effect(name, result)
			return function() effects[name] = true; return result end
		end
		local on_result
		local session = CheckSession.new({
			push = function() return true end,
			check = function(_, answer) on_result = answer; return true end,
			channel = function() return "dev" end,
			current = function() return "v0.0.0-dev.144" end,
			set_channel = effect("switch_channel", true),
			install = effect("update", true),
			open_changelog = effect("whats_new", true),
			report = function(_, complete) effects.report = true; complete(true) end,
			open_log = effect("open_log", true),
			repository = function() return corpus.repository end,
			open_url = effect("open_url", true),
			close = effect("close"),
			log_path = function() return "/logs/today.log" end,
			log = function() end,
		})
		session.start()
		if phase ~= "checking" then on_result(answer_of(phase)) end
		return session, effects, on_result
	end

	helpers.describe("update-check session vectors: the phase of each action", function()
		for _, rule in ipairs(corpus.actions) do
			local allowed = {}
			for _, phase in ipairs(rule.phases) do allowed[phase] = true end
			for _, phase in ipairs({ "checking", "up_to_date", "available", "no_release", "error" }) do
				helpers.it(rule.action .. " in " .. phase, function()
					local session, effects = session_in(phase)
					session.on_message({ action = rule.action, url = corpus.link, channel = corpus.switch_channel })
					helpers.assert_eq(effects[rule.action] == true, allowed[phase] == true)
				end)
			end
		end
	end)

	helpers.describe("update-check session vectors: the page's state message", function()
		for _, vector in ipairs(corpus.state_messages) do
			helpers.it(vector.id, function()
				local session, _, on_result = session_in("checking")
				on_result(answer_of(vector.answer, vector.check_only))
				local message = session.message()
				for name, value in pairs(vector.expect) do helpers.assert_eq(message[name], value, name) end
				for name, value in pairs(vector.expect_notes or {}) do
					helpers.assert_eq(message.notes[name], value, "notes." .. name)
				end
				for _, name in ipairs(vector.absent) do helpers.assert_eq(message[name], nil, name) end
			end)
		end
	end)

	helpers.describe("update-check session vectors: the exhausted rate limit", function()
		for _, vector in ipairs(corpus.rate_limit) do
			helpers.it(vector.id, function()
				local detail = RateLimit.exhausted_detail(vector.status, vector.remaining, vector.reset)
				helpers.assert_eq(detail or "", vector.detail)
			end)
		end
	end)
end
