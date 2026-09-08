import Foundation

enum TemporaryArtifactStore {
    static var directoryName: String {
        YoumuFeatureEnvironmentStore.shared.temporaryDirectory.lastPathComponent
    }

    static func managedDirectory(root: URL? = nil) -> URL {
        guard let root else {
            return YoumuFeatureEnvironmentStore.shared.temporaryDirectory
        }
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func cleanup(root: URL? = nil) {
        let directory = managedDirectory(root: root)
        guard directory.lastPathComponent == directoryName else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
