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

## Verification

Manifests and scripts are verified automatically via GitHub Actions on every push.
