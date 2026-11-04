// Report this Mac's optional backup setup without creating jobs or uploading data.
import Foundation

enum TranscriptBackupConfiguration {
    static var message: String {
        let job = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.ethansk.hello-chat-transcript-backup.plist")
        guard let data = try? Data(contentsOf: job),
              let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              settings["Label"] as? String == "com.ethansk.hello-chat-transcript-backup" else {
            return "Google Drive backup isn't configured on this Mac."
        }
        return "Google Drive backup is configured on this Mac. Existing backups remain when saving is off."
    }
}
