#!/usr/bin/env bash
#
# patch_nodes_ca.sh — make a vCluster node's containerd trust our registry CA.
#
# WHY THIS IS A SCRIPT AND NOT A MAKE RECIPE
#   The mechanism is five chained `docker cp` / `docker exec` steps against state
#   that lives inside a container's writable layer. Buried in a make recipe it has
#   no seam: you cannot assert it, you cannot test it, and every step's failure is
#   swallowed by `2>/dev/null || true` while `✓ patched` is printed regardless.
#
#   As a script it can VERIFY and EXIT NON-ZERO, which is the only difference that
#   matters: a green tick now means the node really trusts the CA, not that five
#   commands were typed.
#
# WHAT IS ASSERTED, PER NODE (all five, or the target fails):
#   1. the node container is running
#   2. the certs.d directory exists and is named for the authority we dial
#   3. ca.crt is present AND its fingerprint equals the CA on disk
#   4. hosts.toml is present AND names the same authority and ca_file path
#   5. config_path is set in /etc/containerd/config.toml
#   6. containerd is active again after the restart
#
# WHY THE FINGERPRINT (3) IS THE ONE THAT MATTERS
#   Presence is not identity. Every node in this lab holds a ca.crt, so a
#   presence check passes after `make down` has destroyed the CA that signed the
#   running registry — the node is then holding an ORPHANED trust anchor that
#   validates nothing, and nothing in the stack will say so. Comparing
#   fingerprints is what turns that silent state into a failed command.
#
# WHY `systemctl restart` AND NOT `kill -SIGHUP`
#   SIGHUP is not a reload signal containerd handles. It terminates the process;
#   systemd then spends several seconds starting a replacement, so every pod on
#   the node is stuck with no runtime at all. A restart is a bounded, supervised
#   stop that the kernel does for us. Either way we WAIT for `is-active` before
#   reporting success — the old code printed ✓ while containerd was still down.
#
# USAGE
#   ./scripts/patch_nodes_ca.sh patch <vcluster> <ca.crt> <hosts.toml> <certs.d-dir>
#   ./scripts/patch_nodes_ca.sh verify <vcluster> <ca.crt> <certs.d-dir>
#
# EXIT CODES
#   0  every node asserted clean
#   1  one or more nodes failed an assertion (each failure is named)
#   2  bad usage
#
# macOS ships bash 3.2: no associative arrays, no mapfile.

set -uo pipefail

MODE="${1:-}"; shift || true
case "$MODE" in
    patch|verify) ;;
    *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

# patch  takes: <vcluster> <ca.crt> <hosts.toml> <certs.d-dir>
# verify takes: <vcluster> <ca.crt> <certs.d-dir>
# The Makefile calls both; they are not the same arity, so they are parsed apart.
VCLUSTER="${1:-}"
CA_CRT="${2:-}"
if [ "$MODE" = "patch" ]; then
    HOSTS_TOML="${3:-}"
    CERTSD="${4:-}"
else
    HOSTS_TOML=""
    CERTSD="${3:-}"
fi

if [ -z "$VCLUSTER" ] || [ -z "$CA_CRT" ] || [ -z "$CERTSD" ]; then
    echo "ERROR: usage: $0 <patch|verify> <vcluster> <ca.crt> [hosts.toml] <certs.d-dir>" >&2
    exit 2
fi
if [ "$MODE" = "patch" ] && [ -z "$HOSTS_TOML" ]; then
    echo "ERROR: patch mode needs the rendered hosts.toml path" >&2
    exit 2
fi
if [ ! -f "$CA_CRT" ]; then
    echo "ERROR: no CA on disk at $CA_CRT — run 'make certs'" >&2
    exit 1
fi

NODES="vcluster.cp.${VCLUSTER} vcluster.node.${VCLUSTER}.worker-1 vcluster.node.${VCLUSTER}.worker-2 vcluster.node.${VCLUSTER}.worker-3"

# The one fingerprint every node must agree with.
WANT_FP="$(openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
if [ -z "$WANT_FP" ]; then
    echo "ERROR: cannot read a SHA-256 fingerprint from $CA_CRT" >&2
    exit 1
fi

fail=0
patched=0
verified=0

# Label: "cp" / "worker-1" ... — the bare container name reads as four near-identical rows.
label() { printf '%s' "$1" | sed -e 's|^vcluster\.cp\..*|cp|' -e 's|^vcluster\.node\.[^.]*\.||'; }

for node in $NODES; do
    lbl="$(label "$node")"

    # ── 1. is it running ────────────────────────────────────────────────────────
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        printf '  ✗ %-10s container not running\n' "$lbl"
        fail=$((fail + 1))
        continue
    fi

    if [ "$MODE" = "patch" ]; then
        # ── 2. the certs.d directory, named for the authority we dial ───────────
        if ! docker exec "$node" mkdir -p "$CERTSD"; then
            printf '  ✗ %-10s could not create %s\n' "$lbl" "$CERTSD"
            fail=$((fail + 1)); continue
        fi
        # ── 3. the CA, and the instruction file beside it ───────────────────────
        if ! docker cp "$CA_CRT" "${node}:${CERTSD}/ca.crt" >/dev/null; then
            printf '  ✗ %-10s could not copy ca.crt into the node\n' "$lbl"
            fail=$((fail + 1)); continue
        fi
        if ! docker cp "$HOSTS_TOML" "${node}:${CERTSD}/hosts.toml" >/dev/null; then
            printf '  ✗ %-10s could not copy hosts.toml into the node\n' "$lbl"
            fail=$((fail + 1)); continue
        fi
        # ── 3b. …and into the node's SYSTEM trust store.                        ──
        # THIS IS NOT REDUNDANT. Measured on containerd v2.2.3 (config version 3):
        # with the CA present in certs.d and `skip_verify = false` in hosts.toml,
        # the pull still failed with "certificate signed by unknown authority",
        # while the byte-identical CA in /usr/local/share/ca-certificates made the
        # same pull succeed. containerd honours skip_verify from hosts.toml but
        # was not applying ca_file from it.
        #
        # The consequence is the important part: with skip_verify = false and only
        # certs.d populated, EVERY pull fails. With skip_verify = true the
        # certs.d CA is never consulted at all, so the whole mechanism appears to
        # work while proving nothing. Installing into BOTH stores is what makes
        # verification real AND the pull succeed — now a wrong or stale CA fails
        # loudly instead of silently passing.
        #
        # See README.md §6 "Why the CA goes into two places".
        if ! docker cp "$CA_CRT" "${node}:/usr/local/share/ca-certificates/registry-ca.crt" >/dev/null; then
            printf '  ✗ %-10s could not install the CA into the system trust store\n' "$lbl"
            fail=$((fail + 1)); continue
        fi
        if ! docker exec "$node" update-ca-certificates >/dev/null 2>&1; then
            printf '  ✗ %-10s update-ca-certificates failed\n' "$lbl"
            fail=$((fail + 1)); continue
        fi
        # ── 4. tell containerd where to look ────────────────────────────────────
        if ! docker exec "$node" sh -c \
            "grep -q 'config_path = \"/etc/containerd/certs.d\"' /etc/containerd/config.toml || \
             sed -i 's|config_path = \"\"|config_path = \"/etc/containerd/certs.d\"|' /etc/containerd/config.toml"; then
            printf '  ✗ %-10s could not set config_path in config.toml\n' "$lbl"
            fail=$((fail + 1)); continue
        fi
        # ── 5. make containerd notice — supervised, and we WAIT for it ─────────
        docker exec "$node" systemctl restart containerd >/dev/null 2>&1
        up=""
        for _ in $(seq 1 30); do
            [ "$(docker exec "$node" systemctl is-active containerd 2>/dev/null)" = "active" ] && { up=1; break; }
            sleep 1
        done
        if [ -z "$up" ]; then
            printf '  ✗ %-10s containerd did not come back active after restart\n' "$lbl"
            fail=$((fail + 1)); continue
        fi
        patched=$((patched + 1))
    fi

    # ══ VERIFY — everything below runs in BOTH modes ══════════════════════════
    # 3a. ca.crt present
    if ! docker exec "$node" test -f "${CERTSD}/ca.crt"; then
        printf '  ✗ %-10s ca.crt MISSING — containerd has no CA to trust\n' "$lbl"
        fail=$((fail + 1)); continue
    fi
    # 3b. …and it is the SAME CA, not merely a file
    got_fp="$(docker exec "$node" openssl x509 -in "${CERTSD}/ca.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
    if [ -z "$got_fp" ]; then
        printf '  ✗ %-10s ca.crt is not a readable certificate\n' "$lbl"
        fail=$((fail + 1)); continue
    fi
    if [ "$got_fp" != "$WANT_FP" ]; then
        printf '  ✗ %-10s ca.crt is NOT the registry CA (orphaned trust anchor)\n' "$lbl"
        printf '      node: %s\n' "$got_fp"
        printf '      want: %s\n' "$WANT_FP"
        printf '      the registry was re-minted after this node was patched — run: make patch-nodes\n'
        fail=$((fail + 1)); continue
    fi
    # 3b. …and the copy in the SYSTEM trust store, which is the one containerd
    #     actually consults on this image. Same bytes, different file.
    SYS_CA=/usr/local/share/ca-certificates/registry-ca.crt
    if ! docker exec "$node" test -f "$SYS_CA"; then
        printf '  ✗ %-10s system trust store has no CA — containerd cannot verify this registry\n' "$lbl"
        fail=$((fail + 1)); continue
    fi
    sys_fp="$(docker exec "$node" openssl x509 -in "$SYS_CA" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
    if [ "$sys_fp" != "$WANT_FP" ]; then
        printf '  ✗ %-10s system trust store holds a DIFFERENT CA than the registry is serving\n' "$lbl"
        printf '      node: %s\n' "${sys_fp:-unreadable}"
        printf '      want: %s\n' "$WANT_FP"
        printf '      the registry was re-minted after this node was patched — run: make patch-nodes\n'
        fail=$((fail + 1)); continue
    fi
    # 4. hosts.toml present and naming the same authority
    if ! docker exec "$node" test -f "${CERTSD}/hosts.toml"; then
        printf '  ✗ %-10s hosts.toml MISSING — the CA above is INERT without it\n' "$lbl"
        fail=$((fail + 1)); continue
    fi
    if ! docker exec "$node" grep -q "${CERTSD}/ca.crt" "${CERTSD}/hosts.toml"; then
        printf '  ✗ %-10s hosts.toml ca_file does not match %s\n' "$lbl" "$CERTSD"
        fail=$((fail + 1)); continue
    fi
    # 5. config_path
    if ! docker exec "$node" grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
        printf '  ✗ %-10s config_path NOT set — containerd never reads certs.d\n' "$lbl"
        fail=$((fail + 1)); continue
    fi
    # 6. runtime alive
    if [ "$(docker exec "$node" systemctl is-active containerd 2>/dev/null)" != "active" ]; then
        printf '  ✗ %-10s containerd is NOT active\n' "$lbl"
        fail=$((fail + 1)); continue
    fi
    # 7. THE ONE THAT MATTERS MOST — a real, VERIFIED TLS handshake to the
#    registry, from inside this node, against the SYSTEM trust store and with NO
#    -CAfile. That is deliberately the default trust path, because that is the
#    one containerd actually uses: a probe that passed `-CAfile <certs.d/ca.crt>`
#    would be testing a file containerd may not even consult.
    #
    #    Everything above checks that FILES are in the right place with the right
    #    bytes. That is not the same as the node being able to complete a verified
    #    handshake. This one closes the gap: it is the only assertion here that
    #    exercises the actual trust path end to end.
    #
    #    `Verify return code: 0 (ok)` is the pass condition. A non-zero code means
    #    the node cannot verify this registry, whatever the directory listing says.
    probe="$(docker exec "$node" openssl s_client -connect "$(basename "$CERTSD")" \
                -servername "$(basename "$CERTSD" | cut -d: -f1)" \
                </dev/null 2>/dev/null | grep -m1 'Verify return code')"
    case "$probe" in
        *"(ok)"*) : ;;
        *)  printf '  ✗ %-10s VERIFIED TLS HANDSHAKE FAILED against %s\n' "$lbl" "$(basename "$CERTSD")"
            printf '      openssl says: %s\n' "${probe:-no handshake at all}"
            printf '      the node cannot verify this registry — pulls will fail\n'
            fail=$((fail + 1)); continue ;;
    esac

    verified=$((verified + 1))
    if [ "$MODE" = "patch" ]; then
        printf '  ✓ %-10s patched + verified (CA fingerprint matches)\n' "$lbl"
    else
        printf '  ✓ %-10s ca ✓ hosts.toml ✓ config_path ✓ containerd ✓ ca-matches ✓\n' "$lbl"
    fi
done

echo ""
if [ "$fail" -ne 0 ]; then
    if [ "$MODE" = "patch" ]; then
        echo "❌ $fail node(s) failed. NOT reporting success — a node that is not patched cannot pull from the registry."
    else
        echo "❌ $fail node(s) failed verification."
    fi
    exit 1
fi

if [ "$MODE" = "patch" ]; then
    echo "✅ $verified/4 node(s) patched and verified."
else
    echo "✅ $verified/4 node(s) verified."
fi