@testable import MeetingTranscriber
import XCTest

/// The license label and the non-commercial mark the model browser shows.
final class HuggingFaceLicenseTests: XCTestCase {
    func testLabelAndNonCommercialMark() {
        let cases: [(identifier: String, label: String, nonCommercial: Bool)] = [
            ("apache-2.0", "Apache 2.0", false),
            ("mit", "MIT", false),
            ("cc-by-4.0", "CC BY 4.0", false),
            ("cc-by-nc-4.0", "CC BY-NC 4.0", true),
            ("cc-by-nc-sa-4.0", "CC BY-NC-SA 4.0", true),
            ("cc-by-nc-nd-3.0", "CC BY-NC-ND 3.0", true),
            ("CC-BY-NC-4.0", "CC BY-NC 4.0", true),
            ("swissdial-cc-by-nc-4.0-no-reidentification", "swissdial-cc-by-nc-4.0-no-reidentification", true),
            ("cc0-1.0", "cc0-1.0", false),
            ("openrail", "openrail", false),
            ("other", "other", false),
            // "nc" only counts as a whole component.
            ("unc-research", "unc-research", false),
        ]
        for testCase in cases {
            let license = HuggingFaceLicense(identifier: testCase.identifier)
            XCTAssertEqual(license.label, testCase.label, testCase.identifier)
            XCTAssertEqual(license.isNonCommercial, testCase.nonCommercial, testCase.identifier)
            let display = testCase.nonCommercial ? "\(testCase.label) — non-commercial" : testCase.label
            XCTAssertEqual(license.displayText, display, testCase.identifier)
        }
    }
}
