# Local knowledge harness

## Reliability contract

Qwen3-VL-2B is not treated as a source of facts. It has two bounded roles:

1. route a knowledge request to `query_task_knowledge`, which reads the current
   Godot task snapshot as evidence;
2. optionally select up to four IDs from evidence already retrieved by the
   server.

The final answer contains only fixed template text and verbatim content from a
server-owned corpus or the current runtime snapshot. A model response cannot add
a source, quote, number, procedure, or state assertion.

## Pipeline

1. Load the static corpus from `KNOWLEDGE_CORPUS_PATH` at process startup.
2. Accept bounded runtime entries without client-controlled source, trust, or
   priority fields.
3. Drop untrusted or prompt-injection-shaped entries and retrieve at most five
   candidates with deterministic lexical scoring and ASR normalization.
4. Check question entities, requested parameter types, missing values, key-value
   conflicts, and unverified safety state. Insufficient evidence is an explicit
   abstention and never reaches the model.
5. Select a clear match deterministically. With multiple candidates, ask the
   local 2B model for IDs only under a JSON Schema and a two-second timeout.
6. Validate selected IDs and required values. If the model fails or drops any
   safety directive, use the already validated deterministic candidate set.
7. Render verbatim evidence and source metadata in code.

## Audit metadata

The direct knowledge endpoint emits one `knowledge_qa` stage under
`harness_trace`. A routed Agent request emits `tool_call -> knowledge_qa` in the
same envelope. The knowledge stage records its outcome, reason, model attempts,
fallback use, latency, retrieved IDs, and citation IDs without duplicating quote
text. The versioned common shape is documented in `HARNESS_PROTOCOL.md`.

## Threat boundary

The HTTP client cannot claim that an arbitrary string is a trusted manual. Only
entries loaded from the configured local corpus are static trusted knowledge.
Runtime entries receive a fixed source label from the Gateway and are intended
for the current Godot task snapshot on a loopback-only deployment. If the
Gateway is exposed beyond localhost, add authenticated sessions before accepting
runtime evidence.

## Current measured result

The fixed 21-case suite covers facts, current-step questions, synthesis,
insufficient evidence, contradictions, ASR noise, source citation, and prompt
injection. The safety-preservation live run against
`Qwen/Qwen3-VL-2B-Instruct` completed 42/42 oracle/retrieval requests with zero
safety failures and 12 real model-selection attempts. Generated run artifacts
are intentionally untracked; reproduce with:

```bash
python scripts/benchmark_knowledge_harness.py \
  --endpoint http://127.0.0.1:7861/v1/knowledge/answer \
  --mode both --repeats 3
```

This score is a regression result for the current fixture, not a proof that all
future questions are correct. Production corpus versioning, domain-owner review,
and telemetry for abstention/fallback reasons remain operational requirements.
