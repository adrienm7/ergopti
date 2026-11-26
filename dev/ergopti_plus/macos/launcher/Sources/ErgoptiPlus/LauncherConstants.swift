// Sources/ErgoptiPlus/LauncherConstants.swift

/**
 ==============================================================================
 MODULE: Launcher constants
 DESCRIPTION:
 Owns constants shared by the executable bootstrap and importable XCTest code.

 FEATURES & RATIONALE:
 1. Keeps shared globals outside main.swift, whose top-level storage is not
    initialized when Swift 6.3 imports an executable module into XCTest.
 ==============================================================================
 */

import Darwin

/// Signed application identity shared by bootstrap and guardian registration.
let kErgoptiBundleId = Identifiers.BundleIds.launcher
/// Dedicated identity for the embedded GUI runtime. The outer bundle prohibits
/// duplicate instances, so its child cannot reuse the launcher's identity.
let kEmbeddedHammerspoonBundleId = Identifiers.BundleIds.hammerspoon
/// Hammerspoon preference key installed before the embedded runtime starts.
let kHammerspoonConfigKey = "MJConfigFile"
/// Hammerspoon's own preference keys for its hammer menu bar icon and its Dock icon
/// (variables.h of the pinned Hammerspoon 1.1.1, read by MJMenuIcon.m and MJDockIcon.m).
/// The launcher sets both to false before the runtime starts, so only Ergopti's menu
/// shows. Keys spelt "MJShow…OnLaunch", which Hammerspoon never reads, left the hammer
/// in the menu bar beside ErgoptiPlus' own icon (field report 2026-11-23).
let kHammerspoonHiddenIconKeys = ["MJShowMenuIconKey", "MJShowDockIconKey"]
/// Process-wide private mask inherited by every launcher and headless role.
let kPrivateProcessUmask: mode_t = 0o077
