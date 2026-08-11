#!/usr/bin/env bash
#
# Mock-backend tests for kamusm_timestamp.sh (no network, no real jar).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$ROOT/kamusm_timestamp.sh"
export KAMUSM_BACKEND=mock

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected='$expected' actual='$actual')" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (missing $path)" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_no_file() {
  local label="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (unexpected $path)" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (missing '$needle' in output)" >&2
    echo "$haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (unexpected '$needle')" >&2
    FAIL=$((FAIL + 1))
  fi
}

run_cli() {
  # Runs CLI; sets RUN_OUT and RUN_RC (does not exit on non-zero).
  set +e
  RUN_OUT="$("$CLI" "$@" 2>&1)"
  RUN_RC=$?
  set -e
}

# Sorted "relpath size cksum" lines for every regular file under dir.
snapshot_tree() {
  local root="$1"
  (
    cd "$root" || exit 1
    find . -type f -print | sort | while IFS= read -r rel; do
      # cksum: CRC SIZE PATH
      set -- $(cksum "$rel")
      printf '%s %s %s\n' "$rel" "$2" "$1"
    done
  )
}

build_fixtures() {
  local base="$1"
  local splunkdb="$base/splunkdb"
  local kamusmdb="$base/kamusmdb"

  rm -rf "$base"
  mkdir -p \
    "$splunkdb/firewall/db/db_100_90_0/rawdata" \
    "$splunkdb/firewall/db/db_200_190_1/rawdata" \
    "$splunkdb/firewall/db/hot_v1_0/rawdata" \
    "$splunkdb/firewall/colddb/db_300_290_2/rawdata" \
    "$splunkdb/other/db/db_1_0_0/rawdata" \
    "$kamusmdb/firewall"

  printf 'hash-aaa' >"$splunkdb/firewall/db/db_100_90_0/rawdata/l2Hash_0_aaa.dat"
  printf 'hash-bbb' >"$splunkdb/firewall/db/db_200_190_1/rawdata/l2Hash_0_bbb.dat"
  printf 'hash-hot' >"$splunkdb/firewall/db/hot_v1_0/rawdata/l1Hashes_0_ccc.dat"
  printf 'hash-cold' >"$splunkdb/firewall/colddb/db_300_290_2/rawdata/l2Hash_0_cold.dat"
  printf 'hash-ddd' >"$splunkdb/other/db/db_1_0_0/rawdata/l2Hash_0_ddd.dat"

  # Pre-stamp firewall/db_100_90_0 with a valid mock token matching current hash.
  local hash_file="$splunkdb/firewall/db/db_100_90_0/rawdata/l2Hash_0_aaa.dat"
  local digest
  if command -v xxd >/dev/null 2>&1; then
    digest="$(xxd -p "$hash_file" | tr -d '\n')"
  else
    digest="$(od -An -v -tx1 "$hash_file" | tr -d ' \n')"
  fi
  printf 'MOCK-ZD:%s\n' "$digest" >"$kamusmdb/firewall/db_100_90_0.zd"
}

# --- tests ---

test_create_stamps_unsigned_skips_hot_and_stamped() {
  echo "TEST: create stamps only unstamped l2 buckets"
  local base before after zd_hits
  base="$(mktemp -d)"
  build_fixtures "$base"

  before="$(snapshot_tree "$base/splunkdb")"
  run_cli create --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb"
  after="$(snapshot_tree "$base/splunkdb")"
  zd_hits="$(find "$base/splunkdb" -name '*.zd' 2>/dev/null | wc -l | tr -d ' ')"

  assert_eq "exit 0" "0" "$RUN_RC"
  assert_eq "splunkdb snapshot unchanged" "$before" "$after"
  assert_eq "no .zd under splunkdb" "0" "$zd_hits"
  assert_file "stamped db_200_190_1" "$base/kamusmdb/firewall/db_200_190_1.zd"
  assert_file "stamped colddb bucket" "$base/kamusmdb/firewall/db_300_290_2.zd"
  assert_file "stamped other db_1_0_0" "$base/kamusmdb/other/db_1_0_0.zd"
  assert_no_file "did not stamp hot bucket" "$base/kamusmdb/firewall/hot_v1_0.zd"
  assert_contains "skipped already stamped" "$RUN_OUT" "skipped:"
  assert_file "ledger exists" "$base/kamusmdb/ledger.csv"
  assert_contains "stamped count" "$RUN_OUT" "stamped: 3"

  rm -rf "$base"
}

test_create_dry_run() {
  echo "TEST: create --dry-run lists candidates, writes nothing"
  local base
  base="$(mktemp -d)"
  build_fixtures "$base"

  run_cli create --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb" --dry-run
  assert_eq "exit 0" "0" "$RUN_RC"
  assert_contains "lists db_200_190_1" "$RUN_OUT" "firewall/db_200_190_1"
  assert_contains "lists colddb" "$RUN_OUT" "firewall/db_300_290_2"
  assert_contains "lists other" "$RUN_OUT" "other/db_1_0_0"
  assert_no_file "no new firewall token" "$base/kamusmdb/firewall/db_200_190_1.zd"
  assert_no_file "no colddb token" "$base/kamusmdb/firewall/db_300_290_2.zd"
  assert_no_file "no other token" "$base/kamusmdb/other/db_1_0_0.zd"
  assert_no_file "no ledger" "$base/kamusmdb/ledger.csv"
  assert_contains "dry-run message" "$RUN_OUT" "Dry-run"

  rm -rf "$base"
}

test_create_index_filter() {
  echo "TEST: create --index firewall does not touch other"
  local base
  base="$(mktemp -d)"
  build_fixtures "$base"

  run_cli create --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb" --index firewall
  assert_eq "exit 0" "0" "$RUN_RC"
  assert_file "stamped firewall bucket" "$base/kamusmdb/firewall/db_200_190_1.zd"
  assert_file "stamped firewall colddb" "$base/kamusmdb/firewall/db_300_290_2.zd"
  assert_no_file "did not stamp other" "$base/kamusmdb/other/db_1_0_0.zd"

  rm -rf "$base"
}

test_create_force_restamps() {
  echo "TEST: create --force re-stamps existing token"
  local base
  base="$(mktemp -d)"
  build_fixtures "$base"

  run_cli create --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb" --force
  assert_eq "exit 0" "0" "$RUN_RC"
  assert_contains "stamped all l2" "$RUN_OUT" "stamped: 4"
  assert_file "force token db_100" "$base/kamusmdb/firewall/db_100_90_0.zd"
  assert_file "force token colddb" "$base/kamusmdb/firewall/db_300_290_2.zd"

  run_cli verify --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb" --strict-coverage
  assert_eq "verify after force" "0" "$RUN_RC"
  assert_contains "all verify_ok" "$RUN_OUT" "verify_ok:     4"

  rm -rf "$base"
}

test_verify_reports_unstamped_and_passed() {
  echo "TEST: verify reports unstamped + passed for verify-ok"
  local base
  base="$(mktemp -d)"
  build_fixtures "$base"
  run_cli verify --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb"
  assert_eq "exit 0 (no verify_failed)" "0" "$RUN_RC"
  assert_contains "verify_ok for pre-stamped" "$RUN_OUT" "verify_ok:     1"
  assert_contains "unstamped listed" "$RUN_OUT" "unstamped:"
  assert_contains "unstamped db_200" "$RUN_OUT" "firewall/db_200_190_1"
  assert_contains "unstamped colddb" "$RUN_OUT" "firewall/db_300_290_2"
  assert_contains "passed with unstamped" "$RUN_OUT" "passed (with unstamped buckets)"

  rm -rf "$base"
}

test_verify_fails_on_bad_token() {
  echo "TEST: verify fails when mock marks a token bad"
  local base
  base="$(mktemp -d)"
  build_fixtures "$base"
  echo 'MOCK-ZD-BAD' >"$base/kamusmdb/firewall/db_100_90_0.zd"

  run_cli verify --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb" --index firewall
  assert_eq "exit non-zero" "1" "$RUN_RC"
  assert_contains "verify_failed" "$RUN_OUT" "verify_failed:"
  assert_contains "failed bucket" "$RUN_OUT" "firewall/db_100_90_0"

  rm -rf "$base"
}

test_orphan_zd_does_not_fail() {
  echo "TEST: orphan .zd does not fail verify"
  local base
  base="$(mktemp -d)"
  build_fixtures "$base"
  mkdir -p "$base/kamusmdb/firewall"
  echo 'orphan' >"$base/kamusmdb/firewall/db_orphan_gone.zd"

  # Stamp all so no unstamped noise for firewall+other — stamp everything first
  run_cli create --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb"
  run_cli verify --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb"
  assert_eq "exit 0" "0" "$RUN_RC"
  assert_contains "orphan listed" "$RUN_OUT" "orphan_tokens"
  assert_contains "orphan key" "$RUN_OUT" "firewall/db_orphan_gone"
  assert_contains "passed" "$RUN_OUT" "passed"

  rm -rf "$base"
}

test_strict_coverage_fails_on_unstamped() {
  echo "TEST: --strict-coverage fails when unstamped remain"
  local base
  base="$(mktemp -d)"
  build_fixtures "$base"

  run_cli verify --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb" --strict-coverage
  assert_eq "exit non-zero" "1" "$RUN_RC"
  assert_contains "strict message" "$RUN_OUT" "strict-coverage"

  rm -rf "$base"
}

# --- jar + proxy (fake java; no real Zamane / TSA) ---------------------------

# Minimal one-bucket tree for jar-backend proxy tests.
build_proxy_fixtures() {
  local base="$1"
  rm -rf "$base"
  mkdir -p \
    "$base/splunkdb/firewall/db/db_100_90_0/rawdata" \
    "$base/kamusmdb" \
    "$base/bindir"
  printf 'hash-proxy' >"$base/splunkdb/firewall/db/db_100_90_0/rawdata/l2Hash_0_p.dat"
  touch "$base/fake.jar"
  ln -sf "$SCRIPT_DIR/bin/fake_java" "$base/bindir/java"
}

# Run create under jar backend with fake java on PATH. Leaves RUN_OUT/RUN_RC.
# Extra args are NAME=value pairs for env (e.g. KAMUSM_PROXY_IP=…).
run_jar_create() {
  local base="$1"
  shift
  set +e
  RUN_OUT="$(
    env -u KAMUSM_PROXY_IP -u KAMUSM_PROXY_PORT -u KAMUSM_PROXY_USER -u KAMUSM_PROXY_PASSWORD \
      KAMUSM_BACKEND=jar \
      KAMUSM_JAR_PATH="$base/fake.jar" \
      KAMUSM_CUSTOMER_NO=1 \
      KAMUSM_CUSTOMER_PASSWORD=secret \
      KAMUSM_TSA_URL=http://tsa.test \
      KAMUSM_TSA_PORT=80 \
      PATH="$base/bindir:/usr/bin:/bin" \
      "$@" \
      "$CLI" create --splunkdb "$base/splunkdb" --kamusmdb "$base/kamusmdb" --index firewall
  )"
  RUN_RC=$?
  set -e
}

test_jar_proxy_args_passed_to_java() {
  echo "TEST: jar create passes KAMUSM_PROXY_* as Zamane CLI args"
  local base argv_log
  base="$(mktemp -d)"
  argv_log="$base/java.argv"
  build_proxy_fixtures "$base"

  run_jar_create "$base" \
    KAMUSM_FAKE_JAVA_ARGV_LOG="$argv_log" \
    KAMUSM_PROXY_IP=10.1.2.3 \
    KAMUSM_PROXY_PORT=8080 \
    KAMUSM_PROXY_USER=puser \
    KAMUSM_PROXY_PASSWORD=ppass

  assert_eq "exit 0" "0" "$RUN_RC"
  assert_file "token written" "$base/kamusmdb/firewall/db_100_90_0.zd"
  assert_file "argv log written" "$argv_log"
  assert_contains "proxy ip in argv" "$(cat "$argv_log")" "10.1.2.3"
  assert_contains "proxy port in argv" "$(cat "$argv_log")" "8080"
  assert_contains "proxy user in argv" "$(cat "$argv_log")" "puser"
  assert_contains "proxy pass in argv" "$(cat "$argv_log")" "ppass"
  # Ordering: ... customer pass, then proxy fields, then hash alg
  assert_contains "proxy before hash alg" "$(cat "$argv_log")" \
    "1 secret 10.1.2.3 8080 puser ppass sha-256"

  rm -rf "$base"
}

test_jar_omit_proxy_goes_direct_argv() {
  echo "TEST: jar create omits proxy CLI args when KAMUSM_PROXY_* unset"
  local base argv_log
  base="$(mktemp -d)"
  argv_log="$base/java.argv"
  build_proxy_fixtures "$base"

  run_jar_create "$base" KAMUSM_FAKE_JAVA_ARGV_LOG="$argv_log"

  assert_eq "exit 0" "0" "$RUN_RC"
  assert_file "argv log written" "$argv_log"
  assert_not_contains "no 8080 leak" "$(cat "$argv_log")" "8080"
  assert_contains "direct arity ends with hash" "$(cat "$argv_log")" \
    "1 secret sha-256"
  assert_not_contains "no proxy user" "$(cat "$argv_log")" "puser"

  rm -rf "$base"
}

test_jar_proxy_traffic_reaches_listener() {
  echo "TEST: with proxy set, fake java TCP-connects to proxy listener"
  local base hit_file port listener_pid listener_rc argv_log i
  base="$(mktemp -d)"
  hit_file="$base/proxy.hit"
  argv_log="$base/java.argv"
  build_proxy_fixtures "$base"

  rm -f "$hit_file"
  python3 "$SCRIPT_DIR/bin/proxy_listener.py" "$hit_file" 10 >"$base/listener.port" &
  listener_pid=$!
  i=0
  while [[ ! -s "$base/listener.port" && "$i" -lt 50 ]]; do
    sleep 0.05
    i=$((i + 1))
  done
  port="$(tr -d '[:space:]' <"$base/listener.port")"
  if [[ -z "$port" || "$port" == "0" ]]; then
    echo "  FAIL: listener did not publish port" >&2
    FAIL=$((FAIL + 1))
    kill "$listener_pid" 2>/dev/null || true
    rm -rf "$base"
    return
  fi

  run_jar_create "$base" \
    KAMUSM_FAKE_JAVA_ARGV_LOG="$argv_log" \
    KAMUSM_FAKE_JAVA_CONNECT=1 \
    KAMUSM_PROXY_IP=127.0.0.1 \
    KAMUSM_PROXY_PORT="$port"

  set +e
  wait "$listener_pid"
  listener_rc=$?
  set -e

  assert_eq "create exit 0" "0" "$RUN_RC"
  assert_eq "listener accepted peer" "0" "$listener_rc"
  assert_file "proxy hit recorded" "$hit_file"
  assert_contains "argv used listener port" "$(cat "$argv_log")" "127.0.0.1 $port"

  rm -rf "$base"
}

test_jar_no_proxy_skips_proxy_listener() {
  echo "TEST: without proxy, fake java does not connect to proxy listener"
  local base hit_file port listener_pid listener_rc
  base="$(mktemp -d)"
  hit_file="$base/proxy.hit"
  build_proxy_fixtures "$base"

  rm -f "$hit_file"
  python3 "$SCRIPT_DIR/bin/proxy_listener.py" "$hit_file" 2 >"$base/listener.port" &
  listener_pid=$!
  local i=0
  while [[ ! -s "$base/listener.port" && "$i" -lt 50 ]]; do
    sleep 0.05
    i=$((i + 1))
  done
  port="$(tr -d '[:space:]' <"$base/listener.port")"

  # No KAMUSM_PROXY_*; connect flag set but unused without proxy args.
  run_jar_create "$base" KAMUSM_FAKE_JAVA_CONNECT=1

  set +e
  wait "$listener_pid"
  listener_rc=$?
  set -e

  assert_eq "create exit 0" "0" "$RUN_RC"
  assert_eq "listener timed out (no traffic)" "1" "$listener_rc"
  assert_no_file "no proxy hit" "$hit_file"

  rm -rf "$base"
}

main() {
  [[ -x "$CLI" ]] || chmod +x "$CLI"
  mkdir -p "$SCRIPT_DIR/output"
  local log_file="$SCRIPT_DIR/output/last_run.log"

  # Same-shell group (not a pipe) so PASS/FAIL stay visible; copy to gitignored log.
  {
    test_create_stamps_unsigned_skips_hot_and_stamped
    test_create_dry_run
    test_create_index_filter
    test_create_force_restamps
    test_verify_reports_unstamped_and_passed
    test_verify_fails_on_bad_token
    test_orphan_zd_does_not_fail
    test_strict_coverage_fails_on_unstamped
    test_jar_proxy_args_passed_to_java
    test_jar_omit_proxy_goes_direct_argv
    test_jar_proxy_traffic_reaches_listener
    test_jar_no_proxy_skips_proxy_listener

    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    echo "Log: $log_file"
  } >"$log_file" 2>&1

  cat "$log_file"
  [[ "$FAIL" -eq 0 ]]
}

main "$@"
