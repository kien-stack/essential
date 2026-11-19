#!/usr/bin/env bash
# Nightly install-and-upgrade test, used by .github/workflows/nightly.yaml (same file in every pack repo).
# It installs the pack the way a customer does: settings committed and pushed to the branch ArgoCD
# follows, then ./install.sh install. The workflow runs it from a copy outside the checkout, because the
# upgrade job checks out an older release that does not have this file.
#   e2e.sh setup                 check the runner size, install yq + k3s, start the usage sampler
#   e2e.sh previous              the release to upgrade from: latest v* tag that is not this commit
#   e2e.sh configure <branch>    commit the CI settings on <branch> (domain, repo/branch, profile), push it
#   e2e.sh wait <minutes> <sha>  every ArgoCD Application Synced + Healthy at <sha> for 60 s, else fail
#   e2e.sh diagnose              unhealthy apps: conditions, resources, pods, events, logs
#   e2e.sh mark <phase>          timestamp a phase for the report (install, healthy, upgrade...)
#   e2e.sh report <title>        requests and peak usage per namespace: job summary + $OUT/report.*
#   e2e.sh cleanup               delete the pushed branch, stop the sampler
# Env: OUT (output dir), PROFILE (full | light: .github/nightly/profile-<name>.yaml), K3S_VERSION,
# K3S_EXEC, YQ_VERSION, MIN_CPU / MIN_MEM_GB (runner size check, SKIP_SIZE_CHECK=true to bypass),
# FREE_DISK=true, GITHUB_TOKEN (push/delete the branch), SAMPLE_EVERY (seconds, default 15).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-${RUNNER_TEMP:-$PWD}/nightly-out}
mkdir -p "$OUT"
log() { printf '\033[1;36m[nightly]\033[0m %s\n' "$*"; }
die() { printf '::error::%s\n' "$*"; exit 1; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat; fi; }

# ------------------------------------------------------------------ setup
setup() {
  local cpu mem
  cpu=$(nproc); mem=$(awk '/^MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
  log "runner: $cpu vCPU, $mem GiB RAM, $(df -h --output=avail / | tail -1 | tr -d ' ') free on /"
  if [ "${SKIP_SIZE_CHECK:-false}" != true ] && { [ "$cpu" -lt "${MIN_CPU:-0}" ] || awk -v m="$mem" -v n="${MIN_MEM_GB:-0}" 'BEGIN{exit !(m < n - 1)}'; }; then
    printf '### Runner too small\n\n%s vCPU / %s GiB, profile `%s` needs %s vCPU / %s GB. Set the repository variable `NIGHTLY_RUNS_ON` to a larger runner (see docs/CI.md), or run it by hand with `skip_size_check`.\n' \
      "$cpu" "$mem" "${PROFILE:-full}" "${MIN_CPU:-0}" "${MIN_MEM_GB:-0}" | summary
    die "runner too small for this pack: $cpu vCPU / $mem GiB < ${MIN_CPU:-0} vCPU / ${MIN_MEM_GB:-0} GB"
  fi
  if [ "${FREE_DISK:-false}" = true ]; then
    # Images of the AI packs need ~30 GB: drop the preinstalled SDKs we never use
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL
    sudo docker image prune -af >/dev/null 2>&1 || true
    log "free on / after cleanup: $(df -h --output=avail / | tail -1 | tr -d ' ')"
  fi
  sudo curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION:?}/yq_linux_amd64" -o /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq

  log "k3s ${K3S_VERSION:?} (${K3S_EXEC:-})"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="${K3S_EXEC:-} --write-kubeconfig-mode=644" sh - >/dev/null
  sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl   # kubectl = the server version
  mkdir -p "$HOME/.kube"; cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; chmod 600 "$HOME/.kube/config"
  local i
  for i in $(seq 60); do kubectl get nodes >/dev/null 2>&1 && break; sleep 2; done
  kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
  # k3s adds its own metrics-server a few seconds after the node is Ready: wait for it, so configure
  # sees it (the pack's brick is dropped, as on a customer k3s) and kubectl top works from the start
  case " ${K3S_EXEC:-} " in
    *metrics-server*) ;;
    *) for i in $(seq 90); do kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1 && break; sleep 2; done
       kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s >/dev/null ;;
  esac
  log "node ready: $(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'), allocatable $(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu} CPU, {.items[0].status.allocatable.memory}')"
  printf '%s\t%s\t%s\n' "$cpu" "$mem" "$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')" >"$OUT/runner.tsv"

  nohup "$HERE/e2e.sh" sample >"$OUT/sampler.log" 2>&1 &
  echo $! >"$OUT/sampler.pid"
  mark k3s
}

# Usage samples every SAMPLE_EVERY seconds (metrics-server: k3s's own until the pack's takes over)
sample() {
  local t
  while :; do
    t=$(date +%s)
    kubectl top pods -A --no-headers 2>/dev/null \
      | awk -v t="$t" '{c=$3; m=$4; sub(/m$/, "", c); sub(/Mi$/, "", m); print t "\t" $1 "\t" $2 "\t" c "\t" m}' >>"$OUT/top-pods.tsv" || true
    kubectl top nodes --no-headers 2>/dev/null \
      | awk -v t="$t" '{c=$2; m=$4; sub(/m$/, "", c); sub(/Mi$/, "", m); print t "\t" c "\t" m}' >>"$OUT/top-node.tsv" || true
    awk -v t="$t" '/^MemTotal/{tot=$2} /^MemAvailable/{av=$2} END{printf "%s\t%d\t%d\n", t, (tot-av)/1024, tot/1024}' /proc/meminfo >>"$OUT/host-mem.tsv"
    sleep "${SAMPLE_EVERY:-15}"
  done
}

mark() { printf '%s\t%s\n' "$(date +%s)" "$1" >>"$OUT/phases.tsv"; }

previous() {
  local head t; head=$(git rev-parse HEAD)
  for t in $(git tag --merged HEAD --sort=-v:refname --list 'v[0-9]*'); do
    [ "$(git rev-list -n1 "$t")" = "$head" ] || { echo "$t"; return 0; }
  done
  die "no release tag before $head"
}

# ------------------------------------------------------------------ configure
# What a customer commits before ./install.sh (scripts/install.sh in essential, setup() in install.sh of
# the paid packs): domain <node-ip>.sslip.io with self-signed certs, ArgoCD following this repo on
# <branch>. Plus the profile. Then commit and push: ArgoCD only reads Git.
brick_off() {
  local f=argocd/applications/platform/appset.yaml
  if yq -e '.spec.generators[0] | has("list")' "$f" >/dev/null 2>&1; then
    A="$1" yq -i 'del(.spec.generators[0].list.elements[] | select(.app == strenv(A)))' "$f"
  else   # releases with a git directory generator: exclude the folder
    A="helm/platform/$1" yq -i '.spec.generators[0].git.directories += [{"path": strenv(A), "exclude": true}]' "$f"
  fi
}

configure() {
  local branch=${1:?branch} repo ip dom f
  repo="https://github.com/${GITHUB_REPOSITORY:?}.git"
  ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  dom="$ip.sslip.io"
  git switch -q -C "$branch"
  D="$dom" E="admin@$dom" yq -i '.global.domain = strenv(D) | .global.tls.issuer = "selfsigned" |
    .global.issuer = "selfsigned-ca" | .global.tls.email = strenv(E)' cluster.yaml
  if [ -d helm/platform/langfuse ]; then U="https://langfuse.$dom" yq -i '.langfuse.langfuse.nextauth.url = strenv(U)' cluster.yaml; fi
  R="$repo" B="$branch" yq -i '.spec.source.repoURL = strenv(R) | .spec.source.targetRevision = strenv(B)' argocd/app-of-apps.yaml
  for f in argocd/applications/*/appset.yaml; do
    R="$repo" B="$branch" yq -i '(.spec.generators[0] | select(has("git")) | .git) |= (.repoURL = strenv(R) | .revision = strenv(B)) |
      .spec.template.spec.source.repoURL = strenv(R) | .spec.template.spec.source.targetRevision = strenv(B)' "$f"
  done
  # k3s runs its own metrics-server: drop the brick, as scripts/install.sh does
  if [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]; then
    brick_off metrics-server
  fi

  local p="$HERE/profile-${PROFILE:-full}.yaml" b n i x
  if [ "${PROFILE:-full}" != full ]; then
    [ -f "$p" ] || die "unknown profile ${PROFILE}: no $p"
    log "profile ${PROFILE}: bricks off: $(yq -r '.bricksOff // [] | join(" ")' "$p")"
    for b in $(yq -r '.bricksOff // [] | .[]' "$p"); do brick_off "$b"; done
    if [ "$(yq -r '.values // {} | length' "$p")" -gt 0 ]; then P="$p" yq -i '. *= (load(strenv(P)) | .values)' cluster.yaml; fi
    n=$(yq -r '.edits // [] | length' "$p")
    for ((i = 0; i < n; i++)); do
      f=$(yq -r ".edits[$i].file" "$p"); x=$(yq -r ".edits[$i].expr" "$p")
      if [ -f "$f" ]; then yq -i "$x" "$f"; fi
    done
  fi

  git add cluster.yaml argocd helm
  git -c user.name=kien-stack-nightly -c user.email=nightly@kien-stack.invalid -c commit.gpgsign=false \
    commit -qm "ci(nightly): CI settings (domain $dom, profile ${PROFILE:-full})"
  git --no-pager show --stat --format='%h %s' HEAD | sed 's/^/  /'
  gitauth push -q --force origin "HEAD:refs/heads/$branch"
  echo "$branch" >"$OUT/branch"
  log "pushed $branch at $(git rev-parse --short HEAD): ArgoCD follows it"
}

gitauth() {
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GITHUB_TOKEN:?}" | base64 | tr -d '\n')" "$@"
}

cleanup() {
  if [ -f "$OUT/sampler.pid" ]; then kill "$(cat "$OUT/sampler.pid")" 2>/dev/null || true; fi
  if [ -f "$OUT/branch" ]; then gitauth push -q origin --delete "$(cat "$OUT/branch")" || true; fi
}

# ------------------------------------------------------------------ wait / diagnose
apps_json() { kubectl -n argocd get applications -o json 2>/dev/null || echo '{"items": []}'; }

# Applications not Synced + Healthy (or not yet at <sha>, or still syncing): name sync health revision
not_ready() {
  apps_json | jq -r --arg rev "${1:-}" '.items[]
    | select(.status.sync.status != "Synced" or .status.health.status != "Healthy"
        or (.status.operationState.phase // "Succeeded") == "Running"
        or ($rev != "" and (.status.sync.revision // "") != $rev))
    | [.metadata.name, (.status.sync.status // "-"), (.status.health.status // "-"), ((.status.sync.revision // "-")[0:7])] | @tsv'
}

wait_apps() {
  local minutes=${1:?minutes} rev=${2:-} deadline ok_since=0 bad last="" n
  deadline=$((SECONDS + minutes * 60))
  log "waiting up to $minutes min for every Application Synced + Healthy${rev:+ at ${rev:0:7}}"
  while :; do
    bad=$(not_ready "$rev"); n=$(apps_json | jq '.items | length')
    if [ -z "$bad" ] && [ "$n" -gt 0 ]; then
      # Healthy for 60 s in a row: a later sync wave can still turn an app Progressing
      if [ "$ok_since" -eq 0 ]; then ok_since=$SECONDS; elif [ $((SECONDS - ok_since)) -ge 60 ]; then break; fi
    else ok_since=0; fi
    if [ "$bad" != "$last" ]; then
      if [ -n "$bad" ]; then printf '  %s not ready:\n' "$(wc -l <<<"$bad" | tr -d ' ')"; column -t <<<"$bad" | sed 's/^/    /'; fi
      last=$bad
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf '::error::not Synced + Healthy after %s min: %s\n' "$minutes" "$(cut -f1 <<<"$bad" | tr '\n' ' ')"
      return 1
    fi
    sleep 10
  done
  log "all $n Applications Synced + Healthy${rev:+ at ${rev:0:7}}"
}

# Every app that is not Synced + Healthy: its conditions and unhealthy resources, then the pods, events and
# logs of its namespace. Printed in collapsible groups and saved in $OUT/diag.
diagnose() {
  local d="$OUT/diag" a ns p bad
  mkdir -p "$d"
  {
    echo "### Nodes"; kubectl get nodes -o wide; kubectl describe nodes | sed -n '/^Conditions:/,/^Events:/p'
    echo; echo "### Applications"; kubectl -n argocd get applications -o wide
    echo; echo "### Pods not ready"; not_ready_pods
    echo; echo "### Runner"; df -h /; free -m
  } >"$d/cluster.txt" 2>&1 || true
  echo "::group::cluster"; cat "$d/cluster.txt"; echo "::endgroup::"
  bad=$(not_ready "" | cut -f1)
  {
    printf '### Not Synced + Healthy\n\n| Application | Sync | Health | Message |\n|---|---|---|---|\n'
    apps_json | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
      | "| \(.metadata.name) | \(.status.sync.status // "-") | \(.status.health.status // "-") | \(
          ([.status.conditions[]?.message] + [.status.operationState.message // empty]
           + [.status.resources[]? | select((.health.status // "Healthy") != "Healthy") | "\(.kind)/\(.name): \(.health.message // .health.status)"])
          | map(gsub("[\\n|]"; " ") | .[0:200]) | .[0:3] | join("<br>"))) |"'
  } | summary
  for a in $bad; do
    ns=$(kubectl -n argocd get application "$a" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)
    {
      echo "### Application $a"
      kubectl -n argocd get application "$a" -o json | jq '{sync: .status.sync, health: .status.health,
        conditions: .status.conditions, operation: (.status.operationState // {} | {phase, message,
          failed: [.syncResult.resources[]? | select(.status != "Synced")]}),
        resources: [.status.resources[]? | select(.status != "Synced" or (.health.status // "Healthy") != "Healthy")]}'
      if [ -n "$ns" ]; then
        echo; echo "### Pods in $ns"; kubectl -n "$ns" get pods -o wide
        echo; echo "### Events in $ns"; kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -40
        for p in $(not_ready_pods "$ns" | awk 'NR>1{print $2}'); do
          echo; echo "### describe $ns/$p"; kubectl -n "$ns" describe pod "$p" | sed -n '/^Init Containers:\|^Containers:/,$p' | tail -80
          echo; echo "### logs $ns/$p"; kubectl -n "$ns" logs "$p" --all-containers --prefix --tail=80 2>&1 || true
          kubectl -n "$ns" logs "$p" --all-containers --prefix --previous --tail=40 2>/dev/null | sed 's/^/(previous) /' || true
        done
      fi
    } >"$d/app-$a.txt" 2>&1 || true
    echo "::group::$a"; cat "$d/app-$a.txt"; echo "::endgroup::"
  done
}

# Pods that are not Succeeded and not Running with every container ready: namespace name phase ready
not_ready_pods() {
  local scope=(-A); if [ -n "${1:-}" ]; then scope=(-n "$1"); fi
  { echo "NAMESPACE NAME PHASE READY"
    kubectl get pods "${scope[@]}" -o json | jq -r '.items[] | select(.status.phase != "Succeeded")
      | select(.status.phase != "Running" or ([.status.containerStatuses[]?.ready] | all | not))
      | [.metadata.namespace, .metadata.name, .status.phase,
         "\([.status.containerStatuses[]? | select(.ready)] | length)/\(.spec.containers | length)"] | @tsv'
  } | column -t
}

# ------------------------------------------------------------------ report
# Requests: the pods running or pending now (containers + native sidecars). Peak: highest sum over one
# sample (kubectl top, every SAMPLE_EVERY s) per namespace and for all pods. Idle: average after the last
# "healthy" mark. Node: kubectl top node (pods + k3s + system). Host: MemTotal - MemAvailable.
report() {
  local title=${1:-Report} healthy=0 req="$OUT/requests.tsv"
  touch "$OUT/top-pods.tsv" "$OUT/top-node.tsv" "$OUT/host-mem.tsv" "$OUT/phases.tsv"
  healthy=$(awk '$2 ~ /healthy$/ {t=$1} END{print t+0}' "$OUT/phases.tsv")
  kubectl get pods -A -o json 2>/dev/null | jq -r '
    def cpu: if . == null then 0 elif endswith("m") then (.[:-1] | tonumber) else (tonumber * 1000) end;
    def mem: if . == null then 0 else (capture("^(?<n>[0-9.eE+]+)(?<u>[a-zA-Z]*)$") as $c
      | ($c.n | tonumber) * ({"": 1, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "Ki": 1024,
          "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776}[$c.u] // 1) / 1048576) end;
    [.items[] | select(.status.phase == "Running" or .status.phase == "Pending")
      | {ns: .metadata.namespace,
         c: ([.spec.containers[], (.spec.initContainers[]? | select(.restartPolicy == "Always"))] | map(.resources.requests.cpu | cpu) | add // 0),
         m: ([.spec.containers[], (.spec.initContainers[]? | select(.restartPolicy == "Always"))] | map(.resources.requests.memory | mem) | add // 0)}]
    | group_by(.ns)[] | [.[0].ns, length, (map(.c) | add | round), (map(.m) | add | round)] | @tsv' >"$req" || : >"$req"

  awk -F'\t' -v healthy="$healthy" -v title="$title" -v runner="$(cat "$OUT/runner.tsv" 2>/dev/null)" \
      -v every="${SAMPLE_EVERY:-15}" -v json="$OUT/report.json" '
    function cores(m) { return sprintf("%.2f", m / 1000) }
    function gib(mi)  { return sprintf("%.1f Gi", mi / 1024) }
    function mib(mi)  { return sprintf("%d Mi", mi) }
    FILENAME ~ /requests.tsv$/ { ns[$1] = 1; pods[$1] = $2; rc[$1] = $3; rm[$1] = $4; next }
    FILENAME ~ /top-pods.tsv$/ {
      ns[$2] = 1; sc[$1 SUBSEP $2] += $4; sm[$1 SUBSEP $2] += $5; tc[$1] += $4; tm[$1] += $5; ts[$1] = 1; next }
    FILENAME ~ /top-node.tsv$/ { if ($2 > nc) nc = $2; if ($3 > nm) nm = $3; next }
    FILENAME ~ /host-mem.tsv$/ { if ($2 > hm) hm = $2; ht = $3; next }
    FILENAME ~ /phases.tsv$/   { np++; pt[np] = $1; pn[np] = $2; next }
    END {
      n = 0
      for (t in ts) {
        n++; idle = (healthy > 0 && t + 0 >= healthy)
        if (tc[t] > ptc) ptc = tc[t]; if (tm[t] > ptm) ptm = tm[t]
        if (idle) { ni++; itc += tc[t]; itm += tm[t] }
        for (s in ns) {
          if (sc[t, s] > pc[s]) pc[s] = sc[t, s]; if (sm[t, s] > pm[s]) pm[s] = sm[t, s]
          if (idle) { ic[s] += sc[t, s]; im[s] += sm[t, s] }
        }
      }
      split(runner, r, "\t")
      printf "### %s\n\n", title
      printf "Runner %s vCPU / %s GiB, k3s %s. %d samples every %ss, %d of them idle (after the last ready mark).\n\n", r[1], r[2], r[3], n, every, ni
      printf "Timeline, minutes after k3s:"
      for (i = 1; i <= np; i++) printf "%s %s %.1f", (i > 1 ? "," : ""), pn[i], (pt[i] - pt[1]) / 60
      printf "\n\n"
      print "| Namespace | Pods | CPU requests | Memory requests | Peak CPU | Peak memory | Idle CPU | Idle memory |"
      print "|---|--:|--:|--:|--:|--:|--:|--:|"
      cmd = "sort"; fflush()
      for (s in ns) {
        printf "| %s | %d | %s | %s | %s | %s | %s | %s |\n", s, pods[s], cores(rc[s]), mib(rm[s]), cores(pc[s]), mib(pm[s]),
          (ni ? cores(ic[s] / ni) : "-"), (ni ? mib(im[s] / ni) : "-") | cmd
        trc += rc[s]; trm += rm[s]; tp += pods[s]
      }
      close(cmd); fflush()
      printf "| **All pods** | %d | **%s** | **%s** | **%s** | **%s** | %s | %s |\n", tp, cores(trc), gib(trm), cores(ptc), gib(ptm),
        (ni ? cores(itc / ni) : "-"), (ni ? gib(itm / ni) : "-")
      printf "| Node (pods + k3s + system, kubectl top node) | | | | %s | %s | | |\n", cores(nc), gib(nm)
      printf "| Runner memory used (MemTotal - MemAvailable) | | | | | %s of %s | | |\n\n", gib(hm), gib(ht)
      printf "{\"title\": \"%s\", \"runner\": {\"cpu\": %d, \"memGiB\": %s, \"k3s\": \"%s\"}, \"samples\": %d, \"idleSamples\": %d,", title, r[1], r[2] + 0, r[3], n, ni > json
      printf " \"total\": {\"pods\": %d, \"requestsCpu\": %s, \"requestsMemMi\": %d, \"peakCpu\": %s, \"peakMemMi\": %d, \"idleCpu\": %s, \"idleMemMi\": %d, \"nodePeakCpu\": %s, \"nodePeakMemMi\": %d, \"hostPeakMemMi\": %d},", tp, cores(trc), trm, cores(ptc), ptm, (ni ? cores(itc / ni) : 0), (ni ? itm / ni : 0), cores(nc), nm, hm > json
      printf " \"namespaces\": {" > json
      sep = ""
      for (s in ns) { printf "%s\"%s\": {\"pods\": %d, \"requestsCpu\": %s, \"requestsMemMi\": %d, \"peakCpu\": %s, \"peakMemMi\": %d}", sep, s, pods[s], cores(rc[s]), rm[s], cores(pc[s]), pm[s] > json; sep = ", " }
      printf "}}\n" > json
    }' "$req" "$OUT/top-pods.tsv" "$OUT/top-node.tsv" "$OUT/host-mem.tsv" "$OUT/phases.tsv" >"$OUT/report.md"
  summary <"$OUT/report.md"
  cat "$OUT/report.md"
}

cmd=${1:-}; shift || true
case "$cmd" in
  setup) setup ;;
  sample) sample ;;
  previous) previous ;;
  configure) configure "$@" ;;
  wait) wait_apps "$@" ;;
  diagnose) diagnose ;;
  mark) mark "$@" ;;
  report) report "$@" ;;
  cleanup) cleanup ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
