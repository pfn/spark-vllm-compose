#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: launch-cluster.sh <command> [args...]" >&2
    exit 1
fi

# Store original arguments to exec unmodified later on HEAD node
ORIGINAL_ARGS=("$@")

NEED_NODE_RANK=0
MODE="none"

for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
    if [[ "${ORIGINAL_ARGS[i]}" == "--node-rank" && "${ORIGINAL_ARGS[i+1]:-}" == "0" ]]; then
        NEED_NODE_RANK=1
    fi
    if [[ "${ORIGINAL_ARGS[i]}" == "--distributed-executor-backend" && "${ORIGINAL_ARGS[i+1]:-}" == "ray" ]]; then
        MODE="ray"
    fi
done

# 1. Prepare base command on HEAD node (NO trailing newline yet)
if [[ "$NEED_NODE_RANK" -eq 1 ]]; then
    WORKER_CMD=()
    for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
        if [[ "${ORIGINAL_ARGS[i]}" == "--node-rank" && "${ORIGINAL_ARGS[i+1]:-}" == "0" ]]; then
            i=$((i + 1)) # safely skip '0' without breaking set -e
            continue
        fi
        WORKER_CMD+=("${ORIGINAL_ARGS[i]}")
    done
    WORKER_CMD+=("--headless")
    
    # Serialize array safely. Do NOT add a trailing newline yet.
    printf '%q ' "${WORKER_CMD[@]}" | tr -d '\n' > ~/.vllm-cluster-command

elif [[ "$MODE" == "ray" ]]; then
    # Single-quoted EOF prevents head-node expansion of ${HEAD_IP_ADDRESS} etc.
    cat > ~/.vllm-cluster-command <<'EOF'
ray start --block --object-store-memory 1073741824 --num-cpus NODE_COUNT --disable-usage-stats --address=${HEAD_IP_ADDRESS}:6379 --node-ip-address ${NODE_IP_ADDRESS}
EOF

else
    : # No distribution logic needed; proceed to execution
fi

# 2. Distribute to WORKER_NODES if applicable
if [[ -n "${WORKER_NODES:-}" && ( "$NEED_NODE_RANK" -eq 1 || "$MODE" == "ray" ) ]]; then
    read -ra NODE_LIST <<< "$WORKER_NODES" # Safely splits on any whitespace

    if [[ "$NEED_NODE_RANK" -eq 1 ]]; then
        INDEX=0
        for NODE in "${NODE_LIST[@]}"; do
            echo "Provisioning worker: $NODE (index=$INDEX)"
            
            # Pre-compute the exact final command locally to avoid remote quoting/newline issues
	    FINAL_CMD=("${WORKER_CMD[@]}" "--node-rank" "$((INDEX + 1))")
            
            # Serialize safely, strip internal newlines if any, leave file open
            printf '%q ' "${FINAL_CMD[@]}" | tr -d '\n' > /tmp/.vllm-worker-cmd
            
            scp /tmp/.vllm-worker-cmd "$NODE":~/.vllm-cluster-command || { echo "Failed SCP to $NODE"; exit 1; }
            
            # Append final newline so bash executes it cleanly on container startup
            ssh "$NODE" "echo '' >> ~/.vllm-cluster-command && docker restart vllm" || { echo "Failed to restart $NODE"; exit 1; }
            
            INDEX=$((INDEX + 1))
        done
    elif [[ "$MODE" == "ray" ]]; then
        WORKER_COUNT=${#NODE_LIST[@]}
        CLUSTER_SIZE=$((WORKER_COUNT + 1)) # Workers + Head Node
        
        for NODE in "${NODE_LIST[@]}"; do
            echo "Provisioning worker: $NODE (cluster_size=$CLUSTER_SIZE)"
            
            scp ~/.vllm-cluster-command "$NODE":~/.vllm-cluster-command || { echo "Failed SCP to $NODE"; exit 1; }
            
            ssh "$NODE" "sed -i 's/NODE_COUNT/'"$CLUSTER_SIZE"'/g' ~/.vllm-cluster-command && docker restart vllm" || { echo "Failed to configure/restart $NODE"; exit 1; }
        done
    fi
fi

# 3. Execute the original unmodified command on HEAD node
echo "Starting head node..."
exec "${ORIGINAL_ARGS[@]}"
