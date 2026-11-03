#!/usr/bin/env bash
# Copy this job's share of images.tsv from Docker Hub to the ACR mirror (linux/amd64 only).
# Usage: push.sh <job> <jobs> [limit]
#   job/jobs: this runner takes the rows with index % jobs == job; limit > 0 only uses the first
#   rows of images.tsv (for trial runs).
# Env: ALIYUN_REGISTRY, ALIYUN_NAME_SPACE; ANON_CFG and AUTH_CFG are docker config dirs that both
#   hold the ACR login, AUTH_CFG also the Docker Hub login (used on retries, e.g. after an anonymous
#   rate limit). Images already in the mirror are skipped, so re-running only fills the gaps.
set -uo pipefail

JOB=$1 JOBS=$2 LIMIT=${3:-0}
PREFIX="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE"
ok=0 skipped=0 failed=0 i=-1
: > results.tsv
while IFS=$'\t' read -r src path; do
  i=$((i + 1))
  if (( LIMIT > 0 && i >= LIMIT )); then break; fi
  (( i % JOBS == JOB )) || continue
  dst="$PREFIX/$path"
  if DOCKER_CONFIG=$ANON_CFG crane digest "$dst" > /dev/null 2>&1; then
    skipped=$((skipped + 1))
    printf 'SKIP\t%s\t%s\n' "$src" "$dst" >> results.tsv
    continue
  fi
  copied=0
  for attempt in 1 2 3 4; do
    cfg=$ANON_CFG
    if (( attempt % 2 == 0 )); then cfg=$AUTH_CFG; fi
    if DOCKER_CONFIG=$cfg crane copy --platform linux/amd64 "docker.io/$src" "$dst" \
        > copy.log 2>&1; then
      # --platform only filters multi-platform indexes: verify a single-platform source too
      platform=$(DOCKER_CONFIG=$ANON_CFG crane config "$dst" 2> /dev/null \
        | jq -r '"\(.os // "?")/\(.architecture // "?")"')
      if [ "$platform" = linux/amd64 ]; then
        copied=1
      else
        DOCKER_CONFIG=$ANON_CFG crane delete "$dst" > /dev/null 2>&1 || true
        echo "::error::$src is ${platform:-unknown}, not linux/amd64; removed from the mirror"
      fi
      break
    fi
    echo "::warning::$src attempt $attempt: $(tail -n 1 copy.log)"
    sleep $((attempt * 20))
  done
  if (( copied )); then
    ok=$((ok + 1))
    printf 'OK\t%s\t%s\n' "$src" "$dst" >> results.tsv
  else
    failed=$((failed + 1))
    printf 'FAIL\t%s\t%s\n' "$src" "$dst" >> results.tsv
  fi
done < images.tsv
summary="job $JOB/$JOBS: copied $ok, already mirrored $skipped, failed $failed"
echo "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$summary" >> "$GITHUB_STEP_SUMMARY"; fi
exit $(( failed > 0 ))
