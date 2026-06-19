#!/bin/bash
# ralph — autonomous task loop for zoidformer.
#
# Usage:
#   ./scripts/ralph.sh                          # multi-phase loop
#   ./scripts/ralph.sh 0.1.3                    # single task
#   ./scripts/ralph.sh --minutes=30             # time-bounded
#   ./scripts/ralph.sh --dry-run               # preview next action
#
# Stopping ralph:
#   touch scripts/STOP.md
#   kill -TERM $(cat /tmp/ralph.pid)
#   Ctrl-C

set -e

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
SKILL="$REPO_ROOT/skills/ralph.md"
LOG="$REPO_ROOT/docs/ralph-log.md"
ERRLOG="$REPO_ROOT/docs/ralph-errors.log"

# Agent configuration — override via env
TASK_PLANNING_AGENT="${TASK_PLANNING_AGENT:-opencode/deepseek-v4-flash-free}"
BASIC_DEV_AGENT="${BASIC_DEV_AGENT:-opencode/deepseek-v4-flash-free}"
MID_DEV_AGENT="${MID_DEV_AGENT:-opencode/deepseek-v4-flash-free}"
PRO_DEV_AGENT="${PRO_DEV_AGENT:-opencode/deepseek-v4-flash-free}"
TASK_REVIEW_AGENT="${TASK_REVIEW_AGENT:-opencode/deepseek-v4-flash-free}"
RELEASE_REVIEW_AGENT="${RELEASE_REVIEW_AGENT:-opencode/deepseek-v4-flash-free}"
MAJOR_RELEASE_REVIEW_AGENT="${MAJOR_RELEASE_REVIEW_AGENT:-opencode/deepseek-v4-flash-free}"
ARCHITECT_AGENT="${ARCHITECT_AGENT:-opencode/deepseek-v4-flash-free}"

CAVEMAN="${CAVEMAN:-1}"
CAVEMAN_LEVEL="${CAVEMAN_LEVEL:-full}"

BASE_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"

BOLD=$(tput bold 2>/dev/null || true)
CYAN=$(tput setaf 6 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

log()  { printf '%s\n' "${CYAN}[ralph]${RESET} $*"; }
good() { printf '%s\n' "${GREEN}[ralph]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[ralph]${RESET} $*"; }
die()  { printf '%s\n' "${RED}[ralph]${RESET} $*" >&2; exit 1; }

# Argument parsing
SINGLE_TASK=""
DURATION_SECS=0
DRY_RUN=0

for _arg in "$@"; do
    case "$_arg" in
        --minutes=*)
            _mins="${_arg#--minutes=}"
            case "$_mins" in ''|*[!0-9]*) die "--minutes requires a positive integer";; esac
            DURATION_SECS=$((DURATION_SECS + _mins * 60))
            ;;
        --hours=*)
            _hrs="${_arg#--hours=}"
            case "$_hrs" in ''|*[!0-9]*) die "--hours requires a positive integer";; esac
            DURATION_SECS=$((DURATION_SECS + _hrs * 3600))
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -*) die "Unknown flag: $_arg";;
        *)
            [ -z "$SINGLE_TASK" ] || die "Only one task id allowed"
            SINGLE_TASK="$_arg"
            ;;
    esac
done

START_TIME="$(date +%s)"
DEADLINE=0
[ "$DURATION_SECS" -gt 0 ] && DEADLINE=$((START_TIME + DURATION_SECS))

# Sanity checks
[ -f "$SKILL" ] || die "skill file missing: $SKILL"
command -v opencode >/dev/null 2>&1 || die "opencode CLI not found in PATH"

case "$BASE_BRANCH" in
    main) MINOR_VERSION="" ;;
    release/*)
        MINOR_VERSION="${BASE_BRANCH#release/}"
        case "$MINOR_VERSION" in
            *[!0-9.]* | "") die "invalid minor version: $MINOR_VERSION" ;;
        esac ;;
    *) die "must be on main or release/X.Y, not $BASE_BRANCH" ;;
esac

if [ -n "$SINGLE_TASK" ] && [ "$BASE_BRANCH" != "main" ]; then
    TASK_MINOR="$(printf '%s' "$SINGLE_TASK" | sed 's/\.[0-9]*$//')"
    [ "$TASK_MINOR" = "$MINOR_VERSION" ] || die "Task $SINGLE_TASK not in $BASE_BRANCH"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run: no changes."
    exit 0
fi

cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
    die "working tree is dirty — commit or stash first"
fi

# ERR trap — log unexpected failures
trap '_rc=$?; warn "Unhandled error (exit $_rc) — check $ERRLOG"; log_session "FATAL: unhandled error (exit $_rc)"; exit $_rc' ERR

printf '%d\n' $$ > /tmp/ralph.pid

RALPH_SESSION_ID="$(date +%s)"

# ── helper: run an agent ──────────────────────────────────────────────────────
# BUG FIX (vs zoidborg-agent): opencode failure must NOT trigger set -e.
# The `|| true` on the assignment prevents set -e from exiting on a bad exit code
# from opencode. We capture exit code manually and warn, but don't die — the
# caller decides whether to abort based on the output content.
agent_output() {
    _agent="$1"
    _prompt="$2"
    _label="${3:-agent}"

    if [ "$CAVEMAN" = "1" ]; then
        _caveman_prefix="Respond like a smart caveman. Terse. No fluff.
Drop articles, hedging. Fragments OK. Technical terms exact. Caveman level: $CAVEMAN_LEVEL.
"
    else
        _caveman_prefix=""
    fi

    _full_prompt="$(printf '%s\n%s' "$_caveman_prefix" "$_prompt")"
    printf '\n## %s — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_label" >> "$ERRLOG"

    # NOTE: `|| true` is intentional — prevents set -e from killing the script
    # when opencode returns non-zero (network error, rate limit, model refusal, etc).
    # We log the exit code and warn, but let callers handle empty/bad output.
    _output="$(opencode run -m "$_agent" "$_full_prompt" 2>>"$ERRLOG")" || true
    _exit_code=$?
    printf 'exit_code=%s\n' "$_exit_code" >> "$ERRLOG"
    if [ "$_exit_code" -ne 0 ]; then
        warn "$_label failed (exit $_exit_code). Output may be empty. See $ERRLOG"
    fi
    printf '%s\n' "$_output"
}

task_num_from_line() {
    printf '%s\n' "$1" | sed -n 's/.*\[ \] `\([0-9.]*\)`.*/\1/p'
}

all_todo_lines() {
    for _f in "$REPO_ROOT/docs"/todo-v*.md; do
        [ -f "$_f" ] && cat "$_f" || true
    done
}

task_block() {
    all_todo_lines | awk -v tid="$1" '
        BEGIN { pat = "^- \\[.\\] `" tid "`" }
        $0 ~ pat                    { found=1; print; next }
        found && /^- \[.\] `[0-9]/  { exit }
        found                       { print }
    '
}

log_session() {
    _entry="$1"
    printf '\n## %s — %s\n\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RALPH_SESSION_ID" "$_entry" >> "$LOG"
}

# ── main loop ────────────────────────────────────────────────────────────────
log "ralph started on $BASE_BRANCH (session $RALPH_SESSION_ID)"
log_session "ralph started on $BASE_BRANCH"

while true; do
    # Time check
    if [ "$DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
        good "Time limit reached. Stopping."
        log_session "stopped: time limit reached"
        exit 0
    fi

    # Stop sentinel
    if [ -f "$REPO_ROOT/scripts/STOP.md" ]; then
        good "STOP.md found. Stopping."
        rm -f "$REPO_ROOT/scripts/STOP.md"
        log_session "stopped: STOP.md sentinel"
        exit 0
    fi

    # On main: find next phase and switch to its release branch
    if [ "$BASE_BRANCH" = "main" ]; then
        NEXT_TASK="$(all_todo_lines | grep -m1 '\[ \] `[0-9]' | sed 's/.*`\([0-9.]*\)`.*/\1/')" || true
        if [ -z "$NEXT_TASK" ]; then
            good "No open tasks. All phases complete."
            log_session "all tasks complete"
            exit 0
        fi
        NEXT_MINOR="$(printf '%s' "$NEXT_TASK" | sed 's/\.[0-9]*$//')"
        if ! git show-ref --verify "refs/heads/release/$NEXT_MINOR" >/dev/null 2>&1; then
            git checkout -b "release/$NEXT_MINOR" main
            log "created release/$NEXT_MINOR from main"
        else
            git checkout "release/$NEXT_MINOR"
        fi
        BASE_BRANCH="release/$NEXT_MINOR"
        MINOR_VERSION="$NEXT_MINOR"
        log "switched to $BASE_BRANCH"
        log_session "switched to $BASE_BRANCH for phase $MINOR_VERSION"
        continue
    fi

    # Find next open task in this phase
    NEXT_LINE="$(all_todo_lines | grep -m1 '\[ \] `'"$MINOR_VERSION"'\.')" || true
    if [ -z "$NEXT_LINE" ]; then
        log "All tasks in $MINOR_VERSION complete. Running phase review."
        log_session "phase $MINOR_VERSION review starting"

        TASK_LIST="$(all_todo_lines | grep '`'"$MINOR_VERSION"'\.')" || true

        REVIEW_PROMPT="Phase $MINOR_VERSION review for zoidformer.

Completed tasks:
$TASK_LIST

Check:
1. All tasks meet acceptance criteria.
2. CHANGELOG.md has unreleased entries for this phase.
3. docs/memory.md has entries for each task.
4. cargo check passes.
5. If major release (X.0), note human sign-off required.

End your response with exactly one of these two lines:
VERDICT: PASS
VERDICT: FAIL — <reason>

IMPORTANT: Do NOT use any tools. Only produce text output."

        REVIEW_OUTPUT="$(agent_output "$RELEASE_REVIEW_AGENT" "$REVIEW_PROMPT" "phase-review-$MINOR_VERSION")"
        printf '%s\n' "$REVIEW_OUTPUT"

        if printf '%s\n' "$REVIEW_OUTPUT" | grep -qi 'VERDICT: FAIL'; then
            warn "Phase review FAILED. Fix issues and rerun."
            log_session "phase $MINOR_VERSION review FAILED"
            exit 1
        fi

        good "Phase $MINOR_VERSION review PASSED."

        git checkout main
        git merge --no-ff "release/$MINOR_VERSION" -m "chore: merge phase $MINOR_VERSION"
        git branch -d "release/$MINOR_VERSION"
        git push origin main
        good "Merged $MINOR_VERSION to main."
        log_session "phase $MINOR_VERSION merged to main"

        case "$MINOR_VERSION" in
            *0) log "Major release — RC required. Human sign-off before tagging."
                log_session "major release RC required for $MINOR_VERSION"
                exit 0
                ;;
        esac

        BASE_BRANCH="main"
        continue
    fi

    TASK_NUM="$(task_num_from_line "$NEXT_LINE")"
    log "Next task: $TASK_NUM"

    git checkout -b "task-$TASK_NUM" "release/$MINOR_VERSION"
    log "created task-$TASK_NUM from release/$MINOR_VERSION"

    TASK_DESC="$(all_todo_lines | grep -m1 "\[ \] \`$TASK_NUM\`" | sed 's/.*`[0-9.]*` //')"
    TASK_BLOCK="$(task_block "$TASK_NUM")"
    TASK_DIFFICULTY="$(printf '%s\n' "$TASK_BLOCK" | grep '\*\*Difficulty:\*\*' | sed 's/.*\*\*Difficulty:\*\* *//' | tr -d ' ')"
    TASK_OVERRIDE_MODEL="$(printf '%s\n' "$TASK_BLOCK" | grep '\*\*Model:\*\*' | sed 's/.*\*\*Model:\*\* *//' | tr -d ' ')"
    log "Task: $TASK_DESC (difficulty: ${TASK_DIFFICULTY:-unknown})"

    case "$TASK_OVERRIDE_MODEL" in
        PRO_DEV_AGENT) IMPL_AGENT="$PRO_DEV_AGENT" ;;
        ARCHITECT_AGENT) IMPL_AGENT="$ARCHITECT_AGENT" ;;
        *) case "$TASK_DIFFICULTY" in
               High|VeryHigh) IMPL_AGENT="$PRO_DEV_AGENT" ;;
               *) IMPL_AGENT="$MID_DEV_AGENT" ;;
           esac ;;
    esac
    log "Implementation agent: $IMPL_AGENT"

    LEARNINGS_HASH_BEFORE="$(md5sum "$REPO_ROOT/docs/learnings.md" 2>/dev/null | cut -d' ' -f1 || echo '')"

    # Plan
    log "Planning..."
    PLAN_PROMPT="Task $TASK_NUM for zoidformer: $TASK_DESC

Full task spec:
$TASK_BLOCK

Produce a numbered implementation plan. Each step: file path, what changes.
Note any new crates needed.

IMPORTANT: Do NOT use any tools. Only produce text output."

    PLAN="$(agent_output "$TASK_PLANNING_AGENT" "$PLAN_PROMPT" "plan-$TASK_NUM")"
    printf 'Plan:\n%s\n' "$PLAN"
    log_session "task $TASK_NUM plan:\n$PLAN"

    # Implement
    IMPL_PROMPT="Task $TASK_NUM: $TASK_DESC

Full task spec:
$TASK_BLOCK

Implementation plan:
$PLAN

Implement each step. Use tools (Read, Write, Edit, Bash) as needed.
Follow AGENTS.md rules strictly:
- No unwrap/expect/panic/todo! in production paths
- cargo check --workspace must pass after each step
- After all steps, update:
  - docs/todo-vN.md (mark task [x])
  - docs/memory.md (Decision/Context/Impact/Follow-up)
  - docs/learnings.md (if new durable insight)
  - CHANGELOG.md (unreleased entry)"

    log "Implementing with $IMPL_AGENT..."
    IMPL_OUTPUT="$(agent_output "$IMPL_AGENT" "$IMPL_PROMPT" "impl-$TASK_NUM")"
    printf '%s\n' "$IMPL_OUTPUT"

    # Self-review
    log "Self-review..."
    REVIEW_PROMPT="Review task $TASK_NUM: $TASK_DESC

Diff stat:
$(git diff "release/$MINOR_VERSION" --stat)

1. Does code compile? (cargo check)
2. Any unwrap/expect/panic/todo! in production?
3. Error paths handled?
4. Safety comments on unsafe/FFI?
5. Tests adequate?

List issues by severity: blocker/warning/nit.
End your response with exactly one of:
VERDICT: PASS
VERDICT: NEEDS_FIX — <blocker description>

IMPORTANT: Do NOT use any tools. Only produce text output."

    REVIEW="$(agent_output "$TASK_REVIEW_AGENT" "$REVIEW_PROMPT" "review-$TASK_NUM")"
    printf '%s\n' "$REVIEW"

    if printf '%s\n' "$REVIEW" | grep -qi 'VERDICT: NEEDS_FIX'; then
        warn "Review found blockers. Fixing..."
        FIX_PROMPT="Fix blockers for task $TASK_NUM:

$REVIEW

Current diff:
$(git diff)"
        FIX_OUTPUT="$(agent_output "$ARCHITECT_AGENT" "$FIX_PROMPT" "fix-review-$TASK_NUM")"
        printf '%s\n' "$FIX_OUTPUT"
    fi

    # Pre-commit gate
    log "Running pre-commit checks..."
    cargo fmt --check || cargo fmt
    cargo clippy --workspace --all-targets --all-features -- -D warnings || {
        warn "Clippy failed. Fixing..."
        FIX_OUTPUT="$(agent_output "$ARCHITECT_AGENT" "Fix clippy warnings:\n$(git diff)" "fix-clippy-$TASK_NUM")"
        printf '%s\n' "$FIX_OUTPUT"
        cargo clippy --workspace --all-targets --all-features -- -D warnings || die "Clippy still failing"
    }
    cargo test --workspace || die "Tests failing"

    # Commit
    git add -A
    git commit -m "feat: $TASK_NUM — $TASK_DESC"
    good "Committed $TASK_NUM"

    # Merge back to release branch
    git checkout "release/$MINOR_VERSION"
    git merge --no-ff "task-$TASK_NUM" -m "chore: merge task-$TASK_NUM"
    git branch -d "task-$TASK_NUM"
    good "Merged task-$TASK_NUM into release/$MINOR_VERSION"
    log_session "task $TASK_NUM completed and merged"

    # Learnings-triggered re-architecture check
    LEARNINGS_HASH_AFTER="$(md5sum "$REPO_ROOT/docs/learnings.md" 2>/dev/null | cut -d' ' -f1 || echo '')"
    if [ -n "$LEARNINGS_HASH_BEFORE" ] && [ "$LEARNINGS_HASH_BEFORE" != "$LEARNINGS_HASH_AFTER" ]; then
        log "New learnings — running architecture review..."
        NEW_LEARNINGS="$(git diff HEAD~1 -- docs/learnings.md 2>/dev/null | grep '^+[^+]' || true)"
        REARCH_PROMPT="New learnings added during task $TASK_NUM:

$NEW_LEARNINGS

Review:
1. Architecture updates needed?
2. Any todo tasks now blocked, obsolete, or misordered?
3. AGENTS.md invariants outdated?
4. New invariants implied?

If changes needed: make minimal targeted edits. Update memory.md.
If no changes: output the single word UNCHANGED.

IMPORTANT: Do NOT use any tools. Only produce text output."

        REARCH_OUTPUT="$(agent_output "$ARCHITECT_AGENT" "$REARCH_PROMPT" "rearch-$TASK_NUM")"
        printf '%s\n' "$REARCH_OUTPUT"
        log_session "re-arch review after task $TASK_NUM:\n$REARCH_OUTPUT"

        if ! printf '%s\n' "$REARCH_OUTPUT" | grep -qi 'unchanged'; then
            if ! git diff --quiet; then
                git add docs/architecture.md AGENTS.md docs/todo.md docs/todo-v*.md docs/memory.md 2>/dev/null || true
                git commit -m "chore: re-arch after task $TASK_NUM learnings" || true
            fi
        fi
    fi

    if [ -n "$SINGLE_TASK" ]; then
        good "Single task $TASK_NUM complete. Stopping."
        exit 0
    fi
done
