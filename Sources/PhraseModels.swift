import Foundation

struct PhraseItem: Codable, Equatable, Identifiable {
  var id: String
  var trigger: String
  var output: String
  var enabled: Bool
  var note: String

  var normalizedTrigger: String {
    trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

func defaultPhrases() -> [PhraseItem] {
  [
    PhraseItem(
      id: UUID().uuidString,
      trigger: "ppqd",
      output: "https://qoder.com.cn/referral?referral_code=6mpxrWtpt1apoEHrGvd0LHbwGK80uYQH",
      enabled: true,
      note: "Qoder 推荐注册链接。"
    ),
    PhraseItem(
      id: UUID().uuidString,
      trigger: "ppdb",
      output: "https://shurufa.doubao.com/pc",
      enabled: true,
      note: "豆包输入法官网。"
    ),
    PhraseItem(
      id: UUID().uuidString,
      trigger: "ppyy",
      output: "https://uuyc.163.com/",
      enabled: true,
      note: "UU 远程官网。"
    ),
    PhraseItem(
      id: UUID().uuidString,
      trigger: "ppvs",
      output: "https://aixlg.com/vs/",
      enabled: true,
      note: "游目产品页。"
    ),
    PhraseItem(
      id: UUID().uuidString,
      trigger: "ppxlg",
      output: "https://aixlg.com/hotkeys.html",
      enabled: true,
      note: "小龙哥 Mac 快捷键教程。"
    ),
  ]
}
