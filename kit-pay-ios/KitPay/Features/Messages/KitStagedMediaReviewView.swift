import SwiftUI

/// The final review uses the same durable composer and send identity as an ordinary chat.
/// Editing/removing an item never publishes it; only the explicit Send action queues the batch.
struct KitStagedMediaReviewView: View {
    let recipientName: String
    let attachments: [ChatStagedAttachment]
    @Binding var caption: String
    let canSend: Bool
    let isBusy: Bool
    let onOpen: (ChatStagedAttachment) -> Void
    let onEdit: (ChatStagedAttachment) -> Void
    let onRemove: (UUID) -> Void
    let onClose: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review before sending").font(.headline)
                    Text("To \(recipientName)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Return to chat with draft")
            }
            .padding(.horizontal).padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(attachments) { attachment in
                        attachmentCard(attachment)
                    }
                    TextField("Add a message…", text: $caption, axis: .vertical)
                        .lineLimit(2...6)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Message or media caption")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(isBusy)

            Button(action: onSend) {
                HStack(spacing: 10) {
                    if isBusy { ProgressView().tint(.white) }
                    else { Image(systemName: "paperplane.fill") }
                    Text("Send").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .foregroundStyle(.white)
                .background(KitColor.green, in: Capsule())
            }
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.55)
            .accessibilityLabel("Send to \(recipientName)")
            .padding()
        }
        .background(KitColor.canvas.ignoresSafeArea())
    }

    private func attachmentCard(_ attachment: ChatStagedAttachment) -> some View {
        VStack(spacing: 0) {
            Button { onOpen(attachment) } label: {
                ZStack {
                    KitColor.paleGreen.opacity(0.35)
                    if let preview = attachment.previewImage {
                        Image(uiImage: preview).resizable().scaledToFit()
                    } else {
                        Image(systemName: attachment.kind.symbolName)
                            .font(.system(size: 48)).foregroundStyle(KitColor.green)
                    }
                    if attachment.kind == .video, !attachment.isPreparing {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 42)).foregroundStyle(.white, .black.opacity(0.5))
                    }
                    if attachment.isPreparing { ProgressView() }
                }
                .frame(height: attachment.kind == .document ? 110 : 220)
                .clipped()
            }
            .buttonStyle(.plain)
            .disabled(attachment.isPreparing)
            .accessibilityLabel("Preview \(attachment.displayName)")

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(attachment.needsVideoTrim ? "Trim this video to send it" : attachment.byteLabel)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { onRemove(attachment.id) } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Remove \(attachment.displayName)")
                }
                if let editLabel = attachment.editLabel {
                    Button { onEdit(attachment) } label: {
                        Label(editLabel, systemImage: attachment.editSymbol)
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(attachment.isPreparing)
                }
            }
            .padding(12)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
