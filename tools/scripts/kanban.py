#!/usr/bin/env python3
"""Work tracking for this repo — a kanban board kept in a JSONL file.

Why a file and not a tracker: `CLAUDE.md` forbids tracker IDs in code,
comments, and commit messages, because trackers rot and code outlives them.
That rule leaves a real gap — multi-session work still needs somewhere to
record what is in flight, what it taught us, and what it unblocked. This
board fills it without putting an external system's identifiers into the
source: the board references the code, never the other way round.

The board file is deliberately **gitignored**. It is working state, not
project truth. Anything the repo should remember permanently gets promoted
out of here into the code, its tests, or a document under `design/` — a card
is done when its lesson has a home that is not this file.

Storage: one JSON object per line, one line per card, holding the card's
current state plus its own append-only `history`. JSONL because it greps and
diffs cleanly and a corrupt line costs one card rather than the board.
Mutations rewrite the whole file through a temporary file and an atomic
rename, so an interrupted write cannot truncate it.

Usage::

    tools/scripts/kanban.py add "Widen Theme to semantic roles" \\
        --type gap --lane framework --priority P1 --tags theme,design-system
    tools/scripts/kanban.py board
    tools/scripts/kanban.py list --status todo --lane framework
    tools/scripts/kanban.py move TUI-3 doing
    tools/scripts/kanban.py note TUI-3 "measurer and renderer must share one allocation"
    tools/scripts/kanban.py lesson TUI-3 "shared passes drift unless they share code"
    tools/scripts/kanban.py show TUI-3
    tools/scripts/kanban.py lessons
    tools/scripts/kanban.py link TUI-9 --blocked-by TUI-3

Exits 0 on success, 1 on a usage or lookup error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import date
from pathlib import Path
from typing import Any, Iterable, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
BOARD_PATH = REPO_ROOT / "design" / "board.jsonl"

# Ordered: `board` prints columns in this sequence, and `move` accepts any of
# them. "icebox" is not "todo" — it records a decision to not do something yet,
# which is worth keeping distinct from work merely not started.
STATUSES = ("icebox", "todo", "doing", "review", "done", "dropped")

# `gap` is the load-bearing one for this repo: something the framework cannot
# express, discovered by trying to build with it. Distinct from `bug` (it does
# the wrong thing) and `feature` (nobody has asked for it yet).
TYPES = ("bug", "gap", "feature", "chore", "lesson")

PRIORITIES = ("P0", "P1", "P2", "P3")

ID_PREFIX = "TUI"


# --------------------------------------------------------------------------
# Storage
# --------------------------------------------------------------------------

def load() -> list[dict[str, Any]]:
    """Read every card. Malformed lines are reported and skipped rather than
    aborting: losing one hand-edited card should not make the board
    unreadable."""
    if not BOARD_PATH.exists():
        return []
    cards: list[dict[str, Any]] = []
    for lineno, raw in enumerate(BOARD_PATH.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            cards.append(json.loads(line))
        except json.JSONDecodeError as exc:
            print(f"warning: {BOARD_PATH.name}:{lineno}: skipped unparseable line ({exc})",
                  file=sys.stderr)
    return cards


def save(cards: Iterable[dict[str, Any]]) -> None:
    """Rewrite the board atomically — temp file in the same directory, then
    rename. A partial write would otherwise leave the board truncated at
    whatever byte the process died on."""
    BOARD_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(BOARD_PATH.parent), prefix=".board-", suffix=".jsonl")
    try:
        with os.fdopen(fd, "w") as handle:
            for card in cards:
                handle.write(json.dumps(card, ensure_ascii=False, sort_keys=True) + "\n")
        os.replace(tmp, BOARD_PATH)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def next_id(cards: list[dict[str, Any]]) -> str:
    """Highest existing number plus one. Ids are never reused — a dropped
    card's id stays spoken for so old notes referring to it keep meaning
    what they said."""
    highest = 0
    for card in cards:
        raw = str(card.get("id", ""))
        if raw.startswith(ID_PREFIX + "-"):
            try:
                highest = max(highest, int(raw.split("-", 1)[1]))
            except ValueError:
                continue
    return f"{ID_PREFIX}-{highest + 1}"


def find(cards: list[dict[str, Any]], card_id: str) -> dict[str, Any]:
    wanted = card_id.upper()
    if not wanted.startswith(ID_PREFIX + "-"):
        wanted = f"{ID_PREFIX}-{wanted}"
    for card in cards:
        if str(card.get("id", "")).upper() == wanted:
            return card
    sys.exit(f"error: no card {wanted}")


def today() -> str:
    return date.today().isoformat()


def record(card: dict[str, Any], event: str, detail: str = "") -> None:
    card.setdefault("history", []).append(
        {"date": today(), "event": event, "detail": detail})
    card["updated"] = today()


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def summarise(card: dict[str, Any]) -> str:
    tags = ",".join(card.get("tags") or [])
    tag_part = f"  [{tags}]" if tags else ""
    blockers = card.get("blocked_by") or []
    block_part = f"  ⛔ {','.join(blockers)}" if blockers else ""
    return (f"{card['id']:<8} {card.get('priority', 'P2'):<3} "
            f"{card.get('type', 'chore'):<8} {card.get('title', '')}"
            f"{tag_part}{block_part}")


def cmd_board(args: argparse.Namespace) -> None:
    cards = load()
    if not cards:
        print("board is empty — add a card with `kanban.py add`")
        return
    for status in STATUSES:
        column = [c for c in cards if c.get("status") == status]
        if not column and status in ("dropped", "icebox"):
            continue
        print(f"\n{status.upper()}  ({len(column)})")
        print("─" * 72)
        for card in sorted(column, key=lambda c: (c.get("priority", "P2"), c["id"])):
            print("  " + summarise(card))
    print()


def cmd_list(args: argparse.Namespace) -> None:
    cards = load()
    if args.status:
        cards = [c for c in cards if c.get("status") == args.status]
    if args.lane:
        cards = [c for c in cards if c.get("lane") == args.lane]
    if args.type:
        cards = [c for c in cards if c.get("type") == args.type]
    if args.tag:
        cards = [c for c in cards if args.tag in (c.get("tags") or [])]
    for card in sorted(cards, key=lambda c: (c.get("priority", "P2"), c["id"])):
        print(summarise(card))


def cmd_show(args: argparse.Namespace) -> None:
    card = find(load(), args.id)
    print(f"{card['id']}  {card.get('title', '')}")
    print(f"  status    {card.get('status')}")
    print(f"  type      {card.get('type')}    priority {card.get('priority')}")
    print(f"  lane      {card.get('lane')}")
    if card.get("tags"):
        print(f"  tags      {', '.join(card['tags'])}")
    if card.get("blocked_by"):
        print(f"  blocked   {', '.join(card['blocked_by'])}")
    if card.get("refs"):
        print(f"  refs      {', '.join(card['refs'])}")
    if card.get("body"):
        print(f"\n{card['body']}\n")
    if card.get("lessons"):
        print("  lessons")
        for lesson in card["lessons"]:
            print(f"    • {lesson}")
    if card.get("history"):
        print("  history")
        for entry in card["history"]:
            detail = f" — {entry['detail']}" if entry.get("detail") else ""
            print(f"    {entry['date']}  {entry['event']}{detail}")


def cmd_lessons(args: argparse.Namespace) -> None:
    """Every lesson on the board, with the card that earned it. This is the
    view worth re-reading before starting related work."""
    for card in sorted(load(), key=lambda c: c["id"]):
        for lesson in card.get("lessons") or []:
            print(f"{card['id']}  {lesson}")
            print(f"{'':8}  ↳ {card.get('title', '')}")


# --------------------------------------------------------------------------
# Mutation
# --------------------------------------------------------------------------

def cmd_add(args: argparse.Namespace) -> None:
    cards = load()
    card = {
        "id": next_id(cards),
        "title": args.title,
        "type": args.type,
        "status": args.status,
        "lane": args.lane,
        "priority": args.priority,
        "tags": args.tags.split(",") if args.tags else [],
        "body": args.body or "",
        "refs": args.refs.split(",") if args.refs else [],
        "blocked_by": [],
        "lessons": [],
        "created": today(),
        "updated": today(),
        "history": [],
    }
    record(card, "created")
    cards.append(card)
    save(cards)
    print(card["id"])


def cmd_move(args: argparse.Namespace) -> None:
    cards = load()
    card = find(cards, args.id)
    previous = card.get("status")
    card["status"] = args.status
    record(card, "moved", f"{previous} → {args.status}")
    save(cards)
    print(f"{card['id']}: {previous} → {args.status}")


def cmd_note(args: argparse.Namespace) -> None:
    cards = load()
    card = find(cards, args.id)
    record(card, "note", args.text)
    save(cards)


def cmd_lesson(args: argparse.Namespace) -> None:
    cards = load()
    card = find(cards, args.id)
    card.setdefault("lessons", []).append(args.text)
    record(card, "lesson", args.text)
    save(cards)


def normalise_id(raw: str) -> str:
    value = raw.strip().upper()
    if not value:
        return ""
    return value if value.startswith(ID_PREFIX + "-") else f"{ID_PREFIX}-{value}"


def cmd_link(args: argparse.Namespace) -> None:
    cards = load()
    card = find(cards, args.id)
    # `--set` replaces rather than appends. Dependencies get recorded against
    # ids that shift while a batch of cards is still being created, so the
    # common correction is "these are the blockers, forget what I said".
    if args.set is not None:
        card["blocked_by"] = []
        record(card, "unblocked", "cleared")
        raw_ids = args.set
    else:
        raw_ids = args.blocked_by or ""
    for raw in raw_ids.split(","):
        blocker = normalise_id(raw)
        if not blocker:
            continue
        if blocker == str(card.get("id", "")).upper():
            sys.exit(f"error: {blocker} cannot block itself")
        find(cards, blocker)  # validate it exists
        if blocker not in card.setdefault("blocked_by", []):
            card["blocked_by"].append(blocker)
            record(card, "blocked", f"by {blocker}")
    save(cards)


def cmd_edit(args: argparse.Namespace) -> None:
    cards = load()
    card = find(cards, args.id)
    for field in ("title", "priority", "lane", "body"):
        value = getattr(args, field, None)
        if value is not None:
            card[field] = value
            record(card, "edited", f"{field} = {value}")
    if args.refs is not None:
        card["refs"] = args.refs.split(",") if args.refs else []
        record(card, "edited", "refs")
    if args.tags is not None:
        card["tags"] = args.tags.split(",") if args.tags else []
        record(card, "edited", "tags")
    save(cards)


# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="kanban.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    add = sub.add_parser("add", help="create a card")
    add.add_argument("title")
    add.add_argument("--type", choices=TYPES, default="chore")
    add.add_argument("--status", choices=STATUSES, default="todo")
    add.add_argument("--lane", default="framework")
    add.add_argument("--priority", choices=PRIORITIES, default="P2")
    add.add_argument("--tags", default="")
    add.add_argument("--refs", default="")
    add.add_argument("--body", default="")
    add.set_defaults(func=cmd_add)

    board = sub.add_parser("board", help="print the board by column")
    board.set_defaults(func=cmd_board)

    listing = sub.add_parser("list", help="filter cards")
    listing.add_argument("--status", choices=STATUSES)
    listing.add_argument("--lane")
    listing.add_argument("--type", choices=TYPES)
    listing.add_argument("--tag")
    listing.set_defaults(func=cmd_list)

    show = sub.add_parser("show", help="print one card in full")
    show.add_argument("id")
    show.set_defaults(func=cmd_show)

    move = sub.add_parser("move", help="change a card's status")
    move.add_argument("id")
    move.add_argument("status", choices=STATUSES)
    move.set_defaults(func=cmd_move)

    note = sub.add_parser("note", help="append a history note")
    note.add_argument("id")
    note.add_argument("text")
    note.set_defaults(func=cmd_note)

    lesson = sub.add_parser("lesson", help="record what a card taught us")
    lesson.add_argument("id")
    lesson.add_argument("text")
    lesson.set_defaults(func=cmd_lesson)

    lessons = sub.add_parser("lessons", help="print every lesson on the board")
    lessons.set_defaults(func=cmd_lessons)

    link = sub.add_parser("link", help="record a dependency")
    link.add_argument("id")
    link.add_argument("--blocked-by", dest="blocked_by", default="",
                      help="append blockers (comma-separated ids)")
    link.add_argument("--set", default=None,
                      help="replace the blocker list outright; empty string clears it")
    link.set_defaults(func=cmd_link)

    edit = sub.add_parser("edit", help="change fields on a card")
    edit.add_argument("id")
    edit.add_argument("--title")
    edit.add_argument("--priority", choices=PRIORITIES)
    edit.add_argument("--lane")
    edit.add_argument("--body")
    edit.add_argument("--tags")
    edit.add_argument("--refs")
    edit.set_defaults(func=cmd_edit)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
