// Sources/ErgoptiPlus/OwnedLogDirectory.swift

/**
 ==============================================================================
 MODULE: Owned log directory
 DESCRIPTION:
 Resolves one configured log folder to a real directory owned by the current
 user and opens it without following any symbolic link after that resolution.

 FEATURES & RATIONALE:
 1. User layouts are honoured: a configuration or log folder reached through
    symbolic links (for example a folder versioned in a Git repository) is
    resolved once with realpath, so the user's own links are followed exactly
    once, at validation time.
 2. No late redirection: the resolved path is opened with O_NOFOLLOW_ANY, so a
    link swapped into any component after resolution is refused instead of
    followed, and the descriptor is then checked for type and ownership.
 3. Missing folders are created component by component inside their resolved
    parent with mode 0700. The target of a dangling link is never created.
 4. Every refusal carries a user-fixable cause, so the launcher can name the
    folder and the reason instead of reporting a bare child exit status.
 ==============================================================================
 */

import Darwin
import Foundation

/// One user-fixable reason why a configured log folder cannot be used.
enum LogDirectoryRefusal: Error, Equatable {
	case invalidPath
	case danglingSymlink(link: String)
	case accessDenied(errorCode: Int32)
	case notDirectory
	case notOwned(resolvedPath: String)
	case cannotCreate(errorCode: Int32)
	case cannotSetPermissions(errorCode: Int32)
	case unavailable(errorCode: Int32)

	/// Stable suffix of the localized alert key for this refusal.
	var localizationKey: String {
		switch self {
		case .invalidPath: return "invalid_path"
		case .danglingSymlink: return "dangling_symlink"
		case .accessDenied: return "access_denied"
		case .notDirectory: return "not_directory"
		case .notOwned: return "not_owned"
		case .cannotCreate: return "cannot_create"
		case .cannotSetPermissions: return "cannot_set_permissions"
		case .unavailable: return "unavailable"
		}
	}

	/// Secondary value shown beside the folder: the link, owner path, or OS error.
	var detail: String {
		switch self {
		case .invalidPath, .notDirectory: return ""
		case let .danglingSymlink(link): return link
		case let .notOwned(resolvedPath): return resolvedPath
		case let .accessDenied(errorCode), let .cannotCreate(errorCode),
			let .cannotSetPermissions(errorCode), let .unavailable(errorCode):
			return String(cString: strerror(errorCode))
		}
	}
}

/// A refused log folder: the path the user configured and the exact cause.
struct LogDirectoryFailure: Error, Equatable {
	let path: String
	let refusal: LogDirectoryRefusal

	/// English developer diagnostic for launcher.log and the Lua NACK detail.
	var diagnostic: String {
		switch refusal {
		case .invalidPath:
			return "log folder \(path) is not an absolute directory path"
		case let .danglingSymlink(link):
			return "log folder \(path) cannot be used: \(link) is a symbolic link whose target does not exist"
		case .accessDenied:
			return "macOS denied access to log folder \(path) (\(refusal.detail))"
		case .notDirectory:
			return "log folder \(path) is not a directory"
		case let .notOwned(resolvedPath):
			return "log folder \(path) resolves to \(resolvedPath), which is not owned by the current user"
		case .cannotCreate:
			return "log folder \(path) could not be created (\(refusal.detail))"
		case .cannotSetPermissions:
			return "log folder \(path) could not be restricted to the current user (\(refusal.detail))"
		case .unavailable:
			return "log folder \(path) cannot be opened (\(refusal.detail))"
		}
	}
}

/// Opened, validated, 0700 log directory. The caller owns `descriptor`.
struct OwnedLogDirectory {
	let descriptor: Int32
	let resolvedPath: String
}

enum OwnedLogDirectoryResolver {
	/// Resolves, creates when missing, opens, and validates one log folder.
	/// - Parameter path: Absolute folder path as configured by the driver.
	/// - Returns: The open directory, or the exact user-fixable refusal.
	static func open(_ path: String) -> Result<OwnedLogDirectory, LogDirectoryFailure> {
		guard let normalized = normalizedAbsoluteDirectoryPath(path) else {
			return .failure(LogDirectoryFailure(path: path, refusal: .invalidPath))
		}
		let resolvedPath: String
		switch resolveCreatingMissing(normalized) {
		case let .success(value): resolvedPath = value
		case let .failure(refusal):
			return .failure(LogDirectoryFailure(path: normalized, refusal: refusal))
		}

		let descriptor = Darwin.open(
			resolvedPath,
			O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
		)
		guard descriptor >= 0 else {
			return .failure(LogDirectoryFailure(
				path: normalized,
				refusal: refusalForOpenError(errno)
			))
		}
		var attributes = stat()
		let refusal: LogDirectoryRefusal?
		if Darwin.fstat(descriptor, &attributes) != 0 {
			refusal = .unavailable(errorCode: errno)
		} else if (attributes.st_mode & S_IFMT) != S_IFDIR {
			refusal = .notDirectory
		} else if attributes.st_uid != geteuid() {
			refusal = .notOwned(resolvedPath: resolvedPath)
		} else if Darwin.fchmod(descriptor, S_IRWXU) != 0 {
			refusal = .cannotSetPermissions(errorCode: errno)
		} else {
			refusal = nil
		}
		if let refusal {
			Darwin.close(descriptor)
			return .failure(LogDirectoryFailure(path: normalized, refusal: refusal))
		}
		return .success(OwnedLogDirectory(descriptor: descriptor, resolvedPath: resolvedPath))
	}

	/// Normalizes one absolute directory without admitting a NUL or parent escape.
	static func normalizedAbsoluteDirectoryPath(_ path: String) -> String? {
		guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < Int(PATH_MAX)
		else { return nil }
		let normalized = URL(fileURLWithPath: path, isDirectory: true)
			.standardizedFileURL.path
		guard normalized.hasPrefix("/"), normalized != "/" else { return nil }
		return normalized
	}

	/// Returns the symlink-free path of `path`, creating missing trailing folders.
	private static func resolveCreatingMissing(_ path: String) -> Result<String, LogDirectoryRefusal> {
		if let resolved = realPath(path) { return .success(resolved) }
		let resolveError = errno
		guard resolveError == ENOENT else { return .failure(refusalForOpenError(resolveError)) }

		// realpath reports ENOENT for a dangling link as well as a missing leaf.
		// Creating a dangling link's target would write wherever the link points,
		// so only a genuinely absent component is created.
		var attributes = stat()
		if Darwin.lstat(path, &attributes) == 0 {
			if (attributes.st_mode & S_IFMT) == S_IFLNK {
				return .failure(.danglingSymlink(link: path))
			}
			return .failure(.unavailable(errorCode: resolveError))
		}
		let parent = (path as NSString).deletingLastPathComponent
		let leaf = (path as NSString).lastPathComponent
		guard !parent.isEmpty, parent != path, !leaf.isEmpty else {
			return .failure(.unavailable(errorCode: resolveError))
		}
		let resolvedParent: String
		switch resolveCreatingMissing(parent) {
		case let .success(value): resolvedParent = value
		case let .failure(refusal): return .failure(refusal)
		}
		let candidate = resolvedParent == "/" ? "/" + leaf : resolvedParent + "/" + leaf
		if Darwin.mkdir(candidate, S_IRWXU) != 0 && errno != EEXIST {
			let createError = errno
			if createError == EACCES || createError == EPERM {
				return .failure(.accessDenied(errorCode: createError))
			}
			return .failure(.cannotCreate(errorCode: createError))
		}
		// A concurrent creator may have won with a link; resolution decides again.
		if let resolved = realPath(candidate) { return .success(resolved) }
		let finalError = errno
		if finalError == ENOENT, Darwin.lstat(candidate, &attributes) == 0,
			(attributes.st_mode & S_IFMT) == S_IFLNK {
			return .failure(.danglingSymlink(link: candidate))
		}
		return .failure(refusalForOpenError(finalError))
	}

	private static func realPath(_ path: String) -> String? {
		guard let resolved = Darwin.realpath(path, nil) else { return nil }
		defer { free(resolved) }
		return String(cString: resolved)
	}

	private static func refusalForOpenError(_ errorCode: Int32) -> LogDirectoryRefusal {
		switch errorCode {
		case EACCES, EPERM: return .accessDenied(errorCode: errorCode)
		case ENOTDIR: return .notDirectory
		default: return .unavailable(errorCode: errorCode)
		}
	}
}
