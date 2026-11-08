#!/bin/bash
# Public replay of the built-CLI loopback proofs for openclaw/discrawl #412 #413 #414 #416.
# Needs: git, go (toolchain auto -> 1.27.3), python3 >= 3.11, curl, gh (only to read PR bodies).
# Uses only public material: the saariuslystoned/discrawl fork branches and the fixture code in each PR body.
set -uo pipefail
W=${1:-$(mktemp -d)}; cd "$W"
git clone -q https://github.com/saariuslystoned/discrawl.git src && cd src
git fetch -q origin fix/guilds-forward-pagination fix/archived-thread-cursor-precision fix/media-channel-posts fix/forwarded-message-text
cd "$W"
# fixtures: first python block of #412; first two python blocks of #413 (world fixture, scenario generator)
gh pr view 412 -R openclaw/discrawl --json body --jq .body | python3 -I -c 'import re,sys; b=re.findall(r"```python\n(.*?)```", sys.stdin.read(), re.S); open("guild_fixture.py","w").write(b[0])'
gh pr view 413 -R openclaw/discrawl --json body --jq .body | python3 -I -c 'import re,sys; b=re.findall(r"```python\n(.*?)```", sys.stdin.read(), re.S); open("world_fixture.py","w").write(b[0]); open("make_worlds.py","w").write(b[1])'
mkdir -p worlds && python3 -I make_worlds.py worlds
build() { # build <ref> <port> <out>
  (cd src && git checkout -q "$1" && GOWORK=off go build -ldflags "-X github.com/bwmarrin/discordgo.EndpointDiscord=http://127.0.0.1:$2/" -o "$W/$3" ./cmd/discrawl) }
cli() { # cli <bin> <home> args...  (throwaway HOME, placeholder token, never a real config)
  local bin=$1 home=$2; shift 2
  env -i PATH=/usr/bin:/bin HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" XDG_STATE_HOME="$home/.local/state" DISCRAWL_NO_AUTO_UPDATE=1 DISCORD_BOT_TOKEN=fixture-not-a-token "$W/$bin" --config "$home/config.toml" "$@"; }
serve() { python3 -I "$@" & FIX=$!; for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/v9/users/@me" && return; sleep 0.1; done; }
for case in 412:fix/guilds-forward-pagination 413:fix/archived-thread-cursor-precision 414:fix/media-channel-posts 416:fix/forwarded-message-text; do
  pr=${case%%:*}; branch=${case#*:}; PORT=$((38000 + pr))
  build origin/main $PORT before-$pr && build "origin/$branch" $PORT after-$pr || exit 1
  case $pr in
    412) serve guild_fixture.py $PORT req-$pr.jsonl ;;
    413) serve world_fixture.py $PORT worlds/world-threads.json req-$pr.jsonl ;;
    414) serve world_fixture.py $PORT worlds/world-media.json req-$pr.jsonl ;;
    416) serve world_fixture.py $PORT worlds/world-forward.json req-$pr.jsonl ;;
  esac
  for side in before after; do
    h=$(mktemp -d); echo "== #$pr $side ($( [ $side = before ] && echo main || echo $branch ) @ $(cd src && git rev-parse --short origin/$( [ $side = before ] && echo main || echo $branch )))"
    if [ $pr = 412 ]; then
      cli $side-$pr $h --json init | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["discovered_guilds"]; print("init discovered=%d unique=%d" % (len(d), len(set(d))))'
      cli $side-$pr $h --json init --guild 100000000000002100 >/dev/null 2>$h/e; echo "init --guild <guild 301> exit=$? $(head -1 $h/e)"
      cli $side-$pr $h --json doctor | python3 -I -c 'import json,sys; print("doctor guild_access=%s" % json.load(sys.stdin).get("guild_access"))'
    else
      cli $side-$pr $h --json init >/dev/null 2>&1
      cli $side-$pr $h --json sync --source discord --full 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("sync threads=%s messages=%s" % (d.get("threads"), d.get("messages")))'
      case $pr in
        413) cli $side-$pr $h sql "select count(*) as archived_threads from channels where kind='thread_public'"; cli $side-$pr $h search 'thread body 100' 2>&1 | tail -2 ;;
        414) cli $side-$pr $h sql "select name, kind from channels order by name"; cli $side-$pr $h search 'media post' 2>&1 ;;
        416) cli $side-$pr $h search roadmap 2>&1; cli $side-$pr $h sql "select id, normalized_content from messages" ;;
      esac
    fi
    rm -rf "$h"
  done
  kill $FIX; wait $FIX 2>/dev/null
done
