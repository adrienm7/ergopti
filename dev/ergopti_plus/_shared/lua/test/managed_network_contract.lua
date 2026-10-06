--- _shared/lua/test/managed_network_contract.lua

--- ==============================================================================
--- MODULE: Managed Network Failure Corpus Replay
--- DESCRIPTION:
--- Replays manually authored expectations across the Lua drivers. This tests
--- classification and capability admission, not actual proxy or TLS behavior.
--- ==============================================================================

local M = {}
local Failure = require("network.failure")

local LABELS = {
	retry = "network.action.retry", proxy_settings = "network.action.open_proxy_settings",
	download_folder = "network.action.open_download_folder", diagnostics = "error_dialog.open_log",
}

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = copy(child) end
	return result
end

--- Registers the independent receipt corpus and refusal boundary controls.
--- @param policy table Decoded canonical managed_network.json.
--- @param corpus table Decoded independent failure_vectors.json.
--- @param helpers table The driver's test registration and assertion helpers.
function M.run(policy, corpus, helpers)
	assert(corpus.schema_version == 1 and #corpus.vectors == 53, "independent network failure inventory")
	local contract = Failure.new(policy)
	for _, vector in ipairs(corpus.vectors) do
		helpers.it("managed network receipt: " .. vector.id, function()
			local report = contract.classify(vector.receipt, vector.capabilities or {})
			helpers.assert_eq(report.cause, vector.cause, vector.id)
			helpers.assert_eq(report.message_key, "network.failure." .. vector.cause, vector.id .. " locale")
			helpers.assert_eq(#report.actions, #vector.actions, vector.id .. " action count")
			for index, action in ipairs(report.actions) do
				helpers.assert_eq(action.id, vector.actions[index], vector.id .. " action order")
				helpers.assert_eq(action.label_key, LABELS[vector.actions[index]], vector.id .. " action locale")
				for key in pairs(action) do
					helpers.assert_true(key == "id" or key == "label_key", "action must not expose raw native metadata")
				end
			end
			if vector.evidence then helpers.assert_eq(report.evidence, vector.evidence, vector.id .. " evidence") end
			for key in pairs(report) do
				helpers.assert_true(key == "cause" or key == "message_key" or key == "evidence" or key == "actions",
					"failure report must not copy URLs, stderr, paths or credentials")
			end
		end)
	end

	helpers.it("managed network click rechecks the retired retry owner", function()
		local current = { owner_alive = true, retry_available = true, diagnostics_available = true }
		helpers.assert_eq(contract.actions("unknown", current)[1].id, "retry")
		current.owner_alive = false
		local actions = contract.actions("unknown", current)
		helpers.assert_eq(#actions, 1)
		helpers.assert_eq(actions[1].id, "diagnostics")
	end)

	helpers.it("managed network policy refuses unknown receipt fields", function()
		local malformed = copy(policy)
		malformed.rules[1].when.typo_stage = { "file_write" }
		helpers.assert_eq(pcall(Failure.new, malformed), false)
	end)

	helpers.it("managed network policy refuses vacuous rules and unknown capabilities", function()
		local malformed = copy(policy)
		malformed.rules[1].when = {}
		helpers.assert_eq(pcall(Failure.new, malformed), false)
		malformed = copy(policy)
		malformed.actions.retry.requires = { "imaginary_owner" }
		helpers.assert_eq(pcall(Failure.new, malformed), false)
	end)

	helpers.it("managed network classifier rejects missing caller contexts", function()
		helpers.assert_eq(pcall(contract.classify, "untyped stderr", {}), false)
		helpers.assert_eq(pcall(contract.classify, {}, nil), false)
	end)
end

--- Registers the independently authored optional-backend capability corpus.
--- @param policy table Decoded canonical managed_network.json.
--- @param corpus table Decoded independent alternative_capability_vectors.json.
--- @param helpers table The driver's test registration and assertion helpers.
function M.run_alternatives(policy, corpus, helpers)
	assert(corpus.schema_version == 1 and #corpus.vectors == 7, "independent alternative capability inventory")
	local contract = Failure.new(policy)
	for _, vector in ipairs(corpus.vectors) do
		helpers.it("managed network alternate capability: " .. vector.id, function()
			local actions = contract.actions(vector.cause, vector.capabilities)
			helpers.assert_eq(#actions, #vector.actions, vector.id .. " action count")
			for index, action in ipairs(actions) do
				helpers.assert_eq(action.id, vector.actions[index], vector.id .. " action order")
				helpers.assert_eq(action.label_key, "mlx.use_ollama", vector.id .. " action locale")
				for key in pairs(action) do
					helpers.assert_true(key == "id" or key == "label_key", "alternate action must not expose raw metadata")
				end
			end
		end)
	end
end

--- Registers both fixed corpora through the caller's existing resource owner.
--- @param read function Reads and decodes one shared resource relative path.
--- @param helpers table The driver's test registration and assertion helpers.
function M.register(read, helpers)
	local policy = read("modules/network/managed_network.json")
	M.run(policy, read("tests/corpus/network/failure_vectors.json"), helpers)
	M.run_alternatives(policy, read("tests/corpus/network/alternative_capability_vectors.json"), helpers)
end

return M
