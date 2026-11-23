import SwiftUI

extension Binding where Value == Int {
    // A formatted TextField can submit the current number again during a view update.
    // Forward only a real edit so Settings doesn't queue repeated Spotify volume checks.
    func changes(in range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { wrappedValue }, set: { proposed in
            let next = Swift.min(range.upperBound, Swift.max(range.lowerBound, proposed))
            guard next != wrappedValue else { return }
            wrappedValue = next
        })
    }
}
