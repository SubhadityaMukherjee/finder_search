import SwiftUI
import SwiftData

@main
struct FinderSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        do {
            let fm = FileManager.default
            guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                fatalError("Application Support directory not found")
            }
            let bundleDir = appSupport.appending(path: "FinderSearch", directoryHint: .isDirectory)
            try? fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
            let storeURL = bundleDir.appending(path: "store.sqlite")
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: FileRecord.self, Chunk.self, TrackedFolder.self,
                configurations: config
            )
            let store = Store(modelContainer: container)
            let state = AppState(store: store)
            _appState = State(initialValue: state)
            // Hand it to the AppDelegate (instantiated earlier by SwiftUI) via the side channel.
            AppStateHolder.instance = state

            if CommandLine.arguments.contains("--self-test") {
                Task { @MainActor in
                    await SelfTest.run(appState: state)
                }
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("FinderSearch", id: "main") {
            SearchWindow()
                .environment(appState)
                .modelContainer(appState.store.modelContainer)
        }
        .defaultSize(width: 900, height: 620)
    }
}
