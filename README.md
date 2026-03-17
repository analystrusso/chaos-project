# chaos-project

A chaos engineering lab built on AWS EC2, demonstrating infrastructure resilience through hypothesis-driven fault injection experiments. The full stack — from cloud infrastructure to observability to fault injection — is provisioned and configured entirely through code.

---

## What This Project Demonstrates

- **Infrastructure as Code** with Terraform (VPC, EC2, security groups, TLS key pair)
- **Configuration management** with Ansible (k3s cluster bootstrapping, Helm deployments, application setup)
- **Multi-node Kubernetes** via k3s on EC2 (beyond single-node minikube)
- **Observability** with Prometheus and Grafana (kube-prometheus-stack)
- **Horizontal Pod Autoscaling** tied to real CPU metrics via metrics-server
- **Chaos engineering** with Chaos Mesh, following a hypothesis-driven methodology
- **Load generation** with k6 to produce measurable signal during experiments

---

## Architecture

```
AWS (us-east-2)
└── VPC (10.0.0.0/16)
    └── Public Subnet (10.0.1.0/24)
        ├── chaos-master (t3.small) — k3s control plane, Helm, Prometheus, Grafana, Chaos Mesh
        ├── chaos-worker-0 (t3.small) — k3s worker
        └── chaos-worker-1 (t3.small) — k3s worker

Kubernetes workloads (default namespace):
├── target-app (nginx, 3 replicas) — experiment target
├── k6-load-generator — continuous traffic against target-app
└── target-app-hpa — scales target-app 3→9 replicas at 50% CPU

Kubernetes workloads (monitoring namespace):
└── kube-prometheus-stack (Prometheus, Grafana, Alertmanager, node-exporter)

Kubernetes workloads (chaos-mesh namespace):
└── Chaos Mesh (controller, daemon x3, dashboard, DNS server)
```

---

## Prerequisites

### Local machine
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/index.html) >= 2.12 (`pip install ansible`)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with sufficient IAM permissions
- SSH client

### AWS IAM permissions required
Your IAM user needs permissions for: EC2 (instances, VPCs, security groups, key pairs), and the ability to describe regions and availability zones.

---

## Cost

Three `t3.small` instances at ~$0.0208/hr each. **Tear down when not in use** — `terraform destroy` removes all resources. Rebuild takes approximately 10-15 minutes.

---

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/analystrusso/chaos-project
cd chaos-project
```

### 2. Configure AWS credentials

```bash
aws configure
```

### 3. Create terraform.tfvars

Copy the example file and fill in real values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Required values:

```hcl
region = "us-east-2"
my_ip  = "YOUR.PUBLIC.IP.ADDRESS/32"   # find with: curl ifconfig.me
default_tags = {
  project     = "chaos-engineering"
  environment = "dev"
  owner       = "yourname"
}
```

> **Find your public IP:** `curl ifconfig.me` — append `/32` for CIDR notation.

### 4. Provision infrastructure

```bash
terraform init
terraform apply
```

Terraform will output the public IPs of all three instances when complete.

### 5. Update Ansible inventory

Edit `ansible/inventory.ini` with the IPs from Terraform output:

```ini
[master]
chaos-master ansible_host=<master_public_ip> ansible_user=ubuntu ansible_ssh_private_key_file=/home/youruser/chaos-project/chaos-keypair.pem

[workers]
chaos-worker-0 ansible_host=<worker_0_public_ip> ansible_user=ubuntu ansible_ssh_private_key_file=/home/youruser/chaos-project/chaos-keypair.pem
chaos-worker-1 ansible_host=<worker_1_public_ip> ansible_user=ubuntu ansible_ssh_private_key_file=/home/youruser/chaos-project/chaos-keypair.pem
```

> **Use absolute paths** for `ansible_ssh_private_key_file` — relative paths behave unpredictably depending on where you invoke ansible-playbook from.

### 6. Run the Ansible playbook

```bash
ansible-playbook -i ansible/inventory.ini ansible/playbook.yaml
```

This takes approximately 10-15 minutes. It will:
1. Retrieve the k3s join token from the master
2. Join both workers to the cluster using the master's **private IP**
3. Verify all 3 nodes are Ready
4. Install Helm
5. Deploy kube-prometheus-stack (Prometheus + Grafana)
6. Install Chaos Mesh
7. Deploy target-app (nginx, 3 replicas) with HPA
8. Deploy k6 load generator
9. Install metrics-server

> **Do not run the playbook while the cluster is under heavy load.** The API server on t3.small instances can time out during Helm operations under CPU pressure. Scale k6 to zero first: `kubectl scale deployment k6-load-generator --replicas=0 -n default`

---

## Accessing Services

All services require SSH tunneling — there is no Ingress configured and k3s is not installed on your local machine.

### Grafana

```bash
ssh -i chaos-keypair.pem -L 3000:localhost:3000 ubuntu@<master_public_ip> \
  "sudo k3s kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80 --address 127.0.0.1"
```

Open `http://localhost:3000` — credentials: `admin` / `prom-operator`

### Chaos Mesh Dashboard

```bash
ssh -i chaos-keypair.pem -L 2333:localhost:2333 ubuntu@<master_public_ip> \
  "sudo k3s kubectl port-forward svc/chaos-dashboard -n chaos-mesh 2333:2333 --address 127.0.0.1"
```

Open `http://localhost:2333`

> **If port-forward fails with "address already in use":** A previous session left a dangling port-forward process on the master. SSH in and run `sudo pkill -f "port-forward"` then retry.

### Chaos Mesh Dashboard — RBAC Token

The dashboard requires a service account token. Generate one each session:

```bash
sudo k3s kubectl create token chaos-admin -n chaos-mesh --duration=24h
```

If the `chaos-admin` service account doesn't exist yet:

```bash
sudo k3s kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: chaos-admin
  namespace: chaos-mesh
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: chaos-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: chaos-admin
    namespace: chaos-mesh
EOF
```

---

## Tear Down and Rebuild

```bash
# Tear down
terraform destroy

# Rebuild (after terraform apply)
# Update IPs in ansible/inventory.ini, then:
ansible-playbook -i ansible/inventory.ini ansible/playbook.yaml
```

The only manual step between destroy and rebuild is updating the IPs in `inventory.ini` — everything else is fully automated.

---

## Chaos Experiments

Experiments are defined as Kubernetes manifests in `experiments/` and applied with:

```bash
sudo k3s kubectl apply -f experiments/<experiment>.yaml
```

All experiments follow a hypothesis-driven structure: define steady state, state a hypothesis, inject the fault, observe, document the result.

### Steady State Definition

Established under baseline load (k6, 10 VUs):

| Metric | Baseline Value |
|--------|---------------|
| Available replicas | 3/3 |
| CPU utilization | ~1-5% |
| Packet drops | 0 p/s |
| k6 error rate | 0% |

---

### Experiment 1: Single Node Failure

**Hypothesis:** When a single worker node is lost, Kubernetes will reschedule all affected pods to surviving nodes within 2 minutes, with k6 error rate below 5% throughout recovery.

**Method:** Cordon and drain one worker node while k6 runs continuously.

```bash
sudo k3s kubectl cordon <worker-node>
sudo k3s kubectl drain <worker-node> --ignore-daemonsets --delete-emptydir-data
```

To restore:
```bash
sudo k3s kubectl uncordon <worker-node>
```

**Result: CONFIRMED**
- Recovery time: ~3 seconds
- Packet drops during recovery: 0
- k6 errors during recovery: 0
- Grafana showed pod transition with zero dropped packets

**Limitation:** Recovery was faster than Prometheus' default 15s scrape interval, making the event nearly invisible in Grafana. The kubectl watch and zero packet drop metrics are the primary evidence.

---

### Experiment 2: Traffic Spike and Horizontal Autoscaling

**Hypothesis:** When traffic spikes to 5x baseline, HPA will scale target-app beyond 3 replicas to maintain CPU utilization below the 50% threshold, and scale back down within 5 minutes of load dropping.

**Method:** k6 ramps from 10 to 100 VUs over 2 minutes, sustains for 5 minutes, then drops back.

k6 stages (configured in the k6-script ConfigMap):
```javascript
stages: [
  { duration: '1m', target: 10 },   // baseline
  { duration: '2m', target: 100 },  // spike
  { duration: '5m', target: 100 },  // sustained
  { duration: '2m', target: 10 },   // recovery
]
```

**Result: CONFIRMED**
- HPA triggered scaling at ~50% CPU utilization
- Replica count increased from 3 to 6 during sustained load
- System scaled back to 3 replicas after ~5 minute stabilization window
- No errors observed during scale-up or scale-down

**Key observation:** CPU request tuning is critical for HPA behavior. With requests set too high (100m), actual utilization never exceeded 15% regardless of load, preventing HPA from triggering. With requests set to 10m, the same load produced 50%+ utilization and triggered autoscaling as expected.

---


### Experiment 3: Traffic Latency Injection

**Hypothesis:** When 200ms of artificial latency is injected on target-app pods, the application remains available and k6 maintains a near-zero error rate, but p99 response latency increases proportionally.

**Method:** Chaos Mesh injected 200ms of network latency with 50ms jitter and 25% correlation on all target-app pods for 5 minutes. k6 ran continuously at 50 VUs throughout, measuring the impace on response times and error rate. Jitter and correlation were included to more realistically model real-world network conditions rather than a flat artificial delay.

```
mkdir -p /home/ubuntu/experiments
cat <<EOF > /home/ubuntu/experiments/network-latency-01.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: network-latency-01
  namespace: chaos-mesh
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - default
    labelSelectors:
      app: target-app
  delay:
    latency: 200ms
    correlation: "25"
    jitter: 50ms
  duration: 5m
EOF
```
Verify k6 is running before injecting:
```bash
sudo k3s kubectl logs -l app=k6 -n default --tail=5
```
Apply the experiment
```bash
sudo k3s kubectl apply -f /home/ubuntu/experiments/network-latency-01.yaml
```
The experiment runs for 5 minutes before quitting automatically. Results are captured in the k6 summary output after completion.
```bash
sudo k3s kubectl logs -l app=k6 -n default --tail=50
```

**Result: CONFIRMED**
- Baseline avg response time: ~6ms
- Response time under 200ms injection: avg 154ms, p95 246ms
- Error rate during injection: 0.04% (14/34803 requests)
- Application remained available throughout

---

## Known Limitations and Gotchas

**Inventory IPs change on every terraform apply.** There is no dynamic inventory configured. Update `ansible/inventory.ini` manually after each `terraform apply`. A future improvement would use Ansible's AWS EC2 dynamic inventory plugin.

**Workers must join via private IP.** The k3s API server on port 6443 is restricted to VPC CIDR in the security group. Using the master's public IP for K3S_URL will cause workers to fail silently — the k3s-agent service will run but never successfully join the cluster. Check `journalctl -u k3s-agent` on workers if nodes don't appear in `kubectl get nodes`.

**Helm operations can timeout under load.** The API server on t3.small instances has limited headroom. Scale k6 to zero before running the playbook against an existing cluster.

**Helm lock errors.** If the playbook is interrupted mid-run, Helm may leave a release in `pending-upgrade` state. Fix with: `helm rollback <release> -n <namespace> --kubeconfig /etc/rancher/k3s/k3s.yaml`

**Chaos Mesh requires containerd socket path.** k3s stores its containerd socket at `/run/k3s/containerd/containerd.sock`, not the default path. Without `--set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock` during Helm install, the chaos daemon installs successfully but cannot interact with containers — fault injection silently fails.

**Pod distribution is not guaranteed.** Without topology spread constraints, Kubernetes may schedule multiple target-app pods on the same node. The deployment manifest includes a `topologySpreadConstraint` to enforce one pod per node, but if pods are manually deleted and rescheduled they may land on the same node. Verify with `kubectl get pods -o wide` before running node-level experiments.

**SSH tunnels are required for all dashboards.** There is no Ingress or LoadBalancer configured. Both Grafana (port 3000) and the Chaos Mesh dashboard (port 2333) require SSH port forwarding from your local machine.

---

## Repository Structure

```
chaos-project/
├── .gitignore
├── providers.tf              # Terraform provider configuration
├── variables.tf              # Variable declarations
├── main.tf                   # AWS infrastructure (VPC, EC2, security groups, key pair)
├── outputs.tf                # Public IPs for master and workers
├── terraform.tfvars.example  # Safe template — copy to terraform.tfvars and fill in values
├── terraform.tfvars          # NOT committed — real values including your IP
├── chaos-keypair.pem         # NOT committed — generated by Terraform at apply time
├── user-data/
│   ├── master.sh             # k3s server install (runs at EC2 launch)
│   └── worker.sh             # Minimal worker prep (k3s agent installed by Ansible)
├── ansible/
│   ├── inventory.ini         # Host definitions — update IPs after each terraform apply
│   └── playbook.yaml         # Full cluster configuration playbook
└── experiments/
    ├── node-failure-01.yaml  # Experiment 1: single node drain
    └── traffic-spike-01.yaml # Experiment 2: HPA under load
```
