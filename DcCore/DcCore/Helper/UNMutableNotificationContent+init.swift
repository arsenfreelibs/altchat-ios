import UserNotifications
import UIKit
import Intents

public extension UNMutableNotificationContent {

    /// Returns a communication-style notification (iOS 15+) with the sender's avatar displayed
    /// on the left and the app icon on the bottom-right — matching Android's behaviour.
    /// Falls back to the standard `init?` initialiser on older OS versions.
    @available(iOS 15, iOSApplicationExtension 15, *)
    static func communicationContent(forMessage msg: DcMsg, chat: DcChat, context: DcContext) -> UNNotificationContent? {
        guard let base = UNMutableNotificationContent(forMessage: msg, chat: chat, context: context) else { return nil }
        let contact = context.getContact(id: msg.fromContactId)
        return base.withCommunicationIntent(sender: contact, chat: chat, context: context)
    }

    /// Returns a communication-style notification (iOS 15+) for an incoming reaction.
    @available(iOS 15, iOSApplicationExtension 15, *)
    static func communicationContent(forReaction reaction: String, from contactId: Int, msg: DcMsg, chat: DcChat, context: DcContext) -> UNNotificationContent? {
        guard let base = UNMutableNotificationContent(forReaction: reaction, from: contactId, msg: msg, chat: chat, context: context) else { return nil }
        let contact = context.getContact(id: contactId)
        return base.withCommunicationIntent(sender: contact, chat: chat, context: context)
    }

    /// Returns a communication-style notification (iOS 15+) for an incoming WebXDC notification.
    @available(iOS 15, iOSApplicationExtension 15, *)
    static func communicationContent(forWebxdcNotification notification: String, msg: DcMsg, chat: DcChat, context: DcContext) -> UNNotificationContent? {
        guard let base = UNMutableNotificationContent(forWebxdcNotification: notification, msg: msg, chat: chat, context: context) else { return nil }
        let contact = context.getContact(id: msg.fromContactId)
        return base.withCommunicationIntent(sender: contact, chat: chat, context: context)
    }
}

public extension UNMutableNotificationContent {
    /// The limit for expanded notifications on iOS 14+.
    ///
    /// Note: The notification will be truncated at ~170 characters automatically by the system
    /// but the rest of the characters are visible by long-pressing the notification.
    private static var pushNotificationCharLimit = 250

    /// Initialiser that returns a notification for an incoming message. Returns nil if no notification should be sent (eg if chat is muted)
    convenience init?(forMessage msg: DcMsg, chat: DcChat, context: DcContext) {
        guard msg.id != 0 else { return nil } // invalid message
        guard !context.isMuted() else { return nil }
        guard !chat.isMuted || (chat.isMultiUser && msg.isReplyToSelf && context.isMentionsEnabled) else { return nil }
        self.init()
        let sender = msg.getSenderName(context.getContact(id: msg.fromContactId))
        title = chat.isMultiUser ? chat.name : sender
        body = (chat.isMultiUser ? "\(sender): " : "") + (msg.summary(chars: Self.pushNotificationCharLimit) ?? "")
        userInfo["account_id"] = context.id
        userInfo["chat_id"] = chat.id
        userInfo["message_id"] = msg.id
        threadIdentifier = "\(context.id)-\(chat.id)"
        sound = .default
        setRelevanceScore(for: msg, in: chat, context: context)
    }

    /// Initialiser that returns a notification for an incoming reaction. Returns nil if no notification should be sent (eg if chat is muted)
    convenience init?(forReaction reaction: String, from contact: Int, msg: DcMsg, chat: DcChat, context: DcContext) {
        guard !context.isMuted() else { return nil }
        guard !chat.isMuted || (chat.isMultiUser && context.isMentionsEnabled) else { return nil }
        let contact = context.getContact(id: contact)
        let summary = msg.summary(chars: Self.pushNotificationCharLimit) ?? ""
        self.init()
        title = chat.name
        body = String.localized(stringID: "reaction_by_other", parameter: contact.displayName, reaction, summary)
        userInfo["account_id"] = context.id
        userInfo["chat_id"] = chat.id
        userInfo["message_id"] = msg.id
        threadIdentifier = "\(context.id)-\(chat.id)"
        sound = .default
        setRelevanceScore(for: msg, in: chat, context: context)
    }

    /// Initialiser that returns a notification for an incoming webxdc notification. Returns nil if no notification should be sent (eg if chat is muted)
    convenience init?(forWebxdcNotification notification: String, msg: DcMsg, chat: DcChat, context: DcContext) {
        guard !context.isMuted() else { return nil }
        guard !chat.isMuted || (chat.isMultiUser && context.isMentionsEnabled) else { return nil }
        self.init()
        title = chat.name
        body = msg.getWebxdcAppName() + ": " + notification
        userInfo["account_id"] = context.id
        userInfo["chat_id"] = chat.id
        userInfo["message_id"] = msg.id
        threadIdentifier = "\(context.id)-\(chat.id)"
        sound = .default
        setRelevanceScore(for: msg, in: chat, context: context)
    }

    convenience init?(forIncomingCallMsg msg: DcMsg, chat: DcChat, context: DcContext) {
        guard !context.isMuted(), !chat.isMuted, !canUseCallKit else { return nil }
        self.init()
        let sender = msg.getSenderName(context.getContact(id: msg.fromContactId))
        title = chat.isMultiUser ? chat.name : sender
        body = .localized("incoming_call")
        userInfo["account_id"] = context.id
        userInfo["chat_id"] = chat.id
        userInfo["message_id"] = msg.id
        userInfo["answer_call"] = true
        threadIdentifier = "calls"
        sound = .default // TODO: Ring?
        setRelevanceScore(for: msg, in: chat, context: context)
    }

    convenience init?(forMissedCallMsg msg: DcMsg, chat: DcChat, context: DcContext) {
        guard !context.isMuted(), !chat.isMuted, !canUseCallKit else { return nil }
        self.init()
        let sender = msg.getSenderName(context.getContact(id: msg.fromContactId))
        title = chat.isMultiUser ? chat.name : sender
        body = .localized("missed_call")
        userInfo["account_id"] = context.id
        userInfo["chat_id"] = chat.id
        userInfo["message_id"] = msg.id
        threadIdentifier = "calls"
        sound = .default
        setRelevanceScore(for: msg, in: chat, context: context)
    }
}

private extension UNMutableNotificationContent {

    /// Renders a circular gradient image with the contact's initials — matching the `InitialsBadge` style.
    @available(iOS 15, iOSApplicationExtension 15, *)
    static func makeInitialsImage(name: String, color: UIColor, size: CGFloat = 160) -> UIImage? {
        let initials = DcUtils.getInitials(inputName: name)
        guard !initials.isEmpty else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let cgCtx = ctx.cgContext
            cgCtx.addEllipse(in: rect)
            cgCtx.clip()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let cgColors = [color.lightened(by: 0.25).cgColor, color.darkened(by: 0.2).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: [0, 1]) {
                cgCtx.drawLinearGradient(gradient,
                                        start: CGPoint(x: 0, y: 0),
                                        end: CGPoint(x: size, y: size),
                                        options: [])
            }
            let font = UIFont.systemFont(ofSize: size * 0.40, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let textSize = initials.size(withAttributes: attrs)
            let textRect = CGRect(x: (size - textSize.width) / 2,
                                  y: (size - textSize.height) / 2,
                                  width: textSize.width,
                                  height: textSize.height)
            initials.draw(in: textRect, withAttributes: attrs)
        }
    }

    /// Wraps the receiver in an `INSendMessageIntent` interaction so iOS renders
    /// the notification with the sender's avatar (Communication Notifications, iOS 15+).
    @available(iOS 15, iOSApplicationExtension 15, *)
    func withCommunicationIntent(sender contact: DcContact, chat: DcChat, context: DcContext) -> UNNotificationContent {
        // Build the sender handle and avatar image (real photo or generated initials circle)
        let handle = INPersonHandle(value: contact.email, type: .emailAddress)
        let avatar: INImage?
        // Use imageData (not URL) — notification UI runs in a separate process
        // that has no access to the app's private sandbox file URLs.
        if let url = contact.profileImageURL {
            if let data = try? Data(contentsOf: url) {
                avatar = INImage(imageData: data)
            } else {
                #if DEBUG
                logger.info("🖼️NOTIF photo file missing: \(url.lastPathComponent)")
                #endif
                avatar = UNMutableNotificationContent.makeInitialsImage(name: contact.displayName, color: contact.color)
                    .flatMap { $0.pngData() }.map { INImage(imageData: $0) }
            }
        } else if let img = UNMutableNotificationContent.makeInitialsImage(name: contact.displayName, color: contact.color),
                  let data = img.pngData() {
            avatar = INImage(imageData: data)
        } else {
            avatar = nil
        }
        let inSender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: contact.displayName,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: "\(context.id).\(contact.id)"
        )

        // Build the intent
        let groupName: INSpeakableString? = chat.isMultiUser ? INSpeakableString(spokenPhrase: chat.name) : nil
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: groupName,
            conversationIdentifier: threadIdentifier,
            serviceName: nil,
            sender: inSender,
            attachments: nil
        )

        // For group chats attach the group avatar so it shows under the sender avatar
        if chat.isMultiUser, let imageData = chat.profileImage?.pngData() {
            intent.setImage(INImage(imageData: imageData), forParameterNamed: \.speakableGroupName)
        }

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil) // enables Focus filters, Siri suggestions, notification summary

        // INSendMessageIntent conforms to UNNotificationContentProviding (iOS 15+).
        // Cast via as? because DcCore deployment target is iOS 14.
        guard let provider = intent as? UNNotificationContentProviding else { return self }
        do {
            return try updating(from: provider)
        } catch {
            #if DEBUG
            logger.info("🖼️NOTIF updating ERR \(error.localizedDescription)")
            #endif
            return self
        }
    }
}

extension UNMutableNotificationContent {
    fileprivate func setRelevanceScore(for msg: DcMsg, in chat: DcChat, context: DcContext) {
        guard #available(iOS 15, *) else { return }
        relevanceScore = switch true {
        case _ where chat.visibility == DC_CHAT_VISIBILITY_PINNED: 0.9
        case _ where chat.isMultiUser && context.isMentionsEnabled && msg.isReplyToSelf: 0.8
        case _ where chat.isMuted: 0.0
        case _ where chat.isMultiUser: 0.3
        default: 0.5
        }
    }
}
