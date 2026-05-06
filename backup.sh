#!/usr/bin/env bash
set -euo pipefail

# Required token scopes: study:read, puzzle:read
# Generate at: https://lichess.org/account/oauth/token

DOWNLOAD_PUZZLES=false
for arg in "$@"; do
    case "${arg}" in
        --puzzles) DOWNLOAD_PUZZLES=true ;;
        *) echo "Unknown option: ${arg}" >&2; echo "Usage: $0 [--puzzles]" >&2; exit 1 ;;
    esac
done

if [[ -z "${LICHESS_TOKEN:-}" ]]; then
    echo "Error: LICHESS_TOKEN environment variable not set" >&2
    exit 1
fi

for cmd in http jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found (httpie and jq required)" >&2
        exit 1
    fi
done

API="https://lichess.org"
AUTH="Authorization:Bearer ${LICHESS_TOKEN}"
DATE=$(date +%Y-%m-%d--%H-%M)
DIR="lichess-backup-${DATE}"
mkdir -p "${DIR}"

echo "Fetching account info..."
USERNAME=$(http GET "${API}/api/account" "${AUTH}" | jq -r '.username')
echo "User: ${USERNAME}"
echo "Output: ${DIR}/"
echo ""

# --- Games ---
echo "Backing up games..."
http --stream GET "${API}/api/games/user/${USERNAME}" \
    "${AUTH}" \
    Accept:application/x-chess-pgn \
    moves==true \
    tags==true \
    clocks==true \
    evals==true \
    opening==true \
    > "${DIR}/games.pgn"
GAME_COUNT=$(grep -c '^\[Event ' "${DIR}/games.pgn" 2>/dev/null || echo 0)
echo "  ${GAME_COUNT} games → games.pgn ($(du -h "${DIR}/games.pgn" | cut -f1))"

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

        http --stream GET "${API}/api/study/${STUDY_ID}.pgn" \
            "${AUTH}" \
            < /dev/null \
            > "${OUTFILE}"

        CHAPTER_COUNT=$(grep -c '^\[Event ' "${OUTFILE}" 2>/dev/null || echo 0)
        echo "  ${STUDY_NAME} → ${CHAPTER_COUNT} chapters ($(du -h "${OUTFILE}" | cut -f1))"
        STUDY_NUM=$((STUDY_NUM + 1))
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

        BATCH=$(http GET "${API}/api/puzzle/activity" "${PUZZLE_ARGS[@]}")

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
echo "Done. Backup in: ${DIR}/"
