import AppKit
import SwiftUI

struct ShortcutGuideEntry: Identifiable, Equatable {
  enum SourceKind: Equatable {
    case current(index: Int, item: ShortcutItem)
  }

  let kind: SourceKind

  var id: String {
    switch kind {
    case .current(_, let item): return item.id
    }
  }

  var index: Int {
    switch kind {
    case .current(let index, _): return index
    }
  }

  var shortcutItem: ShortcutItem? {
    if case .current(_, let item) = kind { return item }
    return nil
  }

  var title: String {
    switch kind {
    case .current(_, let item): return item.name
    }
  }

  var hotkeyText: String {
    switch kind {
    case .current(_, let item): return item.displayHotkey
    }
  }

  var category: String {
    switch kind {
    case .current(_, let item): return shortcutGuideCategory(for: item)
    }
  }

  var source: String {
    switch kind {
    case .current(_, let item): return shortcutGuideSource(for: item)
    }
  }

  var statusText: String {
    switch kind {
    case .current(_, let item): return item.enabled ? "启用" : "停用"
    }
  }

  var description: String {
    switch kind {
    case .current(_, let item):
      let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
      return note.isEmpty ? shortcutHumanDescription(item) : note
    }
  }

  var actionTitle: String {
    switch kind {
    case .current(_, let item): return item.action.title
    }
  }

  var scopeText: String {
    switch kind {
    case .current(_, let item): return item.scope.isEmpty ? "未设置" : item.scope
    }
  }

  var targetText: String {
    switch kind {
    case .current(_, let item): return item.target
    }
  }

  func matches(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return true }
    return [
      title,
      scopeText,
      hotkeyText,
      actionTitle,
      targetText,
      description,
      category,
      source,
      statusText,
    ].contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
  }
}

func shortcutGuideCategoryIcon(_ category: String) -> String {
  switch category {
  case "全部": return "square.grid.2x2"
  case "软件类": return "app.badge"
  case "窗口类": return "rectangle.on.rectangle"
  case "截图类": return "camera.viewfinder"
  case "PDF类": return "doc.richtext"
  case "系统级": return "gearshape.2"
  case "其他类": return "command"
  default: return "command"
  }
}

func shortcutGuideCategoryTint(_ category: String) -> Color {
  switch category {
  case "全部": return accent
  case "软件类": return accent
  case "窗口类": return teal
  case "截图类": return amber
  case "PDF类": return accent
  case "系统级": return indigo
  case "其他类": return muted
  default: return muted
  }
}

func shortcutGuideCategoryPreview(_ category: String) -> String {
  switch category {
  case "全部": return "Caps / ⌘"
  case "软件类": return "Caps E"
  case "窗口类": return "Caps ◀"
  case "截图类": return "Caps + 1"
  case "PDF类": return "⌥ [ / ]"
  case "系统级": return "Caps ⌘ X"
  case "其他类": return "Caps B"
  default: return "Caps"
  }
}
