# IndeRun Core (Android)

Platform-specific host services used by the Android IndeRun engine.

Implemented services:

- `ConnectivityService`
- `SecureStorageService`
- `ClockService`

## Security Note

Credentials are addressed through `authContextRef` instead of being passed as raw secrets in request payloads.
