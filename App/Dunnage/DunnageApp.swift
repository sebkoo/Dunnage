import SwiftUI
import UIKit
import DunnageTransport

/// The app. It owns exactly what only an app can own (spec §4.1): the background session's
/// identifier and configuration, the delegate the system hands the relaunch events to, the
/// container layout, and the driver loop that runs on launch.
@main
struct DunnageApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            UploadScreen(model: delegate.model)
                .task { await delegate.model.begin() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// One per process. The configuration is `URLSessionPartTasks`' own (ADR-0007 §6): the
    /// resource timeout, `isDiscretionary` false and `sessionSendsLaunchEvents` true, each
    /// with its reason recorded there. The app names the identifier and nothing else.
    let tasks = URLSessionPartTasks(
        configuration: URLSessionPartTasks.backgroundConfiguration(
            identifier: UploadModel.backgroundSessionIdentifier))

    private(set) lazy var container: Container = {
        // A container the app cannot open is not a state this app can run in: every path
        // below — the ledger, the payload copy, the chunk files — is derived from it.
        try! Container.applicationSupport()
    }()

    private(set) lazy var model = UploadModel(
        container: container,
        tasks: tasks,
        arguments: LaunchArguments.parse(ProcessInfo.processInfo.arguments))

    /// The system woke the app to deliver this session's events. The handler is handed to
    /// `URLSessionPartTasks`, which calls it back from `urlSessionDidFinishEvents` — the
    /// one caller (spec §4.1).
    nonisolated func application(_ application: UIApplication,
                                 handleEventsForBackgroundURLSession identifier: String,
                                 completionHandler: @escaping () -> Void) {
        let handler = UncheckedHandler(completionHandler)
        Task { @MainActor in
            guard identifier == UploadModel.backgroundSessionIdentifier else {
                handler.call()
                return
            }
            tasks.finishedEvents { handler.call() }
        }
    }

    /// The `last-exit` marker.
    ///
    /// **Evidence only when present.** Its absence is never read as a signal: a process
    /// killed before this hook ran and a hook that never runs leave the same missing file
    /// (ADR-0007 O-14). Nothing in the test, the job or the ADR reads the absence.
    nonisolated func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated { container.recordExit("applicationWillTerminate") }
    }
}

/// A completion handler UIKit hands over on the main thread and Swift 6 will not let cross
/// an isolation boundary on its own. It is called once, on the main actor, and the box
/// exists only to say so.
private final class UncheckedHandler: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}
