#!/bin/bash
# vibe-runner-check.sh v2.0 — universal enforcement for Claude Code
# SECURITY: sanitize input, validate paths, no eval/exec, no network
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${PLUGIN_DIR}/vibe-runner.log"
MAX_LOG_SIZE=1048576
ACTION="${1:-}" ; TARGET="${2:-}"
PROJECT_ROOT="${PROJECT_ROOT:-.}"
CONFIG_FILE="${PROJECT_ROOT}/vibe-runner.config.json"
STATE_FILE="${PROJECT_ROOT}/vibe-runner-state.json"
BLOCKED=0 ; WARNINGS=""

sanitize_path() { echo "$1" | tr -cd 'a-zA-Z0-9/._ -'; }
validate_path() {
    [[ "$1" == *".."* ]] && { echo "SECURITY:path_traversal — suspicious path: $1"; exit 1; }
    local r; r=$(realpath -m "$1" 2>/dev/null || echo "$1")
    [[ "$r" == *".."* ]] && { echo "SECURITY:path_traversal — $1"; exit 1; }
}
[[ "$ACTION" == "write" && -n "$TARGET" ]] && { validate_path "$TARGET"; TARGET=$(sanitize_path "$TARGET"); }

log_entry() {
    if [[ -f "$LOG_FILE" ]]; then
        local s; s=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        [[ "$s" -gt "$MAX_LOG_SIZE" ]] && mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}
warn() { WARNINGS="${WARNINGS}WARN:$1\n"; log_entry "[VR:CHECK] ⚠️ $1"; }
block() { BLOCKED=1; log_entry "[VR:CHECK] ❌ $1"; echo "VIOLATION:$1"; }
pass_ok() { log_entry "[VR:CHECK] ✅ $1"; }

# Config: merge user config with defaults via python3
load_config() {
    python3 -c "
import json,sys,os
D={'checks':{'file-size':{'enabled':True,'limit':300},'tdd':{'enabled':True,'src':'src/','tests':'tests/','pattern':'test_\${name}'},'secrets':{'enabled':True},'design-tokens':{'enabled':False},'env-in-code':{'enabled':True},'conventional-commits':{'enabled':True,'pattern':''},'no-env-commit':{'enabled':True},'diff-size':{'enabled':True,'warn':500}},'phases':None,'subagents':None,'custom_checks':[]}
p=os.environ.get('VR_CONFIG','$CONFIG_FILE')
try:
 if os.path.isfile(p):
  u=json.load(open(p))
  if 'checks' in u:
   for k,v in u['checks'].items():
    if k in D['checks']:D['checks'][k].update(v)
    else:D['checks'][k]=v
  for k in('phases','subagents','custom_checks'):
   if k in u:D[k]=u[k]
except Exception as e:print(f'CFGWARN:{e}',file=sys.stderr)
print(json.dumps(D))" 2>/dev/null || echo '{}'
}

cfg_get() {
    echo "$CFG" | python3 -c "
import json,sys;d=json.load(sys.stdin)
path='$1'.split('.');v=d
for p in path:
 if isinstance(v,dict):v=v.get(p)
 elif isinstance(v,list):
  try:v=v[int(p)]
  except:v=None
 else:v=None
if v is None:print('$2')
elif isinstance(v,bool):print('true' if v else 'false')
elif isinstance(v,(dict,list)):print(json.dumps(v))
else:print(v)" 2>/dev/null || echo "$2"
}

chk_enabled() { [[ "$(cfg_get "checks.$1.enabled" "$2")" == "true" ]]; }

check_file_size() {
    chk_enabled file-size true || return 0; [[ ! -f "$1" ]] && return 0
    local lim; lim=$(cfg_get 'checks.file-size.limit' '300')
    local n; n=$(wc -l < "$1" 2>/dev/null | tr -d ' '); n=${n:-0}
    [[ "$n" -gt "$lim" ]] && block "file_size — ${n} lines (limit: ${lim}) in $1" || pass_ok "file_size: $1 (${n}/${lim})"
}

check_tdd() {
    chk_enabled tdd true || return 0
    local src; src=$(cfg_get 'checks.tdd.src' 'src/')
    echo "$1" | grep -q "$src" || return 0
    local tdir pat bn tn; tdir=$(cfg_get 'checks.tdd.tests' 'tests/')
    pat=$(cfg_get 'checks.tdd.pattern' 'test_${name}')
    bn=$(basename "$1"); bn="${bn%.*}"
    tn=$(echo "$pat" | sed "s/\${name}/$bn/g")
    if compgen -G "${PROJECT_ROOT}/${tdir}${tn}.*" >/dev/null 2>&1 || compgen -G "${PROJECT_ROOT}/${tdir}*/${tn}.*" >/dev/null 2>&1; then
        pass_ok "tdd: test for $1"
    else
        block "tdd — no test for $1 (expected ${tdir}${tn}.*)"
    fi
}

check_secrets() {
    chk_enabled secrets true || return 0; [[ ! -f "$1" ]] && return 0
    [[ "$(basename "$1")" == .env* ]] && return 0
    grep -nEq '(sk-[a-zA-Z0-9]{20}|API_KEY\s*=\s*"|password\s*=\s*"|PRIVATE KEY|[0-9]{7,}:[A-Za-z0-9])' "$1" 2>/dev/null \
        && block "secrets — hardcoded token/password in $1" || pass_ok "secrets: $1"
}

check_design_tokens() {
    chk_enabled design-tokens false || return 0
    echo "$1" | grep -qE '\.(css|tsx|jsx|vue|svelte)$' || return 0
    [[ ! -f "$1" ]] && return 0
    grep -nEq '#[0-9a-fA-F]{3,8}[^a-zA-Z]|rgb\(|hsl\(' "$1" 2>/dev/null \
        && block "design_tokens — hardcoded color in $1" || pass_ok "design_tokens: $1"
}

check_env_in_code() {
    chk_enabled env-in-code true || return 0; [[ ! -f "$1" ]] && return 0
    [[ "$(basename "$1")" == .env* || "$(basename "$1")" == *.md ]] && return 0
    grep -nEq '(PASSWORD|SECRET|PRIVATE_KEY)\s*=\s*"[^"]+"|password\s*=\s*"[^"]+"' "$1" 2>/dev/null \
        && block "env_in_code — secret hardcoded in $1" || pass_ok "env_in_code: $1"
}

check_conventional_commit() {
    chk_enabled conventional-commits true || return 0
    local cp; cp=$(cfg_get 'checks.conventional-commits.pattern' '')
    if [[ -n "$cp" ]]; then
        echo "$1" | grep -qE "$cp" && pass_ok "conventional_commit" || block "conventional_commit — doesn't match: $cp"
    else
        echo "$1" | grep -qE '^(feat|fix|docs|style|refactor|test|chore|ci|build|perf)(\(.+\))?(!)?:' \
            && pass_ok "conventional_commit: $1" || block "conventional_commit — use: type(scope): desc"
    fi
}

check_no_env_commit() {
    chk_enabled no-env-commit true || return 0
    git diff --cached --name-only 2>/dev/null | grep -qE '\.env$|\.env\.' \
        && block "no_env_commit — .env in staging" || pass_ok "no_env_commit"
}

check_diff_size() {
    chk_enabled diff-size true || return 0
    local lim dl; lim=$(cfg_get 'checks.diff-size.warn' '500')
    dl=$(git diff --cached --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || echo 0); dl=${dl:-0}
    [[ "$dl" -gt "$lim" ]] && warn "diff_size — ${dl} lines (limit: ${lim})"
}

# Custom checks via python3 (single call for all)
run_custom_checks() {
    local mode="$1" file="$2" msg="$3"
    local checks; checks=$(cfg_get 'custom_checks' '[]')
    [[ "$checks" == "[]" || "$checks" == "" ]] && return 0
    local tmpf; tmpf=$(mktemp); echo "$checks" > "$tmpf"
    trap "rm -f '$tmpf'" RETURN
    python3 - "$mode" "$file" "$msg" "$PROJECT_ROOT" "$tmpf" << 'PYEOF'
import json,sys,re,os,fnmatch,subprocess
mode,fpath,msg,pr=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
rp=os.path.relpath(fpath,pr) if os.path.isabs(fpath) else fpath
checks=json.load(open(sys.argv[5]))
def match_pat(f,p):
 for g in p.split('|'):
  g=g.strip()
  if fnmatch.fnmatch(f,g) or fnmatch.fnmatch(os.path.basename(f),g): return True
  if '**' in g and fnmatch.fnmatch(f,g.replace('**/','*')): return True
 return False
for c in checks:
 if not isinstance(c,dict): continue
 nm=c.get('name','?');sev=c.get('severity','warn');ms=c.get('message',nm)
 if c.get('on','write')!=mode: continue
 if mode=='write':
  pat=c.get('pattern','')
  if not pat or not sev: print(f'WARN:invalid:{nm}');continue
  if not match_pat(fpath,pat) and not match_pat(rp,pat): continue
  ct=c.get('check_type','');exc=c.get('exclude_grep','vr-ignore')
  if ct=='file_exists':
   rf=c.get('required_file','')
   if rf and not os.path.exists(os.path.join(pr,rf)): print(f'{sev.upper()}:{nm}:{ms}')
   continue
  if ct=='function_length':
   lim=int(c.get('limit',50))
   try: lines=open(fpath,errors='replace').readlines()
   except: continue
   fp=re.compile(r'^(def |function |const \w+ ?=|async function |export )')
   fs=None;fn=''
   for i,l in enumerate(lines):
    if fp.search(l.lstrip()):
     if fs is not None and i-fs>lim: print(f'{sev.upper()}:{nm}:{fn[:50]} is {i-fs} lines (limit {lim})')
     fs=i;fn=l.strip()
   if fs is not None and len(lines)-fs>lim: print(f'{sev.upper()}:{nm}:{fn[:50]} is {len(lines)-fs} lines (limit {lim})')
   continue
  try: content=open(fpath,errors='replace').read();lines=content.splitlines()
  except: continue
  gp=c.get('grep','');mc=c.get('must_contain','')
  if gp:
   try: rx=re.compile(gp)
   except: print(f'WARN:bad_regex:{nm}');continue
   hit=any(rx.search(l) for l in lines if not (exc and re.search(r'vr-ignore',l)))
   if hit: print(f'{sev.upper()}:{nm}:{ms}')
  if mc:
   try: rx=re.compile(mc)
   except: print(f'WARN:bad_regex:{nm}');continue
   if not rx.search(content): print(f'{sev.upper()}:{nm}:{ms}')
 elif mode=='commit':
  oif=c.get('only_if_message','')
  if oif:
   try:
    if not re.search(oif,msg): continue
   except: continue
  gs=c.get('grep_staged','')
  if gs:
   try: st=subprocess.check_output(['git','diff','--cached','--name-only'],text=True,timeout=5)
   except: st=''
   if gs not in st: print(f'{sev.upper()}:{nm}:{ms}')
  gm=c.get('grep_message','')
  if gm:
   try:
    if re.search(gm,msg): print(f'{sev.upper()}:{nm}:{ms}')
   except: pass
PYEOF
    rm -f "$tmpf"
}

# Phase control via python3
check_phases() {
    local file="$1" phases; phases=$(cfg_get 'phases' 'null')
    [[ "$phases" == "null" || "$phases" == "None" || -z "$phases" ]] && return 0
    local tmpph; tmpph=$(mktemp); echo "$phases" > "$tmpph"
    python3 - "$file" "$PROJECT_ROOT" "$STATE_FILE" "$tmpph" << 'PYPHASE'
import json,sys,os,glob,fnmatch
fp,pr,sf=sys.argv[1],sys.argv[2],sys.argv[3]
ph=json.load(open(sys.argv[4]))
if not isinstance(ph,dict) or not ph.get('enabled'): sys.exit(0)
ds=ph.get('definitions',[]);gs=ph.get('gates',[])
if not ds: sys.exit(0)
st={}
if os.path.isfile(sf):
 try: st=json.load(open(sf))
 except: st={}
def art_ok(d):
 a=d.get('artifact','')
 if not a: return False
 fs=glob.glob(os.path.join(pr,a))
 if not fs: return False
 ms=d.get('artifact_min_size',0);rs=d.get('required_sections',[])
 for f in fs:
  try: c=open(f).read()
  except: continue
  if ms and len(c)<ms: print(f'WARN:phase_incomplete — {f} too small');return False
  for s in rs:
   if s not in c: print(f'WARN:phase_incomplete — missing "{s}"');return False
 return True
cp=st.get('current_phase','')
if not cp:
 cp=ds[0]['id']
 for i,d in enumerate(ds):
  if d.get('skip_if'):
   cp=ds[min(i+1,len(ds)-1)]['id'] if i+1<len(ds) else d['id'];continue
  if glob.glob(os.path.join(pr,d.get('artifact',''))) and art_ok(d):
   cp=ds[i+1]['id'] if i+1<len(ds) else d['id']
  else: cp=d['id'];break
ci=next((i for i,d in enumerate(ds) if d['id']==cp),0)
for g in gs:
 fi=next((i for i,d in enumerate(ds) if d['id']==g.get('from','')),- 1)
 ti=next((i for i,d in enumerate(ds) if d['id']==g.get('to','')),- 1)
 if fi<0 or ti<0: continue
 ta=ds[ti].get('artifact','')
 if ta and ci<=fi:
  if fnmatch.fnmatch(fp,ta) or fnmatch.fnmatch(fp,ta.replace('**/','*').replace('**','*')):
   if g.get('require_artifact') and not art_ok(ds[fi]):
    print('BLOCK:phase — phase "'+cp+'", write to '+fp+' blocked (need '+ds[fi].get('artifact','')+')')
cd=ds[ci];ca=cd.get('artifact','')
if ca and (fnmatch.fnmatch(fp,ca) or fnmatch.fnmatch(fp,ca.replace('**/','*'))):
 if art_ok(cd) and ci+1<len(ds):
  nx=ds[ci+1];st['current_phase']=nx['id']
  if nx.get('skip_if') and ci+2<len(ds): st['current_phase']=ds[ci+2]['id']
  print('PHASE_ADVANCE:'+st['current_phase'])
st.setdefault('current_phase',cp)
json.dump(st,open(sf,'w'),indent=2)
PYPHASE
    rm -f "$tmpph"
}

# === MAIN ===
CFG=$(load_config)

process_output() {
    while IFS= read -r line; do
        case "$line" in
            BLOCK:*) block "${line#BLOCK:}" ;;
            WARN:*) warn "${line#WARN:}" ;;
            PHASE_ADVANCE:*) log_entry "[VR:PHASE] → ${line#PHASE_ADVANCE:}"; echo "$line" ;;
        esac
    done
}

case $ACTION in
    write)
        if echo "$TARGET" | grep -qE '(\.claude/rules/|\.claude/hooks/|CLAUDE\.md)'; then
            log_entry "[VR:REDISCOVERY] $TARGET changed"; bash "$SCRIPT_DIR/vibe-runner-discover.sh" || true
            echo "REDISCOVERY:triggered — tools updated after $TARGET change"
        fi
        FP="${PROJECT_ROOT}/${TARGET}"; [[ "$TARGET" == /* ]] && FP="$TARGET"
        check_file_size "$FP"; check_tdd "$TARGET"; check_secrets "$FP"
        check_design_tokens "$FP"; check_env_in_code "$FP"
        _cc_out=$(run_custom_checks write "$FP" "")
        [[ -n "$_cc_out" ]] && process_output <<< "$_cc_out"
        _ph_out=$(check_phases "$TARGET")
        [[ -n "$_ph_out" ]] && process_output <<< "$_ph_out"
        [[ "$BLOCKED" -eq 0 && -z "$WARNINGS" ]] && pass_ok "write $TARGET"
        [[ -n "$WARNINGS" ]] && echo -e "$WARNINGS"
        [[ "$BLOCKED" -eq 1 ]] && exit 1; exit 0 ;;
    commit)
        check_conventional_commit "$TARGET"; check_no_env_commit; check_diff_size
        _cc_out=$(run_custom_checks commit "" "$TARGET")
        [[ -n "$_cc_out" ]] && process_output <<< "$_cc_out"
        [[ -n "$WARNINGS" ]] && echo -e "$WARNINGS"
        [[ "$BLOCKED" -eq 1 ]] && exit 1; exit 0 ;;
    session_end)
        if [[ -f "$LOG_FILE" ]]; then
            V=$(grep -c "\[VR:CHECK\] ❌" "$LOG_FILE" 2>/dev/null || echo 0)
            P=$(grep -c "\[VR:CHECK\] ✅" "$LOG_FILE" 2>/dev/null || echo 0)
            W=$(grep -c "\[VR:CHECK\] ⚠️" "$LOG_FILE" 2>/dev/null || echo 0)
            R=$(grep -c "\[VR:REDISCOVERY\]" "$LOG_FILE" 2>/dev/null || echo 0)
            log_entry "[VR:SUMMARY] violations=$V passes=$P warnings=$W rediscoveries=$R"
            echo "SESSION_SUMMARY: violations=$V passes=$P warnings=$W rediscoveries=$R"
        else echo "SESSION_SUMMARY: no log file found"; fi ;;
    *) echo "Vibe Runner Check v2.0.0"; echo "Usage: vibe-runner-check.sh {write|commit|session_end} [target]"; exit 1 ;;
esac
