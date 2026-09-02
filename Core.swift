/*
 Crypt
 
 Copyright 2025 The Crypt Project.
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import Foundation
import Security
import os.log

class Crypt: NSObject {

  // Define a pointer to the MechanismRecord. This will be used to get and set
  // all the inter-mechanism data. It is also used to allow or deny the login.
  var mechanism: UnsafePointer<MechanismRecord>

  // init the class with a MechanismRecord
  @objc init(mechanism: UnsafePointer<MechanismRecord>) {
    cryptLog("initWithMechanismRecord", log: coreLog, type: .debug)
    self.mechanism = mechanism
  }

  // Allow the login. End of the mechanism
  func allowLogin() {
    cryptLog("called allowLogin", log: coreLog, type: .default)
    _ = self.mechanism.pointee.fPlugin.pointee.fCallbacks.pointee.SetResult(
      mechanism.pointee.fEngine, AuthorizationResult.allow)
  }

  private func getContextData(key: AuthorizationString) -> NSData? {
    cryptLog("getContextData called", log: coreLog, type: .debug)
    var value: UnsafePointer<AuthorizationValue>?
    let data = withUnsafeMutablePointer(to: &value) { (ptr: UnsafeMutablePointer) -> NSData? in
      var flags = AuthorizationContextFlags()
      if self.mechanism.pointee.fPlugin.pointee.fCallbacks.pointee.GetContextValue(
        self.mechanism.pointee.fEngine, key, &flags, ptr) != errAuthorizationSuccess {
        cryptLog("GetContextValue failed", log: coreLog, type: .error)
        return nil
      }
      guard let length = ptr.pointee?.pointee.length else {
        cryptLog("length failed to unwrap", log: coreLog, type: .error)
        return nil
      }
      guard let buffer = ptr.pointee?.pointee.data else {
        cryptLog("data failed to unwrap", log: coreLog, type: .error)
        return nil
      }
      if length == 0 {
        cryptLog("length is 0", log: coreLog, type: .error)
        return nil
      }
      return NSData.init(bytes: buffer, length: length)
    }
    return data
  }

  var username: NSString? {
    get {
      cryptLog("Requesting username...", log: coreLog, type: .debug)
      guard let data = getContextData(key: kAuthorizationEnvironmentUsername) else {
        return nil
      }
      guard let s = NSString.init(bytes: data.bytes,
                                  length: data.length,
                                  encoding: String.Encoding.utf8.rawValue)
      else { return nil }
      return s.replacingOccurrences(of: "\0", with: "") as NSString
    }
  }

  var password: NSString? {
    get {
      cryptLog("Requesting password...", log: coreLog, type: .debug)
      guard let data = getContextData(key: kAuthorizationEnvironmentPassword) else {
        return nil
      }
      guard let s = NSString.init(bytes: data.bytes,
                                  length: data.length,
                                  encoding: String.Encoding.utf8.rawValue)
      else { return nil }
      return s.replacingOccurrences(of: "\0", with: "") as NSString
    }
  }
}
