import Foundation
import IsoCore

package enum ProjectDirectory {
  package static func resolve(_ directory: String?) throws -> String {
    let path = directory ?? FileManager.default.currentDirectoryPath
    guard let canonical = canonicalPath(path) else {
      let reason = String(cString: strerror(errno))
      throw ContextError("Failed to resolve project directory \(path)", cause: HostError(reason))
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw HostError("Project directory is not a directory: \(canonical)") }
    return canonical
  }
}
