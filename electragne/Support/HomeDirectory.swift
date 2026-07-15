import Foundation

nonisolated enum HomeDirectory {
    /// The sandbox reports the container as home; CLI key files live in the
    /// user's account home directory.
    static var realPath: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}
