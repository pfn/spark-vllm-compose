# spark-vllm-compose

Multi-node vLLM inference on DGX Spark clusters using Docker Compose.

This repository simplifies deploying distributed vLLM across DGX Spark nodes by providing pre-configured Docker Compose setups for head and worker nodes. It uses vLLM's native multiprocessing backend (`--nnodes --node-rank`) for multi-node coordination, with the `launch-cluster.sh` script automatically distributing commands to worker nodes.

## Prerequisites

- **DGX Spark nodes** running the latest DGX OS (updates recommended)
- **vllm-node-tf5 image** built on each node using `build_and_copy.sh` from [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker):
  ```bash
  ./build_and_copy.sh -t vllm-node-tf5 --tf5
  ```
- **Docker access**: Add your user to the `docker` group to avoid `sudo`:
  ```bash
  sudo usermod -aG docker $USER
  # Log out and back in for changes to take effect
  ```
- **SSH setup**: Follow NVIDIA's DGX Spark setup guides to configure passwordless SSH between nodes. The shared SSH key (`~/.ssh/id_ed25519_shared`) and config (`~/.ssh/config`) should be in place before deployment.

## Networking Setup

Before deploying the cluster, configure static IPs for QSFP56 interfaces on each node. Full instructions are available here:

- [spark-vllm-docker NETWORKING.md](https://github.com/eugr/spark-vllm-docker/blob/main/docs/NETWORKING.md)
- [NVIDIA: Connect Two Sparks](https://build.nvidia.com/spark/connect-two-sparks/stacked-sparks)

**Key points:**
- Assign static IPs to the QSFP56 interfaces (e.g., `enp1s0f1np1`) on each node
- Use a dedicated subnet separate from your management network
- Ensure passwordless SSH between nodes for cluster coordination
- Set MTU to 9000 for jumbo frames
- **Add hostnames to `/etc/hosts`**: On each node, add entries mapping worker hostnames to their static IB IPs. For example, on all nodes:
  ```bash
  # /etc/hosts
  192.168.177.11  node1
  192.168.177.12  node2
  192.168.177.13  node3
  ```
  The `WORKER_NODES` variable in `head/compose.yaml` references these hostnames, so they must be resolvable.

## Quick Start

### 1. Clone the Repository

Clone this repository onto **each node** in the cluster:
```bash
git clone <repository-url> spark-vllm-compose
cd spark-vllm-compose
```

### 2. Download Models

Manually download your models to the `models/` directory on each node:
```bash
# On each node
mkdir -p models
# Download your model (example using huggingface-cli)
huggingface-cli download <model-id> --local-dir models/<model-name>
```

Ensure the model files exist at the same path on all nodes, as this directory is mounted into the containers.

### 3. Configure Head Node

On the head node (e.g., `node1`):

#### Edit `head/compose.yaml`
Update the `WORKER_NODES` environment variable in the `vllm-noray` service to list your worker hostnames:
```yaml
services:
  vllm-noray:
    # ...
    environment:
      - WORKER_NODES=node2 node3  # Space-separated list of worker hostnames
    command: >
      /launch-cluster.sh vllm serve
        /models/Qwen3.5-397B-A17B-int4-AutoRound
        --served-model-name "Qwen3.5 397B:int4"
        --tensor-parallel-size 2
        --nnodes 3 --node-rank 0 --master-addr node1 --master-port 54321
        # ... other options
```

**Important:** The `command` must be prefixed with `/launch-cluster.sh` - this script handles distributing the command to workers and coordinating cluster startup.

Update `--nnodes` to match your total node count (head + workers).

#### Edit `head/.env`
Update IP addresses:
```bash
HEAD_IP_ADDRESS=192.168.177.11    # This node's IP
NODE_IP_ADDRESS=192.168.177.11    # Same as HEAD for head node
MODELS_BASEDIR=$HOME/spark-vllm-compose/models
```

### 4. Configure Worker Node(s)

On each worker node (e.g., `node2`, `node3`):

#### Edit `worker1/.env`
Update IP addresses for each worker:
```bash
# On node2
NODE_IP_ADDRESS=192.168.177.12    # This worker's IP
HEAD_IP_ADDRESS=192.168.177.11    # Head node's IP
MODELS_BASEDIR=$HOME/spark-vllm-compose/models

# On node3
NODE_IP_ADDRESS=192.168.177.13    # This worker's IP
HEAD_IP_ADDRESS=192.168.177.11    # Head node's IP
MODELS_BASEDIR=$HOME/spark-vllm-compose/models
```

The worker `compose.yaml` files should not need modification unless you have custom requirements.

### 5. Start the Cluster

**Head node:**
```bash
cd head
docker compose up -d vllm-noray
```

**Worker nodes:**
```bash
cd worker1
docker compose up -d
```

Run the worker command on each worker node in the cluster.

The head node will automatically:
1. Wait for the vLLM container to be ready
2. SCP the launch command to each worker node listed in `WORKER_NODES`
3. Restart worker containers to execute the command
4. Start vLLM on the head node with `--node-rank 0`

### 6. Verify Deployment

Check the vLLM head container logs:
```bash
docker compose -f head/compose.yaml logs -f vllm-noray
```

You should see vLLM initialization messages and eventually the server ready message indicating all nodes have connected.

## Single-Node Setup

For running on a single DGX Spark without clustering:

1. Edit `head/compose.yaml` and set `WORKER_NODES` to an empty string:
   ```yaml
   environment:
     - WORKER_NODES=
   ```

2. Remove the `--nnodes`, `--node-rank`, `--master-addr`, and `--tensor-parallel-size` options from the vLLM command:
   ```yaml
   command: >
     /launch-cluster.sh vllm serve
       /models/<your-model-path>
       --served-model-name <model-name>
   ```

3. Start with `docker compose up -d` as usual.

## Scaling Beyond 2 Nodes

DGX Spark natively supports 2 nodes via direct QSFP56 connection. For larger clusters:

1. **Hardware**: Use a QSFP56 switch (e.g., MikroTik CRS812-DDQ)
2. **Configuration**: 
   - Copy `worker1/` directory for each additional worker (e.g., `worker2/`, `worker3/`)
   - Update each worker's `.env` with unique `NODE_IP_ADDRESS`
   - Add hostnames to `/etc/hosts` on all nodes
   - Update `WORKER_NODES` in `head/compose.yaml` to list all workers:
     ```yaml
     - WORKER_NODES="node2 node3 node4"
     ```
   - Update `--nnodes` in the vLLM command to match total node count

## Example Configurations

The `head/compose.yaml` includes several example service configurations demonstrating different models and settings. These examples are provided for reference and may be modified or removed based on your specific use case. The key pattern to follow is:

1. Use `/launch-cluster.sh` as the command prefix
2. Include `--nnodes`, `--node-rank 0`, and `--master-addr` for multi-node
3. Set `WORKER_NODES` environment variable to list your workers

## How It Works

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     DGX Spark Cluster                           │
│                                                                 │
│  ┌─────────────────┐          ┌─────────────────┐               │
│  │   Head Node     │          │   Worker Node   │               │
│  │   (node1)       │          │   (node2)       │               │
│  │                 │          │                 │               │
│  │  ┌───────────┐  │  SSH     │  ┌───────────┐  │               │
│  │  │  vLLM     │  │ ───────▶ │  │  vLLM     │  │               │
│  │  │  Rank 0   │  │  SCP     │  │  Rank 1   │  │               │
│  │  │  :8000    │  │  cmd     │  │           │  │               │
│  │  └───────────┘  │          │  └───────────┘  │               │
│  │       ▲         │          │       ▲         │               │
│  │       │         │          │       │         │               │
│  │  ┌───────────┐  │          │  ┌───────────┐  │               │
│  │  │launch-    │  │          │  │launch-    │  │               │
│  │  │cluster.sh │  │          │  │worker.sh  │  │               │
│  │  └───────────┘  │          │  └───────────┘  │               │
│  └─────────────────┘          └─────────────────┘               │
└─────────────────────────────────────────────────────────────────┘
```

### Multi-Node Coordination Flow

1. **Head node starts**: The `launch-cluster.sh` script runs as the container entrypoint
2. **Command preparation**: The script parses the vLLM command, extracting `--node-rank 0` and preparing a modified command for workers (with their respective `--node-rank` values)
3. **Worker provisioning**: The head node SCPs the command file (`~/.vllm-cluster-command`) to each worker listed in `WORKER_NODES` and triggers a container restart
4. **Worker execution**: Workers wait for the command file via `launch-worker.sh`, then execute it with their assigned rank
5. **Head execution**: After provisioning all workers, the head node executes vLLM with `--node-rank 0`
6. **Cluster formation**: vLLM's multiprocessing backend connects all nodes via the specified `--master-addr` and `--master-port`

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `launch-cluster.sh` | `head/` | Prepares and distributes vLLM commands to all workers |
| `launch-worker.sh` | `worker1/` | Waits for command file from head and executes vLLM |
| `drop-caches.sh` | `head/`, `worker1/` | Clears system caches to maximize available GPU memory |
| `setup-ssh.sh` | `head/` | Ensures SSH client is available for worker communication |
| `.vllm-cluster-command` | `~/.vllm-cluster-command` | Temporary file containing the serialized vLLM command |

### Drop Caches Behavior

The `drop-caches.sh` script runs on container startup to clear system page cache, dentries, and inodes:
```bash
echo 3 > /host/proc/sys/vm/drop_caches
```

This is **recommended for DGX Spark** because large models (e.g., Qwen3.5-397B) barely fit in available memory, and system caches can consume several GB of RAM. Clearing caches ensures maximum memory for model weights and KV cache.

### Environment Variables

Key environment variables configured in `.env` files and `compose.yaml`:

| Variable | Location | Purpose | Example |
|----------|----------|---------|---------|
| `WORKER_NODES` | `head/compose.yaml` | Space-separated worker hostnames | `node2 node3` |
| `HEAD_IP_ADDRESS` | `.env` | IP of the head node | `192.168.177.11` |
| `NODE_IP_ADDRESS` | `.env` | IP of the current node | `192.168.177.12` |
| `MODELS_BASEDIR` | `.env` | Host path for model storage | `$HOME/spark-vllm-compose/models` |

### RDMA/InfiniBand Configuration

The compose files include extensive NCCL and UCX environment variables for optimal RDMA communication over the QSFP56 interface:

```yaml
environment:
  - UCX_NET_DEVICES=enp1s0f1np1
  - NCCL_IB_DISABLE=0
  - NCCL_IB_HCA=rocep1s0f1,roceP2p1s0f1
  - NCCL_SOCKET_IFNAME=enp1s0f1np1
  # ... etc
```

These ensure tensor parallel communication uses the high-speed InfiniBand interface rather than falling back to TCP.

## Ray Backend (Optional)

Ray support is included but **not recommended** for new deployments. The native multiprocessing backend via `launch-cluster.sh` is preferred.

To enable Ray mode:
1. Edit `head/compose.yaml` and use a service with `--distributed-executor-backend ray`
2. Uncomment `RAY_CLUSTER_SIZE` in the environment section

Note: Ray support may be removed in future versions.

## File Structure

```
spark-vllm-compose/
├── head/
│   ├── .env                  # Head node configuration (IPs, paths)
│   ├── compose.yaml          # Head node Docker Compose config (includes WORKER_NODES)
│   ├── launch-cluster.sh     # Command distribution script (KEY COMPONENT)
│   ├── ray-start-head.sh     # Ray cluster init (legacy)
│   ├── setup-ssh.sh          # SSH client setup
│   └── drop-caches.sh        # Memory cache clearing
├── worker1/
│   ├── .env                  # Worker 1 configuration (IPs, paths)
│   ├── compose.yaml          # Worker 1 Docker Compose config
│   ├── launch-worker.sh      # Waits for command and executes vLLM
│   └── drop-caches.sh        # Memory cache clearing
└── models/                   # Mount point for your models (gitignored)
```

## Dependencies

- **Base image**: `vllm-node-tf5` (built from [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker))
  - Note: Official NGC vLLM containers have outdated transformers versions
- **vLLM**: Latest version with multiprocessing distributed executor backend
- **RDMA/RoCE**: Required for multi-node NCCL communication

## Auto-Restart Behavior

Docker Compose is configured with `restart: unless-stopped`, which means:

- **Crash recovery**: If vLLM crashes/exits unexpectedly, the containers will automatically restart
- **Boot recovery**: Containers will start automatically after system reboot (if they were running before shutdown)
- **Manual stop**: Containers will NOT auto-restart if you manually run `docker compose down`

This ensures your cluster recovers from transient failures without manual intervention.

## Troubleshooting

### Workers Not Connecting

1. Verify SSH connectivity: `ssh node2 echo "test"`
2. Check `WORKER_NODES` in `head/compose.yaml` matches actual hostnames
3. Verify hostnames are in `/etc/hosts` on all nodes
4. Check `~/.vllm-cluster-command` exists on workers: `docker exec vllm cat ~/.vllm-cluster-command`

### NCCL Timeouts

1. Verify InfiniBand interface: `ibstat` should show active ports
2. Check NCCL logs: `NCCL_DEBUG=INFO docker compose logs vllm-noray`
3. Ensure `UCX_NET_DEVICES` matches your actual interface name

### Out of Memory Errors

1. Reduce `--gpu-memory-utilization` in the vLLM command
2. Verify drop-caches is running: check logs for "Dropping caches" message
3. Close other memory-intensive processes on the host

### Model Download Issues

Models are mounted from `MODELS_BASEDIR`. Ensure:
- Models are pre-downloaded to the specified directory on all nodes
- The directory exists before starting containers
- Permissions allow the container to read the models
