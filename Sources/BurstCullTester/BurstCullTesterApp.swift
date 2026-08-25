import SwiftUI

@main
struct BurstCullTesterApp: App {
    var body: some Scene {
        WindowGroup("Burst Cull Tester") {
            BurstCullTesterView()
        }
        .defaultSize(width: 1_140, height: 760)
    }
}
