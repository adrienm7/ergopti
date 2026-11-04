--- _shared/lua/llm/model_catalogue.lua

--- ==============================================================================
--- MODULE: Model Catalogue Projection
--- DESCRIPTION:
--- Projects the shared model catalogue into the exact rows consumed by the
--- shared model selector page. macOS and Linux use this module so parameter,
--- hardware, URL, runtime-name, and installed-state rules cannot drift; the
--- Windows twin (ui/model_browser/init.ahk) is pinned to the same row fields by
--- tools/test/test-model-selector-page.cjs.
--- ==============================================================================

local M = {}

--- Reduces a model identity to the key both drivers compare on.
---
--- Public because the comparison has to be the SAME one everywhere. `M.build`
--- uses it to decide which row is active; a caller's installed-state lookup uses
--- it to decide which rows are installed. Two copies of this rule would let the
--- browser mark "Qwen3:latest" active while reporting it as not installed, so
--- there is exactly one (llm-model-identity-single-normaliser).
--- @param value any Display name or backend-native tag.
--- @return string Comparison key; empty for a non-string.
function M.normalise_name(value)
	if type(value) ~= "string" then return "" end
	return (value:lower():gsub("%s+", ""):gsub(":latest$", ""))
end

local normalise_name = M.normalise_name

--- Parses a parameter-count string ("8.03B", "750M") into billions.
--- @param value string|number
--- @return number
function M.parse_billions(value)
	if type(value) == "number" then return value end
	if type(value) ~= "string" then return 0 end
	local number = tonumber(value:match("([%d%.]+)")) or 0
	if value:upper():find("M", 1, true) and not value:upper():find("B", 1, true) then
		number = number / 1000
	end
	return number
end

--- Resolves the backend-native identity carried by a catalogue model.
--- @param model table
--- @param backend string
--- @return string|nil
function M.runtime_name(model, backend)
	if type(model) ~= "table" then return nil end
	local source = type(model.urls) == "table" and model.urls[backend] or nil
	if type(source) ~= "string" or source == "" then return nil end
	if backend == "ollama" then
		local tag = source:match("^https://ollama%.com/library/([^/?#]+)")
		if tag then return tag end
	end
	local name = model.name or model.repo
	return type(name) == "string" and name ~= "" and name or nil
end

--- Builds the normalised payload expected by injectModels().
--- @param catalogue table Decoded models.json.
--- @param backend string "mlx" or "ollama".
--- @param active_model string|nil Backend-native or display identity.
--- @param is_installed function|nil Called with (display_name, runtime_name).
--- @return table { backend, active, models }
function M.build(catalogue, backend, active_model, is_installed)
	backend = type(backend) == "string" and backend ~= "" and backend or "ollama"
	local rows = {}
	local active = type(active_model) == "string" and active_model or ""
	local active_key = normalise_name(active)
	for _, provider in ipairs(type(catalogue) == "table" and catalogue or {}) do
		for _, family in ipairs(type(provider.families) == "table" and provider.families or {}) do
			for _, model in ipairs(type(family.models) == "table" and family.models or {}) do
				local display_name = model.name or model.repo
				local runtime_name = M.runtime_name(model, backend)
				if type(display_name) == "string" and display_name ~= "" and runtime_name then
					local parameters = type(model.parameters) == "table" and model.parameters or {}
					local total = M.parse_billions(parameters.total)
					local active_parameters = M.parse_billions(parameters.active)
					if active_parameters <= 0 then active_parameters = total end
					local requirements = type(model.hardware_requirements) == "table"
						and model.hardware_requirements[backend] or nil
					local capabilities = type(model.capabilities) == "table"
						and model.capabilities or {}
					local installed = false
					if type(is_installed) == "function" then
						local ok, result = pcall(is_installed, display_name, runtime_name)
						installed = ok and result == true
					end
					rows[#rows + 1] = {
						name = display_name,
						runtime_name = runtime_name,
						family = type(family.label) == "string" and family.label or "",
						provider = type(provider.label) == "string" and provider.label or "",
						params_b = total,
						active_b = active_parameters,
						is_moe = active_parameters > 0 and active_parameters < total,
						ram_gb = tonumber(type(requirements) == "table" and requirements.ram_gb) or 0,
						-- The weights' download is what the model occupies on disk.
						disk_gb = tonumber(type(requirements) == "table" and requirements.download_gb) or 0,
						backend = backend,
						speed_tok_s = tonumber(capabilities.speed_tok_s) or 0,
						type = type(model.type) == "string" and model.type or "chat",
						installed = installed,
						url = type(model.urls) == "table"
							and (model.urls.hf or model.urls[backend]) or "",
					}
					if active_key ~= "" and (normalise_name(display_name) == active_key
							or normalise_name(runtime_name) == active_key) then
						active = display_name
					end
				end
			end
		end
	end
	return { backend = backend, active = active, models = rows }
end

--- Builds the selector page payload: every backend the driver offers, each
--- with its availability, and the rows of each in one list.
--- @param catalogue table Decoded models.json.
--- @param spec table {
---   active_backend = string, active_model = string|nil,
---   backends = { { id, brand, emoji, kind, available = boolean, reason_key = string|nil,
---                  is_installed = function|nil, extra_rows = table|nil, default_model = string|nil } },
---   capabilities = table|nil }
--- @return table { backend, active, backends, models, capabilities }
function M.build_selector(catalogue, spec)
	if type(spec) ~= "table" or type(spec.backends) ~= "table" then
		error("model_catalogue.build_selector: spec.backends is required")
	end
	local active_backend = spec.active_backend
	local models, backends, active = {}, {}, ""
	for _, backend in ipairs(spec.backends) do
		if type(backend.id) ~= "string" or backend.id == "" then
			error("model_catalogue.build_selector: a backend has no id")
		end
		backends[#backends + 1] = {
			id = backend.id, brand = backend.brand, emoji = backend.emoji, kind = backend.kind,
			available = backend.available == true, reason_key = backend.reason_key,
		}
		local is_active = backend.id == active_backend
		local rows
		if backend.kind == "local" then
			local payload = M.build(catalogue, backend.id, is_active and spec.active_model or nil, backend.is_installed)
			rows = payload.models
			if is_active then active = payload.active end
			local default_key = normalise_name(backend.default_model)
			for _, row in ipairs(rows) do
				if default_key ~= "" and (normalise_name(row.name) == default_key
						or normalise_name(row.runtime_name) == default_key) then
					row.is_default = true
				end
			end
		else
			rows = {}
		end
		for _, extra in ipairs(type(backend.extra_rows) == "table" and backend.extra_rows or {}) do
			extra.backend = backend.id
			rows[#rows + 1] = extra
			if is_active and type(spec.active_model) == "string" and spec.active_model ~= ""
					and normalise_name(extra.name) == normalise_name(spec.active_model) then
				active = extra.name
			end
		end
		for _, row in ipairs(rows) do models[#models + 1] = row end
	end
	if active == "" and type(spec.active_model) == "string" then active = spec.active_model end
	return {
		backend = active_backend, active = active, backends = backends, models = models,
		capabilities = type(spec.capabilities) == "table" and spec.capabilities or {},
	}
end

return M
