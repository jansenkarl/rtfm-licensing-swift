import XCTest
@testable import RTFMLicensing

final class RTFMLicensingTests: XCTestCase {
    func testVersionIsSemantic() {
        XCTAssertNotNil(RTFMLicensingInfo.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }
}
