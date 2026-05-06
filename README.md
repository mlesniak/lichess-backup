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
# Games + studies
bash backup.sh

# Games + studies + puzzle history
bash backup.sh --puzzles
```

## Output

Creates `lichess-backup-YYYY-MM-DD--HH-MM/` with:

```
lichess-backup-2026-05-06--14-32/
  games.pgn           # all games (PGN, with clocks/evals/openings)
  studies/
    Study_Name-<id>.pgn   # one file per study
  puzzles.ndjson      # puzzle activity history (if --puzzles)
```

Each run is a fresh snapshot — deleted studies are not included.
