# Harness trace protocol

Tool routing and evidence-gated knowledge answering keep separate domain
decisions, but publish one versioned audit envelope. A request may contain more
than one ordered stage:

```text
ordinary UI request: tool_call
knowledge request:   tool_call -> knowledge_qa
```

## Envelope

`assistant_final.payload.harness_trace` and
`POST /v1/knowledge/answer.harness_trace` use this shape:

```json
{
  "version": 1,
  "stages": [
    {
      "type": "tool_call",
      "outcome": "executed",
      "reason": "verified_semantic_tool_call",
      "model_attempts": 1,
      "fallback_used": false,
      "latency_ms": 1234.5,
      "details": {
        "tool_name": "query_task_knowledge"
      }
    },
    {
      "type": "knowledge_qa",
      "outcome": "answered",
      "reason": "deterministic_evidence",
      "model_attempts": 0,
      "fallback_used": false,
      "latency_ms": 8.1,
      "details": {
        "retrieved_ids": ["step-17"],
        "citation_ids": ["step-17"],
        "citation_count": 1
      }
    }
  ]
}
```

The common fields are deliberately small:

- `type` identifies the bounded decision stage. Version 1 emits `tool_call`
  and `knowledge_qa`; new stages can be added without changing existing ones.
- `outcome` is one of `executed`, `answered`, `clarified`, `abstained`, or
  `rejected`.
- `reason` is the stable machine-readable domain reason.
- `model_attempts` counts model inferences owned by this stage.
- `fallback_used` states that the result used a safe alternative to the
  stage's proposed automatic path. It does not mean the request failed.
- `latency_ms` is measured by the Gateway. For `tool_call` it covers routing,
  semantic verification, policy validation, and the selected Godot RPC. For
  `knowledge_qa` it covers evidence assembly and the knowledge harness.
- `details` contains stage-specific audit data. Common consumers must not
  require fields from another stage type.

The trace records decisions and evidence identifiers, not unrestricted model
reasoning. Knowledge quotes remain in the existing citations response instead
of being duplicated inside the trace.

## Compatibility

`assistant_final.payload.tool_harness` remains available as a compatibility
view during migration. New logging, benchmarks, and clients should read
`harness_trace`. Task knowledge requests use `query_task_knowledge` and publish
the semantic route `knowledge_qa`. The Godot tool returns evidence entries; it
does not invoke an answer model.

The Python types live in `harness_protocol.py`. `ToolCallDecision` and
`KnowledgeAnswer` remain independent domain objects and only convert their
auditable fields into `HarnessStageTrace` at the service boundary.
