# ingress-nginx-to-gateway-api

Classifies ingress-nginx annotations into three categories and provides Gateway API migration manifests with verification scripts.

## Category breakdown

| Scenario | before | category-a | category-b (Envoy Gateway) | category-b (Istio) |
|---|---|---|---|---|
| basic routing | ✓ | ✓ | — | — |
| rewrite | ✓ | ✓ | — | — |
| canary | ✓ | ✓ | — | — |
| auth | ✓ | — | ✓ | ✓ |
| rate-limit | ✓ | — | ✓ | ✓ |
| X-Custom-Header | ✓ | ✓ | — | — |
| X-Request-ID | ✓ | — | ✓ | ✓ |

- **category-a**: Migrates using Gateway API standard spec (HTTPRoute filters). The manifests reference `parentRefs.name: eg` (Envoy Gateway). When running with Istio, the verification script rewrites the name to match the Istio Gateway.
- **category-b**: Migrates to implementation-specific CRDs. The approach depends on which implementation you choose.
- **category-c**: No migration path exists. Most nginx directives in `configuration-snippet` fall here. Simple use cases like adding a static response header can be replaced with the standard `ResponseHeaderModifier` filter (category-a), but there is no structural equivalent for arbitrary nginx directives in Gateway API.

## Directory structure

```
.
├── app/
│   ├── echo.yaml                    # sample app (v1 / v2)
│   └── auth-service.yaml            # mock auth service
├── before/                          # ingress-nginx manifests (pre-migration)
├── after/
│   ├── category-a/                  # migrates to Gateway API standard
│   ├── category-b-envoy-gateway/    # migrates to Envoy Gateway-specific resources
│   └── category-b-istio/            # migrates to Istio-specific resources
├── kind/                            # kind cluster configs for local verification
└── scripts/
    ├── lib/tests.sh                 # shared test functions
    ├── verify-before.sh             # verify with ingress-nginx
    ├── verify-envoy.sh              # verify with Envoy Gateway
    └── verify-istio.sh              # verify with Istio
```

## Local verification

Requires `limactl` and `kubectl`. Each script creates or reuses a Lima k3s instance by default. To run against an existing cluster, set `KUBECONFIG` before running the script.

```bash
# ingress-nginx (before migration)
bash scripts/verify-before.sh

# Envoy Gateway (after migration)
bash scripts/verify-envoy.sh

# Istio (after migration)
bash scripts/verify-istio.sh
```

## About auth-service

The auth tests in `before/04-auth.yaml` and `after/category-b-*/04-auth.yaml` require `app/auth-service.yaml` to be deployed. It returns 200 for requests with `Authorization: Bearer valid-token` and 401/403 otherwise. Replace with real JWT validation or OAuth token introspection in production.
