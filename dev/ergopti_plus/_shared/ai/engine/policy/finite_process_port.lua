--- _shared/ai/engine/policy/finite_process_port.lua

--- Compatibility entrypoint for the already-qualified finite process bridge.
--- The common core preserves .start's finite-only admission and adds an explicit
--- .start_service API sharing that same instance's exact owner exclusion.
return require("ai.engine.policy.process_port")
