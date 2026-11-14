import Foundation

/// Local selection is separate from the server's status; disabling restores the server view.
public struct EGLocalEmojiStatus: Codable, Equatable {
    public enum Kind: String, Codable {
        case original
        case hidden
        case emoji
    }

    public let kind: Kind
    public let fileId: Int64?
    public let expirationDate: Int32?

    public init(kind: Kind, fileId: Int64? = nil, expirationDate: Int32? = nil) {
        self.kind = kind
        self.fileId = fileId
        self.expirationDate = expirationDate
    }

    public static let original = EGLocalEmojiStatus(kind: .original)
    public static let hidden = EGLocalEmojiStatus(kind: .hidden)

    /// Imported malformed/expired selections behave like no local override.
    public func effective(at timestamp: Int32) -> EGLocalEmojiStatus {
        switch self.kind {
        case .original:
            return .original
        case .hidden:
            return .hidden
        case .emoji:
            guard let fileId = self.fileId, fileId != 0 else {
                return .original
            }
            if let expirationDate = self.expirationDate, expirationDate <= timestamp {
                return .original
            }
            return self
        }
    }
}
