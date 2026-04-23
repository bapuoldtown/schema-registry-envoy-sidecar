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
├── LICENSE
└── .gitignore
```

---

## Quick local POC (prove it works before touching CBA)

```bash
docker compose up -d
sleep 40
bash scripts/verify.sh
```

Expected: 6 green PASS lines. If you see all green, the RBAC filter is
behaving correctly — you have a working artefact to demo.

## Proof of DELETE Blocking

Running the verification script produces the following output, confirming DELETE requests are blocked:

```
== Target: http://localhost:8080  |  Subject: envoy-poc-1776944867 ==

== Test 1: GET /subjects → expect 200 ==
  PASS GET 200

== Test 2: POST schema → expect 200 ==
  PASS POST 200, body: {"id":2}

== Test 3: DELETE subject → expect 403 + x-delete-blocked header ==
    status: 403, header: x-delete-blocked: envoy-sidecar-rbac
    body:   {"blocked_by":"envoy-sidecar-rbac","error_code":40300,"message":"DELETE blocked by Envoy sidecar RBAC policy"}
  PASS DELETE blocked (403 + proof header present)

== Test 4: DELETE version → expect 403 ==
  PASS DELETE version 403

== Test 5: Subject still exists (DELETE didn't leak through) → expect 200 ==
  PASS GET versions 200: [1]

== Test 6: Envoy RBAC metrics (admin :9901) ==
    rbac.allowed=3  rbac.denied=2
  PASS rbac.denied=2 (>=2 expected)

== Summary: 6 passed, 0 failed ==
```

This demonstrates that:
- DELETE requests return 403 Forbidden with a custom `x-delete-blocked` header.
- The subject persists after attempted deletion.
- Envoy metrics show 2 denied requests (the DELETE attempts).

```bash
# When you're done:
docker compose down -v
```

---

## The mission in 4 bullets

1. **Envoy image mirror:** file ticket for platform team to mirror `envoyproxy/envoy:v1.31-latest` to `hub.docker.internal.cba/envoyproxy/envoy:...`.

2. **ADR review:** share ADR with platform lead + security + networking. Answer open questions.

3. **PR in GitOps repo:** modify deployment.yaml to add sidecar container.

4. **Dev soak → prod rollout:** follow phased plan.

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
