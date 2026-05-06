#!/usr/bin/env bash
set -euo pipefail

# Required token scopes: study:read, puzzle:read
# Generate at: https://lichess.org/account/oauth/token

DOWNLOAD_PUZZLES=false
KEEP=0
COMPRESS=true
ERRORS=0
STATE_FILE="${HOME}/.lichess-backup-state"

usage() {
    echo "Usage: $0 [--puzzles] [--keep N] [--no-compress]" >&2
    echo "  --puzzles      Download puzzle activity history" >&2
    echo "  --keep N       Keep only N most recent backups (0 = keep all)" >&2
    echo "  --no-compress  Skip compression, keep raw directory" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --puzzles)     DOWNLOAD_PUZZLES=true; shift ;;
        --keep)        [[ -z "${2:-}" ]] && usage; KEEP="$2"; shift 2 ;;
        --no-compress) COMPRESS=false; shift ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -z "${LICHESS_TOKEN:-}" ]]; then
    echo "Error: LICHESS_TOKEN environment variable not set" >&2
    exit 1
fi

for cmd in http jq tar; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found" >&2
        exit 1
    fi
done

API="https://lichess.org"
AUTH="Authorization:Bearer ${LICHESS_TOKEN}"

# --- Token scope check ---
echo "Checking token scopes..."
TOKEN_INFO=$(echo "${LICHESS_TOKEN}" | http POST "${API}/api/token/test" Content-Type:text/plain 2>/dev/null || true)
SCOPES=$(echo "${TOKEN_INFO}" | jq -r 'to_entries[0].value.scopes // ""')
WARNINGS=0
if [[ "${SCOPES}" != *"study:read"* ]]; then
    echo "  Warning: study:read scope missing — private studies will be skipped" >&2
    WARNINGS=$((WARNINGS + 1))
fi
if [[ "${DOWNLOAD_PUZZLES}" == true && "${SCOPES}" != *"puzzle:read"* ]]; then
    echo "  Warning: puzzle:read scope missing — puzzle download will be empty" >&2
    WARNINGS=$((WARNINGS + 1))
fi
[[ ${WARNINGS} -eq 0 ]] && echo "  OK"

DATE=$(date +%Y-%m-%d--%H-%M)
DIR="lichess-backup-${DATE}"
mkdir -p "${DIR}"

trap 'if [[ ${ERRORS} -gt 0 ]]; then echo ""; echo "Backup completed with ${ERRORS} error(s)." >&2; exit 2; fi' EXIT

echo "Fetching account info..."
USERNAME=$(http GET "${API}/api/account" "${AUTH}" | jq -r '.username')
echo "User: ${USERNAME}"
echo "Output: ${DIR}/"
echo ""

# --- http wrapper with 429 retry ---
http_with_retry() {
    local attempt=0
    while true; do
        attempt=$((attempt + 1))
        local status
        status=$(http --check-status "$@" 2>&1) && return 0 || true
        if echo "${status}" | grep -q "429"; then
            echo "  Rate limited — waiting 60s (attempt ${attempt})..." >&2
            sleep 60
            [[ ${attempt} -ge 3 ]] && { echo "  ERROR: still rate limited after 3 attempts" >&2; return 1; }
        else
            return 1
        fi
    done
}

# --- Games (incremental) ---
echo "Backing up games..."
SINCE_PARAM=""
LAST_TS=""
if [[ -f "${STATE_FILE}" ]]; then
    LAST_TS=$(grep "^last_game_ts=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "${LAST_TS}" ]]; then
        SINCE_PARAM="since==${LAST_TS}"
        echo "  Incremental: fetching games since $(date -d @$((LAST_TS / 1000)) '+%Y-%m-%d %H:%M' 2>/dev/null || echo "${LAST_TS}ms")"
    fi
fi

if http --stream GET "${API}/api/games/user/${USERNAME}" \
    "${AUTH}" \
    Accept:application/x-chess-pgn \
    moves==true \
    tags==true \
    clocks==true \
    evals==true \
    opening==true \
    ${SINCE_PARAM} \
    > "${DIR}/games.pgn"; then
    GAME_COUNT=$(grep -c '^\[Event ' "${DIR}/games.pgn" 2>/dev/null || echo 0)
    echo "  ${GAME_COUNT} games → games.pgn ($(du -h "${DIR}/games.pgn" | cut -f1))"
    # Save timestamp for next incremental run (now in ms)
    NEW_TS=$(date +%s%3N)
    if [[ -f "${STATE_FILE}" ]]; then
        sed -i '/^last_game_ts=/d' "${STATE_FILE}"
    fi
    echo "last_game_ts=${NEW_TS}" >> "${STATE_FILE}"
else
    echo "  ERROR: games download failed" >&2
    ERRORS=$((ERRORS + 1))
fi

# --- Studies (one file per study) ---
echo "Backing up studies..."
STUDIES_DIR="${DIR}/studies"
mkdir -p "${STUDIES_DIR}"

STUDY_LIST=$(http GET "${API}/api/study/by/${USERNAME}" "${AUTH}" Accept:application/x-ndjson || true)

if [[ -z "${STUDY_LIST}" ]]; then
    echo "  0 studies (check study:read scope on token)"
else
    STUDY_NUM=0
    while IFS= read -r line; do
        STUDY_ID=$(echo "${line}" | jq -r '.id')
        STUDY_NAME=$(echo "${line}" | jq -r '.name' | tr '/' '-' | tr ' ' '_' | tr -cd '[:alnum:]_.-')
        OUTFILE="${STUDIES_DIR}/${STUDY_NAME}-${STUDY_ID}.pgn"

        if http --stream GET "${API}/api/study/${STUDY_ID}.pgn" \
            "${AUTH}" \
            < /dev/null \
            > "${OUTFILE}"; then
            CHAPTER_COUNT=$(grep -c '^\[Event ' "${OUTFILE}" 2>/dev/null || echo 0)
            echo "  ${STUDY_NAME} → ${CHAPTER_COUNT} chapters ($(du -h "${OUTFILE}" | cut -f1))"
            STUDY_NUM=$((STUDY_NUM + 1))
        else
            echo "  ERROR: study ${STUDY_NAME} (${STUDY_ID}) download failed" >&2
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "${STUDY_LIST}"

    echo "  ${STUDY_NUM} studies → studies/"
fi

# --- Puzzles (paginated, opt-in via --puzzles) ---
if [[ "${DOWNLOAD_PUZZLES}" == true ]]; then
    echo "Backing up puzzle activity..."
    PUZZLE_FILE="${DIR}/puzzles.ndjson"
    > "${PUZZLE_FILE}"
    LAST_DATE=""
    TOTAL=0

    while true; do
        PUZZLE_ARGS=("${AUTH}" Accept:application/x-ndjson max==1000)
        [[ -n "${LAST_DATE}" ]] && PUZZLE_ARGS+=("before==${LAST_DATE}")

        BATCH=$(http GET "${API}/api/puzzle/activity" "${PUZZLE_ARGS[@]}" || true)

        if [[ -z "${BATCH}" ]]; then
            break
        fi

        COUNT=$(echo "${BATCH}" | wc -l)
        echo "${BATCH}" >> "${PUZZLE_FILE}"
        TOTAL=$((TOTAL + COUNT))

        if [[ ${COUNT} -lt 1000 ]]; then
            break
        fi

        LAST_DATE=$(echo "${BATCH}" | tail -1 | jq -r '.date')
        echo "  ${TOTAL} puzzles so far..."
    done

    if [[ "${TOTAL}" -eq 0 ]]; then
        echo "  0 puzzles → puzzles.ndjson (check puzzle:read scope on token)"
    else
        echo "  ${TOTAL} puzzle activities → puzzles.ndjson ($(du -h "${PUZZLE_FILE}" | cut -f1))"
    fi
else
    echo "Skipping puzzles (pass --puzzles to include)"
fi

echo ""

# --- Compress ---
if [[ "${COMPRESS}" == true ]]; then
    echo "Compressing..."
    ARCHIVE="${DIR}.tar.gz"
    tar czf "${ARCHIVE}" "${DIR}/"
    rm -rf "${DIR}"
    echo "  $(du -h "${ARCHIVE}" | cut -f1) → ${ARCHIVE}"
    OUTPUT="${ARCHIVE}"
else
    OUTPUT="${DIR}/"
fi

# --- Cleanup old backups ---
if [[ "${KEEP}" -gt 0 ]]; then
    if [[ "${COMPRESS}" == true ]]; then
        mapfile -t OLD < <(ls -t lichess-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)))
    else
        mapfile -t OLD < <(ls -dt lichess-backup-*/ 2>/dev/null | tail -n +$((KEEP + 1)))
    fi
    if [[ ${#OLD[@]} -gt 0 ]]; then
        echo "Removing ${#OLD[@]} old backup(s)..."
        rm -rf "${OLD[@]}"
    fi
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo "Done with ${ERRORS} error(s). Output: ${OUTPUT}" >&2
    ERRORS=0
    exit 2
fi
echo "Done. Output: ${OUTPUT}"
ERRORS=0
