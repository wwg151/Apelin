import ApelinCore
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A release package a build left in `Builds/`, offered only while the file
/// there still has the bytes the build recorded, so what is shared or
/// published is the package that build made, never built or packaged again.
struct DistributionPackage {
    /// How far it has gone. Published (the linked repository's clone holds
    /// these bytes under the name publishing gives them) says more than
    /// Shared (a share sheet completed with them), which says more than
    /// Built.
    enum State {
        case built, shared, published

        var title: String {
            switch self {
            case .built: String(localized: "Built")
            case .shared: String(localized: "Shared")
            case .published: String(localized: "Published")
            }
        }
    }

    var artifactID: String
    var bootstrap: BuildBootstrap
    var packageID: String
    var version: String
    var architecture: String
    var createdAt: Date
    var file: URL
    /// `sha256:` of the file, as its build recorded it.
    var digest: String
    var isPublished: Bool

    var state: State {
        if isPublished {
            .published
        } else if SharedPackages.contains(digest) {
            .shared
        } else {
            .built
        }
    }

    /// What sharing and publishing take.
    var item: DistributionPublishing.Item {
        DistributionPublishing.Item(path: file.path, digest: digest, packageID: packageID, version: version, bootstrap: bootstrap, createdAt: createdAt)
    }
}

/// The release packages the distribution page offers, read from the
/// artifact records apelin-build writes as mobile
/// (`Builds/artifacts/<artifactID>.json`: `ArtifactRecord` in ApelinBuild,
/// which the app does not link), each file read back before it is offered.
enum DistributionPackages {
    /// The fields of `ArtifactRecord` read here.
    private struct Record: Decodable {
        var artifactID: String
        var projectID: String
        var configuration: String
        var bootstrap: String
        var path: String
        var digest: String
        var packageID: String
        var packageVersion: String
        var architecture: String
        var createdAt: Date
    }

    private static var buildsFolder: URL {
        DataFolder.app.root.appendingPathComponent("Builds", isDirectory: true)
    }

    /// Every available release build for this project, newest first. A
    /// description keeps its package identity; a workspace's script chooses
    /// that identity. Each artifact remains a separate selectable build.
    static func history(
        projectID: String,
        package: (id: String, version: String)?,
        isWorkspace: Bool,
        repository: DistributionRepository?,
    ) async -> [DistributionPackage] {
        guard isWorkspace || package != nil else { return [] }
        return await Task.detached { () -> [DistributionPackage] in
            let releases = records().filter { record in
                record.projectID == projectID && record.configuration == "Release"
                    && (package.map { record.packageID == $0.id } ?? true)
            }.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.artifactID < $1.artifactID
            }
            let debs = repository.flatMap(debsFolder(of:))
            var publishedDigests: [String: String] = [:]
            var checkedNames: Set<String> = []
            return releases.compactMap { record in
                guard let target = BuildBootstrap(rawValue: record.bootstrap),
                      let file = try? verify(path: record.path, digest: record.digest)
                else { return nil }
                if let debs, let name = fileName(package: record.packageID, version: record.packageVersion, architecture: record.architecture),
                   checkedNames.insert(name).inserted
                {
                    publishedDigests[name] = publishedDigest(of: record, in: debs)
                }
                let name = fileName(package: record.packageID, version: record.packageVersion, architecture: record.architecture)
                return DistributionPackage(
                    artifactID: record.artifactID,
                    bootstrap: target,
                    packageID: record.packageID,
                    version: record.packageVersion,
                    architecture: record.architecture,
                    createdAt: record.createdAt,
                    file: file,
                    digest: record.digest,
                    isPublished: name.flatMap { publishedDigests[$0] } == record.digest,
                )
            }
        }.value
    }

    /// The build's file where the build left it, inside `Builds/`, with the
    /// bytes it recorded; throws saying which is not so.
    static func verify(path: String?, digest: String) throws -> URL {
        guard let path, let canonical = CanonicalPath.resolve(path),
              let builds = CanonicalPath.resolve(buildsFolder.path),
              CanonicalPath.isCanonical(canonical, inside: builds)
        else {
            throw ApelinError(.notFound, String(localized: "The package is no longer available. Build it again."))
        }
        guard sha256(ofFileAt: canonical) == digest else {
            throw ApelinError(.conflict, String(localized: "The package changed after it was built. Build it again before exporting."))
        }
        return URL(fileURLWithPath: canonical)
    }

    /// Remove only this build's local package and artifact record. Logs,
    /// dSYMs and repository copies remain available.
    static func remove(_ package: DistributionPackage) async throws {
        let artifactID = package.artifactID
        let path = package.file.path
        let digest = package.digest
        try await Task.detached {
            guard !artifactID.isEmpty, !artifactID.hasPrefix("."),
                  !artifactID.contains("/"), !artifactID.contains("\0"),
                  let builds = CanonicalPath.resolve(buildsFolder.path),
                  let folder = CanonicalPath.resolve(buildsFolder.appendingPathComponent("artifacts").path),
                  folder == builds + "/artifacts"
            else { throw ApelinError(.notFound, String(localized: "The package is no longer available. Build it again.")) }
            let recordPath = folder + "/" + artifactID + ".json"
            guard CanonicalPath.resolve(recordPath) == recordPath else {
                throw ApelinError(.notFound, String(localized: "The package is no longer available. Build it again."))
            }
            let record = try JSONCoding.decode(Record.self, from: Data(contentsOf: URL(fileURLWithPath: recordPath)))
            let recordedPath = BootstrapRootPath.rebased(record.path, onto: folder)
            let file = try verify(path: path, digest: digest)
            guard record.artifactID == artifactID, record.digest == digest,
                  CanonicalPath.resolve(recordedPath) == file.path,
                  file.path.hasSuffix(".deb")
            else { throw ApelinError(.conflict, String(localized: "The package changed after it was built. Build it again before exporting.")) }
            // unlink never recursively removes a directory or follows a link.
            guard unlink(file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard unlink(recordPath) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }.value
    }

    /// `<Package>_<Version>_<Architecture>.deb`, the name
    /// `distributionPublish` gives a package in the repository's `debs/`,
    /// the epoch's colon spelled `%3a` as dpkg-name does; nil for fields it
    /// refuses, so no other path is ever made from them.
    static func fileName(package: String, version: String, architecture: String) -> String? {
        let name = "\(package)_\(version.replacingOccurrences(of: ":", with: "%3a"))_\(architecture).deb"
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.+-~_%")
        guard !package.isEmpty, !version.isEmpty, !architecture.isEmpty,
              !name.hasPrefix("."), name.count <= 255,
              name.dropLast(4).allSatisfy(allowed.contains)
        else { return nil }
        return name
    }

    /// Every record that reads, in no particular order.
    private static func records() -> [Record] {
        let folder = buildsFolder.appendingPathComponent("artifacts", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  var record = try? JSONCoding.decode(Record.self, from: data) else { return nil }
            // a build from before roothide renamed its root (issue #34)
            record.path = BootstrapRootPath.rebased(record.path, onto: folder.path)
            return record
        }
    }

    /// The linked repository's `debs/`, in its workspace project.
    private static func debsFolder(of repository: DistributionRepository) -> String? {
        guard let root = DataFolder.app.project(named: repository.projectName),
              let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
              let clone = CanonicalPath.resolve(root.path),
              clone == projects + "/" + repository.projectName,
              let debs = CanonicalPath.resolve(clone + "/debs"),
              debs == clone + "/debs"
        else { return nil }
        return debs
    }

    /// The digest of the regular file the repository holds under the name
    /// `record`'s package is published as; nil when there is none.
    private static func publishedDigest(of record: Record, in debs: String) -> String? {
        guard let name = fileName(package: record.packageID, version: record.packageVersion, architecture: record.architecture)
        else { return nil }
        let path = debs + "/" + name
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return sha256(ofFileAt: path)
    }

    /// `sha256:` and the file's hex digest, read a mebibyte at a time; nil
    /// when it cannot be read to its end.
    private static func sha256(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                return nil
            }
            // nil, not an empty piece, is the end of the file
            guard let chunk, !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The packages a share sheet completed with, by digest, newest last, in
/// the app's defaults: what makes a package Shared.
enum SharedPackages {
    private static let key = "distribution.sharedPackages"
    private static let limit = 200

    static func contains(_ digest: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: key)?.contains(digest) ?? false
    }

    static func record(_ digest: String) {
        var digests = UserDefaults.standard.stringArray(forKey: key)?.filter { $0 != digest } ?? []
        digests.append(digest)
        UserDefaults.standard.set(Array(digests.suffix(limit)), forKey: key)
    }
}

/// The repository-facing icon is independent of the project's sidebar icon.
@MainActor
enum DistributionIconFile {
    private static let name = "icon.png"
    private static let side = 256
    private static let iconLimit = 1 << 20
    private static let inputLimit = 32 << 20
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let readFlags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC

    private static func systemError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    /// Walk single components from the canonical data root. Keep the directory
    /// open across the operation rather than re-resolving its name at commit.
    private static func directory(_ projectName: String, create: Bool) throws -> Int32? {
        guard DataFolder.app.project(named: projectName) != nil,
              let root = CanonicalPath.resolve(DataFolder.app.root.path)
        else { throw CocoaError(.fileReadInvalidFileName) }
        let base = open(root, directoryFlags)
        guard base >= 0 else { throw systemError() }
        defer { close(base) }
        let projects = openat(base, "Projects", directoryFlags)
        guard projects >= 0 else { throw systemError() }
        defer { close(projects) }
        let project = openat(projects, projectName, directoryFlags)
        guard project >= 0 else { throw systemError() }
        defer { close(project) }
        if create, mkdirat(project, "Distribution", 0o755) != 0, errno != EEXIST { throw systemError() }
        let folder = openat(project, "Distribution", directoryFlags)
        if folder < 0, !create, errno == ENOENT { return nil }
        guard folder >= 0 else { throw systemError() }
        return folder
    }

    /// Takes ownership of fd. Bound the actual read too: the file may grow
    /// after fstat, and mapping a mutable picker file would not be a snapshot.
    private static func bytes(_ fd: Int32, limit: Int) throws -> Data {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard info.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(65536, limit + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        }
        return result
    }

    private static func source(_ data: Data) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return source
    }

    static func read(projectName: String) throws -> Data? {
        guard let folder = try directory(projectName, create: false) else { return nil }
        defer { close(folder) }
        let fd = openat(folder, name, readFlags)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw systemError() }
        let data = try bytes(fd, limit: iconLimit)
        let image = try source(data)
        guard CGImageSourceGetType(image) as String? == UTType.png.identifier,
              CGImageSourceGetCount(image) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == side, props[kCGImagePropertyPixelHeight] as? Int == side,
              CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
              CGImageSourceGetStatus(image) == .statusComplete else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    static func importImage(from url: URL, projectName: String) throws -> Data {
        guard url.isFileURL, !url.path.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, readFlags)
        guard fd >= 0 else { throw systemError() }
        let image = try source(bytes(fd, limit: inputLimit))
        guard let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = props[kCGImagePropertyPixelHeight] as? Int, height > 0,
              width <= 64_000_000 / height else { throw CocoaError(.fileReadCorruptFile) }
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let edge = CGFloat(side)
        let scale = edge / CGFloat(max(thumb.width, thumb.height))
        let w = CGFloat(thumb.width) * scale, h = CGFloat(thumb.height) * scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format)
        let png = renderer.pngData { _ in
            UIImage(cgImage: thumb).draw(in: CGRect(x: (edge - w) / 2, y: (edge - h) / 2, width: w, height: h))
        }
        guard !png.isEmpty, png.count <= iconLimit else { throw CocoaError(.fileWriteUnknown) }
        guard let folder = try directory(projectName, create: true) else { throw CocoaError(.fileNoSuchFile) }
        defer { close(folder) }
        try replace(in: folder, with: png)
        return png
    }

    private static func replace(in folder: Int32, with png: Data) throws {
        let temp = ".icon-\(UUID().uuidString).tmp"
        let fd = openat(folder, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw systemError() }
        defer { unlinkat(folder, temp, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: png)
        try handle.close()
        var info = stat()
        var flags = UInt32(RENAME_NOFOLLOW_ANY)
        if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw CocoaError(.fileWriteInvalidFileName) }
        } else {
            guard errno == ENOENT else { throw systemError() }
            flags |= UInt32(RENAME_EXCL)
        }
        guard renameatx_np(folder, temp, folder, name, flags) == 0 else { throw systemError() }
    }
}
