--- tests/fixtures/llm_response_syntax_contract.lua

--- ==============================================================================
--- MODULE: Linux Structured Completion Syntax Contract
--- DESCRIPTION:
--- Independent expected replies and refusals for the canonical strict JSON owner.
--- Registered provider tests and real public HTTP receipts share these values.
--- Duplicate keys, lone surrogates and non-finite decoded numbers are explicit
--- strict-owner refusals, separate from malformed JSON grammar. This contract does
--- not broaden the universal provider corpus or change first-part selection.
--- ==============================================================================

local M = {}

M.vectors = {
	{
		name = "openai malformed unknown escape",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"A\\qB\"}}]}",
		admission = "malformed",
	},
	{
		name = "openai malformed non-hex Unicode escape",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"\\u 061\"}}]}",
		admission = "malformed",
	},
	{
		name = "openai malformed raw tab",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"A\tB\"}}]}",
		admission = "malformed",
	},
	{
		name = "openai malformed raw line feed",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"A\nB\"}}]}",
		admission = "malformed",
	},
	{
		name = "openai malformed leading-zero metadata",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy\"}}],\"usage\":{\"tokens\":01}}",
		admission = "malformed",
	},
	{
		name = "openai malformed trailing-decimal metadata",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy\"}}],\"usage\":{\"tokens\":1.}}",
		admission = "malformed",
	},
	{
		name = "openai strict refusal duplicate metadata keys",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy\"}}],\"usage\":{\"tokens\":1,\"tokens\":2}}",
		admission = "strict",
	},
	{
		name = "openai strict refusal lone high surrogate",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"\\ud800\"}}]}",
		admission = "strict",
	},
	{
		name = "openai strict refusal lone low surrogate",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"\\udfff\"}}]}",
		admission = "strict",
	},
	{
		name = "openai strict refusal non-finite metadata",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy\"}}],\"usage\":{\"tokens\":1e999}}",
		admission = "strict",
	},
	{
		name = "openai healthy retry",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"valid reply\"}}]}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "openai escaped Unicode pair",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"\\u00e9 \\ud83d\\ude00 \\\\n\"}}]}",
		admission = "healthy",
		expected = "é 😀 \\n",
	},
	{
		name = "openai typed null",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":null}}]}",
		admission = "healthy",
	},
	{
		name = "openai typed false",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":false}}]}",
		admission = "healthy",
	},
	{
		name = "openai retained null array metadata",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"valid reply\"}}],\"usage\":{\"items\":[null,[],{},false],\"absent\":null}}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "openai nested error metadata",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"valid reply\"}}],\"metadata\":{\"error\":null}}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "openai escaped control text",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"line\\nnext\\ttab\\\"quote\"}}]}",
		admission = "healthy",
		expected = "line\nnext\ttab\"quote",
	},
	{
		name = "openai first selection with retained array shape",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"first\"}},{\"message\":{\"content\":\"second\"}}]}",
		admission = "healthy",
		expected = "first",
	},
	{
		name = "anthropic malformed unknown escape",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"A\\qB\"}]}",
		admission = "malformed",
	},
	{
		name = "anthropic malformed non-hex Unicode escape",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"\\u 061\"}]}",
		admission = "malformed",
	},
	{
		name = "anthropic malformed raw tab",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"A\tB\"}]}",
		admission = "malformed",
	},
	{
		name = "anthropic malformed raw line feed",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"A\nB\"}]}",
		admission = "malformed",
	},
	{
		name = "anthropic malformed leading-zero metadata",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy\"}],\"usage\":{\"tokens\":01}}",
		admission = "malformed",
	},
	{
		name = "anthropic malformed trailing-decimal metadata",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy\"}],\"usage\":{\"tokens\":1.}}",
		admission = "malformed",
	},
	{
		name = "anthropic strict refusal duplicate metadata keys",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy\"}],\"usage\":{\"tokens\":1,\"tokens\":2}}",
		admission = "strict",
	},
	{
		name = "anthropic strict refusal lone high surrogate",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"\\ud800\"}]}",
		admission = "strict",
	},
	{
		name = "anthropic strict refusal lone low surrogate",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"\\udfff\"}]}",
		admission = "strict",
	},
	{
		name = "anthropic strict refusal non-finite metadata",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy\"}],\"usage\":{\"tokens\":1e999}}",
		admission = "strict",
	},
	{
		name = "anthropic healthy retry",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"valid reply\"}]}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "anthropic escaped Unicode pair",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"\\u00e9 \\ud83d\\ude00 \\\\n\"}]}",
		admission = "healthy",
		expected = "é 😀 \\n",
	},
	{
		name = "anthropic typed null",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":null}]}",
		admission = "healthy",
	},
	{
		name = "anthropic typed false",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":false}]}",
		admission = "healthy",
	},
	{
		name = "anthropic retained null array metadata",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"valid reply\"}],\"usage\":{\"items\":[null,[],{},false],\"absent\":null}}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "anthropic nested error metadata",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"valid reply\"}],\"metadata\":{\"error\":null}}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "anthropic escaped control text",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"line\\nnext\\ttab\\\"quote\"}]}",
		admission = "healthy",
		expected = "line\nnext\ttab\"quote",
	},
	{
		name = "anthropic first selection with retained array shape",
		format = "anthropic",
		body = "{\"content\":[null,{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"text\",\"text\":\"second\"}]}",
		admission = "healthy",
		expected = "first",
	},
	{
		name = "gemini malformed unknown escape",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"A\\qB\"}]}}]}",
		admission = "malformed",
	},
	{
		name = "gemini malformed non-hex Unicode escape",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\\u 061\"}]}}]}",
		admission = "malformed",
	},
	{
		name = "gemini malformed raw tab",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"A\tB\"}]}}]}",
		admission = "malformed",
	},
	{
		name = "gemini malformed raw line feed",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"A\nB\"}]}}]}",
		admission = "malformed",
	},
	{
		name = "gemini malformed leading-zero metadata",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy\"}]}}],\"usage\":{\"tokens\":01}}",
		admission = "malformed",
	},
	{
		name = "gemini malformed trailing-decimal metadata",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy\"}]}}],\"usage\":{\"tokens\":1.}}",
		admission = "malformed",
	},
	{
		name = "gemini strict refusal duplicate metadata keys",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy\"}]}}],\"usage\":{\"tokens\":1,\"tokens\":2}}",
		admission = "strict",
	},
	{
		name = "gemini strict refusal lone high surrogate",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\\ud800\"}]}}]}",
		admission = "strict",
	},
	{
		name = "gemini strict refusal lone low surrogate",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\\udfff\"}]}}]}",
		admission = "strict",
	},
	{
		name = "gemini strict refusal non-finite metadata",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy\"}]}}],\"usage\":{\"tokens\":1e999}}",
		admission = "strict",
	},
	{
		name = "gemini healthy retry",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"valid reply\"}]}}]}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "gemini escaped Unicode pair",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\\u00e9 \\ud83d\\ude00 \\\\n\"}]}}]}",
		admission = "healthy",
		expected = "é 😀 \\n",
	},
	{
		name = "gemini typed null",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":null}]}}]}",
		admission = "healthy",
	},
	{
		name = "gemini typed false",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":false}]}}]}",
		admission = "healthy",
	},
	{
		name = "gemini retained null array metadata",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"valid reply\"}]}}],\"usage\":{\"items\":[null,[],{},false],\"absent\":null}}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "gemini nested error metadata",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"valid reply\"}]}}],\"metadata\":{\"error\":null}}",
		admission = "healthy",
		expected = "valid reply",
	},
	{
		name = "gemini escaped control text",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"line\\nnext\\ttab\\\"quote\"}]}}]}",
		admission = "healthy",
		expected = "line\nnext\ttab\"quote",
	},
	{
		name = "gemini first selection with retained array shape",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[null,{\"thought\":true,\"text\":\"private\"},{\"text\":\"first\"},{\"text\":\"second\"}]}},{\"content\":{\"parts\":[{\"text\":\"other candidate\"}]}}]}",
		admission = "healthy",
		expected = "first",
	},
}

return M
