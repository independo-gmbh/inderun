/* This file was generated from JSON Schema. Do not edit by hand. */

export const taskRequestSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/task-request.schema.json",
  "title": "TaskRequest",
  "description": "Milestone-1 text-to-text request contract for Mode 1 run().",
  "type": "object",
  "additionalProperties": true,
  "required": [
    "schemaVersion",
    "task",
    "policy"
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
      "description": "Optional caller-provided idempotency/debug identifier for this request.",
      "type": "string",
      "minLength": 1
    },
    "task": {
      "description": "Task descriptor used by routing and provider capability matching.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "description": "Milestone-1 task kind for text input to text output.",
          "const": "text_to_text"
        }
      }
    },
    "prompt": {
      "description": "Single text prompt input for simple text-to-text execution.",
      "type": "string",
      "minLength": 1
    },
    "messages": {
      "description": "Conversation-style text input for chat-like text-to-text execution.",
      "type": "array",
      "minItems": 1,
      "items": {
        "description": "One message in the conversation input.",
        "type": "object",
        "additionalProperties": true,
        "required": [
          "role",
          "content"
        ],
        "properties": {
          "role": {
            "description": "Role of the message author.",
            "enum": [
              "system",
              "user",
              "assistant"
            ]
          },
          "content": {
            "description": "Text content for this message.",
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "generation": {
      "description": "Optional provider-neutral generation hints.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "maxOutputTokens": {
          "description": "Optional upper bound for generated output tokens.",
          "type": "integer",
          "minimum": 1
        },
        "temperature": {
          "description": "Optional randomness hint where 0 is most deterministic and 2 is highest supported variance.",
          "type": "number",
          "minimum": 0,
          "maximum": 2
        },
        "topP": {
          "description": "Optional nucleus sampling probability hint.",
          "type": "number",
          "minimum": 0,
          "maximum": 1
        },
        "seed": {
          "description": "Optional deterministic generation seed when supported by the provider.",
          "type": "integer"
        },
        "stop": {
          "description": "Optional stop sequences that should end generation when matched.",
          "type": "array",
          "items": {
            "type": "string"
          }
        }
      }
    },
    "policy": {
      "description": "Execution policy constraints used by the router.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "execution"
      ],
      "properties": {
        "execution": {
          "description": "Required execution target for milestone routing.",
          "enum": [
            "on_device",
            "cloud"
          ]
        }
      }
    },
    "telemetry": {
      "description": "Caller telemetry preferences for this request.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "consent": {
          "description": "Whether the caller consents to telemetry collection for this request.",
          "type": "boolean"
        },
        "level": {
          "description": "Requested telemetry detail level.",
          "enum": [
            "off",
            "minimal",
            "debug"
          ]
        },
        "tags": {
          "description": "Optional caller-provided non-secret labels for telemetry correlation.",
          "type": "object",
          "additionalProperties": {
            "type": "string"
          }
        }
      }
    },
    "authContextRef": {
      "description": "Reference to a secure credential slot. Raw credentials must not be placed in the request.",
      "type": "string",
      "minLength": 1
    }
  }
} as const;

export const taskResultSchema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.inderun.dev/1.0/task-result.schema.json",
  "title": "TaskResult",
  "description": "Milestone-1 text-to-text result contract for Mode 1 run().",
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
      "description": "Opaque run identifier assigned or normalized by the engine.",
      "type": "string",
      "minLength": 1
    },
    "output": {
      "description": "Normalized text output returned by the selected provider.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "type",
        "text"
      ],
      "properties": {
        "type": {
          "description": "Output payload kind for milestone text-to-text execution.",
          "const": "text"
        },
        "text": {
          "description": "Generated text returned to the caller.",
          "type": "string"
        }
      }
    },
    "finishReason": {
      "description": "Normalized reason why generation ended.",
      "enum": [
        "stop",
        "length",
        "cancelled",
        "error"
      ]
    },
    "usage": {
      "description": "Optional normalized token usage information reported by the provider.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "inputTokens": {
          "description": "Number of input tokens consumed, when reported by the provider.",
          "type": "integer",
          "minimum": 0
        },
        "outputTokens": {
          "description": "Number of output tokens generated, when reported by the provider.",
          "type": "integer",
          "minimum": 0
        },
        "totalTokens": {
          "description": "Total token count, when reported by the provider.",
          "type": "integer",
          "minimum": 0
        }
      }
    },
    "telemetry": {
      "description": "Required minimal telemetry summary attached to every result.",
      "type": "object",
      "additionalProperties": true,
      "required": [
        "providerUsed",
        "totalMs"
      ],
      "properties": {
        "providerUsed": {
          "description": "Identifier of the provider selected for the completed attempt.",
          "type": "string",
          "minLength": 1
        },
        "totalMs": {
          "description": "Total measured execution duration in milliseconds.",
          "type": "number",
          "minimum": 0
        },
        "errorClass": {
          "description": "Optional normalized error class if the result represents a provider-level error outcome.",
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
      "required": [
        "executionTarget",
        "networkOnline"
      ],
      "properties": {
        "executionTarget": {
          "description": "Required execution target for the route plan.",
          "enum": [
            "on_device",
            "cloud"
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
      "required": [
        "preferredProviderIds"
      ],
      "properties": {
        "preferredProviderIds": {
          "description": "Provider IDs ordered from highest to lowest preference.",
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          }
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
                    "execution_target_mismatch",
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
