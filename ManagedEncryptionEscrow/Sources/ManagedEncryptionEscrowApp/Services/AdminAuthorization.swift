//
//  AdminAuthorization.swift
//  Managed Encryption Escrow
//
//  One administrator authorization, asked for at the moment it is needed:
//  when Prefs saves a change, or when Rotate starts. The helper checks the
//  authorization before it acts. Nothing stays unlocked: the reference is
//  destroyed as soon as the save or run that asked for it is done, so the
//  next change asks again.
//

import Foundation
import Security
import ManagedEncryptionEscrowXPC

final class AdminAuthorization {
    private let authRef: AuthorizationRef

    /// The external form the helper accepts.
    let externalForm: Data

    private init(authRef: AuthorizationRef, externalForm: Data) {
        self.authRef = authRef
        self.externalForm = externalForm
    }

    deinit {
        AuthorizationFree(authRef, [.destroyRights])
    }

    /// Shows the system's administrator prompt. Returns nil when the user
    /// cancels or the credentials are not an administrator's.
    static func request() -> AdminAuthorization? {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }

        let status = EscrowConstants.adminRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            return nil
        }

        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            return nil
        }
        return AdminAuthorization(authRef: ref, externalForm: withUnsafeBytes(of: &form) { Data($0) })
    }
}
