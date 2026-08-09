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
    sample-app/                      # shared Deployment + Service (image: nginx, replicas: 1)
    service-b/
  overlay/
    dev/sample-app/                  # env overlay: namespace, image tag, replicas
    stage/sample-app/
    sandbox/sample-app/
    prod/sample-app/
  namespaces.yaml
scripts/
  promote.sh                         # simulate a tag promotion dev → stage → prod
```

Each env overlay pins its own image tag and namespace:

| Env     | Namespace           | Replicas | Image (current) |
|---------|---------------------|----------|-----------------|
| dev     | `sample-app-dev`    | 1        | `nginx:1.27.0`  |
| stage   | `sample-app-stage`  | 1        | `nginx:1.27.0`  |
| sandbox | `sample-app-sandbox`| 1        | `nginx:1.27.0`  |
| prod    | `sample-app-prod`   | 1        | `nginx:1.27.0`  |

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

To reset an overlay after a simulation:

```bash
git checkout repo/overlay/dev repo/overlay/stage   # prod overlay is new/untracked
```

## Render an environment manually

```bash
kustomize build repo/overlay/dev/sample-app
```

## Changes made in this iteration

- Added the missing **`repo/overlay/prod/sample-app`** overlay so the full
  dev → stage → prod path exists.
- **Unified replicas to `1`** across dev, stage, and prod (previously 1 / 2 / 3).
  Since `base` already sets `replicas: 1`, the per-env replica patch is currently a
  no-op — kept in place as a ready knob for scaling an env later.
- Added **`scripts/promote.sh`** to simulate tag promotion across environments.

## Known gaps / TODO

These do not affect the local dry-render simulation, but must be fixed before this
promotes correctly on a live cluster:

- [x] ~~**ApplicationSet path** points to `repo/overlay/{{env}}` but the `kustomization.yaml`
  files live in `repo/overlay/{{env}}/sample-app`.~~ Now targets `repo/overlay/{{env}}/sample-app`.
- [x] ~~**Namespace is defined three ways**.~~ Standardized on `sample-app-<env>` everywhere:
  overlays render into it, the appset destination is `sample-app-{{env}}` with
  `CreateNamespace=true`, and `namespaces.yaml` matches.
- [x] ~~**`sandbox` overlay is empty** — its generated Application cannot sync.~~
  Added `repo/overlay/sandbox/sample-app` (namespace `sample-app-sandbox`, replicas 1).
- [ ] Not yet added: Istio `DestinationRule` / `VirtualService` for canary traffic
  shifting (see conversation notes on pipeline-driven vs. Argo Rollouts canary).
