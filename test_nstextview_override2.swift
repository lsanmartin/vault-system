import AppKit

class MyTextView: NSTextView {
    var textView._customSelectedRanges: [NSValue]? = nil
    
    override var selectedRanges: [NSValue] {
        get {
            return textView._customSelectedRanges ?? super.selectedRanges
        }
        set {
            print("Property setter called with \(newValue.count) ranges")
            let hasMultipleEmpty = newValue.filter { $0.rangeValue.length == 0 }.count > 1
            if hasMultipleEmpty {
                textView._customSelectedRanges = newValue
                super.selectedRanges = [newValue.first!]
            } else {
                textView._customSelectedRanges = nil
                super.selectedRanges = newValue
            }
        }
    }
    
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        print("setSelectedRanges method called with \(ranges.count) ranges")
        let hasMultipleEmpty = ranges.filter { $0.rangeValue.length == 0 }.count > 1
        if hasMultipleEmpty {
            textView._customSelectedRanges = ranges
            super.setSelectedRanges([ranges.first!], affinity: affinity, stillSelecting: stillSelecting)
        } else {
            textView._customSelectedRanges = nil
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
    }
}

let textView = MyTextView()
textView.string = "hello world\nthis is a test\n"
let r1 = NSRange(location: 2, length: 0)
let r2 = NSRange(location: 10, length: 0)

textView.selectedRanges = [NSValue(range: r1), NSValue(range: r2)]
print("After setting length=0: \(textView._customSelectedRanges != nil ? "custom exists" : "custom wiped")")
