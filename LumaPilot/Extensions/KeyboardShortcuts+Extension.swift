//  Copyright © LumaPilot.

import Cocoa
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let brightnessUp = Self("brightnessUp")
  static let brightnessDown = Self("brightnessDown")
  static let contrastUp = Self("contrastUp")
  static let contrastDown = Self("contrastDown")
  static let volumeUp = Self("volumeUp")
  static let volumeDown = Self("volumeDown")
  static let mute = Self("mute")
  static let displayOff = Self("displayOff")
  static let displayOn = Self("displayOn")
  static let toggleDisplay1 = Self("toggleDisplay1", default: .init(.one, modifiers: [.option]))
  static let toggleDisplay2 = Self("toggleDisplay2", default: .init(.two, modifiers: [.option]))
  static let toggleDisplay3 = Self("toggleDisplay3", default: .init(.three, modifiers: [.option]))
  static let toggleDisplay4 = Self("toggleDisplay4", default: .init(.four, modifiers: [.option]))
  static let toggleDisplay5 = Self("toggleDisplay5", default: .init(.five, modifiers: [.option]))
  static let toggleDisplay6 = Self("toggleDisplay6", default: .init(.six, modifiers: [.option]))
  static let toggleDisplay7 = Self("toggleDisplay7", default: .init(.seven, modifiers: [.option]))
  static let toggleDisplay8 = Self("toggleDisplay8", default: .init(.eight, modifiers: [.option]))
  static let toggleDisplay9 = Self("toggleDisplay9", default: .init(.nine, modifiers: [.option]))
  static let toggleDisplay10 = Self("toggleDisplay10", default: .init(.zero, modifiers: [.option]))

  static let displayToggleShortcuts: [Self] = [
    .toggleDisplay1,
    .toggleDisplay2,
    .toggleDisplay3,
    .toggleDisplay4,
    .toggleDisplay5,
    .toggleDisplay6,
    .toggleDisplay7,
    .toggleDisplay8,
    .toggleDisplay9,
    .toggleDisplay10
  ]

  static let none = Self("none")
}
