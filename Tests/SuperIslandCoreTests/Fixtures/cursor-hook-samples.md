# Cursor hook payload samples — live capture

Captured verbatim from **Cursor 3.8.24** on 2026-06-28 via a throwaway logging
hook (`user_email` redacted). These confirm `CursorHookEvent`'s field names and
the event ordering the integration relies on. The GUI agent (Composer) fires
these reliably for every turn.

Key confirmations:
- Field names match `CursorHookEvent.CodingKeys` exactly: `conversation_id`,
  `hook_event_name`, `prompt`, `text`, `status`, `workspace_roots`.
- `workspace_roots` is an array of absolute path strings.
- `afterAgentResponse` carries the assistant `text`; `stop` carries only
  `status` (`completed`/`aborted`/`error`) — so turn-end classification must use
  the text stashed from `afterAgentResponse`, which fires immediately before
  `stop`.
- Bonus: each event also carries a real `transcript_path`
  (`~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`) — a future
  cold-start status-seeding source (not used yet).

## beforeSubmitPrompt

```json
{"conversation_id":"2dd698cf-…","generation_id":"f202b57e-…","model":"composer-2.5-fast","model_id":"composer-2.5","model_params":[{"id":"fast","value":"true"}],"composer_mode":"agent","prompt":"Ask me a question please","attachments":[],"session_id":"2dd698cf-…","hook_event_name":"beforeSubmitPrompt","cursor_version":"3.8.24","workspace_roots":["/Users/akhil/memorial-app"],"user_email":"<redacted>","transcript_path":null}
```

## afterAgentResponse (question-ending turn → needs-attention)

```json
{"conversation_id":"2dd698cf-…","generation_id":"f202b57e-…","text":"What would you like to work on next in the memorial app — a new feature, a bug fix, or something else entirely?","input_tokens":17674,"output_tokens":220,"session_id":"2dd698cf-…","hook_event_name":"afterAgentResponse","cursor_version":"3.8.24","workspace_roots":["/Users/akhil/memorial-app"],"transcript_path":"/Users/akhil/.cursor/projects/Users-akhil-memorial-app/agent-transcripts/2dd698cf-…/2dd698cf-….jsonl"}
```

## stop

```json
{"conversation_id":"2dd698cf-…","generation_id":"f202b57e-…","status":"completed","loop_count":0,"input_tokens":17674,"output_tokens":220,"session_id":"2dd698cf-…","hook_event_name":"stop","cursor_version":"3.8.24","workspace_roots":["/Users/akhil/memorial-app"],"transcript_path":"…/2dd698cf-….jsonl"}
```
