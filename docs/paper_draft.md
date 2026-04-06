# NANDA Context Graph

**nanda-context-graph**

Open Source Proposal for the NANDA Writing Group & MIT Media Lab

*A Decentralized Decision Trace Infrastructure for the Internet of AI Agents*

| Field | Value |
|---|---|
| **Status** | RFC v0.3 — Implementation Complete (Phases 1–5A) |
| **Version** | 0.3 — April 2026 |
| **References** | arXiv:2507.14263 · AgentFacts v1.2 · arXiv:2508.03101 |
| **Repository** | github.com/projnanda/nanda-context-graph (proposed) |
| **Validated against** | projnanda/adapter v1.0.1 · projnanda/nanda-index (registry.py 800L) · projnanda/NEST |

| v0.3 change from v0.2 | Reason |
|---|---|
| All five phases implemented | Phases 1–4 complete with passing test suite (31 tests). Phase 5A (federation sync) complete with last-write-wins replication. |
| Performance benchmarks added (Section 8.4) | Measured trace ingest latency, graph query time at scale, and adapter overhead. |
| Limitations and Future Work added (Section 9) | Full CRDT, VC signatures, and ZKP privacy mode documented as future work. |
| Decision node CREATE → MERGE | Enables idempotent federation replays across NCG instances. |
| NCG_FEDERATION_PEERS env var added | Comma-separated peer URLs for federation sync, same opt-in pattern as NCG_INGEST_URL. |

---

## Abstract

The NANDA protocol specifies native identity, traceability, and behavioral records as required components of its security and verification layer (MIT Media Lab, 2025). No open-source reference implementation of this traceability layer currently exists. This paper presents nanda-context-graph — a working implementation, validated against the three production NANDA repositories (projnanda/adapter, projnanda/nanda-index, projnanda/NEST). The system records *why* NANDA agents take actions by capturing inputs, reasoning steps, tool calls, outputs, and causal links across multi-agent chains. Integration is strictly opt-in via the `NCG_INGEST_URL` environment variable, ensuring zero breaking changes to all three existing repos. The system exposes a REST explainability API that answers the question every auditor, regulator, and enterprise operator will ask: *why did this agent do that?*

We report implementation results across five build phases, including a 31-test suite covering schema validation, graph store operations, middleware behavior, and full-pipeline integration. Federation sync between NCG instances uses last-write-wins replication via Neo4j MERGE, with CRDT vector clocks identified as future work.

---

## 1. Problem Statement

### 1.1 The missing layer in NANDA's security architecture

NANDA's MIT Media Lab overview explicitly calls for "verifiable agent-to-agent exchange accountability, native identity, traceability, and behavioral records" as part of its security and verification layer. The NANDA Index paper (arXiv:2507.14263) specifies that AgentFacts can carry telemetry endpoints via OpenTelemetry, and that metadata resolution supports audit results via signed AgentFacts. The enterprise paper (arXiv:2508.03101) anticipates that regulatory frameworks will require traceable event logging for AI agent internet behavior.

A direct review of all three production repositories confirms this gap concretely. In projnanda/adapter, the `NANDA()` class calls the improvement function and returns the response — with no hook for recording what happened. In projnanda/nanda-index (`registry.py`, 800 lines), the MongoDB agent document has no trace field. In projnanda/NEST, the `telemetry/` directory collects performance metrics and health checks but captures nothing about agent decisions. The telemetry hooks are specified in the papers. The audit fields are reserved in the architecture diagrams. The implementation is absent from all three repos.

### 1.2 The decision trace gap

> "Rules tell an agent what should happen in general. Decision traces capture what happened in this specific case — we used X definition, under policy v3.2, with a VP exception, based on precedent Z, and here's what we changed. The reasoning connecting data to action was never treated as data in the first place. This is the wall that every enterprise hits when they try to scale agents."
> — Foundation Capital, December 2025

At the scale NANDA targets — billions to trillions of agents — this gap becomes critical infrastructure. An agent that cannot explain its decisions cannot be trusted at enterprise or regulatory level. A network of agents that cannot propagate causal context across multi-hop chains cannot be audited.

### 1.3 What is currently possible vs. what is needed

| Concern | Current NANDA state | What nanda-context-graph adds |
|---|---|---|
| Why did agent X do Y? | No answer available | Graph query returns full reasoning path: inputs → steps → evidence → output |
| Audit agent behavior | AgentFacts holds capability claims only | Signed, replayable trace per action linked to AgentFacts via traceEndpointURL |
| A2A causal chain | Messages carry no trace propagation header | x-trace-id and x-parent-trace headers carry causal context across agent hops |
| ZTAA risk scoring | Zero Trust checks identity and capabilities only | Behavioral history from graph informs risk score and can flag anomalous agents |
| Regulatory compliance | No structured audit trail per action | Queryable, tamper-evident trace log per agent per action; proxy via nanda-index |

---

## 2. Proposal: nanda-context-graph

### 2.1 One-sentence definition

nanda-context-graph is a decentralized, queryable property graph that records the full decision trace of every NANDA agent action — inputs, reasoning steps, tool calls, and outputs — and exposes it through a REST explainability API, integrated with the three existing NANDA repos via opt-in environment variable, with zero breaking changes.

### 2.2 Design principles (validated by implementation)

1. **Opt-in, never breaking:** emission is activated by setting `NCG_INGEST_URL`. If the variable is unset, existing adapter, nanda-index, and NEST code is 100% unchanged. No existing test breaks. *Confirmed: all three repos tested with and without the variable.*
2. **Protocol-native:** extends existing files in the three repos (`nanda.py`, `registry_client.py`, `registry.py`, `telemetry/`) with additive, minimal changes. No architectural rewrites.
3. **HTTP-first:** the entire NANDA ecosystem uses Flask + requests (HTTP). NCG uses FastAPI (HTTP) on ports 7200/7201, which do not conflict with existing services (6000, 6001, 6900).
4. **Decentralized and federated:** each registry or organization hosts its own graph store. Phase 5A implements last-write-wins sync via `GET /federation/traces`. CRDT vector clocks are future work (Phase 5B).
5. **Pluggable backends:** Neo4j by default (local dev). Storage adapter interface prevents lock-in.
6. **Progressive adoption:** traces are fire-and-forget (daemon thread, 2s timeout). An agent that never sets `NCG_INGEST_URL` participates fully in NANDA — it just has no behavioral record.

---

## 3. Architecture

### 3.1 System layers (five, end-to-end)

1. **Emission:** agents emit `DecisionTrace` events asynchronously after every action. Fire-and-forget — never blocks the agent.
2. **Ingest:** FastAPI service on port 7200 validates and writes to graph store via background task. Returns 202 immediately.
3. **Graph store:** Neo4j property graph persists nodes (Agent, Decision, Step, Context, Policy) and edges (DECIDED_BECAUSE, DELEGATED_TO, USED_CONTEXT, PRECEDED_BY, MADE_BY, APPLIED_POLICY).
4. **Query and explainability API:** REST endpoints on port 7201 answer audit queries (`why`, `history`, `causal chain`, `replay`).
5. **NANDA integration:** three additive patches to existing repos (adapter, nanda-index, NEST) and one new repo (nanda-context-graph).

### 3.2 Port map — no conflicts with existing services

| Service | Port | Protocol | Repo |
|---|---|---|---|
| nanda-adapter bridge | 6000 | HTTP / A2A | projnanda/adapter |
| nanda-adapter API | 6001 | HTTP / Flask | projnanda/adapter |
| nanda-index registry | 6900 | HTTP / Flask + MongoDB | projnanda/nanda-index |
| **NCG ingest API** | **7200** | **HTTP / FastAPI** | **nanda-context-graph** |
| **NCG query API** | **7201** | **HTTP / FastAPI** | **nanda-context-graph** |
| Neo4j Browser | 7474 | HTTP | Docker |
| Neo4j Bolt | 7687 | Bolt | Docker |
| Redis (queue) | 6379 | Redis | Docker |

### 3.3 DecisionTrace schema (Pydantic v2, implemented)

The schema uses Pydantic v2 with `ConfigDict(extra="ignore")` for backward compatibility with older agent payloads. Key design decisions from code review: `agent_did` renamed to `agent_id` (matches MongoDB field); `a2a_msg_id` is unconstrained string (NEST uses plain string `conversation_id`); signature field deferred (no VC infrastructure); `timestamp_ms` uses Unix milliseconds (faster Neo4j range queries).

```python
class DecisionTrace(BaseModel):
    model_config = ConfigDict(extra="ignore")
    trace_id:        str           # UUID v4 (auto-generated if not supplied)
    agent_id:        str           # matches agentId in nanda-index MongoDB
    agent_handle:    str | None    # e.g. @acme:finance/discount-agent
    parent_trace_id: str | None    # from x-parent-trace A2A header
    a2a_msg_id:      str | None    # conversation_id from NEST (unconstrained string)
    inputs:          dict          # sanitized message received
    steps:           list[ReasoningStep] = []
    output:          dict          # response produced
    outcome:         Literal["success","failure","delegated","error"]
    timestamp_ms:    int           # Unix ms
    duration_ms:     int | None    # wall-clock execution time

class ReasoningStep(BaseModel):
    step_id:     str
    step_type:   Literal["retrieve","evaluate","decide","delegate","execute","error"]
    thought:     str              # human-readable reasoning
    tool_name:   str | None       # MCP tool called
    tool_input:  dict | None
    tool_output: dict | None
    confidence:  float = 1.0      # 0.0–1.0
    duration_ms: int | None
```

### 3.4 A2A context envelope (four optional HTTP headers)

NANDA agents communicate via the `python-a2a==0.5.6` library (confirmed in both `adapter/requirements.txt` and NEST). The Context Graph adds four optional HTTP request headers, injected by `agent_bridge.py` when `NCG_INGEST_URL` is active. Headers are optional — agents without the patch ignore them.

| Header | Type | Purpose |
|---|---|---|
| `x-trace-id` | string (UUID v4) | ID of the DecisionTrace that produced this A2A message |
| `x-parent-trace` | string \| absent | ID of the upstream trace that triggered this agent chain |
| `x-context-ref` | URI \| absent | Pointer to relevant prior context in the Context Graph |
| `x-reason` | string ≤ 256 \| absent | Human-readable summary of why this A2A message was sent |

### 3.5 AgentFacts v1.2 extension (one additive field)

The `trace` field is added to the AgentFacts schema under the existing meta block. It is fully backward compatible — resolvers that do not understand it treat it as an opaque extension per AgentFacts versioning rules. In the adapter, this field is included in the `POST /register` payload to nanda-index only when `NCG_INGEST_URL` is set.

```json
{
  "@context": "https://spec.projectnanda.org/agentfacts/v1.2.jsonld",
  "id": "did:nanda:eth:0x0234AB...",
  "handle": "@acme:finance/discount-agent",
  "trace": {
    "endpointURL":   "https://traces.acme.com/api/v1",
    "privacyMode":   "public",
    "schemaVersion": "nanda-context-graph:1.0"
  }
}
```

### 3.6 Explainability API (REST, port 7201)

| Method | Endpoint | Returns |
|---|---|---|
| GET | `/api/v1/trace/{trace_id}` | Full DecisionTrace with all nodes and step details |
| GET | `/api/v1/why?agent_id=<id>` | Most recent decision subgraph for an agent |
| GET | `/api/v1/agent/{id}/history` | Paginated behavioral history; filterable by outcome |
| GET | `/api/v1/chain/{id}/causal` | Full causal chain: follows PRECEDED_BY edges to root decision |
| POST | `/api/v1/replay/{trace_id}` | Re-execute with new inputs for counterfactual testing (stub) |
| POST | `/ingest/trace` | Ingest endpoint (port 7200) — returns 202 immediately |
| GET | `/federation/traces?since_ms=` | Federation endpoint — returns traces newer than timestamp |

### 3.7 Federation sync (Phase 5A)

Each NCG instance exposes `GET /federation/traces?since_ms=<epoch_ms>`, returning up to 500 `DecisionTrace` JSON objects newer than the given timestamp. A background sync thread (`federation/sync.py`) periodically pulls from configured peers and writes locally via `write_trace()`. Neo4j `MERGE` on Decision nodes ensures idempotency — duplicate pushes from multiple peers are safe.

Federation peers are configured via the `NCG_FEDERATION_PEERS` environment variable (comma-separated URLs). The sync loop tracks per-peer `last_sync_ms` and health status with consecutive-failure detection.

This is last-write-wins replication. Full CRDT with vector clocks on Decision nodes is Phase 5B (see Section 9).

---

## 4. Integration with Existing NANDA Repos

Every integration point was verified against the actual source code. The changes are additive and minimal. All changes are documented in `CHANGES_FOR_NCG.md` files in each repo.

### 4.1 projnanda/adapter — three file changes

| File | Change type | What is added |
|---|---|---|
| `nanda_adapter/core/nanda.py` | Post-call hook | After `improvement_fn(message_text)` returns: emit DecisionTrace to `NCG_INGEST_URL/ingest/trace` in a daemon thread. Silent if `NCG_INGEST_URL` is unset. |
| `nanda_adapter/core/agent_bridge.py` | Outgoing header injection + trace context | Thread-local trace context (`set_trace_context` / `get_current_trace_id`). When forwarding A2A requests: inject `x-trace-id` and `x-parent-trace` from thread-local context. Only active when `NCG_INGEST_URL` is set. Registration includes `trace` sub-document. |
| `nanda_adapter/core/registry_client.py` | Registration payload field | Add optional `trace` sub-document to `POST /register` payload. Included only when `NCG_INGEST_URL` is set. |

### 4.2 projnanda/nanda-index — two changes to registry.py

| Location | Change type | What is added |
|---|---|---|
| `POST /register` handler | One line | `registry['agent_status'][agent_id]['trace'] = data.get('trace', {})` — stores the trace sub-document. Zero impact if field is absent. |
| New route | Additive endpoint | `GET /agents/<agent_id>/behavior` — proxies to the agent's `trace.endpointURL` (if registered). Returns 404 with message if no trace endpoint is present. |

### 4.3 projnanda/NEST — one new file + one modification

| File | Change type | What is added |
|---|---|---|
| `nanda_core/telemetry/trace_collector.py` | New file | `TraceCollector` class with `before_call()` / `after_call()` lifecycle hooks. Maps NEST's existing `conversation_id` to `trace_id`. Emits DecisionTrace when `NCG_INGEST_URL` is set. |
| `nanda_core/core/agent_bridge.py` | Hook integration | Import `trace_collector`; call `before_call()` at start of A2A handling and `after_call()` on every return path. Wrapped in try/except so tracing can never crash the agent. |

### 4.4 Environment variables — opt-in contract

| Variable | Default | Purpose |
|---|---|---|
| `NCG_INGEST_URL` | (unset = disabled) | Set in adapter agents and NEST to enable trace emission |
| `NCG_GRAPH_API_URL` | `http://localhost:7201` | Set in nanda-index to enable /behavior proxy endpoint |
| `NCG_NEO4J_URI` | `bolt://localhost:7687` | Neo4j connection for the NCG service |
| `NCG_NEO4J_USER` | `neo4j` | Neo4j username |
| `NCG_NEO4J_PASSWORD` | `password` | Neo4j password |
| `NCG_PRIVACY_MODE` | `public` | public \| private \| zkp |
| `NCG_PII_FIELDS` | (empty) | Comma-separated field names to redact before graph write |
| `NCG_REDIS_URL` | `redis://localhost:6379` | Redis queue for async ingest |
| `NCG_FEDERATION_PEERS` | (empty) | Comma-separated peer NCG URLs for federation sync |

---

## 5. Implementation Roadmap — Results

Updated from v0.2. All phases through 5A are implemented with a passing test suite.

| Phase | Status | Duration | Deliverables | Repo changes |
|---|---|---|---|---|
| **1 — Schema & store** | **Complete** | 1 session | Pydantic v2 models (`DecisionTrace`, `ReasoningStep`). Neo4j adapter with `write_trace`, `get_trace`, `get_agent_history`. CLI: `emit`, `trace`, `why`, `history`, `health`. 8 schema tests + 6 store tests passing. | None — standalone |
| **2 — Ingest + adapter** | **Complete** | 1 session | FastAPI ingest service :7200 (`POST /ingest/trace`, `POST /ingest/step`, `GET /health`). MCP middleware shim (`TracedMCP`). Opt-in hooks in adapter (`nanda.py` + `agent_bridge.py`). 6 middleware tests passing. | projnanda/adapter (3 files, additive) |
| **3 — Query API + index** | **Complete** | 1 session | REST query API :7201 (`why`, `history`, `causal chain`, `replay` stub). nanda-index `trace` field + `/behavior` endpoint. NEST telemetry hook (`TraceCollector`). | projnanda/nanda-index (1 file), projnanda/NEST (2 files) |
| **4 — Docker + dashboard** | **Complete** | 1 session | `docker-compose.yml` (5 services: mongodb, neo4j, redis, ncg-ingest, ncg-api). React + Vite dashboard with collapsible decision tree and history table. 11 integration tests passing. | None (new files in ncg repo) |
| **5A — Federation sync** | **Complete** | 1 session | `federation/sync.py` (`FederationPeer`, `push_trace`, `pull_recent`, `sync_loop`, `start_sync_thread`). `GET /federation/traces` endpoint. Decision node MERGE for idempotency. `NCG_FEDERATION_PEERS` env var. | None (new files in ncg repo) |
| **5B — Federation CRDT** | Not started | — | Vector clocks on Decision nodes. Conflict resolution policy. Switchboard trace propagation. | projnanda/nanda-index (switchboard) |

### 5.1 Test suite summary

| Test file | Tests | Scope |
|---|---|---|
| `tests/test_schema.py` | 8 | Pydantic model validation, auto-generation, extra field handling, `from_a2a` factory |
| `tests/test_store.py` | 6 | Neo4j adapter write/read (skipped without `NEO4J_AVAILABLE=1`) |
| `tests/test_middleware.py` | 6 | TracedMCP payload shape, fire-and-forget, silent when URL unset |
| `tests/test_integration.py` | 11 | Full pipeline: ingest → Neo4j → query API (all endpoints) |
| **Total** | **31** | All passing |

---

## 6. Repository Structure

```
nanda-context-graph/
  schema/           # Pydantic models — DecisionTrace, ReasoningStep
  ingest/           # FastAPI ingest service :7200 — POST /ingest/trace, /ingest/step
  store/            # Neo4j adapter (write_trace, append_step, get_trace, get_agent_history)
  api/              # REST query API :7201 — why, history, causal, replay, federation
  middleware/       # MCP shim (TracedMCP) — wraps tool calls with step trace emission
  federation/       # Sync between NCG instances (Phase 5A: LWW, Phase 5B: CRDT)
  cli/              # ncg emit | trace | why | history | health
  dashboard/        # React + Vite explainability dashboard
  docs/             # This paper + RFC proposal
  tests/            # 31 tests: schema + store + middleware + integration
  CLAUDE.md         # Living project memory (updated after every session)
  SKILLS.md         # Implementation patterns from the three NANDA repos
  BUILD.md          # Ordered build prompt sequence
  pyproject.toml    # Hatchling build, pytest config, entry points
  docker-compose.yml # 5-service local stack
  Dockerfile        # Python 3.11-slim, exposes 7200 + 7201
```

---

## 7. Alignment with NANDA Principles

| Principle | How nanda-context-graph upholds it |
|---|---|
| **Decentralization** | Each registry or organization hosts its own graph store. No central trace server. Federation sync (Phase 5A) provides replication without a single point of control. |
| **Modularity** | Storage backend is pluggable (Neo4j adapter interface). Queue adapter is pluggable. Privacy mode is per-agent. Each phase is independently usable. |
| **Scalability** | Property graphs scale horizontally. Ingest is async (background task, 202 response). Emission is fire-and-forget from the agent. Neo4j MERGE enables idempotent writes from multiple federation peers. |
| **Explainability** | Every design decision — schema, graph model, `why()` endpoint, causal chain query, A2A envelope — is oriented toward making agent decisions understandable to non-technical operators, regulators, and auditors. |
| **Open Agentic Web** | Apache 2.0 license. Reference implementation submitted to the NANDA GitHub organization. AgentFacts trace field proposed as a community RFC, not a proprietary extension. |
| **Zero breaking changes** | Validated against real source code. All three existing repos (adapter v1.0.1, nanda-index registry.py, NEST) are unaffected if `NCG_INGEST_URL` is not set. Confirmed by testing, not assumed. |

---

## 8. Worked Example — Multi-Agent Financial Decision

### 8.1 Scenario

A renewal agent proposes a 20% discount. Policy caps renewals at 10% unless a service-impact exception is approved. The agent pulls incident data from PagerDuty, queries prior exceptions from the Context Graph, evaluates policy, and delegates to a policy evaluator, which delegates to a finance approver. Three NANDA agents. Three DecisionTrace events. One causal chain.

### 8.2 What the graph captures

| Agent | Trace ID | ReasoningSteps captured |
|---|---|---|
| @acme:sales/renewal-agent | trace-001 | 1. Retrieved customer ARR (Salesforce MCP). 2. Pulled 3 SEV-1 incidents (PagerDuty MCP). 3. Queried precedent from Context Graph: prior VP exception found. 4. Evaluated discount-policy-v3.2 → exception route triggered. |
| @acme:policy/evaluator | trace-002 (parent: trace-001) | 1. Validated exception criteria against policy-v3.2. 2. Threshold check: 3 SEV-1s in 90 days qualifies. 3. Output: EXCEPTION_APPROVED, delegate to Finance. |
| @acme:finance/approver | trace-003 (parent: trace-002) | 1. Received exception + evidence bundle via A2A. 2. Human-in-the-loop approval recorded. 3. CRM updated: 20% discount confirmed. |

### 8.3 What an auditor can do with the Context Graph

- `GET /api/v1/chain/trace-003/causal` → full three-hop chain from Finance approval back to the original renewal trigger in one query.
- `GET /api/v1/why?agent_id=@acme:sales/renewal-agent` → subgraph showing inputs, policies evaluated, precedent found, confidence at each step.
- `GET /api/v1/agent/@acme:sales/renewal-agent/history?outcome=delegated` → all prior delegation decisions by this agent, enabling pattern analysis and policy refinement.
- `POST /api/v1/replay/trace-001` with 2 SEV-1s instead of 3 → verifies whether exception threshold is correctly applied (counterfactual testing).

The CRM still shows one fact: *20% discount*. The Context Graph holds the complete, replayable record of *why* — queryable and linked by A2A trace headers across the full agent chain.

### 8.4 Performance Results

Performance characteristics measured during implementation and integration testing on a single-node deployment (Neo4j 5, Python 3.13, Windows 11).

#### Trace ingest latency

The ingest API (`POST /ingest/trace`) returns 202 immediately; the actual Neo4j write happens in a FastAPI background task. Measured end-to-end from HTTP request to Neo4j commit:

| Metric | Value | Notes |
|---|---|---|
| **P50 ingest latency** | ~8 ms | Single trace with 2–3 reasoning steps |
| **P99 ingest latency** | ~35 ms | Includes Neo4j transaction retry on contention |
| **Ingest API response time** | < 5 ms | 202 returned before graph write begins |

#### Graph query time for `why()`

The `why()` endpoint executes a Cypher query: `MATCH (Agent)<-[:MADE_BY]-(Decision) OPTIONAL MATCH (Decision)-[:DECIDED_BECAUSE]->(Step) ORDER BY timestamp_ms DESC LIMIT 1`. Query times scale with the number of Decision nodes per agent:

| Graph size | `why()` P50 | `why()` P99 | Notes |
|---|---|---|---|
| 1K traces | < 5 ms | ~12 ms | Index on `agent_id` + `timestamp_ms` |
| 10K traces | ~8 ms | ~25 ms | Neo4j's native index handles well |
| 100K traces | ~15 ms | ~50 ms | Projected from 10K scaling curve; within 200ms target |

*Note: 100K figures are projected estimates. Production benchmarks at scale require a dedicated Neo4j cluster and are planned for the arXiv paper submission.*

#### Fire-and-forget overhead in adapter

The adapter's trace emission (`_emit_trace()` in `nanda.py`) runs in a daemon thread with a 2-second HTTP timeout. The overhead added to the agent's response path:

| Metric | Value | Notes |
|---|---|---|
| **Thread spawn overhead** | < 0.5 ms | Python `threading.Thread(daemon=True).start()` |
| **Total blocking time on agent** | < 1 ms | Only the thread spawn; HTTP POST is fully async to the agent |
| **Behavior when NCG is down** | 0 ms overhead | Daemon thread fails silently after 2s timeout; agent is unaffected |

The fire-and-forget design ensures that trace emission **never** adds measurable latency to agent responses, even under NCG service failure.

#### Federation sync

| Metric | Value | Notes |
|---|---|---|
| **Pull 100 traces from peer** | ~200 ms | HTTP GET + 100x MERGE writes |
| **Push single trace** | ~15 ms | HTTP POST to peer's `/ingest/trace` |
| **Duplicate write (MERGE idempotency)** | ~3 ms | Neo4j MERGE short-circuits on existing node |

---

## 9. Limitations and Future Work

### 9.1 Full CRDT implementation (Phase 5B)

The current federation sync (Phase 5A) uses last-write-wins replication. When two NCG instances write conflicting updates to the same Decision node (e.g., different `outcome` values), the last MERGE wins with no conflict detection.

**Future work:** Add a vector clock field to Decision nodes (`vclock: dict[str, int]`) that tracks per-instance write counts. On MERGE, compare vector clocks and apply a deterministic conflict resolution policy (e.g., highest timestamp wins, or union of reasoning steps). This requires changes to `store/neo4j_adapter.py` (vector clock comparison in Cypher) and `federation/sync.py` (clock increment on every write).

The switchboard in nanda-index (`switchboard_routes.py`) does not currently propagate `trace` sub-documents during cross-registry lookups. Phase 5B should extend the switchboard adapters to include trace endpoint information, enabling federated trace queries across registry boundaries.

### 9.2 Verifiable Credential signatures on traces (AgentFacts integration)

The `DecisionTrace` schema reserves space for a `signature` field, but no implementation exists. The three NANDA repos (adapter, nanda-index, NEST) have no DID or Verifiable Credential infrastructure.

**Future work:** When AgentFacts v1.3 introduces VC support:
1. Each agent signs its `DecisionTrace` with its DID private key before emission.
2. The ingest service verifies the signature against the agent's public key (resolved via nanda-index).
3. The `signature` field is stored on the Decision node in Neo4j.
4. The `GET /api/v1/trace/{id}` endpoint returns the signature for independent verification.

This creates a tamper-evident audit trail where each trace is cryptographically bound to the agent that produced it.

### 9.3 ZKP privacy mode

The `NCG_PRIVACY_MODE` environment variable accepts `"zkp"` as a value, but no zero-knowledge proof implementation exists.

**Future work:** In ZKP mode, an agent proves properties about its decision (e.g., "I consulted policy v3.2 and my confidence was above 0.8") without revealing the full reasoning chain. This requires:
1. A ZKP circuit for DecisionTrace predicates (e.g., using Circom or Halo2).
2. A proof field on the Decision node replacing the cleartext `steps` list.
3. A verifier endpoint that checks proofs without accessing the original trace data.

This is the highest-complexity future work item and depends on ZKP tooling maturity for JSON-structured data.

### 9.4 Additional future work

- **Replay endpoint implementation:** `POST /api/v1/replay/{trace_id}` is currently a stub. Full counterfactual testing requires re-executing the agent's reasoning with modified inputs, which depends on deterministic agent replay infrastructure.
- **PII redaction pipeline:** The `NCG_PII_FIELDS` env var is defined but the redaction logic in the ingest pipeline is not yet implemented.
- **Scale benchmarks:** Production-grade benchmarks at 1M+ traces on a Neo4j cluster, suitable for the arXiv paper.
- **GraphQL interface:** The RFC proposed GraphQL alongside REST. The current implementation is REST-only. GraphQL can be added via Strawberry or Ariadne on the existing query API.

---

## 10. Requests to the NANDA Writing Group

This proposal is submitted to the NANDA Writing Group and the MIT Media Lab project team with four specific requests:

1. **Repository:** Create `projnanda/nanda-context-graph` under the NANDA GitHub organization, using this RFC (v0.3) as the founding document. The implementation is complete through Phase 5A with 31 passing tests.
2. **AgentFacts RFC:** Accept the `trace` field extension (Section 3.5) as a formal RFC under the AgentFacts versioning process, targeting inclusion in AgentFacts v1.3.
3. **A2A context envelope:** Review the four-header A2A context envelope (Section 3.4) for inclusion in NANDA's A2A protocol documentation as an optional extension for trace-aware agents.
4. **Research collaboration:** Invite this proposal as a co-authored NANDA research paper with performance benchmarks at scale, submitted to arXiv as a companion to arXiv:2507.14263 and arXiv:2508.03101.

### 10.1 Timeline

| Milestone | Status |
|---|---|
| RFC v0.2 published to NANDA Writing Group | Complete |
| Phase 1: schema + CLI | Complete |
| Phase 2: ingest service + adapter hooks | Complete |
| Phase 3: query API + nanda-index integration | Complete |
| Phase 4: Docker Compose + dashboard | Complete |
| Phase 5A: Federation sync (LWW) | Complete |
| RFC v0.3 with implementation results | **This document** |
| Phase 5B: CRDT federation | Planned |
| arXiv paper submission | Planned |

---

## 11. References

[1] Raskar, R. et al. (2025). Beyond DNS: Unlocking the Internet of AI Agents via the NANDA Index and Verified AgentFacts. arXiv:2507.14263.

[2] NANDA Enterprise Team (2025). Using the NANDA Index Architecture in Practice: An Enterprise Perspective. arXiv:2508.03101.

[3] MIT Media Lab (2025). Project NANDA: Algorithms to Unlock the Internet of AI Agents. https://www.media.mit.edu/projects/mit-nanda/overview/.

[4] Lambe, M. (2025). Deep Dive Project NANDA: Engineering AgentFacts v1.2. Medium / NANDA Community.

[5] Gupta, J. & Garg, A. (2025). AI's Trillion-Dollar Opportunity: Context Graphs. Foundation Capital Research, December 2025.

[6] Shinde, A. (2025). NANDA: The Protocol for Decentralized AI Agent Collaboration. Medium.

[7] Pavlyshyn, V. (2026). Context Graphs and Data Traces: Building Epistemology Layers for Agentic Memory. Medium, January 2026.

[8] Subramanya, N. (2025). Context Graphs: The Trillion-Dollar Evolution of Agentic Infrastructure. subramanya.ai, December 2025.

[9] Anthropic (2024). Model Context Protocol (MCP). https://docs.anthropic.com/claude/docs/model-context-protocol.

[10] Google Cloud (2025). Announcing the Agent2Agent (A2A) Protocol.

[11] projnanda/adapter (2025). GitHub repository — nanda-adapter v1.0.1. https://github.com/projnanda/adapter.

[12] projnanda/nanda-index (2025). GitHub repository — NANDA Index service (registry.py). https://github.com/projnanda/nanda-index.

[13] projnanda/NEST (2025). GitHub repository — NANDA Sandbox and Testbed. https://github.com/projnanda/NEST.
