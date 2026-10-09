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
let kErgoptiBundleId = "com.ergoptiplus.app"
/// Dedicated identity for the embedded GUI runtime. The outer bundle prohibits
/// duplicate instances, so its child cannot reuse the launcher's identity.
let kEmbeddedHammerspoonBundleId = "com.ergoptiplus.app.hammerspoon"
/// Hammerspoon preference key installed before the embedded runtime starts.
let kHammerspoonConfigKey = "MJConfigFile"
/// Process-wide private mask inherited by every launcher and headless role.
let kPrivateProcessUmask: mode_t = 0o077
