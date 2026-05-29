import SwiftUI

@main
struct AutoImproveRecorderIOSApp: App {
    @StateObject private var state: IOSAppState

    init() {
        AIRColdStartTracker.markAppInit()
        AIRColdStartTracker.markStateInitStart()
        let s = IOSAppState()
        AIRColdStartTracker.markStateInitDone()
        _state = StateObject(wrappedValue: s)

        if AIRBenchmarkRunner.isActive {
            AIRBenchmarkRunner.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            IOSRecorderView()
                .environmentObject(state)
        }
    }
}
