import Foundation
import Testing
@testable import Slightshot

struct StagingCleanupTests {
    @Test func unavailableParentIsRetriedWhenItReturns() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("volume")
        let offline = root.appendingPathComponent("offline")
        let staging = parent.appendingPathComponent(RecordingExport.stagingPrefix + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        RecordingExport.rememberStagingParent(parent)
        defer {
            try? manager.removeItem(at: root)
            try? manager.createDirectory(at: parent, withIntermediateDirectories: true)
            RecordingExport.forgetStagingParent(parent)
            try? manager.removeItem(at: root)
        }
        try manager.moveItem(at: parent, to: offline)
        sweep(parent)
        #expect(RecordingExport.stagingParents.contains { $0.path == parent.path },
                "An unavailable drive must stay registered for the next launch")
        try manager.moveItem(at: offline, to: parent)
        sweep(parent)
        #expect(!manager.fileExists(atPath: staging.path))
        #expect(!RecordingExport.stagingParents.contains { $0.path == parent.path })
    }

    @Test func failedDeletionAndLiveFoldersKeepTheirParent() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = parent.appendingPathComponent(RecordingExport.stagingPrefix + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        RecordingExport.rememberStagingParent(parent)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? manager.removeItem(at: staging)
            RecordingExport.forgetStagingParent(parent)
            try? manager.removeItem(at: parent)
        }
        let lock = try FolderLock(directory: staging)
        sweep(parent)
        #expect(RecordingExport.stagingParents.contains { $0.path == parent.path })
        lock.release()
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        sweep(parent)
        #expect(manager.fileExists(atPath: staging.path))
        #expect(RecordingExport.stagingParents.contains { $0.path == parent.path })
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        sweep(parent)
        #expect(!manager.fileExists(atPath: staging.path))
        #expect(!RecordingExport.stagingParents.contains { $0.path == parent.path })
    }

    private func sweep(_ parent: URL) {
        ScreenRecordingSession.removeAbandonedDirectories(
            prefix: RecordingExport.stagingPrefix, in: parent, createdBefore: .distantFuture)
        RecordingExport.forgetStagingParent(parent)
    }
}
