# tools/test/fixtures/prepare-sparkle-native-physical-probe.py
"""Extract the pinned actual child helper for mandatory native XCTest controls."""

from pathlib import Path
import argparse
import hashlib

parser = argparse.ArgumentParser()
parser.add_argument("--source", required=True)
parser.add_argument("--sha256", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--profile", choices=("fixed", "legacy-projection"), default="fixed")
args = parser.parse_args()
data = Path(args.source).read_bytes()
if hashlib.sha256(data).hexdigest() != args.sha256:
    raise ValueError("The actual child source pin differs.")
text = data.decode("utf-8")
start = text.index("private enum PhysicalFixtureFailure:")
end = text.index("final class PrivateArchiveChild:")
body = text[start:end]
if (
    body.count("private func physicalFixtureDirectory(") != 1
    or "Darwin.realpath(value, nil)" not in body
):
    raise ValueError("The actual physical helper body is missing.")
if args.profile == "legacy-projection":
    # This explicit inverse uses the original child's Foundation primitive.
    body = """private enum PhysicalFixtureFailure: Error { case refused }
private func physicalFixtureDirectory(_ source: URL) throws -> URL {
    return source.resolvingSymlinksInPath()
}
"""
probe = (
    """import Foundation
import Darwin

"""
    + body
    + """
private enum ProbeRefusal: Error { case failed }
private func require(_ value: Bool, _ reason: String) throws {
    if !value {
        fputs("SPARKLE_CHILD_PHYSICAL_PROBE_REFUSED:" + reason + "\\n", stderr)
        throw ProbeRefusal.failed
    }
}
private func runProbe() throws {
    guard CommandLine.arguments.count == 2 else { throw PhysicalFixtureFailure.refused }
    let manager = FileManager.default
    let parent = try physicalFixtureDirectory(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    // A legacy projection refuses before it can acquire an owned subdirectory.
    try require(parent.path == CommandLine.arguments[1], "parent-physical")
    let root = parent.appendingPathComponent("OwnedChildPhysicalProbe-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    var primary: Error?
    do {
        let target = root.appendingPathComponent("physical-directory", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("owned-alias", isDirectory: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: target)
        let observed = try physicalFixtureDirectory(alias)
        let pointer = alias.withUnsafeFileSystemRepresentation { value -> UnsafeMutablePointer<CChar>? in
            guard let value else { return nil }
            return Darwin.realpath(value, nil)
        }
        guard let pointer else { throw PhysicalFixtureFailure.refused }
        defer { free(pointer) }
        guard let expected = String(validatingUTF8: pointer) else { throw PhysicalFixtureFailure.refused }
        try require(observed.path == expected, "alias-identity")
        var first = stat(), second = stat()
        try require(lstat(pointer, &first) == 0 && lstat(observed.path, &second) == 0, "alias-metadata")
        try require(first.st_dev == second.st_dev && first.st_ino == second.st_ino, "alias-inode")
        try require(second.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), "alias-kind")
        let ordinary = root.appendingPathComponent("ordinary")
        try Data("private physical probe".utf8).write(to: ordinary, options: .withoutOverwriting)
        var refused = false
        do { _ = try physicalFixtureDirectory(ordinary) } catch { refused = true }
        try require(refused, "regular-file")
        refused = false
        do { _ = try physicalFixtureDirectory(root.appendingPathComponent("missing")) } catch { refused = true }
        try require(refused, "missing")
        refused = false
        do { _ = try physicalFixtureDirectory(URL(string: "https://example.invalid/")!) } catch { refused = true }
        try require(refused, "non-file")
        let installed = root.appendingPathComponent("installed", isDirectory: true)
        try manager.createDirectory(at: installed, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let bundle = installed.appendingPathComponent("ErgoptiPlus.app", isDirectory: true)
        try manager.createDirectory(at: bundle, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let physicalRoot = try physicalFixtureDirectory(root)
        let physicalBundle = try physicalFixtureDirectory(bundle)
        try require(physicalRoot.path == root.path &&
            physicalBundle == physicalRoot.appendingPathComponent("installed/ErgoptiPlus.app", isDirectory: true), "root-binding")
        try require(physicalRoot.path != alias.path, "raw-root-alias")
        try require(physicalBundle != physicalRoot.appendingPathComponent("foreign.app", isDirectory: true), "foreign-bundle")
    } catch { primary = error }
    do { try manager.removeItem(at: root) }
    catch {
        fputs("SPARKLE_CHILD_PHYSICAL_PROBE_CLEANUP_REFUSED\\n", stderr)
        if primary == nil { primary = error }
    }
    if let primary { throw primary }
    print("SPARKLE_CHILD_PHYSICAL_PROBE_COMPLETE:5")
}
do { try runProbe() }
catch {
    if !(error is ProbeRefusal) { fputs("SPARKLE_CHILD_PHYSICAL_PROBE_UNAVAILABLE\\n", stderr) }
    exit(1)
}
"""
)
output = Path(args.output)
if output.exists():
    raise ValueError("Native probe output must be absent.")
output.write_text(probe, encoding="utf-8", newline="\n")
