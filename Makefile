# ══════════════════════════════════════════════════════════════════════════════
#  EXTRACT — the local registry + vcluster slice of CORE_Banking/deploy
# ══════════════════════════════════════════════════════════════════════════════
#
#  Every recipe below is COPIED VERBATIM from the source Makefile. Nothing is
#  re-implemented, renamed, or "improved" — that is the whole point: this file
#  exists so the source's registry → certs → containerd-trust chain can be run
#  and observed on its own, so a design issue in it can be root-caused.
#
#  Provenance of each target — line numbers as of the source Makefile at the
#  time of extraction (it changes; verify-extract.sh checks the recipes, not
#  the line numbers):
#
#    certs / certs-clean     deploy/Makefile 1123-1165   (ADR-56)
#    registry-up             deploy/Makefile 146-164     (`make run` steps 1-3)
#    registry-down           deploy/Makefile 275-290     (`make down`)
#    vcluster-up             deploy/Makefile 309-322     (`make k8s` step 1)
#    patch-nodes             deploy/Makefile 324-335     (`make k8s` step 2/10)  ★
#    vcluster-down           deploy/Makefile 441-460     (`make k8s-down`)
#    k8s-use                 deploy/Makefile 717-725     (`make k8s-use`)
#
#  ★ patch-nodes is the mechanism under investigation. It is reproduced
#    VERBATIM, including the parts that are wrong:
#      • the four hardcoded container names
#      • `2>/dev/null || true` on every step            → finding D3
#      • `pkill -HUP containerd`                          → finding D2
#      • `skip_verify = true` in hosts.toml               → finding D4
#    None of those are corrected here. Correcting them would end the
#    reproduction, and each is a candidate root cause.
#
#  DEVIATIONS FROM THE SOURCE
#
#    a) RESOURCE NAMES only — never mechanism. `container_name` and the compose
#       project are docker-daemon-global, and the vcluster name is global to the
#       vcluster CLI. Sharing them means `docker compose -p <project> down` or
#       `vcluster delete <name>` from either directory destroys the other.
#       Renames: core-registry→regis-registry, corebanking→regis, my-core1→
#       my-regis1, and the SAN that must match the container name.
#
#    b) `make k8s` step 1.5 is OMITTED. It applies
#       k8s/core1/0.01.namespace.yaml, which creates nine namespaces for the
#       core services. That manifest is not extracted — it exists only to host
#       the real core-* workloads, and the pull test does not use them. The pull
#       test brings its own single namespace inside
#       k8s/1.01.nginx-pull-test.yaml.
#
#    c) source `make run` steps 4-6 omitted: the 11-service wait loop, Kafka
#       topic creation, FX seeding, pg-bootstrap, JDBC sink registration. None
#       is needed for a registry to serve an image.
#
#    d) source `make k8s` steps 3-10 omitted: Redis, Vault, Elastic, Traefik,
#       monitoring, the core services. Step 2 — the CA injection — is the
#       mechanism under study.
#
#    e) the source's k8s manifests are NOT extracted, and an nginx pull test
#       replaces them. The real manifests each need a ServiceAccount, ConfigMaps
#       and a Vault Secret before doing anything — the wrong shape for isolating
#       an image pull, and where finding D5 (wrong-namespace Secret) lives.
#
#    f) ADDED, because the source has no standalone push for this case:
#       `make push-nginx`. The source builds images in core/build/Makefile,
#       which needs the Go toolchain and the whole source tree.
#
#  Every deviation is enumerated and checked by ./verify-extract.sh.
#
# ══════════════════════════════════════════════════════════════════════════════

CORE_ID ?= core1
CORE_N := $(patsubst core%,%,$(CORE_ID))
VCLUSTER ?= my-regis1

# ── Registry endpoint, derived from the verbatim .env ────────────────────────
# Everything below renders the image reference from these, so the port lives in
# exactly one place (.env) and the manifests, the push target and the deploy
# target cannot disagree about it. The vcluster nodes dial
# host.docker.internal:<port> — NOT localhost:<port>, because "localhost" inside
# a node is the node itself.
REGISTRY_PORT       ?= $(shell sed -n 's/^HOST_PORT_REGISTRY=//p' .env | head -1 | tr -d ' \r"')
REGISTRY_DOCKER_HOST := host.docker.internal

# ── COMPOSE PROJECT ISOLATION ────────────────────────────────────────────────
# Two independent mechanisms, because either alone is defeatable:
#
#   COMPOSE  passes -p regis explicitly. The -p flag has the HIGHEST precedence
#             in docker compose, so it beats both COMPOSE_PROJECT_NAME and the
#             `name:` key in the compose file.
#
#   export   sets COMPOSE_PROJECT_NAME in the environment. This matters because
#             .env is a VERBATIM source file and it pins
#                 COMPOSE_PROJECT_NAME=corebanking
#             Precedence is: -p flag > COMPOSE_PROJECT_NAME (env) >
#             name: (file) > directory basename — and a real environment
#             variable beats a value read from the .env FILE. So without this
#             export, any bare `docker compose …` run in this directory would
#             resolve to the source's `corebanking` project, where
#             `down` / `--remove-orphans` deletes the source stack's
#             containers.
#
# One definition, used by every compose call below, so the project name cannot
# drift between targets.
COMPOSE_PROJECT ?= regis
COMPOSE := COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT) docker compose -p $(COMPOSE_PROJECT)
export COMPOSE_PROJECT

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo ""
	@echo "  CORE — extracted registry + vcluster slice"
	@echo "  ══════════════════════════════════════════════════════"
	@echo ""
	@echo "  REGISTRY"
	@echo "    make certs          generate the CA + server cert   (source: certs)"
	@echo "    make registry-up    mint certs, start registry+UI  (source: make run 1-3)"
	@echo "    make registry-down  stop registry+UI               (source: make down)"
	@echo "    make preflight      CA-validated check of the live endpoint"
	@echo "    make catalog        list repositories and tags"
	@echo ""
	@echo "  VCLUSTER + CA INJECTION"
	@echo "    make vcluster-up    create vcluster + patch containerd  (source: make k8s 1,1.5,2)"
	@echo "    make patch-nodes    re-run ONLY the source's step-[2/10] loop"
	@echo "    make verify-nodes   read back what landed in each node"
	@echo "    make k8s-use        kubectl → $(VCLUSTER)              (source: make k8s-use)"
	@echo "    make vcluster-down  delete the cluster               (source: make k8s-down)"
	@echo ""
	@echo "  PUBLISH — get an image into the registry"
	@echo "    make push-nginx     pull nginx:alpine, retag, push to $(REGISTRY_PORT)"
	@echo "    make catalog        list repositories and tags"
	@echo ""
	@echo "  DEPLOY — pull it onto the vcluster  ← the assertion"
	@echo "    make deploy-nginx   apply the manifest, prove the pull"
	@echo "    make logs-nginx     the pod and its log"
	@echo "    make pull-test-fail negative control: a bogus tag MUST fail"
	@echo "    make undeploy-nginx remove the workloads"
	@echo ""
	@echo "  DIAGNOSE"
	@echo "    make status         one screen across every layer"
	@echo "    make verify-extract prove every file still matches the source"
	@echo ""
	@echo "  ISOLATED FROM THE SOURCE STACK (renamed so it can never collide):"
	@echo "    compose project : $(COMPOSE_PROJECT)            (source: corebanking)"
	@echo "    containers     : regis-registry, regis-registry-ui"
	@echo "                     (source: core-registry, core-registry-ui)"
	@echo "    vcluster       : $(VCLUSTER)                        (source: my-core1)"
	@echo ""
	@echo "  CERT validity: 2 days, regenerated on every registry-up."
	@echo ""


# ══════════════════════════════════════════════════════════════════════════════
#  CERTIFICATES
#  VERBATIM from deploy/Makefile 885-939 — the `certs` target (ADR-56).
#  This is where the certificates are CREATED. Nothing here is modified.
# ══════════════════════════════════════════════════════════════════════════════

# ── Local Registry TLS Certificates (ADR-56) ───────────────────────────────────
# Generates a self-signed CA and server certificate for the local registry.
# Certs are regenerated on every `make run` — rotation is a non-event.
# SANs: localhost, regis-registry, host.docker.internal, 127.0.0.1
# (the source lists `core-registry` here; renamed to match the container
#  hostname below, since the UI reaches the registry BY THAT NAME over
#  HTTPS. A SAN that does not match makes the proxy fail verification.)
# Validity: 2 days (short-lived by design; rebuilt on every stack bring-up).
# Output: ./data/registry/certs/{ca.crt,ca.key,server.crt,server.key}
CERTS_DIR := ./data/registry/certs
CA_KEY := $(CERTS_DIR)/ca.key
CA_CRT := $(CERTS_DIR)/ca.crt
SERVER_KEY := $(CERTS_DIR)/server.key
SERVER_CRT := $(CERTS_DIR)/server.crt
SERVER_CSR := $(CERTS_DIR)/server.csr
SAN_CONFIG := $(CERTS_DIR)/san.cnf

certs: $(CA_CRT) $(SERVER_CRT)
	@echo "✅ Registry TLS certs ready at $(CERTS_DIR)/"

$(CA_CRT): $(CA_KEY)
	@openssl req -x509 -new -nodes -key $(CA_KEY) -sha256 -days 730 \
		-subj "/CN=CORE Local Registry CA" -out $(CA_CRT)

$(CA_KEY):
	@mkdir -p $(CERTS_DIR)
	@openssl genrsa -out $(CA_KEY) 4096

$(SAN_CONFIG):
	@echo "[req]" > $(SAN_CONFIG)
	@echo "distinguished_name = req_distinguished_name" >> $(SAN_CONFIG)
	@echo "req_extensions = v3_req" >> $(SAN_CONFIG)
	@echo "[req_distinguished_name]" >> $(SAN_CONFIG)
	@echo "CN = localhost" >> $(SAN_CONFIG)
	@echo "[v3_req]" >> $(SAN_CONFIG)
	@echo "subjectAltName = @alt_names" >> $(SAN_CONFIG)
	@echo "[alt_names]" >> $(SAN_CONFIG)
	@echo "DNS.1 = localhost" >> $(SAN_CONFIG)
	@echo "DNS.2 = regis-registry" >> $(SAN_CONFIG)
	@echo "DNS.3 = host.docker.internal" >> $(SAN_CONFIG)
	@echo "IP.1 = 127.0.0.1" >> $(SAN_CONFIG)

$(SERVER_KEY):
	@openssl genrsa -out $(SERVER_KEY) 4096

$(SERVER_CSR): $(SERVER_KEY) $(SAN_CONFIG)
	@openssl req -new -key $(SERVER_KEY) -out $(SERVER_CSR) -config $(SAN_CONFIG) -subj "/CN=localhost"

$(SERVER_CRT): $(SERVER_CSR) $(CA_CRT) $(CA_KEY)
	@openssl x509 -req -in $(SERVER_CSR) -CA $(CA_CRT) -CAkey $(CA_KEY) -CAcreateserial \
		-out $(SERVER_CRT) -days 2 -sha256 -extensions v3_req -extfile $(SAN_CONFIG)

# Clean certs (for manual regeneration)
certs-clean:
	@rm -rf $(CERTS_DIR)
	@echo "✅ Certs cleaned"

.PHONY: certs certs-clean


# ══════════════════════════════════════════════════════════════════════════════
#  REGISTRY
#  From deploy/Makefile `make run` (146-164) and `make down` (200-209).
#  Only the registry services and the cert step are reproduced; the Kafka /
#  Postgres / sink steps are not needed for a registry to serve images.
# ══════════════════════════════════════════════════════════════════════════════

# VERBATIM structure of `make run`'s registry-relevant steps. The 11-service
# wait loop and the Kafka/pg/sink steps that follow it in the source are
# omitted — they gate on services this extract does not run.
registry-up: certs
	@echo "🚀 [1/3] Creating local Docker Compose Persist directories..."
	@mkdir -p ./data/registry

	@echo "🚀 [2/3] Generating registry TLS certificates..."
	@$(MAKE) certs

	@echo "🚀 [3/3] Starting Docker Compose stack (regis)..."
	$(COMPOSE) up -d \
		regis_registry regis_registry_ui

.PHONY: registry-up

# From `make down`. NOTE the source also removes ./data/postgres, ./data/rustfs
# and ./data/filebeat; those directories are not created by this extract.
registry-down:
	@echo "🚀 Tear down compose stack..."
	$(COMPOSE) stop regis_registry regis_registry_ui
	$(COMPOSE) rm -f regis_registry regis_registry_ui
	@rm -rf ./data/registry
	@echo "✅ ... Compose stack torn down (registry blobs AND generated TLS certs wiped)"
.PHONY: registry-down


# ══════════════════════════════════════════════════════════════════════════════
#  VCLUSTER + THE CONTAINERd CA INJECTION
#
#  THIS IS THE CODE THAT ANSWERS "where are the certificates injected into
#  containerd?" — deploy/Makefile `make k8s` step [2/10], lines 237-242.
#
#  The loop is reproduced VERBATIM, including:
#     • the four hardcoded container names
#     • `2>/dev/null || true` on every copy        → finding #3
#     • `pkill -HUP containerd`                    → finding #4
#     • `skip_verify = true` inside hosts.toml     → finding #5
#  None of those are corrected here. Correcting them would destroy the
#  reproduction, and each is a candidate root cause.
# ══════════════════════════════════════════════════════════════════════════════

# ── Stage: create the vcluster (source `make k8s` steps 1 and 1.5) ───────────
vcluster-up:
	@echo ""
	@echo "🚀 [1/9] Creating vcluster $(VCLUSTER)..."
	@vcluster list 2>/dev/null | grep -q "$(VCLUSTER).*running" && echo "  ✓ already running" || \
		{ test -f vcluster$(CORE_N).yml || { echo "ERROR: vcluster$(CORE_N).yml not found — supply the config file first" >&2; exit 1; }; \
		  vcluster create $(VCLUSTER) -f vcluster$(CORE_N).yml; }

	# The source's `make k8s` step [1.5] applies k8s/core1/0.01.namespace.yaml,
	# which creates nine namespaces (core, entities, interface, security, admin,
	# ingress, monitoring, elastic, redis) for the core services.
	#
	# That manifest is NOT extracted here: it exists only to host the real
	# core-* workloads, and the pull test does not use them. The pull test brings
	# its own single namespace (regis-pull) inside
	# k8s/1.01.nginx-pull-test.yaml, which `make deploy-nginx` applies.
	#
	# Step [1.5] is therefore omitted rather than reproduced against a manifest
	# this extract does not carry. It is declared in verify-extract.sh §5(d) and
	# it is not part of the mechanism under study — step [2/10] is.
	@echo "  ⏳ settling 3s for the cluster…"
	@sleep 3

	@$(MAKE) patch-nodes
.PHONY: vcluster-up

# ── Stage [2/10]: inject the CA into containerd. VERBATIM. ───────────────────
patch-nodes:
	@echo ""
	@echo "🚀 [2/10] Patching vcluster nodes to trust local registry (self-signed TLS)..."
	@echo "  Copying CA cert to all nodes (cp + 3 workers) and configuring containerd..."
	@for node in vcluster.cp.$(VCLUSTER) vcluster.node.$(VCLUSTER).worker-1 vcluster.node.$(VCLUSTER).worker-2 vcluster.node.$(VCLUSTER).worker-3; do \
		if docker ps --format '{{.Names}}' | grep -q "^$$node$$"; then \
			docker exec $$node mkdir -p /etc/containerd/certs.d/host.docker.internal:5001 2>/dev/null || true; \
			docker cp ./data/registry/certs/ca.crt $$node:/etc/containerd/certs.d/host.docker.internal:5001/ca.crt 2>/dev/null || true; \
			docker cp ./scripts/containerd-hosts.toml $$node:/etc/containerd/certs.d/host.docker.internal:5001/hosts.toml 2>/dev/null || true; \
			docker exec $$node sh -c 'sed -i "s|config_path = \"\"|config_path = \"/etc/containerd/certs.d\"|" /etc/containerd/config.toml' 2>/dev/null || true; \
			docker exec $$node pkill -HUP containerd 2>/dev/null || true; \
			echo "  ✓ $$node patched"; \
		else \
			echo "  ⚠ $$node not running (skipped)"; \
		fi; \
	done
.PHONY: patch-nodes

# The source prints "✓ $$node patched" unconditionally. This target shows what
# is ACTUALLY in the node, so the difference between "patched" and "patched
# correctly" is visible. It changes nothing.
#
# NOTE ON REPORTING containerd: it is read via `systemctl is-active`, and the
# PID is shown, because a single-point `pgrep` check is unreliable here. The
# patch loop ends with `pkill -HUP containerd`, which TERMINATES the process
# (finding #4) and systemd takes ~5-7s to start a new one. A probe run inside
# that window reports "not running" and looks like a catastrophic failure when
# it is really a transient restart. Reporting the systemd state and the PID
# together distinguishes "dead" from "mid-restart".
verify-nodes:
	@echo ""
	@echo "🔍 Reading back what the step-[2/10] loop actually put in each node..."
	@for node in vcluster.cp.$(VCLUSTER) vcluster.node.$(VCLUSTER).worker-1 vcluster.node.$(VCLUSTER).worker-2 vcluster.node.$(VCLUSTER).worker-3; do \
		if ! docker ps --format '{{.Names}}' | grep -q "^$$node$$"; then echo "  ⚠ $$node not running (skipped)"; continue; fi; \
		printf '  %s\n' "$$node"; \
		printf '    certs.d dir   : '; \
		docker exec $$node ls /etc/containerd/certs.d/host.docker.internal:5001 2>&1 | tr '\n' ' ' || true; echo; \
		printf '    ca.crt        : '; \
		docker exec $$node test -f /etc/containerd/certs.d/host.docker.internal:5001/ca.crt 2>/dev/null && echo "present" || echo "MISSING"; \
		printf '    hosts.toml    : '; \
		docker exec $$node test -f /etc/containerd/certs.d/host.docker.internal:5001/hosts.toml 2>/dev/null && echo "present" || echo "MISSING  ← containerd ignores the CA without this"; \
		printf '    config_path   : '; \
		docker exec $$node grep -o 'config_path = "[^"]*"' /etc/containerd/config.toml 2>/dev/null | head -1 || echo "(not set)"; \
		printf '    containerd    : '; \
		docker exec $$node sh -c 'printf "%s (pid %s)\n" "$$(systemctl is-active containerd 2>/dev/null)" "$$(pgrep -x containerd | head -1)"' 2>/dev/null || echo "?"; \
	done
	@echo ""
	@echo "  Reminder: the loop above ends with 'pkill -HUP containerd', which kills the"
	@echo "  process rather than reloading it. 'activating' with no pid means systemd is"
	@echo "  mid-restart (~5-7s) — that is the expected consequence, not a new fault."
.PHONY: verify-nodes

# From `make k8s-use` (source ~line 470).
k8s-use:
	@echo ""
	@echo "🚀 Switching vcluster focus → $(VCLUSTER) (updates current kubectl context)..."
	@test -f vcluster$(CORE_N).yml && echo "  (vcluster$(CORE_N).yml present)" || true
	vcluster connect $(VCLUSTER) --update-current=true
	@echo ""
	@echo "✅ ... kubectl now targets $(VCLUSTER). Verify: kubectl get ns"
.PHONY: k8s-use

# From `make k8s-down` (source 320-353), reduced to the vcluster itself.
vcluster-down:
	@echo ""
	@echo "🛑 Destroying vcluster(s)..."
	@if vcluster list 2>/dev/null | grep -q "$(VCLUSTER)"; then \
		vcluster delete "$(VCLUSTER)" && echo "  ✓ $(VCLUSTER) deleted"; \
	else \
		echo "  – $(VCLUSTER) absent (skipped)"; \
	fi
	@echo "  ✅ ... vcluster(s) torn down"
.PHONY: vcluster-down


# ══════════════════════════════════════════════════════════════════════════════
#  PUBLISH — put an image into the registry
#
#  The source does this from core/build/Makefile (`docker buildx build --push`
#  of a Go ELF into a distroless image). That needs the Go toolchain, the
#  prebuilt binaries in core/bin, and the whole source tree — none of which
#  this extract carries.
#
#  So this extract publishes a stock nginx:alpine instead. The PUSH is the
#  thing under test's concern, and it is identical either way: a tarball of
#  layers PUT to the registry over HTTPS, which is the same server behaviour
#  the kubelet's pull later depends on. What is being proven about the registry
#  does not depend on what is inside the image.
#
#  ── PREREQUISITE: the docker DAEMON must trust the CA ────────────────────────
#
#  curl honours --cacert explicitly, but the docker daemon has its OWN trust
#  store and does not. `docker push` goes through the daemon, so a daemon that
#  does not trust our CA fails the push with an x509 error even though
#  `make preflight` just proved the CA is correct. The source has NO target
#  that installs this — `core/build` simply assumes it is already configured,
#  which is why the first push in a fresh checkout is a common stumble.
#
#  Docker Desktop on macOS reads the USER-level path:
#      ~/.docker/certs.d/localhost:5001/ca.crt
#  (NOT /etc/docker/certs.d, which is the Linux path and is ignored here.)
#  A daemon restart may be needed for it to take effect.
# ══════════════════════════════════════════════════════════════════════════════
NGINX_TAG    ?= alpine
IMAGE_REPO   ?= regis-nginx
IMAGE_NAME   := $(IMAGE_REPO):$(NGINX_TAG)
HOST_IMAGE   := localhost:$(REGISTRY_PORT)/$(IMAGE_REPO):$(NGINX_TAG)
NODE_IMAGE   := $(REGISTRY_DOCKER_HOST):$(REGISTRY_PORT)/$(IMAGE_REPO):$(NGINX_TAG)
DAEMON_CA    := $(HOME)/.docker/certs.d/localhost:$(REGISTRY_PORT)/ca.crt

push-nginx:
	@echo "🚀 Publishing $(IMAGE_NAME) into the registry"
	@echo "   from Docker Hub : nginx:$(NGINX_TAG)"
	@echo "   pushed as       : $(HOST_IMAGE)   (host-side authority)"
	@echo "   pulled as       : $(NODE_IMAGE)   (node-side authority)"
	@echo ""
	@$(MAKE) preflight
	@# Same image, two references: the builder reaches the registry on the
	@# published host port, the kubelet reaches it on the Docker gateway name.
	@# One push serves both — the repository, tag and content are identical.
	@if [ ! -f "$(DAEMON_CA)" ]; then \
		echo ""; \
		echo "⚠️  docker daemon does not trust the registry CA yet."; \
		echo "   Installing to $(DAEMON_CA)"; \
		mkdir -p "$(dir $(DAEMON_CA))" && cp ./data/registry/certs/ca.crt "$(DAEMON_CA)" \
			&& echo "   ✓ installed. If the push below fails with x509, restart Docker Desktop."; \
	fi
	@echo ""
	@echo "  → docker pull nginx:$(NGINX_TAG)"
	@docker pull nginx:$(NGINX_TAG)
	@echo "  → docker tag  → $(HOST_IMAGE)"
	@docker tag nginx:$(NGINX_TAG) $(HOST_IMAGE)
	@echo "  → docker push"
	@docker push $(HOST_IMAGE)
	@echo ""
	@echo "✅ $(IMAGE_NAME) is in the registry"
	@echo "   verify:  make catalog"
.PHONY: push-nginx


# ══════════════════════════════════════════════════════════════════════════════
#  DEPLOY — pull it onto the vcluster
#
#  This is the assertion. Everything above exists to make this one line work:
#
#      image: host.docker.internal:5001/regis-nginx:alpine
#
#  k8s/1.01.nginx-pull-test.yaml is the ONLY file here that is not extracted
#  from the source — the source's own manifests are the real core-* services,
#  each needing a ServiceAccount, ConfigMaps, a Vault Secret and a full config
#  surface before it does anything. That is the wrong shape for isolating
#  "can a node pull an image over our self-signed TLS".
# ══════════════════════════════════════════════════════════════════════════════
NAMESPACE ?= regis-pull
DEPLOY    ?= nginx
PULL_TIMEOUT ?= 180

deploy-nginx:
	@echo ""
	@echo "🚀 Deploying $(IMAGE_NAME) onto $(VCLUSTER)"
	@echo "   image : $(NODE_IMAGE)"
	@echo "   ns    : $(NAMESPACE)"
	@echo ""
	@case "$$(kubectl config current-context 2>/dev/null)" in \
		*$(VCLUSTER)*) : ;; \
		*) echo "ERROR: kubectl context is '$$(kubectl config current-context 2>/dev/null)', not $(VCLUSTER)"; \
		   echo "       point it at the cluster first:  make k8s-use"; \
		   exit 1 ;; \
	esac
	@$(MAKE) preflight
	@# Render the authority from .env. The manifest carries
	@# host.docker.internal:5001 on disk because that is what reads well, but
	@# the port is authoritative in .env and must not be duplicated by hand.
	@TMP=$$(mktemp -d); \
	sed -e 's|host\.docker\.internal:[0-9]*|$(REGISTRY_DOCKER_HOST):$(REGISTRY_PORT)|g' \
	    -e 's|regis-nginx:[a-z0-9._-]*|$(IMAGE_REPO):$(NGINX_TAG)|g' \
	    k8s/1.01.nginx-pull-test.yaml > $$TMP/m.yaml; \
	kubectl apply -f $$TMP/m.yaml || { rm -rf $$TMP; exit 1; }; \
	rm -rf $$TMP
	@echo ""
	@echo "⏳ waiting for the image pull (timeout $(PULL_TIMEOUT)s)…"
	@# Poll for a terminal outcome rather than just sleeping: a pull failure
	@# should be reported as soon as the kubelet has a reason, not after the
	@# full timeout. Every distinct reason here is a distinct root cause.
	@for i in $$(seq 1 $(PULL_TIMEOUT)); do \
		PHASE=$$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.phase}' 2>/dev/null); \
		REASON=$$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null); \
		case "$$REASON" in \
			ErrImagePull|ImagePullBackOff|InvalidImageName) \
				echo ""; \
				echo "❌ pull failed: $$REASON" >&2; \
				kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp 2>/dev/null | grep -i "failed to pull\|Failed" | tail -5 | sed 's/^/   /' >&2; \
				echo "" >&2; \
				echo "   Each of these names a different root cause:" >&2; \
				echo "     x509: certificate signed by unknown authority" >&2; \
				echo "        → the node's CA does not match the registry's certificate." >&2; \
				echo "          Check: make verify-nodes ; make preflight" >&2; \
				echo "     x509: certificate is valid for localhost, not host.docker.internal" >&2; \
				echo "        → the cert SAN is missing the name the node dials." >&2; \
				echo "          Fix:   make certs-clean && make registry-up && make patch-nodes" >&2; \
				echo "     x509: certificate has expired" >&2; \
				echo "        → the leaf is valid 2 days by design." >&2; \
				echo "          Fix:   make certs-clean && make registry-up && make patch-nodes" >&2; \
				echo "     no such host / lookup host.docker.internal" >&2; \
				echo "        → DNS, not TLS. The node cannot route to the gateway." >&2; \
				echo "     manifest unknown" >&2; \
				echo "        → the tag is not in the registry.  Fix: make push-nginx" >&2; \
				exit 1 ;; \
		esac; \
		[ "$$PHASE" = "Running" ] && break; \
		sleep 1; \
	done
	@POD=$$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	PHASE=$$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.phase}' 2>/dev/null); \
	if [ "$$PHASE" != "Running" ]; then \
		echo ""; \
		echo "❌ pod did not reach Running within $(PULL_TIMEOUT)s (last phase: $$PHASE)" >&2; \
		echo "   For a first cold pull, raise it:  make deploy-nginx PULL_TIMEOUT=420" >&2; \
		exit 1; \
	fi
	@echo ""
	@echo "  ── proof ─────────────────────────────────────────────────────"
	@echo "  pod            : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')"
	@echo "  node           : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].spec.nodeName}')"
	@echo "  resolved image : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.containerStatuses[0].image}')"
	@echo "  containerID    : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.containerStatuses[0].containerID}' | cut -c1-19)…"
	@echo ""
	@echo "  The kubelet events for this pod carry the definitive line:"
	@echo "    kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | grep -i pull"
	@echo ""
	@echo "  ✅ $(IMAGE_NAME) pulled from $(REGISTRY_DOCKER_HOST):$(REGISTRY_PORT) and is running."
	@echo ""
	@echo "     Note what this does NOT prove: scripts/containerd-hosts.toml sets"
	@echo "     skip_verify = true, so a successful pull shows the path works but not"
	@echo "     that the CA is correct. See README finding #4, and run:"
	@echo "       make verify-nodes   (is the CA actually in each node?)"
	@echo "       make preflight      (is it the CA the registry is serving?)"
.PHONY: deploy-nginx

logs-nginx:
	@kubectl -n $(NAMESPACE) get pods -o wide
	@echo ""
	@kubectl -n $(NAMESPACE) logs -l app=nginx --tail=20
.PHONY: logs-nginx

# The negative control. A tag that must NOT resolve, so that a passing
# positive test means something: with a self-signed registry, a wrong CA, a
# wrong tag, an unresolvable host and a dead registry all surface as the SAME
# ErrImagePull. Without a test that must fail, "it worked" is indistinguishable
# from "the image was already cached on the node".
pull-test-fail:
	@echo "⚠️  NEGATIVE CONTROL — deploying a tag that does not exist."
	@echo "   This MUST fail. If it succeeds, the positive test is not testing"
	@echo "   the registry at all (most likely: the node already had the image"
	@echo"    cached, so imagePullPolicy: Always is not in effect)."
	@kubectl -n $(NAMESPACE) delete deployment nginx-pull-fail --ignore-not-found >/dev/null 2>&1 || true
	@TMP=$$(mktemp -d); \
	sed -e 's|host\.docker\.internal:[0-9]*|$(REGISTRY_DOCKER_HOST):$(REGISTRY_PORT)|g' \
	    -e 's|regis-nginx:[a-z0-9._-]*|$(IMAGE_REPO):__no-such-tag__|g' \
	    -e 's|name: nginx$$|name: nginx-pull-fail|' \
	    -e 's|app: nginx|app: nginx-pull-fail|g' \
	    k8s/1.01.nginx-pull-test.yaml > $$TMP/m.yaml; \
	kubectl apply -f $$TMP/m.yaml >/dev/null; \
	rm -rf $$TMP
	@for i in $$(seq 1 120); do \
		REASON=$$(kubectl -n $(NAMESPACE) get pod -l app=nginx-pull-fail -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null); \
		case "$$REASON" in \
			ErrImagePull|ImagePullBackOff) \
				echo ""; \
				echo "✅ NEGATIVE CONTROL PASSED — the pull failed, as it must."; \
				echo "   reason: $$REASON"; \
				kubectl -n $(NAMESPACE) delete deployment nginx-pull-fail --ignore-not-found >/dev/null 2>&1; \
				exit 0 ;; \
		esac; \
		sleep 1; \
	done; \
	echo ""; \
	echo "❌ NEGATIVE CONTROL FAILED — the pod did not report a pull error." >&2; \
	echo "   The test is not exercising the registry, so the positive result" >&2; \
	echo "   above does not mean anything. Inspect:" >&2; \
	echo "     kubectl -n $(NAMESPACE) describe pod -l app=nginx-pull-fail" >&2; \
	exit 1
.PHONY: pull-test-fail

undeploy-nginx:
	@echo "🧹 Removing the pull-test workloads from namespace $(NAMESPACE)…"
	@kubectl -n $(NAMESPACE) delete deployment nginx nginx-pull-fail --ignore-not-found 2>/dev/null || true
	@echo "  ✅ removed (namespace $(NAMESPACE) retained)"
.PHONY: undeploy-nginx

# ══════════════════════════════════════════════════════════════════════════════
#  DIAGNOSE — read-only observation. Adds no mechanism of its own.
# ══════════════════════════════════════════════════════════════════════════════

# Is the CA on disk the CA the registry is actually serving? Distinguishes
# "registry down" from "serving a different certificate", which otherwise look
# identical from a pull failure.
preflight:
	@echo "🔍 registry preflight"
	@if [ ! -f ./data/registry/certs/ca.crt ]; then \
		echo "  ❌ no CA on disk — make certs"; exit 1; fi
	@if curl -fsS --cacert ./data/registry/certs/ca.crt \
	     https://localhost:$$(sed -n 's/^HOST_PORT_REGISTRY=//p' .env | head -1 | tr -d ' ')/v2/_catalog >/dev/null 2>&1; then \
		echo "  ✅ the CA on disk validates the live endpoint"; \
	elif curl -fsSk https://localhost:$$(sed -n 's/^HOST_PORT_REGISTRY=//p' .env | head -1 | tr -d ' ')/v2/_catalog >/dev/null 2>&1; then \
		echo "  ❌ registry is UP but serving a DIFFERENT certificate than the CA on disk"; \
		echo "     → 'make certs-clean && make registry-up' (both sides must agree)"; \
		exit 1; \
	else \
		echo "  ❌ nothing listening — make registry-up"; exit 1; fi
.PHONY: preflight

catalog:
	@PORT=$$(sed -n 's/^HOST_PORT_REGISTRY=//p' .env | head -1 | tr -d ' '); \
	echo "  Registry catalog — localhost:$$PORT"; \
	curl -fsS --cacert ./data/registry/certs/ca.crt "https://localhost:$$PORT/v2/_catalog" \
	  | jq -r '.repositories[]?' | sed 's/^/    /'
.PHONY: catalog

# One screen across every layer, each naming a distinct failure.
status:
	@PORT=$$(sed -n 's/^HOST_PORT_REGISTRY=//p' .env | head -1 | tr -d ' '); \
	echo ""; echo "  CORE registry + vcluster — status"; \
	echo "  ═════════════════════════════════════════════════════════════"; echo ""; \
	echo "  ── compose ──────────────────────────────────────────────────"; \
	for s in regis-registry regis-registry-ui; do \
	  if docker ps --format '{{.Names}}' | grep -q "^$$s$$"; then \
	    printf '  ✅ %-22s %s\n' "$$s" "$$(docker inspect -f '{{.State.Status}}{{if .State.Health}}({{.State.Health.Status}}){{end}}' $$s)"; \
	  else printf '  ❌ %-22s not running\n' "$$s"; fi; done; \
	echo ""; echo "  ── certs ────────────────────────────────────────────────────"; \
	if [ -f ./data/registry/certs/ca.crt ]; then \
	  printf '  ✅ %-22s %s\n' "ca.crt" "$$(openssl x509 -in ./data/registry/certs/ca.crt -noout -enddate | cut -d= -f2)"; \
	  printf '  %-22s ' "server.crt expires"; \
	  openssl x509 -in ./data/registry/certs/server.crt -noout -checkend 0 >/dev/null 2>&1 \
	    && echo "valid" || echo "EXPIRED (2-day leaf by design → make certs-clean && make registry-up)"; \
	else printf '  ❌ %-22s missing — make certs\n' "certs"; fi; \
	echo ""; echo "  ── endpoint ─────────────────────────────────────────────────"; \
	curl -fsS --cacert ./data/registry/certs/ca.crt "https://localhost:$$PORT/v2/_catalog" >/dev/null 2>&1 \
	  && printf '  ✅ %-22s CA validates, HTTPS serving\n' "registry:$$PORT" \
	  || printf '  ❌ %-22s unreachable or serving a different cert\n' "registry:$$PORT"; \
	echo ""; echo "  ── vcluster ──────────────────────────────────────────────────"; \
	vcluster list 2>/dev/null | grep -q "$(VCLUSTER)" \
	  && printf '  ✅ %-22s present\n' "$(VCLUSTER)" || printf '  ❌ %-22s absent\n' "$(VCLUSTER)"; \
	CTX=$$(kubectl config current-context 2>/dev/null); \
	case "$$CTX" in *$(VCLUSTER)*) printf '  ✅ %-22s %s\n' "kubectl context" "$$CTX";; \
	                        *) printf '  ❌ %-22s %s (want *%s*) — make k8s-use\n' "kubectl context" "$$CTX" "$(VCLUSTER)";; esac; \
	echo ""; echo "  ── containerd trust (per node) ──────────────────────────────"; \
	for node in vcluster.cp.$(VCLUSTER) vcluster.node.$(VCLUSTER).worker-1 vcluster.node.$(VCLUSTER).worker-2 vcluster.node.$(VCLUSTER).worker-3; do \
	  # Short label: "cp" for the control plane, "worker-N" for a worker.
	  # `${node##*.}` alone would render vcluster.cp.<name> as the vcluster
	  # name, which reads as a duplicate row rather than a node identity.
	  # A `case` construct is avoided deliberately: it does not survive the
	  # single-logical-line compression a make recipe requires.
	  LBL=$$(printf '%s' "$$node" | sed -e 's|^vcluster\.cp\..*|cp|' -e 's|^vcluster\.node\.[^.]*\.||'); \
	  if ! docker ps --format '{{.Names}}' | grep -q "^$$node$$"; then \
	    printf '  \xe2\x9a\xa0\xf0\x90\x8d %-22s not running (skipped)\n' "$$LBL"; continue; fi; \
	  if docker exec $$node test -f /etc/containerd/certs.d/host.docker.internal:5001/ca.crt 2>/dev/null; then CA=y; else CA=n; fi; \
	  if docker exec $$node test -f /etc/containerd/certs.d/host.docker.internal:5001/hosts.toml 2>/dev/null; then HT=y; else HT=n; fi; \
	  if docker exec $$node grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml 2>/dev/null; then CP=y; else CP=n; fi; \
	  if docker exec $$node sh -c 'pgrep -x containerd >/dev/null' 2>/dev/null; then CD=y; else CD=n; fi; \
	  if [ "$$CA" = y ] && [ "$$HT" = y ] && [ "$$CP" = y ] && [ "$$CD" = y ]; then \
	    printf '  \xe2\x9c\x85 %-22s ca ✓ hosts.toml ✓ config_path ✓ containerd ✓\n' "$$LBL"; \
	  else \
	    [ "$$CA" = n ] && printf '  \xe2\x9d\x8c %-22s ca.crt MISSING\n' "$$LBL"; \
	    [ "$$HT" = n ] && printf '  \xe2\x9d\x8c %-22s hosts.toml MISSING — CA inert\n' "$$LBL"; \
	    [ "$$CP" = n ] && printf '  \xe2\x9d\x8c %-22s config_path NOT set\n' "$$LBL"; \
	    [ "$$CD" = n ] && printf '  \xe2\x9d\x8c %-22s containerd NOT running (mid-restart?)\n' "$$LBL"; \
	  fi; \
	done; \
	echo ""; echo "  ── nginx (pulled from the registry) ─────────────────────────"; \
	if kubectl -n $(NAMESPACE) get deploy nginx >/dev/null 2>&1; then \
	  READY=$$(kubectl -n $(NAMESPACE) get deploy nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null); \
	  WANT=$$(kubectl -n $(NAMESPACE) get deploy nginx  -o jsonpath='{.spec.replicas}' 2>/dev/null); \
	  READY=$${READY:-0}; \
	  IMG=$$(kubectl -n $(NAMESPACE) get deploy nginx -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null); \
	  if [ "$$READY" = "$$WANT" ]; then \
	    printf '  \xe2\x9c\x85 %-22s %s/%s ready  (%s)\n' "nginx" "$$READY" "$$WANT" "$$IMG"; \
	  else \
	    printf '  \xe2\x9c\x85 %-22s deployed %s/%s — IMAGE PULLED OK (%s)\n' "nginx" "$$READY" "$$WANT" "$$IMG"; \
	    printf '     \xe2\x9a\xa0 0 ready means nginx is not serving :80 yet, which is a\n'; \
	    printf '        container concern, NOT an image-pull one. Confirm the pull from\n'; \
	    printf '        the events:\n'; \
	    printf "          kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | grep -i pull\n"; \
	  fi; \
	else \
	  printf '  \xe2\x9a\xa0\xf0\x90\x8d %-22s not deployed — make deploy-nginx\n' "nginx"; \
	fi; \
	echo ""
.PHONY: status


# ══════════════════════════════════════════════════════════════════════════════
#  PROVE THE EXTRACT IS FAITHFUL
#
#  Every file in this extract that came from the source is compared byte for
#  byte against the source. If this target fails, the reproduction has drifted
#  and any conclusion drawn from it is invalid.
# ══════════════════════════════════════════════════════════════════════════════
verify-extract:
	@./verify-extract.sh
.PHONY: verify-extract
