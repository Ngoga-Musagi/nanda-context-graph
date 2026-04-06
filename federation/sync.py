"""Federation sync — last-write-wins replication between NCG instances.

Phase 5A: simple push/pull with Neo4j MERGE for idempotency.
Phase 5B (future): CRDT vector clocks on Decision nodes.

Each NCG instance exposes GET /federation/traces?since_ms=<epoch_ms>
which returns DecisionTrace JSON for traces newer than since_ms.
"""

import logging
import os
import threading
import time
from dataclasses import dataclass, field

import httpx

from schema.models import DecisionTrace
from store.neo4j_adapter import Neo4jAdapter

logger = logging.getLogger("ncg.federation")


@dataclass
class FederationPeer:
    """Represents another NCG instance at a known URL."""

    url: str
    name: str = ""
    last_sync_ms: int = 0
    healthy: bool = True
    _consecutive_failures: int = field(default=0, repr=False)

    def __post_init__(self):
        self.url = self.url.rstrip("/")
        if not self.name:
            self.name = self.url


def push_trace(trace_id: str, peer_url: str, graph: Neo4jAdapter) -> bool:
    """Send a single trace to another NCG instance via its ingest endpoint.

    Returns True if the remote accepted (2xx), False otherwise.
    """
    peer_url = peer_url.rstrip("/")
    trace_data = graph.get_trace(trace_id)
    if not trace_data:
        logger.warning("push_trace: trace %s not found locally", trace_id)
        return False

    # Reconstruct full trace with steps for the remote ingest API
    try:
        resp = httpx.post(
            f"{peer_url}/ingest/trace",
            json=trace_data,
            timeout=10.0,
        )
        if resp.status_code in (200, 202):
            logger.info("Pushed trace %s to %s", trace_id, peer_url)
            return True
        logger.warning(
            "push_trace %s to %s: HTTP %d", trace_id, peer_url, resp.status_code
        )
        return False
    except httpx.HTTPError as exc:
        logger.error("push_trace %s to %s failed: %s", trace_id, peer_url, exc)
        return False


def pull_recent(
    peer_url: str, since_ms: int, graph: Neo4jAdapter
) -> int:
    """Pull traces from a peer since a timestamp and write them locally.

    Returns the number of traces written.
    """
    peer_url = peer_url.rstrip("/")
    try:
        resp = httpx.get(
            f"{peer_url}/federation/traces",
            params={"since_ms": since_ms},
            timeout=15.0,
        )
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        logger.error("pull_recent from %s failed: %s", peer_url, exc)
        return 0

    traces = resp.json()
    if not isinstance(traces, list):
        logger.warning("pull_recent from %s: expected list, got %s", peer_url, type(traces).__name__)
        return 0

    written = 0
    for raw in traces:
        try:
            trace = DecisionTrace(**raw)
            graph.write_trace(trace)  # MERGE makes this idempotent
            written += 1
        except Exception as exc:
            logger.warning("pull_recent: skipping bad trace: %s", exc)

    if written:
        logger.info("Pulled %d traces from %s (since_ms=%d)", written, peer_url, since_ms)
    return written


def sync_loop(
    peers: list[FederationPeer],
    graph: Neo4jAdapter,
    interval_s: int = 60,
    stop_event: threading.Event | None = None,
) -> None:
    """Background loop that syncs with all peers on a fixed interval.

    Runs until stop_event is set (or forever if None).
    Each cycle pulls traces newer than the peer's last_sync_ms.
    """
    _stop = stop_event or threading.Event()
    logger.info(
        "Federation sync loop started: %d peers, interval=%ds",
        len(peers),
        interval_s,
    )

    while not _stop.is_set():
        for peer in peers:
            try:
                count = pull_recent(peer.url, peer.last_sync_ms, graph)
                if count > 0:
                    peer.last_sync_ms = int(time.time() * 1000)
                peer.healthy = True
                peer._consecutive_failures = 0
            except Exception as exc:
                peer._consecutive_failures += 1
                if peer._consecutive_failures >= 3:
                    peer.healthy = False
                logger.error(
                    "Sync with %s failed (%d consecutive): %s",
                    peer.name,
                    peer._consecutive_failures,
                    exc,
                )

        _stop.wait(timeout=interval_s)


def start_sync_thread(
    graph: Neo4jAdapter,
    interval_s: int = 60,
) -> tuple[threading.Thread, threading.Event]:
    """Parse NCG_FEDERATION_PEERS env var and start the sync loop in a daemon thread.

    Env var format: comma-separated URLs, e.g.
      NCG_FEDERATION_PEERS=http://peer1:7201,http://peer2:7201

    Returns (thread, stop_event) so the caller can shut it down.
    """
    raw = os.getenv("NCG_FEDERATION_PEERS", "")
    urls = [u.strip() for u in raw.split(",") if u.strip()]
    if not urls:
        logger.info("No federation peers configured (NCG_FEDERATION_PEERS is empty)")
        return None, None

    peers = [FederationPeer(url=u) for u in urls]
    stop_event = threading.Event()

    thread = threading.Thread(
        target=sync_loop,
        args=(peers, graph, interval_s, stop_event),
        daemon=True,
        name="ncg-federation-sync",
    )
    thread.start()
    logger.info("Federation sync thread started for peers: %s", urls)
    return thread, stop_event
