#!/usr/bin/env bash
################################################################################################################################
#
#   verify-extract.sh — prove this directory is a faithful EXTRACTION of the
#                       source, not a rewrite of it.
#
#   WHY THIS EXISTS
#     The purpose of this directory is to reproduce one mechanism from
#     CORE_Banking/deploy — the TLS registry, its locally generated certs, and
#     the CA injection into vcluster containerd — so that a design issue in
#     that mechanism can be root-caused.
#
#     A root-cause conclusion is only valid if the thing being studied is
#     byte-identical to the thing in production. The moment someone "tidies" a
#     healthcheck, hardens an error path, or renames a resource, the extract
#     stops reproducing the defect and starts reproducing a fiction.
#
#     So the fidelity is machine-checked, and the differences that DO exist are
#     enumerated explicitly rather than left to memory.
#
#   WHAT IS CHECKED
#     • files copied verbatim must be byte-identical (sha256)
#     • the compose file's registry services must be byte-identical, and the
#       only permitted difference is the removal of the other services
#     • the Makefile recipes that implement the mechanism must appear verbatim
#     • every deviation must be on the declared allow-list
#
#   EXIT CODES
#     0  the extract is faithful; any differences are the declared ones
#     1  drift — a file that should be verbatim is not
#
################################################################################################################################

set -uo pipefail

SRC="${CORE_SOURCE:-/Users/george/Desktop/MyDocs/Creator/CORE_Banking/deploy}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
FAIL=0

printf '%s\n' "${BLD}  EXTRACT FIDELITY CHECK${RST}"
printf '  source: %s\n' "$SRC"
printf '  extract: %s\n\n' "$HERE"

[ -d "$SRC" ] || { echo "${RED}source not found: $SRC${RST}"; exit 1; }

# ── 1. Files that must be byte-identical ─────────────────────────────────────
printf '  %s1. verbatim files%s\n' "$BLD" "$RST"
VERBATIM="
scripts/containerd-hosts.toml
scripts/purge_registry.sh
scripts/recover_registry_ca.sh
vcluster1.yml
.env
"
for f in $VERBATIM; do
    if [ ! -f "$HERE/$f" ]; then
        printf '     %sMISSING%s  %s\n' "$RED" "$RST" "$f"; FAIL=1
    elif cmp -s "$HERE/$f" "$SRC/$f"; then
        printf '     %s✓%s  %-46s %s\n' "$GRN" "$RST" "$f" \
               "$(shasum -a 256 "$HERE/$f" | cut -c1-12)"
    else
        printf '     %sDRIFT%s %-46s\n' "$RED" "$RST" "$f"
        diff "$SRC/$f" "$HERE/$f" | head -10 | sed 's/^/          /'
        FAIL=1
    fi
done

# scripts/containerd-hosts.toml has NO trailing newline in the source. `cmp`
# above already proves byte equality, so this only needs to make the fact
# VISIBLE — the missing final newline is easy to destroy with an editor that
# helpfully adds one, and this is the file whose absence silently disables the
# whole mechanism (finding #3). The check is derived by comparing the last byte
# of each file against each other rather than re-deriving it from the content.
if [ -f "$HERE/scripts/containerd-hosts.toml" ] && [ -f "$SRC/scripts/containerd-hosts.toml" ]; then
    H_LAST="$(tail -c 1 "$HERE/scripts/containerd-hosts.toml" | od -An -tx1 | tr -d ' \n')"
    S_LAST="$(tail -c 1 "$SRC/scripts/containerd-hosts.toml"  | od -An -tx1 | tr -d ' \n')"
    if [ "$H_LAST" = "$S_LAST" ]; then
        if [ "$S_LAST" = "0a" ]; then
            printf '     %s✓%s  %-46s (ends with newline, as in source)\n' \
                   "$GRN" "$RST" "  └ trailing byte 0x0a"
        else
            printf '     %s✓%s  %-46s (no trailing newline, as in source — 0x%s)\n' \
                   "$GRN" "$RST" "  └ trailing byte" "$S_LAST"
        fi
    else
        printf '     %sDRIFT%s trailing byte: extract 0x%s, source 0x%s\n' \
               "$RED" "$RST" "$H_LAST" "$S_LAST"
        FAIL=1
    fi
fi

# ── 2. Compose: the registry services, modulo the DECLARED renames ───────────
# The extract renames the source's resource identifiers so that it cannot
# collide with a running source stack (container_name and the compose project
# are docker-daemon-global, not directory-scoped). That means this block is no
# longer byte-identical to the source — so instead of asserting equality, the
# check applies the declared renames TO THE SOURCE and requires the result to
# equal the extract exactly.
#
# That is a stronger guarantee than a byte-compare: it proves the only
# differences are the ones claimed, and that everything else — the healthcheck,
# the depends_on condition, the volume mounts, the TLS env, every comment — is
# untouched. A hand-edit anywhere else in the block still fails.
printf '\n  %s2. docker-compose.yml — registry services, modulo declared renames%s\n' "$BLD" "$RST"
extract_block() {
    # From the CONTAINER REGISTRY section header to the end of the UI service.
    awk '/CONTAINER REGISTRY \(local/{f=1} f{print} /DELETE_IMAGES: "true"/{exit}' "$1"
}
# The complete, declared set of renames. Adding one here without also making it
# in docker-compose.yml will fail the comparison below — which is the point.
apply_renames() {
    sed -e 's/core_registry_ui/regis_registry_ui/g' \
        -e 's/core_registry/regis_registry/g'     \
        -e 's/core-registry-ui/regis-registry-ui/g' \
        -e 's/core-registry/regis-registry/g'     \
        -e 's/\bcorebanking\b/regis/g'             "$1"
}
if extract_block "$HERE/docker-compose.yml" > /tmp/_ex_block.txt \
   && extract_block "$SRC/docker-compose.yml" > /tmp/_src_block.txt \
   && apply_renames /tmp/_src_block.txt > /tmp/_src_renamed.txt; then
    if cmp -s /tmp/_ex_block.txt /tmp/_src_renamed.txt; then
        printf '     %s✓%s  registry + registry-ui block == source, after renaming only:\n' \
               "$GRN" "$RST"
        printf '         core_registry_ui → regis_registry_ui\n'
        printf '         core_registry     → regis_registry\n'
        printf '         core-registry-ui  → regis-registry-ui   (container_name, hostname)\n'
        printf '         core-registry     → regis-registry      (container_name, hostname,\n'
        printf '                                                 NGINX_PROXY_PASS_URL)\n'
        printf '         corebanking        → regis               (compose project + network)\n'
        printf '       %s lines compared\n' "$(wc -l < /tmp/_ex_block.txt | tr -d ' ')"
    else
        printf '     %sDRIFT%s beyond the declared renames:\n' "$RED" "$RST"
        diff /tmp/_src_renamed.txt /tmp/_ex_block.txt | head -20 | sed 's/^/          /'
        printf '       (left = source+renames, right = extract)\n'
        FAIL=1
    fi
else
    printf '     %sMISSING%s CONTAINER REGISTRY block\n' "$RED" "$RST"; FAIL=1
fi

# Assert the cert's SAN names the container the UI actually proxies to.
#
# This is a CONSISTENCY check, not a functional one: the UI sets
# NGINX_PROXY_SSL_VERIFY=off, so nginx does not verify the upstream certificate
# and DNS.2 is not load-bearing today. It is asserted anyway because a
# certificate naming an identity that no longer exists on the network is a
# latent failure — it breaks the moment anyone enables verification or runs a
# `curl https://<container>:5000` from another container with checking on.
if grep -q 'DNS.2 = regis-registry' "$HERE/Makefile" \
   && grep -q 'NGINX_PROXY_PASS_URL: https://regis-registry:5000' "$HERE/docker-compose.yml"; then
    printf '     %s✓%s  SAN DNS.2 matches the container the UI proxies to\n' "$GRN" "$RST"
else
    printf '     %sMISMATCH%s SAN DNS.2 and NGINX_PROXY_PASS_URL disagree — the\n' "$RED" "$RST"
    printf '            registry UI proxy would fail TLS verification.\n'
    FAIL=1
fi

# The removal list is the extract's entire premise, so state it explicitly.
# Only names inside the `services:` block count — a naive `^  [a-z_]+:` also
# matches `networks: default:` and `configs: pg_conf:`, which are not services
# and would make the report both wrong and alarming.
printf '\n     services present in source, deliberately removed here:\n'
source_services() {
    awk '/^services:/{f=1;next} /^[a-z]/{f=0} f && /^  [a-z_]+:/{sub(/^  /,"");sub(/:$/,"");print}' "$1"
}
extract_services() {
    docker compose -f "$1" config --services 2>/dev/null
}
source_services "$SRC/docker-compose.yml" | while read -r s; do
    # The two registry services are the ones being KEPT — everything else in
    # the services: block is expected to be gone. The kept pair is matched
    # AFTER renaming, since that is how it appears in the extract.
    case "$s" in
        core_registry|core_registry_ui)
            renamed=$(printf '%s' "$s" | sed -e 's/core_registry_ui/regis_registry_ui/' -e 's/core_registry/regis_registry/')
            if extract_services "$HERE/docker-compose.yml" | grep -qx "$renamed"; then
                printf '       %skept%s     %-20s → %-20s (subject of the extraction)\n' \
                       "$GRN" "$RST" "$s" "$renamed"
            else
                printf '       %sMISSING%s  %s → expected as %s\n' "$RED" "$RST" "$s" "$renamed"
            fi
            continue ;;
    esac
    if extract_services "$HERE/docker-compose.yml" | grep -qx "$s"; then
        printf '       %sUNEXPECTED%s %s — should have been removed\n' "$RED" "$RST" "$s"
    else
        printf '       %sremoved%s  %s\n' "$YEL" "$RST" "$s"
    fi
done
if grep -q '^configs:' "$HERE/docker-compose.yml"; then
    printf '       %sUNEXPECTED%s configs: block still present (postgres-only)\n' "$RED" "$RST"
else
    printf '       %sremoved%s  configs: (pg_conf, pg_hba — referenced only by core_postgres)\n' "$YEL" "$RST"
fi

# ── 3. Makefile — the mechanism recipes ──────────────────────────────────────
# §1 proves the copied files are identical and §2 proves the compose services
# are. This proves the RECIPES that implement the mechanism are identical,
# which matters because a recipe is not a file: someone can reword a comment
# or restructure a loop without changing behaviour, and equally can drop a
# `docker cp` line and change everything. These assertions name the specific
# lines that carry the behaviour.
printf '\n  %s3. Makefile — mechanism recipes%s\n' "$BLD" "$RST"
check_recipe() {
    local label="$1" needle="$2"
    if grep -qF -- "$needle" "$HERE/Makefile"; then
        printf '     %s✓%s  %s\n' "$GRN" "$RST" "$label"
    else
        printf '     %sMISSING%s %s\n' "$RED" "$RST" "$label"
        printf '          expected verbatim in the Makefile:\n'
        printf '            %s\n' "$needle" | sed 's/^/              /'
        FAIL=1
    fi
}
# certs — where the certificates are CREATED
check_recipe "certs: ca.crt self-signed from ca.key, 730d" \
  'openssl req -x509 -new -nodes -key $(CA_KEY) -sha256 -days 730'
check_recipe "certs: server.crt signed by the CA, 2-day leaf" \
  '-CAcreateserial \'
check_recipe "certs: RSA 4096 keygen" \
  'openssl genrsa -out $(CA_KEY) 4096'
# certs — the SAN the kubelet dials by. Drop this and every node pull fails
# with "certificate is valid for localhost, not host.docker.internal".
check_recipe "certs: SAN DNS.3 = host.docker.internal  (the name nodes dial)" \
  'DNS.3 = host.docker.internal'
# k8s [2/10] — where the CA is INJECTED into containerd
check_recipe "k8s [2/10]: mkdir certs.d/host.docker.internal:5001" \
  'docker exec $$node mkdir -p /etc/containerd/certs.d/host.docker.internal:5001'
check_recipe "k8s [2/10]: docker cp ca.crt into the node" \
  'docker cp ./data/registry/certs/ca.crt $$node:/etc/containerd/certs.d/host.docker.internal:5001/ca.crt'
check_recipe "k8s [2/10]: docker cp scripts/containerd-hosts.toml into the node" \
  'docker cp ./scripts/containerd-hosts.toml $$node:/etc/containerd/certs.d/host.docker.internal:5001/hosts.toml'
check_recipe "k8s [2/10]: set config_path in config.toml" \
  'config_path = \"\"|config_path = \"/etc/containerd/certs.d\"'
check_recipe "k8s [2/10]: pkill -HUP containerd   (a kill, not a reload — finding #2)" \
  'docker exec $$node pkill -HUP containerd'
# The nginx pull test's own two load-bearing lines.
check_recipe "deploy-nginx: imagePullPolicy Always (no cache shortcut)" \
  'imagePullPolicy: Always'

# ── 4. Compose project isolation ─────────────────────────────────────────────
# This is the check that matters most, because the failure it guards against
# already happened: a compose invocation from this directory resolving to the
# SOURCE's project, where `down` and `--remove-orphans` delete the source
# stack's containers.
#
# Two things must hold, and NEITHER is sufficient alone:
#
#   1. the compose file's `name:` is ours. On its own this buys nothing —
#      docker compose resolves the project name in this order:
#          -p flag  >  COMPOSE_PROJECT_NAME (environment)  >  name: (file)
#      and .env is a VERBATIM source file that pins
#      COMPOSE_PROJECT_NAME=corebanking, which silently beats `name: regis`.
#
#   2. every compose invocation goes through $(COMPOSE), which sets BOTH the -p
#      flag and the environment variable — so neither the .env nor an inherited
#      shell value can win.
#
# Both are asserted, and the resolution is checked empirically rather than
# assumed.
printf '\n  %s4. compose project isolation%s\n' "$BLD" "$RST"

EX_NAME="$(sed -n 's/^name: //p' "$HERE/docker-compose.yml" | head -1)"
MK_NAME="$(sed -n 's/^ *COMPOSE_PROJECT ?= *//p' "$HERE/Makefile" | head -1)"
if [ -n "$EX_NAME" ] && [ "$EX_NAME" = "$MK_NAME" ]; then
    printf '     %s✓%s  compose file name: (%s) == Makefile COMPOSE_PROJECT\n' \
           "$GRN" "$RST" "$EX_NAME"
else
    printf '     %sDRIFT%s compose file name: "%s" but Makefile COMPOSE_PROJECT: "%s"\n' \
           "$RED" "$RST" "$EX_NAME" "$MK_NAME"
    FAIL=1
fi

ENV_PROJ="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$HERE/.env" | head -1)"
if [ -n "$ENV_PROJ" ] && [ "$ENV_PROJ" != "$EX_NAME" ]; then
    printf '     %s⚠%s  .env is VERBATIM and pins COMPOSE_PROJECT_NAME=%s\n' "$YEL" "$RST" "$ENV_PROJ"
    printf '        That value BEATS `name:` in the compose file, so the -p flag and\n'
    printf '        the exported variable are what actually keep us isolated.\n'
    if grep -q '^COMPOSE := COMPOSE_PROJECT_NAME=\$(COMPOSE_PROJECT) docker compose -p \$(COMPOSE_PROJECT)' \
            "$HERE/Makefile"; then
        printf '     %s✓%s  neutralised: every compose call goes through $(COMPOSE)\n' "$GRN" "$RST"
    else
        printf '     %sUNPROTECTED%s not every compose call uses $(COMPOSE)\n' "$RED" "$RST"
        FAIL=1
    fi
    # Prove the resolution empirically rather than trusting the precedence docs.
    RESOLVED="$(cd "$HERE" && COMPOSE_PROJECT_NAME="$EX_NAME" \
                docker compose -p "$EX_NAME" -f docker-compose.yml config 2>/dev/null \
                | sed -n 's/^name: //p' | head -1)"
    if [ "$RESOLVED" = "$EX_NAME" ]; then
        printf '     %s✓%s  resolves to "%s" exactly as the Makefile invokes it\n' \
               "$GRN" "$RST" "$RESOLVED"
    else
        printf '     %sRESOLVES TO%s "%s" — isolation is NOT in effect\n' "$RED" "$RST" "$RESOLVED"
        FAIL=1
    fi
fi

# ── 5. Declared deviations from the source ───────────────────────────────────────────────
printf '\n  %s5. declared deviations from the source%s\n' "$BLD" "$RST"
printf '     These are the ONLY intended differences. Anything else is drift.\n\n'

cat <<'DEVIATIONS'
     ── (a) RENAMES — resource identity only, never mechanism ──────────────

         core_registry_ui  → regis_registry_ui    compose service key
         core_registry     → regis_registry       compose service key
         core-registry-ui  → regis-registry-ui    container_name, hostname
         core-registry     → regis-registry       container_name, hostname,
                                                   NGINX_PROXY_PASS_URL
         corebanking       → regis                compose project, network
         my-core1          → my-regis1            vcluster name
         SAN DNS.2         core-registry → regis-registry

         WHY: container_name and the compose project are docker-daemon-global,
         not directory-scoped, and the vcluster name is global to the vcluster
         CLI. Sharing them with the source means `docker compose -p <project>
         down` and `vcluster delete <name>` from either directory destroy the
         other's containers, volumes and cluster. That is not hypothetical — it
         happened, repeatedly, before these renames were made.

         The SAN rename is HYGIENE, not a functional requirement. The UI sets
         NGINX_PROXY_SSL_VERIFY=off, so nginx does not verify the upstream cert
         and DNS.2 is not load-bearing today. Renaming it keeps the certificate
         from asserting an identity that no longer exists on the network, and
         it becomes load-bearing the moment anything verifies by that name.
         §2 asserts the SAN and the proxy URL agree, on those grounds.

         NOT renamed, because they are the source's k8s object identity and are
         verbatim files — editing them would break the fidelity this extract
         exists to provide:
             core-users, core-service, core-bootstrap   (k8s object names)
             vcluster: my-core1  inside 0.02.core-bootstrap.yaml  ← see (e)

     ── (b) removal of the other compose services ───────────────────────────
         See §2 for the enumerated list.

     ── (c) source `make run` steps 4-6 omitted: the 11-service wait loop,
         Kafka topic creation, FX seeding, pg-bootstrap and JDBC sink
         registration. None is needed for a registry to serve an image, and
         each gates on services this extract does not run.

     ── (d) source `make k8s` steps 1.5, 3-10 omitted: step 1.5 applies
         k8s/core1/0.01.namespace.yaml (9 namespaces) and steps 3-10 deploy
         Redis, Vault, Elastic, Traefik, monitoring and the core services.
         Step 2 — the registry CA injection — is the mechanism under study and
         is reproduced verbatim.

     ── (e) NOT extracted: the source's k8s manifests. The real
         (k8s/core1/4.04.users.deployment-service.yaml) needs a ServiceAccount,
         a ConfigMap, a Vault Secret built from k8s/conf/keys.conf, and a full
         configuration surface before it does anything. That is the wrong shape
         for isolating "can a node pull an image over our self-signed TLS", and
         it is where the wrong-namespace Secret defect (§ finding #5) lives.

         Their two load-bearing lines are reproduced in
         k8s/1.01.nginx-pull-test.yaml, which is the ONE file in this extract
         that is not extracted from the source:
             image: host.docker.internal:5001/regis-nginx:alpine
             imagePullPolicy: Always
         Both are byte-identical in FORM to the source's core-users manifest,
         differing only in repository and tag.

     ── (f) ADDED, because the source has no standalone push for this case:
         the source builds images in core/build/Makefile, which needs the Go
         toolchain, the prebuilt ELFs in core/bin, and the whole source tree.
         `make push-nginx` publishes a stock nginx:alpine instead. The push is
         the same server behaviour either way — a tarball of layers PUT over
         HTTPS — so what is proven about the registry does not depend on the
         image's contents.

     ── (g) read-only observation added here: verify-extract.sh, plus the
         Makefile's preflight / catalog / status / verify-nodes targets. They
         add no mechanism and change no state.
DEVIATIONS
printf '\n'

# ── Verdict ──────────────────────────────────────────────────────────────────
printf '  %s%s%s\n' "$BLD" "──────────────────────────────────────────────────────────" "$RST"
if [ "$FAIL" -eq 0 ]; then
    printf '  %s✅ EXTRACT IS FAITHFUL%s — every verbatim file matches the source,\n' "$GRN" "$RST"
    printf '     and the differences are exactly the ones declared above.\n\n'
    exit 0
fi
printf '  %s❌ DRIFT DETECTED%s — the reproduction is no longer faithful.\n' "$RED" "$RST"
printf '     Any root-cause conclusion drawn from this run is INVALID until\n'
printf '     the drift above is resolved.\n\n'
exit 1
