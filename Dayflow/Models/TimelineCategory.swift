import Foundation
import SwiftUI

struct TimelineCategory: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    var details: String
    var order: Int
    var isSystem: Bool
    var isIdle: Bool
    var isNew: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        details: String = "",
        order: Int,
        isSystem: Bool = false,
        isIdle: Bool = false,
        isNew: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.details = details
        self.order = order
        self.isSystem = isSystem
        self.isIdle = isIdle
        self.isNew = isNew
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct LLMCategoryDescriptor: Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let description: String?
    let isSystem: Bool
    let isIdle: Bool
}

@MainActor
final class CategoryStore: ObservableObject {
    enum StoreKeys {
        static let categories = "colorCategories"
        static let hasUsedApp = "hasUsedApp"
    }

    @Published private(set) var categories: [TimelineCategory] = []

    init() {
        load()
    }

    var editableCategories: [TimelineCategory] {
        categories.filter { !$0.isSystem }.sorted { $0.order < $1.order }
    }

    var idleCategory: TimelineCategory? {
        categories.first(where: { $0.isIdle })
    }

    func addCategory(name: String, colorHex: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (categories.map { $0.order }.max() ?? -1) + 1
        let now = Date()
        let category = TimelineCategory(
            name: trimmed,
            colorHex: colorHex ?? "#E5E7EB",
            details: "",
            order: nextOrder,
            isSystem: false,
            isIdle: false,
            isNew: true,
            createdAt: now,
            updatedAt: now
        )
        categories.append(category)
        save()

        if UserDefaults.standard.bool(forKey: StoreKeys.hasUsedApp) == false {
            UserDefaults.standard.set(true, forKey: StoreKeys.hasUsedApp)
        }
    }

    func updateCategory(id: UUID, mutate: (inout TimelineCategory) -> Void) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        var category = categories[idx]
        mutate(&category)
        category.updatedAt = Date()
        category.isNew = false
        categories[idx] = category
        save()
    }

    func assignColor(_ hex: String, to id: UUID) {
        updateCategory(id: id) { cat in
            cat.colorHex = hex
        }
    }

    func updateDetails(_ details: String, for id: UUID) {
        updateCategory(id: id) { cat in
            cat.details = details
        }
    }

    func renameCategory(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateCategory(id: id) { cat in
            cat.name = trimmed
        }
    }

    func removeCategory(id: UUID) {
        guard let category = categories.first(where: { $0.id == id }) else { return }
        guard category.isSystem == false else { return }
        categories.removeAll { $0.id == id }
        save()
    }

    func reorderCategories(_ idsInOrder: [UUID]) {
        var newCategories: [TimelineCategory] = []
        var order = 0
        for id in idsInOrder {
            guard let idx = categories.firstIndex(where: { $0.id == id }) else { continue }
            var cat = categories[idx]
            cat.order = order
            cat.updatedAt = Date()
            newCategories.append(cat)
            order += 1
        }
        let untouched = categories.filter { idsInOrder.contains($0.id) == false }
        categories = (newCategories + untouched).sorted { $0.order < $1.order }
        save()
    }

    func persist() {
        save()
    }

    func snapshotForLLM() -> [LLMCategoryDescriptor] {
        categories
            .sorted { $0.order < $1.order }
            .map { cat in
                LLMCategoryDescriptor(
                    id: cat.id,
                    name: cat.name,
                    description: catDescription(cat),
                    isSystem: cat.isSystem,
                    isIdle: cat.isIdle
                )
            }
    }

    private func catDescription(_ category: TimelineCategory) -> String? {
        if category.isIdle {
            return "Mark sessions where the user is idle for more than half of the time."
        }
        let trimmed = category.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func load() {
        let decoded = CategoryPersistence.loadPersistedCategories()
        if decoded.isEmpty {
            categories = CategoryPersistence.defaultCategories
        } else {
            categories = CategoryPersistence.ensureIdleCategoryPresent(in: decoded)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(categories) {
            UserDefaults.standard.set(data, forKey: StoreKeys.categories)
        }
    }

}

extension CategoryStore {
    nonisolated static func descriptorsForLLM() -> [LLMCategoryDescriptor] {
        let categories = CategoryPersistence.loadPersistedCategories()
        let effective = categories.isEmpty ? CategoryPersistence.defaultCategories : categories
        return effective
            .sorted { $0.order < $1.order }
            .map { category in
                LLMCategoryDescriptor(
                    id: category.id,
                    name: category.name,
                    description: {
                        if category.isIdle {
                            return "Use when the user is idle for more than half of this period."
                        }
                        let trimmed = category.details.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }(),
                    isSystem: category.isSystem,
                    isIdle: category.isIdle
                )
            }
    }
}

private extension CategoryStore {
    static func ensureIdleCategoryPresent(in categories: [TimelineCategory]) -> [TimelineCategory] {
        CategoryPersistence.ensureIdleCategoryPresent(in: categories)
    }
}

enum CategoryPersistence {
    static func loadPersistedCategories() -> [TimelineCategory] {
        guard let data = UserDefaults.standard.data(forKey: CategoryStore.StoreKeys.categories) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let categories = try? decoder.decode([TimelineCategory].self, from: data) {
            return ensureIdleCategoryPresent(in: categories)
        }
        struct LegacyColorCategory: Codable {
            let id: Int64
            var name: String
            var color: String?
            var details: String
            var isNew: Bool?
        }
        if let legacy = try? decoder.decode([LegacyColorCategory].self, from: data) {
            var order = 0
            let converted = legacy.map { item -> TimelineCategory in
                defer { order += 1 }
                return TimelineCategory(
                    id: UUID(),
                    name: item.name,
                    colorHex: item.color ?? "#E5E7EB",
                    details: item.details,
                    order: order,
                    isSystem: false,
                    isIdle: false,
                    isNew: item.isNew ?? false
                )
            }
            return ensureIdleCategoryPresent(in: converted)
        }
        return []
    }

    static var defaultCategories: [TimelineCategory] {
        let now = Date()
        let base: [(String, String, Bool, Bool, String)] = [
            (
                "Work",
                "#B984FF",
                false,
                false,
                "Professional, school, or career-focused tasks (coding, design, meetings, research)."
            ),
            (
                "Personal",
                "#6AADFF",
                false,
                false,
                "Intentional non-work activities for life, wellbeing, hobbies, or personal errands."
            ),
            (
                "Distraction",
                "#FF5950",
                false,
                false,
                "Unplanned, aimless, or compulsive time sinks (social media, doomscrolling, non-work videos, rabbit holes)."
            ),
            (
                "Idle",
                "#A0AEC0",
                true,
                true,
                "Mark sessions where the user is idle for most of the time."
            )
        ]
        return base.enumerated().map { idx, entry in
            TimelineCategory(
                name: entry.0,
                colorHex: entry.1,
                details: entry.4,
                order: idx,
                isSystem: entry.2,
                isIdle: entry.3,
                isNew: false,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    static func ensureIdleCategoryPresent(in categories: [TimelineCategory]) -> [TimelineCategory] {
        if categories.contains(where: { $0.isIdle }) {
            return categories.sorted { $0.order < $1.order }
        }

        var updated = categories
        let order = (categories.map { $0.order }.max() ?? -1) + 1
        let now = Date()
        let idle = TimelineCategory(
            name: "Idle",
            colorHex: "#A0AEC0",
            details: "Mark sessions where the user is idle for most of the time.",
            order: order,
            isSystem: true,
            isIdle: true,
            isNew: false,
            createdAt: now,
            updatedAt: now
        )
        updated.append(idle)
        return updated.sorted { $0.order < $1.order }
    }
}
