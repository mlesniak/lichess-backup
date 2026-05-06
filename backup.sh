#!/usr/bin/env bash
set -euo pipefail

# Required token scopes: study:read, puzzle:read
# Generate at: https://lichess.org/account/oauth/token

DOWNLOAD_PUZZLES=false
KEEP=0
ERRORS=0

usage() {
    echo "Usage: $0 [--puzzles] [--keep N]" >&2
    echo "  --puzzles   Download puzzle activity history" >&2
    echo "  --keep N    Keep only N most recent backups (0 = keep all)" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --puzzles) DOWNLOAD_PUZZLES=true; shift ;;
        --keep)    [[ -z "${2:-}" ]] && usage; KEEP="$2"; shift 2 ;;
        *)         echo "Unknown option: $1" >&2; usage ;;
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
DATE=$(date +%Y-%m-%d--%H-%M)
DIR="lichess-backup-${DATE}"
mkdir -p "${DIR}"

# Cleanup partial backup on unexpected exit
trap 'if [[ ${ERRORS} -gt 0 ]]; then echo ""; echo "Backup completed with ${ERRORS} error(s) — archive skipped." >&2; exit 2; fi' EXIT

echo "Fetching account info..."
USERNAME=$(http GET "${API}/api/account" "${AUTH}" | jq -r '.username')
echo "User: ${USERNAME}"
echo "Output: ${DIR}/"
echo ""

# --- Games ---
echo "Backing up games..."
if http --stream GET "${API}/api/games/user/${USERNAME}" \
    "${AUTH}" \
    Accept:application/x-chess-pgn \
    moves==true \
    tags==true \
    clocks==true \
    evals==true \
    opening==true \
    > "${DIR}/games.pgn"; then
    GAME_COUNT=$(grep -c '^\[Event ' "${DIR}/games.pgn" 2>/dev/null || echo 0)
    echo "  ${GAME_COUNT} games → games.pgn ($(du -h "${DIR}/games.pgn" | cut -f1))"
else
    echo "  ERROR: games download failed" >&2
    ERRORS=$((ERRORS + 1))
fi

# --- Studies (one file per study) ---
echo "Backing up studies..."
STUDIES_DIR="${DIR}/studies"
mkdir -p "${STUDIES_DIR}"

STUDY_LIST=$(http GET "${API}/api/study/by/${USERNAME}" "${AUTH}" Accept:application/x-ndjson)

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

# --- Compress ---
echo ""
echo "Compressing..."
ARCHIVE="${DIR}.tar.gz"
tar czf "${ARCHIVE}" "${DIR}/"
rm -rf "${DIR}"
echo "  $(du -h "${ARCHIVE}" | cut -f1) → ${ARCHIVE}"

# --- Cleanup old backups ---
if [[ "${KEEP}" -gt 0 ]]; then
    mapfile -t OLD < <(ls -t lichess-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)))
    if [[ ${#OLD[@]} -gt 0 ]]; then
        echo "Removing ${#OLD[@]} old backup(s)..."
        rm -f "${OLD[@]}"
    fi
fi

echo ""
if [[ ${ERRORS} -gt 0 ]]; then
    echo "Done with ${ERRORS} error(s). Archive: ${ARCHIVE}" >&2
    ERRORS=0  # disarm trap, report via exit code below
    exit 2
fi
echo "Done. Archive: ${ARCHIVE}"
ERRORS=0  # disarm trap — clean exit
