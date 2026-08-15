import SwiftUI
@preconcurrency import WebKit

class WebViewModel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var lastLoadedHTML: String? = nil
    var onNavigate: ((URL) -> Void)? = nil
    var onCheckboxToggled: ((Int) -> Void)? = nil
    var isCheckboxToggleUpdate: Bool = false
    
    var lastFindNext: Bool = false
    var lastFindPrev: Bool = false
    var lastClearSearch: Bool = false
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "consoleLog", let logStr = message.body as? String {
            Telemetry.shared.log("WebView", eventType: "JSConsole", message: logStr)
        }
        if message.name == "toggleCheckbox",
           let body = message.body as? [String: Any],
           let index = body["index"] as? Int {
            isCheckboxToggleUpdate = true
            onCheckboxToggled?(index)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if let fragment = url.fragment, !fragment.isEmpty {
                let targetId = fragment.removingPercentEncoding ?? fragment
                let escapedTarget = targetId.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let js = ##"""
                (function() {
                    var target = "\##(escapedTarget)";
                    var el = document.getElementById(target) || document.getElementsByName(target)[0];
                    if (!el) {
                        var headings = document.querySelectorAll("h1, h2, h3, h4, h5, h6, [id]");
                        for (var i = 0; i < headings.length; i++) {
                            var h = headings[i];
                            var id = h.id || h.innerText.toLowerCase().replace(/[^a-z0-9áéíóúñü\s-]/g, "").trim().replace(/\s+/g, "-");
                            if (id === target || h.innerText.trim() === target) {
                                el = h;
                                break;
                            }
                        }
                    }
                    if (el) {
                        el.scrollIntoView({ behavior: "smooth" });
                    }
                })();
                """##
                webView.evaluateJavaScript(js, completionHandler: nil)
                decisionHandler(.cancel)
                return
            }
            onNavigate?(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

struct WebView: View {
    let htmlContent: String
    let baseURL: URL?
    @Binding var triggerSearch: Bool
    var onNavigate: ((URL) -> Void)? = nil
    var onCheckboxToggled: ((Int) -> Void)? = nil
    
    @State private var showSearchPanel: Bool = false
    @State private var searchQuery: String = ""
    @State private var findNextTrigger: Bool = false
    @State private var findPrevTrigger: Bool = false
    @State private var clearSearchTrigger: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebViewRepresentable(
                htmlContent: htmlContent,
                baseURL: baseURL,
                searchQuery: searchQuery,
                findNextTrigger: $findNextTrigger,
                findPrevTrigger: $findPrevTrigger,
                clearSearchTrigger: $clearSearchTrigger,
                onNavigate: onNavigate,
                onCheckboxToggled: onCheckboxToggled
            )
            .onChange(of: triggerSearch) { _, newValue in
                if newValue {
                    showSearchPanel = true
                    triggerSearch = false
                }
            }
            
            if showSearchPanel {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    
                    TextField("Buscar en página...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 150)
                        .onSubmit { findNextTrigger.toggle() }
                        .onChange(of: searchQuery) { _, _ in findNextTrigger.toggle() }
                    
                    Divider().frame(height: 16)
                    
                    Button(action: { findPrevTrigger.toggle() }) {
                        Image(systemName: "chevron.up")
                    }.buttonStyle(.plain)
                    
                    Button(action: { findNextTrigger.toggle() }) {
                        Image(systemName: "chevron.down")
                    }.buttonStyle(.plain)
                    
                    Divider().frame(height: 16)
                    
                    Button(action: { 
                        showSearchPanel = false
                        searchQuery = ""
                        clearSearchTrigger.toggle()
                    }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                )
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: showSearchPanel)
            }
        }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let htmlContent: String
    let baseURL: URL?
    let searchQuery: String
    @Binding var findNextTrigger: Bool
    @Binding var findPrevTrigger: Bool
    @Binding var clearSearchTrigger: Bool
    var onNavigate: ((URL) -> Void)? = nil
    var onCheckboxToggled: ((Int) -> Void)? = nil
    
    func makeCoordinator() -> WebViewModel { WebViewModel() }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        let consoleScript = """
            var originalLog = console.log;
            console.log = function(m) { window.webkit.messageHandlers.consoleLog.postMessage("LOG: " + m); originalLog(m); };
            window.onerror = function(m, s, l) { window.webkit.messageHandlers.consoleLog.postMessage("ERR: " + m + " at " + l); };
        """
        userContentController.addUserScript(WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContentController.add(context.coordinator, name: "consoleLog")
        userContentController.add(context.coordinator, name: "toggleCheckbox")
        config.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onCheckboxToggled = onCheckboxToggled
        if context.coordinator.isCheckboxToggleUpdate {
            context.coordinator.isCheckboxToggleUpdate = false
            context.coordinator.lastLoadedHTML = htmlContent
        } else if context.coordinator.lastLoadedHTML != htmlContent {
            context.coordinator.lastLoadedHTML = htmlContent
            nsView.loadHTMLString(htmlContent, baseURL: baseURL)
        }
        
        if findNextTrigger != context.coordinator.lastFindNext {
            context.coordinator.lastFindNext = findNextTrigger
            let config = WKFindConfiguration()
            config.backwards = false
            config.wraps = true
            Task {
                try? await nsView.find(searchQuery, configuration: config)
            }
        }
        
        if findPrevTrigger != context.coordinator.lastFindPrev {
            context.coordinator.lastFindPrev = findPrevTrigger
            let config = WKFindConfiguration()
            config.backwards = true
            config.wraps = true
            Task {
                try? await nsView.find(searchQuery, configuration: config)
            }
        }
        
        if clearSearchTrigger != context.coordinator.lastClearSearch {
            context.coordinator.lastClearSearch = clearSearchTrigger
            Task {
                try? await nsView.find("", configuration: WKFindConfiguration())
            }
        }
    }
}
