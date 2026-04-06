"""Neo4j graph store for decision traces.

Follows SKILL-09 from SKILLS.md. All writes use explicit transactions.
Node/edge types match CLAUDE.md section 5 (Graph Node/Edge Types).

Manual Neo4j start (do NOT auto-start):
  docker run -d --name ncg-neo4j -p 7474:7474 -p 7687:7687 \
    -e NEO4J_AUTH=neo4j/password neo4j:5
"""

from neo4j import GraphDatabase

from schema.models import DecisionTrace


class Neo4jAdapter:
    def __init__(self, uri: str, user: str, password: str):
        self._driver = GraphDatabase.driver(
            uri, auth=(user, password), max_transaction_retry_time=5.0
        )

    # ── writes ───────────────────────────────────────────────────────

    def write_trace(self, trace: DecisionTrace) -> None:
        """Write a complete DecisionTrace as a subgraph to Neo4j."""
        with self._driver.session() as session:
            session.execute_write(self._create_trace_subgraph, trace)

    @staticmethod
    def _create_trace_subgraph(tx, trace: DecisionTrace) -> None:
        # Upsert Agent node
        tx.run(
            """
            MERGE (a:Agent {agent_id: $agent_id})
            ON CREATE SET a.handle = $handle, a.first_seen_ms = $ts
            ON MATCH  SET a.last_seen_ms = $ts
            """,
            agent_id=trace.agent_id,
            handle=trace.agent_handle or "",
            ts=trace.timestamp_ms,
        )

        # Upsert Decision node (MERGE for federation idempotency)
        tx.run(
            """
            MERGE (d:Decision {trace_id: $trace_id})
            ON CREATE SET d.outcome = $outcome, d.timestamp_ms = $ts, d.duration_ms = $dur
            ON MATCH  SET d.outcome = $outcome, d.duration_ms = $dur
            """,
            trace_id=trace.trace_id,
            outcome=trace.outcome,
            ts=trace.timestamp_ms,
            dur=trace.duration_ms or 0,
        )

        # MADE_BY: Decision → Agent
        tx.run(
            """
            MATCH (a:Agent {agent_id: $agent_id})
            MATCH (d:Decision {trace_id: $trace_id})
            MERGE (d)-[:MADE_BY]->(a)
            """,
            agent_id=trace.agent_id,
            trace_id=trace.trace_id,
        )

        # PRECEDED_BY: Decision → parent Decision (causal chain)
        if trace.parent_trace_id:
            tx.run(
                """
                MATCH (d:Decision {trace_id: $trace_id})
                MATCH (p:Decision {trace_id: $parent_id})
                MERGE (d)-[:PRECEDED_BY]->(p)
                """,
                trace_id=trace.trace_id,
                parent_id=trace.parent_trace_id,
            )

        # Create Step nodes + DECIDED_BECAUSE edges
        for step in trace.steps:
            tx.run(
                """
                CREATE (s:Step {
                    step_id:   $step_id,
                    step_type: $type,
                    thought:   $thought,
                    tool_name: $tool
                })
                """,
                step_id=step.step_id,
                type=step.step_type,
                thought=step.thought,
                tool=step.tool_name or "",
            )

            tx.run(
                """
                MATCH (d:Decision {trace_id: $trace_id})
                MATCH (s:Step {step_id: $step_id})
                MERGE (d)-[:DECIDED_BECAUSE]->(s)
                """,
                trace_id=trace.trace_id,
                step_id=step.step_id,
            )

    def append_step(self, parent_trace_id: str, step: dict) -> bool:
        """Append a Step node to an existing Decision. Returns True if Decision was found."""
        with self._driver.session() as session:
            result = session.execute_write(
                self._create_and_link_step, parent_trace_id, step
            )
            return result

    @staticmethod
    def _create_and_link_step(tx, parent_trace_id: str, step: dict) -> bool:
        # Check Decision exists
        check = tx.run(
            "MATCH (d:Decision {trace_id: $tid}) RETURN d",
            tid=parent_trace_id,
        )
        if not check.single():
            return False

        tx.run(
            """
            CREATE (s:Step {
                step_id:   $step_id,
                step_type: $type,
                thought:   $thought,
                tool_name: $tool
            })
            """,
            step_id=step.get("step_id", ""),
            type=step.get("step_type", "execute"),
            thought=step.get("thought", ""),
            tool=step.get("tool_name", ""),
        )
        tx.run(
            """
            MATCH (d:Decision {trace_id: $trace_id})
            MATCH (s:Step {step_id: $step_id})
            MERGE (d)-[:DECIDED_BECAUSE]->(s)
            """,
            trace_id=parent_trace_id,
            step_id=step.get("step_id", ""),
        )
        return True

    # ── reads ────────────────────────────────────────────────────────

    def get_trace(self, trace_id: str) -> dict | None:
        """Return full trace subgraph as a dict, or None if not found."""
        with self._driver.session() as session:
            result = session.run(
                """
                MATCH (d:Decision {trace_id: $trace_id})-[:MADE_BY]->(a:Agent)
                OPTIONAL MATCH (d)-[:DECIDED_BECAUSE]->(s:Step)
                RETURN d, a, collect(s) AS steps
                """,
                trace_id=trace_id,
            )
            record = result.single()
            if not record:
                return None
            return {
                "trace_id": record["d"]["trace_id"],
                "agent_id": record["a"]["agent_id"],
                "outcome": record["d"]["outcome"],
                "timestamp_ms": record["d"]["timestamp_ms"],
                "duration_ms": record["d"]["duration_ms"],
                "steps": [dict(s) for s in record["steps"]],
            }

    def get_agent_history(
        self, agent_id: str, limit: int = 20, outcome: str | None = None
    ) -> list[dict]:
        """Return paginated decision history for an agent."""
        with self._driver.session() as session:
            if outcome:
                result = session.run(
                    """
                    MATCH (a:Agent {agent_id: $agent_id})<-[:MADE_BY]-(d:Decision)
                    WHERE d.outcome = $outcome
                    RETURN d ORDER BY d.timestamp_ms DESC LIMIT $limit
                    """,
                    agent_id=agent_id,
                    outcome=outcome,
                    limit=limit,
                )
            else:
                result = session.run(
                    """
                    MATCH (a:Agent {agent_id: $agent_id})<-[:MADE_BY]-(d:Decision)
                    RETURN d ORDER BY d.timestamp_ms DESC LIMIT $limit
                    """,
                    agent_id=agent_id,
                    limit=limit,
                )
            return [dict(r["d"]) for r in result]

    # ── lifecycle ────────────────────────────────────────────────────

    def close(self) -> None:
        self._driver.close()
