import Foundation

extension UserDefaults {
    private static let customFiltersKey = "chat_custom_filters"
    private static let chatFilterMapKey = "chat_filter_map"
    static let maxCustomFilters = 8

    func loadCustomFilters() -> [ChatFilter] {
        guard let data = data(forKey: UserDefaults.customFiltersKey),
              let filters = try? JSONDecoder().decode([ChatFilter].self, from: data) else {
            return []
        }
        return filters
    }

    func saveCustomFilters(_ filters: [ChatFilter]) {
        if let data = try? JSONEncoder().encode(filters) {
            set(data, forKey: UserDefaults.customFiltersKey)
        }
    }

    func loadChatFilterMap() -> [Int: [UUID]] {
        guard let data = data(forKey: UserDefaults.chatFilterMapKey),
              let stringDict = try? JSONDecoder().decode([String: [UUID]].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: stringDict.compactMap { key, value -> (Int, [UUID])? in
            guard let intKey = Int(key) else { return nil }
            return (intKey, value)
        })
    }

    func saveChatFilterMap(_ map: [Int: [UUID]]) {
        let stringDict = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stringDict) {
            set(data, forKey: UserDefaults.chatFilterMapKey)
        }
    }

    func assignChat(_ chatId: Int, toFilter filterId: UUID) {
        var map = loadChatFilterMap()
        map[chatId] = [filterId]
        saveChatFilterMap(map)
    }

    func removeChatFromFilter(_ chatId: Int) {
        var map = loadChatFilterMap()
        map.removeValue(forKey: chatId)
        saveChatFilterMap(map)
    }

    func filterIds(for chatId: Int) -> [UUID] {
        return loadChatFilterMap()[chatId] ?? []
    }

    func chatIds(for filterId: UUID) -> [Int] {
        return loadChatFilterMap().compactMap { chatId, filterIds in
            filterIds.contains(filterId) ? chatId : nil
        }
    }

    /// Removes all chat assignments for a deleted filter.
    func removeFilterAssignments(for filterId: UUID) {
        var map = loadChatFilterMap()
        for (chatId, filterIds) in map {
            let updated = filterIds.filter { $0 != filterId }
            if updated.isEmpty {
                map.removeValue(forKey: chatId)
            } else {
                map[chatId] = updated
            }
        }
        saveChatFilterMap(map)
    }
}
