# Tool-call harness

The harness separates semantic generalization from hard safety invariants. It
does not try to reproduce natural-language understanding with an ever-growing
set of routing regular expressions.

```text
user_message
    -> structural preflight (injection and invalid protocol-shaped parameters)
    -> Qwen selection-only tool proposal + structured semantic frame
    -> independent action-entailment check for state changes
    -> code-owned authorization, schema, UI-state and boundary checks
    -> real Godot tool_call only when every required gate passes
```

## Semantic frame

Every selection-only function includes a required `semantic_context` object:

```json
{
  "request_mode": "execute",
  "target": "task_guide",
  "operation": "next",
  "target_source": "explicit",
  "arguments_grounded": true
}
```

Qwen must describe the user's utterance independently of the function it chose.
The harness maps `(target, operation)` to a canonical tool and compares that
with the proposed function. A disagreement can be corrected from the structured
frame without parsing the original sentence in Python.

`request_mode` distinguishes an immediate command, an information or permission
question, a non-executable mention, ordinary conversation, and an unclear
request. `target_source` distinguishes a reliably named target, a user-supplied
name with one model-selected nearest target (`approximate`), a target inferred
from the only visible panel, and a genuinely unclear target. An approximate
state-changing target is never dispatched immediately: it becomes a pending
suggestion that requires a same-conversation confirmation. Parameterized calls
additionally require `arguments_grounded=true`.

The full field semantics live once in the router system message. Function
schemas keep only compact descriptions because the same `semantic_context`
schema is attached to every authorized tool; repeating the full prose for each
tool can exceed the 8K model context without adding information.

For compatibility with models that still label a nearest-target proposal as
`context`, the harness accepts the same confirm-only path only when two
independent signals agree: the router selected one concrete state-changing
tool, and the action-entailment verifier returned `unclear`. Explicit
contradictions and non-execution cues remain vetoes. This fallback can create a
pending suggestion but can never dispatch the action directly.

Parameterized nearest-target suggestions keep only arguments that passed the
strict schema and were grounded in the current utterance. The confirmation text
renders those arguments (for example, the exact page), and confirmation
revalidates them against the latest UI state before dispatch.

For an explicit-page state change, an `explicit` source is executable only when
the utterance also contains one canonical UI name for the model-selected
target. If Qwen maps an unseen name to a target but labels it `explicit`, the
mapping is retained only as a pending suggestion. The canonical-name check
never selects a target and does not maintain fuzzy aliases; semantic
nearest-target selection remains the model's responsibility.

## Independent action entailment

A state-changing candidate first passes a narrow code-owned authorization
grammar. The grammar cannot select or correct a tool; it only accepts commands
that explicitly name the same target and action as the semantic candidate.
Everything else receives a second, independent Qwen pass. That pass does not
see the tool catalog or the router's answer. It receives only the untrusted
utterance and a code-owned description of the candidate action, and returns one
verdict:

- `entailed`: the final user intent clearly authorizes this exact action now;
- `contradicted`: the utterance rejects, cancels, discusses, or replaces it;
- `unclear`: authorization cannot be established.

Only `entailed` may continue. Missing, malformed, timed-out, contradicted, or
unclear assessments fail closed. `TOOL_SEMANTIC_TIMEOUT` controls this pass.

The verifier is deliberately not the sole safety boundary. A small,
high-precision code-owned non-execution cue list can only veto mutations; it
never selects or corrects a tool. The veto evaluates the final intent segment,
so a later correction or explicit command supersedes an earlier negation while
final cancellations remain blocked.

The same narrow grammar normalizes a bounded list of high-confidence ASR
substitutions before authorization (for example, a UI action or target changed
by one common homophone). Normalization still cannot select a tool: the
normalized target and action must match the semantic candidate exactly.

## Contextual semantic correction

Two product invariants can correct a model proposal without granting broader
authority:

- asking how to perform the current step uses the evidence-backed knowledge
  route, while asking which step is currently visible uses the state reader;
- navigating to an explicitly named, closed panel without requesting a page
  resolves to opening that panel when the opener is authorized. An explicit
  page remains parameterized and is never discarded by this correction.

These corrections run from the structured semantic frame, current UI facts,
and the existing `allowed_tools` boundary. State-changing corrections still
require the independent action-entailment gate.

## Code-owned invariants

Python remains authoritative for:

- the request's `allowed_tools` boundary;
- strict argument schemas and grounded non-default parameters;
- visible target panels and ambiguous simultaneous panels;
- first/last page and out-of-range positions;
- one-call limits, malformed output, timeouts and missing assessments;
- the final decision to dispatch a real Godot RPC.

The model never executes a real tool. It calls a selection-only proxy, and the
real RPC is made only after the harness returns `action=execute`.

## Audit metadata

`assistant_final.payload.harness_trace` contains a versioned `tool_call` stage
with the common outcome, reason, model-attempt, fallback, and latency fields.
Its `details` records the proposed function and arguments, semantic frame,
independent entailment verdict, canonical tool, correction flag, and semantic
verifier attempts. A knowledge route appends a `knowledge_qa` stage after it.

`assistant_final.payload.tool_harness` exposes the former flat representation
during migration. New consumers should use the common trace documented in
`HARNESS_PROTOCOL.md`.

## Benchmark

The fixed suite in `tests/fixtures/tool_call_cases.json` covers normal routing,
parameters, knowledge delegation, ASR substitutions, negation, hypotheticals,
ambiguity, invalid input, state boundaries, unrelated input, semantic
paraphrases, implicit commands, and self-correction.

```bash
python -m unittest discover -s agent_service/tests -v
python scripts/benchmark_tool_call_harness.py --repeats 3
python scripts/benchmark_tool_call_harness.py --category semantic_variation
python scripts/benchmark_tool_call_harness.py --category negation --repeats 10
```

The benchmark reports separate measures:

- `raw_exact_rate`: original Qwen function and normalized arguments;
- `semantic_consistency_rate`: function choice versus semantic frame;
- `strict_pass_rate`: exact requested behavior, with no fallback;
- `effective_pass_rate`: includes explicitly allowed safe degradation;
- `degraded_safe_fallbacks`: commands that were not executed and instead
  required confirmation;
- `false_mutations` and `unauthorized_calls`: both must remain zero;
- `entailment_verdicts`: behavior of the independent state-change gate.

The command prints `PASS` only for strict behavior, `DEGRADED` only for an
explicitly fixture-authorized safe fallback, and `FAIL` otherwise. It exits
non-zero on a strict behavior miss, incomplete request, forbidden mutation, or
unauthorized call. Category denominators include runtime failures. Detailed
JSONL and a neighboring `.summary.json` file, including model and source-run
metadata, are written under the selected output path.

When adding a difficult expression, add semantic families rather than one-off
keyword variants. If the correct product behavior may be either execution or a
safe clarification, use `safe_fallback_routes`; the strict score will still
show the lost automatic execution instead of hiding it.
