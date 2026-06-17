# IndeRun Core (Android)

The `inderun-core` module contains the platform-specific implementations of the [HostServices] required by the IndeRun engine.

## Implemented Services

*   **`ConnectivityService`**: Uses `ConnectivityManager` to monitor network availability.
*   **`SecureStorageService`**: A slot-based credential store addressed by `authContextRef`, currently backed by app-private shared preferences in this milestone.
*   **`ClockService`**: Provides a monotonic elapsed-realtime clock for timing and telemetry.

## Extending HostServices

To add a new platform service, follow these steps:

1.  Define the interface in `HostServices.kt`.
2.  Implement the service within this module.
3.  Register it in the `HostServicesFactory.create(context)` method.

### Security Note: SecureStorage
Credentials are stored and retrieved via their unique `authContextRef` identifier rather than passing raw secrets through API layers or request payloads.
