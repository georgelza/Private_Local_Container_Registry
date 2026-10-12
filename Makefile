# ══════════════════════════════════════════════════════════════════════════════
#  LOCAL REGISTRY + vCLUSTER  —  a self-contained lab
#
#  One chain, five commands:
#
#      make run     	bring the registry up (mints certs first)
#      make pull    	fetch nginx:alpine into local Docker
#      make build   	push that image into the registry
#      make k8s     	create the cluster and inject the CA into every node
#      make app     	deploy manifest/nginx.yaml and prove the pull
#
#  Teardown:
#      make down        compose down, wipe ./data/registry
#      make k8s-down    delete the cluster, wipe ./data/cluster
#      make clean       both of the above, wipe ./data
#
#  THE ONE THING THIS L EXISTS TO PROVE
#      A registry with a certificate we generated ourselves, serving an image
#      that a Kubernetes node we never configured by any supported means pulls
#      over HTTPS and runs. See README.md.
# ══════════════════════════════════════════════════════════════════════════════

.DEFAULT_GOAL := help


# ── THE REGISTRY AUTHORITY ───────────────────────────────────────────────────
# Derive it ONCE, here, and let everything else reference these four names.
#
# There are two vantage points and they are NOT interchangeable:
#
#   $(REGISTRY_ENDPOINT)   localhost:$(PORT)
#         host-side tools. `curl`, `docker push`. The published port.
#
#   $(REGISTRY_AUTHORITY)  host.docker.internal:$(PORT)
#         what a vCluster node dials. Inside a node container "localhost" is
#         the NODE ITSELF — there is no registry on that port in there.
#         host.docker.internal is Docker's embedded DNS name for the VM gateway.
#
# The authority appears in five places that must agree, and nothing else in the
# tree is allowed to spell it out:
#
#     cert SAN  DNS.3        -> $(REGISTRY_HOST)          [certs target]
#     certs.d  directory     -> $(CERTSD_IN_NODE)         [this file]
#     hosts.toml server/ca_file -> $(REGISTRY_AUTHORITY)  [rendered from template]
#     containerd-hosts.toml  -> rendered, never committed with a port baked in
#     image reference        -> $(NODE_IMAGE)             [app target]
#
# Change HOST_PORT_REGISTRY in .env and all five follow. That is the entire
# point: when these could disagree, a correct CA could sit in a directory
# containerd never reads and every pull would fail with no error anywhere.
# ─────────────────────────────────────────────────────────────────────────────
include .env
export

VCLUSTER        ?= my-regis1
VCLUSTER_CONFIG ?= vcluster1.yml

REGISTRY_HOST ?= host.docker.internal

# Fail HERE, at parse time, with the actual cause named. Previously a missing
# HOST_PORT_REGISTRY silently produced an empty string, and the symptom
# surfaced much later as "nothing listening — make registry-up" — which reads
# like a registry fault and sends you hunting in entirely the wrong place.
ifeq ($(strip $(HOST_PORT_REGISTRY)),)
$(error HOST_PORT_REGISTRY is not set in .env — the registry authority cannot be derived)
endif

REGISTRY_PORT      ?= $(HOST_PORT_REGISTRY)
REGISTRY_AUTHORITY := $(REGISTRY_HOST):$(REGISTRY_PORT)
REGISTRY_ENDPOINT  := localhost:$(REGISTRY_PORT)
CERTSD_IN_NODE     := /etc/containerd/certs.d/$(REGISTRY_AUTHORITY)
REGISTRY_API       := https://$(REGISTRY_ENDPOINT)/v2

# Compose project identity. `container_name` and the compose project are
# docker-daemon-GLOBAL, not scoped to this directory, so both are set
# explicitly. -p beats COMPOSE_PROJECT_NAME, which beats `name:` in the file.
COMPOSE_PROJECT ?= regis
COMPOSE := docker compose -p $(COMPOSE_PROJECT)

# The image under test.
NGINX_TAG   ?= alpine
IMAGE_REPO  ?= regis-nginx
IMAGE_NAME  := $(IMAGE_REPO):$(NGINX_TAG)
LOCAL_IMAGE := nginx:$(NGINX_TAG)
HOST_IMAGE  := $(REGISTRY_ENDPOINT)/$(IMAGE_REPO):$(NGINX_TAG)
NODE_IMAGE  := $(REGISTRY_AUTHORITY)/$(IMAGE_REPO):$(NGINX_TAG)

# ── PATHS ────────────────────────────────────────────────────────────────────
CERTS_DIR      := ./data/registry/certs
CA_KEY         := $(CERTS_DIR)/ca.key
CA_CRT         := $(CERTS_DIR)/ca.crt
SERVER_KEY     := $(CERTS_DIR)/server.key
SERVER_CRT     := $(CERTS_DIR)/server.crt
SERVER_CSR     := $(CERTS_DIR)/server.csr
SAN_CONFIG     := $(CERTS_DIR)/san.cnf
# Rendered, not committed. See scripts/containerd-hosts.toml.tmpl.
HOSTS_TOML     := $(CERTS_DIR)/hosts.toml
HOSTS_TMPL     := ./scripts/containerd-hosts.toml.tmpl
# The docker daemon's OWN trust store. Docker Desktop on macOS reads the
# user-level path; /etc/docker/certs.d is the Linux path and is ignored here.
DAEMON_CA      := $(HOME)/.docker/certs.d/$(REGISTRY_AUTHORITY)/ca.crt
# …and the one for `localhost`, which is the name a host-side push dials.
DAEMON_CA_HOST := $(HOME)/.docker/certs.d/$(REGISTRY_ENDPOINT)/ca.crt

NAMESPACE    ?= regis-pull
MANIFEST     := manifest/nginx.yaml
PULL_TIMEOUT ?= 180

.PHONY: help
help:
	@echo ""
	@echo "  LOCAL REGISTRY + vCLUSTER"
	@echo ""
	@echo "    make run         bring the registry up (mints certs first)"
	@echo "    make pull        fetch $(LOCAL_IMAGE) into local Docker"
	@echo "    make build       push it into $(REGISTRY_ENDPOINT)"
	@echo "    make k8s         create the cluster + inject the CA into every node"
	@echo "    make app         deploy $(MANIFEST) and prove the pull   ← the assertion"
	@echo ""
	@echo "  TEARDOWN (total — all directories under ./data, certs included)"
	@echo "    make down        compose down, wipe ./data/registry"
	@echo "    make k8s-down    delete the cluster, wipe ./data/cluster"
	@echo "    make clean       both, wipe ./data"
	@echo ""
	@echo "  DIAGNOSE"
	@echo "    make status          one screen across every layer"
	@echo "    make preflight       is the CA on disk the CA the registry is serving?"
	@echo "    make catalog         list repositories and tags"
	@echo "    make verify-nodes    read back what landed in each node"
	@echo "    make pull-test-fail  negative control — a bogus tag MUST fail"
	@echo ""
	@echo "  INTERNAL"
	@echo "    make certs / certs-clean  mint or drop the TLS material"
	@echo "    make patch-nodes          re-inject the CA, verified"
	@echo ""
	@echo "  ENDPOINTS"
	@echo "    registry    $(REGISTRY_ENDPOINT)"
	@echo "    registry UI http://localhost:$(HOST_PORT_REGISTRY_UI)"
	@echo "    nodes dial  $(REGISTRY_AUTHORITY)"
	@echo ""


# ══════════════════════════════════════════════════════════════════════════════
#  CERTIFICATES
#
#  A self-signed CA (730d) signs a short-lived leaf (2d). SANs cover every name
#  a client might dial: the gateway name the kubelet uses, localhost for
#  host-side tools, the container hostname for the UI's proxy, and the loopback
#  literal for IP-dialing clients.
# ══════════════════════════════════════════════════════════════════════════════
certs: $(CA_CRT) $(SERVER_CRT) $(HOSTS_TOML)

$(CA_KEY):
	@mkdir -p $(CERTS_DIR)
	@openssl genrsa -out $(CA_KEY) 4096

$(CA_CRT): $(CA_KEY)
	@openssl req -x509 -new -nodes -key $(CA_KEY) -sha256 -days 730 \
		-subj "/CN=Local Registry CA" -out $(CA_CRT)

$(SAN_CONFIG): | $(CERTS_DIR)
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
	@echo "DNS.3 = $(REGISTRY_HOST)" >> $(SAN_CONFIG)
	@echo "IP.1 = 127.0.0.1" >> $(SAN_CONFIG)

$(SERVER_KEY): | $(CERTS_DIR)
	@openssl genrsa -out $(SERVER_KEY) 4096

$(SERVER_CSR): $(SERVER_KEY) $(SAN_CONFIG)
	@openssl req -new -key $(SERVER_KEY) -out $(SERVER_CSR) -config $(SAN_CONFIG) -subj "/CN=localhost"

$(SERVER_CRT): $(SERVER_CSR) $(CA_CRT) $(CA_KEY)
	@openssl x509 -req -in $(SERVER_CSR) -CA $(CA_CRT) -CAkey $(CA_KEY) -CAcreateserial \
		-out $(SERVER_CRT) -days 2 -sha256 -extensions v3_req -extfile $(SAN_CONFIG)

# Rendered from the template so the authority can never disagree with itself.
$(HOSTS_TOML): $(HOSTS_TMPL) $(SAN_CONFIG)
	@sed -e 's|__REGISTRY_AUTHORITY__|$(REGISTRY_AUTHORITY)|g' \
	     -e 's|__CERTSD_IN_NODE__|$(CERTSD_IN_NODE)|g' \
	     $(HOSTS_TMPL) > $(HOSTS_TOML)
	@echo "✅ registry TLS certs ready — leaf valid 2 days, CA 730"
	@echo "   authority: $(REGISTRY_AUTHORITY)"

certs-clean:
	@rm -rf $(CERTS_DIR)
	@echo "✅ certs dropped — the next 'make run' mints a new CA, and every node must then be re-patched"

.PHONY: certs certs-clean


# ══════════════════════════════════════════════════════════════════════════════
#  make run — the registry
# ══════════════════════════════════════════════════════════════════════════════
run: certs
	@echo ""
	@echo "🚀 [1/4] Certs — CA + $(REGISTRY_PORT) leaf, SAN $(REGISTRY_HOST)"
	@echo ""
	@echo "🚀 [2/4] Persistent store"
	@mkdir -p ./data/registry
	@echo ""
	@echo "🚀 [3/4] Compose stack ($(COMPOSE_PROJECT))"
	@$(COMPOSE) up -d regis_registry regis_registry_ui
	@echo ""
	@echo "🚀 [4/4] Waiting for HTTPS to answer"
	@for i in $$(seq 1 30); do \
		$(MAKE) --no-print-directory preflight >/dev/null 2>&1 && break; \
		sleep 2; \
	done
	@$(MAKE) --no-print-directory preflight || exit 1
	@echo ""
	@echo "✅ registry up on $(REGISTRY_ENDPOINT)"
	@echo "   UI       http://localhost:$(HOST_PORT_REGISTRY_UI)"
	@echo "   next     make pull && make build && make k8s && make app"

.PHONY: run


# ══════════════════════════════════════════════════════════════════════════════
#  make pull — fetch the base image into LOCAL DOCKER
#  Separate from `build` because these are different failures: a pull that dies
#  is a network problem, a push that dies is a trust problem.
# ══════════════════════════════════════════════════════════════════════════════
pull:
	@echo "📥 Pulling $(LOCAL_IMAGE) into local Docker"
	@docker pull $(LOCAL_IMAGE)
	@echo "✅ $(LOCAL_IMAGE) is in the local Docker store"

.PHONY: pull


# ══════════════════════════════════════════════════════════════════════════════
#  make build — import the local Docker image into the registry
#
#  docker push goes through the DAEMON, which has its own trust store that
#  `curl --cacert` does not touch. So preflight passing does NOT mean push will
#  work — and on a fresh machine the first push dies with an x509 error while
#  every check has just said green.
# ══════════════════════════════════════════════════════════════════════════════
build: preflight
	@echo ""
	@echo "📦 Importing $(LOCAL_IMAGE) → $(HOST_IMAGE)"
	@# The daemon must trust this CA under BOTH names it could be asked to dial.
	@for d in "$(DAEMON_CA)" "$(DAEMON_CA_HOST)"; do \
		if [ ! -f "$$d" ]; then \
			mkdir -p "$$(dirname "$$d")" && cp $(CA_CRT) "$$d" \
				|| { echo "  ✗ could not install the CA at $$d" >&2; exit 1; }; \
			echo "  ✓ daemon trust store: $$d"; \
		fi; \
	done
	@docker image inspect $(LOCAL_IMAGE) >/dev/null 2>&1 \
		|| { echo "  ✗ $(LOCAL_IMAGE) is not in local Docker — run: make pull" >&2; exit 1; }
	@docker tag $(LOCAL_IMAGE) $(HOST_IMAGE)
	@docker push $(HOST_IMAGE)
	@echo ""
	@$(MAKE) --no-print-directory catalog
	@echo ""
	@echo "✅ $(IMAGE_NAME) is in the registry"
	@echo "   nodes will pull it as: $(NODE_IMAGE)"

.PHONY: build


# ══════════════════════════════════════════════════════════════════════════════
#  make k8s — the cluster, and the CA injection
#
#  The kubelet pulls the image, so the pull happens on the NODE, before the pod
#  exists. There is no pod spec in which to say "trust this CA", and
#  imagePullSecrets carry credentials, not certificates. The only thing that
#  works here is to put the CA in containerd's own trust store on every node.
#
#  A vCluster node is a Docker container, so the Docker CLI is the lever:
#  docker cp a file in, docker exec to write config. That is the whole trick,
#  and it is why this lives in a script that can verify itself.
# ══════════════════════════════════════════════════════════════════════════════
k8s: certs
	@echo ""
	@echo "🚀 [1/3] Creating vcluster $(VCLUSTER)"
	@vcluster list 2>/dev/null | grep -q "$(VCLUSTER).*running" && echo "  ✓ already running" || \
		{ test -f $(VCLUSTER_CONFIG) || { echo "ERROR: $(VCLUSTER_CONFIG) not found" >&2; exit 1; }; \
		  vcluster create $(VCLUSTER) -f $(VCLUSTER_CONFIG); }
	@echo "  ⏳ settling 5s"
	@sleep 5
	@echo ""
	@echo "🚀 [2/3] Injecting the CA into every node's containerd"
	@./scripts/patch_nodes_ca.sh patch "$(VCLUSTER)" "$(CA_CRT)" "$(HOSTS_TOML)" "$(CERTSD_IN_NODE)"
	@echo ""
	@echo "🚀 [3/3] Pointing kubectl at $(VCLUSTER)"
	@vcluster connect $(VCLUSTER) --update-current=true >/dev/null 2>&1 \
		|| { echo "ERROR: could not connect kubectl to $(VCLUSTER)" >&2; exit 1; }
	@echo ""
	@echo "✅ cluster up, every node trusts $(REGISTRY_AUTHORITY)"
	@echo "   next: make app"

patch-nodes: certs
	@./scripts/patch_nodes_ca.sh patch "$(VCLUSTER)" "$(CA_CRT)" "$(HOSTS_TOML)" "$(CERTSD_IN_NODE)"

verify-nodes:
	@echo ""
	@echo "🔍 Reading back what actually landed in each node"
	@./scripts/patch_nodes_ca.sh verify "$(VCLUSTER)" "$(CA_CRT)" "$(CERTSD_IN_NODE)"

.PHONY: k8s patch-nodes verify-nodes


# ══════════════════════════════════════════════════════════════════════════════
#  make app — THE ASSERTION
#  Everything above exists to make one line work:
#      image: host.docker.internal:5001/regis-nginx:alpine
# ══════════════════════════════════════════════════════════════════════════════
app: preflight
	@echo ""
	@echo "🚀 Deploying $(IMAGE_NAME) from $(REGISTRY_AUTHORITY)"
	@case "$$(kubectl config current-context 2>/dev/null)" in \
		*$(VCLUSTER)*) : ;; \
		*) echo "ERROR: kubectl context is '$$(kubectl config current-context 2>/dev/null)', not $(VCLUSTER)" >&2; \
		   echo "       fix with:  make k8s" >&2; exit 1 ;; \
	esac
	@# The nodes must trust the CA that is running NOW. `make down` mints a new
	@# one and destroys the old; a cluster left standing across that boundary is
	@# holding an orphaned anchor, and nothing about the pull will tell you.
	@./scripts/patch_nodes_ca.sh verify "$(VCLUSTER)" "$(CA_CRT)" "$(CERTSD_IN_NODE)" >/dev/null \
		|| { echo ""; echo "ERROR: a node does not trust the current CA — run: make patch-nodes" >&2; exit 1; }
	@TMP=$$(mktemp -d); \
	sed -e 's|host\.docker\.internal:[0-9]*|$(REGISTRY_AUTHORITY)|g' \
	    -e 's|regis-nginx:[a-z0-9._-]*|$(IMAGE_REPO):$(NGINX_TAG)|g' \
	    $(MANIFEST) > $$TMP/m.yaml; \
	kubectl apply -f $$TMP/m.yaml || { rm -rf $$TMP; exit 1; }; \
	rm -rf $$TMP
	@echo ""
	@echo "⏳ waiting for the pull (timeout $(PULL_TIMEOUT)s)"
	@for i in $$(seq 1 $(PULL_TIMEOUT)); do \
		PHASE=$$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.phase}' 2>/dev/null); \
		REASON=$$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null); \
		case "$$REASON" in \
			ErrImagePull|ImagePullBackOff|InvalidImageName) \
				echo ""; \
				echo "❌ pull failed: $$REASON" >&2; \
				kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp 2>/dev/null | grep -i "failed\|not found\|denied" | tail -5 | sed 's/^/   /' >&2; \
				echo "" >&2; \
				echo "   Each of these names a different root cause:" >&2; \
				echo "     x509: certificate signed by unknown authority" >&2; \
				echo "        → the node's CA does not match the registry's certificate" >&2; \
				echo "          check: make verify-nodes ; make preflight" >&2; \
				echo "     x509: certificate is valid for localhost, not $(REGISTRY_HOST)" >&2; \
				echo "        → the cert SAN is missing the name the node dials" >&2; \
				echo "          fix:   make certs-clean && make run && make k8s" >&2; \
				echo "     x509: certificate has expired" >&2; \
				echo "        → the leaf is valid 2 days by design" >&2; \
				echo "          fix:   make certs-clean && make run && make k8s" >&2; \
				echo "     no such host / lookup $(REGISTRY_HOST)" >&2; \
				echo "        → DNS, not TLS. the node cannot route to the Docker gateway" >&2; \
				echo "     manifest unknown" >&2; \
				echo "        → the tag is not in the registry.  fix: make build" >&2; \
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
		echo "   for a first cold pull, raise it:  make app PULL_TIMEOUT=420" >&2; \
		exit 1; \
	fi
	@echo ""
	@echo "  ── proof ────────────────────────────────────────────────"
	@echo "  pod            : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')"
	@echo "  node           : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].spec.nodeName}')"
	@echo "  resolved image : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.containerStatuses[0].image}')"
	@echo "  containerID    : $$(kubectl -n $(NAMESPACE) get pod -l app=nginx -o jsonpath='{.items[0].status.containerStatuses[0].containerID}' | cut -c1-19)…"
	@echo ""
	@echo "  The definitive line, from the kubelet itself:"
	@echo "    kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | grep -i pulled"
	@echo ""
	@echo "✅ $(IMAGE_NAME) pulled from $(REGISTRY_AUTHORITY) and is running."
	@echo ""
	@echo "  What this does NOT prove: run 'make pull-test-fail'. A bogus tag must"
	@echo "  fail too. With one registry, a wrong CA, a wrong tag, an unresolvable"
	@echo "  host and a dead registry all surface as the SAME ErrImagePull — so"
	@echo "  without a test that must fail, 'it worked' and 'the image was already"
	@echo "  cached on the node' look identical."

logs:
	@kubectl -n $(NAMESPACE) get pods -o wide
	@echo ""
	@kubectl -n $(NAMESPACE) logs -l app=nginx --tail=20

# The negative control. A tag that must NOT resolve.
# imagePullPolicy: Always is what makes this meaningful — with IfNotPresent a
# cached image satisfies the pull and the registry is never contacted.
pull-test-fail:
	@echo "⚠️  NEGATIVE CONTROL — deploying a tag that does not exist."
	@echo "   This MUST fail. If it succeeds, the positive test is not testing"
	@echo "   the registry at all (most likely: the node already had the image"
	@echo "   cached, so imagePullPolicy: Always is not in effect)."
	@kubectl -n $(NAMESPACE) delete deployment nginx-pull-fail --ignore-not-found >/dev/null 2>&1 || true
	@TMP=$$(mktemp -d); \
	sed -e 's|host\.docker\.internal:[0-9]*|$(REGISTRY_AUTHORITY)|g' \
	    -e 's|regis-nginx:[a-z0-9._-]*|$(IMAGE_REPO):__no-such-tag__|g' \
	    -e 's|name: nginx$$|name: nginx-pull-fail|' \
	    -e 's|app: nginx|app: nginx-pull-fail|g' \
	    $(MANIFEST) > $$TMP/m.yaml; \
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
	echo "   The test is not exercising the registry." >&2; \
	echo "     kubectl -n $(NAMESPACE) describe pod -l app=nginx-pull-fail" >&2; \
	exit 1

undeploy:
	@kubectl -n $(NAMESPACE) delete deployment nginx nginx-pull-fail --ignore-not-found 2>/dev/null || true
	@echo "  ✅ workloads removed (namespace $(NAMESPACE) retained)"

.PHONY: app logs pull-test-fail undeploy


# ══════════════════════════════════════════════════════════════════════════════
#  TEARDOWN — total. Every directory under ./data goes, certificates included.
#
#  That is the honest default for a lab: nothing survives a teardown, so a
#  clean cycle starts from a known state and the trust chain is re-established
#  from scratch every time. The cost is that `make run` after a `make down`
#  mints a NEW CA — so the cluster must be re-patched (`make k8s`) before it can
#  pull again. Every target that needs a trusted node checks that.
# ══════════════════════════════════════════════════════════════════════════════
k8s-down:
	@echo ""
	@echo "🛑 Deleting vcluster $(VCLUSTER)"
	@if vcluster list 2>/dev/null | grep -q "$(VCLUSTER)"; then \
		vcluster delete "$(VCLUSTER)" >/dev/null 2>&1 \
			&& echo "  ✓ $(VCLUSTER) deleted" \
			|| { echo "  ✗ $(VCLUSTER) delete FAILED" >&2; exit 1; }; \
	else \
		echo "  – $(VCLUSTER) absent (skipped)"; \
	fi
	@echo "🛑 Removing node volumes"
	@rm -rf ./data/cluster
	@echo "  ✓ ./data/cluster removed (node volumes n1..n3)"
	@echo "✅ cluster torn down"

down:
	@echo ""
	@echo "🛑 Compose down ($(COMPOSE_PROJECT))"
	@$(COMPOSE) down -v --remove-orphans || true
	@echo "🛑 Removing registry blobs and certificates"
	@rm -rf ./data/registry
	@echo "  ✓ ./data/registry removed (certs included — the next 'make run' mints a new CA)"
	@echo "✅ compose torn down"

clean:
	@echo ""
	@echo "🧹 TOTAL TEARDOWN — cluster, compose, and everything under ./data"
	@$(MAKE) --no-print-directory k8s-down
	@$(MAKE) --no-print-directory down
	@rm -rf ./data
	@echo ""
	@echo "✅ Clean. Next:  make run → make pull → make build → make k8s → make app"

.PHONY: k8s-down down clean


# ══════════════════════════════════════════════════════════════════════════════
#  DIAGNOSE
# ══════════════════════════════════════════════════════════════════════════════

# Is the CA on disk the CA the registry is SERVING? This separates two failures
# that are identical from a pull: the registry is down, and the registry is up
# but serving a different certificate than the one on disk.
preflight:
	@if [ ! -f $(CA_CRT) ]; then \
		echo "❌ no CA on disk — make certs"; exit 1; fi
	@if curl -fsS --cacert $(CA_CRT) $(REGISTRY_API)/_catalog >/dev/null 2>&1; then \
		echo "✅ the CA on disk validates the live endpoint ($(REGISTRY_ENDPOINT))"; \
	elif curl -fsSk $(REGISTRY_API)/_catalog >/dev/null 2>&1; then \
		echo "❌ registry is UP but serving a DIFFERENT certificate than the CA on disk"; \
		echo "   → make certs-clean && make run   (both sides must agree)"; \
		exit 1; \
	else \
		echo "❌ nothing listening on $(REGISTRY_ENDPOINT) — make run"; exit 1; fi

catalog:
	@echo "  catalog — $(REGISTRY_ENDPOINT)"; \
	curl -fsS --cacert $(CA_CRT) $(REGISTRY_API)/_catalog | jq -r '.repositories[]?' | sed 's/^/    /' \
		|| { echo "  ❌ unreachable — make run"; exit 1; }

status:
	@echo ""
	@echo "  LOCAL REGISTRY + vCLUSTER — status"
	@echo "  ═════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  ── authority ─────────────────────────────────────────────"
	@printf '  %-24s %s\n' "nodes dial" "$(REGISTRY_AUTHORITY)"
	@printf '  %-24s %s\n' "host tools dial" "$(REGISTRY_ENDPOINT)"
	@printf '  %-24s %s\n' "certs.d in node" "$(CERTSD_IN_NODE)"
	@echo ""
	@echo "  ── compose ─────────────────────────────────────────────"
	@for s in regis-registry regis-registry-ui; do \
		if docker ps --format '{{.Names}}' | grep -q "^$$s$$"; then \
			printf '  ✅ %-22s %s\n' "$$s" "$$(docker inspect -f '{{.State.Status}}{{if .State.Health}}({{.State.Health.Status}}){{end}}' $$s)"; \
		else printf '  ❌ %-22s not running\n' "$$s"; fi; \
	done
	@echo ""
	@echo "  ── certs ───────────────────────────────────────────────"
	@if [ -f $(CA_CRT) ]; then \
		printf '  ✅ %-22s %s\n' "ca.crt" "$$(openssl x509 -in $(CA_CRT) -noout -enddate | cut -d= -f2)"; \
		printf '  %-22s ' "server.crt"; \
		openssl x509 -in $(SERVER_CRT) -noout -checkend 0 >/dev/null 2>&1 \
			&& echo "valid" || echo "EXPIRED — make certs-clean && make run && make k8s"; \
	else printf '  ❌ %-22s missing — make run\n' "certs"; fi
	@echo ""
	@echo "  ── endpoint ─────────────────────────────────────────────"
	@curl -fsS --cacert $(CA_CRT) $(REGISTRY_API)/_catalog >/dev/null 2>&1 \
		&& printf '  ✅ %-22s CA validates, HTTPS serving\n' "registry:$(REGISTRY_PORT)" \
		|| printf '  ❌ %-22s unreachable or serving a different cert\n' "registry:$(REGISTRY_PORT)"
	@echo ""
	@echo "  ── vcluster ─────────────────────────────────────────────"
	@vcluster list 2>/dev/null | grep -q "$(VCLUSTER)" \
		&& printf '  ✅ %-22s present\n' "$(VCLUSTER)" || printf '  ❌ %-22s absent\n' "$(VCLUSTER)"
	@CTX=$$(kubectl config current-context 2>/dev/null); \
	case "$$CTX" in *$(VCLUSTER)*) printf '  ✅ %-22s %s\n' "kubectl context" "$$CTX";; \
	                        *) printf '  ❌ %-22s %s (want *%s*) — make k8s\n' "kubectl context" "$$CTX" "$(VCLUSTER)";; esac
	@echo ""
	@echo "  ── containerd trust (per node) ─────────────────────────"
	@if vcluster list 2>/dev/null | grep -q "$(VCLUSTER)"; then \
		./scripts/patch_nodes_ca.sh verify "$(VCLUSTER)" "$(CA_CRT)" "$(CERTSD_IN_NODE)" \
			| sed 's/^/ /' || true; \
	else printf '  ⚠ %-22s no cluster — make k8s\n' "$(VCLUSTER)"; fi
	@echo ""
	@echo "  ── nginx (pulled from the registry) ────────────────────"
	@if kubectl -n $(NAMESPACE) get deploy nginx >/dev/null 2>&1; then \
		READY=$$(kubectl -n $(NAMESPACE) get deploy nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null); \
		WANT=$$(kubectl -n $(NAMESPACE) get deploy nginx  -o jsonpath='{.spec.replicas}' 2>/dev/null); \
		READY=$${READY:-0}; \
		IMG=$$(kubectl -n $(NAMESPACE) get deploy nginx -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null); \
		if [ "$$READY" = "$$WANT" ]; then \
			printf '  ✅ %-22s %s/%s ready  (%s)\n' "nginx" "$$READY" "$$WANT" "$$IMG"; \
		else \
			printf '  ✅ %-22s deployed %s/%s — IMAGE PULLED OK (%s)\n' "nginx" "$$READY" "$$WANT" "$$IMG"; \
			printf '     ⚠ 0 ready means nginx is not serving :80 yet, which is a\n'; \
			printf '        container concern, not an image-pull one. Confirm the pull:\n'; \
			printf '          kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | grep -i pulled\n'; \
		fi; \
	else \
		printf '  ⚠ %-22s not deployed — make app\n' "nginx"; \
	fi
	@echo ""

.PHONY: preflight catalog status