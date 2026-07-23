import SwiftUI
import WebKit
import FXDesign

@MainActor
final class BrowserViewModel: NSObject, ObservableObject {
    @Published var urlText: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    private weak var webView: WKWebView?
    private var attachedWebViewID: ObjectIdentifier?
    private var lastCommittedURLString = ""
    private var pendingURLString: String?
    private var onCommittedURLChange: ((String) -> Void)?

    func setCommittedURLChangeHandler(_ onCommittedURLChange: @escaping (String) -> Void) {
        self.onCommittedURLChange = onCommittedURLChange
    }

    func synchronizeWorkspaceURL(_ workspaceURL: String) {
        let trimmed = workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearPage(propagateChange: false)
            return
        }

        let normalized = normalizedURLString(from: trimmed)
        if urlText != normalized {
            urlText = normalized
        }

        guard let webView else {
            pendingURLString = normalized
            return
        }

        if webView.url?.absoluteString == normalized || lastCommittedURLString == normalized {
            lastCommittedURLString = normalized
            pendingURLString = nil
            return
        }

        load(normalized, propagateChange: false)
    }

    func attach(webView: WKWebView) {
        let webViewID = ObjectIdentifier(webView)
        guard attachedWebViewID != webViewID else { return }

        attachedWebViewID = webViewID
        self.webView = webView
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        if let pendingURLString {
            load(pendingURLString, propagateChange: false)
        } else {
            syncNavigationState()
            synchronizeWorkspaceURL(urlText)
        }
    }

    func loadCurrentInput() {
        load(urlText)
    }

    func reload() {
        errorMessage = nil
        webView?.reload()
    }

    func dismissError() {
        errorMessage = nil
    }

    func clearPage(propagateChange: Bool = true) {
        urlText = ""
        pageTitle = ""
        canGoBack = false
        canGoForward = false
        isLoading = false
        errorMessage = nil
        lastCommittedURLString = ""
        pendingURLString = nil

        if propagateChange {
            onCommittedURLChange?("")
        }

        guard let webView else { return }
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    var hasPage: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !lastCommittedURLString.isEmpty
            || webView?.url != nil
            || isLoading
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    private func load(_ rawValue: String, propagateChange: Bool = true) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearPage(propagateChange: propagateChange)
            return
        }

        guard let url = normalizedURL(from: trimmed) else {
            errorMessage = "Enter a valid HTTP or HTTPS address."
            return
        }

        let normalized = url.absoluteString
        errorMessage = nil
        urlText = normalized
        pendingURLString = normalized

        guard let webView else { return }

        lastCommittedURLString = normalized
        pendingURLString = nil
        if propagateChange {
            onCommittedURLChange?(normalized)
        }
        webView.load(URLRequest(url: url))
    }

    private func normalizedURL(from rawValue: String) -> URL? {
        guard let url = URL(string: normalizedURLString(from: rawValue)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func normalizedURLString(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains("://") {
            return trimmed
        }

        if trimmed.hasPrefix("::1") {
            return "http://[::1]\(trimmed.dropFirst(3))"
        }

        if trimmed.hasPrefix("localhost")
            || trimmed.hasPrefix("127.0.0.1")
            || trimmed.hasPrefix("0.0.0.0")
            || trimmed.hasPrefix("[::1]") {
            return "http://\(trimmed)"
        }

        return "https://\(trimmed)"
    }

    private func syncNavigationState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        pageTitle = webView?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? webView?.title ?? ""
            : ""

        if let currentURL = webView?.url?.absoluteString, !currentURL.isEmpty {
            urlText = currentURL
            if lastCommittedURLString != currentURL {
                lastCommittedURLString = currentURL
                onCommittedURLChange?(currentURL)
            }
        } else if webView?.isLoading != true {
            urlText = ""
            lastCommittedURLString = ""
        }
    }

    private func presentNavigationError(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }

        let detail: String
        switch nsError.code {
        case NSURLErrorCannotConnectToHost:
            detail = "The preview server is not accepting connections."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            detail = "The host could not be found."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            detail = "Check the network connection and try again."
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot:
            detail = "The server certificate could not be verified."
        case NSURLErrorTimedOut:
            detail = "The server took too long to respond."
        default:
            detail = nsError.localizedDescription
        }

        errorMessage = detail
    }
}

extension BrowserViewModel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            errorMessage = nil
            syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            isLoading = false
            errorMessage = nil
            syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            isLoading = false
            presentNavigationError(error)
            syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            isLoading = false
            presentNavigationError(error)
            syncNavigationState()
        }
    }
}

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var model: BrowserViewModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        model.attach(webView: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

struct BrowserPanel: View {
    let agent: AgentInfo

    @StateObject private var browser = BrowserViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            FXDivider()

            if let errorMessage = browser.errorMessage {
                browserErrorBanner(errorMessage)
                FXDivider()
            }

            ZStack(alignment: .topTrailing) {
                BrowserWebView(model: browser)
                    .background(FXColors.panelBg)

                if browser.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(FXSpacing.md)
                }
            }
        }
        .background(FXColors.panelBg)
        .task(id: agent.id) {
            browser.setCommittedURLChangeHandler { [weak agent] committedURL in
                guard let agent, agent.workspace.browserURLString != committedURL else { return }
                agent.workspace.browserURLString = committedURL
            }
            browser.synchronizeWorkspaceURL(agent.workspace.browserURLString)
        }
        .onChange(of: agent.workspace.browserURLString) { _, newValue in
            browser.synchronizeWorkspaceURL(newValue)
        }
    }

    private var toolbar: some View {
        HStack(spacing: FXSpacing.sm) {
            HStack(spacing: FXSpacing.xs) {
                toolbarButton("chevron.left", label: "Go back", enabled: browser.canGoBack, action: browser.goBack)
                toolbarButton("chevron.right", label: "Go forward", enabled: browser.canGoForward, action: browser.goForward)
                toolbarButton("arrow.clockwise", label: "Reload page", enabled: browser.hasPage, action: browser.reload)
            }

            TextField("Enter a URL", text: $browser.urlText)
                .textFieldStyle(.plain)
                .font(FXTypography.mono)
                .foregroundStyle(FXColors.fgSecondary)
                .padding(.horizontal, FXSpacing.sm)
                .padding(.vertical, FXSpacing.xxs)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
                .accessibilityLabel("Browser address")
                .onSubmit(browser.loadCurrentInput)

            toolbarButton("xmark", label: "Clear page", enabled: browser.hasPage) {
                browser.clearPage()
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.bgElevated)
    }

    private func toolbarButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        FXIconButton(icon: icon, label: label, size: 24, action: action)
        .disabled(!enabled)
    }

    private func browserErrorBanner(_ message: String) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.warning)

            Text(message)
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry") {
                browser.loadCurrentInput()
            }
            .buttonStyle(.plain)
            .font(FXTypography.captionMedium)
            .foregroundStyle(FXColors.accent)

            FXIconButton(icon: "xmark", label: "Dismiss browser error", size: 24) {
                browser.dismissError()
            }
        }
        .padding(.horizontal, FXSpacing.md)
        .padding(.vertical, FXSpacing.sm)
        .background(FXColors.warning.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
