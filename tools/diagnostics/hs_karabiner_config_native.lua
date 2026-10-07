-- tools/diagnostics/hs_karabiner_config_native.lua
-- Builds, merges and atomically publishes inert rules in an owned private file.
-- No controller initialization, native lease, guardian or Karabiner service is used.

local M = {}

local function read(path)
	local file = assert(io.open(path, "rb"))
	local raw = assert(file:read("*a"))
	assert(file:close())
	return raw
end

function M.run(receipt_path, destination, nonce)
	local Codec = require("adapters.json_codec")
	local Config = require("platform.remap.config")
	local Generator = require("platform.remap.generator")
	local FileSystem = require("adapters.file_system")
	local Controller = require("platform.remap.lease_controller")
	local original = read(destination)
	assert(not Controller.is_initialized(), "A real lease owner already exists")
	local result = {
		schema_version = 1,
		contract = "karabiner.build-merge",
		nonce = nonce,
		pid = hs.processInfo.processID,
		executable = hs.processInfo.executablePath,
		bundle_id = hs.processInfo.bundleID,
		version = hs.processInfo.version,
		publication_scope = "private-file-only",
		complete = false,
		lease_initialized = false,
		private_source_restored = false,
		codec_independent = false,
		native_equal_values_shared = false,
		variants = {},
		errors = {},
	}
	local ok, failure = xpcall(function()
		local twins = [[{"left":[{"options":["first"]}],"right":[{"options":["first"]}]}]]
		local native = assert(hs.json.decode(twins))
		result.native_equal_values_shared = native.left == native.right
		local detached = assert(Codec.decode(twins))
		assert(detached.left ~= detached.right and detached.left[1] ~= detached.right[1])
		detached.left[1].options[1] = "changed"
		detached.left[2] = { options = { "added" } }
		result.codec_independent = detached.right[1].options[1] == "first" and #detached.right == 1
		assert(result.codec_independent, "Equal native JSON values did not become independent trees")
		-- The packaged configdir may contain only a loader. Resolve the installed
		-- production module, whose sibling data directory owns these catalogues.
		local config_source = assert(package.searchpath("platform.remap.config", package.path))
		local data = assert(config_source:match("^(.*[/\\])")) .. "data/"
		local actions = assert(Config.load_available_actions(data .. "actions.json"))
		local keys = assert(Config.load_tap_hold_keys(data .. "tap_hold_keys.json"))
		local combos = assert(Config.load_mod_combos(data .. "mod_combos.json"))
		local non_canonical = Config.compute_non_canonical_combos(combos)
		for _, preset in ipairs({ "default", "recommended" }) do
			for _, tap_holds in ipairs({ false, true }) do
				for _, combinations in ipairs({ false, true }) do
					local state = preset == "recommended" and Config.build_recommended_state(keys, combos)
						or Config.build_default_state(keys, combos)
					state.tap_holds_enabled, state.mod_combos_enabled = tap_holds, combinations
					local generated, detail, legacy, context = Generator.build_karabiner_json(
						state, actions, keys, combos, non_canonical, data, nonce)
					assert(generated, "Native rule build refused: " .. tostring(detail))
					local merged, merge_detail, snapshot = Generator.merge_into_existing_config(
						generated, destination, legacy, context)
					assert(merged, "Native merge refused: " .. tostring(merge_detail))
					assert(snapshot.status == "ok" and snapshot.content == read(destination),
						"The actual merge source receipt differs")
					local deployed, deploy_detail = Generator.merge_and_deploy_config(
						generated, destination, legacy, context)
					assert(deployed == true, "Native publication refused: " .. tostring(deploy_detail))
					local published = assert(Codec.decode(read(destination)))
					local repeated, repeat_detail, attempts = Generator.merge_and_deploy_config(
						generated, destination, legacy, context)
					assert(repeated == true and repeat_detail == "unchanged" and attempts == 0,
						"Identical native rules were not confirmed unchanged")
					result.variants[#result.variants + 1] = {
						preset = preset,
						tap_holds = tap_holds,
						combinations = combinations,
						config = published,
						exact_source_snapshot = true,
						repeated_unchanged = true,
					}
				end
			end
		end
	end, debug.traceback)
	if not ok then result.errors[#result.errors + 1] = tostring(failure) end
	local restore_ok, restored, restore_detail = pcall(function()
		local accepted, detail = FileSystem.write_if_unchanged(destination, original,
			{ status = "ok", content = read(destination) })
		return accepted == true and read(destination) == original, detail
	end)
	result.private_source_restored = restore_ok and restored == true
	if not result.private_source_restored then
		result.errors[#result.errors + 1] = "Owned source restoration refused: "
			.. tostring(restore_ok and restore_detail or restored)
	end
	result.lease_initialized = Controller.is_initialized()
	result.complete = ok and result.private_source_restored and not result.lease_initialized
	local file = assert(io.open(receipt_path .. ".pending", "wb"))
	assert(file:write(assert(Codec.encode(result)) .. "\n"))
	assert(file:close())
	assert(os.rename(receipt_path .. ".pending", receipt_path))
	return nonce
end

--- Publishes eight complete configurations into an explicit private owner, without merge.
---@param receipt_path string Fresh diagnostic receipt destination.
---@param private_root string Existing ordinary private ErgoptiPlus parent directory.
---@param nonce string Private diagnostic generation token.
---@param uid number Actual Python creator UID.
---@param pid number Exact live scripting process PID.
---@return string nonce Original diagnostic challenge.
function M.run_owned(receipt_path, private_root, nonce, uid, pid)
	local Codec = require("adapters.json_codec")
	local Config = require("platform.remap.config")
	local Owned = require("platform.remap.owned_configuration")
	local Controller = require("platform.remap.lease_controller")
	local result = {
		schema_version = 1, contract = "karabiner.owned-private-publication", nonce = nonce,
		pid = hs.processInfo.processID, executable = hs.processInfo.executablePath,
		bundle_id = hs.processInfo.bundleID, version = hs.processInfo.version,
		publication_scope = "private-file-only", installation = false, remapping = false,
		lease_initialized = false, complete = false, cleanup_settled = false,
		stock_sentinel_preserved = false, variants = {}, errors = {},
	}
	local owner, publisher, token = {}, nil, nil
	local stock_path = private_root .. "/stock-personal.json"
	local destination = private_root .. "/karabiner/karabiner.json"
	local original = read(stock_path)
	local ok = xpcall(function()
		assert(not Controller.is_initialized(), "A real lease owner already exists")
		publisher = assert(Owned.bind_private(owner, private_root, uid, pid))
		token = assert(publisher.identity(owner))
		local config_source = assert(package.searchpath("platform.remap.config", package.path))
		local data = assert(config_source:match("^(.*[/\\])")) .. "data/"
		local actions = assert(Config.load_available_actions(data .. "actions.json"))
		local keys = assert(Config.load_tap_hold_keys(data .. "tap_hold_keys.json"))
		local combos = assert(Config.load_mod_combos(data .. "mod_combos.json"))
		local non_canonical = Config.compute_non_canonical_combos(combos)
		for _, preset in ipairs({ "default", "recommended" }) do
			for _, tap_holds in ipairs({ false, true }) do
				for _, combinations in ipairs({ false, true }) do
					local state = preset == "recommended" and Config.build_recommended_state(keys, combos)
						or Config.build_default_state(keys, combos)
					state.tap_holds_enabled, state.mod_combos_enabled = tap_holds, combinations
					assert(publisher.publish(owner, token, { state = state, actions = actions, keys = keys,
						combos = combos, non_canonical = non_canonical, data = data, lease_token = nonce }) == true,
						"Complete private publication refused")
					result.variants[#result.variants + 1] = { preset = preset, tap_holds = tap_holds,
						combinations = combinations, config = assert(Codec.decode(read(destination))),
						exact_publication_receipt = true, cleanup_settled = true }
				end
			end
		end
	end, function() return "owned_private_publication_failed" end)
	if not ok then result.errors[#result.errors + 1] = "owned_private_publication_failed" end
	if publisher and token then
		local detached, acknowledged = pcall(publisher.detach, owner, token)
		result.cleanup_settled = detached and acknowledged == true and publisher.retired(owner, token) == true
	end
	local stock_ok, stock = pcall(read, stock_path)
	result.stock_sentinel_preserved = stock_ok and stock == original
	result.lease_initialized = Controller.is_initialized()
	result.complete = ok and result.cleanup_settled and result.stock_sentinel_preserved
		and not result.lease_initialized
	local file = assert(io.open(receipt_path .. ".pending", "wb"))
	assert(file:write(assert(Codec.encode(result)) .. "\n")); assert(file:close())
	assert(os.rename(receipt_path .. ".pending", receipt_path))
	return nonce
end

return M
