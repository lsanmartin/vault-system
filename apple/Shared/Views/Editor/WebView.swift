import SwiftUI
@preconcurrency import WebKit

class WebViewModel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var lastLoadedHTML: String? = nil
    var onNavigate: ((URL) -> Void)? = nil
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "consoleLog", let logStr = message.body as? String {
            Telemetry.shared.log("WebView", eventType: "JSConsole", message: logStr)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            onNavigate?(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

struct WebView: NSViewRepresentable {
    let htmlContent: String
    let baseURL: URL?
    @Binding var triggerSearch: Bool
    var onNavigate: ((URL) -> Void)? = nil
    
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
        config.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        if context.coordinator.lastLoadedHTML != htmlContent {
            context.coordinator.lastLoadedHTML = htmlContent
            nsView.loadHTMLString(htmlContent, baseURL: baseURL)
        }
        
        if triggerSearch {
            DispatchQueue.main.async {
                triggerSearch = false
                let action = NSSelectorFromString("performFindPanelAction:")
                if nsView.responds(to: action) {
                    nsView.window?.makeFirstResponder(nsView)
                    let item = NSMenuItem(title: "Find", action: action, keyEquivalent: "f")
                    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                    NSApp.sendAction(action, to: nsView, from: item)
                } else {
                    print("WebView no soporta performFindPanelAction nativamente en AppKit")
                }
            }
        }
    }
}
