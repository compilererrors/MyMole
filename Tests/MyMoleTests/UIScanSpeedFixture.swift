import Foundation
import Observation
import StorageKit
import SwiftUI

@MainActor @Observable final class UIScanSpeedPreferences {
    let defaults: UserDefaults
    var value: Int {
        didSet { defaults.set(value, forKey: PerformanceLevel.defaultsKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        value = PerformanceLevel.current(in: defaults).rawValue
    }

    var binding: Binding<Int> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
