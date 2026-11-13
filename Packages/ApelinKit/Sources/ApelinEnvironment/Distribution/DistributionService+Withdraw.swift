import ApelinCore
import ApelinGit
import ApelinProtocol
import Foundation

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
