#!/usr/bin/env bash
# Copy this job's share of images.tsv from Docker Hub to the ACR mirror (linux/amd64 only).
# Usage: push.sh <job> <jobs> [limit]
#   job/jobs: this runner takes the rows with index % jobs == job; limit > 0 only uses the first
#   rows of images.tsv (for trial runs).
# Env: ALIYUN_REGISTRY, ALIYUN_NAME_SPACE; ANON_CFG and AUTH_CFG are docker config dirs that both
#   hold the ACR login, AUTH_CFG also the Docker Hub login (used on retries, e.g. after an anonymous
#   rate limit); PARALLEL images copied at once (default 8: the upload to China is slow per
#   connection, so concurrency multiplies throughput); CRANE_JOBS concurrent blobs per image (8);
#   BUDGET_MIN minutes after which no new copy starts (300, below the job's 350-minute limit, so
#   running copies can finish): the rest of the share is left for the next round.
# Images already in the mirror are skipped, so re-running only fills the gaps. Exits non-zero if
# a copy failed or rows were left over.
set -uo pipefail

JOB=$1 JOBS=$2 LIMIT=${3:-0}
PARALLEL=${PARALLEL:-8} CRANE_JOBS=${CRANE_JOBS:-8} BUDGET_MIN=${BUDGET_MIN:-300}
PREFIX="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE"

copy_one() {  # src path: copy one image and append its result line
  local src=$1 dst=$PREFIX/$2 attempt cfg platform log
  if DOCKER_CONFIG=$ANON_CFG crane digest "$dst" > /dev/null 2>&1; then
    printf 'SKIP\t%s\t%s\n' "$src" "$dst" >> results.tsv
    return 0
  fi
  log=$(mktemp)
  for attempt in 1 2 3 4; do
    cfg=$ANON_CFG
    if (( attempt % 2 == 0 )); then cfg=$AUTH_CFG; fi
    if DOCKER_CONFIG=$cfg crane copy --jobs "$CRANE_JOBS" --platform linux/amd64 \
        "docker.io/$src" "$dst" > "$log" 2>&1; then
      # --platform only filters multi-platform indexes: verify a single-platform source too
      platform=$(DOCKER_CONFIG=$ANON_CFG crane config "$dst" 2> /dev/null \
        | jq -r '"\(.os // "?")/\(.architecture // "?")"')
      if [ "$platform" = linux/amd64 ]; then
        rm -f "$log"
        printf 'OK\t%s\t%s\n' "$src" "$dst" >> results.tsv
        return 0
      fi
      DOCKER_CONFIG=$ANON_CFG crane delete "$dst" > /dev/null 2>&1 || true
      echo "::error::$src is ${platform:-unknown}, not linux/amd64; removed from the mirror"
      break
    fi
    echo "::warning::$src attempt $attempt: $(tail -n 1 "$log")"
    sleep $((attempt * 20))
  done
  rm -f "$log"
  printf 'FAIL\t%s\t%s\n' "$src" "$dst" >> results.tsv
}

: > results.tsv
i=-1 running=0 deferred=0
while IFS=$'\t' read -r src path; do
  i=$((i + 1))
  if (( LIMIT > 0 && i >= LIMIT )); then break; fi
  (( i % JOBS == JOB )) || continue
  if (( SECONDS >= BUDGET_MIN * 60 )); then deferred=$((deferred + 1)); continue; fi
  copy_one "$src" "$path" < /dev/null &  # never let a copy read images.tsv
  running=$((running + 1))
  if (( running >= PARALLEL )); then
    wait -n
    running=$((running - 1))
  fi
done < images.tsv
wait
ok=$(grep -c '^OK' results.tsv) skipped=$(grep -c '^SKIP' results.tsv)
failed=$(grep -c '^FAIL' results.tsv)
summary="job $JOB/$JOBS: copied $ok, already mirrored $skipped, failed $failed"
summary+=", left for the next round $deferred"
echo "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$summary" >> "$GITHUB_STEP_SUMMARY"; fi
exit $(( failed + deferred > 0 ))
