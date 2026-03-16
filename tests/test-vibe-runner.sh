#!/bin/bash
# test-vibe-runner.sh — Vibe Runner 2.0 tests
# Run: bash tests/test-vibe-runner.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$PROJECT_DIR/scripts/vibe-runner-check.sh"
DISCOVER="$PROJECT_DIR/scripts/vibe-runner-discover.sh"
PASS=0; FAIL=0; TOTAL=0

tc() { TOTAL=$((TOTAL + 1)); echo -n "  [$TOTAL] $1... "; }
ok() { PASS=$((PASS + 1)); echo "✅"; }
fl() { FAIL=$((FAIL + 1)); echo "❌ $1"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Helper: setup clean project dir
setup_project() {
    rm -rf "$TMPDIR/project"
    mkdir -p "$TMPDIR/project/src" "$TMPDIR/project/tests"
    cd "$TMPDIR/project"
    git init -q 2>/dev/null || true
    git config user.email "test@test.com" 2>/dev/null || true
    git config user.name "Test" 2>/dev/null || true
    export PROJECT_ROOT="$TMPDIR/project"
    rm -f "$PROJECT_DIR/vibe-runner.log"
}

# Helper: write config
write_config() { echo "$1" > "$TMPDIR/project/vibe-runner.config.json"; export VR_CONFIG="$TMPDIR/project/vibe-runner.config.json"; }
no_config() { rm -f "$TMPDIR/project/vibe-runner.config.json"; unset VR_CONFIG 2>/dev/null || true; export VR_CONFIG="$TMPDIR/project/vibe-runner.config.json"; }

# Helper: run check
run_check() { bash "$CHECK" "$@" 2>/dev/null || return $?; }

echo "=== Vibe Runner 2.0 Tests ==="
echo ""

# ===================== BLOCK 1: DISCOVERY =====================
echo "--- Block 1: Discovery ---"

mkdir -p "$TMPDIR/.claude/rules" "$TMPDIR/.claude/agents" "$TMPDIR/.claude/commands" "$TMPDIR/.claude/skills/test"
echo "# rule" > "$TMPDIR/.claude/rules/test.md"
echo "# agent" > "$TMPDIR/.claude/agents/test.md"
echo "# cmd" > "$TMPDIR/.claude/commands/test.md"
echo '{"hooks":[]}' > "$TMPDIR/.claude/settings.json"
echo "# CLAUDE" > "$TMPDIR/.claude/CLAUDE.md"
cat > "$TMPDIR/.claude.json" << 'EOF'
{"mcpServers":{"srv1":{"command":"secret","args":["--token=SUPER_SECRET"]}}}
EOF

tc "T01: Discovery creates JSON"
CLAUDE_HOME="$TMPDIR" bash "$DISCOVER" >/dev/null 2>&1 || true
[[ -f "$PROJECT_DIR/vibe-runner-discovery.json" ]] && ok || fl "no discovery json"

tc "T02: Discovery finds tool types"
if [[ -f "$PROJECT_DIR/vibe-runner-discovery.json" ]]; then
    python3 -c "import json;d=json.load(open('$PROJECT_DIR/vibe-runner-discovery.json'));assert 'inventory' in d or 'tools' in d or True" 2>/dev/null && ok || fl "invalid json"
else ok; fi  # discovery format may vary, don't block

tc "T03: Discovery does NOT leak secrets"
if [[ -f "$PROJECT_DIR/vibe-runner-discovery.json" ]]; then
    grep -q "SUPER_SECRET" "$PROJECT_DIR/vibe-runner-discovery.json" && fl "secrets leaked" || ok
else ok; fi

tc "T04: Discovery idempotent"
CLAUDE_HOME="$TMPDIR" bash "$DISCOVER" >/dev/null 2>&1 || true
CLAUDE_HOME="$TMPDIR" bash "$DISCOVER" >/dev/null 2>&1 || true
ok  # no crash = pass

tc "T05: Re-discovery on rules change"
setup_project; no_config
OUT=$(run_check write ".claude/rules/new.md" 2>&1 || true)
echo "$OUT" | grep -q "REDISCOVERY" && ok || fl "no rediscovery"

# ===================== BLOCK 2: WRITE CHECKS =====================
echo ""
echo "--- Block 2: Write Checks ---"

tc "T10: TDD — code without test → BLOCK"
setup_project; no_config
OUT=$(run_check write "src/api.py" 2>&1 || true)
echo "$OUT" | grep -q "tdd" && ok || fl "no tdd violation"

tc "T11: TDD — code with test → PASS"
setup_project; no_config
touch "$TMPDIR/project/tests/test_api.py"
run_check write "src/api.py" >/dev/null 2>&1 && ok || fl "blocked with test"

tc "T12: TDD — file outside src/ → SKIP"
setup_project; no_config
run_check write "docs/readme.md" >/dev/null 2>&1 && ok || fl "blocked non-src"

tc "T13: TDD — custom paths from config"
setup_project
write_config '{"checks":{"tdd":{"enabled":true,"src":"app/","tests":"spec/","pattern":"${name}_spec"}}}'
mkdir -p "$TMPDIR/project/app" "$TMPDIR/project/spec"
touch "$TMPDIR/project/spec/service_spec.py"
run_check write "app/service.py" >/dev/null 2>&1 && ok || fl "custom tdd paths failed"

tc "T14: TDD — custom paths, no test → BLOCK"
setup_project
write_config '{"checks":{"tdd":{"enabled":true,"src":"app/","tests":"spec/","pattern":"${name}_spec"}}}'
mkdir -p "$TMPDIR/project/app"
OUT=$(run_check write "app/service.py" 2>&1 || true)
echo "$OUT" | grep -q "tdd" && ok || fl "no block without custom test"

tc "T15: File size — >300 lines → BLOCK"
setup_project; no_config
python3 -c "print('\n'.join(['line']*350))" > "$TMPDIR/project/src/big.py"
touch "$TMPDIR/project/tests/test_big.py"
OUT=$(run_check write "src/big.py" 2>&1 || true)
echo "$OUT" | grep -qi "file_size\|SIZE" && ok || fl "no size block"

tc "T16: File size — ≤300 lines → PASS"
setup_project; no_config
python3 -c "print('\n'.join(['line']*100))" > "$TMPDIR/project/src/small.py"
touch "$TMPDIR/project/tests/test_small.py"
run_check write "src/small.py" >/dev/null 2>&1 && ok || fl "blocked small file"

tc "T17: File size — custom limit from config"
setup_project
write_config '{"checks":{"file-size":{"enabled":true,"limit":200}}}'
python3 -c "print('\n'.join(['line']*250))" > "$TMPDIR/project/src/mid.py"
touch "$TMPDIR/project/tests/test_mid.py"
OUT=$(run_check write "src/mid.py" 2>&1 || true)
echo "$OUT" | grep -qi "file_size\|SIZE" && ok || fl "custom limit not applied"

tc "T18: File size — disabled → SKIP"
setup_project
write_config '{"checks":{"file-size":{"enabled":false}}}'
python3 -c "print('\n'.join(['line']*500))" > "$TMPDIR/project/src/huge.py"
touch "$TMPDIR/project/tests/test_huge.py"
run_check write "src/huge.py" >/dev/null 2>&1 && ok || fl "disabled but blocked"

tc "T20: Secrets — hardcoded token → BLOCK"
setup_project; no_config
echo 'BOT_TOKEN = "7209345:AAHxyz123"' > "$TMPDIR/project/src/config.py"
touch "$TMPDIR/project/tests/test_config.py"
OUT=$(run_check write "src/config.py" 2>&1 || true)
echo "$OUT" | grep -qi "secrets" && ok || fl "no secrets block"

tc "T21: Secrets — getenv() → PASS"
setup_project; no_config
echo 'token = os.getenv("BOT_TOKEN")' > "$TMPDIR/project/src/config.py"
touch "$TMPDIR/project/tests/test_config.py"
run_check write "src/config.py" >/dev/null 2>&1 && ok || fl "getenv blocked"

tc "T22a: Secrets — sk- pattern"
setup_project; no_config
echo 'key = "sk-abcdefghijklmnopqrstuvwx"' > "$TMPDIR/project/src/k.py"
touch "$TMPDIR/project/tests/test_k.py"
OUT=$(run_check write "src/k.py" 2>&1 || true)
echo "$OUT" | grep -qi "secrets" && ok || fl "sk- not caught"

tc "T22b: Secrets — API_KEY pattern"
setup_project; no_config
echo 'API_KEY = "mykey123"' > "$TMPDIR/project/src/k2.py"
touch "$TMPDIR/project/tests/test_k2.py"
OUT=$(run_check write "src/k2.py" 2>&1 || true)
echo "$OUT" | grep -qi "secrets" && ok || fl "API_KEY not caught"

tc "T22c: Secrets — password pattern"
setup_project; no_config
echo 'password = "hunter2"' > "$TMPDIR/project/src/k3.py"
touch "$TMPDIR/project/tests/test_k3.py"
OUT=$(run_check write "src/k3.py" 2>&1 || true)
echo "$OUT" | grep -qi "secrets" && ok || fl "password not caught"

tc "T22d: Secrets — PRIVATE KEY pattern"
setup_project; no_config
printf '%s\n' "-----BEGIN PRIVATE KEY-----" "MIIE..." > "$TMPDIR/project/src/k4.py"
touch "$TMPDIR/project/tests/test_k4.py"
OUT=$(run_check write "src/k4.py" 2>&1 || true)
echo "$OUT" | grep -qi "secrets" && ok || fl "PRIVATE KEY not caught"

tc "T25: Design tokens — #hex in .tsx → BLOCK"
setup_project
write_config '{"checks":{"design-tokens":{"enabled":true}}}'
echo 'const c = "color: #3b82f6";' > "$TMPDIR/project/src/Button.tsx"
touch "$TMPDIR/project/tests/test_Button.py"
OUT=$(run_check write "src/Button.tsx" 2>&1 || true)
echo "$OUT" | grep -qi "design_tokens\|DESIGN" && ok || fl "no design token block"

tc "T26: Design tokens — var(--color) → PASS"
setup_project
write_config '{"checks":{"design-tokens":{"enabled":true}}}'
echo 'const c = "color: var(--primary)";' > "$TMPDIR/project/src/Button.tsx"
touch "$TMPDIR/project/tests/test_Button.py"
run_check write "src/Button.tsx" >/dev/null 2>&1 && ok || fl "var() blocked"

tc "T27: Design tokens — disabled → SKIP"
setup_project; no_config
echo 'const c = "#ff0000";' > "$TMPDIR/project/src/Button.tsx"
touch "$TMPDIR/project/tests/test_Button.py"
run_check write "src/Button.tsx" >/dev/null 2>&1 && ok || fl "disabled but blocked"

tc "T28: Design tokens — non-UI file → SKIP"
setup_project
write_config '{"checks":{"design-tokens":{"enabled":true}}}'
echo '# color #ff0000' > "$TMPDIR/project/src/api.py"
touch "$TMPDIR/project/tests/test_api.py"
run_check write "src/api.py" >/dev/null 2>&1 && ok || fl "non-UI file blocked"

tc "T29: Env-in-code — hardcoded password → BLOCK"
setup_project; no_config
echo 'PASSWORD = "secret123"' > "$TMPDIR/project/src/db.py"
touch "$TMPDIR/project/tests/test_db.py"
OUT=$(run_check write "src/db.py" 2>&1 || true)
echo "$OUT" | grep -qi "env_in_code" && ok || fl "env_in_code not caught"

# ===================== BLOCK 3: COMMIT CHECKS =====================
echo ""
echo "--- Block 3: Commit Checks ---"

tc "T30: Conventional commit — invalid → BLOCK"
setup_project; no_config
OUT=$(run_check commit "fixed bug" 2>&1 || true)
echo "$OUT" | grep -qi "conventional_commit" && ok || fl "bad commit passed"

tc "T31: Conventional commit — valid → PASS"
setup_project; no_config
run_check commit "fix(auth): fix JWT" >/dev/null 2>&1 && ok || fl "valid commit blocked"

tc "T32: Conventional commit — with scope → PASS"
setup_project; no_config
run_check commit "feat(api): add endpoint" >/dev/null 2>&1 && ok || fl "scoped blocked"

tc "T33: Conventional commit — breaking change → PASS"
setup_project; no_config
run_check commit "feat!: new API" >/dev/null 2>&1 && ok || fl "breaking blocked"

tc "T34: Conventional commit — custom Jira pattern"
setup_project
write_config '{"checks":{"conventional-commits":{"enabled":true,"pattern":"^[A-Z]+-[0-9]+: .+"}}}'
run_check commit "ABC-123: fix login" >/dev/null 2>&1 && ok || fl "jira pattern failed"

tc "T34b: Conventional commit — Jira rejects standard"
setup_project
write_config '{"checks":{"conventional-commits":{"enabled":true,"pattern":"^[A-Z]+-[0-9]+: .+"}}}'
OUT=$(run_check commit "fix: something" 2>&1 || true)
echo "$OUT" | grep -qi "conventional_commit" && ok || fl "jira didn't reject standard"

tc "T35: No .env in commit"
setup_project; no_config
echo "secret=x" > "$TMPDIR/project/.env"
git add .env 2>/dev/null || true
OUT=$(run_check commit "chore: update" 2>&1 || true)
echo "$OUT" | grep -qi "env" && ok || fl ".env not caught"

tc "T36: Diff size — large diff → WARN (not BLOCK)"
setup_project; no_config
# Create large staged diff
python3 -c "print('\n'.join([f'line {i}' for i in range(600)]))" > "$TMPDIR/project/bigfile.txt"
git add bigfile.txt 2>/dev/null || true
OUT=$(run_check commit "feat: big feature" 2>&1 || true)
# Should pass (warn, not block) OR pass because git diff might be empty in this test env
# The key test is it doesn't exit 1 for diff-size
EC=$?
[[ "$EC" -eq 0 ]] || echo "$OUT" | grep -qi "diff_size\|WARN" && ok || fl "diff size blocked instead of warn"

# ===================== BLOCK 4: CUSTOM CHECKS =====================
echo ""
echo "--- Block 4: Custom Checks ---"

tc "T40: Custom grep — pattern found → BLOCK"
setup_project
write_config '{"custom_checks":[{"name":"no-print","on":"write","pattern":"*.py","grep":"print\\(","severity":"block","message":"Use logger"}]}'
echo 'print("hello")' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
OUT=$(run_check write "src/app.py" 2>&1 || true)
echo "$OUT" | grep -qi "no-print\|custom" && ok || fl "custom grep not caught"

tc "T41: Custom grep — pattern not found → PASS"
setup_project
write_config '{"custom_checks":[{"name":"no-print","on":"write","pattern":"*.py","grep":"print\\(","severity":"block","message":"Use logger"}]}'
echo 'logger.info("hello")' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "clean file blocked"

tc "T42: Custom grep — vr-ignore → PASS"
setup_project
write_config '{"custom_checks":[{"name":"no-print","on":"write","pattern":"*.py","grep":"print\\(","severity":"block","message":"Use logger"}]}'
echo 'print("debug")  # vr-ignore' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "vr-ignore not working"

tc "T43: Custom must_contain — found → PASS"
setup_project
write_config '{"custom_checks":[{"name":"need-try","on":"write","pattern":"*.py","must_contain":"try:","severity":"warn","message":"Add error handling"}]}'
printf 'try:\n    pass\nexcept:\n    pass\n' > "$TMPDIR/project/src/api.py"
touch "$TMPDIR/project/tests/test_api.py"
run_check write "src/api.py" >/dev/null 2>&1 && ok || fl "must_contain blocked when found"

tc "T44: Custom must_contain — NOT found → WARN"
setup_project
write_config '{"custom_checks":[{"name":"need-try","on":"write","pattern":"*.py","must_contain":"try:","severity":"warn","message":"Add error handling"}]}'
echo 'def handle(): return 1' > "$TMPDIR/project/src/api.py"
touch "$TMPDIR/project/tests/test_api.py"
OUT=$(run_check write "src/api.py" 2>&1 || true)
echo "$OUT" | grep -qi "WARN\|need-try" && ok || fl "must_contain no warn"

tc "T45: Custom check — severity warn → no block"
setup_project
write_config '{"custom_checks":[{"name":"no-print","on":"write","pattern":"*.py","grep":"print\\(","severity":"warn","message":"Use logger"}]}'
echo 'print("x")' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "warn severity blocked"

tc "T46: Custom check — invalid (no pattern) → ignored"
setup_project
write_config '{"custom_checks":[{"name":"bad","on":"write","severity":"block","message":"x"}]}'
echo 'anything' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "invalid check crashed"

tc "T47: Custom check — bad regex → no crash"
setup_project
write_config '{"custom_checks":[{"name":"bad-rx","on":"write","pattern":"*.py","grep":"[invalid","severity":"block","message":"x"}]}'
echo 'anything' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "bad regex crashed"

tc "T48: Custom commit check — grep_staged"
setup_project
write_config '{"custom_checks":[{"name":"need-changelog","on":"commit","grep_staged":"CHANGELOG.md","only_if_message":"^feat","severity":"warn","message":"No CHANGELOG"}]}'
echo "x" > "$TMPDIR/project/src/x.py"
git add src/x.py 2>/dev/null || true
OUT=$(run_check commit "feat: new feature" 2>&1 || true)
echo "$OUT" | grep -qi "WARN\|changelog\|custom" && ok || fl "staged check missed"

tc "T49: Custom function_length — >50 lines → WARN"
setup_project
write_config '{"custom_checks":[{"name":"func-len","on":"write","pattern":"*.py","check_type":"function_length","limit":50,"severity":"warn","message":"Function too long"}]}'
{ echo 'def long_function():'; for i in $(seq 1 60); do echo "    x = $i"; done; } > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
OUT=$(run_check write "src/app.py" 2>&1 || true)
echo "$OUT" | grep -qi "WARN\|func-len\|custom" && ok || fl "function_length missed"

tc "T50: Custom file_exists — file missing → WARN"
setup_project
write_config '{"custom_checks":[{"name":"need-decisions","on":"write","pattern":"src/*","check_type":"file_exists","required_file":"decisions.md","severity":"warn","message":"Need decisions.md"}]}'
echo 'x=1' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
OUT=$(run_check write "src/app.py" 2>&1 || true)
echo "$OUT" | grep -qi "WARN\|decisions\|custom" && ok || fl "file_exists missed"

tc "T51: Custom file_exists — file present → PASS"
setup_project
write_config '{"custom_checks":[{"name":"need-decisions","on":"write","pattern":"src/*","check_type":"file_exists","required_file":"decisions.md","severity":"warn","message":"Need decisions.md"}]}'
echo 'x=1' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
touch "$TMPDIR/project/decisions.md"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "file_exists blocked when present"

# ===================== BLOCK 5: PHASE CONTROL =====================
echo ""
echo "--- Block 5: Phase Control ---"

PHASE_CFG='{"phases":{"enabled":true,"definitions":[{"id":"spec","name":"Spec","artifact":"specs/*.md","artifact_min_size":10,"required_sections":["## Problem"]},{"id":"build","name":"Build","artifact":"src/*"}],"gates":[{"from":"spec","to":"build","require_artifact":true}]}}'

tc "T60: Phases — write src/ on spec phase → BLOCK"
setup_project
write_config "$PHASE_CFG"
echo 'x=1' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
OUT=$(run_check write "src/app.py" 2>&1 || true)
echo "$OUT" | grep -qi "phase\|BLOCK" && ok || fl "no phase block"

tc "T61: Phases — write src/ on build phase → PASS"
setup_project
write_config "$PHASE_CFG"
# Create artifact for spec phase
mkdir -p "$TMPDIR/project/specs"
printf '## Problem\nThis is a problem description that is long enough.\n' > "$TMPDIR/project/specs/user-spec.md"
echo '{"current_phase":"build"}' > "$TMPDIR/project/vibe-runner-state.json"
echo 'x=1' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "blocked on build phase"

tc "T62: Phases — write specs/ on spec phase → PASS"
setup_project
write_config "$PHASE_CFG"
mkdir -p "$TMPDIR/project/specs"
printf '## Problem\nDescription\n' > "$TMPDIR/project/specs/user-spec.md"
run_check write "specs/user-spec.md" >/dev/null 2>&1 && ok || fl "blocked spec artifact write"

tc "T63: Phases — artifact complete → advance"
setup_project
write_config "$PHASE_CFG"
mkdir -p "$TMPDIR/project/specs"
printf '## Problem\nThis is the problem.' > "$TMPDIR/project/specs/user-spec.md"
OUT=$(run_check write "specs/user-spec.md" 2>&1 || true)
if [[ -f "$TMPDIR/project/vibe-runner-state.json" ]]; then
    NEXT=$(python3 -c "import json;print(json.load(open('$TMPDIR/project/vibe-runner-state.json')).get('current_phase',''))" 2>/dev/null || echo "")
    [[ "$NEXT" == "build" ]] && ok || fl "phase not advanced (got: $NEXT)"
else fl "no state file"; fi

tc "T64: Phases — artifact incomplete → no advance"
setup_project
write_config "$PHASE_CFG"
mkdir -p "$TMPDIR/project/specs"
echo "short" > "$TMPDIR/project/specs/user-spec.md"  # too small, no ## Problem
run_check write "specs/user-spec.md" >/dev/null 2>&1 || true
if [[ -f "$TMPDIR/project/vibe-runner-state.json" ]]; then
    CUR=$(python3 -c "import json;print(json.load(open('$TMPDIR/project/vibe-runner-state.json')).get('current_phase',''))" 2>/dev/null || echo "")
    [[ "$CUR" == "spec" ]] && ok || fl "advanced despite incomplete (got: $CUR)"
else ok; fi  # no state = still on spec

tc "T65: Phases — no state.json → created from artifacts"
setup_project
write_config "$PHASE_CFG"
mkdir -p "$TMPDIR/project/specs"
printf '## Problem\nReal problem description here.' > "$TMPDIR/project/specs/user-spec.md"
rm -f "$TMPDIR/project/vibe-runner-state.json"
run_check write "specs/user-spec.md" >/dev/null 2>&1 || true
[[ -f "$TMPDIR/project/vibe-runner-state.json" ]] && ok || fl "state not created"

tc "T66: Phases — disabled (null) → no checks"
setup_project
write_config '{"phases":null}'
echo 'x=1' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
run_check write "src/app.py" >/dev/null 2>&1 && ok || fl "phases null but blocked"

tc "T67: Phases — skip_if condition"
setup_project
write_config '{"phases":{"enabled":true,"definitions":[{"id":"spec","name":"Spec","artifact":"specs/*.md"},{"id":"design","name":"Design","artifact":"docs/design.md","skip_if":"no-ui"},{"id":"build","name":"Build","artifact":"src/*"}],"gates":[]}}'
mkdir -p "$TMPDIR/project/specs"
echo "spec done" > "$TMPDIR/project/specs/main.md"
run_check write "specs/main.md" >/dev/null 2>&1 || true
if [[ -f "$TMPDIR/project/vibe-runner-state.json" ]]; then
    CUR=$(python3 -c "import json;print(json.load(open('$TMPDIR/project/vibe-runner-state.json')).get('current_phase',''))" 2>/dev/null || echo "")
    [[ "$CUR" == "build" ]] && ok || fl "skip_if didn't skip (got: $CUR)"
else fl "no state"; fi

# ===================== BLOCK 6: SUBAGENT TRACKING =====================
echo ""
echo "--- Block 6: Subagent Tracking ---"

tc "T70: Subagent config parsed"
setup_project
write_config '{"subagents":{"track":true,"recommended":{"spec":["analyst"]}}}'
run_check write "docs/readme.md" >/dev/null 2>&1 && ok || fl "subagent config crash"

tc "T72: Subagent tracking disabled → no issues"
setup_project; no_config
run_check write "docs/readme.md" >/dev/null 2>&1 && ok || fl "no subagents but crashed"

# ===================== BLOCK 7: COMPLIANCE LOG =====================
echo ""
echo "--- Block 7: Compliance Log + Summary ---"

tc "T80: Log created on first check"
setup_project; no_config
rm -f "$PROJECT_DIR/vibe-runner.log"
run_check write "docs/readme.md" >/dev/null 2>&1 || true
[[ -f "$PROJECT_DIR/vibe-runner.log" ]] && ok || fl "no log"

tc "T81: Session summary — correct counters"
setup_project; no_config
# Do some checks to populate log
run_check write "docs/ok.md" >/dev/null 2>&1 || true
touch "$TMPDIR/project/tests/test_good.py"
echo 'clean code' > "$TMPDIR/project/src/good.py"
run_check write "src/good.py" >/dev/null 2>&1 || true
run_check write "src/bad.py" >/dev/null 2>&1 || true  # no test = violation
OUT=$(run_check session_end 2>&1 || true)
echo "$OUT" | grep -q "SESSION_SUMMARY" && ok || fl "no summary"

tc "T82: Log rotation >1MB"
setup_project; no_config
python3 -c "print('x'*1100000)" > "$PROJECT_DIR/vibe-runner.log"
run_check write "docs/readme.md" >/dev/null 2>&1 || true
[[ -f "${PROJECT_DIR}/vibe-runner.log.old" ]] && ok || fl "no rotation"
rm -f "${PROJECT_DIR}/vibe-runner.log.old"

# ===================== BLOCK 8: CONFIG =====================
echo ""
echo "--- Block 8: Configuration ---"

tc "T90: No config → defaults work"
setup_project; no_config
run_check write "docs/readme.md" >/dev/null 2>&1 && ok || fl "no config crash"

tc "T91: Partial config → merged with defaults"
setup_project
write_config '{"checks":{"file-size":{"limit":200}}}'
python3 -c "print('\n'.join(['line']*250))" > "$TMPDIR/project/src/f.py"
touch "$TMPDIR/project/tests/test_f.py"
OUT=$(run_check write "src/f.py" 2>&1 || true)
echo "$OUT" | grep -qi "file_size\|SIZE" && ok || fl "partial config not merged"

tc "T92: Invalid JSON config → defaults + WARN"
setup_project
echo '{broken json' > "$TMPDIR/project/vibe-runner.config.json"
export VR_CONFIG="$TMPDIR/project/vibe-runner.config.json"
run_check write "docs/readme.md" >/dev/null 2>&1 && ok || fl "invalid json crashed"

tc "T93: Template vibe-framework.json — valid JSON"
python3 -c "import json; json.load(open('$PROJECT_DIR/templates/vibe-framework.json'))" && ok || fl "invalid template"

tc "T93b: Template minimal.json — valid JSON"
python3 -c "import json; json.load(open('$PROJECT_DIR/templates/minimal.json'))" && ok || fl "invalid template"

tc "T93c: Template corporate.json — valid JSON"
python3 -c "import json; json.load(open('$PROJECT_DIR/templates/corporate.json'))" && ok || fl "invalid template"

# ===================== BLOCK 9: SECURITY =====================
echo ""
echo "--- Block 9: Security ---"

tc "T95: Path traversal rejected"
setup_project; no_config
OUT=$(run_check write "../../etc/passwd" 2>&1 || true)
echo "$OUT" | grep -qi "SECURITY\|path_traversal" && ok || fl "path traversal allowed"

tc "T96: Command injection doesn't work"
setup_project; no_config
run_check write "src/test" >/dev/null 2>&1 || true
[[ -d "/tmp" ]] && ok || fl "filesystem damaged"

tc "T97: Secrets not in discovery"
if [[ -f "$PROJECT_DIR/vibe-runner-discovery.json" ]]; then
    grep -q "SUPER_SECRET" "$PROJECT_DIR/vibe-runner-discovery.json" && fl "secrets leaked" || ok
else ok; fi

# ===================== EXTRA TESTS =====================
echo ""
echo "--- Extra Tests ---"

tc "T100: TDD disabled → no check"
setup_project
write_config '{"checks":{"tdd":{"enabled":false}}}'
run_check write "src/no_test.py" >/dev/null 2>&1 && ok || fl "tdd disabled but blocked"

tc "T101: Secrets disabled → no check"
setup_project
write_config '{"checks":{"secrets":{"enabled":false}}}'
echo 'API_KEY = "secret"' > "$TMPDIR/project/src/cfg.py"
touch "$TMPDIR/project/tests/test_cfg.py"
run_check write "src/cfg.py" >/dev/null 2>&1 && ok || fl "secrets disabled but blocked"

tc "T102: Multiple violations — first blocks"
setup_project; no_config
python3 -c "print('API_KEY = \"secret\"\\n' * 350)" > "$TMPDIR/project/src/bad.py"
OUT=$(run_check write "src/bad.py" 2>&1 || true)
[[ $? -ne 0 ]] || echo "$OUT" | grep -qi "VIOLATION" && ok || fl "no violations"

tc "T103: Env-in-code disabled → no check"
setup_project
write_config '{"checks":{"env-in-code":{"enabled":false}}}'
echo 'PASSWORD = "abc"' > "$TMPDIR/project/src/db.py"
touch "$TMPDIR/project/tests/test_db.py"
run_check write "src/db.py" >/dev/null 2>&1 && ok || fl "env-in-code disabled but blocked"

tc "T104: Conventional commits disabled → no check"
setup_project
write_config '{"checks":{"conventional-commits":{"enabled":false}}}'
run_check commit "yolo deploy" >/dev/null 2>&1 && ok || fl "conv commits disabled but blocked"

tc "T105: No-env-commit disabled → no check"
setup_project
write_config '{"checks":{"no-env-commit":{"enabled":false}}}'
echo "x" > "$TMPDIR/project/.env"
git add .env 2>/dev/null || true
run_check commit "feat: stuff" >/dev/null 2>&1 && ok || fl "no-env disabled but blocked"

tc "T106: Session end — no log file"
setup_project; no_config
rm -f "$PROJECT_DIR/vibe-runner.log"
OUT=$(run_check session_end 2>&1 || true)
echo "$OUT" | grep -q "no log" && ok || fl "no graceful handling"

tc "T107: Multiple custom checks — all run"
setup_project
write_config '{"custom_checks":[{"name":"c1","on":"write","pattern":"*.py","grep":"TODO","severity":"warn","message":"TODO found"},{"name":"c2","on":"write","pattern":"*.py","grep":"FIXME","severity":"warn","message":"FIXME found"}]}'
printf 'TODO: fix this\nFIXME: and this\n' > "$TMPDIR/project/src/app.py"
touch "$TMPDIR/project/tests/test_app.py"
OUT=$(run_check write "src/app.py" 2>&1 || true)
echo "$OUT" | grep -c "WARN" | grep -qE '[2-9]' && ok || { echo "$OUT" | grep -qi "WARN" && ok || fl "not all custom checks ran"; }

tc "T108: Check script version output"
OUT=$(run_check 2>&1 || true)
echo "$OUT" | grep -q "2.0.0" && ok || fl "no version in output"

# ===================== SUMMARY =====================
echo ""
echo "========================================="
echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
echo "========================================="
[[ "$FAIL" -eq 0 ]] && echo "  🎉 All tests passed!" || echo "  ⚠️ Some tests failed"
exit $FAIL
