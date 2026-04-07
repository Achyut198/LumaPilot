//  Copyright © LumaPilot.

import AppKit
import os.log

class MenuHandler: NSMenu, NSMenuDelegate {
  var combinedSliderHandler: [Command: SliderHandler] = [:]
  var displayToggleSwitches: [CGDirectDisplayID: NSSwitch] = [:]

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
      for display in displays where (!relevant || DisplayManager.resolveEffectiveDisplayID(display.identifier) == DisplayManager.resolveEffectiveDisplayID(currentDisplay!.identifier)) && !display.isDummy {
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
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw(), !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume), !prefs.bool(forKey: PrefKey.hideVolume.rawValue) {
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
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) != MultiSliders.combine.rawValue {
      self.addDisplayMenuBlock(display: display, addedSliderHandlers: addedSliderHandlers, blockName: display.readPrefAsString(key: .friendlyName) != "" ? display.readPrefAsString(key: .friendlyName) : display.name, monitorSubMenu: monitorSubMenu, numOfDisplays: numOfDisplays, asSubMenu: asSubMenu)
    }
    if addedSliderHandlers.count > 0, prefs.integer(forKey: PrefKey.menuIcon.rawValue) == MenuIcon.sliderOnly.rawValue {
      app.updateStatusItemVisibility(true)
    }
  }

  private func appendMenuHeader(display: Display, friendlyName: String, monitorSubMenu: NSMenu, asSubMenu: Bool, numOfDisplays _: Int) {
    let monitorMenuItem = NSMenuItem()
    if asSubMenu {
      monitorMenuItem.title = "\(friendlyName)"
      monitorMenuItem.submenu = monitorSubMenu
      self.insertItem(monitorMenuItem, at: 0)
      return
    }

    let itemView = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 34))
    itemView.wantsLayer = true
    itemView.layer?.cornerRadius = 9
    itemView.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.33, alpha: 0.72).cgColor
    itemView.layer?.borderColor = NSColor(calibratedRed: 0.28, green: 0.66, blue: 0.99, alpha: 0.65).cgColor
    itemView.layer?.borderWidth = 1

    let iconView = NSImageView(frame: NSRect(x: 14, y: 10, width: 14, height: 14))
    iconView.image = NSImage(systemSymbolName: CGDisplayIsBuiltin(display.identifier) != 0 ? "laptopcomputer" : "display", accessibilityDescription: friendlyName)
    iconView.contentTintColor = NSColor(calibratedRed: 0.73, green: 0.93, blue: 1.00, alpha: 1)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    itemView.addSubview(iconView)

    let titleField = NSTextField(labelWithString: friendlyName)
    titleField.frame = NSRect(x: 35, y: 8, width: 150, height: 18)
    titleField.font = NSFont.boldSystemFont(ofSize: 12)
    titleField.textColor = NSColor(calibratedRed: 0.88, green: 0.96, blue: 1.00, alpha: 1)
    itemView.addSubview(titleField)

    let displaySwitch = NSSwitch(frame: NSRect(x: 194, y: 6, width: 50, height: 22))
    displaySwitch.state = DisplayManager.shared.isDisplayActive(display.identifier) ? .on : .off
    displaySwitch.target = self
    displaySwitch.action = #selector(self.displayEnabledToggleChanged(_:))
    displaySwitch.tag = Int(display.identifier)
    displaySwitch.toolTip = NSLocalizedString("Toggle display connection", comment: "Shown in menu")
    itemView.addSubview(displaySwitch)
    self.displayToggleSwitches[display.identifier] = displaySwitch

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

  private func shouldShowDisableDisplayWarning() -> Bool {
    !prefs.bool(forKey: PrefKey.skipDisableDisplayWarning.rawValue)
  }

  private func showDisableDisplayWarning(for displayName: String) -> Bool {
    guard self.shouldShowDisableDisplayWarning() else {
      return true
    }
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Disconnect display?", comment: "Shown in the alert dialog")
    alert.informativeText = String(format: NSLocalizedString("This will disconnect \"%@\" from the active display layout. Use the menu action to reconnect it later.", comment: "Shown in the alert dialog"), displayName)
    alert.alertStyle = .warning
    alert.addButton(withTitle: NSLocalizedString("Disconnect", comment: "Shown in the alert dialog"))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Shown in the alert dialog"))
    alert.showsSuppressionButton = true
    let response = alert.runModal()
    if alert.suppressionButton?.state == .on {
      prefs.set(true, forKey: PrefKey.skipDisableDisplayWarning.rawValue)
    }
    return response == .alertFirstButtonReturn
  }

  @objc private func displayEnabledToggleChanged(_ sender: NSSwitch) {
    let displayID = CGDirectDisplayID(sender.tag)
    let shouldEnable = sender.state == .on

    if !shouldEnable {
      guard DisplayManager.shared.canDisableDisplay(displayID) else {
        sender.state = .on
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Display cannot be disconnected", comment: "Shown in the alert dialog")
        alert.informativeText = NSLocalizedString("At least one display must stay enabled.", comment: "Shown in the alert dialog")
        alert.runModal()
        return
      }

      let displayName = DisplayManager.shared.knownDisplays[displayID] ?? String(displayID)
      guard self.showDisableDisplayWarning(for: displayName) else {
        sender.state = .on
        return
      }
    }

    let result = DisplayManager.shared.setDisplayEnabled(displayID, enabled: shouldEnable)
    if !result.success {
      sender.state = shouldEnable ? .off : .on
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Display toggle failed", comment: "Shown in the alert dialog")
      alert.informativeText = result.error ?? NSLocalizedString("Unknown error.", comment: "Shown in the alert dialog")
      alert.runModal()
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
      if app.macOS10() {
        self.insertItem(NSMenuItem.separator(), at: self.items.count)
      }
      for disabledDisplay in disabledDisplays {
        let reconnectTitle = String(format: NSLocalizedString("Reconnect %@", comment: "Shown in menu"), disabledDisplay.name)
        let reconnectItem = NSMenuItem(title: reconnectTitle, action: #selector(self.reconnectDisplayMenuClicked(_:)), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.tag = Int(disabledDisplay.id)
        self.insertItem(reconnectItem, at: self.items.count)
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
      updateIcon.action = #selector(app.updaterController.checkForUpdates(_:))
      updateIcon.target = app.updaterController

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
    } else if prefs.integer(forKey: PrefKey.menuItemStyle.rawValue) != MenuItemStyle.hide.rawValue {
      if app.macOS10() {
        self.insertItem(NSMenuItem.separator(), at: self.items.count)
      }
      self.insertItem(withTitle: NSLocalizedString("Settings…", comment: "Shown in menu"), action: #selector(app.prefsClicked), keyEquivalent: ",", at: self.items.count)
      let updateItem = NSMenuItem(title: NSLocalizedString("Check for updates…", comment: "Shown in menu"), action: #selector(app.updaterController.checkForUpdates(_:)), keyEquivalent: "")
      updateItem.target = app.updaterController
      self.insertItem(updateItem, at: self.items.count)
      self.insertItem(withTitle: NSLocalizedString("Quit", comment: "Shown in menu"), action: #selector(app.quitClicked), keyEquivalent: "q", at: self.items.count)
    }
  }
}
