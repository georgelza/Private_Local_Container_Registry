#!/usr/bin/env bash
#
# recover_registry_ca.sh — restore the registry CA onto the host.
#
# WHY THIS EXISTS
#   ./data/registry/certs/ is generated, not checked in. `make run` mints a fresh
#   ca.crt/ca.key/server.crt/server.key on every bring-up. If that directory is
#   emptied while the registry container keeps running, every TLS check fails —
#   and the CA PRIVATE KEY is gone, so the certs cannot simply be reissued to
#   match the certificate the live registry is still serving.
#
#   The nodes still hold the CA: every one keeps it at
#       /etc/containerd/certs.d/host.docker.internal:<port>/ca.crt
#   because that is where the registry is pulled from. Copying it back out is
#   therefore the correct repair — and unlike regeneration it is VERIFIABLE.
#
#   In this lab the honest answer is usually simpler: `make down` and `make k8s`
#   rebuild the whole chain from scratch. This script exists for when you want
#   to recover the CA without destroying a cluster you have already set up.
#
# USAGE
#   scripts/recover_registry_ca.sh [node-container ...]
#
#   Defaults to every running vcluster node container.
#   Override REGISTRY_HOST if your .env uses a non-default port.
#
# EXIT CODES
#   0  CA recovered and verified against the live registry
#   1  no source found, or the recovered CA does not validate the endpoint
#
# macOS ships bash 3.2: no mapfile.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="$PROJECT_DIR/data/registry/certs"
CA_PATH_IN_CONTAINER="/etc/containerd/certs.d/host.docker.internal:${REGISTRY_HOST:-$(grep -E '^HOST_PORT_REGISTRY=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d= -f2)}/ca.crt"
REGISTRY_URL="${REGISTRY_SCHEME:-https}://localhost:${REGISTRY_HOST:-$(grep -E '^HOST_PORT_REGISTRY=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d= -f2)}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Collect candidate source containers: explicit args, else every vcluster node.
if [ "$#" -gt 0 ]; then
    NODES="$*"
else
    NODES="$(docker ps --format '{{.Names}}' | grep -E '^vcluster\.(node|cp)\.' || true)"
fi
[ -n "$NODES" ] || die "no vcluster node containers found — pass a container name explicitly"

for node in $NODES; do
    if ! docker exec "$node" test -f "$CA_PATH_IN_CONTAINER" 2>/dev/null; then
        continue
    fi
    mkdir -p "$CERTS_DIR"
    # Write atomically: a half-copied CA would fail the preflight with a
    # confusing TLS error instead of "file missing".
    tmp="$(mktemp "$CERTS_DIR/.ca.crt.XXXXXX")"
    if docker cp "$node:$CA_PATH_IN_CONTAINER" "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$CERTS_DIR/ca.crt"
        chmod 0644 "$CERTS_DIR/ca.crt"
        echo "✅ recovered CA from $node → $CERTS_DIR/ca.crt"

        # The recovery is only useful if it actually validates the endpoint.
        if curl -fsS --cacert "$CERTS_DIR/ca.crt" "$REGISTRY_URL/v2/_catalog" >/dev/null 2>&1; then
            echo "✅ verified: the recovered CA validates $REGISTRY_URL"
            echo
            echo "NOTE: ca.key is NOT recoverable from a node — nodes hold only the public"
            echo "      ca.crt. Do not run 'make certs' expecting it to reissue a matching"
            echo "      server cert; that rotates the CA out from under the running nodes."
            echo "      To rebuild the whole chain instead:  make clean && make run"
            exit 0
        fi
        die "recovered CA does NOT validate $REGISTRY_URL — the registry is serving a different cert; run 'make clean && make run' for a consistent rebuild"
    fi
    rm -f "$tmp"
done

die "no CA found at $CA_PATH_IN_CONTAINER on any of: $NODES"