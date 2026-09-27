import SwiftUI

public enum FXLayout {
    public static let readableContentWidth: CGFloat = 760
    public static let userMessageMaxWidth: CGFloat = 600
    public static let userAttachmentThumbnailWidth: CGFloat = 176
    public static let userAttachmentAspectRatio: CGFloat = 1.6
    public static let userAttachmentThumbnailHeight: CGFloat =
        userAttachmentThumbnailWidth / userAttachmentAspectRatio
    public static let collapsedUserMessageHeight: CGFloat = 176
    public static let imagePreviewMinimumWidth: CGFloat = 720
    public static let imagePreviewMinimumHeight: CGFloat = 520
    public static let minimumConversationWidth: CGFloat = 460
    public static let minimumBrowserPreviewWidth: CGFloat = 320
    public static let splitPanelResizeHandleWidth: CGFloat = 12
    public static let minimumTerminalHeight: CGFloat = 120
    public static let maximumTerminalHeight: CGFloat = 500
    public static let diffNavigatorWidth: CGFloat = 248
    public static let diffNavigatorSideBySideWidth: CGFloat = 720
    public static let diffNavigatorCompactHeight: CGFloat = 200
    public static let modalWidth: CGFloat = 440
}
