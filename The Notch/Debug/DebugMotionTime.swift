import SwiftUI

/// Pins every continuously-animating mark in the tree to one chosen instant.
///
/// `FrameDump` can already render the real views, but it renders them at whatever "now" happens
/// to be — which is useless for an animation, and worse than useless for these particular ones,
/// since each is phased from its own start and would render at elapsed ≈ 0. The individual views
/// grew `debugElapsed` / `debugPhase` parameters for the filmstrips, but a parameter only reaches
/// a view the dump constructs *directly*. It cannot reach a `StatusIndicator` four levels down
/// inside a real `NotchRootView`, which is exactly where the interesting frames are.
///
/// An environment value reaches all of them without any surface having to thread a debug
/// parameter through its initialiser. Nothing sets it outside `FrameDump`, and when it is unset
/// every view falls back to the display link as usual.
extension EnvironmentValues {
    @Entry var debugMotionTime: Double?
}
