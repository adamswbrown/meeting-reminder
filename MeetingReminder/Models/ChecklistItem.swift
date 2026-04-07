import Foundation

struct ChecklistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isChecked: Bool

    init(id: UUID = UUID(), text: String, isChecked: Bool = false) {
        self.id = id
        self.text = text
        self.isChecked = isChecked
    }

    /// Default checklist items for new users
    static let defaults: [ChecklistItem] = [
        ChecklistItem(text: "Close unnecessary tabs"),
        ChecklistItem(text: "Get water/coffee"),
        ChecklistItem(text: "Open meeting notes"),
        ChecklistItem(text: "Review agenda"),
        ChecklistItem(text: "Check action items from last meeting"),
    ]

    // MARK: - Persistence

    static func load() -> [ChecklistItem] {
        guard let data = UserDefaults.standard.data(forKey: "defaultChecklist"),
              let items = try? JSONDecoder().decode([ChecklistItem].self, from: data) else {
            return defaults
        }
        return items
    }

    static func save(_ items: [ChecklistItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "defaultChecklist")
        }
    }
}
