#!/usr/bin/env bash
# Cut over the 9router systemd user service to a staged release directory.
#
#   scripts/cutover-release.sh <release-dir>     # explicit
#   scripts/cutover-release.sh                   # newest under ~/9router-releases
#
# Single-shot: preconditions -> backup unit -> atomic unit rewrite -> restart ->
# readiness -> application verification, with an auto-rollback trap. Downtime is only
# the restart + boot, because the release is expected to be fully staged already.
#
# Run DETACHED in tmux (the gateway being restarted is what serves the agent driving
# this), e.g.:
#   tmux new-session -d -s 9r -n cutover
#   tmux send-keys -t 9r:cutover "bash scripts/cutover-release.sh" Enter
set -euo pipefail

RELEASES_ROOT="$HOME/9router-releases"
unit="$HOME/.config/systemd/user/9router.service"
port=20128

release="${1:-}"
if [ -z "$release" ]; then
  release=$(ls -1dt "$RELEASES_ROOT"/*/ 2>/dev/null | head -1 | sed 's:/$::')
fi
[ -n "$release" ] && [ -d "$release" ] || { echo "FATAL: no release dir (given: '$release')"; exit 2; }

version=$(node -p "require('$release/package.json').version")
old_release=$(grep -m1 '^WorkingDirectory=' "$unit" | cut -d= -f2-)
stamp=$(date +%Y%m%d-%H%M%S)
backup_dir="$HOME/9router-backups/${stamp}-pre-v${version}"
log="$backup_dir/deploy.log"
mkdir -p "$backup_dir"
exec > >(tee -a "$log") 2>&1

printf 'START=%s\nRELEASE=%s\nVERSION=%s\nBACKUP=%s\nOLD_RELEASE=%s\n' \
  "$(date -Is)" "$release" "$version" "$backup_dir" "$old_release"

# ---- preconditions: the staged release must be complete and runnable here ----
[ "$release" != "$old_release" ] || { echo "FATAL: target equals currently running release"; exit 2; }
test -s "$release/custom-server.js" || { echo "FATAL: no custom-server.js"; exit 2; }
test -s "$release/.next/BUILD_ID" || { echo "FATAL: no BUILD_ID"; exit 2; }
test -s "$release/.next/standalone/custom-server.js" || { echo "FATAL: no standalone server"; exit 2; }
test -d "$release/.next/standalone/.next/static" || { echo "FATAL: standalone static missing"; exit 2; }
test -d "$release/.next/standalone/public" || { echo "FATAL: standalone public missing"; exit 2; }
test -d "$release/node_modules" || { echo "FATAL: no node_modules"; exit 2; }
test -d "$old_release" || { echo "FATAL: running release not a dir: $old_release"; exit 2; }

# arch guard: never cut over to a bundle that cannot execute on this host
x64=$(find "$release/node_modules" \( -name '*x64*.node' -o -name '*x86_64*.node' \) 2>/dev/null | wc -l)
arm=$(find "$release/node_modules" -name '*arm64*.node' 2>/dev/null | wc -l)
printf 'ARCH_GUARD host=%s arm64=%s x64=%s\n' "$(uname -m)" "$arm" "$x64"
[ "$x64" -eq 0 ] || { echo "FATAL: x86_64 native bindings present"; exit 2; }
if [ "$(uname -m)" = "aarch64" ]; then
  [ "$arm" -ge 4 ] || { echo "FATAL: too few arm64 bindings ($arm)"; exit 2; }
fi

cp -p -- "$unit" "$backup_dir/9router.service"
grep -m1 '^WorkingDirectory=' "$backup_dir/9router.service"

# ---- atomic unit rewrite: replace the whole old release path (covers both directives)
python3 - "$unit" "$old_release" "$release" <<'PY'
from pathlib import Path
import sys
p, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
s = p.read_text()
assert old in s, f"old release path not found in unit: {old}"
s = s.replace(old, new)
assert new in s and old not in s, "unit rewrite verification failed"
p.write_text(s)
print("unit rewritten ->", new)
PY

old_version=$(node -p "require('$old_release/package.json').version" 2>/dev/null || echo unknown)

rollback() {
  rc=$?
  printf 'FAIL rc=%s; ROLLING_BACK to %s (v%s)\n' "$rc" "$old_release" "$old_version"
  systemctl --user stop 9router.service || true
  cp -p -- "$backup_dir/9router.service" "$unit"
  systemctl --user daemon-reload
  systemctl --user start 9router.service || true
  for _ in $(seq 1 60); do
    curl -fsS --max-time 4 "http://127.0.0.1:${port}/api/version" 2>/dev/null | grep -q "\"currentVersion\":\"${old_version}\"" && break
    sleep 1
  done
  printf 'ROLLBACK_DONE version=%s\n' "$(curl -sS --max-time 5 "http://127.0.0.1:${port}/api/version" 2>/dev/null || echo UNREACHABLE)"
  exit "$rc"
}
trap rollback ERR

# ---- cutover ----
systemctl --user stop 9router.service
systemctl --user daemon-reload
systemctl --user start 9router.service

v=""
for _ in $(seq 1 90); do
  [ "$(systemctl --user is-active 9router.service || true)" = active ] || { sleep 1; continue; }
  v=$(curl -sS --max-time 5 "http://127.0.0.1:${port}/api/version" 2>/dev/null || true)
  printf '%s' "$v" | grep -q "\"currentVersion\":\"${version}\"" && break
  sleep 1
done
printf '%s' "$v" | grep -q "\"currentVersion\":\"${version}\"" || { echo "readiness FAILED; got: $v"; false; }

# ---- application-level verification ----
out="/tmp/9r-models-${version}.json"
code=$(curl -sS --max-time 15 -o "$out" -w '%{http_code}' "http://127.0.0.1:${port}/v1/models")
printf 'MODELS_HTTP=%s\n' "$code"
[ "$code" = "200" ] || false

printf 'DASHBOARD_HTTP=%s (307 expected)\n' \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${port}/dashboard")"

listener=$(ss -ltnp 2>/dev/null | grep -c ":${port}" || true)
printf 'LISTENER_%s=%s\n' "$port" "$listener"
[ "$listener" -ge 1 ] || false

python3 - "$out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ids = [m['id'] for m in d.get('data', [])]
print('TOTAL_MODELS=%d' % len(ids))
cb = sorted(i for i in ids if i.startswith('cbcn/'))
print('CBCN_MODELS=%d' % len(cb))
assert len(cb) >= 10, 'cbcn model count regressed'
assert any('deepseek-v4.1-flash' in i for i in ids), 'deepseek-v4.1-flash missing'
print('FORK_FEATURES_OK')
PY

trap - ERR
pid=$(systemctl --user show 9router.service -p MainPID --value)
printf 'CUTOVER_OK PID=%s PROC_CWD=%s VERSION=%s\n' "$pid" "$(readlink -f "/proc/$pid/cwd")" "$v"
printf 'DONE=%s\n' "$(date -Is)"
