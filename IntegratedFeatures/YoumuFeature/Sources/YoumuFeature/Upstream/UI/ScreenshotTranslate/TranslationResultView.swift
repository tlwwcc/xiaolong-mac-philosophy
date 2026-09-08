import SwiftUI

class TranslationResultViewModel: ObservableObject {
    @Published var originalText: String
    @Published var translatedText: String
    @Published var isCopied = false

    init(originalText: String, translatedText: String) {
        self.originalText = originalText
        self.translatedText = translatedText
    }

    func copyTranslation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isCopied = false
        }
    }
}

struct TranslationResultView: View {
    @ObservedObject var viewModel: TranslationResultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.visionAccentSoft)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("翻译结果")
                        .font(.headline)
                    Text("文字可选择，译文可一键复制")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            textCard(
                title: "原文",
                symbol: "doc.text",
                text: viewModel.originalText,
                emphasized: false
            ) {
                Button {
                    SpeechService.shared.toggle(text: viewModel.originalText)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("朗读原文")
            }

            textCard(
                title: "译文",
                symbol: "character.book.closed",
                text: viewModel.translatedText,
                emphasized: true
            ) {
                Button {
                    viewModel.copyTranslation()
                } label: {
                    Label(
                        viewModel.isCopied ? "已复制" : "复制",
                        systemImage: viewModel.isCopied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.visionAccentSoft))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("复制译文")
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func textCard<Actions: View>(
        title: String,
        symbol: String,
        text: String,
        emphasized: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundColor(emphasized ? .accentColor : .secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(emphasized ? .primary : .secondary)
                Spacer()
                actions()
            }

            ScrollView {
                Text(text)
                    .font(.system(size: emphasized ? 14 : 13))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: emphasized ? .infinity : 108)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: VisionDesign.cardRadius, style: .continuous)
                .fill(emphasized ? Color.visionAccentSoft : Color.visionCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VisionDesign.cardRadius, style: .continuous)
                .stroke(emphasized ? Color.accentColor.opacity(0.24) : Color.visionBorder, lineWidth: 1)
        )
    }
}
