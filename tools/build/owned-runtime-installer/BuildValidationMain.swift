// Standalone inert validator, never enrolled in the normal launcher or privileged helper product.
import Darwin
import Foundation
@main
struct OwnedRuntimeBuildValidationMain {
	static func main() { Darwin.exit(OwnedRuntimeBuildValidationEntry.validate(arguments: CommandLine.arguments) ? 0 : 78) }
}
