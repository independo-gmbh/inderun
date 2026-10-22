/* This file was generated from JSON Schema. Do not edit by hand. */

export const taskRequestSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/task-request.schema.json",
  "title": "TaskRequest",
  "description": "The request payload for a run() or stream() execution. The common envelope (schemaVersion, requestId, task, modelProfile, constraints, preferences, telemetry, authContextRef) is task-agnostic; each task kind owns its payload (ADR 016). text_to_text: at least one of `prompt` (single-turn) or `messages` (multi-turn) must be present — both may be present together, though callers should typically supply just one — and `speech`/`delivery` are forbidden. text_to_speech: `speech` and `delivery` are required and `prompt`, `messages` and `generation` are forbidden. `constraints`/`preferences` steer routing but never select a provider directly.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "schemaVersion",
    "task"
  ],
  "allOf": [
    {
      "if": {
        "properties": {
          "task": {
            "type": "object",
            "properties": {
              "kind": {
                "const": "text_to_text"
              }
            }
          }
        }
      },
      "then": {
        "anyOf": [
          {
            "required": [
              "prompt"
            ]
          },
          {
            "required": [
              "messages"
            ]
          }
        ],
        "not": {
          "anyOf": [
            {
              "required": [
                "speech"
              ]
            },
            {
              "required": [
                "delivery"
              ]
            }
          ]
        }
      }
    },
    {
      "if": {
        "properties": {
          "task": {
            "type": "object",
            "properties": {
              "kind": {
                "const": "text_to_speech"
              }
            }
          }
        }
      },
      "then": {
        "required": [
          "speech",
          "delivery"
        ],
        "not": {
          "anyOf": [
            {
              "required": [
                "prompt"
              ]
            },
            {
              "required": [
                "messages"
              ]
            },
            {
              "required": [
                "generation"
              ]
            }
          ]
        },
        "properties": {
          "delivery": {
            "type": "object",
            "properties": {
              "mode": {
                "enum": [
                  "playback",
                  "artifact"
                ]
              }
            }
          }
        }
      }
    }
  ],
  "properties": {
    "schemaVersion": {
      "description": "Contract schema version used to interpret the request payload.",
      "const": "1.0"
    },
    "requestId": {
      "description": "Optional identifier for tracking or correlating this specific execution attempt.",
      "type": "string",
      "minLength": 1
    },
    "task": {
      "description": "A descriptor specifying the type of work to be performed. The kind selects which payload the request must carry.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "title": "TaskKind",
          "description": "The operation: 'text_to_text' (prompt-based text generation) or 'text_to_speech' (speech synthesis from text). A consumer built against an older revision rejects a kind it does not know through validation.",
          "enum": [
            "text_to_text",
            "text_to_speech"
          ]
        }
      }
    },
    "prompt": {
      "description": "A simple, single-turn text prompt used to trigger a response from the AI model.",
      "type": "string",
      "minLength": 1
    },
    "messages": {
      "description": "A list of interaction messages for multi-turn conversation or chat-style execution.",
      "type": "array",
      "minItems": 1,
      "items": {
        "description": "An individual message in a conversation.",
        "type": "object",
        "additionalProperties": true,
        "required": [
          "role",
          "content"
        ],
        "properties": {
          "role": {
            "description": "The role of the author (e.g., 'user', 'assistant').",
            "enum": [
              "system",
              "user",
              "assistant"
            ]
          },
          "content": {
            "description": "The actual text content of the message.",
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "speech": {
      "title": "SpeechInput",
      "description": "The text_to_speech payload. Required for text_to_speech and forbidden for every other kind.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "text",
        "locale"
      ],
      "properties": {
        "text": {
          "description": "Plain text to speak. Markup such as SSML is out of scope.",
          "type": "string",
          "minLength": 1
        },
        "locale": {
          "description": "BCP 47 tag of the language to speak, e.g. 'de-AT'.",
          "type": "string",
          "minLength": 1
        },
        "localeMatch": {
          "title": "LocaleMatch",
          "description": "'language' (default): the primary language subtag is a hard requirement and the region is a preference. 'exact': the full tag is a hard requirement.",
          "enum": [
            "exact",
            "language"
          ]
        },
        "voice": {
          "title": "SpeechVoice",
          "description": "Provider-neutral voice traits. A 'preferred' voice (default) shapes which voice speaks and is never a reason to fail; a 'required' one takes part in routing and is never relaxed silently. Carries no provider voice identifier.",
          "type": "object",
          "additionalProperties": true,
          "if": {
            "properties": {
              "requirement": {
                "const": "required"
              }
            },
            "required": [
              "requirement"
            ]
          },
          "then": {
            "required": [
              "gender"
            ]
          },
          "properties": {
            "gender": {
              "$ref": "provider-dynamic-capabilities.schema.json#/$defs/voiceGender"
            },
            "requirement": {
              "title": "RequirementLevel",
              "description": "'preferred' (default) or 'required'. A required voice must name at least one trait.",
              "enum": [
                "required",
                "preferred"
              ]
            }
          }
        }
      }
    },
    "delivery": {
      "title": "OutputDeliveryRequest",
      "description": "How the result of a non-text task must reach the application (ADR 016). Required for non-text tasks and forbidden for text_to_text, whose output is implicitly inline. A provider never substitutes playback for an artifact or the reverse.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "mode"
      ],
      "if": {
        "properties": {
          "mode": {
            "const": "artifact"
          }
        }
      },
      "else": {
        "not": {
          "anyOf": [
            {
              "required": [
                "mediaTypes"
              ]
            },
            {
              "required": [
                "destinationRef"
              ]
            }
          ]
        }
      },
      "properties": {
        "mode": {
          "$ref": "provider-descriptor.schema.json#/$defs/outputDelivery"
        },
        "mediaTypes": {
          "description": "Only valid with 'artifact' delivery: the acceptable media types, always a hard requirement. Absent means the provider chooses and the artifact reports what it produced.",
          "type": "array",
          "minItems": 1,
          "uniqueItems": true,
          "items": {
            "type": "string",
            "minLength": 1
          }
        },
        "destinationRef": {
          "description": "Only valid with 'artifact' delivery: an opaque reference to an application destination the engine writes the finished artifact to, resolved by the host's artifact-destination service (ADR 017) -- never a raw path or URL, like authContextRef for credentials. The result's artifact is then application-owned and the engine keeps no copy. A host without the service refuses the request before routing.",
          "type": "string",
          "minLength": 1
        }
      }
    },
    "modelProfile": {
      "description": "Name of the model profile to route within, as configured on the engine. Absent or 'auto' means every registered target, ranked by constraints and preferences alone. A profile is an application-defined, ordered allow-list of targets (provider instances bound to one model each); raw model or provider identifiers are never accepted here. An unknown profile name fails request validation.",
      "type": "string",
      "minLength": 1
    },
    "generation": {
      "description": "Optional configuration for fine-tuning how the AI model generates its response.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "maxOutputTokens": {
          "description": "The maximum number of tokens to generate in a single response.",
          "type": "integer",
          "minimum": 1
        },
        "temperature": {
          "description": "Controls the randomness of the output. Range: 0 (most deterministic) to 2 (highest variance).",
          "type": "number",
          "minimum": 0,
          "maximum": 2
        },
        "topP": {
          "description": "Nucleus sampling parameter for controlling diversity vs focus in the output.",
          "type": "number",
          "minimum": 0,
          "maximum": 1
        },
        "seed": {
          "description": "A fixed seed for deterministic generation (where supported by the underlying provider).",
          "type": "integer"
        },
        "stop": {
          "description": "Sequence tokens that should terminate the generation process.",
          "type": "array",
          "items": {
            "type": "string"
          }
        }
      }
    },
    "constraints": {
      "description": "Request-level routing constraints used by the planner.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "privacy": {
          "description": "Privacy requirement or preference for execution placement.",
          "enum": [
            "local_required",
            "local_preferred",
            "cloud_allowed",
            "cloud_required"
          ]
        },
        "cloud": {
          "description": "Cloud execution constraint.",
          "enum": [
            "forbidden",
            "allowed",
            "required"
          ]
        },
        "timeoutMs": {
          "description": "Optional timeout budget in milliseconds, passed to the planner and to providers. It bounds the time until the run commits to a provider -- its first content, its first possible audible effect, or its artifact handoff -- not the duration of audio it plays. The engines add no timers of their own.",
          "type": "integer",
          "minimum": 1
        }
      }
    },
    "preferences": {
      "description": "Soft routing preferences used for deterministic provider ordering.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "optimizeFor": {
          "description": "Primary optimization goal when multiple providers remain eligible.",
          "enum": [
            "privacy",
            "latency",
            "cost",
            "balanced"
          ]
        }
      }
    },
    "telemetry": {
      "description": "Execution preferences for tracking usage and performance metrics.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "consent": {
          "description": "Whether the user consents to telemetry collection for this specific request.",
          "type": "boolean"
        },
        "level": {
          "description": "The granularity of the collected metrics (off, minimal, or debug).",
          "enum": [
            "off",
            "minimal",
            "debug"
          ]
        },
        "tags": {
          "description": "Optional key-value pairs for correlating telemetry data with specific features or users.",
          "type": "object",
          "additionalProperties": {
            "type": "string"
          }
        }
      }
    },
    "authContextRef": {
      "description": "A unique identifier used to retrieve credentials from a secure local storage. Raw sensitive keys (API keys, etc.) should NEVER be placed directly in the request payload.",
      "type": "string",
      "minLength": 1
    }
  }
} as const;

export const taskResultSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/task-result.schema.json",
  "title": "TaskResult",
  "description": "The response payload for a completed run() execution, for every task kind; output.type tells the content representation apart (text, managed playback, retrievable artifact). A full execution failure (validation, routing, or every attempted provider failing) is surfaced by run() throwing an IndeRunError instead of returning a TaskResult; finishReason and telemetry.errorClass are reserved for a provider reporting a non-fatal, degraded outcome on an otherwise-successful result (finishReason 'error' is produced by the Android ML Kit GenAI provider; telemetry.errorClass is not currently set by any provider in this codebase).",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "schemaVersion",
    "runId",
    "output",
    "finishReason",
    "telemetry"
  ],
  "properties": {
    "schemaVersion": {
      "description": "Contract schema version used to interpret the result payload.",
      "const": "1.0"
    },
    "runId": {
      "description": "A unique, opaque identifier assigned by the engine for this specific execution attempt.",
      "type": "string",
      "minLength": 1
    },
    "output": {
      "description": "The normalized output of the selected provider. See task-output.schema.json.",
      "$ref": "task-output.schema.json"
    },
    "finishReason": {
      "description": "How generation ended: 'stop' (natural end), 'length' (hit maxOutputTokens), or 'cancelled'. 'error' is reserved for a provider reporting a non-fatal issue on an otherwise-returned result — the Android ML Kit GenAI provider produces it when Gemini Nano reports a finish reason that is neither a natural stop nor the token limit. A full execution failure is instead surfaced by run() throwing an IndeRunError.",
      "enum": [
        "stop",
        "length",
        "cancelled",
        "error"
      ]
    },
    "usage": {
      "description": "Optional metadata regarding the quantity of tokens processed by the provider.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "inputTokens": {
          "description": "Number of input tokens consumed, as reported by the provider.",
          "type": "integer",
          "minimum": 0
        },
        "outputTokens": {
          "description": "Number of output tokens generated, as reported by the provider.",
          "type": "integer",
          "minimum": 0
        },
        "totalTokens": {
          "description": "Aggregated token count for this request, as reported by the provider.",
          "type": "integer",
          "minimum": 0
        }
      }
    },
    "telemetry": {
      "description": "Required metadata providing an overview of the execution result and performance metrics.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "providerUsed",
        "totalMs"
      ],
      "properties": {
        "providerUsed": {
          "description": "The identifier for the specific provider that handled the request (e.g., 'openai_compatible_cloud').",
          "type": "string",
          "minLength": 1
        },
        "reportedModel": {
          "description": "The model identifier the provider reported in its own response, set by the provider when its backend reports one. The engine carries it into provenance.reportedModel; it is never inferred from configuration.",
          "type": "string",
          "minLength": 1
        },
        "totalMs": {
          "description": "Measured execution duration in milliseconds, including route selection and result processing.",
          "type": "number",
          "minimum": 0
        },
        "errorClass": {
          "description": "Present only if a provider reports a degraded outcome on an otherwise-successful result; no provider in this codebase currently sets this. Distinct from run() throwing — a thrown IndeRunError never produces a TaskResult at all.",
          "enum": [
            "CapabilityMismatch",
            "Offline",
            "AuthError",
            "RateLimited",
            "Timeout",
            "Unavailable",
            "Internal"
          ]
        }
      }
    },
    "provenance": {
      "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
      "$ref": "execution-provenance.schema.json"
    }
  }
} as const;

export const inderunErrorSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/inderun-error.schema.json",
  "title": "IndeRunError",
  "description": "The error shape thrown by run() (wrapped in an IndeRunException) when execution fails — via validation, routing (no eligible provider), or every attempted provider failing. Never returned as part of a successful TaskResult.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "schemaVersion",
    "errorClass",
    "message"
  ],
  "properties": {
    "schemaVersion": {
      "description": "Contract schema version used to interpret the error payload.",
      "const": "1.0"
    },
    "errorClass": {
      "description": "Normalized error taxonomy, shared with TaskResult.telemetry.errorClass: CapabilityMismatch (request needs something no eligible provider supports), Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider throttled the request), Timeout (provider exceeded its execution budget), Internal (unexpected engine-side failure).",
      "enum": [
        "CapabilityMismatch",
        "Offline",
        "AuthError",
        "RateLimited",
        "Timeout",
        "Unavailable",
        "Internal"
      ]
    },
    "message": {
      "description": "Human-readable error message suitable for logs and developer diagnostics.",
      "type": "string",
      "minLength": 1
    },
    "runId": {
      "description": "Opaque run identifier associated with the failed execution, if available.",
      "type": "string",
      "minLength": 1
    },
    "providerId": {
      "description": "Identifier of the provider associated with the failure, if execution reached a provider.",
      "type": "string",
      "minLength": 1
    },
    "retryable": {
      "description": "Whether retrying the same request may succeed.",
      "type": "boolean"
    },
    "retryAfterMs": {
      "description": "Optional suggested delay before retrying, in milliseconds.",
      "type": "integer",
      "minimum": 0
    },
    "details": {
      "description": "Optional structured diagnostic details. It must not contain raw secrets.",
      "type": "object",
      "additionalProperties": true
    },
    "provenance": {
      "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
      "$ref": "execution-provenance.schema.json"
    }
  }
} as const;

export const httpRequestSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/http-request.schema.json",
  "title": "HttpRequest",
  "description": "Normalized HTTP request payload for host-provided cloud transport.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "method",
    "url"
  ],
  "properties": {
    "method": {
      "description": "HTTP method to use for the request.",
      "enum": [
        "GET",
        "POST",
        "PUT",
        "DELETE",
        "PATCH"
      ]
    },
    "url": {
      "description": "Absolute target URL for the provider transport request.",
      "type": "string",
      "minLength": 1
    },
    "headers": {
      "description": "HTTP headers to send after the provider adapter has applied any required transport-level credentials.",
      "type": "object",
      "additionalProperties": {
        "type": "string"
      }
    },
    "body": {
      "description": "Optional serialized request body. For JSON APIs this should be a JSON string.",
      "type": "string"
    },
    "timeoutMs": {
      "description": "Optional maximum duration for the host transport attempt in milliseconds.",
      "type": "integer",
      "minimum": 1
    }
  }
} as const;

export const httpResponseSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/http-response.schema.json",
  "title": "HttpResponse",
  "description": "Normalized HTTP response payload returned by host-provided cloud transport.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "status",
    "statusText",
    "headers",
    "body"
  ],
  "properties": {
    "status": {
      "description": "HTTP status code returned by the provider transport.",
      "type": "integer",
      "minimum": 100,
      "maximum": 599
    },
    "statusText": {
      "description": "HTTP status text returned by the provider transport.",
      "type": "string"
    },
    "headers": {
      "description": "HTTP response headers normalized to string key-value pairs.",
      "type": "object",
      "additionalProperties": {
        "type": "string"
      }
    },
    "body": {
      "description": "Serialized response body returned by the provider transport.",
      "type": "string"
    }
  }
} as const;

export const telemetryEventSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/telemetry-event.schema.json",
  "title": "TelemetryEvent",
  "description": "Normalized telemetry event emitted by the orchestrator and providers.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "type",
    "runId",
    "timestamp",
    "payload"
  ],
  "properties": {
    "type": {
      "title": "TelemetryEventType",
      "description": "Telemetry event kind emitted by the orchestrator or provider integration.",
      "enum": [
        "route_decided",
        "attempt_succeeded",
        "attempt_failed",
        "stream_attempt_started",
        "stream_attempt_succeeded",
        "stream_attempt_failed",
        "stream_completed",
        "stream_failed",
        "stream_cancelled"
      ]
    },
    "runId": {
      "description": "Opaque run identifier associated with this execution event.",
      "type": "string",
      "minLength": 1
    },
    "timestamp": {
      "description": "Wall-clock event timestamp in Unix epoch milliseconds.",
      "type": "number",
      "minimum": 0
    },
    "payload": {
      "description": "Event-specific metadata. It must not contain prompt payloads or raw secrets.",
      "type": "object",
      "additionalProperties": true
    }
  }
} as const;

export const routePlannerInputSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/route-planner-input.schema.json",
  "title": "RoutePlannerInput",
  "description": "Pure data input contract for deterministic shared-core route planning.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "task",
    "constraints",
    "preferences",
    "providers"
  ],
  "properties": {
    "task": {
      "description": "Task descriptor for provider task matching: the kind plus the requirements routing can check against declared capabilities. Absent requirement fields are never checked, so a text request carries the kind alone.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "description": "The task kind, matched against the providers' task capabilities.",
          "type": "string",
          "minLength": 1
        },
        "inputs": {
          "description": "Input media kinds the request carries. Every one must be accepted by the provider's task capability. The SDKs send ['text'] for text_to_text.",
          "type": "array",
          "items": {
            "$ref": "provider-descriptor.schema.json#/$defs/inputKind"
          }
        },
        "delivery": {
          "title": "DeliveryRequirement",
          "description": "The output delivery the request requires. Absent for text, whose delivery is implicitly inline.",
          "type": "object",
          "additionalProperties": true,
          "required": [
            "mode"
          ],
          "properties": {
            "mode": {
              "$ref": "provider-descriptor.schema.json#/$defs/outputDelivery"
            },
            "mediaTypes": {
              "description": "Acceptable media types; the provider must declare at least one for the requested delivery. Absent means any.",
              "type": "array",
              "items": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        "locale": {
          "title": "LocaleRequirement",
          "description": "The locale the request requires. Under 'language' matching the region is a preference: a provider known to offer the exact tag ranks ahead of an otherwise equal one. A provider that cannot enumerate its locales is not rejected on this basis; it must fail before committing instead.",
          "type": "object",
          "additionalProperties": true,
          "required": [
            "tag",
            "match"
          ],
          "properties": {
            "tag": {
              "description": "BCP 47 tag.",
              "type": "string",
              "minLength": 1
            },
            "match": {
              "title": "LocaleMatch",
              "description": "'exact' requires the full tag; 'language' requires only the primary language subtag and treats the region as a preference.",
              "enum": [
                "exact",
                "language"
              ]
            }
          }
        },
        "voice": {
          "title": "VoiceRequirement",
          "description": "Voice traits the request asks for. Only a 'required' voice can reject a provider; a 'preferred' one shapes which listed voice the plan binds a candidate to, always within the request's privacy policy.",
          "type": "object",
          "additionalProperties": true,
          "required": [
            "requirement"
          ],
          "properties": {
            "gender": {
              "$ref": "provider-dynamic-capabilities.schema.json#/$defs/voiceGender"
            },
            "requirement": {
              "title": "RequirementLevel",
              "description": "'required' takes part in routing; 'preferred' does not.",
              "enum": [
                "required",
                "preferred"
              ]
            }
          }
        }
      }
    },
    "interactionMode": {
      "description": "Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs produced before this field existed keep their exact Mode-1 semantics. The mode filters eligible providers; it never changes candidate ordering.",
      "enum": [
        "run",
        "stream"
      ]
    },
    "constraints": {
      "description": "Hard routing constraints evaluated before provider selection.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "privacy": {
          "description": "Privacy requirement or preference for execution placement.",
          "enum": [
            "local_required",
            "local_preferred",
            "cloud_allowed",
            "cloud_required"
          ]
        },
        "cloud": {
          "description": "Cloud execution constraint.",
          "enum": [
            "forbidden",
            "allowed",
            "required"
          ]
        },
        "networkOnline": {
          "description": "Current connectivity snapshot used for cloud route planning.",
          "type": "boolean"
        }
      }
    },
    "preferences": {
      "description": "Soft route ordering preferences applied after hard filtering.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "optimizeFor": {
          "description": "Primary optimization goal when multiple providers remain eligible.",
          "enum": [
            "privacy",
            "latency",
            "cost",
            "balanced"
          ]
        }
      }
    },
    "modelProfile": {
      "description": "The resolved model profile the request routes within. Absent means the built-in 'auto' profile: no allow-list, and ordering by placement and preference alone. When present, providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the position in targetIds ranks the survivors after placement and before preferences. Ids that name no registered provider are ignored.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "name",
        "targetIds"
      ],
      "properties": {
        "name": {
          "description": "Profile name, carried for explanations.",
          "type": "string",
          "minLength": 1
        },
        "targetIds": {
          "description": "Provider ids in profile order.",
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "providers": {
      "description": "Static descriptors plus dynamic capability checks for planning. Both shapes are the provider schemas themselves, shared by $ref, so the planner reads exactly what checkCapabilities() reports.",
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "descriptor",
          "capabilities"
        ],
        "properties": {
          "descriptor": {
            "description": "The provider's static capability declaration.",
            "$ref": "provider-descriptor.schema.json"
          },
          "capabilities": {
            "description": "The provider's live capability check, already folded by the engine (for example, streamingAvailable is false when the provider declares streaming but does not implement it).",
            "$ref": "provider-dynamic-capabilities.schema.json"
          }
        }
      }
    }
  }
} as const;

export const routePlanSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/route-plan.schema.json",
  "title": "RoutePlan",
  "description": "Deterministic shared-core Mode-1 route planning result.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "fallbackProviderIds",
    "candidates",
    "rejectedProviders",
    "explanation"
  ],
  "properties": {
    "selectedProviderId": {
      "description": "Chosen primary provider ID, if any.",
      "type": "string",
      "minLength": 1
    },
    "fallbackProviderIds": {
      "description": "Fallback provider IDs ordered after the primary selection.",
      "type": "array",
      "items": {
        "type": "string",
        "minLength": 1
      }
    },
    "candidates": {
      "description": "Eligible candidates in deterministic order.",
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "providerId",
          "order"
        ],
        "properties": {
          "providerId": {
            "type": "string",
            "minLength": 1
          },
          "order": {
            "type": "integer",
            "minimum": 0
          },
          "voice": {
            "description": "The voice this candidate must use if it is attempted, chosen by the planner from the provider's dynamic voice inventory. It is the best voice that satisfies the request's locale, required voice traits and privacy — under local-required privacy always one that keeps data on the device — ranked by preferred gender, then exact locale region, then on-device before network. The adapter must use a voice with exactly these traits. Absent when the request names no locale or voice, or the provider does not list its voices; the adapter then chooses itself under the same rules.",
            "$ref": "provider-dynamic-capabilities.schema.json#/$defs/voice"
          }
        }
      }
    },
    "rejectedProviders": {
      "description": "Providers filtered out during planning together with machine-readable reasons.",
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "providerId",
          "reasons"
        ],
        "properties": {
          "providerId": {
            "type": "string",
            "minLength": 1
          },
          "reasons": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": true,
              "required": [
                "code",
                "message"
              ],
              "properties": {
                "code": {
                  "description": "Normalized rejection reason. 'streaming_not_supported' means the descriptor does not statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming but the dynamic capability snapshot reports it cannot stream in the current host environment. 'not_in_model_profile' means the request named a model profile that does not list this provider. 'input_not_supported', 'output_delivery_not_supported', 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the provider's task capability lacks an input kind, output delivery, media type, locale or voice the request requires.",
                  "enum": [
                    "task_not_supported",
                    "run_not_supported",
                    "streaming_not_supported",
                    "streaming_unavailable",
                    "privacy_constraint",
                    "cloud_constraint",
                    "offline",
                    "capability_unavailable",
                    "not_in_model_profile",
                    "input_not_supported",
                    "output_delivery_not_supported",
                    "output_format_not_supported",
                    "locale_not_supported",
                    "voice_not_available"
                  ]
                },
                "message": {
                  "type": "string",
                  "minLength": 1
                }
              }
            }
          }
        }
      }
    },
    "failureCode": {
      "description": "Normalized routing failure class when no provider is selected.",
      "enum": [
        "capability_mismatch",
        "offline",
        "unavailable"
      ]
    },
    "explanation": {
      "description": "Human-readable selection or failure explanation suitable for telemetry/debugging.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "summary"
      ],
      "properties": {
        "summary": {
          "type": "string",
          "minLength": 1
        },
        "selectedProviderId": {
          "type": "string",
          "minLength": 1
        }
      }
    }
  }
} as const;

export const modelPackageSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/model-package.schema.json",
  "title": "ModelPackage",
  "description": "Provider-neutral descriptor for a developer-supplied/custom local model made available to an IndeRun local-model provider family (for example, the ONNX Runtime family). It describes model identity, format, task support, source, files, integrity, licensing, and resource expectations. It is bootstrap/configuration metadata resolved before execution; it is not part of the public TaskRequest/TaskResult surface, and it must not carry raw secrets.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "id",
    "format"
  ],
  "properties": {
    "id": {
      "description": "Stable application-scoped identifier for the model package.",
      "type": "string",
      "minLength": 1
    },
    "version": {
      "description": "Optional application-defined version for the model package, used for cache invalidation and compatibility checks.",
      "type": "string",
      "minLength": 1
    },
    "format": {
      "description": "Model packaging format the target runtime family must understand. 'onnx' is a plain ONNX graph, 'ort' is an ONNX Runtime optimized/mobile format, 'genai' is an ONNX Runtime GenAI model package.",
      "enum": [
        "onnx",
        "ort",
        "genai"
      ]
    },
    "tasks": {
      "description": "IndeRun task kinds this model package can serve (for example 'text_to_text'). Used by dynamic capability checks and route matching.",
      "type": "array",
      "items": {
        "type": "string",
        "minLength": 1
      }
    },
    "runtime": {
      "description": "Optional runtime compatibility expectations. Fields are advisory hints for capability checks; the provider adapter owns exact enforcement.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "minOpset": {
          "description": "Minimum ONNX opset version the model requires, where known.",
          "type": "integer",
          "minimum": 1
        },
        "minRuntimeVersion": {
          "description": "Minimum runtime package version required to load the model, where known.",
          "type": "string",
          "minLength": 1
        },
        "platforms": {
          "description": "Platforms the package is expected to run on (for example 'web', 'android', 'apple'). Absence means unconstrained.",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "files": {
      "description": "Files that make up the model package, expressed as source-relative names/paths. The provider adapter and model source resolve these to concrete bytes per platform.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "required": {
          "description": "Files that must be present for the package to load (for example the model graph).",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
        },
        "tokenizer": {
          "description": "Optional tokenizer file, where the model requires one.",
          "type": "string",
          "minLength": 1
        },
        "config": {
          "description": "Optional model/generation config file, where the model requires one.",
          "type": "string",
          "minLength": 1
        },
        "external": {
          "description": "Optional external data files referenced by the model graph (for example ONNX external weights).",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "integrity": {
      "description": "Optional integrity metadata used to validate resolved files before load.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "checksums": {
          "description": "Map of file name to expected checksum (for example 'sha256:...'). Absence means integrity is not verified by IndeRun.",
          "type": "object",
          "additionalProperties": {
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "license": {
      "description": "Optional license/source metadata for the model, for developer transparency. Free-form.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "spdx": {
          "description": "SPDX license identifier where known (for example 'Apache-2.0').",
          "type": "string",
          "minLength": 1
        },
        "url": {
          "description": "License or model card URL where available.",
          "type": "string",
          "minLength": 1
        }
      }
    },
    "source": {
      "description": "Where the model files are obtained from. Availability of each source type is platform-dependent; see the ONNX Runtime provider-family specification for the per-platform support matrix.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "sourceType"
      ],
      "properties": {
        "sourceType": {
          "description": "Discriminator for how the host makes model files available. 'registry' is a web repository/registry reference (for example a Hugging Face-style repo), 'bundled' is an app asset/resource, 'programmatic' is supplied directly by application code, 'filesystem' is a local path where the platform allows it, 'app_managed' is an app-managed cache/storage location, 'remote' is a host-managed download.",
          "enum": [
            "registry",
            "bundled",
            "programmatic",
            "filesystem",
            "app_managed",
            "remote"
          ]
        },
        "ref": {
          "description": "Optional source-specific reference (for example a registry repo id or a bundled asset base path). Interpretation depends on 'sourceType'. Must not contain credentials: URL userinfo (for example 'https://user:pass@host/...') is rejected, and credentials must be supplied via authContextRef instead.",
          "type": "string",
          "minLength": 1,
          "pattern": "^(?![\\s\\S]*://[^/@]*@)[\\s\\S]*$"
        }
      }
    },
    "limits": {
      "description": "Optional known resource expectations, used by capability checks to reject on constrained devices before load.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "diskBytes": {
          "description": "Approximate on-disk size of the resolved package, where known.",
          "type": "integer",
          "minimum": 0
        },
        "memBytes": {
          "description": "Approximate peak memory required to run the model, where known.",
          "type": "integer",
          "minimum": 0
        }
      }
    }
  }
} as const;

export const streamRunSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/stream-run.schema.json",
  "title": "StreamRunHandle",
  "description": "The serializable acknowledgment returned when a Mode 2 stream is opened, before any StreamEvent has arrived. This is the identity/correlation contract only: the live, consumable stream itself is a platform-idiomatic construct (an AsyncIterable<StreamEvent> in TypeScript, a Flow<StreamEvent> in Kotlin, an AsyncThrowingStream<StreamEvent, Error> in Swift) that is never serialized and is out of scope for this schema. Design seam only; no engine or provider implementation exists yet (see docs/architecture/architecture.md).",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "schemaVersion",
    "runId",
    "startedAt"
  ],
  "properties": {
    "schemaVersion": {
      "description": "Contract schema version used to interpret this handle payload.",
      "const": "1.0"
    },
    "runId": {
      "description": "A unique, opaque identifier assigned by the engine for this stream run. Every StreamEvent and the terminal StreamTerminalOutcome for this run carry the same runId, matching the identity convention used by TaskResult.runId and IndeRunError.runId.",
      "type": "string",
      "minLength": 1
    },
    "startedAt": {
      "description": "Wall-clock time the stream run was opened, in Unix epoch milliseconds.",
      "type": "number",
      "minimum": 0
    },
    "providerId": {
      "description": "Identifier of the provider selected to service this stream, if routing has completed by the time the handle is returned. Absent while route selection is still pending.",
      "type": "string",
      "minLength": 1
    }
  }
} as const;

export const streamEventSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/stream-event.schema.json",
  "title": "StreamEvent",
  "description": "The canonical Mode 2 streaming event union, discriminated by 'type'. Every variant shares an envelope of schemaVersion, runId, sequence, timestamp, and type. 'sequence' is the ordering authority for events within a run (a monotonically increasing integer starting at 0 per runId) — consumers must order by 'sequence', not by arrival order, since a bridge hop (e.g. a future Capacitor bridge) could reorder delivery. Known event types are split into user-visible content ('content_delta', 'content_snapshot') and mechanical/diagnostic types ('lifecycle', 'diagnostic', 'terminal') so SDKs can distinguish what belongs in a chat UI from what is orchestration detail. Forward compatibility: this union closes with an open 'unknown_event' branch so a consumer built against an older revision of this schema does not hard-fail when a newer, additive minor revision introduces a new known type; per contracts/README.md's schema evolution policy, SDKs must treat an unrecognized 'type' as ignore-or-pass-through-for-diagnostics, never as a hard error. All three engines implement this union (see docs/architecture/architecture.md).",
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "sequence",
        "timestamp",
        "type",
        "payload"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this event payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "Opaque run identifier this event belongs to, matching StreamRunHandle.runId.",
          "type": "string",
          "minLength": 1
        },
        "sequence": {
          "description": "Zero-based, monotonically increasing event index within this run. The ordering authority; do not rely on delivery/arrival order.",
          "type": "integer",
          "minimum": 0
        },
        "timestamp": {
          "description": "Wall-clock event timestamp in Unix epoch milliseconds.",
          "type": "number",
          "minimum": 0
        },
        "type": {
          "description": "User-visible content: an incremental text increment since the previous content_delta or content_snapshot event. Mirrors ProviderDescriptor.streamingStyle 'tokens'/'chunks' (packages/inderun-web/src/core/provider.ts) — providers reporting either style normalize to content_delta.",
          "const": "content_delta"
        },
        "payload": {
          "type": "object",
          "additionalProperties": true,
          "required": [
            "text"
          ],
          "properties": {
            "text": {
              "description": "The incremental text produced since the previous content event.",
              "type": "string"
            }
          }
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "sequence",
        "timestamp",
        "type",
        "payload"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this event payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "Opaque run identifier this event belongs to, matching StreamRunHandle.runId.",
          "type": "string",
          "minLength": 1
        },
        "sequence": {
          "description": "Zero-based, monotonically increasing event index within this run. The ordering authority; do not rely on delivery/arrival order.",
          "type": "integer",
          "minimum": 0
        },
        "timestamp": {
          "description": "Wall-clock event timestamp in Unix epoch milliseconds.",
          "type": "number",
          "minimum": 0
        },
        "type": {
          "description": "User-visible content: the full cumulative text produced so far. Mirrors ProviderDescriptor.streamingStyle 'snapshots' (packages/inderun-web/src/core/provider.ts) — providers reporting that style normalize to content_snapshot rather than content_delta. Retraction: a provider of any streamingStyle may additionally emit a content_snapshot to withdraw content it has already delivered, since a snapshot replaces the run's cumulative text rather than appending to it; an empty one therefore resets that text to nothing. This is how a provider whose backend rejects an in-flight response after partial delivery — an on-device safety/policy check, for example — tells consumers to discard what they have, so a consumer must handle content_snapshot even when the provider's declared style is 'tokens' or 'chunks'.",
          "const": "content_snapshot"
        },
        "payload": {
          "type": "object",
          "additionalProperties": true,
          "required": [
            "text"
          ],
          "properties": {
            "text": {
              "description": "The full cumulative text produced by the run so far.",
              "type": "string"
            }
          }
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "sequence",
        "timestamp",
        "type",
        "payload"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this event payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "Opaque run identifier this event belongs to, matching StreamRunHandle.runId.",
          "type": "string",
          "minLength": 1
        },
        "sequence": {
          "description": "Zero-based, monotonically increasing event index within this run. The ordering authority; do not rely on delivery/arrival order.",
          "type": "integer",
          "minimum": 0
        },
        "timestamp": {
          "description": "Wall-clock event timestamp in Unix epoch milliseconds.",
          "type": "number",
          "minimum": 0
        },
        "type": {
          "description": "Mechanical/diagnostic: a run lifecycle transition (e.g. provider selection, execution start). Not user-visible content; not part of the generated text.",
          "const": "lifecycle"
        },
        "payload": {
          "type": "object",
          "additionalProperties": true,
          "required": [
            "phase"
          ],
          "properties": {
            "phase": {
              "description": "The lifecycle phase reached.",
              "enum": [
                "provider_selected",
                "started"
              ]
            }
          }
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "sequence",
        "timestamp",
        "type",
        "payload"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this event payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "Opaque run identifier this event belongs to, matching StreamRunHandle.runId.",
          "type": "string",
          "minLength": 1
        },
        "sequence": {
          "description": "Zero-based, monotonically increasing event index within this run. The ordering authority; do not rely on delivery/arrival order.",
          "type": "integer",
          "minimum": 0
        },
        "timestamp": {
          "description": "Wall-clock event timestamp in Unix epoch milliseconds.",
          "type": "number",
          "minimum": 0
        },
        "type": {
          "description": "Mechanical/diagnostic: free-form orchestration or provider diagnostic detail. Not user-visible content.",
          "const": "diagnostic"
        },
        "payload": {
          "description": "Event-specific diagnostic metadata. It must not contain prompt payloads or raw secrets, matching the same guardrail as TelemetryEvent.payload.",
          "type": "object",
          "additionalProperties": true
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "sequence",
        "timestamp",
        "type",
        "payload"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this event payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "Opaque run identifier this event belongs to, matching StreamRunHandle.runId.",
          "type": "string",
          "minLength": 1
        },
        "sequence": {
          "description": "Zero-based, monotonically increasing event index within this run. This is always the highest sequence number for the run: the terminal event.",
          "type": "integer",
          "minimum": 0
        },
        "timestamp": {
          "description": "Wall-clock event timestamp in Unix epoch milliseconds.",
          "type": "number",
          "minimum": 0
        },
        "type": {
          "description": "Terminal: the last event of the run, carrying the mutually-exclusive completion/error/cancellation outcome. No further StreamEvent is delivered for this runId after this event.",
          "const": "terminal"
        },
        "payload": {
          "description": "Structurally identical to StreamTerminalOutcome (contracts/schemas/stream-terminal-outcome.schema.json), duplicated by value here rather than by $ref, matching this repo's schema convention of no cross-file references. Keep both shapes in sync; a cross-check test asserts a shared fixture validates against both schemas.",
          "oneOf": [
            {
              "type": "object",
              "additionalProperties": true,
              "required": [
                "schemaVersion",
                "runId",
                "outcome"
              ],
              "anyOf": [
                {
                  "required": [
                    "finalText"
                  ]
                },
                {
                  "required": [
                    "output"
                  ]
                }
              ],
              "properties": {
                "schemaVersion": {
                  "const": "1.0"
                },
                "runId": {
                  "type": "string",
                  "minLength": 1
                },
                "outcome": {
                  "const": "completed"
                },
                "finalText": {
                  "type": "string"
                },
                "output": {
                  "$ref": "task-output.schema.json"
                },
                "finishReason": {
                  "enum": [
                    "stop",
                    "length",
                    "cancelled",
                    "error"
                  ]
                },
                "usage": {
                  "type": "object",
                  "additionalProperties": true,
                  "properties": {
                    "inputTokens": {
                      "type": "integer",
                      "minimum": 0
                    },
                    "outputTokens": {
                      "type": "integer",
                      "minimum": 0
                    },
                    "totalTokens": {
                      "type": "integer",
                      "minimum": 0
                    }
                  }
                },
                "telemetry": {
                  "type": "object",
                  "additionalProperties": true,
                  "required": [
                    "providerUsed",
                    "totalMs"
                  ],
                  "properties": {
                    "providerUsed": {
                      "type": "string",
                      "minLength": 1
                    },
                    "totalMs": {
                      "type": "number",
                      "minimum": 0
                    }
                  }
                },
                "provenance": {
                  "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
                  "$ref": "execution-provenance.schema.json"
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": true,
              "required": [
                "schemaVersion",
                "runId",
                "outcome",
                "error"
              ],
              "properties": {
                "schemaVersion": {
                  "const": "1.0"
                },
                "runId": {
                  "type": "string",
                  "minLength": 1
                },
                "outcome": {
                  "const": "error"
                },
                "partialText": {
                  "type": "string"
                },
                "error": {
                  "type": "object",
                  "additionalProperties": true,
                  "required": [
                    "schemaVersion",
                    "errorClass",
                    "message"
                  ],
                  "properties": {
                    "schemaVersion": {
                      "const": "1.0"
                    },
                    "errorClass": {
                      "enum": [
                        "CapabilityMismatch",
                        "Offline",
                        "AuthError",
                        "RateLimited",
                        "Timeout",
                        "Unavailable",
                        "Internal"
                      ]
                    },
                    "message": {
                      "type": "string",
                      "minLength": 1
                    },
                    "providerId": {
                      "type": "string",
                      "minLength": 1
                    },
                    "retryable": {
                      "type": "boolean"
                    },
                    "retryAfterMs": {
                      "type": "integer",
                      "minimum": 0
                    },
                    "details": {
                      "type": "object",
                      "additionalProperties": true
                    },
                    "provenance": {
                      "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
                      "$ref": "execution-provenance.schema.json"
                    }
                  }
                },
                "provenance": {
                  "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
                  "$ref": "execution-provenance.schema.json"
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": true,
              "required": [
                "schemaVersion",
                "runId",
                "outcome"
              ],
              "properties": {
                "schemaVersion": {
                  "const": "1.0"
                },
                "runId": {
                  "type": "string",
                  "minLength": 1
                },
                "outcome": {
                  "const": "cancelled"
                },
                "partialText": {
                  "type": "string"
                },
                "output": {
                  "$ref": "task-output.schema.json"
                },
                "reason": {
                  "type": "string"
                },
                "provenance": {
                  "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
                  "$ref": "execution-provenance.schema.json"
                }
              }
            }
          ]
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "sequence",
        "timestamp",
        "type"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this event payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "Opaque run identifier this event belongs to, matching StreamRunHandle.runId.",
          "type": "string",
          "minLength": 1
        },
        "sequence": {
          "description": "Zero-based, monotonically increasing event index within this run. The ordering authority; do not rely on delivery/arrival order.",
          "type": "integer",
          "minimum": 0
        },
        "timestamp": {
          "description": "Wall-clock event timestamp in Unix epoch milliseconds.",
          "type": "number",
          "minimum": 0
        },
        "type": {
          "description": "Forward-compatibility catch-all: any event type not among the known constants above. Exists so a consumer validating against this revision of the schema does not hard-fail when a future additive revision introduces a new known event type; SDKs must ignore or pass through such events for diagnostics rather than treating them as an error.",
          "type": "string",
          "not": {
            "enum": [
              "content_delta",
              "content_snapshot",
              "lifecycle",
              "diagnostic",
              "terminal"
            ]
          }
        },
        "payload": {
          "description": "Optional event-specific payload for the unrecognized type. It must not contain prompt payloads or raw secrets.",
          "type": "object",
          "additionalProperties": true
        }
      }
    }
  ]
} as const;

export const streamTerminalOutcomeSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/stream-terminal-outcome.schema.json",
  "title": "StreamTerminalOutcome",
  "description": "How a Mode 2 stream run ended. Completion, error, and cancellation are mutually exclusive terminal outcomes, enforced here as a closed set of three oneOf branches discriminated by 'outcome' (unlike StreamEvent.type, this set is not open-ended: the three-way terminal outcome is a fixed architectural guarantee, not something new outcome kinds get added to; the payload of each branch may grow additively). Exactly one StreamTerminalOutcome is produced per run, and no further StreamEvent is delivered after it (see docs/architecture/architecture.md, 'Cancellation And Fallback'). This shape is also embedded by value as the payload of the terminal StreamEvent (stream-event.schema.json) so it can additionally be exposed standalone, e.g. as a completion future/promise a stream handle resolves independently of consuming the full event sequence; the two copies must stay structurally identical. Note on additionalProperties: per this repo's forward-compatible convention every branch permits unknown extra fields, so mutual exclusivity is enforced via the required 'outcome' discriminator plus each branch's own required peer field being present (finalText or output / error), and for 'cancelled' by the discriminator alone, not by forbidding a payload from also carrying an unrelated stray field from another branch's vocabulary.",
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "outcome"
      ],
      "anyOf": [
        {
          "required": [
            "finalText"
          ]
        },
        {
          "required": [
            "output"
          ]
        }
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this outcome payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "The stream run this outcome terminates, matching StreamRunHandle.runId and every StreamEvent.runId for the run.",
          "type": "string",
          "minLength": 1
        },
        "outcome": {
          "description": "The stream completed normally: every provider-generated event was delivered before this outcome was produced.",
          "const": "completed"
        },
        "finalText": {
          "description": "The full, cumulative text produced by a text run. Equivalent in role to TaskResult.output.text for Mode 1. A text run sets it; a non-text run carries output instead.",
          "type": "string"
        },
        "output": {
          "description": "The normalized output of the run, the same shape run() returns in TaskResult.output. Set for every non-text run; a text run may set it alongside finalText. See task-output.schema.json.",
          "$ref": "task-output.schema.json"
        },
        "finishReason": {
          "description": "How generation ended, mirroring TaskResult.finishReason for Mode 1: 'stop' (natural end), 'length' (hit maxOutputTokens), 'error' (provider reported a non-fatal issue on an otherwise completed run). 'cancelled' is included so this enum stays identical to TaskResult.finishReason, but it is unreachable here: cancellation is its own terminal outcome branch. Optional: providers that do not report a finish reason omit it.",
          "enum": [
            "stop",
            "length",
            "cancelled",
            "error"
          ]
        },
        "usage": {
          "description": "Optional metadata regarding the quantity of tokens processed by the provider. Same shape as TaskResult.usage.",
          "type": "object",
          "additionalProperties": true,
          "properties": {
            "inputTokens": {
              "description": "Number of input tokens consumed, as reported by the provider.",
              "type": "integer",
              "minimum": 0
            },
            "outputTokens": {
              "description": "Number of output tokens generated, as reported by the provider.",
              "type": "integer",
              "minimum": 0
            },
            "totalTokens": {
              "description": "Aggregated token count for this request, as reported by the provider.",
              "type": "integer",
              "minimum": 0
            }
          }
        },
        "telemetry": {
          "description": "Required metadata providing an overview of the execution result and performance metrics. Same shape as TaskResult.telemetry.",
          "type": "object",
          "additionalProperties": true,
          "required": [
            "providerUsed",
            "totalMs"
          ],
          "properties": {
            "providerUsed": {
              "description": "The identifier for the specific provider that handled the request (e.g., 'openai_compatible_cloud').",
              "type": "string",
              "minLength": 1
            },
            "totalMs": {
              "description": "Measured execution duration in milliseconds, including route selection and result processing.",
              "type": "number",
              "minimum": 0
            }
          }
        },
        "provenance": {
          "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
          "$ref": "execution-provenance.schema.json"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "outcome",
        "error"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this outcome payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "The stream run this outcome terminates, matching StreamRunHandle.runId and every StreamEvent.runId for the run.",
          "type": "string",
          "minLength": 1
        },
        "outcome": {
          "description": "The stream ended in failure: validation, routing (no eligible provider), or every attempted provider failing.",
          "const": "error"
        },
        "error": {
          "description": "The normalized error for this failure. Structurally identical to IndeRunError (contracts/schemas/inderun-error.schema.json), duplicated by value here rather than by $ref, matching this repo's schema convention of no cross-file references. Keep both shapes in sync; a cross-check test asserts a shared fixture validates against both schemas.",
          "type": "object",
          "additionalProperties": true,
          "required": [
            "schemaVersion",
            "errorClass",
            "message"
          ],
          "properties": {
            "schemaVersion": {
              "description": "Contract schema version used to interpret the error payload.",
              "const": "1.0"
            },
            "errorClass": {
              "description": "Normalized error taxonomy, identical to IndeRunError.errorClass: CapabilityMismatch (request needs something no eligible provider supports), Offline/Unavailable (provider unreachable or not ready), AuthError (credential/auth failure), RateLimited (provider throttled the request), Timeout (provider exceeded its execution budget), Internal (unexpected engine-side failure).",
              "enum": [
                "CapabilityMismatch",
                "Offline",
                "AuthError",
                "RateLimited",
                "Timeout",
                "Unavailable",
                "Internal"
              ]
            },
            "message": {
              "description": "Human-readable error message suitable for logs and developer diagnostics.",
              "type": "string",
              "minLength": 1
            },
            "providerId": {
              "description": "Identifier of the provider associated with the failure, if execution reached a provider.",
              "type": "string",
              "minLength": 1
            },
            "retryable": {
              "description": "Whether retrying the same request may succeed.",
              "type": "boolean"
            },
            "retryAfterMs": {
              "description": "Optional suggested delay before retrying, in milliseconds.",
              "type": "integer",
              "minimum": 0
            },
            "details": {
              "description": "Optional structured diagnostic details. It must not contain raw secrets.",
              "type": "object",
              "additionalProperties": true
            },
            "provenance": {
              "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
              "$ref": "execution-provenance.schema.json"
            }
          }
        },
        "partialText": {
          "description": "Whatever cumulative text a text run had already delivered before it failed after committing to its provider. Absent when nothing was delivered.",
          "type": "string"
        },
        "provenance": {
          "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
          "$ref": "execution-provenance.schema.json"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "schemaVersion",
        "runId",
        "outcome"
      ],
      "properties": {
        "schemaVersion": {
          "description": "Contract schema version used to interpret this outcome payload.",
          "const": "1.0"
        },
        "runId": {
          "description": "The stream run this outcome terminates, matching StreamRunHandle.runId and every StreamEvent.runId for the run.",
          "type": "string",
          "minLength": 1
        },
        "outcome": {
          "description": "The stream was cancelled. No further StreamEvent is delivered after this outcome, and no further fallback attempt is made, per the engine's cancellation guarantee.",
          "const": "cancelled"
        },
        "partialText": {
          "description": "Whatever cumulative text a text run had already delivered via content_delta/content_snapshot StreamEvents before the cancellation point. Always set for a text run, and empty if cancellation occurred before any content was produced. A non-text run never sets it.",
          "type": "string"
        },
        "output": {
          "description": "What a cancelled non-text run had already produced: a playback run that committed (audio may have been heard) carries a playback output, and an artifact run cancelled while the engine was writing its artifact to an application destination carries that application-owned artifact, whose bytes the write left at the destination. Absent when nothing was produced, e.g. an artifact run cancelled before its artifact was handed over, whose partial media the engine discards. See task-output.schema.json.",
          "$ref": "task-output.schema.json"
        },
        "reason": {
          "description": "Optional human-readable reason the run was cancelled (e.g. caller-initiated abort). Not a machine-taxonomy field; use errorClass on the 'error' outcome branch for failure classification.",
          "type": "string"
        },
        "provenance": {
          "description": "Normalized execution provenance: which target ran, its declared locality, the configured and reported model, and how fallback and routing played out. See execution-provenance.schema.json.",
          "$ref": "execution-provenance.schema.json"
        }
      }
    }
  ]
} as const;

export const providerCapabilitySnapshotSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/provider-capability-snapshot.schema.json",
  "title": "ProviderCapabilitySnapshot",
  "description": "One registered provider's identity, static declaration and live capability check, as returned by checkCapabilities(). A read-only snapshot: producing it executes no task and has no side effects.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "providerId",
    "descriptor",
    "capabilities"
  ],
  "properties": {
    "providerId": {
      "description": "Identifier of the provider; equal to descriptor.id.",
      "type": "string",
      "minLength": 1
    },
    "descriptor": {
      "description": "The provider's static capability declaration.",
      "$ref": "provider-descriptor.schema.json"
    },
    "capabilities": {
      "description": "The provider's live capability check at the time of the call.",
      "$ref": "provider-dynamic-capabilities.schema.json"
    }
  }
} as const;

export const providerDescriptorSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/provider-descriptor.schema.json",
  "title": "ProviderDescriptor",
  "description": "A provider's static capability declaration: identity, placement, transport, supported interaction modes and tasks, cancellation guarantee, resource limits and privacy posture. It does not change while the provider is registered. The route planner, checkCapabilities() and execution provenance all read this one shape.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "id",
    "type",
    "transport",
    "supports",
    "cancel",
    "tasks"
  ],
  "properties": {
    "id": {
      "description": "Unique identifier of the provider instance (a target), e.g. 'apple_foundation_models' or 'openai_compatible_cloud:gpt-5-mini'. Model profiles list targets by this id.",
      "type": "string",
      "minLength": 1
    },
    "type": {
      "title": "ProviderType",
      "description": "Execution placement: 'local' (on the device), 'edge', or 'cloud'.",
      "enum": [
        "local",
        "edge",
        "cloud"
      ]
    },
    "model": {
      "description": "The model this provider instance is bound to, when it can name one. Cloud providers report the model id they send; platform-managed models report an opaque platform alias rather than a guessed weight name. Absent means the provider cannot name its model.",
      "type": "string",
      "minLength": 1
    },
    "transport": {
      "title": "ProviderTransport",
      "description": "How the engine reaches the provider: in-process runtime, operating-system service, buffered HTTP, server-sent events, or a realtime connection.",
      "enum": [
        "in_process",
        "system_service",
        "http",
        "sse",
        "realtime"
      ]
    },
    "streamingStyle": {
      "title": "StreamingStyle",
      "description": "How a streaming provider delivers incremental output: individual tokens, larger chunks, or whole snapshots. Absent for providers that do not stream.",
      "enum": [
        "tokens",
        "chunks",
        "snapshots"
      ]
    },
    "supports": {
      "title": "ProviderSupports",
      "description": "Interaction modes and features the provider statically declares.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "run",
        "streaming",
        "realtime",
        "tools",
        "reasoningEvents",
        "structuredOutput",
        "multimodal"
      ],
      "properties": {
        "run": {
          "description": "Whether the provider supports Mode 1 run (request/response).",
          "type": "boolean"
        },
        "streaming": {
          "description": "Whether the provider supports Mode 2 stream. A provider that declares it must also implement the streaming adapter; the engines report it as unavailable otherwise.",
          "type": "boolean"
        },
        "realtime": {
          "description": "Whether the provider supports Mode 3 realtime sessions. Reserved; no engine implements Mode 3 yet.",
          "type": "boolean"
        },
        "tools": {
          "description": "Whether the provider supports tool calling.",
          "type": "boolean"
        },
        "reasoningEvents": {
          "description": "Whether the provider emits reasoning events alongside content.",
          "type": "boolean"
        },
        "structuredOutput": {
          "description": "Whether the provider supports structured output constrained by a JSON schema.",
          "type": "boolean"
        },
        "multimodal": {
          "description": "Whether the provider accepts non-text inputs such as images or audio.",
          "type": "boolean"
        }
      }
    },
    "cancel": {
      "title": "CancelSemantics",
      "description": "Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops reading locally while remote work may continue, 'none' means cancellation is unsupported. Independently of this value, the engine delivers no event after a cancel.",
      "enum": [
        "hard",
        "soft",
        "none"
      ]
    },
    "tasks": {
      "description": "Task kinds the provider supports, e.g. 'text_to_text'. When taskCapabilities is present it must describe the same kinds and is what routing reads; without it, routing infers capabilities for 'text_to_text' alone (see taskCapabilities).",
      "type": "array",
      "items": {
        "type": "string",
        "minLength": 1
      }
    },
    "limits": {
      "title": "ProviderLimits",
      "description": "Optional input and output resource limits.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "maxInputTokens": {
          "description": "Largest accepted input, in tokens.",
          "type": "integer",
          "minimum": 1
        },
        "maxOutputTokens": {
          "description": "Largest output the provider produces, in tokens.",
          "type": "integer",
          "minimum": 1
        },
        "maxImageBytes": {
          "description": "Largest accepted image, in bytes.",
          "type": "integer",
          "minimum": 1
        },
        "maxAudioSeconds": {
          "description": "Longest accepted or produced audio, in seconds.",
          "type": "integer",
          "minimum": 1
        }
      }
    },
    "privacy": {
      "title": "ProviderPrivacy",
      "description": "Data-egress posture, used to enforce local and cloud routing rules. Absent means a local or edge provider is treated as keeping data on the device and a cloud provider as sending it off.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "dataLeavesDevice"
      ],
      "properties": {
        "dataLeavesDevice": {
          "description": "Whether request content leaves the device.",
          "type": "boolean"
        },
        "regions": {
          "description": "Geographic regions where a cloud provider processes data.",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "taskCapabilities": {
      "description": "What the provider can do for each task: accepted inputs, interaction modes, output deliveries and formats, cancellation, locales and privacy. When present it is authoritative for routing and must list every task the provider serves. When absent (a legacy descriptor), routing infers exactly one entry — 'text_to_text' with text input, inline output, run/stream from supports and cancel from cancel — if tasks contains 'text_to_text', and nothing for any other task: a legacy descriptor is never treated as capable of a non-text task.",
      "type": "array",
      "items": {
        "$ref": "#/$defs/taskCapability"
      }
    }
  },
  "$defs": {
    "taskCapability": {
      "title": "ProviderTaskCapability",
      "description": "The provider's static capabilities for one task kind.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind",
        "inputs",
        "interaction",
        "cancel",
        "outputs"
      ],
      "properties": {
        "kind": {
          "description": "The task kind this entry describes, e.g. 'text_to_speech'.",
          "type": "string",
          "minLength": 1
        },
        "inputs": {
          "description": "Input media kinds the provider accepts for this task.",
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/inputKind"
          }
        },
        "interaction": {
          "title": "ProviderTaskInteraction",
          "description": "Interaction modes the provider supports for this task.",
          "type": "object",
          "additionalProperties": true,
          "required": [
            "run",
            "stream"
          ],
          "properties": {
            "run": {
              "description": "Whether the provider supports Mode 1 run for this task.",
              "type": "boolean"
            },
            "stream": {
              "description": "Whether the provider supports Mode 2 stream for this task.",
              "type": "boolean"
            }
          }
        },
        "cancel": {
          "description": "Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g. when stopping playback is immediate but a synthesis request cannot be aborted.",
          "$ref": "#/properties/cancel"
        },
        "outputs": {
          "description": "How results of this task can be delivered. A provider lists only what it really produces: a provider that can only play audio lists 'playback' and never 'artifact'.",
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/taskOutput"
          }
        },
        "locales": {
          "description": "BCP 47 locales the provider can serve for this task, when it knows them statically. Absent means unknown; the dynamic check may report them instead.",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
        },
        "privacy": {
          "description": "Data-egress posture for this task when it differs from the provider-level privacy, e.g. a provider whose speech synthesis uses a network service. Absent inherits descriptor.privacy.",
          "$ref": "#/properties/privacy"
        }
      }
    },
    "taskOutput": {
      "title": "ProviderTaskOutput",
      "description": "One way the provider can deliver a task's result.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "delivery"
      ],
      "properties": {
        "delivery": {
          "$ref": "#/$defs/outputDelivery"
        },
        "mediaTypes": {
          "description": "Media types the provider can produce with this delivery, e.g. 'audio/wav'. Absent means the provider does not declare them; a request that requires specific media types never routes to such an output.",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "inputKind": {
      "title": "TaskInputKind",
      "description": "A kind of input medium a task consumes.",
      "enum": [
        "text",
        "image",
        "audio"
      ]
    },
    "outputDelivery": {
      "title": "OutputDelivery",
      "description": "How a task's result reaches the application: 'inline' content in the result (text), 'playback' as a managed, audible effect on the device with no retrievable bytes, or 'artifact' as retrievable media.",
      "enum": [
        "inline",
        "playback",
        "artifact"
      ]
    }
  }
} as const;

export const providerDynamicCapabilitiesSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/provider-dynamic-capabilities.schema.json",
  "title": "ProviderDynamicCapabilities",
  "$comment": "streamingAvailable and cancellationAvailable are tri-state on purpose: true, false, or absent. Absent means 'inherit the static declaration' and is a distinct state from both booleans. They must never become nullable: null would be a fourth state no consumer handles, and bridges omit the key specifically to preserve 'absent'.",
  "description": "A provider's live capability check, evaluated on the current host when routing or when checkCapabilities() is called. Unlike the descriptor it can change between calls.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "available"
  ],
  "properties": {
    "available": {
      "description": "Whether the provider is available and functional on this host right now.",
      "type": "boolean"
    },
    "reason": {
      "description": "Why the provider is unavailable, when available is false.",
      "type": "string",
      "minLength": 1
    },
    "streamingAvailable": {
      "description": "Whether the provider can stream (Mode 2) on this host right now. Absent inherits the static descriptor.supports.streaming value; only set it when the host takes streaming away from a provider that otherwise declares it. Never null.",
      "type": "boolean"
    },
    "streamingUnavailableReason": {
      "description": "Why streaming is unavailable, when streamingAvailable is false. Absent lets the route planner synthesize a default message.",
      "type": "string",
      "minLength": 1
    },
    "cancellationAvailable": {
      "description": "Whether cancellation is honored on this host right now. Absent inherits the static descriptor.cancel value: any value other than 'none' means available. Never null.",
      "type": "boolean"
    },
    "taskCapabilities": {
      "description": "Per-task overrides of the provider-level check, for tasks whose availability differs on this host, e.g. a voice that is not installed. Every field of an entry is optional and absent inherits the provider-level value; a false at either level wins.",
      "type": "array",
      "items": {
        "$ref": "#/$defs/taskAvailability"
      }
    }
  },
  "$defs": {
    "taskAvailability": {
      "title": "ProviderTaskAvailability",
      "description": "The live check for one task kind.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "description": "The task kind this entry describes.",
          "type": "string",
          "minLength": 1
        },
        "available": {
          "description": "Whether the task can run on this host right now. Absent inherits the provider-level available. Never null.",
          "type": "boolean"
        },
        "reason": {
          "description": "Why the task is unavailable, when available is false.",
          "type": "string",
          "minLength": 1
        },
        "streamingAvailable": {
          "description": "Whether the task can stream on this host right now. Absent inherits. Never null.",
          "type": "boolean"
        },
        "streamingUnavailableReason": {
          "description": "Why streaming is unavailable for this task, when streamingAvailable is false.",
          "type": "string",
          "minLength": 1
        },
        "cancellationAvailable": {
          "description": "Whether cancellation is honored for this task right now. Absent inherits. Never null.",
          "type": "boolean"
        },
        "locales": {
          "description": "BCP 47 locales available for this task right now. Absent means the provider cannot enumerate them.",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
        },
        "voices": {
          "description": "Voices available for this task right now. Absent means the provider cannot enumerate them; a request that requires a voice then never routes to it.",
          "type": "array",
          "items": {
            "$ref": "#/$defs/voice"
          }
        }
      }
    },
    "voice": {
      "title": "ProviderVoice",
      "description": "Provider-neutral traits of one available voice. Carries no provider voice identifier.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "locale"
      ],
      "properties": {
        "locale": {
          "description": "BCP 47 locale the voice speaks.",
          "type": "string",
          "minLength": 1
        },
        "gender": {
          "$ref": "#/$defs/voiceGender"
        },
        "networkRequired": {
          "description": "Whether using the voice sends data off the device. Absent inherits the task's privacy posture.",
          "type": "boolean"
        }
      }
    },
    "voiceGender": {
      "title": "VoiceGender",
      "description": "Perceived gender of a voice, as the platform reports it.",
      "enum": [
        "female",
        "male",
        "neutral"
      ]
    }
  }
} as const;

export const artifactReadRequestSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/artifact-read-request.schema.json",
  "title": "ArtifactReadRequest",
  "description": "A ranged read of an engine-owned media artifact through IndeRunApi.readArtifact (ADR 017). Reads are repeatable until the artifact is disposed; each returns at most the engine's configured maximum read size, which bounds what one call -- and one bridge message -- carries.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "artifactId"
  ],
  "properties": {
    "artifactId": {
      "description": "MediaArtifact.id of the artifact to read.",
      "type": "string",
      "minLength": 1
    },
    "offset": {
      "description": "Byte offset to read from. Absent means 0. An offset equal to the artifact's size returns an empty, final chunk; a larger one is rejected.",
      "type": "integer",
      "minimum": 0
    },
    "maxBytes": {
      "description": "Most bytes to return. Absent, or larger than the engine's maximum read size, means that maximum.",
      "type": "integer",
      "minimum": 1
    }
  }
} as const;

export const taskOutputSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/task-output.schema.json",
  "title": "TaskOutput",
  "description": "The normalized output of a run, shared by TaskResult and the completed and cancelled stream terminal outcomes (ADR 016). 'type' describes the content representation, not the task: 'text' carries inline text, 'playback' reports a managed, audible effect that has no retrievable bytes, and 'artifact' references retrievable media (ADR 017). A playback output is never an artifact, and an artifact output never implies that anything was played.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "type"
  ],
  "allOf": [
    {
      "if": {
        "properties": {
          "type": {
            "const": "text"
          }
        }
      },
      "then": {
        "required": [
          "text"
        ]
      }
    },
    {
      "if": {
        "properties": {
          "type": {
            "const": "playback"
          }
        }
      },
      "then": {
        "required": [
          "playback"
        ]
      }
    },
    {
      "if": {
        "properties": {
          "type": {
            "const": "artifact"
          }
        }
      },
      "then": {
        "required": [
          "artifact"
        ]
      }
    }
  ],
  "properties": {
    "type": {
      "title": "TaskOutputType",
      "description": "The content representation: 'text', 'playback' or 'artifact'.",
      "enum": [
        "text",
        "playback",
        "artifact"
      ]
    },
    "text": {
      "description": "The text the run produced. Required when type is 'text'.",
      "type": "string"
    },
    "playback": {
      "title": "PlaybackOutput",
      "description": "Completion of managed playback. Required when type is 'playback'. Carries no media.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "durationMs": {
          "description": "How long audible playback lasted, in milliseconds. For a cancelled run, how long it played before it was stopped.",
          "type": "number",
          "minimum": 0
        }
      }
    },
    "artifact": {
      "description": "The retrievable media the run produced. Required when type is 'artifact'.",
      "$ref": "media-artifact.schema.json"
    },
    "speech": {
      "title": "SpeechOutput",
      "description": "The locale and voice traits a text-to-speech run actually used, so an unmet preference is visible without being an error.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "locale"
      ],
      "properties": {
        "locale": {
          "description": "BCP 47 tag of the locale that was spoken.",
          "type": "string",
          "minLength": 1
        },
        "voice": {
          "title": "SpeechOutputVoice",
          "description": "Provider-neutral traits of the voice that spoke. Carries no provider voice identifier.",
          "type": "object",
          "additionalProperties": true,
          "properties": {
            "gender": {
              "$ref": "provider-dynamic-capabilities.schema.json#/$defs/voiceGender"
            }
          }
        }
      }
    }
  }
} as const;

export const mediaArtifactSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/media-artifact.schema.json",
  "title": "MediaArtifact",
  "description": "A reference to retrievable media a run produced (ADR 017). It carries no bytes and no location: an engine-owned artifact is read through the engine by id, and an application-owned one was written to an application destination. Media-neutral: audio, images and video share this shape and differ only in mediaType.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "id",
    "mediaType",
    "owner",
    "lifetime"
  ],
  "properties": {
    "id": {
      "description": "Opaque, engine-issued identifier. Never a path, URL or provider identifier.",
      "type": "string",
      "minLength": 1
    },
    "mediaType": {
      "description": "IANA media type of the bytes, e.g. 'audio/wav'. Encoding parameters ride on the media type (e.g. 'audio/L16;rate=22050').",
      "type": "string",
      "minLength": 1
    },
    "owner": {
      "title": "ArtifactOwner",
      "description": "'engine': the engine holds the bytes and the application reads them by id until it disposes the artifact. 'application': the bytes were written to the application destination named by destinationRef and the engine holds nothing.",
      "enum": [
        "engine",
        "application"
      ]
    },
    "lifetime": {
      "title": "ArtifactLifetime",
      "description": "How long the engine keeps the bytes. 'until_disposed': until the application disposes the artifact or the process ends; the artifact outlives the run that produced it.",
      "enum": [
        "until_disposed"
      ]
    },
    "byteLength": {
      "description": "Size of the media in bytes. Always set for an artifact the engine materialized.",
      "type": "integer",
      "minimum": 0
    },
    "durationMs": {
      "description": "Duration of time-based media in milliseconds, where the producer knows it.",
      "type": "number",
      "minimum": 0
    },
    "destinationRef": {
      "description": "The request's delivery.destinationRef the bytes were written to. Set exactly when owner is 'application'.",
      "type": "string",
      "minLength": 1
    }
  }
} as const;

export const executionProvenanceSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/execution-provenance.schema.json",
  "title": "ExecutionProvenance",
  "description": "Provider-neutral record of how an execution was carried out: the target the outcome is attributed to, its declared locality, the configured and provider-reported model, every attempt, and why other candidates were rejected. Carried on TaskResult, on every StreamTerminalOutcome branch, and on IndeRunError. It reports what the engine observed and what providers declared or reported; it never infers a model or locality a provider did not state, and it never contains request content, credentials, or provider payloads.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "schemaVersion",
    "modelProfile",
    "locality",
    "attemptCount",
    "fallbackOccurred",
    "attempts",
    "routeRejections"
  ],
  "properties": {
    "schemaVersion": {
      "description": "Contract schema version used to interpret this provenance record.",
      "const": "1.0"
    },
    "modelProfile": {
      "description": "The model profile the request routed within; 'auto' when the request named none.",
      "type": "string",
      "minLength": 1
    },
    "providerId": {
      "description": "The target the outcome is attributed to: the provider that produced the result, the provider a stream had committed to when it ended, or the provider that was running when it was cancelled. Absent when no provider was reached or when every attempted provider failed before one was committed to.",
      "type": "string",
      "minLength": 1
    },
    "locality": {
      "description": "Where providerId declares it executes: 'on_device' for a local provider, 'edge', or 'cloud'. A declaration by the provider's descriptor, not a measurement. 'unknown' when providerId is absent.",
      "enum": [
        "on_device",
        "edge",
        "cloud",
        "unknown"
      ]
    },
    "configuredModel": {
      "description": "The model providerId is bound to, as its descriptor declares it. Absent when the provider cannot name its model or no provider is attributed.",
      "type": "string",
      "minLength": 1
    },
    "reportedModel": {
      "description": "The model identifier the provider reported in its own response. Absent means the provider did not report one; it is never inferred from configuration.",
      "type": "string",
      "minLength": 1
    },
    "attemptCount": {
      "description": "How many providers were attempted. 0 when the request failed validation or routing, or was cancelled before any attempt started.",
      "type": "integer",
      "minimum": 0
    },
    "fallbackOccurred": {
      "description": "Whether more than one provider was attempted (attemptCount > 1).",
      "type": "boolean"
    },
    "attempts": {
      "description": "Every attempted provider, in attempt order, with how its attempt ended.",
      "type": "array",
      "items": {
        "title": "ExecutionProvenanceAttempt",
        "type": "object",
        "additionalProperties": true,
        "required": [
          "providerId",
          "outcome"
        ],
        "properties": {
          "providerId": {
            "type": "string",
            "minLength": 1
          },
          "outcome": {
            "title": "AttemptOutcome",
            "description": "'succeeded' (produced the result or was committed to and completed), 'failed', or 'cancelled'.",
            "enum": [
              "succeeded",
              "failed",
              "cancelled"
            ]
          },
          "committed": {
            "description": "Whether the run committed to this provider during the attempt: its first content was delivered, it signalled the first possible audible effect, or it handed over an artifact. After commit a failure ends the run instead of falling back. Absent means the attempt did not commit.",
            "type": "boolean"
          },
          "errorClass": {
            "description": "Normalized error class of a failed attempt.",
            "enum": [
              "CapabilityMismatch",
              "Offline",
              "AuthError",
              "RateLimited",
              "Timeout",
              "Unavailable",
              "Internal"
            ]
          }
        }
      }
    },
    "routeRejections": {
      "description": "Providers the route planner rejected before any attempt, with the normalized RoutePlan reason codes. Codes only: no provider-supplied messages.",
      "type": "array",
      "items": {
        "title": "ExecutionProvenanceRouteRejection",
        "type": "object",
        "additionalProperties": true,
        "required": [
          "providerId",
          "codes"
        ],
        "properties": {
          "providerId": {
            "type": "string",
            "minLength": 1
          },
          "codes": {
            "type": "array",
            "items": {
              "enum": [
                "task_not_supported",
                "run_not_supported",
                "streaming_not_supported",
                "streaming_unavailable",
                "privacy_constraint",
                "cloud_constraint",
                "offline",
                "capability_unavailable",
                "not_in_model_profile",
                "input_not_supported",
                "output_delivery_not_supported",
                "output_format_not_supported",
                "locale_not_supported",
                "voice_not_available"
              ]
            }
          }
        }
      }
    }
  }
} as const;
