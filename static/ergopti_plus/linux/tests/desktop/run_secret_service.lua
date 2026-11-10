--- tests/desktop/run_secret_service.lua

--- ==============================================================================
--- MODULE: API Keys In A Locked Real Secret Service
--- DESCRIPTION:
--- One phase per process, so the second is a restart of the first:
--- * add: with the login keyring of a real gnome-keyring-daemon locked,
---   modules/llm/api_entries.lua add() stores a key through the real
---   secret-tool. GNOME's unlock prompt (gcr-prompter) must open while the
---   store runs inside ui/modal.lua, i.e. inside keyboard_hook.while_released,
---   the call that hands the grabbed keyboard to the desktop; a watcher types
---   the keyring password into that prompt on the session keyboard. The file
---   must then hold a reference, the service the key.
--- * migrate: the launcher locks the keyring again, this phase appends an
---   entry an earlier build wrote in plaintext; migrate_plaintext(), as the daemon runs
---   it at boot, must open the prompt again, move that key to the service and
---   rewrite the file without it, while the first entry's key still loads.
---
--- Exit 0 = every check held. 1 = a failure. 2 = no environment.
--- ==============================================================================

local WAIT_SECONDS = 20
local FIRST_KEY  = "sk-proof-locked-keyring-0001"
local SECOND_KEY = "sk-proof-plaintext-migrated-0002"

local _failures, _checks = 0, 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print(string.format("  %s %s", condition and "ok  " or "FAIL", what))
end

local phase, scratch, password = assert(arg[1]), assert(arg[2]), assert(arg[3])
require("compat.utf8").install()
local quote = require("text_utils").shell_quote
local Json = require("json")

--- @param path string
--- @return string|nil
local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	return text
end

--- Starts the watcher that answers GNOME's unlock prompt, and records what
--- it saw: the prompt's title, and whether the keyboard was handed over.
--- @param marker string The file present while the keyboard is released.
--- @param report string Where the watcher writes what it saw.
local function watch_prompt(marker, report)
	os.remove(report)
	os.execute("( id=$(timeout " .. WAIT_SECONDS .. " xdotool search --sync --onlyvisible --class gcr-prompter | head -n 1)"
		.. ' && sleep 1 && released=no && { [ -e ' .. quote(marker) .. ' ] && released=yes; }'
		.. ' && printf "%s|%s\\n" "$(xdotool getwindowname "$id")" "$released" > ' .. quote(report)
		.. " && xdotool windowactivate --sync \"$id\" type --delay 20 " .. quote(password)
		.. " && xdotool key Return ) >/dev/null 2>&1 &")
end

--- Wraps the real hand-over of the keyboard so the watcher can tell that
--- the prompt is open while the keyboard is the desktop's.
--- @param marker string
local function observe_release(marker)
	local Hook = require("adapters.keyboard_hook")
	local release = Hook.while_released
	Hook.while_released = function(fn, opts)
		local file = assert(io.open(marker, "w"))
		file:close()
		local results = { pcall(release, fn, opts) }
		os.remove(marker)
		if not results[1] then error(results[2], 0) end
		return unpack(results, 2)
	end
end

--- The prompt the watcher answered, or nil.
--- @param report string
--- @return string|nil title
--- @return boolean released
local function prompt_seen(report)
	local text = read_file(report)
	if not text then return nil, false end
	local title, released = text:match("^(.-)|(%a+)\n$")
	return title, released == "yes"
end

local Entries = require("modules.llm.api_entries")
local TokenStore = require("modules.llm.api_token_store")
local marker, report = scratch .. "/released", scratch .. "/prompt"
observe_release(marker)

if phase == "add" then
	print("=== add a key with the keyring locked ===")
	watch_prompt(marker, report)
	local entry, err = Entries.add({ provider = "openai", label = "Proof", token = FIRST_KEY })
	check(entry ~= nil, "the entry is saved: " .. tostring(err))
	local title, released = prompt_seen(report)
	check(title ~= nil, "GNOME's unlock prompt opens: " .. tostring(title))
	check(released, "the prompt opens while the keyboard is handed to the desktop (ui/modal.lua)")
	local source = read_file(Entries.path()) or ""
	local stored = Json.decode(source)
	local reference = stored and stored.entries and stored.entries[1] and stored.entries[1].token
	check(TokenStore.is_reference(reference) and not source:find(FIRST_KEY, 1, true),
		"api_keys.json holds a secret-service reference, not the key")
	local found = reference and TokenStore.lookup_many({ reference }) or {}
	check(found[reference] == FIRST_KEY, "the secret service returns the key for that reference")
	local file = assert(io.open(scratch .. "/first_id", "w"))
	file:write(entry and entry.id or "")
	file:close()
elseif phase == "migrate" then
	print("=== restart: migrate a plaintext key with the keyring locked ===")
	local first_id = read_file(scratch .. "/first_id") or ""
	-- What an earlier build wrote: the key itself in the token field. Appended
	-- before the first read of the file, as a boot finds it.
	local root = assert(Json.decode(assert(read_file(Entries.path()))))
	root.entries[#root.entries + 1] = { id = "openai-plaintext-proof", provider = "openai",
		label = "Plaintext", token = SECOND_KEY, model = "", base_url = "" }
	local file = assert(io.open(Entries.path(), "wb"))
	file:write(Json.encode(root))
	file:close()
	watch_prompt(marker, report)
	check(Entries.migrate_plaintext() == true, "migrate_plaintext moves the plaintext key")
	local title, released = prompt_seen(report)
	check(title ~= nil, "GNOME's unlock prompt opens again: " .. tostring(title))
	check(released, "the prompt opens while the keyboard is handed to the desktop (ui/modal.lua)")
	local source = read_file(Entries.path()) or ""
	check(not source:find(SECOND_KEY, 1, true) and not source:find(FIRST_KEY, 1, true),
		"api_keys.json no longer holds either key in plaintext")
	local stored = Json.decode(source) or { entries = {} }
	local references = {}
	for _, raw in ipairs(stored.entries) do references[#references + 1] = raw.token end
	local found = TokenStore.lookup_many(references) or {}
	check(#references == 2 and found[references[1]] == FIRST_KEY and found[references[2]] == SECOND_KEY,
		"both references resolve to their keys in the secret service")
	check(Entries.get(first_id) ~= nil and Entries.get(first_id).token == FIRST_KEY,
		"the key saved before the restart still loads")
else
	error("unknown phase " .. phase)
end
print(string.format("=== %d check(s), %d failure(s), phase %s ===", _checks, _failures, phase))
os.exit(_failures == 0 and 0 or 1)
