import SwiftUI
import WebKit

class WebViewModel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "consoleLog", let logStr = message.body as? String {
            Telemetry.shared.log("WebView", eventType: "JSConsole", message: logStr)
        }
    }
}

struct WebView: NSViewRepresentable {
    let htmlContent: String
    
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
        nsView.loadHTMLString(htmlContent, baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }
}
