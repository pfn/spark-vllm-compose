#!/usr/bin/env bash

CMD_FILE=~/.vllm-cluster-command

# Path always exists due to bind mount, but its type (file vs directory) and content vary.
if [[ -f "$CMD_FILE" ]]; then
    # File exists -> check if it has content
    if [[ ! -s "$CMD_FILE" ]]; then
        # Empty file: Wait for head node to provision the command
        echo "[launch-worker] Command file is empty. Waiting for configuration..."
        sleep infinity
    else
        # Populated file: Execute the contents as PID 1
        eval exec "$(< $CMD_FILE)"
    fi
else
    # Path exists but is not a file (e.g. Docker created a directory because the host source was missing).
    echo "##############################################################################"
    echo "# FATAL ERROR: ~/.vllm-cluster-command is misconfigured!                  #"
    echo "#                                                                          #"
    echo "# This usually happens because the bind mount source on your HOST machine  #"
    echo "# does not exist. Docker creates a placeholder directory instead of        #"
    echo "# failing, masking the issue until the container starts.                   #"
    echo "#                                                                          #"
    echo "# ACTION REQUIRED:                                                         #"
    echo "# 1. Remove the existing ~/.vllm-cluster-command on your HOST machine.     #"
    echo "# 2. Create a NON-EMPTY file at ~/.vllm-cluster-command on the host.       #"
    echo "# 3. Restart the container: docker restart vllm                            #"
    echo "##############################################################################"
    exit 1
fi
