import AppKit

@MainActor
enum CullApplicationLifecycle {
    weak static var activeModel: CullViewModel?
}

@MainActor
final class FotocopyApplicationDelegate: NSObject, NSApplicationDelegate {
    private var isAwaitingCullDecision = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isAwaitingCullDecision,
              let model = CullApplicationLifecycle.activeModel,
              model.hasPendingCullChanges else {
            return .terminateNow
        }

        isAwaitingCullDecision = true
        model.requestLeavingCull(
            onContinue: { [weak self] in
                self?.replyToTerminationRequest(shouldTerminate: true)
            },
            onCancel: { [weak self] in
                self?.replyToTerminationRequest(shouldTerminate: false)
            }
        )
        return .terminateLater
    }

    private func replyToTerminationRequest(shouldTerminate: Bool) {
        isAwaitingCullDecision = false
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }
}
