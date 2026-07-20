import AppKit

class MyTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        print("mouseDown with modifiers: \(event.modifierFlags)")
        if event.modifierFlags.contains(.command) {
            print("Cmd + Click detected in mouseDown")
        }
        super.mouseDown(with: event)
    }
}

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
let tv = MyTextView(frame: window.contentView!.bounds)
tv.string = "Click here with Cmd"
window.contentView?.addSubview(tv)
window.makeKeyAndOrderFront(nil)

// Run the app briefly (this would need manual clicking to test, which we can't easily do remotely without a UI script)
