# Managed Encryption Escrow

A Prefs / Run / Logs window for Crypt, installed as
`/Applications/Utilities/Managed Encryption Escrow.app`. It leaves Crypt's
`checkin`, its login plugin and the `com.grahamgilbert.crypt` launch daemon
unchanged.

- **Prefs** shows Crypt's settings as `checkin` resolves them. A key a
  configuration profile manages shows its managed value, locked. Every field
  stays read-only until an administrator clicks **Unlock** and authenticates;
  edits then save to `/Library/Preferences/com.grahamgilbert.crypt.plist`. The
  API key is shown only as set or not set, and the recovery key is never shown.
- **Run** starts one of a fixed set of `checkin` runs: Verify, Escrow now,
  Check login mechanisms, and Rotate if invalid (administrator only), and
  streams the output. Anything shaped like a recovery key is redacted before
  it reaches the window.
- **Logs** lists `crypt.log`, its daily rolls and the launchd log under
  `/Library/Managed Encryption/logs`.

The window never runs as root. Runs and preference writes go through
`ManagedEncryptionEscrowHelper`, which the package installs as the
LaunchDaemon `com.grahamgilbert.crypt.helper`. The helper:

- accepts only a client signed as `com.grahamgilbert.crypt.gui` by its own
  Team ID, so an unsigned build refuses every client;
- runs only the fixed `checkin` arguments for a named mode, with a minimal
  environment, and refuses a `checkin` that anyone but root could change;
- writes only the keys the window edits, and only with an authorization
  reference that already holds `system.privilege.admin`. The server URL decides
  where the recovery key is sent, so a standard user can run Verify and Escrow
  but cannot change where the key goes, or discard it.

Sign the helper and the app with the same Developer ID before deployment.

Build and test:

```
swift test
```

```
make pkg
```

Set `SIGNING_IDENTITY_APP` and `SIGNING_IDENTITY_PKG` to sign the app and the
package, and `NOTARIZATION_PROFILE` for `make notarize`.
