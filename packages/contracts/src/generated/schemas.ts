/* This file was generated from JSON Schema. Do not edit by hand. */

export const taskRequestSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/task-request.schema.json",
  "title": "TaskRequest",
  "description": "The standard request payload for initiating a text-to-text execution task within the IndeRun framework.",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "schemaVersion",
    "task"
  ],
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
      "description": "A descriptor specifying the type of work to be performed. For text-to-text, the kind must be 'text_to_text'.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "description": "The standard task category. Currently supports 'text_to_text' for prompt-based interactions.",
          "const": "text_to_text"
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
          "description": "Optional routing timeout budget in milliseconds.",
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
  "description": "The standard response payload for completed text-to-text execution within the IndeRun framework.",
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
      "description": "The normalized content returned from the selected provider.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "type",
        "text"
      ],
      "properties": {
        "type": {
          "description": "Output payload category (e.g., 'text' for Mode 1 text-to-text).",
          "const": "text"
        },
        "text": {
          "description": "The actual text generated by the execution.",
          "type": "string"
        }
      }
    },
    "finishReason": {
      "description": "Standardized reason describing how generation concluded (e.g., 'stop', 'length', 'cancelled', or 'error').",
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
        "totalMs": {
          "description": "Measured execution duration in milliseconds, including route selection and result processing.",
          "type": "number",
          "minimum": 0
        },
        "errorClass": {
          "description": "Included if the request resulted in a provider-level error (e.g., 'CapabilityMismatch' or 'Unavailable').",
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
  }
} as const;

export const inderunErrorSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/inderun-error.schema.json",
  "title": "IndeRunError",
  "description": "Normalized Milestone-1 error contract.",
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
      "description": "Normalized error taxonomy class.",
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
      "description": "Telemetry event kind emitted by the orchestrator or provider integration.",
      "enum": [
        "route_decided",
        "attempt_succeeded",
        "attempt_failed"
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
  "description": "Pure data input contract for deterministic shared-core Mode-1 route planning.",
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
      "description": "Minimal task descriptor for provider task matching.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "type": "string",
          "minLength": 1
        }
      }
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
    "providers": {
      "description": "Static descriptors plus dynamic capability snapshots for planning.",
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
            "type": "object",
            "additionalProperties": true,
            "required": [
              "id",
              "type",
              "supports",
              "tasks"
            ],
            "properties": {
              "id": {
                "type": "string",
                "minLength": 1
              },
              "type": {
                "enum": [
                  "local",
                  "edge",
                  "cloud"
                ]
              },
              "supports": {
                "type": "object",
                "additionalProperties": true,
                "required": [
                  "run"
                ],
                "properties": {
                  "run": {
                    "type": "boolean"
                  }
                }
              },
              "tasks": {
                "type": "array",
                "items": {
                  "type": "string",
                  "minLength": 1
                }
              },
              "privacy": {
                "description": "Descriptor privacy metadata used to enforce local/cloud routing rules.",
                "type": "object",
                "additionalProperties": true,
                "required": [
                  "dataLeavesDevice"
                ],
                "properties": {
                  "dataLeavesDevice": {
                    "type": "boolean"
                  },
                  "regions": {
                    "type": "array",
                    "items": {
                      "type": "string",
                      "minLength": 1
                    }
                  }
                }
              }
            }
          },
          "capabilities": {
            "type": "object",
            "additionalProperties": true,
            "required": [
              "available"
            ],
            "properties": {
              "available": {
                "type": "boolean"
              },
              "reason": {
                "type": "string",
                "minLength": 1
              }
            }
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
                  "enum": [
                    "task_not_supported",
                    "run_not_supported",
                    "privacy_constraint",
                    "cloud_constraint",
                    "offline",
                    "capability_unavailable"
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
