# argo-auto-promote

A GitOps demo showing how an application version is **promoted through environments**
(dev → stage → prod) using Argo CD `ApplicationSet` + a shared Helm chart.

![img.png](img.png)

## Concept

- Every build produces an **immutable, uniquely-tagged image** (e.g. `service-a:0.0.2`,
  or in real life a git-SHA tag like `myapp:git-a1b2c3d`).
- **Promotion = pinning that same tag in the next environment's values file and
  committing.** The image bits never change as they move — what you tested in dev
  is the exact same image that runs in stage and prod.
- Argo CD watches the repo; each `(service, env)` `Application` auto-syncs when its
  values file changes (`syncPolicy.automated` with `prune` + `selfHeal`).
- Promotion is **per service** — `service-a` and `service-b` each have their own
  tag per environment and promote independently. Nothing ties one service's version
  to another's.
- You can **skip versions** (promote sha5 to stage even if dev has moved on to sha7) and
  **roll back** (pin an older tag) — both are just the same "set the tag" operation.

## The services

`services/service-a` and `services/service-b` are minimal Spring Boot apps (Java 21,
Maven), each with one endpoint:

```bash
GET /   ->  {"service": "service-b", "environment": "sample-dev", "imageTag": "0.0.1", "changes": "..."}
```

`environment` and `imageTag` come from the `ENVIRONMENT` / `IMAGE_TAG` env vars the
chart sets on the container (see [The chart](#the-chart-one-template-for-every-service)).

`service-a` additionally calls `service-b` over HTTP (`SERVICE_B_URL`, defaulting to
`http://service-b` — the bare Service name resolves via cluster DNS since both apps
share a namespace) and returns the combined result:

```json
{
  "service": "service-a",
  "environment": "sample-dev",
  "imageTag": "0.0.1",
  "changes": "Calls service-b and returns its response combined with its own",
  "serviceB": {"service": "service-b", "environment": "sample-dev", "imageTag": "0.0.1", "changes": "..."}
}
```

Run one locally:

```bash
cd services/service-b && mvn spring-boot:run
# in another shell
cd services/service-a && SERVICE_B_URL=http://localhost:8080 mvn spring-boot:run -Dspring-boot.run.arguments=--server.port=8081
```

Build the image each values file expects (repository name matches `chart/services/<service>/*.yaml`'s `image.repository`):

```bash
cd services/service-a && docker build -t service-a:0.0.1 .
cd services/service-b && docker build -t service-b:0.0.1 .
```

These images aren't pushed to a registry by default — the values files reference
`service-a:0.0.1` / `service-b:0.0.1` by name, so the cluster needs to already have
them (build directly against the cluster's own container runtime, or push
somewhere it can pull from, and update `image.repository` accordingly).

## The chart: one template for every service

`chart/` is a single generic Helm chart (`Deployment` + `Service`, optionally a
`VirtualService` + `Ingress`) shared by every service. Nothing service-specific is
hardcoded in it — what differs per service/env lives entirely in small values files:

```
chart/
  Chart.yaml
  values.yaml                # shared defaults: port, resources, replicas, ...
  templates/
    deployment.yaml
    service.yaml
    virtualservice.yaml      # only rendered if route.enabled
    ingress.yaml             # only rendered if route.enabled
  services/
    service-a/
      dev.yaml
      stage.yaml
      sandbox.yaml
      prod.yaml
    service-b/
      dev.yaml
      stage.yaml
      sandbox.yaml
      prod.yaml
```

A values file is tiny — this is the *entire* per-service, per-env config:

```yaml
# chart/services/service-a/stage.yaml
name: service-a
image:
  repository: service-a
  tag: "0.0.1"
env:
  SERVICE_B_URL: http://service-b
route:
  enabled: true
  env: stage
```

`IMAGE_TAG` is set directly from `.Values.image.tag` — the same value used for the
container's `image:` field — so there's nothing to keep in sync by hand (the old
Kustomize version of this repo used a `replacements:` trick to read the tag back off
the Deployment's own image field; the chart doesn't need that at all).

**Adding service #3 (or #30):** add its `chart/services/<name>/*.yaml` files and one
line to the `ApplicationSet`'s service list (see below). Nothing else changes — no
new Deployment/Service YAML, no new routing wiring.

## Repository layout

```
chart/                                # see above
repo/
  appset/
    applicationset-services.yaml      # ONE ApplicationSet: matrix of services x envs
  istio/
    istio-base-application.yaml       # Argo CD Application: Istio CRDs (sync-wave 0)
    istiod-application.yaml           # Argo CD Application: control plane (sync-wave 1)
    istio-ingressgateway-application.yaml  # Argo CD Application: ingress gateway, ClusterIP (sync-wave 2)
    gateway-application.yaml          # Argo CD Application: shared Gateway (sync-wave 3)
    gateway/gateway.yaml              # the Gateway itself, lives once in istio-system
  namespaces.yaml
services/
  service-a/                          # Spring Boot app (Java 21, Maven) -- calls service-b, returns combined JSON
  service-b/                          # Spring Boot app (Java 21, Maven)
scripts/
  promote.sh                          # simulate promoting one service dev → stage → prod
```

The `ApplicationSet` generates one `Application` per `(service, env)` pair — e.g.
`service-a-dev`, `service-b-dev`, `service-a-stage`, ... — each syncing
`chart/` with that service/env's own values file:

```yaml
generators:
  - matrix:
      generators:
        - list: {elements: [{service: service-a}, {service: service-b}]}
        - list: {elements: [{env: dev}, {env: stage}, {env: sandbox}, {env: prod}]}
template:
  spec:
    source:
      path: chart
      helm:
        valueFiles: ["services/{{service}}/{{env}}.yaml"]
    destination:
      namespace: "sample-{{env}}"
```

| Env     | Namespace       | service-a (current) | service-b (current) |
|---------|-----------------|----------------------|----------------------|
| dev     | `sample-dev`    | `service-a:0.0.1`    | `service-b:0.0.1`    |
| stage   | `sample-stage`  | `service-a:0.0.1`    | `service-b:0.0.1`    |
| sandbox | `sample-sandbox`| `service-a:0.0.1`    | `service-b:0.0.1`    |
| prod    | `sample-prod`   | `service-a:PROD-v1.0.0` | `service-b:PROD-v1.0.0` |

### URLs (dev, stage)

`chart/services/*/dev.yaml` and `stage.yaml` set `route.enabled: true`, which makes
the chart also render a `VirtualService` (in the service's own `sample-<env>`
namespace) and an `Ingress` (explicitly in `istio-system`, alongside
`istio-ingressgateway` — a core `Ingress`'s backend service must live in the same
namespace as the `Ingress` itself). `sandbox`/`prod` leave `route` unset (`enabled:
false`), so they have no external URL.

Each `VirtualService` carries two hosts:

- a **`nip.io`** host, which resolves without any real DNS record — useful for
  testing straight against `istio-ingressgateway` (e.g. via `kubectl port-forward`),
  bypassing Traefik;
- a **real** host on the shared `apps.shirlenelim.se` wildcard — `<service>-<env>.apps.shirlenelim.se`.

| Env   | service-a | service-b |
|-------|------------|-----------|
| dev   | `service-a.dev.127.0.0.1.nip.io`<br>`service-a-dev.apps.shirlenelim.se` | `service-b.dev.127.0.0.1.nip.io`<br>`service-b-dev.apps.shirlenelim.se` |
| stage | `service-a.stage.127.0.0.1.nip.io`<br>`service-a-stage.apps.shirlenelim.se` | `service-b.stage.127.0.0.1.nip.io`<br>`service-b-stage.apps.shirlenelim.se` |

**How the real hosts reach a service:** this cluster already runs Traefik as its
ingress controller (Rancher Desktop's default, also fronting other workloads like
Grafana), so `istio-ingressgateway`'s Service is `ClusterIP` — not `LoadBalancer` —
and each service's own templated `Ingress` (in `istio-system`) routes to it. Traefik
merges rules from every `Ingress` matching its class, so 30 services means 30 small
`Ingress` objects, not one big hand-maintained one. Traefik forwards by `Host` header
to the gateway; the shared `VirtualService` (`istio-system/sample-gateway`, see
below) routes that same `Host` to the right service/namespace. A wildcard DNS record
(`*.apps.shirlenelim.se` → Traefik's external address) or an `/etc/hosts` entry per
host makes them resolve — this repo doesn't manage that; it's outside the cluster.

`127.0.0.1` in the `nip.io` host is a placeholder for the gateway's ClusterIP, only
reachable via `kubectl port-forward svc/istio-ingressgateway -n istio-system <port>:80`.

### Namespace convention

Namespaces are named **`sample-<env>`** = *the "sample" system, in that environment* —
not per service. A namespace is a boundary for RBAC / quotas / network policy, sized
to what should share it; here every service of the system shares its env's
namespace, even though each is now promoted independently via its own `Application`.

## Simulating a promotion

`scripts/promote.sh` pins a new image tag for **one service** into each env in order
and renders the resulting manifest at every hop, so you can see the diff a promotion
produces.

```bash
# Requires: helm
./scripts/promote.sh service-a 0.0.2
```

It prints the starting tag, promotes dev → stage → prod, shows the rendered
`replicas` / `image` for each, and ends with a `git diff --stat` of the values-file
changes. In real Argo CD, committing those changes is what triggers that service's
`<service>-<env>` Application to sync. Only the service you name is touched —
`service-b` (or service #3, #4, ...) is untouched by a `service-a` promotion.

Each promotion step also "pushes" to a **simulated registry** —
`scripts/registry.txt`, gitignored — recording the image alongside a
per-environment, per-push tag (`dev-v1.0.0`, `dev-v1.0.1`, `stage-v1.0.0`, ...).
The counter is derived from how many entries that env already has, so it keeps
climbing across runs:

```
service-a:0.0.2 dev-v1.0.0 2026-08-19T16:10:08Z
service-a:0.0.2 stage-v1.0.0 2026-08-19T16:10:08Z
service-a:0.0.2 prod-v1.0.0 2026-08-19T16:10:08Z
```

Each `[registry] env=... image=... tag=...` line printed during a run, and the
full simulated registry dumped at the end, show which environment got which
simulated version.

To reset the values files and the simulated registry after a simulation:

```bash
git checkout chart/services
rm -f scripts/registry.txt
```

## Render a service manually

```bash
helm template service-a-dev chart -f chart/services/service-a/dev.yaml -n sample-dev
```

## Promoting between environments (CI)

`.github/workflows/promote-to-env.yml` is a **gated** promotion. You pick a service
and a target env; it reads the *previous* env's pinned tag for that service and
copies it forward — so a tag can only reach an env after it ran in the env before it:

```
dev --> stage --> prod        (sandbox promotes from dev, as a side env)
```

The tag is never typed by hand, so prod can't receive an untested tag. Attach a
GitHub Environment protection rule to `prod` to require a reviewer.

## Installing Istio (Helm, via Argo CD)

`repo/istio/` has Argo CD `Application` manifests that install Istio from the
**official Istio Helm charts** (`https://istio-release.storage.googleapis.com/charts`)
directly — no chart code is vendored into this repo. Istio is cluster-wide
infrastructure, so these apps are not per-service/env and all land in `istio-system`:

| Application             | Chart    | Sync-wave |
|--------------------------|----------|-----------|
| `istio-base`             | `base`   | 0 (CRDs first) |
| `istiod`                 | `istiod` | 1 (control plane) |
| `istio-ingressgateway`   | `gateway`| 2 (ingress) |
| `sample-gateway`         | (plain YAML, `repo/istio/gateway/`) | 3 (the shared `Gateway`, needs the ingress gateway's Service first) |

The sync-wave annotations make Argo CD apply them in order, since `istiod` needs the
CRDs from `istio-base`, and the gateway needs `istiod` and `istio-ingressgateway`
running. Per-service `VirtualService`/`Ingress` resources are *not* deployed here —
each service's own chart render creates its own (see [URLs](#urls-dev-stage) above).

Bootstrap them once (they're standalone `Application`s, not generated per env):

```bash
kubectl apply -f repo/istio/
```

Bump `spec.source.targetRevision` in the three Helm-sourced `Application`s together
when upgrading Istio.

This is a prerequisite for the Istio `DestinationRule` / `VirtualService` canary
traffic-shifting work noted below — sidecar injection still needs to be enabled on the
`sample-*` namespaces (e.g. `istio-injection=enabled` label) before app pods pick up
the mesh.

## Known gaps / TODO

- [x] ~~ApplicationSet path / namespace / empty overlays~~ — fixed.
- [x] ~~service-b Service selector didn't match its pods~~ — fixed.
- [x] ~~Independent per-app promotion~~ — `chart/` + a matrix `ApplicationSet` give
  every service its own `Application` per env; `scripts/promote.sh` and the CI
  workflow both promote one named service at a time.
- [x] ~~Install Istio~~ — `repo/istio/` installs base/istiod/ingress gateway via Helm
  through Argo CD.
- [x] ~~Kustomize per-service boilerplate doesn't scale~~ — replaced with one shared
  chart; adding a service is now values files, not new Deployment/Service/overlay YAML.
- [ ] Push `service-a`/`service-b` images to a real registry — right now the
  values files reference `service-a:0.0.1` / `service-b:0.0.1` by name with nothing
  pushing them anywhere by default, so the cluster needs the images built locally
  against its own container runtime.
- [ ] Enable sidecar injection on `sample-*` namespaces and add `DestinationRule` /
  `VirtualService` for canary traffic shifting (see conversation notes on
  pipeline-driven vs. Argo Rollouts canary).
