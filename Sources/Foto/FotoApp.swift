import SwiftUI

@main
struct FotoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 400)
    }
}
