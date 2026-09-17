#!/usr/bin/env bash
# Live driver: exercises bin/fm-contributions.sh and bin/fm-bearings-snapshot.sh
# the way the fleet runs them. Only the GitHub endpoint is substituted.
set -u
ROOT_UNDER_TEST=${1:?root}
PRELUDE=$(mktemp "${TMPDIR:-/tmp}/fm-prelude.XXXXXX")
LINE=$(grep -n '^failures=0$' "$ROOT_UNDER_TEST/tests/fm-contributions.test.sh" | cut -d: -f1)
head -n $((LINE-1)) "$ROOT_UNDER_TEST/tests/fm-contributions.test.sh" \
  | sed 's|\$(dirname "\${BASH_SOURCE\[0\]}")|'"$ROOT_UNDER_TEST/tests"'|' > "$PRELUDE"
# shellcheck disable=SC1090
. "$PRELUDE"
fail() { printf '   FAIL: %s\n' "$1"; DRIVE_FAILED=1; }
pass() { printf '   %s\n' "$1"; }
DRIVE_FAILED=0
ok()  { printf '   [ok]   %s\n' "$1"; }
bad() { printf '   [FAIL] %s\n' "$1"; DRIVE_FAILED=1; }
hdr() { printf '\n=== %s ===\n' "$1"; }
bearings_at() { # home now
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT_UNDER_TEST" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_BEARINGS_NOW="$2" "$ROOT_UNDER_TEST/bin/fm-bearings-snapshot.sh" --json
}
poll_at() { # home now [env...]
  local home=$1 now=$2; shift 2
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$now" "$@" "$ROOT_UNDER_TEST/bin/fm-contributions.sh" poll
}

################################################################
hdr 'SC1/SC2  poll budget runs out mid-sweep'
home=$(new_home sc1)
forge_home "$home"                       # task delivery -> pull/8
mkdir -p "$home/data/filed"
jq '.task="filed" | .records[0].url="https://github.com/o/r/issues/9" | .records[0].kind="issue" | .records[0].observation=null' \
  "$home/data/delivery/contributions.json" > "$home/data/filed/contributions.json"
printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
printf 'operator: two owned contributions; PR observed at %s\n' "$NOW"
touch "$home/forge/slow"                 # the forge answers slower than the whole budget
printf '$ fm-contributions.sh poll   (FM_CONTRIBUTIONS_BUDGET=1)\n'
out=$(poll_at "$home" "$NOW" env FM_CONTRIBUTIONS_BUDGET=1); rc=$?
printf '%s' "$out" | sed 's/^/| /'
printf '[exit %s, stdout %s bytes]\n' "$rc" "${#out}"
[ -z "$out" ] || bad "budget exhaustion printed a forge diagnostic: $out"
[ -z "$out" ] && ok 'no forge-unavailable diagnostic, so the supervisor is not woken'
printf '$ jq .records[0] data/delivery/contributions.json\n'
jq -c '.records[0] | {url,checked_at,attempted_at,error,state:.observation.state}' "$home/data/delivery/contributions.json" | sed 's/^/| /'
jq -e '.records[0] | .error == null and .checked_at == "2026-09-16T08:00:00Z" and .observation.state == "open"' \
  "$home/data/delivery/contributions.json" >/dev/null && ok 'last coherent observation preserved intact' \
  || bad 'budget exhaustion damaged the stored observation'
# the second URL never got its turn
rm -f "$home/forge/slow"; : > "$home/forge/calls"
printf '$ fm-contributions.sh poll   (next sweep, forge healthy)\n'
poll_at "$home" 2026-09-16T08:05:00Z >/dev/null
printf '  first forge call of the next sweep: %s\n' "$(sed -n '1p' "$home/forge/calls")"
[ "$(sed -n '1p' "$home/forge/calls")" = 'api repos/o/r/issues/9' ] \
  && ok 'the URL that was skipped goes first next time (no starvation)' \
  || bad "deferred URL starved: first call was $(sed -n '1p' "$home/forge/calls")"

################################################################
hdr 'SC7  a genuine forge timeout, with budget to spare, is still reported'
home=$(new_home sc7); forge_home "$home"; touch "$home/forge/slow"
printf '$ fm-contributions.sh poll   (FM_CONTRIBUTIONS_BUDGET=20, gh hangs)\n'
out=$(poll_at "$home" "$NOW" env FM_CONTRIBUTIONS_BUDGET=20)
printf '%s\n' "$out" | sed 's/^/| /'
case "$out" in *'observation unavailable'*) ok 'real forge stall is still surfaced' ;; *) bad 'real forge stall was swallowed' ;; esac
jq -e '.records[0].error != null' "$home/data/delivery/contributions.json" >/dev/null \
  && ok 'failure evidence stored on the record' || bad 'forge timeout left no evidence'

################################################################
hdr 'SC3  a real forge failure is reported once, not on every sweep'
home=$(new_home sc3); forge_home "$home"; touch "$home/forge/fail"
for n in 1 2 3; do
  case $n in 3) rm -f "$home/forge/fail" ;; esac
  out=$(poll_at "$home" "2026-09-16T08:0${n}:00Z")
  printf '$ poll #%s%s\n' "$n" "$([ $n = 3 ] && printf '   (forge recovered)')"
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/| /' || printf '| (silent)\n'
  printf '| record.error = %s\n' "$(jq -c '.records[0].error' "$home/data/delivery/contributions.json")"
  case $n in
    1) [ -n "$out" ] && ok 'first failure is announced' || bad 'failure hidden' ;;
    2) [ -z "$out" ] && ok 'unchanged failure does not wake the supervisor again' || bad 'repeat wake' ;;
    3) jq -e '.records[0].error == null' "$home/data/delivery/contributions.json" >/dev/null \
         && ok 'recovery clears the stored error' || bad 'recovery not observed' ;;
  esac
done

################################################################
hdr 'SC3b  the same outage, seen from the supervisor'
home=$(new_home sc3b); forge_home "$home"
with_home "$home" "$ROOT_UNDER_TEST/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
  || bad 'could not register the delivery check'
: > "$home/forge/calls"
touch "$home/forge/fail"
printf '$ fm-watch-checkpoint.sh --seconds 10   (forge down)\n'
with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
  "$ROOT_UNDER_TEST/bin/fm-watch-checkpoint.sh" --seconds 10 2>/dev/null | sed "s|$home|<home>|g;s/^/| /"
printf '$ cut -f5 state/.wake-queue   (what the supervisor is woken with)\n'
cut -f5 "$home/state/.wake-queue" 2>/dev/null | sed "s|$home|<home>|g;s/^/| /"
queued=$(awk -F '\t' 'NF >= 5 && $3 == "check" { c++ } END { print c+0 }' "$home/state/.wake-queue" 2>/dev/null)
[ "$queued" = 1 ] && ok 'the outage reaches the supervisor once, as one durable wake' \
  || bad "the first outage queued $queued wakes"
printf 'every non-empty line the registered check prints becomes one such wake;\n'
printf 'the outage has not changed, so the next three sweeps must print nothing.\n'
extra=0
for n in 2 3 4; do
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="2026-09-16T08:0${n}:00Z" bash "$home/state/contributions.check.sh")
  printf '$ state/contributions.check.sh   (sweep %s): %s\n' "$n" "$([ -n "$out" ] && printf '%s' "$out" || printf '(silent)')"
  [ -z "$out" ] || extra=$((extra + 1))
done
[ "$extra" -eq 0 ] && ok 'no further supervisor wake while the outage is unchanged' \
  || bad "$extra further supervisor wakes for the same unchanged outage"

################################################################
hdr 'SC4  a merged PR with nothing pending stops being re-observed'
home=$(new_home sc4); forge_home "$home"
mutate_record "$home" delivery '.records[0].observation.state="merged" | .records[0].checked_at="2026-09-01T00:00:00Z"'
: > "$home/forge/calls"
printf 'operator: PR #8 merged on 2026-09-01, backlog row still links it\n'
printf '$ fm-contributions.sh poll\n'
poll_at "$home" "$NOW" >/dev/null
printf '| forge calls made: %s\n' "$(wc -l < "$home/forge/calls" | tr -d ' ')"
[ ! -s "$home/forge/calls" ] && ok 'no forge traffic for merged, settled work' || bad 'merged PR was re-observed'
for when in 2026-09-16T08:00:00Z 2027-06-01T00:00:00Z; do
  snap=$(bearings_at "$home" "$when")
  printf '$ fm-bearings-snapshot.sh --json   (clock %s)\n' "$when"
  printf '%s' "$snap" | jq -c '.contributions | {known,checked,counts,proven_clear}' | sed 's/^/| /'
  printf '%s' "$snap" | jq -e '.contributions.counts.nobody == 1 and .contributions.counts.fleet == 0' >/dev/null \
    && ok "at $when it still needs nobody" || bad "at $when merged work decayed into fleet work"
done

################################################################
hdr 'SC5  adversarial: merged, but a maintainer left feedback'
home=$(new_home sc5); forge_home "$home"
# the forge itself reports this PR as merged, so a poll agrees with the record
sed -i '' 's|merged_at:null|merged_at:"2026-09-01T00:00:00Z"|' "$home/fakebin/gh"
mutate_record "$home" delivery '.records[0].observation.state="merged" | .records[0].checked_at="2026-09-01T00:00:00Z" | .records[0].pending=[{token:"review:terminal",type:"review"}]'
bearings_at "$home" "$NOW" | jq -c '.contributions.counts' | sed 's/^/| counts /'
bearings_at "$home" "$NOW" | jq -e '.contributions.counts.fleet == 1' >/dev/null \
  && ok 'unresolved feedback on a merged PR is still fleet work' || bad 'merged state hid open feedback'
printf '$ fm-contributions.sh pending\n'
with_home "$home" "$ROOT_UNDER_TEST/bin/fm-contributions.sh" pending | jq -c '.[0] | {task,url,token}' | sed 's/^/| /'
poll_at "$home" "$NOW" >/dev/null
[ -s "$home/forge/calls" ] && ok 'still polled while feedback is open' || bad 'feedback-bearing merged PR stopped being polled'
printf '$ fm-contributions.sh ack delivery https://github.com/o/r/pull/8 review:terminal\n'
with_home "$home" "$ROOT_UNDER_TEST/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 review:terminal
: > "$home/forge/calls"
poll_at "$home" 2026-09-16T08:10:00Z >/dev/null
[ ! -s "$home/forge/calls" ] && ok 'retires only after the feedback is acknowledged' || bad 'still polling after ack'

################################################################
hdr 'SC6  adversarial: merged, but the captain still holds it'
home=$(new_home sc6)
record "$home" held 12 merged mergeable '(hold: choose scope) (hold-kind: captain)'
record "$home" clear 13 merged mergeable
mutate_record "$home" held '.records[0].checked_at="2026-09-01T00:00:00Z"'
mutate_record "$home" clear '.records[0].checked_at="2026-09-01T00:00:00Z"'
snap=$(bearings_at "$home" "$NOW")
printf '%s' "$snap" | jq -c '.contributions | {counts,proven_clear,captain:[.captain[]|{url,reason}]}' | sed 's/^/| /'
printf '%s' "$snap" | jq -e '.contributions.counts == {captain:1,fleet:0,maintainer:0,nobody:1}
  and .contributions.captain[0].url == "https://github.com/o/r/pull/12"
  and .contributions.captain[0].reason == "choose scope"
  and .contributions.proven_clear == false' >/dev/null \
  && ok 'the held merge stays a captain call; the clear one needs nobody' \
  || bad 'merged precedence swallowed the live captain hold'

################################################################
hdr 'SC8  adversarial: closed but unmerged work stays live'
home=$(new_home sc8); forge_home "$home"
mutate_record "$home" delivery '.records[0].observation.state="closed" | .records[0].checked_at="2026-09-01T00:00:00Z"'
poll_at "$home" "$NOW" >/dev/null
printf '| forge calls made: %s\n' "$(wc -l < "$home/forge/calls" | tr -d ' ')"
[ -s "$home/forge/calls" ] && ok 'a closed, unmerged PR is still observed' || bad 'closed unmerged work was wrongly retired'

printf '\n================================\n'
[ "$DRIVE_FAILED" -eq 0 ] && printf 'ALL DRIVEN SCENARIOS PASSED\n' || printf 'DRIVEN SCENARIOS FAILED\n'
exit "$DRIVE_FAILED"
