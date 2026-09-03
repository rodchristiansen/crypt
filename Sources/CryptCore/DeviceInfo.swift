/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */
import Foundation
import IOKit
import SystemConfiguration

/// Facts about the machine that accompany an escrowed key. Everything here is
/// read through a framework rather than by parsing the output of a shell tool.
public enum DeviceInfo {
  /// The hardware serial number, read from the IOKit platform expert.
  public static let serialNumber: String = {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return "" }
    defer { IOObjectRelease(service) }
    guard let property = IORegistryEntryCreateCFProperty(
      service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)
    else { return "" }
    return (property.takeRetainedValue() as? String) ?? ""
  }()

  /// The hardware UUID, reported alongside the serial number.
  public static let hardwareUUID: String = {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return "" }
    defer { IOObjectRelease(service) }
    guard let property = IORegistryEntryCreateCFProperty(
      service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
    else { return "" }
    return (property.takeRetainedValue() as? String) ?? ""
  }()

  /// The computer name as set in Sharing preferences.
  public static var computerName: String {
    guard let name = SCDynamicStoreCopyComputerName(nil, nil) else { return "" }
    return name as String
  }

  /// The user at the console, or nil when nobody is logged in. The loginwindow
  /// placeholder accounts are reported as absent.
  public static var consoleUser: String? {
    guard let user = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String? else { return nil }
    if user.isEmpty || user == "loginwindow" { return nil }
    return user
  }

  /// The macOS version, from `ProcessInfo` rather than from `sw_vers`.
  public static var osVersion: OperatingSystemVersion {
    ProcessInfo.processInfo.operatingSystemVersion
  }

  public static var osVersionString: String {
    let version = osVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  /// Users that are never treated as the FileVault-enabled user.
  public static let neverEnabledUsers = ["root", "_mbsetupuser"]
}
