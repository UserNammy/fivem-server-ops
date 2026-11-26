import json
import threading
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from prometheus_client import CollectorRegistry, generate_latest

from fivem_exporter import FiveMCollector, http_get_json

INFO = {
    "server": "FXServer-master SERVER v1.0.0.12345 linux",
    "vars": {"sv_maxClients": "64", "sv_projectName": "test"},
    "resources": ["mapmanager", "chat", "spawnmanager", "oxmysql"],
}
PLAYERS = [
    {"id": 1, "name": "alice", "ping": 40},
    {"id": 2, "name": "bob", "ping": 60},
    {"id": 3, "name": "carol", "ping": 80},
]


def fake_fetch(responses):
    """Return a fetcher serving canned payloads keyed by URL path."""

    def fetch(url, timeout):
        for path, payload in responses.items():
            if url.endswith(path):
                if isinstance(payload, Exception):
                    raise payload
                return payload, 0.05
        raise AssertionError(f"unexpected url {url}")

    return fetch


def scrape(collector):
    registry = CollectorRegistry()
    registry.register(collector)
    return registry


def value(registry, name, labels=None):
    return registry.get_sample_value(name, labels or {})


def test_healthy_server_metrics():
    reg = scrape(FiveMCollector("http://srv:30120/", fetch=fake_fetch(
        {"/info.json": INFO, "/players.json": PLAYERS})))

    assert value(reg, "fivem_up") == 1
    assert value(reg, "fivem_players_online") == 3
    assert value(reg, "fivem_players_max") == 64
    assert value(reg, "fivem_player_ping_avg_ms") == 60
    assert value(reg, "fivem_resources") == 4
    assert value(reg, "fivem_http_response_seconds", {"endpoint": "info"}) == 0.05
    assert value(reg, "fivem_server_info",
                 {"version": "FXServer-master SERVER v1.0.0.12345 linux"}) == 1
    assert value(reg, "fivem_scrape_errors_total") == 0


def test_empty_server():
    reg = scrape(FiveMCollector("http://srv:30120", fetch=fake_fetch(
        {"/info.json": INFO, "/players.json": []})))

    assert value(reg, "fivem_up") == 1
    assert value(reg, "fivem_players_online") == 0
    assert value(reg, "fivem_player_ping_avg_ms") == 0


def test_server_down_reports_up_zero_and_counts_errors():
    collector = FiveMCollector("http://srv:30120", fetch=fake_fetch(
        {"/info.json": urllib.error.URLError("connection refused")}))
    reg = scrape(collector)

    assert value(reg, "fivem_up") == 0
    assert value(reg, "fivem_players_online") is None
    # get_sample_value triggers a new collect(), so the counter keeps growing.
    assert value(reg, "fivem_scrape_errors_total") >= 1


def test_timeout_is_handled():
    reg = scrape(FiveMCollector("http://srv:30120", fetch=fake_fetch(
        {"/info.json": TimeoutError("timed out")})))
    assert value(reg, "fivem_up") == 0


def test_malformed_payload_is_handled():
    reg = scrape(FiveMCollector("http://srv:30120", fetch=fake_fetch(
        {"/info.json": INFO, "/players.json": {"not": "a list"}})))
    assert value(reg, "fivem_up") == 0


def test_missing_max_clients_is_skipped():
    info = {"server": "x", "vars": {}}
    reg = scrape(FiveMCollector("http://srv:30120", fetch=fake_fetch(
        {"/info.json": info, "/players.json": PLAYERS})))
    assert value(reg, "fivem_up") == 1
    assert value(reg, "fivem_players_max") is None


def test_exposition_format_is_valid():
    reg = scrape(FiveMCollector("http://srv:30120", fetch=fake_fetch(
        {"/info.json": INFO, "/players.json": PLAYERS})))
    text = generate_latest(reg).decode()
    assert "# TYPE fivem_up gauge" in text
    assert "fivem_players_online 3.0" in text


@pytest.fixture
def fake_fxserver():
    """A real HTTP server mimicking FXServer, to test the default fetcher."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            payload = {"/info.json": INFO, "/players.json": PLAYERS}.get(self.path)
            if payload is None:
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


def test_http_get_json_against_real_socket(fake_fxserver):
    payload, elapsed = http_get_json(f"{fake_fxserver}/players.json", timeout=2)
    assert len(payload) == 3
    assert elapsed >= 0


def test_end_to_end_with_default_fetcher(fake_fxserver):
    reg = scrape(FiveMCollector(fake_fxserver, timeout=2))
    assert value(reg, "fivem_up") == 1
    assert value(reg, "fivem_players_online") == 3


def test_404_endpoint_marks_down(fake_fxserver):
    reg = scrape(FiveMCollector(f"{fake_fxserver}/nope", timeout=2))
    assert value(reg, "fivem_up") == 0
