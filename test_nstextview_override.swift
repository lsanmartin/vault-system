import AppKit

class MyTextView: NSTextView {
    private var _customSelectedRanges: [NSValue]? = nil
    
    override var selectedRanges: [NSValue] {
        get {
            return _customSelectedRanges ?? super.selectedRanges
        }
        set {
            let hasMultipleEmpty = newValue.filter { $0.rangeValue.length == 0 }.count > 1
            if hasMultipleEmpty {
                _customSelectedRanges = newValue
                super.selectedRanges = [newValue.first!]
            } else {
                _customSelectedRanges = nil
                super.selectedRanges = newValue
            }
        }
    }
}

let textView = MyTextView()
textView.string = "hello world\nthis is a test\n"
let r1 = NSRange(location: 2, length: 0)
let r2 = NSRange(location: 10, length: 0)

textView.selectedRanges = [NSValue(range: r1), NSValue(range: r2)]
print("After setting length=0: \(textView.selectedRanges.map { $0.rangeValue })")

let r3 = NSRange(location: 2, length: 2)
let r4 = NSRange(location: 10, length: 2)
textView.selectedRanges = [NSValue(range: r3), NSValue(range: r4)]
print("After setting length=2: \(textView.selectedRanges.map { $0.rangeValue })")
