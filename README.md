# AI Inferencing with Azure Arc

Experimentation and validation outcomes for deploying AI inference workloads on Azure Arc-enabled Kubernetes clusters across different distributions.

## Goal

Validate that AI inference platforms (Foundry Local, and others) can be deployed on non-AKS Kubernetes distributions connected via Azure Arc. Document divergences, workarounds, and recommendations for each platform.

## Reports

| Platform | Distribution | Status | Report |
|----------|-------------|--------|--------|
| Foundry Local | OpenShift 4.21 (Self-Hosted UPI) | ✅ Validated | [foundry-local-ocp/](foundry-local-ocp/) |

## Structure

```
arc-ai-inference-lab/
├── README.md
└── foundry-local-ocp/
    ├── README.md                    # Comparison of both install methods
    ├── arc-extension/               # Arc Extension install (recommended)
    │   ├── scripts/
    │   ├── env.sh.example
    │   └── README.md
    └── helm-standalone/             # Direct Helm chart install
        ├── scripts/
        ├── manifests/
        ├── env.sh.example
        ├── validation-report.md
        └── README.md
```

## Contributing

Each validation follows a consistent report format:
1. **Environment** — cluster details, versions, region
2. **Phase Results** — step-by-step outcome table
3. **Divergences** — numbered list of platform-specific issues (D1, D2, ...)
4. **Workarounds** — what was applied to make it work
5. **Recommendations** — suggestions back to the product team

## License

MIT
