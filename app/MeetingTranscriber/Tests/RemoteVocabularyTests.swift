import Foundation
@testable import MeetingTranscriber
import XCTest

final class RemoteVocabularyTests: XCTestCase {
    /// A fixed formatter, so the sentences do not depend on the locale.
    private static func formatDate(_ date: Date) -> String {
        "<\(Int(date.timeIntervalSince1970))>"
    }

    func testSourceLabelsAndPersistedValues() {
        XCTAssertEqual(VocabularySource.allCases.map(\.label), ["Local file", "URL"])
        XCTAssertEqual(VocabularySource.allCases.map(\.rawValue), ["file", "url"])
    }

    func testAddressValidationTrimsAndNamesEachProblem() throws {
        let valid = try XCTUnwrap(URL(string: "https://lists.example.org/vocabulary.txt"))
        let cases: [(String, Result<URL, RemoteVocabularyAddressProblem>)] = [
            ("", .failure(.empty)),
            (" \n\t", .failure(.empty)),
            ("http://lists.example.org/vocabulary.txt", .failure(.notHTTPS)),
            ("lists.example.org/vocabulary.txt", .failure(.notHTTPS)),
            ("https://", .failure(.missingHost)),
            ("https:///vocabulary.txt", .failure(.missingHost)),
            ("  https://lists.example.org/vocabulary.txt \n", .success(valid)),
        ]

        for (address, expected) in cases {
            XCTAssertEqual(RemoteVocabulary.validateAddress(address), expected, address)
        }
    }

    func testValidatorsTreatMissingAndEmptyValuesAsAbsent() {
        XCTAssertNil(RemoteVocabularyValidators(etag: nil, lastModified: nil))
        XCTAssertNil(RemoteVocabularyValidators(etag: "", lastModified: ""))
        XCTAssertEqual(RemoteVocabularyValidators(etag: "\"v1\"", lastModified: "")?.etag, "\"v1\"")
        XCTAssertNil(RemoteVocabularyValidators(etag: "\"v1\"", lastModified: "")?.lastModified)
    }

    func testFailureMessages() {
        let cases: [(RemoteVocabularyFailure, String)] = [
            (.offline, "No connection to the server"),
            (.timedOut, "The server did not answer in time"),
            (.httpStatus(401), "Access denied (HTTP 401) – check the access token"),
            (.httpStatus(403), "Access denied (HTTP 403) – check the access token"),
            (.httpStatus(404), "Not found (HTTP 404) – check the address"),
            (.httpStatus(500), "The server answered with HTTP 500"),
            (.redirectToOtherServer, "The address redirects to another server; the token is not sent there"),
            (.insecureRedirect, "The address redirects to an address without https"),
            (.notTextFile, "The address returned a web page, not a text file"),
            (.tooLarge, "The file is larger than 256 KB"),
            (.invalidContent(.tooManyTerms), "Vocabulary file contains too many terms"),
            (.couldNotSave, "The download could not be saved"),
            (.unexpectedNotModified, "The server reported no change for a copy this app does not have"),
            (.cancelled, "The check was cancelled"),
        ]

        for (failure, message) in cases {
            XCTAssertEqual(failure.message, message)
        }
    }

    func testStatusMessages() {
        let updated = Date(timeIntervalSince1970: 1_791_288_120)
        let checked = Date(timeIntervalSince1970: 1_791_291_720)
        let cases: [(RemoteVocabularyStatus, String)] = [
            (.inactive, "Not in use – the vocabulary comes from the local file"),
            (.addressProblem(.empty), "No address entered – no vocabulary in use"),
            (.addressProblem(.notHTTPS), "The address must start with https:// – no vocabulary in use"),
            (.addressProblem(.missingHost), "The address names no server – no vocabulary in use"),
            (.notDownloaded, "Not downloaded yet – no vocabulary in use"),
            (.checking, "Checking the address…"),
            (
                .current(termCount: 128, updatedAt: updated, checkedAt: checked),
                "128 terms · updated <1791288120> · checked <1791291720>",
            ),
            (
                .failed(.offline, lastGood: RemoteVocabularyCopyInfo(termCount: 128, updatedAt: updated)),
                "No connection to the server · using the copy from <1791288120> (128 terms)",
            ),
            (
                .failed(.httpStatus(401), lastGood: RemoteVocabularyCopyInfo(termCount: 1, updatedAt: updated)),
                "Access denied (HTTP 401) – check the access token · using the copy from <1791288120> (1 term)",
            ),
            (.failed(.offline, lastGood: nil), "No connection to the server · no vocabulary in use"),
        ]

        for (status, message) in cases {
            XCTAssertEqual(status.message(formatDate: Self.formatDate), message)
        }
    }
}
