import AppKit

/// Culling writes each explicit Keep or Reject immediately, so quitting never
/// has an in-memory selection set that needs an Apply/Discard decision.
@MainActor
final class FotocopyApplicationDelegate: NSObject, NSApplicationDelegate { }
