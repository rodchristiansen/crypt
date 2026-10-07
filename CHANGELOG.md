# Changelog

## Unreleased

Crypt's client is now Swift throughout. The `checkin` binary was rewritten from
Go into a SwiftPM executable that shares the `CryptCore` sources with the
authorization plugin, so the keychain, preference and FileVault handling exists
once rather than twice in two languages. The Go and Bazel trees are gone.

### Enhancements

- Escrow goes over URLSession rather than shelling out to `/usr/bin/curl`, with
  configurable timeouts (`ServerTimeout`), retries (`ServerRetryAttempts`) and
  an optional API key (`APIKey`, `APIKeyHeader`). Mutual TLS via
  `CommonNameForEscrow` now uses the same request path as everything else.
- `checkin` gained subcommands: `escrow`, `rotate`, `verify`, `config` and
  `auth-mechs`. The single-dash flags of earlier versions still work.
- `checkin verify` reports FileVault state, whether a key is held, whether it
  still unlocks the disk, and when it was last escrowed, as text or JSON.
- `checkin config list` shows every setting, its resolved value, and which layer
  supplied it.
- Configuration now resolves from the environment (`CRYPT_SERVER_URL` and
  friends), then the preference domain, then `/Library/Managed Encryption/config.plist`,
  then the built-in default.
- Distinct exit codes so a management system can tell a configuration problem
  from a server problem from a machine with no key yet.
- Serial number, hardware UUID, computer name and OS version are read through
  IOKit, SystemConfiguration and ProcessInfo instead of by parsing `scutil` and
  `sw_vers` output.
- `LogLevel` sets the floor for the managed log; `--verbose` raises it for one run.

### Removed

- `AdditionalCurlOpts`, which has no meaning now that `curl` is not involved.

## [v4.1.0](https://github.com/grahamgilbert/crypt/compare/4.0.0...4.1.0)

Crypt 4.1.0 only supports macOS 11 and up. Older versions are not supported.

### Fixed in this release

- Preinstall script failed if FoundationPlist.pyc didn't exist #105
- `get_os_version` now works on macOS 12 #107 @discentem

### Enhancements

- All of Crypt is now distributed as Universal2 (No Rosetta required!)
- Python is updated to 3.9.X
- The log file will rotate when it reaches 5MB

## [v4.0.0](https://github.com/grahamgilbert/crypt/compare/3.3.1...4.0.0)

Changes are lost in the mists of time.

## [v3.3.1](https://github.com/grahamgilbert/crypt/compare/3.3.0...3.3.1)

### Fixed in this release

- On Catalina, skip local checking of `usingrecoverykey` after using recovery key to prevent lockout of changing user password (#99 @weswhet)

### Enhancements

- Added documentation on `AdditionalCurlOpts` (#97, #98 @asyiu)
- Example PPPC/TCC profile (@grahamgilbert)
- Document `curl` POST in `checkin` script and use long-form arguments (#93 @erikng)

## [v3.3.0](https://github.com/grahamgilbert/crypt/compare/3.2.1...3.3.0)

### Fixed in this release

- Secrets are no longer visible when inspecting the process (#88 @bdemetris)
- Cleanup the working directory prior to build (#90 @clburlison)

### Enhancements

- Updated to Swift 4.2 (#91 @clburlison)
