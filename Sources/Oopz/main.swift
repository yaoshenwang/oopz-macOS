import AppKit
import SwiftUI

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(SmokeTest.isHeadless() ? .accessory : .regular)
app.run()
