# Device record template (website claims)

CI cannot check what happens on a real device. This template is the format for the dated records behind the
statements on [inderun.dev](https://inderun.dev), for example the compatibility page and the "runs offline" wording.
It follows the rule in [system-speech.md](./system-speech.md): only real runs go into a record, and a check that has not
been run says **pending**.

**Status: no device record exists yet.** Until one does, the site makes no device-verified claim, in particular no
"runs offline" scenario. A successful local request with networking enabled is not proof of an offline run.

## How to use it

1. Copy this file to `docs/verification/<yyyy-mm-dd>-<device>-<platform>.md` (one record per device and run).
2. Fill in every field from what you observed. Write `not tested` rather than leaving a field empty or guessing.
3. Take the package versions from [`website/versions.json`](../../website/versions.json), not from memory.
4. Link the newest record from the compatibility page in the same change.

Do not record anything a user typed; the texts are synthetic.

## Record

| Field                          | Value                                                                                       |
| ------------------------------ | ------------------------------------------------------------------------------------------- |
| Date (yyyy-mm-dd)              |                                                                                             |
| Tester                         |                                                                                             |
| Hardware (model, RAM)          |                                                                                             |
| OS and version                 |                                                                                             |
| Platform / app                 | Capacitor app, Web SDK, Swift or Kotlin; app id and build                                   |
| `@independo/capacitor-inderun` |                                                                                             |
| `@independo/inderun-web`       |                                                                                             |
| `@independo/inderun-contracts` |                                                                                             |
| Swift / Kotlin SDK version     | only if used                                                                                |
| Install / sync steps           | the exact commands and the Capacitor sync step, so the run can be repeated                  |
| Task and privacy rule          | for example `text_to_text` with `local_required`                                            |
| Provider selected              | `provenance.providerId`, `provenance.locality`                                              |
| Result                         | succeeded, refused (reason codes from `details.rejectedProviders`), or failed (error class) |
| Network state                  | on, off (airplane mode), or restricted; how it was set and when                             |
| Model readiness                | `checkCapabilities()` output for the provider: available, reason                            |
| Limitations                    | everything that restricts what this record proves                                           |

## Speech fields

Fill these in for a speech run (`speak()`, `generateSpeech()`, `listVoices()`); otherwise write `not applicable`.

| Field              | Value                                                                                                   |
| ------------------ | ------------------------------------------------------------------------------------------------------- |
| Voices found       | count from `listVoices()`, and how many report a network requirement (Android) or are installed (Apple) |
| Locale requested   |                                                                                                         |
| Voice used         | id and whether it was local, network or unknown                                                         |
| Playback           | heard on the device speaker or not, and any gaps or clipping                                            |
| Cancel             | stop mid-utterance; confirm no audio after the stop and a terminal cancelled outcome                    |
| Network state      | on, off, restricted, and whether `local_required` was still honoured                                    |
| `generateSpeech()` | WAV returned on iOS and Android, refused on the web; note what happened                                 |

## Unsupported-device refusal

Record at least one device where the local provider is unavailable, to show the refusal rather than a failure.

| Field                    | Value                                                                          |
| ------------------------ | ------------------------------------------------------------------------------ |
| Device and OS            |                                                                                |
| Why it is unsupported    | for example model not present, Apple Intelligence off, no browser model        |
| Request                  | task and privacy rule                                                          |
| Outcome                  | `IndeRunError` with `errorClass`, the message, and `details.rejectedProviders` |
| Reason codes             | the codes listed per rejected provider                                         |
| Anything sent off device | confirm none, and how (network log or airplane mode)                           |

## Observations

Free text for anything the fields above do not capture. Keep it to what was seen.
