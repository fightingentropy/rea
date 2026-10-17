#!/usr/bin/env bash
# Sync this fork with morluto/rea and refresh the upstream-owned parts of the
# combined `rea` skill (.agents/skills/rea).
#
#   .fork/sync.sh           merge upstream, refresh references, commit locally
#   .fork/sync.sh --push    same, then push to origin
#
# Exit codes: 0 synced (read the summary), 1 error or merge conflict,
# 2 synced but upstream's SKILL.md changed and needs porting by hand.
set -euo pipefail

PUSH=0
[ "${1:-}" = "--push" ] && PUSH=1

cd "$(git rev-parse --show-toplevel)"
UP_URL=https://github.com/morluto/rea.git
UP=upstream
UP_SKILL=.agents/skills/reverse-engineer-anything
OUR_SKILL=.agents/skills/rea

git remote get-url "$UP" >/dev/null 2>&1 || git remote add "$UP" "$UP_URL"
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean; commit or stash first" >&2
  exit 1
fi

git fetch -q "$UP" main
before=$(git rev-parse HEAD)
up_head=$(git rev-parse "$UP/main")

if ! git merge --no-edit -m "Merge upstream morluto/rea main (${up_head:0:9})" "$UP/main" >/dev/null; then
  git merge --abort || true
  echo "error: merging upstream conflicts with this fork; resolve by hand:" >&2
  echo "  git merge $UP/main" >&2
  exit 1
fi
merged=$(git rev-list --count "$before..$up_head")

# References are upstream's, copied verbatim.
rm -rf "$OUR_SKILL/references"
cp -R "$UP_SKILL/references" "$OUR_SKILL/references"

# Every REA tool our SKILL.md names must still exist in upstream's source.
missing=""
for t in $( { sed -n '/^## Tier 2/,$p' "$OUR_SKILL/SKILL.md" | grep -oE '`[a-z][a-z0-9]*(_[a-z0-9]+)+`'
              grep -oE 'REA `[a-z][a-z0-9]*(_[a-z0-9]+)+`' "$OUR_SKILL/SKILL.md" | sed 's/^REA //'
              grep -oE 'mcp__rea__[a-z0-9_]+' "$OUR_SKILL/SKILL.md" | sed 's/^mcp__rea__//'
            } | tr -d '`' | sort -u ); do
  git grep -q -w -F -e "$t" -- src || missing="$missing $t"
done

# Has upstream's own skill text changed since we last reconciled with it?
last=$(cat "$OUR_SKILL/UPSTREAM" 2>/dev/null || echo "")
port_needed=0
if [ -n "$last" ] && git cat-file -e "$last" 2>/dev/null; then
  git diff --quiet "$last" "$up_head" -- "$UP_SKILL/SKILL.md" || port_needed=1
else
  port_needed=1
fi
[ "$port_needed" = 0 ] && echo "$up_head" > "$OUR_SKILL/UPSTREAM"

if [ -n "$(git status --porcelain -- "$OUR_SKILL")" ]; then
  git add -- "$OUR_SKILL"
  git commit -q -m "chore(fork): refresh rea skill from upstream ${up_head:0:9}"
fi

echo "upstream commits merged: $merged (now at ${up_head:0:9})"
if [ -n "$missing" ]; then
  echo "warning: tools named in $OUR_SKILL/SKILL.md not found in upstream src:$missing"
fi
if [ "$port_needed" = 1 ]; then
  echo "action: upstream's skill text changed. Review and port what matters into $OUR_SKILL/SKILL.md:"
  echo "  git diff ${last:-<none>} $up_head -- $UP_SKILL/SKILL.md"
  echo "then record it: echo $up_head > $OUR_SKILL/UPSTREAM && git commit -am 'chore(fork): port upstream skill changes'"
fi

if [ "$PUSH" = 1 ]; then
  git push -q origin HEAD
  echo "pushed $(git rev-parse --abbrev-ref HEAD) to origin"
fi
[ "$port_needed" = 1 ] && exit 2
exit 0
