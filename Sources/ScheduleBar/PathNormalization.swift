import Foundation

enum PathNormalization {
    static func normalize(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        var path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
