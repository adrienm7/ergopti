// tools/build/fixtures/owned_runtime_lifecycle_signature_main.swift
// Disposable native signature observation; never install or acquire runtime custody.
import Darwin
import Foundation

@main
struct OwnedRuntimeLifecycleSignatureControlMain {
	static func main() {
		guard CommandLine.arguments.count == 2,
			["--expect-allowed", "--expect-refused"].contains(CommandLine.arguments[1]) else {
			Darwin.exit(64)
		}
		let observed = OwnedRuntimeServiceLifecycleLock.fixtureCurrentPublisherSignature()
		let expected = CommandLine.arguments[1] == "--expect-allowed"
		guard observed == expected else { Darwin.exit(1) }
		Darwin.exit(0)
	}
}
