import Foundation

public enum TranscriptPreference {
    public static func english(
        live: [TranscriptSegment],
        reviewed: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let live = live.filter(\.isFinal)
        let reviewed = reviewed.filter(\.isFinal)
        guard !reviewed.isEmpty else { return live }
        guard !live.isEmpty else { return reviewed }
        let liveCharacters = characterCount(live)
        let reviewedCharacters = characterCount(reviewed)
        let liveCoverage = coverage(live)
        let reviewedCoverage = coverage(reviewed)
        let enoughText = reviewedCharacters >= max(120, Int(Double(liveCharacters) * 0.45))
        let enoughCoverage = reviewedCoverage >= max(30, liveCoverage * 0.80)
        return enoughText && enoughCoverage ? reviewed : live
    }

    public static func chinese(
        live: [TranscriptSegment],
        corrected: [TranscriptSegment],
        preferredEnglish: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let live = live.filter(\.isFinal)
        let corrected = corrected.filter(\.isFinal)
        guard !corrected.isEmpty else { return live }
        let preferredSourceIDs = Set(preferredEnglish.map(\.id))
        let matching = corrected.filter { segment in
            segment.sourceSegmentID.map(preferredSourceIDs.contains) == true
        }
        let correctedSourceIDs = Set(matching.compactMap(\.sourceSegmentID))
        let coversPreferredEnglish = preferredSourceIDs.isSubset(of: correctedSourceIDs)
        return matching.count == corrected.count && coversPreferredEnglish ? corrected : live
    }

    public static func characterCount(_ segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    }

    public static func coverage(_ segments: [TranscriptSegment]) -> TimeInterval {
        let finalized = segments.filter(\.isFinal)
        guard let start = finalized.map(\.startTime).min(), let end = finalized.map(\.endTime).max() else { return 0 }
        return max(0, end - start)
    }
}
