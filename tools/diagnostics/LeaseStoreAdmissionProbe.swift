// Synthetic filesystem observations only; no production store or lease authority.
import Darwin
import Foundation

enum ProbeOpen: String, Encodable {
    case unrun, opened, ancestorAlias = "ancestor-alias", accessDenied = "access-denied"
    case missing, notDirectory = "not-directory", interrupted, other
}
enum ProbePhase: String, Encodable {
    case setup, pathObserved = "path-observed", directoryObserved = "directory-observed"
    case created, renamed, removed, complete, refused
}
enum ProbeRefusal: String, Encodable, Error {
    case none, initialOpen = "initial-open", directoryOwned = "directory-owned"
    case namespaceReopen = "namespace-reopen"
    case postTemporaryDirectoryIdentity = "post-temporary-directory-identity"
    case postRenameDirectoryIdentity = "post-rename-directory-identity"
    case recordShape = "record-shape", creation, write, rename, remove
    case countRange = "count-range", other
}
enum ProbeCleanup: String, Encodable { case unrun, complete, debt }
enum ProbeStoreAPI: String, Encodable { case unrun }

struct ProbeReport: Encodable {
    let schema = 1
    let scope = "synthetic-lease-store-admission"
    var foundation_matches_native_path = false
    var canonical_url_preserves_native_path = false
    var foundation_open = ProbeOpen.unrun
    var canonical_open = ProbeOpen.unrun
    var directory_private_owned = false
    var immutable_directory_identity_equal_after_create = false
    var immutable_directory_identity_equal_after_rename = false
    var immutable_directory_identity_equal_after_remove = false
    var directory_link_count_changed_on_create = false
    var directory_link_count_changed_on_rename = false
    var directory_link_count_changed_on_remove = false
    var regular_record_single_link = false
    var regular_record_private_owned = false
    var directory_link_count_before: UInt16 = 0
    var directory_link_count_after_create: UInt16 = 0
    var directory_link_count_after_rename: UInt16 = 0
    var directory_link_count_after_remove: UInt16 = 0
    let canonical_observer_armed = ProbeStoreAPI.unrun
    let canonical_retain = ProbeStoreAPI.unrun
    var phase = ProbePhase.setup
    var refusal = ProbeRefusal.none
    var cleanup = ProbeCleanup.unrun
}

private func opening(_ code: Int32) -> ProbeOpen {
    switch code {
    case ELOOP: return .ancestorAlias
    case EACCES, EPERM: return .accessDenied
    case ENOENT: return .missing
    case ENOTDIR: return .notDirectory
    case EINTR: return .interrupted
    default: return .other
    }
}

// Mutable directory child counts are measured, never used to identify its vnode.
private func immutableIdentity(_ left: stat, _ right: stat) -> Bool {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino
        && left.st_mode == right.st_mode && left.st_uid == right.st_uid
        && left.st_gid == right.st_gid
}
private func privateDirectory(_ value: stat) -> Bool {
    return (value.st_mode & S_IFMT) == S_IFDIR && value.st_uid == geteuid()
        && (value.st_mode & 0o7777) == 0o700
}
private func privateRecord(_ value: stat) -> Bool {
    return (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == geteuid()
        && (value.st_mode & 0o7777) == 0o600 && value.st_nlink == 1
}
private func nativePath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
private func linkCount(_ value: stat) throws -> UInt16 {
    guard let count = UInt16(exactly: value.st_nlink) else { throw ProbeRefusal.countRange }
    return count
}
private func closeOwned(_ descriptor: inout Int32) -> Bool {
    guard descriptor >= 0 else { return true }
    let owned = descriptor
    descriptor = -1
    // Never retry close: an interrupted close can already have released its FD.
    return Darwin.close(owned) == 0
}

private func performProbe() -> ProbeReport {
    var report = ProbeReport()
    guard CommandLine.arguments.count == 1 else {
        report.phase = .refused
        report.refusal = .other
        return report
    }
    var parent: Int32 = -1, fixture: Int32 = -1, record: Int32 = -1
    var parentIdentity: stat?, fixtureIdentity: stat?, recordIdentity: stat?
    var parentPath = "", fixtureName = "", canonicalPath = ""
    var createdFixture = false, attemptedFixture = false, createdRecord = false, removedRecord = false
    var recordName = "probe-record.tmp"
    var auxiliaryCleanupDebt = false

    func parentCurrent() -> Bool {
        guard parent >= 0, let expected = parentIdentity, !parentPath.isEmpty else { return false }
        var held = stat(), named = stat(), reopened = stat()
        guard Darwin.fstat(parent, &held) == 0, privateDirectory(held), immutableIdentity(expected, held),
            Darwin.lstat(parentPath, &named) == 0, privateDirectory(named),
            immutableIdentity(held, named) else { return false }
        let cut = Darwin.open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard cut >= 0 else { return false }
        let accepted = Darwin.fstat(cut, &reopened) == 0 && privateDirectory(reopened)
            && immutableIdentity(held, reopened)
        let closed = Darwin.close(cut) == 0
        if !closed { auxiliaryCleanupDebt = true }
        return closed && accepted
    }
    func fixtureCurrent() -> Bool {
        guard fixture >= 0, let expected = fixtureIdentity, parentCurrent() else { return false }
        var held = stat(), named = stat()
        return Darwin.fstat(fixture, &held) == 0 && privateDirectory(held)
            && immutableIdentity(expected, held)
            && Darwin.fstatat(parent, fixtureName, &named, AT_SYMLINK_NOFOLLOW) == 0
            && privateDirectory(named) && immutableIdentity(held, named)
    }
    func recordCurrent() -> Bool {
        guard record >= 0, let expected = recordIdentity, fixtureCurrent() else { return false }
        var held = stat(), named = stat()
        return Darwin.fstat(record, &held) == 0 && privateRecord(held)
            && immutableIdentity(expected, held)
            && Darwin.fstatat(fixture, recordName, &named, AT_SYMLINK_NOFOLLOW) == 0
            && privateRecord(named) && immutableIdentity(held, named)
    }
    func writeFixedRecord() -> Bool {
        let bytes: [UInt8] = [0x70, 0x72, 0x6f, 0x62, 0x65, 0x0a]
        var offset = 0
        for _ in 0..<8 {
            if offset == bytes.count { return true }
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(record, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { return false }
        }
        return offset == bytes.count
    }
    func observe() throws {
        // Matches the actual failing Foundation fixture construction.
        let foundationParent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard let realParent = nativePath(foundationParent.path) else { throw ProbeRefusal.initialOpen }
        parentPath = realParent
        parent = Darwin.open(realParent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw ProbeRefusal.initialOpen }
        var root = stat()
        guard Darwin.fstat(parent, &root) == 0, (root.st_mode & S_IFMT) == S_IFDIR else {
            throw ProbeRefusal.initialOpen
        }
        guard privateDirectory(root) else { throw ProbeRefusal.directoryOwned }
        parentIdentity = root
        fixtureName = "ergopti-lease-admission-" + UUID().uuidString
        let foundationFixture = foundationParent.appendingPathComponent(fixtureName, isDirectory: true)
        guard parentCurrent() else { throw ProbeRefusal.namespaceReopen }
        var absent = stat()
        guard Darwin.fstatat(parent, fixtureName, &absent, AT_SYMLINK_NOFOLLOW) != 0,
            errno == ENOENT else { throw ProbeRefusal.creation }
        attemptedFixture = true
        do {
            try FileManager.default.createDirectory(at: foundationFixture, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch { throw ProbeRefusal.creation }
        createdFixture = true
        var initial = stat()
        guard Darwin.fstatat(parent, fixtureName, &initial, AT_SYMLINK_NOFOLLOW) == 0,
            privateDirectory(initial) else { throw ProbeRefusal.directoryOwned }
        fixtureIdentity = initial
        // Descriptor custody is independent of the full-path flags being measured.
        fixture = Darwin.openat(parent, fixtureName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fixtureCurrent() else { throw ProbeRefusal.namespaceReopen }
        guard let resolved = nativePath(foundationFixture.path), resolved == realParent + "/" + fixtureName else {
            throw ProbeRefusal.namespaceReopen
        }
        canonicalPath = resolved
        report.foundation_matches_native_path = foundationFixture.path == resolved
        report.canonical_url_preserves_native_path = URL(fileURLWithPath: resolved, isDirectory: true).path == resolved
        let foundationFD = Darwin.open(foundationFixture.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if foundationFD < 0 { report.foundation_open = opening(errno) }
        else {
            var value = stat()
            let valid = Darwin.fstat(foundationFD, &value) == 0 && immutableIdentity(initial, value)
            let closed = Darwin.close(foundationFD) == 0
            if !closed { auxiliaryCleanupDebt = true }
            report.foundation_open = valid && closed ? .opened : .other
        }
        let canonicalFD = Darwin.open(canonicalPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if canonicalFD < 0 { report.canonical_open = opening(errno) }
        else {
            var value = stat()
            let valid = Darwin.fstat(canonicalFD, &value) == 0 && immutableIdentity(initial, value)
            let closed = Darwin.close(canonicalFD) == 0
            if !closed { auxiliaryCleanupDebt = true }
            report.canonical_open = valid && closed ? .opened : .other
        }
        report.phase = .pathObserved
        guard report.canonical_open == .opened else { throw ProbeRefusal.initialOpen }
        guard fixtureCurrent() else { throw ProbeRefusal.namespaceReopen }
        report.directory_private_owned = privateDirectory(initial)
        report.directory_link_count_before = try linkCount(initial)
        report.phase = .directoryObserved

        record = Darwin.openat(fixture, recordName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard record >= 0 else { throw ProbeRefusal.creation }
        createdRecord = true
        var file = stat()
        guard Darwin.fstat(record, &file) == 0, (file.st_mode & S_IFMT) == S_IFREG,
            file.st_uid == geteuid(), file.st_nlink == 1 else { throw ProbeRefusal.recordShape }
        guard Darwin.fchmod(record, S_IRUSR | S_IWUSR) == 0,
            Darwin.fstat(record, &file) == 0, privateRecord(file) else { throw ProbeRefusal.recordShape }
        recordIdentity = file
        guard recordCurrent(), writeFixedRecord(), Darwin.fsync(record) == 0 else { throw ProbeRefusal.write }
        var afterCreate = stat()
        guard Darwin.fstat(fixture, &afterCreate) == 0 else { throw ProbeRefusal.postTemporaryDirectoryIdentity }
        report.immutable_directory_identity_equal_after_create = immutableIdentity(initial, afterCreate)
        report.directory_link_count_after_create = try linkCount(afterCreate)
        report.directory_link_count_changed_on_create = initial.st_nlink != afterCreate.st_nlink
        report.regular_record_single_link = file.st_nlink == 1
        report.regular_record_private_owned = privateRecord(file)
        report.phase = .created
        guard report.immutable_directory_identity_equal_after_create, recordCurrent() else {
            throw ProbeRefusal.postTemporaryDirectoryIdentity
        }
        let finalName = "probe-record.json"
        guard Darwin.fstatat(fixture, finalName, &absent, AT_SYMLINK_NOFOLLOW) != 0,
            errno == ENOENT else { throw ProbeRefusal.rename }
        // Exclusive rename refuses a racing destination; it never overwrites another file.
        guard Darwin.renameatx_np(fixture, recordName, fixture, finalName, UInt32(RENAME_EXCL)) == 0 else {
            throw ProbeRefusal.rename
        }
        recordName = finalName
        var afterRename = stat()
        guard Darwin.fstat(fixture, &afterRename) == 0 else { throw ProbeRefusal.postRenameDirectoryIdentity }
        report.immutable_directory_identity_equal_after_rename = immutableIdentity(initial, afterRename)
        report.directory_link_count_after_rename = try linkCount(afterRename)
        report.directory_link_count_changed_on_rename = afterCreate.st_nlink != afterRename.st_nlink
        report.phase = .renamed
        guard report.immutable_directory_identity_equal_after_rename, recordCurrent() else {
            throw ProbeRefusal.postRenameDirectoryIdentity
        }
        guard Darwin.unlinkat(fixture, recordName, 0) == 0 else { throw ProbeRefusal.remove }
        removedRecord = true
        guard Darwin.fstatat(fixture, recordName, &absent, AT_SYMLINK_NOFOLLOW) != 0,
            errno == ENOENT else { throw ProbeRefusal.remove }
        var afterRemove = stat()
        guard Darwin.fstat(fixture, &afterRemove) == 0 else { throw ProbeRefusal.remove }
        report.immutable_directory_identity_equal_after_remove = immutableIdentity(initial, afterRemove)
        report.directory_link_count_after_remove = try linkCount(afterRemove)
        report.directory_link_count_changed_on_remove = afterRename.st_nlink != afterRemove.st_nlink
        report.phase = .removed
        guard report.immutable_directory_identity_equal_after_remove, fixtureCurrent() else {
            throw ProbeRefusal.namespaceReopen
        }
    }
    do { try observe() }
    catch let refusal as ProbeRefusal { report.phase = .refused; report.refusal = refusal }
    catch { report.phase = .refused; report.refusal = .other }

    // Cleanup never recursively removes a pathname or repairs a replaced namespace.
    var cleanupGood = !auxiliaryCleanupDebt
    if createdRecord && !removedRecord {
        if recordCurrent() && Darwin.unlinkat(fixture, recordName, 0) == 0 {
            removedRecord = true
        } else { cleanupGood = false }
    }
    if !closeOwned(&record) { cleanupGood = false }
    if createdFixture {
        if cleanupGood && fixtureCurrent() && Darwin.unlinkat(parent, fixtureName, AT_REMOVEDIR) == 0 {
            var absent = stat()
            if Darwin.fstatat(parent, fixtureName, &absent, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                cleanupGood = false
            }
        } else { cleanupGood = false }
    } else if attemptedFixture {
        // A throwing Foundation create can leave a directory whose identity was never captured.
        cleanupGood = false
    }
    if !closeOwned(&fixture) { cleanupGood = false }
    if !closeOwned(&parent) { cleanupGood = false }
    report.cleanup = cleanupGood ? .complete : .debt
    if !cleanupGood {
        report.phase = .refused
        if report.refusal == .none { report.refusal = .remove }
    } else if report.phase == .removed {
        report.phase = .complete
    }
    return report
}

@main struct LeaseStoreAdmissionProbe {
    static func main() {
        let report = performProbe()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var bytes = try? encoder.encode(report), bytes.count + 1 <= 4096 else { Darwin.exit(1) }
        bytes.append(0x0a)
        var offset = 0
        for _ in 0..<8 {
            if offset == bytes.count { break }
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written }
            else if written < 0 && errno == EINTR { continue }
            else { Darwin.exit(1) }
        }
        guard offset == bytes.count else { Darwin.exit(1) }
        Darwin.exit(report.phase == .complete && report.cleanup == .complete ? 0 : 1)
    }
}
