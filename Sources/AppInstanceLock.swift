import Foundation
import Darwin

// Login startup and a Dock click can race. Hold one process-lifetime lock
// before creating any model, microphone, window or transcript writer.
final class AppInstanceLock {
    private var descriptor: Int32 = -1
    let acquired: Bool

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            acquired = true
        } else {
            let error = errno
            close(fd)
            guard error == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
            acquired = false
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
