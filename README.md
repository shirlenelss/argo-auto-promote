# argo-auto-promote

A GitOps demo showing how an application version is **promoted through environments**
(dev → stage → prod) using Argo CD `ApplicationSet` + Kustomize overlays.

![img.png](img.png)

## Concept

- Every build produces an **immutable, uniquely-tagged image** (e.g. `nginx:1.27.0`,
  or in real life a git-SHA tag like `myapp:git-a1b2c3d`).
- **Promotion = pinning that same tag in the next environment's overlay and committing.**
  The image bits never change as they move — what you tested in dev is the exact same
  image that runs in stage and prod.
- Argo CD watches the repo; each environment's `Application` auto-syncs when its overlay
  changes (`syncPolicy.automated` with `prune` + `selfHeal`).
- You can **skip versions** (promote sha5 to stage even if dev has moved on to sha7) and
  **roll back** (pin an older tag) — both are just the same "set the tag" operation.

## Repository layout

```
repo/
  appset/
    applicationset-sample-app.yaml   # generates one Application per env (dev/stage/sandbox/prod)
  base/
    sample-app/                      # Deployment + Service (image: nginx, replicas: 1)
    service-b/                       # Deployment + Service (image: nginx, replicas: 1)
    routes/                          # Istio Gateway + VirtualServices (host set per env)
  overlay/
    dev/kustomization.yaml           # env overlay: namespace + system image tag (all apps)
    stage/kustomization.yaml
    sandbox/kustomization.yaml
    prod/kustomization.yaml
  namespaces.yaml
  istio/
    istio-base-application.yaml      # Argo CD Application: Istio CRDs (sync-wave 0)
    istiod-application.yaml          # Argo CD Application: control plane (sync-wave 1)
    istio-ingressgateway-application.yaml  # Argo CD Application: ingress gateway (sync-wave 2)
scripts/
  promote.sh                         # simulate a tag promotion dev → stage → prod
```

Each env overlay deploys the **whole "sample" system** (all apps) into one
per-environment namespace and pins the system's image tag:

| Env     | Namespace       | Apps                    | Image (current) |
|---------|-----------------|-------------------------|-----------------|
| dev     | `sample-dev`    | sample-app, service-b   | `nginx:1.27.0`  |
| stage   | `sample-stage`  | sample-app, service-b   | `nginx:1.27.0`  |
| sandbox | `sample-sandbox`| sample-app, service-b   | `nginx:1.27.0`  |
| prod    | `sample-prod`   | sample-app, service-b   | `nginx:1.27.0`  |

### URLs (dev, stage)

`dev` and `stage` overlay `base/routes` (an Istio `Gateway` + one `VirtualService` per
app) with env-specific `nip.io` hostnames, so each app is reachable through the
`istio-ingressgateway` installed in [Installing Istio](#installing-istio-helm-via-argo-cd)
without needing real DNS:

| Env   | sample-app                              | service-b                              |
|-------|------------------------------------------|------------------------------------------|
| dev   | `sample-app.dev.127.0.0.1.nip.io`         | `service-b.dev.127.0.0.1.nip.io`          |
| stage | `sample-app.stage.127.0.0.1.nip.io`       | `service-b.stage.127.0.0.1.nip.io`        |

`127.0.0.1` is a placeholder — swap it for the ingress gateway's real address:

```bash
kubectl -n istio-system get svc istio-ingressgateway
```

`sandbox` and `prod` don't include `base/routes`, so they have no external URL yet.

### Namespace convention

Namespaces are named **`sample-<env>`** = *the "sample" system, in that environment* —
not per app. A namespace is a boundary for RBAC / quotas / network policy, sized to
what should share it; here all apps of the system share their env's namespace. Use a
per-app namespace (`app-<env>`) only when apps need hard isolation from each other.

### Promotion granularity

Both apps currently use the `nginx` image, so a single `images: newTag` pins the
**whole system as a unit** (system-level promotion). To promote apps independently,
give them distinct image names (e.g. `myorg/sample-app`, `myorg/service-b`) and pin
each separately.

## Simulating a promotion

`scripts/promote.sh` pins a new image tag into each env in order and renders the
resulting manifests at every hop, so you can see the diff a promotion produces.

```bash
# Requires: kustomize
./scripts/promote.sh 1.28.0
```

It prints the starting tags, promotes dev → stage → prod, shows the rendered
`namespace` / `replicas` / `image` for each, and ends with a `git diff --stat`
of the overlay changes. In real Argo CD, committing those overlay changes is what
triggers each `sample-app-<env>` Application to sync.

To reset the overlays after a simulation:

```bash
git checkout repo/overlay
```

## Render an environment manually

```bash
kustomize build repo/overlay/dev
```

## Promoting between environments (CI)

`.github/workflows/promote-to-env.yml` is a **gated** promotion. You pick a target
env; it reads the *previous* env's pinned tag and copies it forward — so a tag can
only reach an env after it ran in the env before it:

```
dev --> stage --> prod        (sandbox promotes from dev, as a side env)
```

The tag is never typed by hand, so prod can't receive an untested tag. Attach a
GitHub Environment protection rule to `prod` to require a reviewer.

## Installing Istio (Helm, via Argo CD)

`repo/istio/` has three Argo CD `Application` manifests that install Istio from the
**official Istio Helm charts** (`https://istio-release.storage.googleapis.com/charts`)
directly — no chart code is vendored into this repo. Unlike the sample app, Istio is
cluster-wide infrastructure, so these apps are not per-environment and all land in
`istio-system`:

| Application             | Chart  | Sync-wave |
|--------------------------|--------|-----------|
| `istio-base`             | `base`   | 0 (CRDs first) |
| `istiod`                 | `istiod` | 1 (control plane) |
| `istio-ingressgateway`   | `gateway`| 2 (ingress) |

The sync-wave annotations make Argo CD apply them in order, since `istiod` needs the
CRDs from `istio-base`, and the gateway needs `istiod` running.

Bootstrap them once (they're standalone `Application`s, not generated per env):

```bash
kubectl apply -f repo/istio/
```

Bump `spec.source.targetRevision` in all three files together when upgrading Istio.

This is a prerequisite for the Istio `DestinationRule` / `VirtualService` canary
traffic-shifting work noted below — sidecar injection still needs to be enabled on the
`sample-*` namespaces (e.g. `istio-injection=enabled` label) before app pods pick up
the mesh.

## Known gaps / TODO

- [x] ~~ApplicationSet path / namespace / empty overlays~~ — fixed; appset targets
  `repo/overlay/{{env}}`, destination `sample-{{env}}` with `CreateNamespace=true`,
  all four envs present.
- [x] ~~service-b Service selector didn't match its pods~~ — fixed
  (`app: service-b-app`).
- [ ] Independent per-app promotion — both apps share the `nginx` image, so they
  promote as one unit. Give them distinct image names to promote separately.
- [x] ~~Install Istio~~ — `repo/istio/` installs base/istiod/ingress gateway via Helm
  through Argo CD.
- [ ] Enable sidecar injection on `sample-*` namespaces and add `DestinationRule` /
  `VirtualService` for canary traffic shifting (see conversation notes on
  pipeline-driven vs. Argo Rollouts canary).
