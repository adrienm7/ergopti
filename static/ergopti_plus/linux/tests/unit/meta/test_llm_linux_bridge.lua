--- tests/unit/meta/test_llm_linux_bridge.lua

local helpers = require("tests.helpers")
local LB       = helpers.load_module("llm.linux_bridge")

helpers.describe("llm.linux_bridge", function()

  -- ==========================================================================
  -- 1. resolve_base_url()
  -- ==========================================================================

  helpers.describe("resolve_base_url()", function()
    helpers.it("returns default URL with no overrides", function()
      local url = LB.resolve_base_url()
      helpers.assert_eq(url, "http://127.0.0.1:11434/api/chat")
    end)

    helpers.it("uses custom port", function()
      local url = LB.resolve_base_url(12345)
      helpers.assert_eq(url, "http://127.0.0.1:12345/api/chat")
    end)

    helpers.it("uses custom host", function()
      local url = LB.resolve_base_url(nil, "10.0.0.5")
      helpers.assert_eq(url, "http://10.0.0.5:11434/api/chat")
    end)

    helpers.it("uses both custom host and port", function()
      local url = LB.resolve_base_url(8080, "ollama.local")
      helpers.assert_eq(url, "http://ollama.local:8080/api/chat")
    end)

    helpers.it("returns empty string for port below minimum", function()
      helpers.assert_eq(LB.resolve_base_url(80), "")
    end)

    helpers.it("returns empty string for port above maximum", function()
      helpers.assert_eq(LB.resolve_base_url(70000), "")
    end)

    helpers.it("floors non-integer ports", function()
      local url = LB.resolve_base_url(11434.9)
      helpers.assert_eq(url, "http://127.0.0.1:11434/api/chat")
    end)
  end)

  -- ==========================================================================
  -- 2. json_encode()
  -- ==========================================================================

  helpers.describe("json_encode()", function()
    helpers.it("encodes nil as null", function()
      helpers.assert_eq(LB.json_encode(nil), "null")
    end)

    helpers.it("encodes booleans", function()
      helpers.assert_eq(LB.json_encode(true), "true")
      helpers.assert_eq(LB.json_encode(false), "false")
    end)

    helpers.it("encodes integers", function()
      helpers.assert_eq(LB.json_encode(42), "42")
      helpers.assert_eq(LB.json_encode(0), "0")
      helpers.assert_eq(LB.json_encode(-17), "-17")
    end)

    helpers.it("handles NaN and infinity", function()
      helpers.assert_eq(LB.json_encode(0 / 0), "null")
      helpers.assert_eq(LB.json_encode(math.huge), "null")
      helpers.assert_eq(LB.json_encode(-math.huge), "null")
    end)

    helpers.it("encodes strings with escaping", function()
      helpers.assert_eq(LB.json_encode("hello"), '"hello"')
      helpers.assert_eq(LB.json_encode('say "hi"'), '"say \\"hi\\""')
      helpers.assert_eq(LB.json_encode("a\\b"), '"a\\\\b"')
      helpers.assert_eq(LB.json_encode("line1\nline2"), '"line1\\nline2"')
      helpers.assert_eq(LB.json_encode("tab\there"), '"tab\\there"')
    end)

    helpers.it("encodes arrays", function()
      helpers.assert_eq(LB.json_encode({1, 2, 3}), "[1,2,3]")
      helpers.assert_eq(LB.json_encode({"a", "b"}), '["a","b"]')
    end)

    helpers.it("encodes objects (sorted keys)", function()
      local result = LB.json_encode({b = 2, a = 1})
      -- Keys sorted alphabetically
      helpers.assert_eq(result, '{"a":1,"b":2}')
    end)

    helpers.it("encodes nested structures", function()
      local result = LB.json_encode({
        model = "llama3.2",
        messages = {
          {role = "user", content = "hello"},
        },
      })
      helpers.assert_true(result:find('"model"'), "has model key")
      helpers.assert_true(result:find('"messages"'), "has messages key")
      helpers.assert_true(result:find('"llama3.2"'), "has model value")
    end)
  end)

  -- ==========================================================================
  -- 3. json_decode()
  -- ==========================================================================

  helpers.describe("json_decode()", function()
    helpers.it("decodes a simple object", function()
      local v = LB.json_decode('{"a":1,"b":2}')
      helpers.assert_eq(v.a, 1)
      helpers.assert_eq(v.b, 2)
    end)

    helpers.it("decodes an array", function()
      local v = LB.json_decode('[1,2,3]')
      helpers.assert_eq(#v, 3)
      helpers.assert_eq(v[1], 1)
    end)

    helpers.it("decodes strings", function()
      local v = LB.json_decode('"hello"')
      helpers.assert_eq(v, "hello")
    end)

    helpers.it("decodes booleans and null", function()
      helpers.assert_eq(LB.json_decode("true"), true)
      helpers.assert_eq(LB.json_decode("false"), false)
    end)

    helpers.it("returns nil on invalid JSON", function()
      helpers.assert_eq(LB.json_decode("not json"), nil)
      helpers.assert_eq(LB.json_decode("{broken"), nil)
    end)

    helpers.it("returns nil on empty string", function()
      helpers.assert_eq(LB.json_decode(""), nil)
    end)

    helpers.it("returns nil on non-string input", function()
      helpers.assert_eq(LB.json_decode(nil), nil)
      helpers.assert_eq(LB.json_decode(42), nil)
    end)
  end)

  -- ==========================================================================
  -- 4. build_payload()
  -- ==========================================================================

  helpers.describe("build_payload()", function()
    helpers.it("builds minimal payload with defaults", function()
      local payload = LB.build_payload("test buffer")
      helpers.assert_eq(payload.model, "llama3.2")
      helpers.assert_eq(payload.stream, false)
      helpers.assert_eq(payload.keep_alive, "30m")
      helpers.assert_eq(#payload.messages, 1)  -- user only, no system
      helpers.assert_eq(payload.messages[1].role, "user")
      helpers.assert_eq(payload.messages[1].content, "test buffer")
    end)

    helpers.it("includes system prompt when provided", function()
      local payload = LB.build_payload("test buffer", {
        system_prompt = "You are a helpful assistant.",
      })
      helpers.assert_eq(#payload.messages, 2)
      helpers.assert_eq(payload.messages[1].role, "system")
      helpers.assert_eq(payload.messages[1].content, "You are a helpful assistant.")
      helpers.assert_eq(payload.messages[2].role, "user")
    end)

    helpers.it("respects custom model, tokens, temperature", function()
      local payload = LB.build_payload("hi", {
        model = "codellama",
        max_tokens = 256,
        temperature = 0.3,
      })
      helpers.assert_eq(payload.model, "codellama")
      helpers.assert_eq(payload.options.temperature, 0.3)
      helpers.assert_eq(payload.options.num_predict, 256)  -- max_tokens * num_preds (1)
    end)

    helpers.it("respects num_predictions in options", function()
      local payload = LB.build_payload("hi", {
        max_tokens = 100,
        num_predictions = 3,
      })
      helpers.assert_eq(payload.options.num_predict, 300)
    end)

    helpers.it("respects stream flag", function()
      local payload = LB.build_payload("hi", { stream = true })
      helpers.assert_eq(payload.stream, true)
    end)

    helpers.it("respects custom keep_alive", function()
      local payload = LB.build_payload("hi", { keep_alive = "5m" })
      helpers.assert_eq(payload.keep_alive, "5m")
    end)
  end)

  -- ==========================================================================
  -- 5. parse_response()
  -- ==========================================================================

  helpers.describe("parse_response()", function()
    helpers.it("parses a valid Ollama chat response", function()
      local body = '{"model":"llama3.2","message":{"role":"assistant","content":"Hello!"}}'
      helpers.assert_eq(LB.parse_response(body), "Hello!")
    end)

    helpers.it("parses a legacy generate-style response", function()
      local body = '{"model":"llama3.2","response":"Bonjour"}'
      helpers.assert_eq(LB.parse_response(body), "Bonjour")
    end)

    helpers.it("returns nil on non-string input", function()
      helpers.assert_eq(LB.parse_response(nil), nil)
      helpers.assert_eq(LB.parse_response(42), nil)
    end)

    helpers.it("returns nil on empty string", function()
      helpers.assert_eq(LB.parse_response(""), nil)
    end)

    helpers.it("returns nil on unparseable JSON", function()
      helpers.assert_eq(LB.parse_response("not json"), nil)
    end)

    helpers.it("returns nil when message.content is missing", function()
      local body = '{"model":"llama3.2","message":{"role":"assistant"}}'
      helpers.assert_eq(LB.parse_response(body), nil)
    end)
  end)

  -- ==========================================================================
  -- 6. parse_stream_line()
  -- ==========================================================================

  helpers.describe("parse_stream_line()", function()
    helpers.it("parses a token from streaming NDJSON", function()
      local line = '{"model":"llama3.2","message":{"role":"assistant","content":"He"}}'
      helpers.assert_eq(LB.parse_stream_line(line), "He")
    end)

    helpers.it("returns nil on empty content (done signal)", function()
      local line = '{"model":"llama3.2","message":{"role":"assistant","content":""}}'
      helpers.assert_eq(LB.parse_stream_line(line), nil)
    end)

    helpers.it("returns nil on empty line", function()
      helpers.assert_eq(LB.parse_stream_line(""), nil)
      helpers.assert_eq(LB.parse_stream_line("   "), nil)
    end)

    helpers.it("returns nil on non-string input", function()
      helpers.assert_eq(LB.parse_stream_line(nil), nil)
    end)
  end)

  -- ==========================================================================
  -- 7. extract_tail()
  -- ==========================================================================

  helpers.describe("extract_tail()", function()
    helpers.it("extracts last N words", function()
      helpers.assert_eq(LB.extract_tail("one two three four five", 3), "three four five")
    end)

    helpers.it("returns all words when fewer than N", function()
      helpers.assert_eq(LB.extract_tail("hello world", 5), "hello world")
    end)

    helpers.it("returns empty on empty buffer", function()
      helpers.assert_eq(LB.extract_tail(""), "")
      helpers.assert_eq(LB.extract_tail("   "), "")
    end)

    helpers.it("returns empty on non-string input", function()
      helpers.assert_eq(LB.extract_tail(nil), "")
    end)

    helpers.it("uses default CONTEXT_TAIL_WORDS when N not provided", function()
      local result = LB.extract_tail("a b c d e f g h i j")
      -- Default is 5
      helpers.assert_eq(result, "f g h i j")
    end)

    helpers.it("handles single word", function()
      helpers.assert_eq(LB.extract_tail("solo", 3), "solo")
    end)
  end)

  -- ==========================================================================
  -- 8. build_request_params() — delegates to shared PromptBuilder
  -- ==========================================================================

  helpers.describe("build_request_params()", function()
    helpers.it("returns a table with expected fields", function()
      local params = LB.build_request_params("test buffer", {})
      helpers.assert_true(type(params) == "table", "returns table")
      -- The exact keys depend on PromptBuilder.build_params, but context should exist
      helpers.assert_true(params.context ~= nil or params.context_tail ~= nil,
        "has context or context_tail field")
    end)
  end)

  -- ==========================================================================
  -- 9. Constants
  -- ==========================================================================

  helpers.describe("constants", function()
    helpers.it("exports expected constants (mirrored from the shared canonicals)", function()
      helpers.assert_eq(LB.OLLAMA_CHAT_PATH, "/api/chat")
      helpers.assert_eq(LB.OLLAMA_DEFAULT_HOST, "127.0.0.1")
      -- These mirror _shared/modules/llm/defaults.json; the JS gate
      -- test-linux-llm-defaults-single-source pins them equal so they cannot drift.
      helpers.assert_eq(LB.OLLAMA_DEFAULT_PORT, 11434)      -- llm_ollama_port
      helpers.assert_eq(LB.DEFAULT_TEMPERATURE, 0.1)        -- llm_temperature (was a divergent 0.7)
      helpers.assert_eq(LB.DEFAULT_KEEP_ALIVE, "30m")       -- llm_ollama_keep_alive
      helpers.assert_eq(LB.DEFAULT_CONTEXT_LENGTH, 500)     -- llm_context_length (Linux was 2000)
      helpers.assert_eq(LB.CONTEXT_TAIL_WORDS, 5)
    end)
  end)

end)
