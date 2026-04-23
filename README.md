# Envoy Sidecar POC — Block SR DELETE at the Network Layer

Schema Registry pod with an **Envoy sidecar container** that blocks HTTP
DELETE via the RBAC filter. Complements ADR-001 (the JAR approach) as an
independent network-layer guardrail.

## Complete package contents

```
envoy-sidecar-poc/
├── README.md                                          # you are here
├── docker-compose.yml                                 # local POC (test before K8s)
├── envoy-config/
│   ├── envoy.yaml                                     # K8s sidecar config (127.0.0.1 upstream)
│   └── envoy.compose.yaml                             # Compose variant (DNS upstream)
├── scripts/
│   └── verify.sh                                      # 6-test proof harness
├── k8s/
│   ├── schema-registry-with-sidecar.yaml              # full K8s manifest (Deployment+Service+CM)
│   └── network-policy.yaml                            # bypass prevention
├── integration/
│   ├── DOCKERFILE-VS-DEPLOYMENT.md                    # WHERE changes go (key doc)
│   ├── ENVOY-IMAGE-MIRROR-TICKET.md                   # ticket template for platform team
│   └── PR-DESCRIPTION.md                              # ready-to-paste PR body
├── docs/
│   └── ADR-002-envoy-sidecar-block-delete.md          # proposal doc
├── LICENSE
└── .gitignore
```

---

## The 3 documents that matter most

| Doc | Read when |
|---|---|
| **`docs/ADR-002-envoy-sidecar-block-delete.md`** | Before presenting to platform lead |
| **`integration/DOCKERFILE-VS-DEPLOYMENT.md`** | When you're ready to make the PR |
| **`integration/PR-DESCRIPTION.md`** | Copy-paste into the PR |

The K8s manifests and Envoy config are the artefacts you'll actually deploy,
but the three docs above are what get you there socially.

---

## Quick local POC (prove it works before touching CBA)

```bash
docker compose up -d
sleep 40
bash scripts/verify.sh
```

Expected: 6 green PASS lines. If you see all green, the RBAC filter is
behaving correctly — you have a working artefact to demo.

```bash
# When you're done:
docker compose down -v
```

---

## The mission in 4 bullets

1. **Envoy image mirror:** file ticket (`integration/ENVOY-IMAGE-MIRROR-TICKET.md`)
   → platform team mirrors `envoyproxy/envoy:v1.31-latest` to
   `hub.docker.internal.cba/envoyproxy/envoy:...`.

2. **ADR review:** share `docs/ADR-002-envoy-sidecar-block-delete.md` with
   platform lead + security + networking. Answer Section 12 open questions.

3. **PR in GitOps repo:** use `integration/DOCKERFILE-VS-DEPLOYMENT.md` to
   see exactly which YAML files to change, and `integration/PR-DESCRIPTION.md`
   as the PR body.

4. **Dev soak → prod rollout:** follow the phased plan in ADR-002 Section 6.

---

## Compared to the JAR approach (ADR-001)

| Aspect | JAR (ADR-001) | Envoy sidecar (ADR-002) |
|---|---|---|
| Code I write | Java (BlockDeleteExtension) | YAML (envoy.yaml + Deployment changes) |
| Compile step? | Yes (Maven) | No |
| New repo for source? | Yes (schema-registry-extensions) | No |
| Artifact to publish? | JAR to JFrog | None |
| CBA Dockerfile change? | Yes (~10 lines) | **No change** |
| CBA Deployment YAML change? | No | **Yes** (add sidecar container) |
| Files to modify | `pom.xml`, `Dockerfile`, `deployment.yaml` (image tag only) | `deployment.yaml`, `service.yaml`, new `configmap.yaml` |
| New third-party image? | No | Yes (Envoy — needs mirror ticket) |
| JMX/Prometheus affected? | **No** (different subsystem) | **No** (different port) |

**Both approaches leave JMX on port 5556 completely untouched.** Neither
affects existing dashboards, alerts, or observability. The only thing that
changes is REST traffic enforcement on port 8081.

---

## Ship one, the other, or both?

- **JAR only (ADR-001):** smaller operational footprint, unbypassable (same JVM), but requires owning a Java build.
- **Envoy only (ADR-002):** zero Java, zero new CI, but adds a container to every SR pod.
- **Both (defense-in-depth):** requires bugs in BOTH layers to let a delete through. Strong guarantee, small cost.

Your platform lead decides. Both ADRs stand on their own; you've built
working POCs for each.

---

## Verification story (same for local + K8s)

```
GET /subjects                 → 200  (passthrough)
POST /subjects/X/versions     → 200  (passthrough)
DELETE /subjects/X            → 403  ← with x-delete-blocked: envoy-sidecar-rbac
DELETE /subjects/X/versions/1 → 403  ← same
GET /subjects/X/versions      → 200  (subject still exists, proving delete didn't leak)
GET :9901/stats?filter=rbac   → rbac.denied ≥ 2  (Envoy metric counter proof)
```

These 6 checks are what `scripts/verify.sh` runs. They're also your
evidence for screenshots in the ADR appendix.
