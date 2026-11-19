import SwiftUI

extension Color {
    static let brand = Color(red: 241 / 255, green: 101 / 255, blue: 34 / 255)       // #F16522
    static let brandYellow = Color(red: 1, green: 202 / 255, blue: 5 / 255)          // #FFCA05
}

extension LinearGradient {
    static let brand = LinearGradient(colors: [.brand, .brandYellow], startPoint: .leading, endPoint: .trailing)
}

/// Renders product descriptions (HTML with headings/lists) as native text.
@MainActor
func htmlAttributed(_ html: String) -> AttributedString? {
    let css = "<style>body{font-family:-apple-system;font-size:15px} h1,h2,h3,h4{font-size:17px}</style>"
    guard let data = (css + html).data(using: .utf8),
          let ns = try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    else { return nil }
    // HTML import hardcodes black text; use the dynamic label color so dark mode works.
    ns.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: ns.length))
    while ns.string.hasSuffix("\n") { ns.deleteCharacters(in: NSRange(location: ns.length - 1, length: 1)) }
    return try? AttributedString(ns, including: \.uiKit)
}

struct DiscountBadge: View {
    let percent: Int
    var body: some View {
        Text("-\(percent)%")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.brand, in: Capsule())
            .foregroundStyle(.white)
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Algo salió mal", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Reintentar", action: retry).buttonStyle(.borderedProminent)
        }
    }
}
