import Foundation

enum Retention {
    static func sanitize(_ text: String) -> String {
        var result = text
        let patterns = [
            #"sk-[A-Za-z0-9_-]{8,}"#,
            #"xai-[A-Za-z0-9_-]{8,}"#,
            #"gsk_[A-Za-z0-9_-]{8,}"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#,
            #"(?i)(api[_-]?key)["'\s:=]+[A-Za-z0-9_-]{8,}"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted]")
            }
        }
        return result
    }

    static func sanitize(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = sanitize(text)
        return cleaned
    }
}
