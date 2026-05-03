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
      "const": "1.0"
    },
    "requestId": {
      "type": "string",
      "minLength": 1
    },
    "task": {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "const": "text_to_text"
        }
      }
    },
    "prompt": {
      "type": "string",
      "minLength": 1
    },
    "messages": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "role",
          "content"
        ],
        "properties": {
          "role": {
            "enum": [
              "system",
              "user",
              "assistant"
            ]
          },
          "content": {
            "type": "string",
            "minLength": 1
          }
        }
      }
    },
    "generation": {
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "maxOutputTokens": {
          "type": "integer",
          "minimum": 1
        },
        "temperature": {
          "type": "number",
          "minimum": 0,
          "maximum": 2
        },
        "topP": {
          "type": "number",
          "minimum": 0,
          "maximum": 1
        },
        "seed": {
          "type": "integer"
        },
        "stop": {
          "type": "array",
          "items": {
            "type": "string"
          }
        }
      }
    },
    "policy": {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "execution"
      ],
      "properties": {
        "execution": {
          "enum": [
            "on_device",
            "cloud"
          ]
        }
      }
    },
    "telemetry": {
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "consent": {
          "type": "boolean"
        },
        "level": {
          "enum": [
            "off",
            "minimal",
            "debug"
          ]
        },
        "tags": {
          "type": "object",
          "additionalProperties": {
            "type": "string"
          }
        }
      }
    },
    "authContextRef": {
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
      "const": "1.0"
    },
    "runId": {
      "type": "string",
      "minLength": 1
    },
    "output": {
      "type": "object",
      "additionalProperties": true,
      "required": [
        "type",
        "text"
      ],
      "properties": {
        "type": {
          "const": "text"
        },
        "text": {
          "type": "string"
        }
      }
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
    "runId": {
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
    }
  }
} as const;
