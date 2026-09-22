import LinkPresentation
import QuotaModel
import SwiftUI
import UIKit

// MARK: - A card as an image

/// The Mac's `ShareableCard`: the card on black, padded, and a footer that
/// signs it — the app icon and the name on the left, the address on the
/// right. The same frame, so an image from the phone and one from the Mac
/// look like the same app's.
struct ShareableCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 14) {
            content
            HStack(spacing: 8) {
                BrandIcon(size: 20)
                Text("QuotaBar")
                    .font(.wordmark(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Text("quota.bar")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: 380)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
enum CardImage {
    /// The card as it is on screen, frozen at this moment, at 3× — sharp in
    /// a chat and on a Retina screen alike. The account is never on the
    /// card, so there is nothing to mask.
    static func render(_ item: MergedReadings.Item, money: CloudMoney, status: ServiceStatus?) -> UIImage? {
        let renderer = ImageRenderer(content: ShareableCard {
            ProviderCard(item: item, money: money, status: status, still: .now)
        })
        renderer.scale = 3
        return renderer.uiImage
    }

    static func copy(_ image: UIImage) {
        UIPasteboard.general.image = image
        #if DEBUG
        // The last copy on disk too, so a simulator run can be checked
        // without pasting it somewhere.
        if let data = image.pngData(), let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: folder.appendingPathComponent("last-copied-card.png"))
        }
        #endif
    }

    /// The system share sheet, from whatever is in front — the list or the
    /// detail page.
    static func share(_ image: UIImage, title: String) {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController
        else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [SharedCard(image: image, title: title)], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}

/// The image with a title and its own thumbnail at the top of the share
/// sheet; a bare `UIImage` gets a blank placeholder there.
private final class SharedCard: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { image }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}

// MARK: - The menu

/// What a long press on a card offers, and the detail page's share button:
/// copy the card as an image, or share it.
struct CardShareActions: View {
    let item: MergedReadings.Item
    let model: ReadingsModel
    let notice: Binding<String?>

    var body: some View {
        Button {
            guard let image = image else { return }
            CardImage.copy(image)
            flash(L10n.t("Image copied", "已复制图片"))
        } label: {
            Label(L10n.t("Copy as Image", "复制为图片"), systemImage: "doc.on.doc")
        }
        Button {
            guard let image = image else { return }
            CardImage.share(image, title: L10n.t("\(item.provider.displayName) limits", "\(item.provider.displayName) 额度"))
        } label: {
            Label(L10n.t("Share Image…", "分享图片…"), systemImage: "square.and.arrow.up")
        }
    }

    private var image: UIImage? {
        CardImage.render(item, money: model.readings.money, status: model.status[item.provider])
    }

    private func flash(_ text: String) {
        notice.wrappedValue = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if notice.wrappedValue == text { notice.wrappedValue = nil }
        }
    }
}

/// The Mac's transient pill: a word that something happened, for a moment.
struct NoticePill: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
