#!/bin/sh

if [ -z ${REDIS_MAXMEMORY:+ok} ]; then
  export REDIS_MAXMEMORY="$(( $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) / 10 * 9 ))"
fi

confd -onetime || exit 2

exec su-exec redis redis-server "$@"
