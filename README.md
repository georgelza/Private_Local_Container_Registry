# Why the vcluster can pull from our local registry — and what it cost us

A worked explanation of one mechanism: how a container image gets from a
self-signed Docker registry on a laptop into a Kubernetes cluster, what we found
when we took it apart, and how we reproduced it in isolation so it could be
fixed properly.

**Written to be shared.** If you are new to this, sections 1–6 are the whole
story. Sections 7–10 are the detail and the diagnostics.

---

## Contents

1. [The situation](#1-the-situation)
2. [What "a CA cert for k8s" actually means](#2-what-a-ca-cert-for-k8s-actually-means)
3. [The workaround, and why we needed one](#3-the-workaround-and-why-we-needed-one)
4. [What we built to study it](#4-what-we-built-to-study-it)
5. [What we found](#5-what-we-found)
6. [Seeing it work](#6-seeing-it-work)
7. [The mechanism in detail](#7-the-mechanism-in-detail)
8. [Diagnosing a failure](#8-diagnosing-a-failure)
9. [Full defect list](#9-full-defect-list)
10. [What we recommend](#10-what-we-recommend)

---

## 1. The situation

We run a local container registry as part of our Docker Compose stack, and a
local Kubernetes cluster (vcluster, running inside Docker) for the application
workloads.

```
   ┌── your laptop ─────────────────────────────────────────────────┐
   │                                                                │
   │   docker compose  ──────────────►  the registry                │
   │      core-registry                   serves images over        │
   │      core-registry-ui                HTTPS on :5001            │
   │                                        ▲                       │
   │                                        │ pulls                 │
   │   vcluster  ────────────────────────►  │                       │
   │      4 node "containers"               │                       │
   │      each runs a real kubelet          │                       │
   │                                        │                       │
   └────────────────────────────────────────┼───────────────────────┘
                                            │
      every application image the cluster runs
      is fetched through here
```

The registry uses a **self-signed certificate** that we generate ourselves. It is
not issued by a public CA and never will be — it serves on `localhost` behind
the Docker VM gateway, so there is nothing to issue it from.

The consequence: **every image pull is an HTTPS connection to a server whose
certificate nothing trusts by default.** Before a single application container
can start, that trust has to be established on every node.

That is the whole problem. Everything below is about how it is solved, and where
the solving is fragile.

---

## 2. What "a CA cert for k8s" actually means

Worth being precise, because two things people reach for first do **not** work.

**It is not a pod-level thing.** A common instinct is to ship the CA to the
cluster the way you ship any other configuration — a ConfigMap, a Secret, an
env var. None of that helps. The image pull happens in the **kubelet, on the
node**, before the pod that wants the image exists. There is no pod spec in
which to express "trust this CA", because the pod has not been created yet.

```
   ┌─ node ──────────────────────────────────────────────┐
   │                                                     │
   │   kubelet ──── "I need image regis-nginx:alpine"    │
   │      │                                              │
   │      │  ← the pull happens HERE, on the node        │
   │      ▼                                              │
   │   containerd ──► HTTPS ──► registry                 │
   │      │                                              │
   │      └─ needs to trust the registry's CA            │
   │                                                     │
   │   ... the pod is created only AFTER this succeeds   │
   └─────────────────────────────────────────────────────┘
```

**It is not `imagePullSecrets`.** A `kubernetes.io/dockerconfigjson` Secret
carries registry *credentials* — username, password, token. It has no field for
a certificate authority. This is a widespread and expensive misunderstanding; if
someone reports "we added the CA to the image pull secret and it still fails",
they are right that it still fails.

**What it actually is:** the container runtime on the node — containerd — needs
the CA in *its own* trust store, in *its own* configuration, before it will
complete a TLS handshake with that registry.

In an ordinary cluster you would arrange this by whatever provisions your nodes:

```
   a normal node
   ┌──────────────────────────────────────────────────────────────────────┐
   │  /etc/containerd/certs.d/                                            │
   │    registry.example.com/                                             │
   │      ca.crt          ← the CA, baked in by:                          │
   │      hosts.toml      ← or written at boot by:                        │
   │                                                node image (AMI)      │
   │  config_path = "/etc/containerd/certs.d"       config management     │
   │                                                (Ansible, cloud-init) |
   │  containerd reads this at startup              privileged DaemonSet  |
   └──────────────────────────────────────────────────────────────────────┘
```

All three routes assume the same thing: **the nodes are long-lived, and you
control the machine they run on.** You can bake into the image, script at boot, or
reach in with a privileged DaemonSet that mounts the host filesystem.

---

## 3. The workaround, and why we needed one

vcluster with the Docker driver does not give you any of those routes.

```
   vcluster, docker driver
   ┌─────────────────────────────────────────────────────────────┐
   │  "my-core1"  is not a set of VMs. It is FOUR DOCKER         │
   │  CONTAINERS that you happened to create with `docker run`   │
   │                                                             │
   │    vcluster.cp.my-core1                                     │
   │    vcluster.node.my-core1.worker-1      ← real containers   │
   │    vcluster.node.my-core1.worker-2         each with its    │
   │    vcluster.node.my-core1.worker-3         own filesystem,  │
   │                                               destroyed     │
   │                                               and recreated │
   │                                               at will       │
   └─────────────────────────────────────────────────────────────┘

   no node image to bake into
   no boot script to run
   no config management reaches inside
   a DaemonSet could mount the host, but the "host" here is the
      Docker VM, not the node — it would not reach containerd
```

**The lever we do have** is the one that created them: the `docker` CLI. If the
node is a container, we can go inside it.

```bash
docker exec <node> …      # run a command inside the node
docker cp  <file> <node>:<path>   # put a file inside the node
```

So the workaround is: **treat each Kubernetes node as a Docker container and
reach into it with the Docker CLI after it has been created.**

That is the entire trick. Concretely, for each of the four node containers:

```
  1.  make a directory for the CA to live in
        docker exec <node> mkdir -p /etc/containerd/certs.d/host.docker.internal:5001

  2.  copy the CA into it
        docker cp ca.crt  <node>:/etc/containerd/certs.d/host.docker.internal:5001/ca.crt

  3.  copy the instruction file beside it
        docker cp hosts.toml <node>:/etc/containerd/certs.d/host.docker.internal:5001/hosts.toml

  4.  tell containerd that directory is where it should look
        docker exec <node> sed -i 's|config_path = ""|
                                      config_path = "/etc/containerd/certs.d"|' …

  5.  make containerd notice
        docker exec <node> pkill -HUP containerd
```

**Why this is a workaround and not a solution:** it is a post-hoc patch applied
by an external process over the Docker API, to state that lives inside a
container's writable layer. It has no lifecycle. Every assumption it rests on
can be broken silently:

- the nodes are **recreated** on any `vcluster delete`/`create`, and on
  rescheduling after a crash — and the CA is gone, because it was never in the
  image and never on a volume;
- nothing in the normal Kubernetes workflow **re-runs it**;
- every step's failure is **individually discarded**, and success is printed
  unconditionally.

Which brings us to what we found.

---

## 4. What we built to study it

Studying this inside the full stack is impractical — the registry is one service
among eleven, and the cluster is one of four. So we extracted *only this
mechanism* into a directory that runs on its own.

```
  this project                          the source it came from
  ─────────────                         ─────────────────────────
  docker-compose.yml      ── extract ──► deploy/docker-compose.yml
      core-registry, core-registry-ui      (8 other services removed)

  .env                    ── extract ──► deploy/.env
  vcluster1.yml           ── extract ──► deploy/vcluster1.yml
  scripts/
    containerd-hosts.toml ── extract ──► deploy/scripts/containerd-hosts.toml
    purge_registry.sh     ── extract ──► deploy/scripts/purge_registry.sh
    recover_registry_ca.sh── extract ──► deploy/scripts/recover_registry_ca.sh
  Makefile                ── extract ──► deploy/Makefile
      certs, registry-up, vcluster-up,      (certs target, k8s step [2/10])
      patch-nodes                            copied VERBATIM
  k8s/1.01.nginx-pull-test.yaml  ── added ──►  (no equivalent exists)
  verify-extract.sh        ── added ──►     (proves the extraction is intact)
```

**It is an extraction, not a rewrite.** The registry services are byte-identical
to the source apart from a set of renames (§7.4), and the `certs` recipe and the
`k8s` step-`[2/10]` injection loop are copied verbatim — **including the parts
that are wrong**, because correcting them would destroy the thing we are trying
to study.

`./verify-extract.sh` proves this mechanically:

```
  1. verbatim files            every extracted file, compared byte-for-byte
  2. docker-compose.yml        the registry services == source, modulo the
                               declared renames — nothing else may differ
  3. Makefile recipes          the specific lines that carry the behaviour
  4. compose project isolation our project name cannot collide with the source's
  5. declared deviations       every difference, enumerated
```

If it fails, the reproduction has drifted and nothing concluded from it is
worth anything.

**What is deliberately not extracted:** the source's own Kubernetes manifests.
They are the real application services, and each one needs a ServiceAccount,
ConfigMaps, a Vault Secret and a full configuration surface before it does
anything. That is the wrong shape for isolating an image pull — and it is where
we found one of the bugs (D5). So the test workload is a stock `nginx:alpine`,
whose two load-bearing lines are byte-identical in form to the source's:

```yaml
# source    k8s/core1/4.04.users.deployment-service.yaml
image: host.docker.internal:5001/core-users:0.6
imagePullPolicy: Always

# here      k8s/1.01.nginx-pull-test.yaml
image: host.docker.internal:5001/regis-nginx:alpine
imagePullPolicy: Always
```

---

## 5. What we found

Eight defects. The full list with evidence is in §9; the four that matter most:

### The one string that must agree in five places  ·  **D6, the worst**

The registry's address — `host.docker.internal:5001` — appears in **five**
places, written in three different files, with nothing checking that they agree:

```
                host.docker.internal:5001
                ═══════════════════════════════
   ┌──────────────┬───────────────┬───────────────┬─────────────┐
   ▼              ▼               ▼               ▼             ▼
 [1] SAN      [2] certs.d     [3] hosts.toml  [4] ca_file   [5] image
 DNS.3 in     directory      server =        path inside  reference in
 san.cnf      name           "https://…:5001"hosts.toml  the manifest

 Makefile     Makefile       scripts/        scripts/     k8s/*.yaml
 `certs`      cp target      containerd-     containerd-  (rendered)
                             hosts.toml      hosts.toml
```

If any one of them disagrees with the others, the CA can be present, correct,
and **never consulted**. No error, no warning, no log line.

**The dangerous case is [2].** The directory containerd scans is named after the
registry host. Put the CA in `certs.d/localhost:5001/` and containerd is looking
for a registry called `localhost:5001` — which is not the one the node dials. You
get:

```
  ca.crt      present   ✔
  hosts.toml  present   ✔
  config_path set       ✔
  → "✓ node patched"
  → every pull: x509: certificate signed by unknown authority
```

A correct certificate, installed exactly as instructed, in a directory nothing
will ever read.

**And our own project README teaches this.** The source's `README.md` documents
the certs.d path as `localhost:5001`. Anyone following it reproduces this failure
precisely, with a green tick printed. The source code uses
`host.docker.internal:5001`; only the documentation is wrong. That divergence
between the docs and the code is finding D6.

### The "reload" is a kill  ·  **D2**

The last step of the workaround is `pkill -HUP containerd`. It is commented as a
reload, and described as one in the README. It is not a reload — **it terminates
containerd**:

```
  before      pid=1260   systemd=active
  pkill -HUP containerd
  t+ 2s       pid=-      systemd=activating
  t+ 4s       pid=-      systemd=activating
  t+ 6s       pid=-      systemd=activating
  t+ 8s       pid=2174   systemd=active      ← different PID
```

It only appears to work because systemd starts a *new* process (note the PID
change) about seven seconds later. For those seven seconds **every node has no
container runtime at all**, and every pod on it is stuck. The loop has already
printed `✓ <node> patched`.

`systemctl restart containerd` is survivable; SIGHUP is not.

### Nothing in the loop can fail  ·  **D3**

All five steps of the workaround are individually guarded with
`2>/dev/null || true`, and `✓ <node> patched` is echoed unconditionally. A missing
`hosts.toml`, a wrong directory name, a `config_path` that never took — all
produce the same output as a correct patch. Combined with the finding above,
this is what makes that entire failure family invisible.

### The CA is supplied and then not verified  ·  **D4**

```toml
[host."https://host.docker.internal:5001"]
  ca_file = "/etc/containerd/certs.d/host.docker.internal:5001/ca.crt"
  skip_verify = true          ← …and then not checked
```

Those two lines contradict each other. The CA is handed to containerd and
verification is switched off, so **a pull succeeds even if `ca.crt` is the wrong
CA, or is stale.** The failure this whole mechanism exists to prevent — a node
that cannot verify the registry — is therefore undetectable from the pull result.

A green deployment is not evidence that the trust chain works. It is evidence
that the path is reachable.

---

## 6. Seeing it work

The demonstration is: a registry we run ourselves, with a certificate we
generated ourselves, serving an image that a Kubernetes node we never configured
by any supported means pulls over HTTPS and runs.

```bash
# 0. prove the reproduction is still faithful to the source
make verify-extract

# 1. generate the certificates and start the registry
make registry-up        # openssl → ca.crt + server.crt; compose up; wait for HTTPS
make preflight          # is the CA on disk the one the registry is serving?
make catalog

# 2. put an image in it
make push-nginx         # docker pull nginx:alpine → retag → push
make catalog            # regis-nginx appears

# 3. create the cluster and inject the CA into every node
make vcluster-up        # vcluster create + the five-step injection, per node
make verify-nodes       # read back what actually landed

# 4. the assertion
make deploy-nginx
kubectl -n regis-pull get events --sort-by=.lastTimestamp | grep -i pull
#  → Successfully pulled image "host.docker.internal:5001/regis-nginx:alpine"

# 5. and prove the result means something
make pull-test-fail     # a tag that does not exist MUST fail
make status
```

Step 5 is not ceremony. With a self-signed registry, a wrong CA, a wrong tag, an
unresolvable host and a dead registry **all produce the same `ErrImagePull`**.
Without a test that must fail, "it worked" is indistinguishable from "the image
was already cached on the node".

### Two things the repo does not set up for you

1. **The Docker daemon's own trust store.** `curl` honours `--cacert`, so every
   preflight passes; but `docker push` goes through the daemon, which has a
   separate store that nothing populates. `make push-nginx` installs the CA and
   tells you if a restart is needed. Details in §7.5.
2. **kubectl must point at the cluster** — `make k8s-use`. Note that
   `vcluster connect --update-current=true` rewrites the **global**
   current-context, so anything else you have running follows the switch. Use a
   scoped `KUBECONFIG` if other work is in flight.

---

## 7. The mechanism in detail

### 7.1 Chain of custody

```
  ①  make certs                openssl, on the host
     ─────────►               ca.key ──signs──► ca.crt   (CA, 730 days)
                                             │signs
                                             ▼
                                        server.crt          (leaf, 2 days)
                                        SAN: localhost
                                             core-registry
                                             host.docker.internal  ★
                                             127.0.0.1

  ②  compose mounts            core-registry serves HTTPS on :5000
     ─────────►               /certs/server.{crt,key}   (read-only bind mount)
                              the CA is NOT given to the registry — only to
                              the clients. The registry presents and waits.

  ③  k8s step [2/10]          into each node container:
     ─────────►               certs.d/host.docker.internal:5001/{ca.crt,hosts.toml}
                              config_path = "/etc/containerd/certs.d"
                              pkill -HUP containerd        (a kill — D2)

  ④  the kubelet pulls        CRI → containerd → reads hosts.toml → HTTPS
     ─────────►               the CA is in place, the name is in the SAN,
                              the pull succeeds, the container runs
```

### 7.2 Why the gateway name, and not `localhost`

```
  ┌─ your Mac ──────────────────────────────────────────────────┐
  │   host process → https://localhost:5001   (published port)  │
  │                                                             │
  │   ┌─ Docker Desktop VM ───────────────────────────────────┐ │
  │   │  a vcluster node                                      │ │
  │   │    "localhost" here = THIS CONTAINER                  │ │
  │   │    there is no registry on :5001 inside it            │ │
  │   │                                                       │ │
  │   │    host.docker.internal ──► VM gateway ──► host       │ │
  │   │                          ──► published port 5001      │ │
  │   └───────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────┘

  host-side tools   →  localhost:5001
  kubelet in a node →  host.docker.internal:5001
```

`host.docker.internal` is Docker's embedded DNS name for the VM gateway. It
resolves to the host from inside any container, and the host's published port is
then reachable. **This is the fact the whole design rests on**, and it is why the
certificate, the trust store and the image reference all key on it.

### 7.3 What each certificate name is for

A TLS client checks **the name it dialled** against the certificate's SAN list —
not the server's own hostname, and not what the client believes the server to be.
So there is one entry per *client vantage point*:

| SAN | who dials it | do they verify? |
|---|---|---|
| `localhost` | host-side tools: `curl --cacert … https://localhost:5001` | yes |
| `core-registry` | the UI's nginx, via `NGINX_PROXY_PASS_URL` | **no** — `NGINX_PROXY_SSL_VERIFY: "off"` |
| `host.docker.internal` | **the vcluster kubelet** | **yes** ★ |
| `127.0.0.1` | IP-literal clients | yes |

Measured, against a certificate carrying the first three, with the CA trusted by
the client:

```
  name the CLIENT dials        verdict
  ──────────────────────────   ──────────────────────────────────
  localhost                    ✅ accepted
  core-registry                ✅ accepted
  wrong.example                ❌ Hostname mismatch
```

**Two conditions must both hold** for a real pull to succeed:

| | condition | established by | if it fails |
|---|---|---|---|
| **(a)** | the CA that signed the leaf is in the store containerd consults | `hosts.toml` + `ca.crt` + `config_path` | `certificate signed by unknown authority` |
| **(b)** | the dialled name is in the certificate's SANs | `DNS.3 = host.docker.internal` | `certificate is valid for localhost, not host.docker.internal` |

And because of D4, **(a) is not actually enforced at runtime.** A successful pull
proves (b) and connectivity — not that the CA is correct.

### 7.4 Why we renamed things

`container_name` and the compose project name are **docker-daemon-global**, not
scoped to a directory, and a vcluster name is global to the vcluster CLI. Sharing
them with the source means `docker compose -p <project> down` or
`vcluster delete <name>` from either directory destroys the other's containers,
volumes and cluster. This is not theoretical — it happened, repeatedly, before
the renames.

| this project | source | what |
|---|---|---|
| `regis` | `corebanking` | compose project + network |
| `regis_registry`, `regis_registry_ui` | `core_registry`, `core_registry_ui` | compose service keys |
| `regis-registry`, `regis-registry-ui` | `core-registry`, `core-registry-ui` | `container_name`, `hostname`, proxy URL |
| `my-regis1` | `my-core1` | vcluster |
| SAN `DNS.2 = regis-registry` | `core-registry` | certificate name |

**The mechanism is untouched.** Only resource identity changed.

> **A trap worth knowing:** renaming `name: regis` in the compose file is *not*
> sufficient. Docker Compose resolves the project name as
> `-p flag > COMPOSE_PROJECT_NAME (env) > name: (file)`, and the extracted `.env`
> is verbatim and pins `COMPOSE_PROJECT_NAME=corebanking`, which beats the file.
> Isolation comes from setting both. `verify-extract.sh` §4 checks the resolution
> empirically.

### 7.5 The second trust store

| | who needs it | when | set up? |
|---|---|---|---|
| **containerd** in each node | the kubelet | pull | **yes** — step `[2/10]` |
| **docker daemon** on the host | `docker push` | build | **no** |

The source defers verification explicitly — `scripts/deploy-app.sh`:

```bash
# Use -k for preflight (self-signed cert); CA cert verification happens at build/push time
```

and `core/build/Makefile` then honours it with `curl --cacert`, before running
`docker buildx --push`, which goes through the daemon. The preflight proves the
CA one way; the push needs it known another way. The deferral lands in the gap.

---

## 8. Diagnosing a failure

```
  symptom                                        → condition failed
  ─────────────────────────────────────────────────────────────────────
  x509: certificate signed by
    unknown authority                                (a) CA not trusted
                                                     ↳ ca.crt in the node?
                                                       hosts.toml there?
                                                       config_path set?
                                                       …or is the CA STALE (D7)?
  x509: certificate is valid for
    localhost, not host.docker.internal              (b) SAN missing
  x509: certificate has expired                       2-day leaf expired
  lookup host.docker.internal: no such host          DNS, not TLS
  connection refused                                 registry not listening
  manifest unknown / 404                             tag not in the registry
  manifest rejected by the API server                scheme in the image ref
```

```bash
make preflight      # is the CA on disk the CA the registry is SERVING?
make verify-nodes   # is ca.crt + hosts.toml + config_path in each node?
make catalog        # is the tag there?

docker exec <node> ls -la /etc/containerd/certs.d/host.docker.internal:5001/
docker exec <node> cat    /etc/containerd/certs.d/host.docker.internal:5001/hosts.toml
docker exec <node> grep    config_path /etc/containerd/config.toml
docker exec <node> sh -c 'systemctl is-active containerd'
docker exec <node> journalctl -u containerd --no-pager -n 20
```

`make preflight` exists to separate two failures that look identical from a pull:
**the registry is down**, and **the registry is serving a different certificate
than the one on disk**. The second is caused by re-minting certificates while the
registry was running (D7), and its only symptom is `unknown authority` — which
reads like a CA problem rather than a lifecycle-coupling one.

---

## 9. Full defect list

| # | defect | state |
|---|---|---|
| **D1** | Registry healthcheck used `curl`, which `registry:2` does not have — the container was permanently `unhealthy`, masked because the UI used `service_started` | **fixed upstream** (`wget`) |
| **D2** | `pkill -HUP containerd` is a kill, not a reload; ~7 s with no runtime on every node, reported as `✓` | open |
| **D3** | Every step of the injection loop is failure-guarded; success is echoed unconditionally — the loop cannot fail | open |
| **D4** | `ca_file` and `skip_verify = true` contradict each other; the CA is never actually verified | open |
| **D5** | `make vault-secret` creates the Secret in `core`; every service Deployment is in `admin` and mounts it — namespace-scoped, so the mount can never resolve and pods hang in `ContainerCreating` | open |
| **D6** | `README.md` documents a different mechanism than the code: wrong node names, **wrong certs.d path (`localhost` vs `host.docker.internal`)**, no `hosts.toml`, no `config_path`, SIGHUP described as a reload, and manifests shown with an `https://` prefix that the API server rejects | open |
| **D7** | `make down` deletes `data/registry/`, destroying the CA **private key** while nodes keep the old CA — and `make run` re-mints certs without re-patching nodes, so every pull then fails with `unknown authority` | open |
| **D8** | The docker daemon's trust store is never populated, so the first `docker push` in a fresh checkout fails on TLS | open |

### D6 in detail — the docs contradict the code

| `README.md` says | the code does |
|---|---|
| nodes are `worker-1, worker-2, worker-3` | `vcluster.cp.<name>`, `vcluster.node.<name>.worker-{1,2,3}` |
| certs.d path is **`localhost:5001`** | **`host.docker.internal:5001`** |
| no `hosts.toml` copied | copies it |
| no `config_path` set | sets it |
| "SIGHUP reloads containerd without restarting the node" | it kills it (D2) |
| "Idempotent: safe to re-run on every `make k8s`" | each run kills containerd again |
| healthcheck `curl -kfsS …` | `wget …` (D1) |
| `image: https://host.docker.internal:5001/…:0.1` | `host.docker.internal:5001/…:0.6` — **zero** with a scheme, across all four cores |

### D7 in detail — the teardown that orphans the trust anchor

```
   make down  →  rm -rf ./data/registry
                     │
                     └─► contains certs/ca.key
                          THE ONLY COPY IN EXISTENCE
                          nodes hold only the public ca.crt

   next `make run`   → mints a BRAND NEW CA
                      → registry serves the new certificate
                      → but make run does NOT re-patch the nodes
                        (only `make k8s` step 2 does, and it is not in `make run`)

   result:  stack reports healthy
            cluster cannot pull a single image
            symptom: "certificate signed by unknown authority"
            — which reads like a CA problem
```

`scripts/recover_registry_ca.sh` exists precisely to copy the CA back out of a
node, and documents that the private key is unrecoverable. That is a workaround
for an ordering defect, not a fix.

---

## 10. What we recommend

In priority order. The first three are small and each removes a whole class of
confusion.

1. **Rewrite `README.md`'s registry section from the Makefile.** It currently
   teaches a certs.d path that cannot work (D6). Documentation that contradicts
   the code is worse than none when the code's own output is unfalsifiable (D3).

2. **Extract `scripts/patch_registry_ca.sh` and call it from the Makefile.** The
   mechanism most worth testing is the part with no seam — five chained
   `docker cp`/`exec` steps in a make recipe. A script is the *precondition* for
   testing it.

3. **Make that script verify, then exit non-zero.** Read `ca.crt`, `hosts.toml`
   and `config_path` back out of each node, and assert the certs.d directory name
   matches the authority the manifests actually use. That single check closes D3
   and the entire authority-mismatch family.

4. **Add `make registry-daemon-ca`** to populate the docker daemon's trust store
   (D8), so the push path stops depending on manual setup.

5. **Replace `pkill -HUP containerd` with `systemctl restart containerd`**, and
   correct the comments that describe it as a reload (D2). Measured: the restart
   is survivable, the SIGHUP is not. Then wait for
   `systemctl is-active containerd` before printing `✓`.

6. **Decide what `skip_verify` should be (D4).** Either set it `false` and accept
   that a stale CA now fails loudly — the correct choice, and it makes
   `preflight` and the pull agree — or keep `true` and document explicitly that
   the CA is best-effort and `preflight` is the only check. What is not
   defensible is shipping `ca_file` and `skip_verify = true` in the same file
   with nothing reconciling them.

7. **Derive the authority once.** Five occurrences of
   `host.docker.internal:5001` across three files, unvalidated. A single
   `REGISTRY_AUTHORITY` feeding the SAN list, the certs.d path, `hosts.toml` and
   the manifest renderer makes the mismatch family structurally impossible.

8. **Move `make vault-secret` to the namespaces that consume it** (D5), or create
   it in each.

9. **Stop `rm -rf ./data/registry` in `make down`** (D7), or preserve
   `certs/ca.key` and wipe only the leaf. `scripts/purge_registry.sh --full`
   already preserves `certs/`; `make down` should use the same discipline.

10. **Reconsider the 2-day leaf, or re-patch nodes from `make run`.** Either
    removes the D7 window. The current design ties trust state to a directory
    that `make down` deletes, on a 2-day clock.

---

## Where things are

```
  Makefile                          orchestration; every target idempotent
  docker-compose.yml                registry + UI, extracted, renames applied
  .env                              verbatim from the source
  vcluster1.yml                     verbatim — node topology and volumes
  scripts/
    containerd-hosts.toml           verbatim, 75 bytes, no trailing newline
    purge_registry.sh               verbatim — preserves certs/ across a wipe
    recover_registry_ca.sh          verbatim — the ca.key-is-unrecoverable warning
  k8s/
    1.01.nginx-pull-test.yaml       the only added file — the pull test
  docs/
    9.Registry_TLS.md               source-ready reference, for deploy/docs/
  verify-extract.sh                 mechanical proof the extraction is intact
  data/                             generated; never committed (CA private key)
```

`docs/9.Registry_TLS.md` is written for the source project — it uses the
source's own resource names and file paths, and follows the numbering of
`deploy/docs/`. It is the document to push back into the source alongside the
`README.md` corrections in §10.1.
