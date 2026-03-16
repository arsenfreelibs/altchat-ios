import Foundation

enum SystemFilter: String, CaseIterable {
    case all
    case unread
}

struct ChatFilter: Codable, Identifiable {
    let id: UUID
    var name: String

    init(name: String) {
        self.id = UUID()
        self.name = name
    }
}

enum ActiveFilter: Equatable {
    case system(SystemFilter)
    case custom(UUID)
}
