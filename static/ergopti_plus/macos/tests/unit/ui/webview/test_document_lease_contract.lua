--- tests/unit/ui/webview/test_document_lease_contract.lua

--- ==============================================================================
--- MODULE: Test Shared Document Lease Contract
--- DESCRIPTION:
--- Replays the shared document lease causal controls under Lua 5.4, so the
--- ledger answers the same cases on both Lua interpreters. The macOS windows
--- keep their own per-view owner; this qualifies the shared ledger only, not
--- WKWebView navigation or the macOS download window.
--- ==============================================================================

require("test.document_lease_contract").register(require("tests.helpers"))
