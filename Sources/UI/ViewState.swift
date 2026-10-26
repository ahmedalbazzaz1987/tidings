import SwiftUI
import Combine

/// Drop-in replacement for SwiftUI's `@State`.
///
/// On the newest SDKs `@State` is implemented as a compiler macro whose plugin ships
/// only with full Xcode, so a Command-Line-Tools build can't expand it. This wrapper
/// stores the value in a `@StateObject`, which is still a plain property wrapper,
/// and behaves the same way: view-local, survives re-renders, `$value` gives a Binding.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    final class Storage: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var storage: Storage

    init(wrappedValue: Value) {
        _storage = StateObject(wrappedValue: Storage(wrappedValue))
    }

    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let s = storage
        return Binding(get: { s.value }, set: { s.value = $0 })
    }
}
