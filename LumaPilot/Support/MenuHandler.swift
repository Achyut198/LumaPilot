//  Copyright © LumaPilot.

import AppKit
import os.log

private class ResolutionMenuItemPayload: NSObject {
  let displayID: CGDirectDisplayID
  let ioDisplayModeID: Int32

  init(displayID: CGDirectDisplayID, ioDisplayModeID: Int32) {
    self.displayID = displayID
    self.ioDisplayModeID = ioDisplayModeID
  }
}

class MenuHandler: NSMenu, NSMenuDelegate {
  var combinedSliderHandler: [Command: SliderHandler] = [:]
  var displayToggleSwitches: [CGDirectDisplayID: NSControl] = [:]

  var lastMenuRelevantDisplayId: CGDirectDisplayID = 0

  func clearMenu() {
    var items: [NSMenuItem] = []
    for i in 0 ..< self.items.count {
      items.append(self.items[i])
    }
    for item in items {
      self.removeItem(item)
    }
    self.combinedSliderHandler.removeAll()
    self.displayToggleSwitches.removeAll()
  }

  func menuWillOpen(_: NSMenu) {
    self.updateMenuRelevantDisplay()
    app.keyboardShortcuts.disengage()
  }

  func closeMenu() {
    self.cancelTrackingWithoutAnimation()
  }

  func updateMenus(dontClose: Bool = false) {
    os_log("Menu update initiated", type: .info)
    if !dontClose {
      self.cancelTrackingWithoutAnimation()
    }
    let menuIconPref = prefs.integer(forKey: PrefKey.menuIcon.rawValue)
    var showIcon = false
    if menuIconPref == MenuIcon.show.rawValue {
      showIcon = true
    } else if menuIconPref == MenuIcon.externalOnly.rawValue {
      let externalDisplays = DisplayManager.shared.displays.filter {
        CGDisplayIsBuiltin($0.identifier) == 0
      }
      if externalDisplays.count > 0 {
        showIcon = true
      }
    }
    app.updateStatusItemVisibility(showIcon)
    self.clearMenu()
    let currentDisplay = DisplayManager.shared.getCurrentDisplay()
    var displays: [Display] = []
    if !prefs.bool(forKey: PrefKey.hideAppleFromMenu.rawValue) {
      displays.append(contentsOf: DisplayManager.shared.getAppleDisplays())
    }
    displays.append(contentsOf: DisplayManager.shared.getOtherDisplays())
    displays = DisplayManager.shared.sortDisplaysByFriendlyName()
    let relevant = prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.relevant.rawValue
    let combine = prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue
    let numOfDisplays = displays.filter { !$0.isDummy }.count
    if numOfDisplays != 0 {
      let asSubMenu: Bool = (displays.count > 3 && !relevant && !combine && app.macOS10()) ? true : false
      var iterator = 0
      let safeCurrentDisplayID = currentDisplay?.identifier ?? displays.first?.identifier ?? 0
      for display in displays where (!relevant || DisplayManager.resolveEffectiveDisplayID(display.identifier) == DisplayManager.resolveEffectiveDisplayID(safeCurrentDisplayID)) && !display.isDummy {
        iterator += 1
        if !relevant, !combine, iterator != 1, app.macOS10() {
          self.insertItem(NSMenuItem.separator(), at: 0)
        }
        self.updateDisplayMenu(display: display, asSubMenu: asSubMenu, numOfDisplays: numOfDisplays)
      }
      if combine {
        self.addCombinedDisplayMenuBlock()
      }
    }
    self.addDefaultMenuOptions()
  }

  func addSliderItem(monitorSubMenu: NSMenu, sliderHandler: SliderHandler) {
    let item = NSMenuItem()
    item.view = sliderHandler.view
    monitorSubMenu.insertItem(item, at: 0)
    if app.macOS10() {
      let sliderHeaderItem = NSMenuItem()
      let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemGray, .font: NSFont.systemFont(ofSize: 12)]
      sliderHeaderItem.attributedTitle = NSAttributedString(string: sliderHandler.title, attributes: attrs)
      monitorSubMenu.insertItem(sliderHeaderItem, at: 0)
    }
  }

  func setupMenuSliderHandler(command: Command, display: Display, title: String) -> SliderHandler {
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue, let combinedHandler = self.combinedSliderHandler[command] {
      combinedHandler.addDisplay(display)
      display.sliderHandler[command] = combinedHandler
      return combinedHandler
    } else {
      let sliderHandler = SliderHandler(display: display, command: command, title: title)
      if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue {
        self.combinedSliderHandler[command] = sliderHandler
      }
      display.sliderHandler[command] = sliderHandler
      return sliderHandler
    }
  }

  func addDisplayMenuBlock(display: Display, addedSliderHandlers: [SliderHandler], blockName: String, monitorSubMenu: NSMenu, numOfDisplays: Int, asSubMenu: Bool) {
    if numOfDisplays > 1, prefs.integer(forKey: PrefKey.multiSliders.rawValue) != MultiSliders.relevant.rawValue, !DEBUG_MACOS10, #available(macOS 11.0, *) {
      class BlockView: NSView {
        override func draw(_: NSRect) {
          let radius = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? CGFloat(4) : CGFloat(11)
          let outerMargin = CGFloat(15)
          let blockRect = self.frame.insetBy(dx: outerMargin, dy: outerMargin / 2 + 2).offsetBy(dx: 0, dy: outerMargin / 2 * -1 + 7)
          for i in 1 ... 5 {
            let blockPath = NSBezierPath(roundedRect: blockRect.insetBy(dx: CGFloat(i) * -1, dy: CGFloat(i) * -1), xRadius: radius + CGFloat(i) * 0.5, yRadius: radius + CGFloat(i) * 0.5)
            NSColor(calibratedRed: 0.0, green: 0.14, blue: 0.21, alpha: 0.08 / CGFloat(i)).setStroke()
            blockPath.stroke()
          }
          let blockPath = NSBezierPath(roundedRect: blockRect, xRadius: radius, yRadius: radius)
          let fillColor = NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.22, alpha: 0.78)
          fillColor.setFill()
          blockPath.fill()
          NSColor(calibratedRed: 0.34, green: 0.60, blue: 0.92, alpha: 0.55).setStroke()
          blockPath.lineWidth = 1.0
          blockPath.stroke()
        }
      }
      var contentWidth: CGFloat = 0
      var contentHeight: CGFloat = 0
      for addedSliderHandler in addedSliderHandlers {
        contentWidth = max(addedSliderHandler.view!.frame.width, contentWidth)
        contentHeight += addedSliderHandler.view!.frame.height
      }
      let margin = CGFloat(13)
      var blockNameView: NSTextField?
      if blockName != "" {
        contentHeight += 21
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor, .font: NSFont.boldSystemFont(ofSize: 12)]
        blockNameView = NSTextField(labelWithAttributedString: NSAttributedString(string: blockName, attributes: attrs))
        blockNameView?.frame.size.width = contentWidth - margin * 2
        blockNameView?.alphaValue = 0.5
      }
      let itemView = BlockView(frame: NSRect(x: 0, y: 0, width: contentWidth + margin * 2, height: contentHeight + margin * 2))
      var sliderPosition = CGFloat(margin * -1 + 1)
      for addedSliderHandler in addedSliderHandlers {
        addedSliderHandler.view!.setFrameOrigin(NSPoint(x: margin, y: margin + sliderPosition + 13))
        itemView.addSubview(addedSliderHandler.view!)
        sliderPosition += addedSliderHandler.view!.frame.height
      }
      if let blockNameView = blockNameView {
        blockNameView.setFrameOrigin(NSPoint(x: margin + 13, y: contentHeight - 8))
        itemView.addSubview(blockNameView)
      }
      let item = NSMenuItem()
      item.view = itemView
      if addedSliderHandlers.count != 0 {
        monitorSubMenu.insertItem(item, at: 0)
      }
    } else {
      for addedSliderHandler in addedSliderHandlers {
        self.addSliderItem(monitorSubMenu: monitorSubMenu, sliderHandler: addedSliderHandler)
      }
    }
    self.appendMenuHeader(display: display, friendlyName: blockName, monitorSubMenu: monitorSubMenu, asSubMenu: asSubMenu, numOfDisplays: numOfDisplays)
  }

  func addCombinedDisplayMenuBlock() {
    if let sliderHandler = self.combinedSliderHandler[.audioSpeakerVolume] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
    if let sliderHandler = self.combinedSliderHandler[.contrast] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
    if let sliderHandler = self.combinedSliderHandler[.brightness] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
  }

  func updateDisplayMenu(display: Display, asSubMenu: Bool, numOfDisplays: Int) {
    os_log("Addig menu items for display %{public}@", type: .info, "\(display.identifier)")
    let monitorSubMenu: NSMenu = asSubMenu ? NSMenu() : self
    var addedSliderHandlers: [SliderHandler] = []
    display.sliderHandler[.audioSpeakerVolume] = nil
    let shouldShowBuiltInVolumeSlider = (display as? AppleDisplay)?.isBuiltIn() == true && SliderHandler.canControlSystemOutputVolume()
    if !prefs.bool(forKey: PrefKey.hideVolume.rawValue), ((display as? OtherDisplay).map({ !$0.isSw() && !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) }) == true || shouldShowBuiltInVolumeSlider) {
      let title = NSLocalizedString("Volume", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .audioSpeakerVolume, display: display, title: title))
    }
    display.sliderHandler[.contrast] = nil
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw(), !display.readPrefAsBool(key: .unavailableDDC, for: .contrast), prefs.bool(forKey: PrefKey.showContrast.rawValue) {
      let title = NSLocalizedString("Contrast", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .contrast, display: display, title: title))
    }
    display.sliderHandler[.brightness] = nil
    if !display.readPrefAsBool(key: .unavailableDDC, for: .brightness), !prefs.bool(forKey: PrefKey.hideBrightness.rawValue) {
      let title = NSLocalizedString("Brightness", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .brightness, display: display, title: title))
    }
    self.addResolutionMenu(for: display, in: monitorSubMenu)
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) != MultiSliders.combine.rawValue {
      self.addDisplayMenuBlock(display: display, addedSliderHandlers: addedSliderHandlers, blockName: display.readPrefAsString(key: .friendlyName) != "" ? display.readPrefAsString(key: .friendlyName) : display.name, monitorSubMenu: monitorSubMenu, numOfDisplays: numOfDisplays, asSubMenu: asSubMenu)
    }
    if addedSliderHandlers.count > 0, prefs.integer(forKey: PrefKey.menuIcon.rawValue) == MenuIcon.sliderOnly.rawValue {
      app.updateStatusItemVisibility(true)
    }
  }

  private func addResolutionMenu(for display: Display, in monitorSubMenu: NSMenu) {
    let displayID = DisplayManager.resolveEffectiveDisplayID(display.identifier)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let modesRef = CGDisplayCopyAllDisplayModes(displayID, options) else {
      return
    }
    guard let allModes = modesRef as? [CGDisplayMode] else {
      return
    }
    let modes = allModes.filter { $0.isUsableForDesktopGUI() }
    guard modes.count > 1 else {
      return
    }

    var uniqueModesById: [Int32: CGDisplayMode] = [:]
    for mode in modes where uniqueModesById[mode.ioDisplayModeID] == nil {
      uniqueModesById[mode.ioDisplayModeID] = mode
    }
    let uniqueModes = uniqueModesById.values.sorted { lhs, rhs in
      let lhsPixels = lhs.width * lhs.height
      let rhsPixels = rhs.width * rhs.height
      if lhsPixels != rhsPixels {
        return lhsPixels > rhsPixels
      }
      if lhs.width != rhs.width {
        return lhs.width > rhs.width
      }
      if lhs.height != rhs.height {
        return lhs.height > rhs.height
      }
      return lhs.refreshRate > rhs.refreshRate
    }
    guard uniqueModes.count > 1 else {
      return
    }

    let currentModeID = CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID
    let defaultModeID = DisplayManager.shared.defaultDisplayModeID(for: displayID)
    let resolutionMenu = NSMenu()

    let resetResolutionItem = NSMenuItem(
      title: NSLocalizedString("Reset to Default", comment: "Shown in menu"),
      action: #selector(self.displayResolutionResetSelected(_:)),
      keyEquivalent: ""
    )
    resetResolutionItem.target = self
    resetResolutionItem.tag = Int(displayID)
    resetResolutionItem.isEnabled = defaultModeID != nil && currentModeID != defaultModeID
    resolutionMenu.addItem(resetResolutionItem)
    resolutionMenu.addItem(NSMenuItem.separator())

    for mode in uniqueModes {
      let modeItem = NSMenuItem(
        title: self.resolutionMenuTitle(for: mode, isDefault: mode.ioDisplayModeID == defaultModeID),
        action: #selector(self.displayResolutionSelected(_:)),
        keyEquivalent: ""
      )
      modeItem.target = self
      modeItem.representedObject = ResolutionMenuItemPayload(displayID: displayID, ioDisplayModeID: mode.ioDisplayModeID)
      modeItem.state = (mode.ioDisplayModeID == currentModeID) ? .on : .off
      resolutionMenu.addItem(modeItem)
    }

    let resolutionParentItem = NSMenuItem(
      title: NSLocalizedString("Resolution", comment: "Shown in menu"),
      action: nil,
      keyEquivalent: ""
    )
    resolutionParentItem.submenu = resolutionMenu
    monitorSubMenu.insertItem(resolutionParentItem, at: 0)
  }

  private func resolutionMenuTitle(for mode: CGDisplayMode, isDefault: Bool) -> String {
    let refreshRate = mode.refreshRate
    let suffix = isDefault ? " (\(NSLocalizedString("Default", comment: "Shown in menu")))" : ""
    if refreshRate > 1 {
      return "\(mode.width)x\(mode.height) @ \(Int(round(refreshRate)))Hz\(suffix)"
    }
    return "\(mode.width)x\(mode.height)\(suffix)"
  }

  @objc private func displayResolutionSelected(_ sender: NSMenuItem) {
    guard let payload = sender.representedObject as? ResolutionMenuItemPayload else {
      return
    }
    let result = DisplayManager.shared.setDisplayResolution(payload.displayID, ioDisplayModeID: payload.ioDisplayModeID)
    if !result.success {
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Resolution change failed", comment: "Shown in the alert dialog")
      alert.informativeText = result.error ?? NSLocalizedString("Unknown error.", comment: "Shown in the alert dialog")
      alert.runModal()
      return
    }
    self.updateMenus(dontClose: true)
  }

  @objc private func displayResolutionResetSelected(_ sender: NSMenuItem) {
    let displayID = CGDirectDisplayID(sender.tag)
    let result = DisplayManager.shared.resetDisplayResolutionToDefault(displayID)
    if !result.success {
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Resolution reset failed", comment: "Shown in the alert dialog")
      alert.informativeText = result.error ?? NSLocalizedString("Unknown error.", comment: "Shown in the alert dialog")
      alert.runModal()
      return
    }
    self.updateMenus(dontClose: true)
  }

  private func appendMenuHeader(display: Display, friendlyName: String, monitorSubMenu: NSMenu, asSubMenu: Bool, numOfDisplays _: Int) {
    let monitorMenuItem = NSMenuItem()
    if asSubMenu {
      monitorMenuItem.title = "\(friendlyName)"
      monitorMenuItem.submenu = monitorSubMenu
      self.insertItem(monitorMenuItem, at: 0)
      return
    }

    let itemView = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 36))
    itemView.wantsLayer = true
    itemView.layer?.cornerRadius = 10
    itemView.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.18, alpha: 0.90).cgColor
    itemView.layer?.borderColor = NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.54, alpha: 0.62).cgColor
    itemView.layer?.borderWidth = 1

    let iconView = NSImageView(frame: NSRect(x: 14, y: 11, width: 14, height: 14))
    if #available(macOS 11.0, *) {
      iconView.image = NSImage(systemSymbolName: CGDisplayIsBuiltin(display.identifier) != 0 ? "laptopcomputer" : "display", accessibilityDescription: friendlyName)
    } else {
      iconView.image = NSImage(named: NSImage.preferencesGeneralName)
    }
    iconView.contentTintColor = NSColor(calibratedRed: 0.74, green: 0.80, blue: 0.90, alpha: 1)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    itemView.addSubview(iconView)

    let titleField = NSTextField(labelWithString: friendlyName)
    titleField.frame = NSRect(x: 35, y: 9, width: 150, height: 18)
    titleField.font = NSFont.boldSystemFont(ofSize: 12)
    titleField.textColor = NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.97, alpha: 1)
    itemView.addSubview(titleField)

    let displayID = DisplayManager.resolveEffectiveDisplayID(display.identifier)
    let initialState: NSControl.StateValue = DisplayManager.shared.isDisplayActive(displayID) ? .on : .off
    if #available(macOS 10.15, *) {
      let displaySwitch = NSSwitch(frame: NSRect(x: 202, y: 9, width: 32, height: 16))
      displaySwitch.controlSize = .small
      displaySwitch.state = initialState
      displaySwitch.target = self
      displaySwitch.action = #selector(self.displayEnabledToggleChanged(_:))
      displaySwitch.tag = Int(displayID)
      displaySwitch.toolTip = NSLocalizedString("Toggle display connection", comment: "Shown in menu")
      itemView.addSubview(displaySwitch)
      self.displayToggleSwitches[display.identifier] = displaySwitch
    } else {
      let displaySwitch = NSButton(frame: NSRect(x: 204, y: 10, width: 36, height: 14))
      displaySwitch.setButtonType(.switch)
      displaySwitch.title = ""
      displaySwitch.isBordered = false
      displaySwitch.state = initialState
      displaySwitch.target = self
      displaySwitch.action = #selector(self.displayEnabledToggleChanged(_:))
      displaySwitch.tag = Int(displayID)
      displaySwitch.toolTip = NSLocalizedString("Toggle display connection", comment: "Shown in menu")
      itemView.addSubview(displaySwitch)
      self.displayToggleSwitches[display.identifier] = displaySwitch
    }

    monitorMenuItem.view = itemView
    self.insertItem(monitorMenuItem, at: 0)
  }

  @objc private func reconnectDisplayMenuClicked(_ sender: NSMenuItem) {
    let displayID = CGDirectDisplayID(sender.tag)
    let result = DisplayManager.shared.setDisplayEnabled(displayID, enabled: true)
    if !result.success {
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Failed to reconnect display", comment: "Shown in the alert dialog")
      alert.informativeText = result.error ?? NSLocalizedString("Unknown error.", comment: "Shown in the alert dialog")
      alert.runModal()
    }
  }

  private func addDisabledDisplayToggleRow(displayID: CGDirectDisplayID, name: String) {
    let monitorMenuItem = NSMenuItem()
    let itemView = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 36))
    itemView.wantsLayer = true
    itemView.layer?.cornerRadius = 10
    itemView.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.18, alpha: 0.55).cgColor
    itemView.layer?.borderColor = NSColor(calibratedRed: 0.32, green: 0.35, blue: 0.41, alpha: 0.60).cgColor
    itemView.layer?.borderWidth = 1

    let iconView = NSImageView(frame: NSRect(x: 14, y: 11, width: 14, height: 14))
    if #available(macOS 11.0, *) {
      iconView.image = NSImage(systemSymbolName: "display", accessibilityDescription: name)
    } else {
      iconView.image = NSImage(named: NSImage.preferencesGeneralName)
    }
    iconView.contentTintColor = NSColor(calibratedWhite: 0.73, alpha: 0.90)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    itemView.addSubview(iconView)

    let titleField = NSTextField(labelWithString: name)
    titleField.frame = NSRect(x: 35, y: 9, width: 150, height: 18)
    titleField.font = NSFont.boldSystemFont(ofSize: 12)
    titleField.textColor = NSColor(calibratedWhite: 0.80, alpha: 0.95)
    itemView.addSubview(titleField)

    if #available(macOS 10.15, *) {
      let displaySwitch = NSSwitch(frame: NSRect(x: 202, y: 9, width: 32, height: 16))
      displaySwitch.controlSize = .small
      displaySwitch.state = .off
      displaySwitch.target = self
      displaySwitch.action = #selector(self.displayEnabledToggleChanged(_:))
      displaySwitch.tag = Int(displayID)
      displaySwitch.toolTip = NSLocalizedString("Toggle display connection", comment: "Shown in menu")
      itemView.addSubview(displaySwitch)
      self.displayToggleSwitches[displayID] = displaySwitch
    } else {
      let displaySwitch = NSButton(frame: NSRect(x: 204, y: 10, width: 36, height: 14))
      displaySwitch.setButtonType(.switch)
      displaySwitch.title = ""
      displaySwitch.isBordered = false
      displaySwitch.state = .off
      displaySwitch.target = self
      displaySwitch.action = #selector(self.displayEnabledToggleChanged(_:))
      displaySwitch.tag = Int(displayID)
      displaySwitch.toolTip = NSLocalizedString("Toggle display connection", comment: "Shown in menu")
      itemView.addSubview(displaySwitch)
      self.displayToggleSwitches[displayID] = displaySwitch
    }

    monitorMenuItem.view = itemView
    self.insertItem(monitorMenuItem, at: 0)
  }

  private func shouldShowDisableDisplayWarning() -> Bool {
    !prefs.bool(forKey: PrefKey.skipDisableDisplayWarning.rawValue)
  }

  private func showDisableDisplayWarning(for displayName: String) -> Bool {
    guard self.shouldShowDisableDisplayWarning() else {
      return true
    }

    let contentWidth: CGFloat = 304
    let makeParagraphLabel: (String, CGFloat, NSFont) -> NSTextField = { text, height, font in
      let label = NSTextField(wrappingLabelWithString: text)
      label.frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)
      label.preferredMaxLayoutWidth = contentWidth
      label.font = font
      label.textColor = NSColor.labelColor
      label.alignment = .center
      label.lineBreakMode = .byWordWrapping
      return label
    }

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.distribution = .fill
    stack.spacing = 9
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)

    if #available(macOS 10.15, *) {
      let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
      if #available(macOS 11.0, *) {
        iconView.image = NSImage(systemSymbolName: "display.trianglebadge.exclamationmark", accessibilityDescription: "Display warning")
      } else {
        iconView.image = NSImage(named: NSImage.cautionName)
      }
      iconView.imageScaling = .scaleProportionallyUpOrDown
      iconView.contentTintColor = NSColor.systemBlue
      stack.addArrangedSubview(iconView)
    }

    stack.addArrangedSubview(makeParagraphLabel(
      String(format: NSLocalizedString("This should remove \"%@\" from the display layout and make it enter standby mode.", comment: "Shown in the alert dialog"), displayName),
      44,
      NSFont.systemFont(ofSize: 13, weight: .medium)
    ))
    stack.addArrangedSubview(makeParagraphLabel(
      NSLocalizedString("Some displays are not compatible with this feature and may not turn off or remain off.", comment: "Shown in the alert dialog"),
      40,
      NSFont.systemFont(ofSize: 12.5)
    ))
    stack.addArrangedSubview(makeParagraphLabel(
      NSLocalizedString("If you cannot turn the display back on using the app, reconnect it manually. For a MacBook display, close and open the lid.", comment: "Shown in the alert dialog"),
      50,
      NSFont.systemFont(ofSize: 12.5)
    ))

    let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 158))
    stack.frame = accessoryContainer.bounds
    stack.autoresizingMask = [.width, .height]
    accessoryContainer.addSubview(stack)

    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Disconnecting a Display", comment: "Shown in the alert dialog")
    alert.informativeText = ""
    alert.alertStyle = .warning
    alert.accessoryView = accessoryContainer
    alert.addButton(withTitle: NSLocalizedString("Disconnect", comment: "Shown in the alert dialog"))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Shown in the alert dialog"))
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = NSLocalizedString("Don't show this warning again!", comment: "Shown in the alert dialog")
    let response = alert.runModal()
    if alert.suppressionButton?.state == .on {
      prefs.set(true, forKey: PrefKey.skipDisableDisplayWarning.rawValue)
    }
    return response == .alertFirstButtonReturn
  }

  @objc private func displayEnabledToggleChanged(_ sender: NSControl) {
    let displayID = CGDirectDisplayID(sender.tag)
    let shouldEnable = sender.intValue == 1
    let setSenderState: (NSControl.StateValue) -> Void = { newState in
      sender.intValue = (newState == .on) ? 1 : 0
    }

    if !shouldEnable {
      guard DisplayManager.shared.canDisableDisplay(displayID) else {
        setSenderState(.on)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Display cannot be disconnected", comment: "Shown in the alert dialog")
        alert.informativeText = NSLocalizedString("At least one display must stay enabled.", comment: "Shown in the alert dialog")
        alert.runModal()
        return
      }

      let displayName = DisplayManager.shared.knownDisplays[displayID] ?? String(displayID)
      guard self.showDisableDisplayWarning(for: displayName) else {
        setSenderState(.on)
        return
      }
    }

    let result = DisplayManager.shared.setDisplayEnabled(displayID, enabled: shouldEnable)
    if !result.success {
      setSenderState(shouldEnable ? .off : .on)
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Display toggle failed", comment: "Shown in the alert dialog")
      alert.informativeText = result.error ?? NSLocalizedString("Unknown error.", comment: "Shown in the alert dialog")
      alert.runModal()
    } else {
      self.updateMenus(dontClose: true)
    }
  }

  func updateMenuRelevantDisplay() {
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.relevant.rawValue {
      if let display = DisplayManager.shared.getCurrentDisplay(), display.identifier != self.lastMenuRelevantDisplayId {
        os_log("Menu must be refreshed as relevant display changed since last time.")
        self.lastMenuRelevantDisplayId = display.identifier
        self.updateMenus(dontClose: true)
      }
    }
  }

  func addDefaultMenuOptions() {
    let disabledDisplays = DisplayManager.shared.getKnownDisabledDisplays()
    if !disabledDisplays.isEmpty {
      for disabledDisplay in disabledDisplays {
        self.addDisabledDisplayToggleRow(displayID: disabledDisplay.id, name: disabledDisplay.name)
      }
    }

    if !DEBUG_MACOS10, #available(macOS 11.0, *), prefs.integer(forKey: PrefKey.menuItemStyle.rawValue) == MenuItemStyle.icon.rawValue {
      let iconSize = CGFloat(18)
      let viewWidth = max(130, self.size.width)
      var compensateForBlock: CGFloat = 0
      if viewWidth > 230 { // if there are display blocks, we need to compensate a bit for the negative inset of the blocks
        compensateForBlock = 4
      }

      let menuItemView = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: iconSize + 10))

      let settingsIcon = NSButton()
      settingsIcon.bezelStyle = .regularSquare
      settingsIcon.isBordered = false
      settingsIcon.setButtonType(.momentaryChange)
      settingsIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: NSLocalizedString("Settings…", comment: "Shown in menu"))
      settingsIcon.alternateImage = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: NSLocalizedString("Settings…", comment: "Shown in menu"))
      settingsIcon.alphaValue = 0.3
      settingsIcon.frame = NSRect(x: menuItemView.frame.maxX - iconSize * 3 - 20 - 17 + compensateForBlock, y: menuItemView.frame.origin.y + 5, width: iconSize, height: iconSize)
      settingsIcon.imageScaling = .scaleProportionallyUpOrDown
      settingsIcon.action = #selector(app.prefsClicked)

      let updateIcon = NSButton()
      updateIcon.bezelStyle = .regularSquare
      updateIcon.isBordered = false
      updateIcon.setButtonType(.momentaryChange)
      var symbolName = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? "arrow.left.arrow.right.square" : "arrow.triangle.2.circlepath.circle"
      updateIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: NSLocalizedString("Check for updates…", comment: "Shown in menu"))
      updateIcon.alternateImage = NSImage(systemSymbolName: symbolName + ".fill", accessibilityDescription: NSLocalizedString("Check for updates…", comment: "Shown in menu"))

      updateIcon.alphaValue = 0.3
      updateIcon.frame = NSRect(x: menuItemView.frame.maxX - iconSize * 2 - 14 - 17 + compensateForBlock, y: menuItemView.frame.origin.y + 5, width: iconSize, height: iconSize)
      updateIcon.imageScaling = .scaleProportionallyUpOrDown
      updateIcon.action = #selector(app.checkForUpdatesClicked(_:))
      updateIcon.target = app

      let quitIcon = NSButton()
      quitIcon.bezelStyle = .regularSquare
      quitIcon.isBordered = false
      quitIcon.setButtonType(.momentaryChange)
      symbolName = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? "multiply.square" : "xmark.circle"
      quitIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: NSLocalizedString("Quit", comment: "Shown in menu"))
      quitIcon.alternateImage = NSImage(systemSymbolName: symbolName + ".fill", accessibilityDescription: NSLocalizedString("Quit", comment: "Shown in menu"))
      quitIcon.alphaValue = 0.3
      quitIcon.frame = NSRect(x: menuItemView.frame.maxX - iconSize - 17 + compensateForBlock, y: menuItemView.frame.origin.y + 5, width: iconSize, height: iconSize)
      quitIcon.imageScaling = .scaleProportionallyUpOrDown
      quitIcon.action = #selector(app.quitClicked)

      menuItemView.addSubview(settingsIcon)
      menuItemView.addSubview(updateIcon)
      menuItemView.addSubview(quitIcon)
      let item = NSMenuItem()
      item.view = menuItemView
      self.insertItem(item, at: self.items.count)

      self.insertItem(NSMenuItem.separator(), at: self.items.count)
      let quitItem = NSMenuItem(title: NSLocalizedString("Quit LumaPilot", comment: "Shown in menu"), action: #selector(app.quitClicked), keyEquivalent: "q")
      quitItem.target = app
      self.insertItem(quitItem, at: self.items.count)
    } else if prefs.integer(forKey: PrefKey.menuItemStyle.rawValue) != MenuItemStyle.hide.rawValue {
      if app.macOS10() {
        self.insertItem(NSMenuItem.separator(), at: self.items.count)
      }
      self.insertItem(withTitle: NSLocalizedString("Settings…", comment: "Shown in menu"), action: #selector(app.prefsClicked), keyEquivalent: ",", at: self.items.count)
      let updateItem = NSMenuItem(title: NSLocalizedString("Check for updates…", comment: "Shown in menu"), action: #selector(app.checkForUpdatesClicked(_:)), keyEquivalent: "")
      updateItem.target = app
      self.insertItem(updateItem, at: self.items.count)
      self.insertItem(withTitle: NSLocalizedString("Quit", comment: "Shown in menu"), action: #selector(app.quitClicked), keyEquivalent: "q", at: self.items.count)
    }
  }
}
