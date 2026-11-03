#!/usr/bin/env bash
# One capped run, started as: systemd-run --user --scope ... scope.sh RECORD -- CMD ARGS...
# Samples anon + shmem every 0.2 s, runs CMD, then reads memory.peak and memory.events before exit,
# because the scope vanishes with its last process. Writes one JSON object to RECORD, and every sample
# to RECORD.trace as "EPOCH BYTES", from which run.py splits the peak by phase.
#
# Sampled anon + shmem is the primary peak: it is what an OOM kill counts. memory.peak also includes
# page cache. After a kernel kill systemd stops the scope with SIGTERM, so this script traps TERM,
# gives CMD 5 s, records, and kills what is left. Exit code: CMD's.
set -u

record=$1
shift
[ "${1:-}" = "--" ] && shift
read -r line </proc/self/cgroup
cg=/sys/fs/cgroup${line#0::}
peakfile=$record.peak
tracefile=$record.trace
start=$EPOCHREALTIME

sample() {
  local peak=0 n=0 key value anon shmem
  trap 'exit 0' TERM
  while :; do
    anon=0 shmem=0
    while read -r key value; do
      case $key in
      anon) anon=$value ;;
      shmem)
        shmem=$value
        break
        ;;
      esac
    done <"$cg/memory.stat"
    n=$((n + 1))
    ((anon + shmem > peak)) && peak=$((anon + shmem))
    printf '%s %s\n' "$peak" "$n" >"$peakfile"
    printf '%s %s\n' "$EPOCHREALTIME" "$((anon + shmem))" >>"$tracefile"
    sleep 0.2
  done
}

sample &
sampler=$!

"$@" &
child=$!

stopping=0
trap 'stopping=1; kill -TERM "$child" 2>/dev/null' TERM INT

status=
while :; do
  wait "$child"
  got=$?
  if ! kill -0 "$child" 2>/dev/null; then
    wait "$child" 2>/dev/null
    again=$?
    if [ "$again" -eq 127 ]; then status=$got; else status=$again; fi
    break
  fi
  if [ "$stopping" -eq 1 ]; then
    for _ in {1..50}; do
      kill -0 "$child" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$child" 2>/dev/null; then
      status=143
      break
    fi
  fi
done

end=$EPOCHREALTIME
kill -TERM "$sampler" 2>/dev/null
wait "$sampler" 2>/dev/null

read -r sampled samples <"$peakfile" || {
  sampled=0
  samples=0
}
read -r peak <"$cg/memory.peak" || peak=0
oom=0 oom_kill=0 mem_max=0
while read -r key value; do
  case $key in
  oom) oom=$value ;;
  oom_kill) oom_kill=$value ;;
  max) mem_max=$value ;;
  esac
done <"$cg/memory.events"

printf '{"exit":%d,"start":%s,"end":%s,"sampled_peak_bytes":%s,"samples":%s,"memory_peak_bytes":%s,"oom":%s,"oom_kill":%s,"memory_max_events":%s,"cgroup":"%s"}\n' \
  "$status" "$start" "$end" "$sampled" "$samples" "$peak" "$oom" "$oom_kill" "$mem_max" "$cg" >"$record"

# Daemons outlive their host when it dies. Nothing may survive the run.
while read -r pid; do
  [ "$pid" = "$$" ] || kill -KILL "$pid" 2>/dev/null
done <"$cg/cgroup.procs"
exit "$status"
