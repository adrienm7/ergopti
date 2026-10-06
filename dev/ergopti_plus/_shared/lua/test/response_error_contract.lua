--- _shared/lua/test/response_error_contract.lua

--- ==============================================================================
--- MODULE: Shared Lua Provider Error Response Contract
--- DESCRIPTION:
--- Explicit expectations for Lua completion extraction with retained JSON error
--- fields. Linux registered provider tests and native public HTTP receipts consume
--- these independent values; foreign JSON adapters and classifiers require their
--- own native validation before adopting this contract. Existing universal parser
--- corpora and their first-part selection remain unchanged.
--- ==============================================================================

local M = {}

M.vectors = {
	{
		name = "openai top-level object error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":{\"message\":\"Provider refused fixture request\"}}",
	},
	{
		name = "openai top-level string error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":\"provider refused\"}",
	},
	{
		name = "openai top-level false error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":false}",
	},
	{
		name = "openai top-level null error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":null}",
	},
	{
		name = "openai healthy retry",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}]}",
		expected = "decoy completion",
	},
	{
		name = "openai nested error metadata",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"metadata\":{\"error\":{\"message\":\"not a provider envelope\"}}}",
		expected = "decoy completion",
	},
	{
		name = "anthropic top-level object error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":{\"message\":\"Provider refused fixture request\"}}",
	},
	{
		name = "anthropic top-level string error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":\"provider refused\"}",
	},
	{
		name = "anthropic top-level false error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":false}",
	},
	{
		name = "anthropic top-level null error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":null}",
	},
	{
		name = "anthropic healthy retry",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}]}",
		expected = "decoy completion",
	},
	{
		name = "anthropic nested error metadata",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"metadata\":{\"error\":{\"message\":\"not a provider envelope\"}}}",
		expected = "decoy completion",
	},
	{
		name = "gemini top-level object error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":{\"message\":\"Provider refused fixture request\"}}",
	},
	{
		name = "gemini top-level string error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":\"provider refused\"}",
	},
	{
		name = "gemini top-level false error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":false}",
	},
	{
		name = "gemini top-level null error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":null}",
	},
	{
		name = "gemini healthy retry",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}]}",
		expected = "decoy completion",
	},
	{
		name = "gemini nested error metadata",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"metadata\":{\"error\":{\"message\":\"not a provider envelope\"}}}",
		expected = "decoy completion",
	},
	{
		name = "anthropic first block policy",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"text\",\"text\":\"second\"}]}",
		expected = "first",
	},
	{
		name = "gemini first part policy",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"private\"},{\"text\":\"first\"},{\"text\":\"second\"}]}},{\"content\":{\"parts\":[{\"text\":\"other candidate\"}]}}]}",
		expected = "first",
	},
	{
		name = "openai escaped literal and Unicode",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"é 😀 literal \\\\n and \\\"quoted\\\"\"}}]}",
		expected = "é 😀 literal \\n and \"quoted\"",
	},
	{
		name = "openai error only",
		format = "openai",
		body = "{\"error\":{\"message\":\"failure\"}}",
	},
	{
		name = "gemini thoughts only",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"private\"}]}}]}",
	},
}

return M
