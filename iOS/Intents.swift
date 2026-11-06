import AppIntents
import FlickKit

/// Action Button / Siri / Shortcuts entry points.
struct AskMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask your Mac"
    static let description = IntentDescription("Opens Flick and starts listening.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.listenOnOpen = true
        Router.shared.showAsk = true
        return .result()
    }
}

struct PlayPauseMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or pause on Mac"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await Link.oneShot([.media(action: .playPause)])
        return .result(dialog: ok ? "Done" : "Mac not reachable")
    }
}

struct LockMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Mac"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await Link.oneShot([.system(action: .lock)])
        return .result(dialog: ok ? "Locked" : "Mac not reachable")
    }
}

struct SleepMacDisplayIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep Mac display"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await Link.oneShot([.system(action: .displaySleep)])
        return .result(dialog: ok ? "Done" : "Mac not reachable")
    }
}

struct FlickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskMacIntent(), phrases: ["Ask my Mac with \(.applicationName)", "\(.applicationName) ask"],
                    shortTitle: "Ask Mac", systemImageName: "waveform")
        AppShortcut(intent: PlayPauseMacIntent(), phrases: ["Pause my Mac with \(.applicationName)", "\(.applicationName) play pause"],
                    shortTitle: "Play/Pause", systemImageName: "playpause")
        AppShortcut(intent: LockMacIntent(), phrases: ["Lock my Mac with \(.applicationName)"],
                    shortTitle: "Lock Mac", systemImageName: "lock")
        AppShortcut(intent: SleepMacDisplayIntent(), phrases: ["Sleep my Mac display with \(.applicationName)"],
                    shortTitle: "Sleep Display", systemImageName: "moon")
    }
}
