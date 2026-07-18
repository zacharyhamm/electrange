# Add an OpenAI-Compatible DeepSeek V4 Backend

## Summary

Add a third “OpenAI-compatible” chat provider using the existing shared provider engine and HTTP transport—no SDK or new dependency. Default it to DeepSeek’s official `https://api.deepseek.com` endpoint and `deepseek-v4-flash`, while allowing any compatible base URL/model. DeepSeek officially supports streaming Chat Completions, tool calls, and both V4 Flash/Pro models.

## Implementation Changes

- Add a thin `OpenAICompatibleClient` that:
  - Calls `{baseURL}/chat/completions` with bearer authentication.
  - Streams SSE text and assembles fragmented tool-call arguments.
  - Reuses the existing local/MCP tool registry and `ChatProviderEngine`.
  - Returns tool results with `tool_call_id`.
  - Preserves DeepSeek `reasoning_content` across tool rounds, as required to avoid 400 responses.
  - Reports missing keys and non-200 responses through `ChatProviderError`.
- Add persisted preferences for base URL, model, and DeepSeek thinking mode. Defaults:
  - URL: `https://api.deepseek.com`
  - Model: `deepseek-v4-flash`
  - Thinking: enabled
- Add an OpenAI-compatible Keychain entry. Environment fallback uses `DEEPSEEK_API_KEY` for the DeepSeek host and `OPENAI_API_KEY` otherwise.
- Extend Settings with API key, editable base URL/model, a model-choice menu loaded from `{baseURL}/models`, and a DeepSeek thinking toggle shown only for the official DeepSeek endpoint. The menu offers both `deepseek-v4-flash` and `deepseek-v4-pro` even if model loading fails.
- Replace the binary Gemini toggle with a single-choice “Chat Provider” submenu for Ollama, Gemini, and OpenAI-compatible. Persist the provider as a string; migrate the old Gemini boolean when no new preference exists.
- Add the minimum neutral message metadata needed for OpenAI `tool_call_id`; existing stored chats remain decodable.
- Preserve the user’s existing uncommitted `AppDelegate.swift` changes while modifying the overlapping provider menu.

## Public Interfaces

- Add `.openAICompatible` to provider/tool-provider enums.
- Replace `ChatProviderPreference.useGemini` with a persisted provider enum and legacy fallback.
- Add optional tool-call ID metadata to `ChatMessage`.
- Extend `ChatConfig` and `UserPreferences` with OpenAI-compatible defaults and settings.

## Test Plan

- Verify request URL, authorization, model, messages, tools, and thinking fields.
- Verify streamed text, `[DONE]`, fragmented parallel tool calls, tool-result IDs, and preserved reasoning content.
- Verify model-list decoding, invalid endpoint handling, missing-key errors, and HTTP errors.
- Verify legacy Gemini preference migration and three-provider client selection.
- Run the existing chat tests and the full project test script/build.

## Assumptions

- “OpenAI APIs” means the OpenAI-compatible Chat Completions protocol, not adding the official OpenAI Responses API.
- DeepSeek-specific thinking fields are sent only to the official DeepSeek host; other compatible endpoints receive standard Chat Completions fields.
- No endpoint presets, pricing UI, token accounting, or additional SDK are added.
