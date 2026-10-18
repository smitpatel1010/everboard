import EverboardCore
import SwiftUI
import WebKit

/// Embedded web page (e.g. a Jira dashboard). Cookies persist, so you sign in once.
struct WebPanelView: View {
    private var model: AppModel { .shared }
    let panel: WebPanel
    @State private var web = WebHolder()

    var body: some View {
        WebViewRepresentable(url: SafeURL.web(panel.url), holder: web)
            .navigationTitle(panel.name)
            .toolbar {
                ToolbarItemGroup {
                    Button { web.view?.goBack() } label: { Image(systemName: "chevron.left") }.help("Back")
                    Button { web.view?.reload() } label: { Image(systemName: "arrow.clockwise.circle") }.help("Reload page")
                    Button { model.open(web.view?.url?.absoluteString ?? panel.url) } label: { Image(systemName: "safari") }
                        .help("Open in browser")
                }
            }
    }
}

@MainActor
final class WebHolder { var view: WKWebView? }

struct WebViewRepresentable: NSViewRepresentable {
    let url: URL?
    let holder: WebHolder

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        holder.view = view
        if let url { view.load(URLRequest(url: url)) }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
