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
        webView?.reload()
    }

    func clearPage(propagateChange: Bool = true) {
        urlText = ""
        pageTitle = ""
        canGoBack = false
        canGoForward = false
        isLoading = false
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

        guard let url = normalizedURL(from: trimmed) else { return }

        let normalized = url.absoluteString
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
        URL(string: normalizedURLString(from: rawValue))
    }

    private func normalizedURLString(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains("://") {
            return trimmed
        }

        if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
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
}

extension BrowserViewModel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            isLoading = true
            syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            isLoading = false
            syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            isLoading = false
            syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            isLoading = false
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

            ZStack(alignment: .topTrailing) {
                BrowserWebView(model: browser)
                    .background(FXColors.bg)

                if browser.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(FXSpacing.md)
                }
            }
        }
        .background(FXColors.bg)
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
                toolbarButton("arrow.clockwise", label: "Reload page", enabled: true, action: browser.reload)
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
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? FXColors.fgSecondary : FXColors.fgTertiary.opacity(0.45))
                .frame(width: 24, height: 24)
                .background(enabled ? FXColors.bgSurface.opacity(0.6) : FXColors.bgSurface.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.xs))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
