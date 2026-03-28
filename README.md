# spark-vllm-compose

Multi-node vLLM inference on DGX Spark clusters using Docker Compose.

This repository simplifies deploying distributed vLLM across DGX Spark nodes by providing pre-configured Docker Compose setups for head and worker nodes.

## Prerequisites

- **DGX Spark nodes** running the latest DGX OS (updates recommended)
- **vllm-node-tf5 image** built on each node using `build_and_copy.sh` from [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker):
  ```bash
  ./build_and_copy.sh -t vllm-node-tf5 --pre-tf
  ```
- **Docker access**: Add your user to the `docker` group to avoid `sudo`:
  ```bash
  sudo usermod -aG docker $USER
  # Log out and back in for changes to take effect
  ```

## Networking Setup

Before deploying the cluster, configure static IPs for QSFP56 interfaces on each node. Full instructions are available here:

- [spark-vllm-docker NETWORKING.md](https://github.com/eugr/spark-vllm-docker/blob/main/docs/NETWORKING.md)
- [NVIDIA: Connect Two Sparks](https://build.nvidia.com/spark/connect-two-sparks/stacked-sparks)

**Key points:**
- Assign static IPs to the QSFP56 interfaces (e.g., `enp1s0f1np1`) on each node
- Use a dedicated subnet separate from your management network
- Ensure passwordless SSH between nodes for Ray cluster coordination
- Set MTU to 9000 for jumbo frames

## Quick Start

### 1. Clone the Repository

Clone this repository onto **each node** in the cluster:
```bash
git clone <repository-url> spark-vllm-compose
cd spark-vllm-compose
```

### 2. Configure Head Node

On the head node (e.g., `spark` or `spark-1`):

#### Edit `head/.env`
Update IP addresses and paths:
```bash
HEAD_IP_ADDRESS=192.168.177.11    # This node's IP
NODE_IP_ADDRESS=192.168.177.11    # Same as HEAD for head node
MODELS_BASEDIR=$HOME/spark-vllm-compose/models
RAY_SCRIPT_DIR=$HOME/spark-vllm-compose/head
```

#### Edit `head/compose.yaml` (optional)
Modify the vLLM command to serve your desired model:
```yaml
command: >
  vllm serve
    /models/<your-model-path>
    --served-model-name <model-name>
    --tensor-parallel-size 2
    # ... other options
```

### 3. Configure Worker Node(s)

On each worker node (e.g., `spark2`):

#### Edit `worker1/.env`
Update IP addresses:
```bash
HEAD_IP_ADDRESS=192.168.177.11    # Head node's IP
NODE_IP_ADDRESS=192.168.177.12    # This worker's IP
MODELS_BASEDIR=$HOME/spark-vllm-compose/models
RAY_SCRIPT_DIR=$HOME/spark-vllm-compose/head
```

#### Edit `worker1/compose.yaml` (optional)
Ensure the models bind mount points to your model directory. The rest should remain unchanged.

### 4. Start the Cluster

**Head node:**
```bash
cd head
docker compose up -d
```

**Worker node(s):**
```bash
cd worker1
docker compose up -d
```

The `ray-start-head.sh` script will wait for all worker nodes to connect before starting vLLM.

### 5. Verify Deployment

Check the vLLM head container logs:
```bash
docker compose -f head/compose.yaml logs -f vllm
```

You should see a message like `✓ Ray cluster ready with 2 nodes` followed by vLLM initialization.

## Single-Node Setup

For running on a single DGX Spark without clustering:

1. Edit `RAY_CLUSTER_SIZE` in `head/.env` to 0 or 1:
   ```bash
   RAY_CLUSTER_SIZE=2
   ```

2. Remove the `--tensor-parallel-size` and `--distributed-executor-backend` options from vllm:
   ```yaml
   --tensor-parallel-size 2  # or appropriate for single node GPU count
   --distributed-executor-backend ray  # may need to be removed for single-node
   ```

3. Start with `docker compose up -d` as usual.

## Scaling Beyond 2 Nodes

DGX Spark natively supports 2 nodes via direct QSFP56 connection. For larger clusters:

1. **Hardware**: Use a QSFP56 switch (e.g., MikroTik CRS812-DDQ)
2. **Configuration**: 
   - Copy `worker1/` directory for each additional worker (e.g., `worker2/`, `worker3/`)
   - Update `.env` files with unique IPs for each node
   - Modify `head/.env` to update the expected node count:
     ```bash
     RAY_CLUSTER_SIZE=N # Replace N with total node count
     ```

## Model Configuration

The default configuration serves `Qwen3.5-122B-A10B-int4-AutoRound` with speculative decoding. Modify the `command:` section in `head/compose.yaml` to:

- Change the model path under `/models/`
- Adjust `--served-model-name` for your API endpoint
- Tune parameters like `--max-model-len`, `--gpu-memory-utilization`, etc.
- Use different quantization options if needed

## File Structure

```
spark-vllm-compose/
├── head/
│   ├── .env              # Head node configuration (IPs, paths)
│   ├── compose.yaml      # Head node Docker Compose config
│   └── ray-start-head.sh # Ray cluster initialization script
├── worker1/
│   ├── .env              # Worker 1 configuration (IPs, paths)
│   └── compose.yaml      # Worker 1 Docker Compose config
└── models/               # Mount point for your models (gitignored)
```

## Dependencies

- **Base image**: `vllm-node-tf5` (built from [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker))
  - Note: Official NGC vLLM containers have outdated transformers versions
- **vLLM**: Latest version with Ray distributed executor backend
- **RDMA/RoCE**: Required for multi-node NCCL communication

## Auto-Restart Behavior

Docker Compose is configured with `restart: unless-stopped`, which means:

- **Crash recovery**: If vLLM or Ray crashes/exits unexpectedly, the containers will automatically restart
- **Boot recovery**: Containers will start automatically after system reboot (if they were running before shutdown)
- **Manual stop**: Containers will NOT auto-restart if you manually run `docker compose down`

This ensures your cluster recovers from transient failures without manual intervention.
