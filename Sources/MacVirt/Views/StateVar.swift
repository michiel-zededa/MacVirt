// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// SwiftUI's `@State` is a macro in the macOS 27 SDK whose plugin only ships
/// with Xcode. Using the underlying property wrapper through an alias lets the
/// app build with just the Command Line Tools as well.
typealias StateVar = SwiftUI.State
