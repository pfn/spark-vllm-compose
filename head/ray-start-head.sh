#!/bin/sh

if [ $RAY_CLUSTER_SIZE -gt 1 ]; then
  ray start --head --port 6379 --object-store-memory $RAY_object_store_memory --num-cpus 2 \
         --node-ip-address $VLLM_HOST_IP --include-dashboard=false --disable-usage-stats

  while true; do
    nodes=$(($(ray status 2>&1 | awk '/Active:/,/Pending:/' | grep -c "^ *[0-9]* node_")))

    [ "$nodes" -ge $RAY_CLUSTER_SIZE ] && break
    [ "$seen" = "yes" -a "$nodes" -eq 0 ] && echo "Ray exited" && exit 1

    [ "$nodes" -gt 0 ] && seen=yes


    echo "⏳ Waiting... Found $nodes/$RAY_CLUSTER_SIZE nodes"
    sleep 5
  done


  echo "✓ Ray cluster ready with $nodes nodes"
else
  echo "✓ Skipping ray cluster init for single node startup"
fi

sync
echo 3 > /host/proc/sys/vm/drop_caches
