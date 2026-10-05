--- _shared/lua/hotstrings/common_autocorrection_migration.lua

--- ==============================================================================
--- MODULE: Common Autocorrection Override Migration
--- DESCRIPTION:
--- Fans out legacy timing and presentation leaves through the shared validated
--- record owner, then publishes only against the exact observed override source.
--- Config schema migration independently owns activation choices in config.toml.
--- ==============================================================================

local M = {}
local Engine = require("config_migrate")
local Codec = require("toml_codec")
local Writer = require("toml_codec.writer")
local Records = require("config_unused_keys")

M.POLICY_PATH = "data/hotstrings/common_autocorrection_migration.toml"

--- Plan the independent override file without changing a schema stamp.
--- @param source string Exact override source bytes.
--- @param operations table Validated record-operation catalogue.
--- @return table Migration plan or refusal.
function M.plan(source, operations)
	if type(operations) ~= "table" then return { outcome = "failed", detail = "operations must be an array" } end
	local planned, plan = pcall(Engine.plan_operations, source, operations)
	if not planned then return { outcome = "failed", detail = "override planning raised: " .. tostring(plan) } end
	if plan.outcome == "failed" then return plan end
	local ok, document = pcall(Codec.decode, source)
	if not ok or type(document) ~= "table" then
		return { outcome = "failed", detail = "the override source is not valid TOML" }
	end
	local model, detail = Engine.model_from_source(source)
	if not model then return { outcome = "failed", detail = detail } end
	local legacy = type(document.autocorrection) == "table" and document.autocorrection.caps
	if type(legacy) == "table" then
		for _, op in ipairs(operations) do
			if op.op == "copy_if_absent" and legacy[op.key] ~= nil
				and not (model.sections[op.section] and model.sections[op.section][op.key]) then
				return { outcome = "failed", detail = "the legacy override leaf has no addressable record: " .. op.key }
			end
		end
	end
	return plan
end

--- Read, plan and conditionally publish before any override runtime consumes it.
--- Missing files remain absent; consumers retain native partial-publication proofs.
--- @param path string Override file path.
--- @param policy_path string Shared operation catalogue path.
--- @param file_adapter table|nil Native file transaction adapter.
--- @return table result Status, exact acknowledged content and refusal detail.
--- @param on_error function|nil Invocation-scoped native diagnostics callback.
--- @param publish function|nil Consumer-owned conditional publication callback.
function M.run(path, policy_path, file_adapter, on_error, publish)
	if (on_error ~= nil and type(on_error) ~= "function") or (publish ~= nil and type(publish) ~= "function") then
		return { status = "failed", detail = "invalid native publication callback" }
	end
	local source, status, detail = Writer.read_classified(path, file_adapter, on_error)
	if status == "absent" then return { status = "absent" } end
	if status ~= "ok" then return { status = "failed", detail = detail or "override source is unreadable" } end
	local decoded, document = pcall(Codec.decode, source)
	if not decoded or type(document) ~= "table" then
		-- Older native owners deliberately carry unsupported foreign/global
		-- records. They may keep that contract only after proving no legacy
		-- common owner is hidden inside an open value or a parent inline table.
		local scan = Records.scan_records(source)
		local legacy_possible = scan == nil
		local function legacy_path(path)
			return type(path) == "table" and path[1] == "autocorrection"
				and (path[2] == nil or path[2] == "caps")
		end
		for _, header in ipairs(scan and scan.headers or {}) do
			if type(header.segments) == "table" and header.segments[1] == "autocorrection"
				and header.segments[2] == "caps" then legacy_possible = true end
		end
		for _, record in ipairs(scan and scan.records or {}) do
			if legacy_path(record.path) then legacy_possible = true end
		end
		if not legacy_possible then
			return { status = "current", content = source, common_admitted = false }
		end
		return { status = "failed", detail = "the override source is not valid TOML" }
	end
	if type(document.autocorrection) ~= "table" or document.autocorrection.caps == nil then
		return { status = "current", content = source }
	end
	local policy_source, policy_status = Writer.read_classified(policy_path, file_adapter, on_error)
	if policy_status ~= "ok" then return { status = "failed", detail = "the override migration policy is unreadable" } end
	local parsed, policy = pcall(Codec.decode, policy_source)
	if not parsed or type(policy) ~= "table" or type(policy.migration) ~= "table"
		or type(policy.migration.ops) ~= "table" then
		return { status = "failed", detail = "the override migration policy is invalid" }
	end
	local plan = M.plan(source, policy.migration.ops)
	if plan.outcome == "failed" then return { status = "failed", detail = plan.detail } end
	if plan.outcome == "current" then return { status = "current", content = source } end
	local expected = { status = "ok", content = source }
	local published, publish_detail, native = (publish or Writer.publish_if_unchanged)(path, plan.candidate,
		file_adapter, expected, on_error)
	local publication = native ~= nil and { native = native, expected = expected,
		candidate = plan.candidate, on_error = on_error, acknowledged = published == true } or nil
	if published ~= true then
		return { status = "failed", detail = publish_detail or "override publication was refused", publication = publication }
	end
	return { status = "migrated", content = plan.candidate, publication = publication }
end

return M
