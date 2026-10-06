//
//  PreferenceSource.swift
//  Managed Encryption Escrow
//
//  Reads Crypt's preferences the way checkin sees them as root, and asks the
//  system which keys a configuration profile manages.
//

import Foundation
import ManagedEncryptionEscrowXPC

protocol PreferenceSource {
    /// The effective value: the managed value when a profile sets the key,
    /// otherwise the value in /Library/Preferences.
    func value(forKey key: String) -> Any?
    /// True when a configuration profile manages the key.
    func isManaged(_ key: String) -> Bool
}

struct SystemPreferenceSource: PreferenceSource {
    let domain = EscrowConstants.preferenceDomain as CFString

    func value(forKey key: String) -> Any? {
        if isManaged(key) {
            return CFPreferencesCopyAppValue(key as CFString, domain)
        }
        return CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    }

    func isManaged(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, domain)
    }
}
