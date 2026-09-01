import Foundation

public enum SecretRedactor {
    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"sk-[A-Za-z0-9_-]{8,}"#),
        try! NSRegularExpression(pattern: #"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s\"']+"#),
        try! NSRegularExpression(pattern: #"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#),
        try! NSRegularExpression(pattern: #"(?i)(api[_-]?key\s*[=:]\s*)[^\s&]+"#),
        try! NSRegularExpression(pattern: #"(?i)(\\?\"api[_-]?key\\?\"\s*:\s*\\?\")[^\"]+(\\?\")"#),
        try! NSRegularExpression(pattern: #"(?i)(DEEPSEEK_API_KEY\s*=\s*)[^\s&]+"#),
        try! NSRegularExpression(pattern: #"(?i)((?:OPENAI|OPENROUTER|AI)_API_KEY\s*=\s*)[^\s&]+"#),
        try! NSRegularExpression(pattern: #"(?i)([?&]token=)[^&\s]+"#),
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let template = pattern.numberOfCaptureGroups > 1 ? "$1[REDACTED]$2" : "$1[REDACTED]"
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
