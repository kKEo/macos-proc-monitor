#!/bin/zsh
# Record the stress scenarios used as ground truth for scoring, episodes and blame.
# Each one: 45 s of baseline, a known load, then 125 s of calm (long enough for the episode
# to close and its blame to be finalised). Output: gzipped recordings in the test fixtures.
# Usage: Support/record_scenarios.sh [scenario ...]     (default: all)
cd "$(dirname "$0")/.."
# Keep the Mac awake: a sleep in the middle of a scenario ruins the recording.
[[ -z $CAFFEINATED ]] && exec env CAFFEINATED=1 caffeinate -i "$0" "$@"
B=.build/release
OUT=Tests/PmonCoreTests/Fixtures/scenarios
WORK=$(mktemp -d)
mkdir -p $OUT
# Fixed cadence rules: never relax because the user is idle or on battery, so recordings are comparable.
echo '{"relaxWhenIdle": false}' > $WORK/config.json

record() {
  local name=$1; shift
  echo "$(date +%T) recording $name"
  $B/pmond --db $WORK/$name.db --config $WORK/config.json --record $WORK/$name.jsonl 2> $WORK/$name.log &
  local daemon=$!
  sleep 45
  "$@"
  sleep 125
  kill -TERM $daemon; wait $daemon
  gzip -9 -c $WORK/$name.jsonl > $OUT/$name.jsonl.gz
  echo "$(date +%T) $name: $(wc -l < $WORK/$name.jsonl | tr -d ' ') lines, $(du -k $OUT/$name.jsonl.gz | cut -f1) kB compressed, episodes: $(sqlite3 $WORK/$name.db 'SELECT COUNT(*) FROM episode')"
}

cpu()      { $B/pmon-stress cpu --threads 16 --seconds 60 >/dev/null }
# More than the Mac has free (about 3.7 GB of 8), so the load's own pages are pushed out and paged back in.
memory()   { $B/pmon-stress memory --mb 4000 --rate 400 --seconds 40 --touch-every 2 >/dev/null }
disk()     { $B/pmon-stress disk --mb 512 --seconds 60 >/dev/null }
mixed()    { $B/pmon-stress cpu --threads 16 --seconds 55 >/dev/null & local c=$!; $B/pmon-stress memory --mb 3500 --rate 400 --seconds 40 --touch-every 2 >/dev/null; wait $c }
quiet()    { sleep 60 }
flapping() { for i in 1 2 3 4; do $B/pmon-stress cpu --threads 16 --seconds 20 >/dev/null; sleep 10; done }
burst()    { $B/pmon-stress cpu --threads 16 --seconds 5 >/dev/null }

scenarios=("$@")
(( ${#scenarios} )) || scenarios=(quiet cpu burst flapping disk memory mixed)
if [[ -n $DRY_RUN ]]; then for s in $scenarios; do echo "would record: $s"; done; exit 0; fi
for s in $scenarios; do record $s $s; done
rm -rf $WORK
echo "$(date +%T) done"
