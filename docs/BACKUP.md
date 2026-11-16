# Backups, alerts and restore

What keeps your data, and how to get it back. Everything below is in Git except the keys, which never are.

| Risk | What protects you |
|---|---|
| You turn a brick off, delete an app folder, or a merge drops an entry | The database is **kept** (see [FAQ, What protects the data](FAQ.md#what-protects-the-data)) |
| A volume claim or namespace is deleted | Database volumes use `openebs-hostpath-retain`: the files stay on disk |
| The node, its disk or the whole cluster is lost | **Off-cluster backups** of every Postgres to S3: restore to any point in time |
| Backups silently stop, the disk fills up, a certificate expires, the node dies | The **checks** brick alerts you, and an external heartbeat notices when it goes quiet |
| Infisical's encryption key is lost | The **recovery kit** keeps it, with the other keys a restore needs |

## 1. Turn on backups

You need an S3 bucket **outside this cluster** (AWS S3, Scaleway, OVH, Cloudflare R2, Backblaze B2, a MinIO on
another machine...) and a key that can read and write it. Use one path per cluster.

1. `cluster.yaml`:

   ```yaml
   global:
     backup:
       s3:
         destinationPath: s3://acme-backups/prod
         endpointURL: https://s3.fr-par.scw.cloud   # empty for AWS S3
         region: fr-par                             # if your provider needs it
   ```

2. Give the cluster the key, once. It is a plain Secret on purpose: Infisical cannot hold the key needed to
   restore Infisical. On a new install, pass it to the installer:

   ```bash
   BACKUP_S3_ACCESS_KEY_ID=... BACKUP_S3_SECRET_ACCESS_KEY=... ./install.sh install
   ```

   On a running cluster:

   ```bash
   kubectl -n external-secrets create secret generic backup-s3 \
     --from-literal=ACCESS_KEY_ID=... --from-literal=ACCESS_SECRET_KEY=...
   ```

3. Commit and push `cluster.yaml`. ArgoCD then gives every Postgres (the bricks' and your apps') continuous WAL
   archiving and a base backup every night at 02:00, kept 30 days (`retentionPolicy`). Each Postgres pod
   restarts once to get the backup sidecar (a few seconds of downtime for that app). The first base backup
   starts at once; if it races that restart and fails, the checks brick starts a new one within 15 minutes.

4. Check:

   ```bash
   ./install.sh doctor                       # "backups: s3://..." instead of BACKUPS OFF
   kubectl get backups -A                    # phase completed
   kubectl get cluster -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ARCHIVING:.status.conditions[?(@.type=="ContinuousArchiving")].status'
   ```

Files land under `s3://<bucket>/<path>/<namespace>/<cluster>/` (`base/` and `wals/`). One Postgres can opt out
with `cnpg-cluster.backup.enabled: false` in its values.

If the bucket is unreachable, Postgres keeps its WAL on the disk and archives it once the bucket is back (the
checks brick alerts you meanwhile: the disk fills up). Switching backups **off** and on again is different: the
WAL written while they were off is never archived, so a restore cannot go past that gap. A new base backup
starts as soon as backups are back on, and restores from then on are complete again.

Not covered here: volumes that are not Postgres (your apps' own PVCs). Keep files in a database or in S3.

## 2. Alerts

The `checks` brick runs every 15 minutes and looks at every Postgres (healthy, WAL archiving, age of the last
base backup), the free space of the disk that holds the volumes, and the TLS certificates (expiring in less
than 14 days). Thresholds: `helm/platform/checks/values.yaml`, override them under `checks:` in `cluster.yaml`.

- `CHECKS_WEBHOOK_URL`: a Slack, Mattermost, Google Chat or Discord incoming webhook. It gets the list of
  problems when it changes, again every 6 hours while it lasts, and a "resolved" message.
- `CHECKS_HEARTBEAT_URL`: a dead man's switch (healthchecks.io, Uptime Kuma "push", Better Stack heartbeat). The
  checks call it only when everything is OK. Set the service to expect a call every 15 minutes (plus a grace
  period): it alerts you when a problem appears **and** when the whole node is down, which nothing inside the
  cluster can report.

```bash
CHECKS_WEBHOOK_URL=https://hooks.slack.com/services/... CHECKS_HEARTBEAT_URL=https://hc-ping.com/<uuid> ./install.sh install
# or on a running cluster:
kubectl -n checks create secret generic checks-notify \
  --from-literal=WEBHOOK_URL=https://hooks.slack.com/services/... --from-literal=HEARTBEAT_URL=https://hc-ping.com/<uuid>
# run it now and read the result
kubectl -n checks create job --from=cronjob/checks checks-now && kubectl -n checks logs -f job/checks-now
```

## 3. Recovery kit

A restore needs keys that are neither in Git nor in the backups: the S3 key, Infisical's `ENCRYPTION_KEY`
(without it a restored Infisical database is unreadable), the Git and External Secrets credentials, the DNS
tokens. Save them once backups are on, and again when one of them changes:

```bash
./install.sh recovery-kit            # writes ~/kien-stack-recovery-kit-<date>.yaml (mode 600)
```

Keep that file **outside the cluster** (a password manager, an encrypted USB key), then delete it from your
machine. It is a list of Kubernetes Secrets: `kubectl apply -f` restores them.

## 4. Restore

### A brick or an app was removed

Its Postgres is still there (`kubectl get cluster -A`). Put the brick back in
`argocd/applications/platform/appset.yaml` (or the folder back in `helm/apps/`) and push: it reconnects to the
same database. To delete the database for good, see the [FAQ](FAQ.md#what-protects-the-data).

### Get data back from a point in time (a table dropped by mistake)

Start a second Postgres from the backups, next to the live one, stopped just before the mistake, then copy what
you need. Example for Infisical (`infisical` namespace, cluster `infisical-cluster`):

```bash
kubectl apply -n infisical -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: infisical-pitr
spec:
  instances: 1
  storage: {size: 5Gi, storageClass: openebs-hostpath}
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "2026-11-16T10:00:00Z"   # UTC, just before the mistake
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: infisical-cluster-backup   # the live cluster's ObjectStore
          serverName: infisical-cluster
YAML
kubectl -n infisical wait cluster/infisical-pitr --for=condition=Ready --timeout=15m
kubectl -n infisical exec infisical-pitr-1 -c postgres -- pg_dump -d infisical -t <table> > table.sql
kubectl -n infisical delete cluster infisical-pitr
```

### The whole cluster is lost (disaster recovery)

On a new cluster, every Postgres starts from the last backups of the old one, then archives to a new path.

1. In your repo, `cluster.yaml`: point `restore.from` at the old path and give the cluster a new one. Commit, push.

   ```yaml
   global:
     backup:
       s3:
         destinationPath: s3://acme-backups/prod-2    # new: never archive over the backups you restore from
       restore:
         from: s3://acme-backups/prod                 # the lost cluster's destinationPath
   ```

2. Restore the keys **before** installing, then install as usual (same domain, or update `global.domain` first).
   In restore mode the encryption keys are not generated: they come from the kit, and `./install.sh doctor`
   refuses to go on without them.

   ```bash
   kubectl apply -f kien-stack-recovery-kit-<date>.yaml
   ./install.sh install            # GIT_USERNAME/GIT_TOKEN if your repo is private (they are in the kit)
   ```

3. Wait until every Postgres is back (`kubectl get cluster -A`: "Cluster in healthy state"), check your apps,
   then remove `restore:` from `cluster.yaml` and push. Run `./install.sh recovery-kit` again.

To stop at a point in time instead of the end of the archived WAL, add `targetTime: "<RFC 3339 UTC>"` under
`restore:`.

## Upgrading an existing install

- Merging this version restarts nothing by itself. When you set `global.backup`, each Postgres pod restarts
  once (backup sidecar).
- Postgres volumes created before keep `reclaimPolicy: Delete`. `./install.sh doctor` lists them with the
  command that switches them to `Retain`.
- A brick you removed from the platform list now keeps running: delete its Application yourself
  (`./install.sh doctor` lists them).
- `infisical-secrets` (Infisical's encryption key) was owned by its ExternalSecret: `./install.sh doctor` gives the
  command that detaches it, so it can never be deleted with it.
