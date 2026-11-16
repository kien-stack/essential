# kien/stack Essential

A free, open source GitOps platform for Kubernetes, installed in one command.
Everything lives in your Git repo and ArgoCD applies it.

**Included:** ArgoCD, Traefik (Gateway API), cert-manager, External Secrets + Infisical,
CloudNativePG with off-cluster backups (Barman Cloud plugin), health checks with alerts, Reloader,
metrics-server, OpenEBS. Optional: Cilium, external-dns.

## Try it

```bash
curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash
```

## Install

1. [Fork this repo](https://github.com/kien-stack/essential/fork).
2. Run the installer. It asks for your fork, domain and email:

```bash
curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash
```

Requirements: a Kubernetes cluster (2 vCPU, 8 GB RAM), `kubectl`, `helm`, `git`.

## Use it

| I want to | Do this, then `git push` |
|---|---|
| Change my settings | Edit `cluster.yaml` |
| Turn a component on | Uncomment it in `argocd/applications/platform/appset.yaml` |
| Turn a component off | Comment it out there, then `kubectl -n argocd delete application <component>` (its databases are kept) |
| Back up my databases | Set `global.backup.s3` in `cluster.yaml`, see [docs/BACKUP.md](docs/BACKUP.md) |
| Deploy my app | Copy an example from `examples/app-template/` to `helm/apps/<my-app>/` |
| Tune a component | Edit `helm/platform/<component>/values.yaml` |

Full docs: https://shop.kien.cc/docs

## License

Apache-2.0. Open source components keep their own licenses.
