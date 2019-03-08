#!/bin/sh

confd -onetime || exit 2

echo "I'm $(whoami) !"

exec su-exec redis redis-server "$@"
