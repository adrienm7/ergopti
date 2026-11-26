--- _shared/ai/engine/ollama/runtime_uninstall.lua

--- ==============================================================================
--- MODULE: Managed Ollama Uninstall Sequence
--- DESCRIPTION:
--- The order and outcome of uninstalling the Ollama Ergopti installed (OLL-11
--- of the 2026-11-20 managed Ollama campaign). macOS and Linux run this module;
--- Windows ports it (windows/ai/engine/ollama/runtime_uninstall.ahk). The three
--- replay _shared/tests/corpus/llm/ollama_uninstall_vectors.json.
---
--- Nothing is removed while a download or an installation runs. The models go
--- first, through the running daemon, only when the user chose so; then the
--- daemon stops; then its files go. The first refusal ends the sequence and
--- names its step, so a refused stop removes nothing and a refused model keeps
--- the runtime that can delete it on the next try. Drivers own the dialogs,
--- the processes and the files behind each port.
--- ==============================================================================

local M = {}

--- The locale key of the message each outcome shows.
M.MESSAGES = {
	done = "ollama.uninstall.done",
	done_models = "ollama.uninstall.done_models",
	busy = "ollama.uninstall.reason_busy",
	models = "ollama.uninstall.reason_models",
	stop = "ollama.uninstall.reason_stop",
	files = "ollama.uninstall.reason_files",
}





-- ==================================
-- ==================================
-- ======= 1/ Uninstall Steps =======
-- ==================================
-- ==================================

--- The steps an uninstall runs, in order.
--- @param remove_models boolean Whether the user chose to delete the models.
--- @return table steps Step names: "models", "stop", "files".
function M.plan(remove_models)
	if remove_models == true then return { "models", "stop", "files" } end
	return { "stop", "files" }
end

--- Deletes the listed models one after the other: the model step of the two
--- Lua drivers. The first refusal ends it.
--- @param names table Model names.
--- @param delete function(name, on_done(deleted)) → true once dispatched.
--- @param done function Receives (ok, refused_name) once.
function M.delete_each(names, delete, done)
	local finished, index = false, 0
	local function finish(ok, name)
		if finished then return end
		finished = true
		done(ok, name)
	end
	local next_model
	next_model = function()
		index = index + 1
		local name = names[index]
		if name == nil then return finish(true, nil) end
		local accepted = delete(name, function(deleted)
			if deleted ~= true then return finish(false, name) end
			return next_model()
		end)
		if accepted ~= true then return finish(false, name) end
	end
	return next_model()
end

--- Runs one uninstall over the driver's ports.
--- @param remove_models boolean Whether the user chose to delete the models.
--- @param ports table { busy = fn() → boolean, delete_models = fn(done(ok)),
---   stop = fn(done(ok)), remove_files = fn(remove_models, done(ok)) }
--- @param on_done function Receives { ok, step, message, steps } once: `step`
---   names the refused step ("busy" when nothing ran), `steps` the steps run.
function M.run(remove_models, ports, on_done)
	if type(remove_models) ~= "boolean" then error("runtime_uninstall: remove_models must be a boolean", 2) end
	if type(on_done) ~= "function" or type(ports) ~= "table" then error("runtime_uninstall: missing callback or ports", 2) end
	for _, name in ipairs({ "busy", "delete_models", "stop", "remove_files" }) do
		if type(ports[name]) ~= "function" then error("runtime_uninstall: missing port " .. name, 2) end
	end
	local ran, finished = {}, false
	local function finish(ok, step)
		if finished then return end
		finished = true
		local key = ok and (remove_models and "done_models" or "done") or step
		on_done({ ok = ok, step = step, message = M.MESSAGES[key], steps = ran })
	end
	if ports.busy() == true then return finish(false, "busy") end
	local steps = M.plan(remove_models)
	local index = 0
	local advance
	advance = function()
		index = index + 1
		local step = steps[index]
		if step == nil then return finish(true, nil) end
		ran[#ran + 1] = step
		local answered = false
		local function done(ok)
			if answered or finished then return end
			answered = true
			if ok ~= true then return finish(false, step) end
			return advance()
		end
		local called, err
		if step == "models" then called, err = pcall(ports.delete_models, done)
		elseif step == "stop" then called, err = pcall(ports.stop, done)
		else called, err = pcall(ports.remove_files, remove_models, done) end
		if not called then
			answered = true
			finish(false, step)
			error(err, 0)
		end
	end
	advance()
end

return M
