import ApelinCore
import ApelinGit
import ApelinProtocol
import CryptoKit
import Foundation
import ImageIO

extension DistributionService {
    static func iconBlobSHA(packageID: String, png: Data) throws -> String {
        let alnum = Set("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        let bytes = packageID.utf8
        guard (2 ... 251).contains(bytes.count), let first = bytes.first, alnum.contains(first),
              bytes.allSatisfy(alnum.union(".+-".utf8).contains)
        else { throw ApelinError(.badRequest, "Use a valid Debian package ID.") }

        guard png.count <= 1 << 20, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              png.suffix(12).elementsEqual([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]),
              let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == 256, props[kCGImagePropertyPixelHeight] as? Int == 256,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == 256, image.height == 256, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetType(source) as String? == "public.png"
        else { throw ApelinError(.badRequest, "Use a single 256 × 256 PNG no larger than 1 MiB.") }
        return Insecure.SHA1.hash(data: Data("blob \(png.count)\0".utf8) + png).map { String(format: "%02x", $0) }.joined()
    }

    func iconStatus(packageID: String, png: Data) async throws -> DistributionIconStatus {
        let local = try Self.iconBlobSHA(packageID: packageID, png: png)
        guard let linked = linked() else { throw ApelinError(.notFound, "Link a package repository in Settings ▸ Git first.") }
        let api = try api()
        let repository = linked.fullName
        let remote = try await api.repository(repository)
        guard remote.fullName.lowercased() == repository.lowercased(), let branch = remote.defaultBranch, !branch.isEmpty,
              let ref = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { throw ApelinError(.conflict, "The linked repository changed or has no default branch.") }
        let path = "/repos/\(repository)/contents/images/\(packageID).png?ref=\(ref)"
        var request = try api.request("GET", path, body: nil)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await api.exchange(request)
        let sha: String?
        if response.statusCode == 404 {
            sha = nil
        } else {
            try GitHubAPI.check(response, data)
            struct Entry: Decodable { let type: String; let sha: String; let path: String }
            let entry = try GitHubAPI.decode(Entry.self, data, "GET", path)
            guard entry.type == "file", entry.path == "images/\(packageID).png", entry.sha.utf8.count == 40,
                  entry.sha.utf8.allSatisfy(Set("0123456789abcdef".utf8).contains)
            else { throw ApelinError(.conflict, "The icon path is not a regular file.") }
            sha = entry.sha
        }
        return DistributionIconStatus(repository: repository, branch: branch, packageID: packageID, blobSHA: sha, localBlobSHA: local)
    }

    func publishIcon(snapshot: DistributionIconStatus, png: Data) async throws -> DistributionIconStatus {
        guard linked()?.fullName == snapshot.repository else {
            throw ApelinError(.conflict, "The linked package repository changed. Refresh the preview.")
        }
        let current = try await iconStatus(packageID: snapshot.packageID, png: png)
        guard snapshot == current, linked()?.fullName == current.repository else {
            throw ApelinError(.conflict, "The repository or icon changed. Refresh the preview before publishing.")
        }
        if current.identical { return current }
        let path = "/repos/\(current.repository)/contents/\(current.path)"
        var body = ["message": "Publish icon for \(current.packageID)", "content": png.base64EncodedString(), "branch": current.branch]
        // Missing sha is create-only; for updates GitHub compares sha atomically.
        body["sha"] = current.blobSHA
        struct Updated: Decodable { let content: GitHubAPI.GitObject }
        let api = try api()
        let result = try await api.send("PUT", path, body: body, as: Updated.self)
        guard result.content.sha == current.localBlobSHA else { throw ApelinError(.unavailable, "Refresh to verify the published icon.") }
        return DistributionIconStatus(repository: current.repository, branch: current.branch, packageID: current.packageID, blobSHA: result.content.sha, localBlobSHA: current.localBlobSHA)
    }
}

extension DistributionService {
    public func packages() async throws -> DistributionPackagesResponse {
        guard let linked = linked() else {
            throw ApelinError(.notFound, "No package repository is linked. Create or link one in Settings ▸ Git.")
        }
        let api = try api()
        let remote = try await api.repository(linked.fullName)
        guard let branch = remote.defaultBranch else {
            throw ApelinError(.notFound, "The package repository has no default branch.")
        }
        let head = try await api.branchHead(linked.fullName, branch: branch)
        let commit = try await api.gitCommit(linked.fullName, sha: head)
        let tree = try await api.gitTree(linked.fullName, sha: commit.tree.sha)
        let packages = tree.tree.filter {
            $0.type == "blob" && ($0.mode == "100644" || $0.mode == "100755") && Self.isPackagePath($0.path)
        }.map { DistributionRepositoryPackage(path: $0.path, sha: $0.sha) }
            .sorted { $0.path < $1.path }
        return DistributionPackagesResponse(repository: linked, branch: branch, commit: head, packages: packages)
    }

    public func prepareWithdraw(_ request: DistributionWithdrawRequest) throws {
        guard let linked = linked(), linked == request.snapshot.repository else {
            throw ApelinError(.conflict, "The linked package repository changed. Refresh the package list.")
        }
        guard !request.packages.isEmpty, request.packages.count <= 100,
              Set(request.packages.map(\.path)).count == request.packages.count,
              request.packages.allSatisfy({ Self.isPackagePath($0.path) && request.snapshot.packages.contains($0) })
        else { throw ApelinError(.badRequest, "Select between 1 and 100 packages from the repository list.") }
        _ = try api()
    }

    public func withdraw(_ request: DistributionWithdrawRequest, reporter: TaskReporter) async throws -> JSONValue {
        try prepareWithdraw(request)
        reporter.stage("fetching")
        let current = try await packages()
        guard current.repository == request.snapshot.repository,
              current.branch == request.snapshot.branch, current.commit == request.snapshot.commit,
              request.packages.allSatisfy({ current.packages.contains($0) })
        else { throw ApelinError(.conflict, "The repository changed. Refresh the package list and select the packages again.") }
        try reporter.checkCancelled()
        reporter.stage("preparing")
        let api = try api()
        let parent = try await api.gitCommit(current.repository.fullName, sha: current.commit)
        try prepareWithdraw(request)
        try reporter.checkCancelled()
        reporter.stage("pushing")
        let commit = try await api.withdraw(current.repository.fullName, branch: current.branch, parent: parent, paths: request.packages.map(\.path))
        // The clone catches up, so the distribution page stops offering a
        // package the repository no longer holds; a clone that cannot move
        // does not undo a withdrawal that already happened.
        if let target = try? git.preparePull(GitPullRequest(projectID: current.repository.projectID)) {
            _ = try? git.pull(target, reporter: reporter)
        }
        return .object([
            "withdrawn": .array(request.packages.map { .string($0.path) }),
            "repository": .string(current.repository.fullName),
            "sourceURL": .string(current.repository.sourceURL),
            "commit": .string(commit),
        ])
    }

    static func isPackagePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "debs" && !parts[1].hasPrefix(".")
            && parts[1].hasSuffix(".deb") && !path.utf8.contains(0)
    }
}
