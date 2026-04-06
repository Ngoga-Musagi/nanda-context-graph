import { useState } from "react";

const API = "http://localhost:7201";

export default function App() {
  const [agentId, setAgentId] = useState("");
  const [decision, setDecision] = useState(null);
  const [history, setHistory] = useState([]);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);

  async function fetchWhy() {
    if (!agentId.trim()) return;
    setLoading(true);
    setError(null);
    try {
      const [whyRes, histRes] = await Promise.all([
        fetch(`${API}/api/v1/why?agent_id=${encodeURIComponent(agentId)}`),
        fetch(`${API}/api/v1/agent/${encodeURIComponent(agentId)}/history?limit=10`),
      ]);
      if (whyRes.ok) {
        setDecision(await whyRes.json());
      } else {
        setDecision(null);
        setError(`why: ${whyRes.status} ${(await whyRes.json()).detail}`);
      }
      if (histRes.ok) {
        const data = await histRes.json();
        setHistory(data.traces || []);
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div style={styles.container}>
      <h1 style={styles.title}>NANDA Context Graph</h1>

      <div style={styles.controls}>
        <input
          style={styles.input}
          type="text"
          placeholder="Agent ID"
          value={agentId}
          onChange={(e) => setAgentId(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && fetchWhy()}
        />
        <button style={styles.button} onClick={fetchWhy} disabled={loading}>
          {loading ? "Loading..." : "Why did this agent act?"}
        </button>
      </div>

      {error && <div style={styles.error}>{error}</div>}

      {decision && <DecisionTree decision={decision} />}

      {history.length > 0 && <HistoryTable traces={history} />}
    </div>
  );
}

function DecisionTree({ decision }) {
  const [open, setOpen] = useState(true);
  const d = decision.decision;
  const steps = decision.steps || [];

  return (
    <div style={styles.card}>
      <h2
        style={{ ...styles.cardTitle, cursor: "pointer" }}
        onClick={() => setOpen(!open)}
      >
        {open ? "\u25BC" : "\u25B6"} Latest Decision
      </h2>
      {open && (
        <div>
          <Row label="Trace ID" value={d.trace_id} />
          <Row label="Outcome" value={<Badge outcome={d.outcome} />} />
          <Row label="Timestamp" value={new Date(d.timestamp_ms).toISOString()} />
          <Row label="Duration" value={d.duration_ms != null ? `${d.duration_ms}ms` : "-"} />

          {steps.length > 0 && (
            <div style={{ marginTop: 12 }}>
              <strong>Steps ({steps.length})</strong>
              {steps.map((s, i) => (
                <StepItem key={s.step_id || i} step={s} index={i} />
              ))}
            </div>
          )}
          {steps.length === 0 && (
            <p style={styles.muted}>No reasoning steps recorded.</p>
          )}
        </div>
      )}
    </div>
  );
}

function StepItem({ step, index }) {
  const [open, setOpen] = useState(false);

  return (
    <div style={styles.step}>
      <div
        style={{ cursor: "pointer", fontWeight: 500 }}
        onClick={() => setOpen(!open)}
      >
        {open ? "\u25BC" : "\u25B6"} Step {index + 1}: {step.step_type}
        {step.tool_name ? ` \u2014 ${step.tool_name}` : ""}
      </div>
      {open && (
        <div style={styles.stepDetail}>
          <Row label="Thought" value={step.thought} />
          {step.tool_name && <Row label="Tool" value={step.tool_name} />}
          {step.confidence != null && (
            <Row label="Confidence" value={step.confidence} />
          )}
          {step.duration_ms != null && (
            <Row label="Duration" value={`${step.duration_ms}ms`} />
          )}
        </div>
      )}
    </div>
  );
}

function HistoryTable({ traces }) {
  return (
    <div style={styles.card}>
      <h2 style={styles.cardTitle}>Agent History (last {traces.length})</h2>
      <table style={styles.table}>
        <thead>
          <tr>
            <th style={styles.th}>Trace ID</th>
            <th style={styles.th}>Outcome</th>
            <th style={styles.th}>Timestamp</th>
            <th style={styles.th}>Duration</th>
          </tr>
        </thead>
        <tbody>
          {traces.map((t) => (
            <tr key={t.trace_id}>
              <td style={styles.td}>
                <code>{t.trace_id}</code>
              </td>
              <td style={styles.td}>
                <Badge outcome={t.outcome} />
              </td>
              <td style={styles.td}>
                {new Date(t.timestamp_ms).toISOString().slice(0, 19)}
              </td>
              <td style={styles.td}>
                {t.duration_ms != null ? `${t.duration_ms}ms` : "-"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Badge({ outcome }) {
  const colors = {
    success: "#22c55e",
    failure: "#ef4444",
    error: "#f97316",
    delegated: "#3b82f6",
  };
  return (
    <span
      style={{
        background: colors[outcome] || "#6b7280",
        color: "#fff",
        padding: "2px 8px",
        borderRadius: 4,
        fontSize: 12,
        fontWeight: 600,
      }}
    >
      {outcome}
    </span>
  );
}

function Row({ label, value }) {
  return (
    <div style={{ display: "flex", gap: 8, padding: "2px 0" }}>
      <span style={{ color: "#6b7280", minWidth: 90 }}>{label}:</span>
      <span>{value}</span>
    </div>
  );
}

const styles = {
  container: {
    maxWidth: 800,
    margin: "0 auto",
    padding: 24,
    fontFamily: "system-ui, -apple-system, sans-serif",
    color: "#1f2937",
  },
  title: { fontSize: 24, fontWeight: 700, marginBottom: 24 },
  controls: { display: "flex", gap: 8, marginBottom: 16 },
  input: {
    flex: 1,
    padding: "8px 12px",
    border: "1px solid #d1d5db",
    borderRadius: 6,
    fontSize: 14,
  },
  button: {
    padding: "8px 16px",
    background: "#2563eb",
    color: "#fff",
    border: "none",
    borderRadius: 6,
    fontSize: 14,
    cursor: "pointer",
  },
  error: {
    background: "#fef2f2",
    color: "#dc2626",
    padding: "8px 12px",
    borderRadius: 6,
    marginBottom: 16,
  },
  card: {
    border: "1px solid #e5e7eb",
    borderRadius: 8,
    padding: 16,
    marginBottom: 16,
  },
  cardTitle: { fontSize: 16, fontWeight: 600, marginBottom: 12 },
  step: {
    marginLeft: 16,
    padding: "6px 0",
    borderLeft: "2px solid #d1d5db",
    paddingLeft: 12,
    marginTop: 4,
  },
  stepDetail: { paddingLeft: 8, marginTop: 4, fontSize: 13 },
  muted: { color: "#9ca3af", fontStyle: "italic" },
  table: { width: "100%", borderCollapse: "collapse", fontSize: 13 },
  th: {
    textAlign: "left",
    padding: "6px 8px",
    borderBottom: "2px solid #e5e7eb",
    fontSize: 12,
    color: "#6b7280",
    textTransform: "uppercase",
  },
  td: { padding: "6px 8px", borderBottom: "1px solid #f3f4f6" },
};
