//
//  VimeApp.swift
//  Vime
//
//  Created by Voltline on 2026/10/4.
//

import SwiftUI

@main
struct VimeApp: App {
    init() {
        VimeExtensionAudit.configureFromLaunchArguments()
        Task { await StorefrontRecorder.record() }
#if DEBUG
        // Reproducible settings for opt-in tests of the installed extension.
        // Normal launches never change the user's choices.
        let arguments = ProcessInfo.processInfo.arguments
#if targetEnvironment(simulator)
        let testingDefaults = UserDefaults(suiteName: KeyboardPreferences.appGroup)
        if arguments.contains("--keyboard-extension-test"),
           let index = arguments.firstIndex(of: "--keyboard-extension-test-learning-id"),
           index + 1 < arguments.count, let id = UUID(uuidString: arguments[index + 1]) {
            testingDefaults?.set(id.uuidString, forKey: "VimeExtensionLearningTestID")
        } else { testingDefaults?.removeObject(forKey: "VimeExtensionLearningTestID") }
#endif
        if arguments.contains("--keyboard-extension-test"),
           let index = arguments.firstIndex(of: "--keyboard-extension-test-height"),
           index + 1 < arguments.count, let factor = Double(arguments[index + 1]) {
            KeyboardPreferences().heightFactor = factor
        }
        if arguments.contains("--keyboard-extension-test"),
           let index = arguments.firstIndex(of: "--keyboard-extension-test-ranking"),
           index + 1 < arguments.count,
           let ranking = CandidateRankingMode(rawValue: arguments[index + 1]) {
            let preferences = KeyboardPreferences()
            preferences.candidateRanking = ranking
            preferences.phraseSuggestions = true
        }
        // Sets the input language before a test run, as the setting in the app does.
        if let index = arguments.firstIndex(of: "--keyboard-input-language"), index + 1 < arguments.count,
           let language = KeyboardInputLanguage(rawValue: arguments[index + 1]), language != .english {
            KeyboardPreferences().inputLanguage = language
        }
#endif
    }
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--keyboard-extension-test") {
                NavigationStack { KeyboardExtensionTestView() }
            } else if ProcessInfo.processInfo.arguments.contains("--chinese-tryout") {
                NavigationStack { ChineseTryOutView() }
            } else { ContentView() }
#else
            ContentView()
#endif
        }
    }
}
