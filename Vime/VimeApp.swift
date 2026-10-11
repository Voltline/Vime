//
//  VimeApp.swift
//  Vime
//
//  Created by Voltline on 2026/10/4.
//

import SwiftUI

@main
struct VimeApp: App {
    init() { VimeExtensionAudit.configureFromLaunchArguments() }
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--keyboard-extension-test") {
                NavigationStack { KeyboardExtensionTestView() }
            } else { ContentView() }
#else
            ContentView()
#endif
        }
    }
}
