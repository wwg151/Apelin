import ApelinCore
@testable import ApelinEnvironment
import Foundation
import XCTest

final class DistributionWithdrawalTests: XCTestCase {
    func testPackagePathsStayInsideDebs() {
        XCTAssertTrue(DistributionService.isPackagePath("debs/test_1_iphoneos-arm64.deb"))
        for path in ["debs/../test.deb", "debs/.hidden.deb", "other/test.deb", "debs/sub/test.deb", "debs/test.deb\0"] {
            XCTAssertFalse(DistributionService.isPackagePath(path))
        }
    }

    func testWithdrawalDeletesOnlySelectedPathsAndNeverForcesBranch() async throws {
        let api = GitHubAPI(token: "test", exchange: { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            let path = try XCTUnwrap(request.url).path
            let answer: [String: Any]
            if path.hasSuffix("/git/trees") {
                XCTAssertEqual(body["base_tree"] as? String, "tree-before")
                let entries = try XCTUnwrap(body["tree"] as? [[String: Any]])
                XCTAssertEqual(entries.count, 1)
                XCTAssertEqual(entries[0]["path"] as? String, "debs/test.deb")
                XCTAssertTrue(entries[0]["sha"] is NSNull)
                answer = ["sha": "tree-after"]
            } else if path.hasSuffix("/git/commits") {
                XCTAssertEqual(body["parents"] as? [String], ["before"])
                XCTAssertEqual(body["tree"] as? String, "tree-after")
                answer = ["sha": "after"]
            } else {
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(body["force"] as? Bool, false)
                XCTAssertEqual(body["sha"] as? String, "after")
                answer = [:]
            }
            return (try JSONSerialization.data(withJSONObject: answer), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let parent = GitHubAPI.GitCommit(sha: "before", tree: .init(sha: "tree-before"))
        let commit = try await api.withdraw("someone/packages", branch: "main", parent: parent, paths: ["debs/test.deb"])
        XCTAssertEqual(commit, "after")
    }

    func testConcurrentBranchUpdateIsReportedAsConflict() async throws {
        let api = GitHubAPI(token: "test", exchange: { request in
            let status = request.httpMethod == "PATCH" ? 422 : 201
            let body: [String: String] = status == 422 ? ["message": "Update is not a fast forward"] : ["sha": "new"]
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await api.withdraw("someone/packages", branch: "main", parent: .init(sha: "before", tree: .init(sha: "tree")), paths: ["debs/test.deb"])
            XCTFail("A concurrent push must be refused")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .conflict)
        }
    }
}
