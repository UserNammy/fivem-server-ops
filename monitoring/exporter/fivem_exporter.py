"""Prometheus exporter for a FiveM (FXServer) game server.

FXServer exposes public JSON endpoints on its game port:
  /info.json     server convars (sv_maxClients...), resources, version
  /players.json  list of connected players (id, name, ping, ...)

The exporter queries them on every Prometheus scrape (no background polling,
so metrics are never stale) and exposes:

  fivem_up                         1 if both endpoints answered, else 0
  fivem_players_online             connected players
  fivem_players_max                sv_maxClients
  fivem_player_ping_avg_ms         average player ping
  fivem_resources                  number of resources reported
  fivem_http_response_seconds      endpoint latency, labelled by endpoint
  fivem_server_info                constant 1 with version label
  fivem_scrape_errors_total        failed scrapes since exporter start
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Iterable, Tuple

from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily
from prometheus_client.registry import Collector

LOG = logging.getLogger("fivem_exporter")

# A fetcher returns (decoded JSON, elapsed seconds) or raises.
Fetcher = Callable[[str, float], Tuple[Any, float]]


def http_get_json(url: str, timeout: float) -> Tuple[Any, float]:
    """GET a URL and decode its JSON body. Returns (payload, elapsed seconds)."""
    req = urllib.request.Request(url, headers={"User-Agent": "fivem-exporter/1.0"})
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (URL is operator config)
        body = resp.read()
    elapsed = time.perf_counter() - start
    return json.loads(body), elapsed


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


class FiveMCollector(Collector):
    """Custom collector: one scrape of FXServer per Prometheus scrape."""

    def __init__(self, base_url: str, timeout: float = 5.0, fetch: Fetcher = http_get_json):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.fetch = fetch
        self.scrape_errors = 0

    def _get(self, path: str) -> Tuple[Any, float]:
        return self.fetch(f"{self.base_url}{path}", self.timeout)

    def collect(self) -> Iterable:
        up = GaugeMetricFamily("fivem_up", "Whether the FiveM server answered its HTTP endpoints.")
        latency = GaugeMetricFamily(
            "fivem_http_response_seconds",
            "Response time of FXServer HTTP endpoints.",
            labels=["endpoint"],
        )

        try:
            info, info_latency = self._get("/info.json")
            players, players_latency = self._get("/players.json")
            if not isinstance(info, dict) or not isinstance(players, list):
                raise ValueError("unexpected payload shape")
        except (urllib.error.URLError, OSError, ValueError) as exc:
            # json.JSONDecodeError is a ValueError; socket timeouts are OSError.
            self.scrape_errors += 1
            LOG.warning("scrape of %s failed: %s", self.base_url, exc)
            up.add_metric([], 0)
            yield up
            yield self._errors_metric()
            return

        up.add_metric([], 1)
        yield up

        latency.add_metric(["info"], info_latency)
        latency.add_metric(["players"], players_latency)
        yield latency

        online = GaugeMetricFamily("fivem_players_online", "Number of connected players.")
        online.add_metric([], len(players))
        yield online

        variables = info.get("vars") or {}
        max_clients = _int_or_none(variables.get("sv_maxClients"))
        if max_clients is not None:
            gmax = GaugeMetricFamily("fivem_players_max", "Configured player slots (sv_maxClients).")
            gmax.add_metric([], max_clients)
            yield gmax

        pings = [p for p in (_int_or_none(pl.get("ping")) for pl in players if isinstance(pl, dict))
                 if p is not None]
        ping = GaugeMetricFamily("fivem_player_ping_avg_ms", "Average ping of connected players.")
        ping.add_metric([], sum(pings) / len(pings) if pings else 0)
        yield ping

        resources = info.get("resources")
        if isinstance(resources, list):
            res = GaugeMetricFamily("fivem_resources", "Number of resources reported by the server.")
            res.add_metric([], len(resources))
            yield res

        server_info = GaugeMetricFamily(
            "fivem_server_info", "FXServer build information.", labels=["version"]
        )
        server_info.add_metric([str(info.get("server", "unknown"))], 1)
        yield server_info

        yield self._errors_metric()

    def _errors_metric(self) -> CounterMetricFamily:
        errors = CounterMetricFamily(
            "fivem_scrape_errors", "Failed scrapes of the FiveM server since exporter start."
        )
        errors.add_metric([], self.scrape_errors)
        return errors


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    base_url = os.environ.get("FIVEM_URL", "http://127.0.0.1:30120")
    port = int(os.environ.get("EXPORTER_PORT", "9877"))
    timeout = float(os.environ.get("FIVEM_TIMEOUT", "5"))

    REGISTRY.register(FiveMCollector(base_url, timeout))
    start_http_server(port)
    LOG.info("exporter listening on :%d, scraping %s", port, base_url)

    # Exit cleanly on docker stop.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    sys.exit(main())
