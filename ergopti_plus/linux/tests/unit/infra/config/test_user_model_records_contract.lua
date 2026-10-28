--- tests/unit/infra/config/test_user_model_records_contract.lua

--- ==============================================================================
--- MODULE: Test Saved Model Record Contract
--- DESCRIPTION:
--- Replays the pure half of the saved-model record contract under LuaJIT: the
--- shared record codec, row admission and unused-key cleanup Linux also uses.
--- Saved user models are a macOS feature (platform_reason
--- llm_saved_user_models_are_macos), so the native Preferences half stays on
--- macOS and nothing here claims a Linux saved-model reader.
--- ==============================================================================

require("test.user_model_records_contract").register_pure(require("tests.helpers"))
