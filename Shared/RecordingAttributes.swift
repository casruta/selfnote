import ActivityKit
import Foundation

struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {}

    let noteID: UUID
    let startedAt: Date
}
