#!/usr/bin/env bash
# codex-consensus.sh -- two independent runs over the same subject with two
# different models, and a mechanical split of the findings into agreed and
# divergent.
#
#   bash codex-consensus.sh <request-file> <second-route>
#   bash codex-consensus.sh --merge-only <verdict1> <verdict2> <route1> <route2> <out.json>
#
# Why. The worst failure of any AI review is not the missed bug, it is the
# confidently invented one. "Check every finding against the code" is the right
# rule, but it hands you a list where signal and noise look identical.
# Agreement between two models is not proof -- it is a cheap, honest priority
# order: look at what both saw first.
#
# Requirement: the route must accept a `schema` field and the request must set
# it. The merge works on structured JSON, not on prose.
#
# Exit codes:
#   0  both runs produced a usable verdict and the summary was built
#   1  neither run produced a usable verdict
#   2  bad request
#   3  one of the two is missing or unusable -- the summary is degraded

set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$BIN/codex-run.sh"
REG="$BIN/routes.conf"
# shellcheck source=compat.sh
. "$BIN/compat.sh"

die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }
say() { printf '%s\n' "$1" >&2; }

# A route name is an identifier, and validating it here removes a whole class of
# problem at the door. `grep -F` treats a pattern containing a newline as
# SEVERAL patterns, so a value like $'review\n#' satisfied the "is this route in
# the registry" check, then reached awk as two lines -- one setting the route,
# one a harmless comment -- and the two runs were the same route twice while the
# independence check saw two different strings.
valid_route() { case $1 in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; return 0; }

if [ "${1-}" = --merge-only ]; then
  [ $# -eq 6 ] || die "usage: $0 --merge-only <verdict1> <verdict2> <route1> <route2> <out.json>"
  OUT1=$2; OUT2=$3; ROUTE1=$4; ROUTE2=$5; MERGED=$6
  for r in "$ROUTE1" "$ROUTE2"; do
    valid_route "$r" || die "route label '$r' is not a plain identifier (A-Z a-z 0-9 _ -)"
  done
  # The labels become JSON keys. Equal labels would collapse two objects into
  # one and silently discard half the findings.
  [ "$ROUTE1" = "$ROUTE2" ] && die "both labels are '$ROUTE1' -- they become JSON keys and would overwrite each other"
  RC1=0; RC2=0
  [ -s "$OUT1" ] || RC1=1
  [ -s "$OUT2" ] || RC2=1
  MERGE_ONLY=1
else
  MERGE_ONLY=0
fi

if [ "$MERGE_ONLY" = 0 ]; then
  [ $# -eq 2 ] || die "usage: $0 <request-file> <second-route>"
  REQ=$1; ROUTE2=$2
  valid_route "$ROUTE2" || die "route name '$ROUTE2' is not a plain identifier (A-Z a-z 0-9 _ -)"
  [ -f "$REQ" ] || die "request file not found: $REQ"
  command -v node >/dev/null 2>&1 || die "node is required to merge verdicts" 2

  get_field() { grep -E "^$1=" "$REQ" | head -1 | cut -d= -f2-; }
  ROUTE1=$(get_field route);   [ -n "$ROUTE1" ] || die "request has no route"
  valid_route "$ROUTE1" || die "route name '$ROUTE1' is not a plain identifier (A-Z a-z 0-9 _ -)"
  SCHEMA=$(get_field schema);  [ -n "$SCHEMA" ] || die "consensus needs structured output: set schema= in the request"
  OUTDIR=$(get_field out_dir); [ -d "$OUTDIR" ] || die "out_dir does not exist"
  [ "$ROUTE1" = "$ROUTE2" ] && die "both routes are '$ROUTE1' -- that is a repeat, not an independent check"

  # A route NAME guarantees nothing: `review` and `plan` are both terra/high.
  # Compare the MODEL and EFFORT from the registry, otherwise "consensus of two
  # models" would be a lie exactly where the mechanism is supposed to reduce
  # invented findings.
  [ -f "$REG" ] || die "registry not found: $REG"
  route_field() {
    awk -v r="route: $1" -v f="$2: " '
      $0==r {p=1; next} /^route: /{p=0}
      p && index($0,f)==1 {print substr($0, length(f)+1); exit}' "$REG"
  }
  for R in "$ROUTE1" "$ROUTE2"; do
    grep -qxF "route: $R" "$REG" || die "route '$R' is not in the registry"
  done
  M1="$(route_field "$ROUTE1" model)/$(route_field "$ROUTE1" effort)"
  M2="$(route_field "$ROUTE2" model)/$(route_field "$ROUTE2" effort)"
  [ "$M1" = "$M2" ] && die "routes '$ROUTE1' and '$ROUTE2' use the same $M1 -- no independence, this is a repeat"
  say "consensus: $ROUTE1 ($M1) vs $ROUTE2 ($M2)"

  REQ2=$(compat_mktemp) || die "mktemp failed" 1
  trap 'rm -f "$REQ2"' EXIT HUP INT TERM
  # awk -v, NOT interpolation into a sed program. The earlier form pasted the
  # route name straight into a sed expression; a value containing a newline
  # injected a second command with the `e` flag and executed it. A value passed
  # through -v is data and cannot become program text.
  awk -v r="$ROUTE2" '
    /^route=/   { print "route=" r; next }
    /^subject=/ { print $0 " [consensus: second run]"; next }
                { print }
  ' "$REQ" > "$REQ2" || die "could not build the second request" 1

  # Exactly one call per route. stdout of the runner is the verdict path.
  say "consensus: run 1 -- route $ROUTE1"
  OUT1=$(bash "$RUN" "$REQ")  ; RC1=$?
  say "consensus: run 2 -- route $ROUTE2"
  OUT2=$(bash "$RUN" "$REQ2") ; RC2=$?
fi

if [ "$RC1" -ne 0 ] && [ "$RC2" -ne 0 ]; then
  say "NO VERDICT: both runs failed (rc1=$RC1, rc2=$RC2)"; exit 1
fi

[ "$MERGE_ONLY" = 1 ] || MERGED="$OUTDIR/codex-consensus-$(compat_call_id).json"

node - "$OUT1" "$OUT2" "$RC1" "$RC2" "$ROUTE1" "$ROUTE2" "$MERGED" <<'NODE'
const fs = require("fs");
const [f1, f2, rc1, rc2, r1, r2, out] = process.argv.slice(2);

// A verdict counts only if it is valid JSON AND carries the required field.
// An earlier version silently got null from malformed JSON and still wrote a
// summary with exit 0; two files containing "{}" produced degraded=false,
// zero counts, and prose about two sources agreeing.
// Elements are validated too, not just the array. `{"findings":[{}]}` is a
// well-formed array of nothing; counting it as a usable verdict produced
// "two sources agree" over zero content.
const usableFinding = f =>
  f && typeof f === "object" && !Array.isArray(f) &&
  (f.file == null || typeof f.file === "string") &&
  (f.line == null || typeof f.line === "number") &&
  typeof f.claim === "string" && f.claim.trim() !== "";

// Pair scoring below is n*m. 500 findings a side is far past any real verdict
// and still only 250k pairs; 2000 would have been four million objects built,
// re-tokenised and sorted with no timeout anywhere.
const MAX_FINDINGS = 500;
const load = (p, rc) => {
  if (rc !== "0") return null;
  let o;
  try { o = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { return null; }
  if (!o || typeof o !== "object" || !Array.isArray(o.findings)) return null;
  if (o.findings.length > MAX_FINDINGS) {
    console.error(`  refusing a verdict with ${o.findings.length} findings (limit ${MAX_FINDINGS})`);
    return null;
  }
  // EVERY element must be usable. Dropping the bad ones and keeping the rest
  // silently shrank the verdict while still reporting it as a full source --
  // a partial verdict presented as a complete one is the failure mode this
  // whole tool exists to prevent.
  if (!o.findings.every(usableFinding)) {
    console.error(`  refusing a verdict: ${o.findings.filter(f => !usableFinding(f)).length} of ${o.findings.length} findings are malformed`);
    return null;
  }
  // Input must never carry the internal cache key: base() trusted an existing
  // __k, so a crafted verdict could give findings in different files the same
  // key and force them to be reported as agreed.
  for (const f of o.findings) delete f.__k;
  return o;
};
const a = load(f1, rc1), b = load(f2, rc2);
if (!a && !b) {
  console.error("  no usable verdict: invalid JSON or no findings array");
  process.exit(1);
}

// Match on the FULL normalised path, not the basename: src/config.js and
// tests/config.js are different files. A finding with no file gets a unique key
// so two unknowns never collapse into one.
// No .toLowerCase(): on a case-sensitive filesystem Foo.js and foo.js are two
// different files, and folding them together manufactures agreement.
let anon = 0;
const pathKey = f => {
  if (!f.file) return "<no file>#" + (++anon);
  return f.file.replace(/\\/g, "/").replace(/^.*?((?:[^/]+\/)*[^/]+)$/, "$1");
};
// A Map, not a property on the object: nothing that came from the input file
// can pre-seed this cache.
const keyCache = new Map();
const base = f => {
  if (!keyCache.has(f)) keyCache.set(f, pathKey(f));
  return keyCache.get(f);
};

// Stop words carry no topic. Without this list a single shared "never" or
// "should" was enough incidental similarity that, added to a line-number
// match, two entirely unrelated findings crossed the threshold and were
// reported as agreement.
const STOP = new Set(("never always when this that with from will does than then there their been have "
  + "more most some other which while would could should must also into over under about after before "
  + "these those such only very much many each both same because during without within through").split(" "));
// \p{L}\p{N} rather than [a-z0-9]: findings are not always written in English,
// and an ASCII-only class would reduce a non-Latin finding to zero words, which
// scores 0 against everything and silently reports every pair as divergent.
const words = s => (s || "").toLowerCase()
  .replace(/[^\p{L}\p{N}]+/gu, " ").split(/\s+/)
  .filter(w => w.length > 3 && !STOP.has(w));

// Overlap coefficient, not Jaccard: two descriptions of the same defect differ
// in length and phrasing, and Jaccard punishes that by inflating the union.
const overlap = (A, B) => {
  const sa = new Set(A), sb = new Set(B);
  if (!sa.size || !sb.size) return 0;
  let inter = 0; for (const w of sa) if (sb.has(w)) inter++;
  return inter / Math.min(sa.size, sb.size);
};

// Meaning is a GATE, not merely a weight. Below MIN_SIM the pair is refused
// outright, however close the line numbers are -- so line proximity can only
// rank candidates that already share subject matter, never create a pair.
const MIN_SIM = 0.10;
const THRESHOLD = 0.30;
const score = (x, y) => {
  if (base(x) !== base(y)) return 0;
  const sim = overlap(words(x.claim + " " + x.why), words(y.claim + " " + y.why));
  if (sim < MIN_SIM) return 0;
  const near = (x.line != null && y.line != null)
    ? Math.max(0, 1 - Math.abs(Number(x.line) - Number(y.line)) / 10) : 0.3;
  return 0.75 * sim + 0.25 * near;
};

const fa = (a && a.findings) || [], fb = (b && b.findings) || [];
const agreed = [], onlyA = [], onlyB = [];

// Global matching: score every pair, sort descending, assign strongest first.
// A left-to-right greedy pass could hand the only candidate to a weak pair and
// starve the strong one.
const pairs = [];
fa.forEach((x, i) => fb.forEach((y, j) => {
  const s = score(x, y);
  if (s >= THRESHOLD) pairs.push({ i, j, s });
}));
pairs.sort((p, q) => q.s - p.s);
const usedA = new Set(), usedB = new Set();
for (const p of pairs) {
  if (usedA.has(p.i) || usedB.has(p.j)) continue;
  usedA.add(p.i); usedB.add(p.j);
  agreed.push({ similarity: Number(p.s.toFixed(2)), [r1]: fa[p.i], [r2]: fb[p.j] });
}
fa.forEach((x, i) => { if (!usedA.has(i)) onlyA.push(x); });
fb.forEach((y, j) => { if (!usedB.has(j)) onlyB.push(y); });

const degraded = !a || !b;
const res = {
  consensus: {
    routes: [r1, r2],
    degraded,
    note: degraded
      ? "One run produced no usable verdict -- this summary has a single source and there is no agreement in it."
      : "Agreement between two models from the SAME family and vendor. Treat it as a priority order, not as proof: a shared training bias produces a shared blind spot.",
    counts: { agreed: agreed.length, only_first: onlyA.length, only_second: onlyB.length },
  },
  agreed,                                     // both saw it -- look here first
  divergent: { [r1]: onlyA, [r2]: onlyB },    // one saw it -- check carefully
  coverage: { [r1]: a && a.coverage, [r2]: b && b.coverage },
  overall:  { [r1]: a && a.overall,  [r2]: b && b.overall },
};
fs.writeFileSync(out, JSON.stringify(res, null, 2));
console.error(`  agreed: ${agreed.length}, only ${r1}: ${onlyA.length}, only ${r2}: ${onlyB.length}`);
NODE
NRC=$?
{ [ $NRC -eq 0 ] && [ -s "$MERGED" ]; } || { say "merge failed: no usable verdict"; exit 1; }

say "summary: $MERGED"
printf '%s\n' "$MERGED"

# Exit 3 covers both a failed run and a run whose verdict was unusable: the
# summary is degraded and the exit code must say so rather than report success.
# readFileSync, not require: require() resolves a relative path WITHOUT a
# leading ./ as a module name, so a perfectly good summary written to
# `out/result.json` threw, was caught, and reported degraded with exit 3.
DEG=$(node -e 'try{const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).consensus.degraded))}catch(e){process.stdout.write("true")}' "$MERGED")
{ [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$DEG" = false ]; } || exit 3
exit 0
