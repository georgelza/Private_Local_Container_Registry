#!/usr/bin/env bash
#
# recover_registry_ca.sh — restore the local registry CA certificate.
#
# WHY THIS EXISTS
#   deploy/data/registry/certs/ is generated, not source-controlled: `make run`
#   regenerates ca.crt/ca.key/server.crt/server.key on every stack bring-up
#   (short-lived by design). If that directory is ever emptied while the
#   registry container keeps running, every `make build` fails at the
#   TLS preflight, and the CA PRIVATE KEY is unrecoverable — so the certs
#   cannot simply be regenerated to match the live server certificate.
#
#   The nodes still hold the CA: each vcluster worker has it at
#   /etc/containerd/certs.d/host.docker.internal:5001/ca.crt, because the
#   registry is pulled from host.docker.internal. Copying it back is therefore
#   the correct repair — and it is verifiable, which regeneration is not.
#
# USAGE
#   deploy/scripts/recover_registry_ca.sh [node-container ...]
#
#   Defaults to every `vcluster.node.*` container. Override REGISTRY_HOST to
#   match a non-default registry port.
#
# EXIT CODES
#   0  CA recovered and verified against the live registry
#   1  no source found, or the recovered CA does not validate the endpoint
#
# License:
#   See <project root>/License.md

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="$DEPLOY_DIR/data/registry/certs"
CA_PATH_IN_CONTAINER="/etc/containerd/certs.d/host.docker.internal:${REGISTRY_HOST:-5001}/ca.crt"
REGISTRY_URL="${REGISTRY_SCHEME:-https}://localhost:${REGISTRY_HOST:-5001}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Collect candidate source containers: explicit args, else every vcluster node.
# NOTE: no mapfile — macOS ships bash 3.2, where it does not exist.
if [ "$#" -gt 0 ]; then
    NODES="$*"
else
    NODES="$(docker ps --format '{{.Names}}' | grep -E '^vcluster\.node\.' || true)"
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
            echo "NOTE: ca.key is NOT recoverable. Do not run 'make certs' expecting it to"
            echo "      reissue a matching server cert — that would rotate the CA out from"
            echo "      under the running nodes. A full 'make run' regenerates BOTH sides"
            echo "      consistently and re-copies the CA to every node."
            exit 0
        fi
        die "recovered CA does NOT validate $REGISTRY_URL — the registry is serving a different cert; run 'make run' for a consistent regeneration"
    fi
    rm -f "$tmp"
done

die "no CA found at $CA_PATH_IN_CONTAINER on any of: $NODES"
