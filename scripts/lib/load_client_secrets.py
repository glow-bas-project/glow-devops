#!/usr/bin/env python3
"""Load keycloak/client-secrets.yaml (stdlib only, no PyYAML dependency)."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load_client_secrets(path: Path) -> dict[str, str]:
    """Return clientId -> env var name from client-secrets.yaml."""
    if not path.is_file():
        raise FileNotFoundError(path)

    clients: dict[str, str] = {}
    in_clients = False

    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "clients:":
            in_clients = True
            continue
        if not in_clients:
            continue
        # End of clients block (next top-level key).
        if not raw.startswith((" ", "\t")):
            break
        key, sep, value = stripped.partition(":")
        if not sep:
            continue
        client_id = key.strip()
        env_var = value.strip().strip('"').strip("'")
        if client_id and env_var:
            clients[client_id] = env_var

    if not clients:
        raise ValueError(f"No clients defined under 'clients:' in {path}")

    return clients


def load_env_var_names(path: Path) -> list[str]:
    return list(load_client_secrets(path).values())


def main() -> None:
    path = Path(sys.argv[1])
    data = load_client_secrets(path)
    if len(sys.argv) > 2 and sys.argv[2] == "--env-vars":
        for name in data.values():
            print(name)
    else:
        print(json.dumps(data))


if __name__ == "__main__":
    main()
