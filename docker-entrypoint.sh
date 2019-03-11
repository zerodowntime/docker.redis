#!/bin/sh

confd -onetime || exit 2

exec su-exec redis redis-server "$@"
