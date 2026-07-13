import Foundation

struct BookmarkWindow: Equatable, Sendable {
    static let defaultRadius: TimeInterval = 30

    let bookmarkTime: TimeInterval
    let secondsBefore: TimeInterval
    let secondsAfter: TimeInterval

    init(
        bookmarkTime: TimeInterval,
        secondsBefore: TimeInterval = defaultRadius,
        secondsAfter: TimeInterval = defaultRadius
    ) {
        self.bookmarkTime = max(0, bookmarkTime)
        self.secondsBefore = max(0, secondsBefore)
        self.secondsAfter = max(0, secondsAfter)
    }

    var range: ClosedRange<TimeInterval> {
        max(0, bookmarkTime - secondsBefore)...(bookmarkTime + secondsAfter)
    }

    func intersects(
        transcriptStart: TimeInterval,
        transcriptEnd: TimeInterval
    ) -> Bool {
        guard transcriptStart <= transcriptEnd else {
            return false
        }

        return transcriptEnd >= range.lowerBound && transcriptStart <= range.upperBound
    }
}
