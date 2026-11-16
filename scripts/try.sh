#!/usr/bin/env bash
# kien/stack Essential TRY: a disposable demo on your current cluster, zero questions.
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash -s uninstall
# Uses the public repo on main (ArgoCD follows main; pin a release with KSTACK_REF=vX.Y.Z),
# <node-ip>.sslip.io and self-signed certs. For real use: https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh
# Overrides: KSTACK_IP, KSTACK_REF. Requires kubectl, helm, git (yq is fetched if missing).
set -euo pipefail
REPO=${KSTACK_SOURCE:-https://github.com/kien-stack/essential}
REF=${KSTACK_REF:-main}
DIR=${KSTACK_DIR:-$HOME/kien-stack-try}
log() { printf '\033[1;35m[kien/stack]\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ask() { # ask VAR "question" default
  local v=${!1:-}; if [ -n "$v" ] || [ -n "${KSTACK_YES:-}" ] || [ ! -r /dev/tty ]; then printf -v "$1" %s "${v:-$3}"; return; fi
  read -r -p "  $2 [${3:-none}]: " v </dev/tty || true; printf -v "$1" %s "${v:-$3}"
}

for b in kubectl helm git; do command -v "$b" >/dev/null || die "$b is required (https://helm.sh/docs/intro/install, https://kubernetes.io/docs/tasks/tools)"; done
if ! command -v yq >/dev/null; then
  mkdir -p "$DIR/.bin"; export PATH="$DIR/.bin:$PATH"
  if ! [ -x "$DIR/.bin/yq" ]; then
    os=$(uname -s | tr A-Z a-z); arch=$(uname -m); case $arch in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
    log "fetching yq ($os/$arch)"; curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${arch}" -o "$DIR/.bin/yq"; chmod +x "$DIR/.bin/yq"
  fi
fi
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "no reachable cluster in the current kubectl context.
  No Kubernetes? k3s in one minute (kien/stack brings its own Traefik, metrics-server and storage):
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"--disable traefik --disable metrics-server --disable local-storage\" sh -"

if [ -d "$DIR/src/.git" ]; then git -C "$DIR/src" fetch -q origin "$REF" && git -C "$DIR/src" checkout -q FETCH_HEAD
else mkdir -p "$DIR"; git -c advice.detachedHead=false clone -q --depth 1 -b "$REF" "$REPO" "$DIR/src"; fi
cd "$DIR/src"

if [ "${1:-}" = uninstall ]; then
  # Deterministic, does not depend on ArgoCD pruning (ArgoCD manages itself and can take itself down first):
  # orphan every Application, remove ArgoCD, then delete the demo namespaces and the cluster-wide
  # objects of each release (webhooks left behind would break the API server for those kinds).
  log "removing the platform (ArgoCD, the demo namespaces and their cluster-wide objects)"
  rel=$(yq -r '.spec.generators[0].list.elements[].app' argocd/applications/platform/appset.yaml)
  ns=$(yq -r '.spec.generators[0].list.elements[].namespace' argocd/applications/platform/appset.yaml | grep -vx kube-system | sort -u)
  for d in helm/apps/*/; do [ -d "$d" ] && { ns="$ns $(basename "$d")"; rel="$rel $(basename "$d")"; }; done
  kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0 >/dev/null 2>&1 || true
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null 2>&1 || true
  for a in $(kubectl -n argocd get applications,applicationsets,appprojects -o name 2>/dev/null); do
    kubectl -n argocd patch "$a" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  kubectl -n argocd delete applications,applicationsets,appprojects --all --wait=false >/dev/null 2>&1 || true
  helm uninstall argocd -n argocd --wait >/dev/null 2>&1 || true
  for r in $rel; do
    kubectl delete validatingwebhookconfigurations,mutatingwebhookconfigurations,apiservices,clusterrolebindings,clusterroles \
      -l app.kubernetes.io/instance="$r" --ignore-not-found >/dev/null 2>&1 || true
  done
  # Workloads first, while the operators (CloudNativePG, External Secrets, cert-manager, OpenEBS) still run
  # and can clear the finalizers of their own resources; then the operators.
  ops="cert-manager cnpg-system external-secrets openebs"
  first=$(for n in $ns; do case " $ops " in *" $n "*) ;; *) echo "$n" ;; esac; done)
  # Demo data: volumes of openebs-hostpath-retain (databases) would stay on disk; let the provisioner delete them
  for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.spec.persistentVolumeReclaimPolicy=="Retain")]}{.metadata.name}={.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null); do
    case " $(echo $ns) " in *" ${pv#*=} "*) kubectl patch pv "${pv%%=*}" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null 2>&1 || true ;; esac
  done
  log "deleting namespaces: $(echo $first)"
  kubectl delete ns $first --ignore-not-found --wait=true --timeout=90s 2>/dev/null || true
  log "deleting operators: $ops"
  kubectl delete ns $ops --ignore-not-found --wait=true --timeout=90s 2>/dev/null || true
  # Anything still stuck on a finalizer (operator already gone): clear it
  for n in $ns; do
    kubectl get ns "$n" >/dev/null 2>&1 || continue
    for r in $(kubectl api-resources --namespaced --verbs=list -o name 2>/dev/null); do
      for o in $(kubectl -n "$n" get "$r" -o name 2>/dev/null); do
        kubectl -n "$n" patch "$o" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      done
    done
  done
  kubectl delete ns $ns --ignore-not-found --wait=true --timeout=2m >/dev/null 2>&1 || log "some namespaces are still terminating: kubectl get ns"
  log "done (CRDs and StorageClasses are kept)"; exit 0
fi

ip=${KSTACK_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}
dom=$ip.sslip.io
log "demo on context $(kubectl config current-context), https://*.$dom, release $REF"
# A demo has no fork: ArgoCD reads OUR public repo at $REF (its cluster.yaml says example.com).
# So, and ONLY in this demo, the root Application pins $REF and overrides global.domain.
# A real install has none of this: https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh writes your settings into your fork.
D="$dom" yq -i '.global.domain = strenv(D)' cluster.yaml
# k3s & co already run a metrics-server: do not deploy ours
if [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]; then
  yq -i 'del(.spec.generators[0].list.elements[] | select(.app == "metrics-server"))' argocd/applications/platform/appset.yaml
fi
D="$dom" V="$REF" EL="$(yq -o=json -I=0 '.spec.generators[0].list.elements' argocd/applications/platform/appset.yaml)" yq -i '.spec.source.targetRevision = strenv(V) |
  .spec.source.kustomize.patches = [
    {"target": {"kind": "ApplicationSet"}, "patch": ([
      {"op": "replace", "path": "/spec/template/spec/source/targetRevision", "value": strenv(V)},
      {"op": "add", "path": "/spec/template/spec/source/helm/valuesObject", "value": {"global": {"domain": strenv(D)}}}] | to_json)},
    {"target": {"kind": "ApplicationSet", "name": "apps"}, "patch": ([
      {"op": "replace", "path": "/spec/generators/0/git/revision", "value": strenv(V)}] | to_json)},
    {"target": {"kind": "ApplicationSet", "name": "platform"}, "patch": ([
      {"op": "replace", "path": "/spec/generators/0/list/elements", "value": (strenv(EL) | from_json)}] | to_json)}]' argocd/app-of-apps.yaml

KSTACK_DEMO=1 bash install.sh install
cat <<TXT

  This is a demo: it tracks the public release $REF, self-signed certs, no customisation.
  minikube/kind: run 'minikube tunnel' if the URLs above do not answer.

  Real install (your domain, Let's Encrypt, your own GitOps repo):
    curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash
  Private AI, monitoring, SSO, rollouts: https://shop.kien.cc
  Remove: curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash -s uninstall
TXT
