# IndeRun Android

Android workspace for the IndeRun SDK, host services, provider adapters, and demo app.

## Modules

- `inderun-kotlin` - public Android SDK entrypoint
- `inderun-core` - platform host services
- `inderun-contracts` - generated Kotlin contract models
- `inderun-mlkit-providers` - on-device ML Kit GenAI provider
- `inderun-openai-providers` - OpenAI-compatible cloud provider
- `inderun-demo-app` - demo app for reviewing the Mode 1 flow

## Commands

```sh
cd android && ./gradlew build
cd android && ./gradlew test
```
