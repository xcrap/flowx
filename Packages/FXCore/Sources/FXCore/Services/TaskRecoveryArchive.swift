import Foundation

/// Preserve the remaining local data of a task whose provider files are gone.
/// Originals stay intact until the caller has confirmed this archive reached Trash.
public enum TaskRecoveryArchive {
    private struct Entry: Codable {
        let originalPath: String
        let archivedPath: String
    }

    public static func copyToTrash(
        metadata: Data,
        files: [URL],
        stagingDirectory: URL,
        trashHandler: (URL) throws -> Void = { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        }
    ) throws {
        let manager = FileManager.default
        let archive = stagingDirectory.appendingPathComponent(
            "FlowX Task Recovery \(UUID().uuidString)", isDirectory: true
        )
        try manager.createDirectory(
            at: archive, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // These are copies only. Failed copying or trashing never removes the
        // source task, and never leaves an incomplete archive presented as saved.
        defer { try? manager.removeItem(at: archive) }
        try metadata.write(to: archive.appendingPathComponent("task.json"), options: .atomic)
        var entries: [Entry] = []
        for (index, source) in files.enumerated() {
            do {
                _ = try source.resourceValues(forKeys: [.isDirectoryKey])
            } catch CocoaError.fileReadNoSuchFile {
                continue
            }
            let relativePath = "files/\(index)/\(source.lastPathComponent)"
            let destination = archive.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.copyItem(at: source, to: destination)
            entries.append(Entry(originalPath: source.path, archivedPath: relativePath))
        }
        try JSONEncoder().encode(entries).write(
            to: archive.appendingPathComponent("files.json"), options: .atomic
        )
        let instructions = """
        FlowX task recovery

        The original Claude session files were already missing. This folder
        preserves the remaining FlowX cache and attachments, not a complete
        Claude transcript. task.json contains the task identity and current state.
        files.json maps each saved file or folder to its original location.

        To recover files, move this folder out of Trash and use files.json to
        locate the copies. Quit FlowX before restoring files to their original
        locations. Restoring the cache alone cannot recreate the missing Claude
        session or make it resumable in Claude Code.
        """
        try Data(instructions.utf8).write(to: archive.appendingPathComponent("README.txt"))
        try trashHandler(archive)
    }
}
