//  Copyright © LumaPilot.

import Cocoa
import CoreGraphics
import Darwin
import os.log

class DisplayManager {
  public static let shared = DisplayManager()
  typealias CGSConfigureDisplayEnabledFunction = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32

  var displays: [Display] = []
  private let knownDisplaysPrefKey = "KnownDisplays"

  /// A persisted reference to a display we have seen before. We keep the stable hardware
  /// identity (vendor/model/serial) alongside the transient `CGDirectDisplayID` so that a
  /// display can still be recognised after macOS reassigns its ID (sleep/wake, reconnect,
  /// GPU switch, disable→enable), instead of being mistaken for a disconnected display.
  struct KnownDisplay {
    var name: String
    var vendorNumber: UInt32
    var modelNumber: UInt32
    var serialNumber: UInt32
    var isBuiltin: Bool = false

    /// Stable key that survives `CGDirectDisplayID` reassignment.
    var identityKey: String { "\(self.vendorNumber):\(self.modelNumber):\(self.serialNumber)" }

    /// Whether this display exposes enough hardware info to be matched across ID changes.
    /// Displays that report all-zero identity (some virtual/dummy/EDID-less panels) can only
    /// be tracked by their transient ID.
    var hasStableIdentity: Bool { self.vendorNumber != 0 || self.modelNumber != 0 || self.serialNumber != 0 }

    /// A reference is only meaningful if it has a real name. Transient/invalid display IDs that
    /// appear briefly during reconfiguration report an empty name (and garbage identity); such
    /// phantom references must never be stored or shown as a disconnected display.
    var isValid: Bool { !self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  var knownDisplays: [CGDirectDisplayID: KnownDisplay] = [:] {
    didSet {
      var dictToSave: [String: [String: Any]] = [:]
      for (key, value) in self.knownDisplays where value.isValid {
        dictToSave[String(key)] = [
          "name": value.name,
          "vendorNumber": value.vendorNumber,
          "modelNumber": value.modelNumber,
          "serialNumber": value.serialNumber,
          "isBuiltin": value.isBuiltin,
        ]
      }
      prefs.set(dictToSave, forKey: self.knownDisplaysPrefKey)
    }
  }

  func loadKnownDisplays() {
    guard let saved = prefs.dictionary(forKey: self.knownDisplaysPrefKey) else {
      return
    }
    var restored: [CGDirectDisplayID: KnownDisplay] = [:]
    for (key, value) in saved {
      guard let id = CGDirectDisplayID(key) else {
        continue
      }
      if let dict = value as? [String: Any] {
        // Current storage format with full hardware identity.
        let entry = KnownDisplay(
          name: dict["name"] as? String ?? "",
          vendorNumber: (dict["vendorNumber"] as? NSNumber)?.uint32Value ?? 0,
          modelNumber: (dict["modelNumber"] as? NSNumber)?.uint32Value ?? 0,
          serialNumber: (dict["serialNumber"] as? NSNumber)?.uint32Value ?? 0,
          isBuiltin: (dict["isBuiltin"] as? NSNumber)?.boolValue ?? false
        )
        // Drop phantom/invalid references (e.g. empty-name transients) instead of restoring them.
        if entry.isValid {
          restored[id] = entry
        }
      } else if let name = value as? String, !name.isEmpty {
        // Legacy storage format (id → name). Migrate; identity resolves next time it comes online.
        restored[id] = KnownDisplay(name: name, vendorNumber: 0, modelNumber: 0, serialNumber: 0)
      }
    }
    self.knownDisplays = restored
  }

  /// Builds a `KnownDisplay` reference for a currently-attached display ID.
  static func makeKnownDisplay(displayID: CGDirectDisplayID) -> KnownDisplay {
    KnownDisplay(
      name: DisplayManager.getDisplayNameByID(displayID: displayID),
      vendorNumber: CGDisplayVendorNumber(displayID),
      modelNumber: CGDisplayModelNumber(displayID),
      serialNumber: CGDisplaySerialNumber(displayID),
      isBuiltin: CGDisplayIsBuiltin(displayID) != 0
    )
  }

  /// Stable hardware identity key for a currently-attached display ID.
  static func identityKey(displayID: CGDirectDisplayID) -> String {
    "\(CGDisplayVendorNumber(displayID)):\(CGDisplayModelNumber(displayID)):\(CGDisplaySerialNumber(displayID))"
  }
  
  var audioControlTargetDisplays: [OtherDisplay] = []
  let globalDDCQueue = DispatchQueue(label: "Global DDC queue")
  let gammaActivityEnforcer = NSWindow(contentRect: .init(origin: NSPoint(x: 0, y: 0), size: .init(width: DEBUG_GAMMA_ENFORCER ? 15 : 1, height: DEBUG_GAMMA_ENFORCER ? 15 : 1)), styleMask: [], backing: .buffered, defer: false)
  var gammaInterferenceCounter = 0
  var gammaInterferenceWarningShown = false

  func createGammaActivityEnforcer() {
    self.gammaActivityEnforcer.title = "LumaPilot Gamma Activity Enforcer"
    self.gammaActivityEnforcer.isMovableByWindowBackground = false
    self.gammaActivityEnforcer.backgroundColor = DEBUG_GAMMA_ENFORCER ? .red : .black
    self.gammaActivityEnforcer.alphaValue = 1 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01)
    self.gammaActivityEnforcer.ignoresMouseEvents = true
    self.gammaActivityEnforcer.level = .screenSaver
    self.gammaActivityEnforcer.orderFrontRegardless()
    self.gammaActivityEnforcer.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary]
    os_log("Gamma activity enforcer created.", type: .info)
  }

  func enforceGammaActivity() {
    if self.gammaActivityEnforcer.alphaValue == 1 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01) {
      self.gammaActivityEnforcer.alphaValue = 2 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01)
    } else {
      self.gammaActivityEnforcer.alphaValue = 1 * (DEBUG_GAMMA_ENFORCER ? 0.5 : 0.01)
    }
  }

  func moveGammaActivityEnforcer(displayID: CGDirectDisplayID) {
    if let screen = DisplayManager.getByDisplayID(displayID: DisplayManager.resolveEffectiveDisplayID(displayID)) {
      self.gammaActivityEnforcer.setFrameOrigin(screen.frame.origin)
    }
    self.gammaActivityEnforcer.orderFrontRegardless()
  }

  var shades: [CGDirectDisplayID: NSWindow] = [:]
  var shadeGrave: [NSWindow] = []

  func isDisqualifiedFromShade(_ displayID: CGDirectDisplayID) -> Bool {
    if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
      if displayID == DisplayManager.resolveEffectiveDisplayID(displayID), DisplayManager.isVirtual(displayID: displayID) || DisplayManager.isDummy(displayID: displayID) {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displayIDs, &displayCount) == .success else {
          return true
        }
        for displayId in displayIDs where CGDisplayMirrorsDisplay(displayId) == displayID && !DisplayManager.isVirtual(displayID: displayID) {
          return true
        }
        return false
      }
      return true
    }
    return false
  }

  func createShadeOnDisplay(displayID: CGDirectDisplayID) -> NSWindow? {
    if let screen = DisplayManager.getByDisplayID(displayID: displayID) {
      let shade = NSWindow(contentRect: .init(origin: NSPoint(x: 0, y: 0), size: .init(width: 10, height: 1)), styleMask: [], backing: .buffered, defer: false)
      shade.title = "LumaPilot Window Shade for Display " + String(displayID)
      shade.isMovableByWindowBackground = false
      shade.backgroundColor = .clear
      shade.ignoresMouseEvents = true
      shade.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
      shade.orderFrontRegardless()
      shade.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
      shade.setFrame(screen.frame, display: true)
      shade.contentView?.wantsLayer = true
      shade.contentView?.alphaValue = 0.0
      shade.contentView?.layer?.backgroundColor = .black
      shade.contentView?.setNeedsDisplay(shade.frame)
      os_log("Window shade created for display %{public}@", type: .info, String(displayID))
      return shade
    }
    return nil
  }

  func getShade(displayID: CGDirectDisplayID) -> NSWindow? {
    guard !self.isDisqualifiedFromShade(displayID) else {
      return nil
    }
    if let shade = shades[displayID] {
      return shade
    } else {
      if let shade = self.createShadeOnDisplay(displayID: displayID) {
        self.shades[displayID] = shade
        return shade
      }
    }
    return nil
  }

  func destroyAllShades() -> Bool {
    var ret = false
    for displayID in self.shades.keys {
      os_log("Attempting to destory shade for display  %{public}@", type: .info, String(displayID))
      if self.destroyShade(displayID: displayID) {
        ret = true
      }
    }
    if ret {
      os_log("Destroyed all shades.", type: .info)
    } else {
      os_log("No shades were found to be destroyed.", type: .info)
    }
    return ret
  }

  func destroyShade(displayID: CGDirectDisplayID) -> Bool {
    if let shade = shades[displayID] {
      os_log("Destroying shade for display %{public}@", type: .info, String(displayID))
      self.shadeGrave.append(shade)
      self.shades.removeValue(forKey: displayID)
      shade.close()
      return true
    }
    return false
  }

  func updateShade(displayID: CGDirectDisplayID) -> Bool {
    guard !self.isDisqualifiedFromShade(displayID) else {
      return false
    }
    if let screen = DisplayManager.getByDisplayID(displayID: displayID) {
      if let shade = getShade(displayID: displayID) {
        shade.setFrame(screen.frame, display: true)
        return true
      }
    }
    return false
  }

  func getShadeAlpha(displayID: CGDirectDisplayID) -> Float? {
    guard !self.isDisqualifiedFromShade(displayID) else {
      return 1
    }
    if let shade = getShade(displayID: displayID) {
      return Float(shade.contentView?.alphaValue ?? 1)
    } else {
      return 1
    }
  }

  func setShadeAlpha(value: Float, displayID: CGDirectDisplayID) -> Bool {
    guard !self.isDisqualifiedFromShade(displayID) else {
      return false
    }
    if let shade = getShade(displayID: displayID) {
      shade.contentView?.alphaValue = CGFloat(value)
      return true
    }
    return false
  }

  func configureDisplays() {
    self.loadKnownDisplays()
    self.clearDisplays()
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineDisplayIDs, &displayCount) == .success else {
      os_log("Unable to get display list.", type: .info)
      return
    }
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      let name = DisplayManager.getDisplayNameByID(displayID: onlineDisplayID)
      let id = onlineDisplayID
      let vendorNumber = CGDisplayVendorNumber(onlineDisplayID)
      let modelNumber = CGDisplayModelNumber(onlineDisplayID)
      let serialNumber = CGDisplaySerialNumber(onlineDisplayID)
      // Record/refresh this display's reference. Drop any stale reference that points at the
      // same physical panel under a different (reassigned) ID so it never lingers as "off".
      self.reconcileKnownDisplay(id: id, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isBuiltin: CGDisplayIsBuiltin(onlineDisplayID) != 0)
      let isDummy: Bool = DisplayManager.isDummy(displayID: onlineDisplayID)
      let isVirtual: Bool = DisplayManager.isVirtual(displayID: onlineDisplayID)
      if !DEBUG_SW, DisplayManager.isAppleDisplay(displayID: onlineDisplayID) { // MARK: (point of interest for testing)
        let appleDisplay = AppleDisplay(id, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isVirtual: isVirtual, isDummy: isDummy)
        os_log("Apple display found - %{public}@", type: .info, "ID: \(appleDisplay.identifier), Name: \(appleDisplay.name) (Vendor: \(appleDisplay.vendorNumber ?? 0), Model: \(appleDisplay.modelNumber ?? 0))")
        self.addDisplay(display: appleDisplay)
      } else {
        let otherDisplay = OtherDisplay(id, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isVirtual: isVirtual, isDummy: isDummy)
        os_log("Other display found - %{public}@", type: .info, "ID: \(otherDisplay.identifier), Name: \(otherDisplay.name) (Vendor: \(otherDisplay.vendorNumber ?? 0), Model: \(otherDisplay.modelNumber ?? 0))")
        self.addDisplay(display: otherDisplay)
      }
    }
  }

  func setupOtherDisplays(firstrun: Bool = false) {
    for otherDisplay in self.getOtherDisplays() {
      for command in [Command.audioSpeakerVolume, Command.contrast] where !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: command) && !otherDisplay.isSw() {
        otherDisplay.setupCurrentAndMaxValues(command: command, firstrun: firstrun)
      }
      if (!otherDisplay.isSw() && !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .brightness)) || otherDisplay.isSw() {
        otherDisplay.setupCurrentAndMaxValues(command: .brightness, firstrun: firstrun)
        otherDisplay.brightnessSyncSourceValue = otherDisplay.readPrefAsFloat(for: .brightness)
      }
    }
  }

  func restoreOtherDisplays() {
    for otherDisplay in self.getDdcCapableDisplays() {
      for command in [Command.contrast, Command.brightness] where !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: command) {
        otherDisplay.restoreDDCSettingsToDisplay(command: command)
      }
    }
  }

  func normalizedName(_ name: String) -> String {
    var normalizedName = name.replacingOccurrences(of: "(", with: "")
    normalizedName = normalizedName.replacingOccurrences(of: ")", with: "")
    normalizedName = normalizedName.replacingOccurrences(of: " ", with: "")
    for i in 0 ... 9 {
      normalizedName = normalizedName.replacingOccurrences(of: String(i), with: "")
    }
    return normalizedName
  }

  func updateAudioControlTargetDisplays(deviceName: String) -> Int {
    self.audioControlTargetDisplays.removeAll()
    os_log("Detecting displays for audio control via audio device name matching...", type: .info)
    var numOfAddedDisplays = 0
    for ddcCapableDisplay in self.getDdcCapableDisplays() {
      var displayAudioDeviceName = ddcCapableDisplay.readPrefAsString(key: .audioDeviceNameOverride)
      if displayAudioDeviceName == "" {
        displayAudioDeviceName = DisplayManager.getDisplayRawNameByID(displayID: ddcCapableDisplay.identifier)
      }
      if self.normalizedName(displayAudioDeviceName) == self.normalizedName(deviceName) {
        self.audioControlTargetDisplays.append(ddcCapableDisplay)
        numOfAddedDisplays += 1
        os_log("Added display for audio control - %{public}@", type: .info, ddcCapableDisplay.name)
      }
    }
    return numOfAddedDisplays
  }

  func getOtherDisplays() -> [OtherDisplay] {
    self.displays.compactMap { $0 as? OtherDisplay }
  }

  func sortDisplays() {
    // Opsiyonel: sıralamadan önce log al
    let before = displays.map { $0.name }
    os_log("Displays before sorting: %{public}@", before)
    
    // In‑place sıralama
    displays.sort { lhs, rhs in
      lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    
    // Opsiyonel: sıralamadan sonra log al
    let after = displays.map { $0.name }
    os_log("Displays after sorting: %{public}@", after)
  }
  
  func sortDisplaysByFriendlyName() -> [Display] {
      return displays.sorted { lhs, rhs in
          let lhsTitle = lhs.readPrefAsString(key: .friendlyName).isEmpty
              ? lhs.name
              : lhs.readPrefAsString(key: .friendlyName)
          let rhsTitle = rhs.readPrefAsString(key: .friendlyName).isEmpty
              ? rhs.name
              : rhs.readPrefAsString(key: .friendlyName)
          return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedDescending
      }
  }



  /// displays dizisini sıralar ve döner
  func getAllDisplays() -> [Display] {
    return displays
  }

  func getDdcCapableDisplays() -> [OtherDisplay] {
    self.displays.compactMap { display -> OtherDisplay? in
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() {
        return otherDisplay
      } else { return nil }
    }
  }

  func getAppleDisplays() -> [AppleDisplay] {
    self.displays.compactMap { $0 as? AppleDisplay }
  }

  func getBuiltInDisplay() -> Display? {
    self.displays.first { CGDisplayIsBuiltin($0.identifier) != 0 }
  }

  func getCurrentDisplay(byFocus: Bool = false) -> Display? {
    if byFocus {
      guard let mainDisplayID = NSScreen.main?.displayID else {
        return nil
      }
      return self.displays.first { $0.identifier == mainDisplayID }
    } else {
      let mouseLocation = NSEvent.mouseLocation
      let screens = NSScreen.screens
      if let screenWithMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }) {
        return self.displays.first { $0.identifier == screenWithMouse.displayID }
      }
      return nil
    }
  }

  func addDisplay(display: Display) {
    self.displays.append(display)
  }

  func clearDisplays() {
    self.displays = []
  }

  func getActiveDisplayIDs() -> [CGDirectDisplayID] {
    var activeDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
    var activeDisplayCount: UInt32 = 0
    guard CGGetActiveDisplayList(32, &activeDisplayIDs, &activeDisplayCount) == .success else {
      return []
    }
    return Array(activeDisplayIDs.prefix(Int(activeDisplayCount))).filter { $0 != 0 }
  }

  func getOnlineDisplayIDs() -> [CGDirectDisplayID] {
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &onlineDisplayIDs, &displayCount) == .success else {
      return []
    }
    return Array(onlineDisplayIDs.prefix(Int(displayCount))).filter { $0 != 0 }
  }

  func isDisplayActive(_ displayID: CGDirectDisplayID) -> Bool {
    self.getActiveDisplayIDs().contains(displayID)
  }

  func canDisableDisplay(_ displayID: CGDirectDisplayID) -> Bool {
    let activeDisplayIDs = self.getActiveDisplayIDs()
    return activeDisplayIDs.contains(displayID) && activeDisplayIDs.count > 1
  }

  /// A known built-in (default) display that is currently offline, usable as a fallback so the
  /// user is switched to their laptop screen when they turn off their only external display.
  func offlineBuiltInFallbackID() -> CGDirectDisplayID? {
    let onlineDisplayIDs = Set(self.getOnlineDisplayIDs())
    for (id, info) in self.knownDisplays where info.isValid && !onlineDisplayIDs.contains(id) {
      // `CGDisplayIsBuiltin` stays reliable for a disabled-but-attached built-in panel, so it
      // backs up the stored flag (which older stored references may lack).
      if info.isBuiltin || CGDisplayIsBuiltin(id) != 0 {
        return id
      }
    }
    return nil
  }

  /// Whether turning `displayID` off can be honoured — either another display stays active, or a
  /// built-in fallback can be brought online in its place.
  func canDisableDisplayWithFallback(_ displayID: CGDirectDisplayID) -> Bool {
    if self.canDisableDisplay(displayID) {
      return true
    }
    return self.isDisplayActive(displayID) && self.offlineBuiltInFallbackID() != nil
  }

  /// Records a currently-attached display and self-heals any stale references to the same
  /// physical panel. When macOS reassigns a display's `CGDirectDisplayID`, the previous ID
  /// would otherwise remain in `knownDisplays` and be reported as a disconnected display even
  /// though the monitor is connected. Matching on the stable hardware identity removes it.
  func reconcileKnownDisplay(id: CGDirectDisplayID, name: String, vendorNumber: UInt32, modelNumber: UInt32, serialNumber: UInt32, isBuiltin: Bool) {
    let entry = KnownDisplay(name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isBuiltin: isBuiltin)
    // Never track a phantom/invalid reference (transient ID with no real name).
    guard entry.isValid else {
      return
    }
    if entry.hasStableIdentity {
      let identity = entry.identityKey
      let onlineIDs = Set(self.getOnlineDisplayIDs())
      let staleIDs = self.knownDisplays.compactMap { key, value -> CGDirectDisplayID? in
        // Reclaim only a reference to the same hardware under a DIFFERENT id that is no longer
        // online. A same-identity id that is itself online is a distinct identical-model monitor
        // and must be kept.
        key != id && value.hasStableIdentity && value.identityKey == identity && !onlineIDs.contains(key) ? key : nil
      }
      for staleID in staleIDs {
        os_log("Reconciling stale display reference %{public}@ into current ID %{public}@ (same hardware).", type: .info, String(staleID), String(id))
        self.knownDisplays.removeValue(forKey: staleID)
      }
    }
    self.knownDisplays[id] = entry
  }

  func getKnownDisabledDisplays() -> [(id: CGDirectDisplayID, name: String)] {
    let onlineDisplayIDs = Set(self.getOnlineDisplayIDs())
    // Stable identities of everything currently online, under whatever ID macOS assigned.
    var onlineIdentities = Set<String>()
    for onlineID in onlineDisplayIDs {
      onlineIdentities.insert(DisplayManager.identityKey(displayID: onlineID))
    }

    var disabledDisplays: [(id: CGDirectDisplayID, name: String)] = []
    var staleIDsToDrop: [CGDirectDisplayID] = []
    var seenIdentities = Set<String>()

    for (id, info) in self.knownDisplays where !onlineDisplayIDs.contains(id) {
      // Drop phantom/invalid references (empty-name transients) so they never render as a
      // nameless "ghost" row or pollute the toggle ordering used by keyboard shortcuts.
      guard info.isValid else {
        staleIDsToDrop.append(id)
        continue
      }
      // If the same physical display is online under a different ID, it is connected, not off.
      // Drop the stale reference so it stops appearing as disconnected.
      if info.hasStableIdentity, onlineIdentities.contains(info.identityKey) {
        staleIDsToDrop.append(id)
        continue
      }
      // Collapse duplicate references to the same physical panel (e.g. leftover ghosts) so a
      // disconnected display is listed only once.
      if info.hasStableIdentity {
        if seenIdentities.contains(info.identityKey) {
          staleIDsToDrop.append(id)
          continue
        }
        seenIdentities.insert(info.identityKey)
      }
      disabledDisplays.append((id, info.name))
    }

    // Self-heal persisted state (replaces the old manual "clear disconnected displays" action).
    for staleID in staleIDsToDrop {
      self.knownDisplays.removeValue(forKey: staleID)
    }

    return disabledDisplays.sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  func setDisplayEnabled(_ displayID: CGDirectDisplayID, enabled: Bool) -> (success: Bool, error: String?) {
    if !enabled, !self.canDisableDisplay(displayID) {
      // Turning off the only active display: switch to the built-in (default) display instead of
      // refusing, so the user is never left with a black screen.
      guard self.isDisplayActive(displayID), let fallbackID = self.offlineBuiltInFallbackID() else {
        return (false, NSLocalizedString("At least one display must stay enabled.", comment: "Shown in the alert dialog"))
      }
      let fallbackResult = self.setDisplayEnabled(fallbackID, enabled: true)
      guard fallbackResult.success, self.canDisableDisplay(displayID) else {
        return (false, fallbackResult.error ?? NSLocalizedString("Could not switch to the built-in display. At least one display must stay enabled.", comment: "Shown in the alert dialog"))
      }
    }

    // Record the display's stable identity BEFORE disabling it, while it is still online and its
    // hardware info is readable. Otherwise a disabled display that was not already tracked (e.g.
    // after a fresh launch or lost prefs) would become invisible in the menu and impossible to
    // turn back on from the app.
    if !enabled, self.knownDisplays[displayID] == nil {
      let entry = DisplayManager.makeKnownDisplay(displayID: displayID)
      if entry.isValid {
        self.knownDisplays[displayID] = entry
      }
    }

    guard let coreGraphicsHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else {
      return (false, NSLocalizedString("This macOS version does not expose the private display toggle API.", comment: "Shown in the alert dialog"))
    }
    defer { dlclose(coreGraphicsHandle) }

    guard let configureDisplayEnabledSymbol = dlsym(coreGraphicsHandle, "CGSConfigureDisplayEnabled") else {
      return (false, NSLocalizedString("This macOS version does not expose the private display toggle API.", comment: "Shown in the alert dialog"))
    }
    let configureDisplayEnabled = unsafeBitCast(configureDisplayEnabledSymbol, to: CGSConfigureDisplayEnabledFunction.self)

    var lastCompleteError: CGError?
    for option in [CGConfigureOption.permanently, CGConfigureOption.forSession] {
      var displayConfigRef: CGDisplayConfigRef?
      let beginResult = CGBeginDisplayConfiguration(&displayConfigRef)
      guard beginResult == .success else {
        return (false, "CGBeginDisplayConfiguration failed (\(beginResult.rawValue)).")
      }

      let configureResult = configureDisplayEnabled(displayConfigRef, displayID, enabled)
      guard configureResult == 0 else {
        CGCancelDisplayConfiguration(displayConfigRef)
        return (false, "CGSConfigureDisplayEnabled failed (\(configureResult)).")
      }

      let completeResult = CGCompleteDisplayConfiguration(displayConfigRef, option)
      if completeResult == .success {
        if enabled {
          let entry = DisplayManager.makeKnownDisplay(displayID: displayID)
          if entry.isValid {
            self.knownDisplays[displayID] = entry
          }
        }
        return (true, nil)
      }

      lastCompleteError = completeResult
      CGCancelDisplayConfiguration(displayConfigRef)
      os_log("CGCompleteDisplayConfiguration failed for option %{public}@ (%{public}d)", type: .error, option == .permanently ? "permanently" : "forSession", completeResult.rawValue)
    }

    let errCode = lastCompleteError?.rawValue ?? -1
    if enabled, errCode == 1001 {
      self.knownDisplays.removeValue(forKey: displayID)
      return (false, NSLocalizedString("Ghost monitor detected and removed. The display ID is no longer valid. Please reopen the menu.", comment: "Shown in the alert dialog"))
    }

    return (false, String(format: NSLocalizedString("Display reconfiguration failed (%d). Try changing arrangement in System Settings > Displays, then retry.", comment: "Shown in the alert dialog"), errCode))
  }

  func setDisplayResolution(_ displayID: CGDirectDisplayID, ioDisplayModeID: Int32) -> (success: Bool, error: String?) {
    let effectiveDisplayID = DisplayManager.resolveEffectiveDisplayID(displayID)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let allModesRef = CGDisplayCopyAllDisplayModes(effectiveDisplayID, options) else {
      return (false, NSLocalizedString("Unable to read available resolutions for this display.", comment: "Shown in the alert dialog"))
    }
    guard let allModes = allModesRef as? [CGDisplayMode] else {
      return (false, NSLocalizedString("Unable to read available resolutions for this display.", comment: "Shown in the alert dialog"))
    }
    guard let selectedMode = allModes.first(where: { $0.ioDisplayModeID == ioDisplayModeID && $0.isUsableForDesktopGUI() }) else {
      return (false, NSLocalizedString("Selected resolution is no longer available.", comment: "Shown in the alert dialog"))
    }

    if let currentMode = CGDisplayCopyDisplayMode(effectiveDisplayID), currentMode.ioDisplayModeID == selectedMode.ioDisplayModeID {
      return (true, nil)
    }

    var lastCompleteError: CGError?
    for option in [CGConfigureOption.permanently, CGConfigureOption.forSession] {
      var displayConfigRef: CGDisplayConfigRef?
      let beginResult = CGBeginDisplayConfiguration(&displayConfigRef)
      guard beginResult == .success else {
        return (false, "CGBeginDisplayConfiguration failed (\(beginResult.rawValue)).")
      }

      let configureResult = CGConfigureDisplayWithDisplayMode(displayConfigRef, effectiveDisplayID, selectedMode, nil)
      guard configureResult == .success else {
        CGCancelDisplayConfiguration(displayConfigRef)
        return (false, "CGConfigureDisplayWithDisplayMode failed (\(configureResult.rawValue)).")
      }

      let completeResult = CGCompleteDisplayConfiguration(displayConfigRef, option)
      if completeResult == .success {
        return (true, nil)
      }

      lastCompleteError = completeResult
      CGCancelDisplayConfiguration(displayConfigRef)
      os_log("CGCompleteDisplayConfiguration for display mode failed for option %{public}@ (%{public}d)", type: .error, option == .permanently ? "permanently" : "forSession", completeResult.rawValue)
    }

    return (false, String(format: NSLocalizedString("Display mode change failed (%d).", comment: "Shown in the alert dialog"), lastCompleteError?.rawValue ?? -1))
  }

  private func usableDisplayModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
    let effectiveDisplayID = DisplayManager.resolveEffectiveDisplayID(displayID)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let modesRef = CGDisplayCopyAllDisplayModes(effectiveDisplayID, options), let allModes = modesRef as? [CGDisplayMode] else {
      return []
    }
    return allModes.filter { $0.isUsableForDesktopGUI() }
  }

  func defaultDisplayModeID(for displayID: CGDirectDisplayID) -> Int32? {
    let modes = self.usableDisplayModes(for: displayID)
    guard !modes.isEmpty else {
      return nil
    }
    if let nativeMode = modes.first(where: { ($0.ioFlags & UInt32(kDisplayModeNativeFlag)) != 0 }) {
      return nativeMode.ioDisplayModeID
    }
    let sortedModes = modes.sorted { lhs, rhs in
      let lhsPixels = lhs.pixelWidth * lhs.pixelHeight
      let rhsPixels = rhs.pixelWidth * rhs.pixelHeight
      if lhsPixels != rhsPixels {
        return lhsPixels > rhsPixels
      }
      return lhs.refreshRate > rhs.refreshRate
    }
    return sortedModes.first?.ioDisplayModeID
  }

  func resetDisplayResolutionToDefault(_ displayID: CGDirectDisplayID) -> (success: Bool, error: String?) {
    guard let defaultModeID = self.defaultDisplayModeID(for: displayID) else {
      return (false, NSLocalizedString("Unable to read available resolutions for this display.", comment: "Shown in the alert dialog"))
    }
    return self.setDisplayResolution(displayID, ioDisplayModeID: defaultModeID)
  }

  func resetAllDisplayResolutionsToDefault() {
    for displayID in self.getActiveDisplayIDs() {
      let result = self.resetDisplayResolutionToDefault(displayID)
      if !result.success {
        os_log(
          "Failed to reset display %{public}@ to default resolution: %{public}@",
          type: .error,
          String(displayID),
          result.error ?? "unknown error"
        )
      }
    }
  }
  
  func addDisplayCounterSuffixes() {
    var nameDisplays: [String: [Display]] = [:]
    for display in self.displays {
      if nameDisplays[display.name] != nil {
        nameDisplays[display.name]?.append(display)
      } else {
        nameDisplays[display.name] = [display]
      }
    }
    for nameDisplayKey in nameDisplays.keys where nameDisplays[nameDisplayKey]?.count ?? 0 > 1 {
      for i in 0 ... (nameDisplays[nameDisplayKey]?.count ?? 1) - 1 {
        if let display = nameDisplays[nameDisplayKey]?[i] {
          display.name = "" + display.name + " (" + String(i + 1) + ")"
        }
      }
    }
  }

  func updateArm64AVServices() {
    if Arm64DDC.isArm64 {
      os_log("arm64 AVService update requested", type: .info)
      var displayIDs: [CGDirectDisplayID] = []
      for otherDisplay in self.getOtherDisplays() {
        displayIDs.append(otherDisplay.identifier)
      }
      for serviceMatch in Arm64DDC.getServiceMatches(displayIDs: displayIDs) {
        for otherDisplay in self.getOtherDisplays() where otherDisplay.identifier == serviceMatch.displayID && serviceMatch.service != nil {
          otherDisplay.arm64avService = serviceMatch.service
          os_log("Display service match successful for display %{public}@", type: .info, String(serviceMatch.displayID))
          if serviceMatch.discouraged {
            os_log("Display %{public}@ is flagged as discouraged by Arm64DDC.", type: .info, String(serviceMatch.displayID))
            otherDisplay.isDiscouraged = true
          } else if serviceMatch.dummy {
            os_log("Display %{public}@ is flagged as dummy by Arm64DDC.", type: .info, String(serviceMatch.displayID))
            otherDisplay.isDiscouraged = true
            otherDisplay.isDummy = true
          } else {
            otherDisplay.arm64ddc = DEBUG_SW ? false : true // MARK: (point of interest when testing)
          }
        }
      }
      os_log("AVService update done", type: .info)
    }
  }

  func resetSwBrightnessForAllDisplays(prefsOnly: Bool = false, noPrefSave: Bool = false, async: Bool = false) {
    for otherDisplay in self.getOtherDisplays() {
      if !prefsOnly {
        _ = otherDisplay.setSwBrightness(1, smooth: async, noPrefSave: noPrefSave)
        if !noPrefSave {
          otherDisplay.smoothBrightnessTransient = 1
        }
      } else if !noPrefSave {
        otherDisplay.savePref(1, key: .SwBrightness)
        otherDisplay.smoothBrightnessTransient = 1
      }
      if otherDisplay.isSw(), !noPrefSave {
        otherDisplay.savePref(1, for: .brightness)
      }
    }
  }

  func restoreSwBrightnessForAllDisplays(async: Bool = false) {
    for otherDisplay in self.getOtherDisplays() {
      if (otherDisplay.readPrefAsFloat(for: .brightness) == 0 && !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue)) || (otherDisplay.readPrefAsFloat(for: .brightness) < otherDisplay.combinedBrightnessSwitchingValue() && !prefs.bool(forKey: PrefKey.separateCombinedScale.rawValue) && !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue)) || otherDisplay.isSw() {
        let savedPrefValue = otherDisplay.readPrefAsFloat(key: .SwBrightness)
        if otherDisplay.getSwBrightness() != savedPrefValue {
          OSDUtils.popEmptyOsd(displayID: otherDisplay.identifier, command: Command.brightness) // This will give the user a hint why is the brightness suddenly changes.
        }
        otherDisplay.savePref(otherDisplay.getSwBrightness(), key: .SwBrightness)
        os_log("Restoring sw brightness to %{public}@ on other display %{public}@", type: .info, String(savedPrefValue), String(otherDisplay.identifier))
        _ = otherDisplay.setSwBrightness(savedPrefValue, smooth: async)
        if otherDisplay.isSw(), let slider = otherDisplay.sliderHandler[.brightness] {
          os_log("Restoring sw slider to %{public}@ for other display %{public}@", type: .info, String(savedPrefValue), String(otherDisplay.identifier))
          slider.setValue(savedPrefValue, displayID: otherDisplay.identifier)
        }
      } else {
        _ = otherDisplay.setSwBrightness(1)
      }
    }
  }

  func getAffectedDisplays(isBrightness: Bool = false, isVolume: Bool = false) -> [Display]? {
    var affectedDisplays: [Display]
    let allDisplays = self.getAllDisplays()
    var currentDisplay: Display?
    if isBrightness {
      if prefs.integer(forKey: PrefKey.multiKeyboardBrightness.rawValue) == MultiKeyboardBrightness.allScreens.rawValue {
        affectedDisplays = allDisplays
        return affectedDisplays
      }
      currentDisplay = self.getCurrentDisplay(byFocus: prefs.integer(forKey: PrefKey.multiKeyboardBrightness.rawValue) == MultiKeyboardBrightness.focusInsteadOfMouse.rawValue)
    }
    if isVolume {
      if prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.allScreens.rawValue {
        affectedDisplays = allDisplays
        return affectedDisplays
      } else if prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.audioDeviceNameMatching.rawValue {
        return self.audioControlTargetDisplays
      }
      currentDisplay = self.getCurrentDisplay(byFocus: false)
    }
    if let currentDisplay = currentDisplay {
      affectedDisplays = [currentDisplay]
      if CGDisplayIsInHWMirrorSet(currentDisplay.identifier) != 0 || CGDisplayIsInMirrorSet(currentDisplay.identifier) != 0, CGDisplayMirrorsDisplay(currentDisplay.identifier) == 0 {
        for display in allDisplays where CGDisplayMirrorsDisplay(display.identifier) == currentDisplay.identifier {
          affectedDisplays.append(display)
        }
      }
    } else {
      affectedDisplays = []
    }
    return affectedDisplays
  }

  static func isDummy(displayID: CGDirectDisplayID) -> Bool {
    let vendorNumber = CGDisplayVendorNumber(displayID)
    let rawName = DisplayManager.getDisplayRawNameByID(displayID: displayID)
    if rawName.lowercased().contains("dummy") || (self.isVirtual(displayID: displayID) && vendorNumber == UInt32(0xF0F0)) {
      os_log("NOTE: Display is a dummy!", type: .info)
      return true
    }
    return false
  }

  static func isVirtual(displayID: CGDirectDisplayID) -> Bool {
    var isVirtual = false
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      if let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?) {
        let isVirtualDevice = dictionary["kCGDisplayIsVirtualDevice"] as? Bool
        let displayIsAirplay = dictionary["kCGDisplayIsAirPlay"] as? Bool
        if isVirtualDevice ?? displayIsAirplay ?? false {
          isVirtual = true
        }
      }
    }
    return isVirtual
  }

  static func engageMirror() -> Bool {
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineDisplayIDs, &displayCount) == .success, displayCount > 1 else {
      return false
    }
    // Break display mirror if there is any
    var mirrorBreak = false
    var displayConfigRef: CGDisplayConfigRef?
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      if CGDisplayIsInHWMirrorSet(onlineDisplayID) != 0 || CGDisplayIsInMirrorSet(onlineDisplayID) != 0 {
        if mirrorBreak == false {
          CGBeginDisplayConfiguration(&displayConfigRef)
        }
        CGConfigureDisplayMirrorOfDisplay(displayConfigRef, onlineDisplayID, kCGNullDirectDisplay)
        mirrorBreak = true
      }
    }
    if mirrorBreak {
      CGCompleteDisplayConfiguration(displayConfigRef, CGConfigureOption.permanently)
      return true
    }
    // Build display mirror
    var mainDisplayId = kCGNullDirectDisplay
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      if CGDisplayIsBuiltin(onlineDisplayID) == 0, mainDisplayId == kCGNullDirectDisplay {
        mainDisplayId = onlineDisplayID
      }
    }
    guard mainDisplayId != kCGNullDirectDisplay else {
      return false
    }
    CGBeginDisplayConfiguration(&displayConfigRef)
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 && onlineDisplayID != mainDisplayId {
      CGConfigureDisplayMirrorOfDisplay(displayConfigRef, onlineDisplayID, mainDisplayId)
    }
    CGCompleteDisplayConfiguration(displayConfigRef, CGConfigureOption.permanently)
    return true
  }

  static func resolveEffectiveDisplayID(_ displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    var realDisplayID = displayID
    if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
      let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
      if mirroredDisplayID != 0 {
        realDisplayID = mirroredDisplayID
      }
    }
    return realDisplayID
  }

  static func isAppleDisplay(displayID: CGDirectDisplayID) -> Bool {
    if #available(macOS 15.0, *) {
      if CGDisplayVendorNumber(displayID) != 1552, CGSIsHDRSupported(displayID), CGSIsHDREnabled(displayID) {
        return CGDisplayIsBuiltin(displayID) != 0
      }
    }
    var brightness: Float = -1
    let ret = DisplayServicesGetBrightness(displayID, &brightness)
    if ret == 0, brightness >= 0 { // If brightness read appears to be successful using DisplayServices then it should be an Apple display
      return true
    }
    return CGDisplayIsBuiltin(displayID) != 0 // If built-in display, it should be Apple
  }

  static func getByDisplayID(displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { $0.displayID == displayID }
  }

  static func getDisplayRawNameByID(displayID: CGDirectDisplayID) -> String {
    let defaultName = ""
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      if let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?), let nameList = dictionary["DisplayProductName"] as? [String: String], let name = nameList["en_US"] ?? nameList.first?.value {
        return name
      }
    }
    if let screen = getByDisplayID(displayID: displayID) {
      return screen.displayName ?? defaultName
    }
    return defaultName
  }

  static func getDisplayNameByID(displayID: CGDirectDisplayID) -> String {
    let defaultName: String = NSLocalizedString("Unknown", comment: "Unknown display name")
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      if let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?), let nameList = dictionary["DisplayProductName"] as? [String: String], var name = nameList[Locale.current.identifier] ?? nameList["en_US"] ?? nameList.first?.value {
        if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
          let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
          if mirroredDisplayID != 0, let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(mirroredDisplayID)?.takeRetainedValue() as NSDictionary?), let nameList = dictionary["DisplayProductName"] as? [String: String], let mirroredName = nameList[Locale.current.identifier] ?? nameList["en_US"] ?? nameList.first?.value {
            name.append(" | " + mirroredName)
          }
        }
        return name
      }
    }
    if let screen = getByDisplayID(displayID: displayID) { // MARK: This, and NSScreen+Extension.swift will not be needed when we drop MacOS 10 support.
      if #available(macOS 10.15, *) {
        return screen.localizedName
      } else {
        return screen.displayName ?? defaultName
      }
    }
    return defaultName
  }
}
