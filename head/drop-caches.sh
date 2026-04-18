#!/bin/sh

echo "✓ Dropping caches to free up memory"
sync
echo 3 > /host/proc/sys/vm/drop_caches
