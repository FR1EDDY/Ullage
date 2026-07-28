import XCTest
@testable import Ullage

final class HudWindowTests: XCTestCase {
    /// The HUD should stay fully interactive while the pointer moves from the
    /// card body onto the close affordance. If the button's hover counts as
    /// "left the HUD", the button vanishes under the cursor and becomes almost
    /// impossible to acquire.
    func testHoveringCloseButtonKeepsHudInteractive() {
        XCTAssertTrue(HudHoverState(card: true, closeButton: false).isInteractive)
        XCTAssertTrue(HudHoverState(card: false, closeButton: true).isInteractive)
        XCTAssertFalse(HudHoverState(card: false, closeButton: false).isInteractive)
    }
}
