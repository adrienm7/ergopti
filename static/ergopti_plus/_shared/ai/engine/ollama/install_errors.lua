--- _shared/ai/engine/ollama/install_errors.lua

--- ==============================================================================
--- MODULE: Managed Ollama Install Error Classes
--- DESCRIPTION:
--- Names why a managed Ollama runtime install failed, from one evidence line,
--- with the closed classes of _shared/ai/data/ollama_install_errors.json, and
--- holds the free-space rule checked before its download. The macOS and Linux
--- drivers read the data file and hand it here; the Windows driver applies the
--- same file (windows/ai/engine/ollama/install_errors.ahk). The three suites
--- replay _shared/tests/corpus/llm/ollama_install_error_vectors.json.
--- ==============================================================================

local M = {}

--- The class an install failure shows when no row of the data file matches.
M.UNKNOWN = "unknown"

--- Admits the decoded data file; a malformed one is a broken install.
--- @param data table Decoded ollama_install_errors.json.
--- @return table classifier { classify(evidence), message_key(class) }.
function M.new(data)
	if type(data) ~= "table" or data.schema_version ~= 1 or type(data.messages) ~= "table"
		or type(data.classes) ~= "table" or #data.classes == 0 then
		error("ollama_install_errors.json is malformed", 2)
	end
	if type(data.messages[M.UNKNOWN]) ~= "string" then
		error("ollama_install_errors.json names no message for its unknown class", 2)
	end
	local rows = {}
	for index, row in ipairs(data.classes) do
		local needle, class = type(row) == "table" and row[1], type(row) == "table" and row[2]
		if type(needle) ~= "string" or needle == "" or needle ~= needle:lower()
			or type(class) ~= "string" or type(data.messages[class]) ~= "string" then
			error("ollama_install_errors.json class row " .. index .. " is malformed", 2)
		end
		rows[index] = { needle, class }
	end
	local messages = {}
	for class, key in pairs(data.messages) do
		if type(class) ~= "string" or type(key) ~= "string" or not key:match("^ollama%.install_error%.[a-z_]+$") then
			error("ollama_install_errors.json message of " .. tostring(class) .. " is malformed", 2)
		end
		messages[class] = key
	end
	local classifier = {}

	--- Names the class of one failure, first matching row wins.
	--- @param evidence string The driver's evidence line.
	--- @return string class A class of the data file, "unknown" when no row matches.
	function classifier.classify(evidence)
		if type(evidence) ~= "string" then error("install failure evidence must be a string", 2) end
		local lowered = evidence:lower()
		for _, row in ipairs(rows) do
			if lowered:find(row[1], 1, true) then return row[2] end
		end
		return M.UNKNOWN
	end

	--- The locale key a class shows.
	--- @param class string A class classify() returned.
	--- @return string key
	function classifier.message_key(class)
		local key = messages[class]
		if not key then error("unknown Ollama install error class " .. tostring(class), 2) end
		return key
	end

	return classifier
end

--- Tells whether the pinned archive may start downloading: the archive, the
--- runtime it unpacks to and the registry margin must be free on the install
--- volume, since the archive stays until its extraction ends (OLL-14).
--- @param asset_bytes number Pinned archive size.
--- @param unpacked_bytes number Pinned unpacked runtime size.
--- @param margin_bytes number [limits] ollama_install_free_space_margin_bytes.
--- @param free_bytes number Bytes free for the user on the install volume.
--- @return boolean fits
function M.fits(asset_bytes, unpacked_bytes, margin_bytes, free_bytes)
	local values = { asset_bytes, unpacked_bytes, margin_bytes, free_bytes }
	for index = 1, 4 do
		local value = values[index]
		if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
			error("free-space inputs must be non-negative integers", 2)
		end
	end
	return free_bytes >= asset_bytes + unpacked_bytes + margin_bytes
end

return M
