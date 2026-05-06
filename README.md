# lichess-backup

Shell script to back up all Lichess data using the [Lichess API](https://lichess.org/api).

## Requirements

- [HTTPie](https://httpie.io/) (`http`)
- [jq](https://jqlang.org/)

## Setup

Generate a token at https://lichess.org/account/oauth/token with scopes:

| Scope | Required for |
|-------|-------------|
| `study:read` | Private studies |
| `puzzle:read` | Puzzle activity (optional) |

```bash
export LICHESS_TOKEN=your_token_here
```

## Usage

```bash
bash backup.sh [--puzzles] [--keep N] [--no-compress]
```

| Flag | Description |
|------|-------------|
| `--puzzles` | Include puzzle activity history |
| `--keep N` | Delete old backups, keep only N most recent |
| `--no-compress` | Skip `.tar.gz` compression, keep raw directory |

```bash
# Games + studies
bash backup.sh

# Everything, keep last 5 backups
bash backup.sh --puzzles --keep 5

# No compression (for scripting/piping)
bash backup.sh --no-compress
```

## Output

Creates `lichess-backup-YYYY-MM-DD--HH-MM.tar.gz` (or directory with `--no-compress`):

```
lichess-backup-2026-05-06--14-32/
  games.pgn              # all games (PGN, with clocks/evals/openings)
  studies/
    Study_Name-<id>.pgn  # one file per study, importable separately
  puzzles.ndjson         # puzzle activity history (if --puzzles)
```

Each run is a fresh snapshot — deleted studies are not included.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `2` | Partial failure (some downloads failed) |
