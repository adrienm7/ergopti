--- _shared/lua/core/llm/ollama_runtime_choice.lua
--- Shared source classification and explicit, one-use native migration choice.
--- Source labels never grant process signalling or listener ownership.
local M = {}
local issued = {}
local foreign = { app = true, user_app = true, homebrew = true, managed = true, path = true }

function M.classify(source_kind)
	if source_kind == "native_managed" then return "native" end
	if foreign[source_kind] == true then return "foreign" end
	return "unknown"
end

local function path(value, empty_allowed)
	return type(value) == "string" and (empty_allowed and value == ""
		or value:sub(1, 1) == "/" and not value:find("[%z\1-\31\127]"))
end

--- Issuance binds a UI choice to exact source, target and unchanged model store.
--- This is application consent only; native admission remains with its owner.
function M.new_migration(source_path, source_kind, native_target, model_store, is_current)
	local class = M.classify(source_kind)
	if not path(source_path, true) or (source_path ~= "" and class ~= "foreign")
		or (source_path == "" and source_kind ~= nil) or not path(native_target, false)
		or (model_store ~= nil and (type(model_store) ~= "string" or model_store:find("[%z\1-\31\127]"))) or type(is_current) ~= "function" then return nil end
	local ok, current = pcall(is_current)
	if not ok or current ~= true then return nil end
	local decision = {}
	issued[decision] = {
		source_path = source_path, source_kind = source_kind, native_target = native_target,
		model_store = model_store, is_current = is_current, selected = false,
	}
	return decision
end

--- Only the actual native-install UI choice calls this operation.
function M.choose(decision, choice)
	local owner = issued[decision]
	if not owner or owner.busy then return false end
	if choice ~= "install_native" then issued[decision] = nil; return false end
	owner.busy = true
	local ok, current = pcall(owner.is_current)
	owner.busy = false
	if issued[decision] ~= owner or not ok or current ~= true then return false end
	owner.selected = true
	return true
end

--- Native adapter consumes this brand, never an object method or plain boolean.
function M.consume(decision, source_path, source_kind, native_target, model_store)
	local owner = issued[decision]
	if not owner or owner.busy or not owner.selected or owner.source_path ~= source_path
		or owner.source_kind ~= source_kind or owner.native_target ~= native_target
		or owner.model_store ~= model_store then return false end
	owner.busy = true
	local ok, current = pcall(owner.is_current)
	owner.busy = false
	if issued[decision] ~= owner or not ok or current ~= true then return false end
	issued[decision] = nil
	-- Continued source/caller currency is not a new installation choice.
	-- The original PTY task owner uses it only at acquisition/start/commit.
	local checking = false
	local function current_context()
		if checking then return false end
		checking = true
		local current_ok, still_current = pcall(owner.is_current)
		checking = false
		return current_ok == true and still_current == true
	end
	return true, current_context
end

function M.cancel(decision)
	if not issued[decision] then return false end
	issued[decision] = nil
	return true
end

return M
