#!/bin/bash

# =============================================================================
# Kubernetes Control Plane Installation Script
# =============================================================================
# 
# Description: Complete Kubernetes Control Plane Installation Script for CKA 
#              Certification Study and Production Use. Automatically installs 
#              latest Kubernetes cluster with containerd runtime and Cilium CNI 
#              on Ubuntu/Debian systems. This script should be run on the 
#              control plane server that will host the Kubernetes master node.
#
# Author:      DevOps Engineer
# Version:     1.0
# Last Updated: $(date +%Y-%m-%d)
# 
# Features:
# - Dynamic version detection (Kubernetes, containerd, runc, Cilium)
# - System requirements validation (CPU, RAM, sudo access)
# - Comprehensive error handling and recovery
# - Proper cleanup of previous installations
# - Automated kernel parameter configuration
# - Shell completion setup (bash/zsh/fish)
# - Production-ready configuration
# - Detailed logging and user feedback
#
# System Requirements:
# - Ubuntu 18.04+ or Debian 9+ (tested)
# - Minimum 2 CPU cores
# - Minimum 2GB RAM
# - Sudo privileges
# - Internet connectivity
#
# Usage:
#   Run this script on the control plane server:
#   chmod +x install_cp.sh
#   ./install_cp.sh
#
# What Gets Installed:
# - Latest Kubernetes (kubeadm, kubelet, kubectl)
# - containerd container runtime
# - runc container runtime
# - Cilium CNI plugin
# - Kubernetes cluster with single control plane
# - kubectl shell completion
#
# Network Configuration:
# - Pod subnet: 192.168.0.0/16
# - Control plane endpoint: k8scp:6443
# - Automatic /etc/hosts configuration
#
# Post-Installation:
# - Cluster ready for use
# - kubectl configured for current user
# - Cilium CNI active and tested
# - All services enabled and running
#
# Troubleshooting:
# - Check logs: journalctl -u kubelet -f
# - Verify cluster: kubectl get nodes
# - Test connectivity: kubectl cluster-info
#
# =============================================================================

set -e

echo "============================================="
echo "Starting Kubernetes Control Plane Installation"
echo "============================================="

echo ""
echo "Checking system requirements..."

# Check CPU count (minimum 2 cores)
CPU_COUNT=$(nproc)
if [ "$CPU_COUNT" -lt 2 ]; then
  echo "ERROR: Insufficient CPU cores. Found: $CPU_COUNT, Required: 2 or more"
  exit 1
fi
echo "CPU check passed: $CPU_COUNT cores available"

# Check RAM (minimum 2GB = 2097152 KB)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
MIN_RAM_KB=2097152 # 2GB in KB

if [ "$RAM_KB" -lt "$MIN_RAM_KB" ]; then
  echo "ERROR: Insufficient RAM. Found: ${RAM_GB}GB, Required: 2GB or more"
  exit 1
fi
echo "RAM check passed: ${RAM_GB}GB available"
echo "All system requirements met"
echo ""

# disable swap
echo "Disabling swap..."
sudo swapoff -a

# update and upgrade system
echo "Installing required system packages..."
sudo apt update
sudo apt install apt-transport-https software-properties-common ca-certificates socat curl -y

# Load kernel modules required for container runtimes and networking
# - overlay: Enables OverlayFS, used by container runtimes (containerd/Docker) for efficient layer storage
# - br_netfilter: Enables bridge netfilter support, allowing iptables rules to apply to bridged traffic
#   Required for the sysctl settings below to take effect
echo "Loading required kernel modules..."
sudo modprobe overlay
sudo modprobe br_netfilter

# Configure kernel networking parameters required for container networking
# These settings prepare the system for Kubernetes by enabling:
# - net.bridge.bridge-nf-call-ip6tables: Allow iptables to see bridged IPv6 traffic
# - net.bridge.bridge-nf-call-iptables: Allow iptables to see bridged IPv4 traffic
# - net.ipv4.ip_forward: Enable packet forwarding between network interfaces
# Without these, container networking (CNI plugins) won't function properly
echo "Configuring kernel networking parameters..."
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

echo "Applying kernel parameter changes..."
sysctl --system

# Verify ip_forward is enabled (required for Kubernetes)
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
  echo "ERROR: ip_forward is not enabled, attempting to fix..."
  echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
  # Also ensure it's set in the config file
  sudo sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/sysctl.d/kubernetes.conf
  sysctl --system

  # Verify again
  if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    echo "ERROR: Failed to enable ip_forward"
    exit 1
  fi
  echo "ip_forward successfully enabled"
fi

echo ""
echo "Cleaning up previous Kubernetes and container runtime installations"
# Stop services if they exist
sudo systemctl stop kubelet 2>/dev/null || true
sudo systemctl stop containerd 2>/dev/null || true

# Clean up Kubernetes if kubeadm is installed
if command -v kubeadm &>/dev/null; then
  sudo kubeadm reset -f || true
fi

# Remove Kubernetes directories
sudo rm -rf /etc/cni/net.d 2>/dev/null || true
sudo rm -rf /var/lib/cni/ 2>/dev/null || true
sudo rm -rf /etc/kubernetes/ 2>/dev/null || true
sudo rm -rf /var/lib/kubelet/ 2>/dev/null || true
sudo rm -rf /var/lib/etcd/ 2>/dev/null || true
sudo rm -rf /var/lib/dockershim/ 2>/dev/null || true
sudo rm -rf /etc/systemd/system/kubelet.service.d 2>/dev/null || true

# Clean container images if crictl is available
if command -v crictl &>/dev/null; then
  sudo crictl rmi "$(sudo crictl images -q)" 2>/dev/null || true
fi

# Remove containerd state
sudo rm -rf /var/lib/containerd/ 2>/dev/null || true

# Detect system OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case $ARCH in
x86_64) ARCH="amd64" ;;
aarch64) ARCH="arm64" ;;
armv7l) ARCH="arm" ;;
*)
  echo "Unsupported architecture: $ARCH"
  exit 1
  ;;
esac

# Get latest containerd release version from GitHub API
CONTAINERD_VERSION=$(curl -s https://api.github.com/repos/containerd/containerd/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [ -z "$CONTAINERD_VERSION" ]; then
  echo "Failed to fetch latest containerd version, using fallback"
  CONTAINERD_VERSION="2.1.3"
fi

echo "Installing containerd $CONTAINERD_VERSION for $OS-$ARCH"
CONTAINERD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-${OS}-${ARCH}.tar.gz"
curl -LO "$CONTAINERD_URL"
sudo tar -xzf "containerd-${CONTAINERD_VERSION}-${OS}-${ARCH}.tar.gz" -C /usr/local
rm "containerd-${CONTAINERD_VERSION}-${OS}-${ARCH}.tar.gz"
/usr/local/bin/containerd --version
sudo curl -L https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -o /etc/systemd/system/containerd.service

# Get latest runc release version from GitHub API
RUNC_VERSION=$(curl -s https://api.github.com/repos/opencontainers/runc/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [ -z "$RUNC_VERSION" ]; then
  echo "Failed to fetch latest runc version, using fallback"
  RUNC_VERSION="1.3.0"
fi

echo "Installing runc $RUNC_VERSION for $ARCH"
RUNC_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${ARCH}"
sudo curl -L "$RUNC_URL" -o /usr/local/sbin/runc
sudo chmod +x /usr/local/sbin/runc

echo "Setting up containerd configuration"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup for better integration with systemd
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Get latest Kubernetes version from GitHub API
K8S_VERSION=$(curl -s https://api.github.com/repos/kubernetes/kubernetes/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [ -z "$K8S_VERSION" ]; then
  echo "Failed to fetch latest Kubernetes version, using fallback"
  K8S_VERSION="1.33.1"
fi

echo ""
echo "Detected latest Kubernetes version: $K8S_VERSION"

# Dynamically get pause container version from Kubernetes source code
# The pause version is defined in cmd/kubeadm/app/constants/constants.go
RELEASE_BRANCH="release-${K8S_VERSION}"
CONSTANTS_URL="https://raw.githubusercontent.com/kubernetes/kubernetes/$RELEASE_BRANCH/cmd/kubeadm/app/constants/constants.go"

echo "Fetching pause container version from Kubernetes source..."
# Try multiple patterns to find the pause version
PAUSE_VERSION=$(curl -s "$CONSTANTS_URL" | grep -E "(PauseVersion|pauseVersion)" | grep -E "=.*\".*\"" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

# If that fails, try alternative patterns
if [ -z "$PAUSE_VERSION" ]; then
  PAUSE_VERSION=$(curl -s "$CONSTANTS_URL" | grep -i "pause.*version" | grep -E "=.*\".*\"" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

# If that fails, try with the main branch
if [ -z "$PAUSE_VERSION" ]; then
  MAIN_CONSTANTS_URL="https://raw.githubusercontent.com/kubernetes/kubernetes/master/cmd/kubeadm/app/constants/constants.go"
  PAUSE_VERSION=$(curl -s "$MAIN_CONSTANTS_URL" | grep -E "(PauseVersion|pauseVersion)" | grep -E "=.*\".*\"" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

# Fallback to static mapping if GitHub fetch fails
if [ -z "$PAUSE_VERSION" ]; then
  echo "Failed to fetch pause version from source, using static mapping"
  K8S_MINOR=$(echo "$K8S_VERSION" | cut -d. -f1,2)
  case "$K8S_MINOR" in
  "1.33" | "1.32" | "1.31") PAUSE_VERSION="3.10" ;;
  "1.30" | "1.29") PAUSE_VERSION="3.9" ;;
  "1.28" | "1.27") PAUSE_VERSION="3.9" ;;
  "1.26" | "1.25") PAUSE_VERSION="3.8" ;;
  *) PAUSE_VERSION="3.10" ;;
  esac
fi

echo "Using pause image version $PAUSE_VERSION for Kubernetes $K8S_VERSION"

# Update pause image in containerd config
sudo sed -i "s|sandbox_image = \".*\"|sandbox_image = \"registry.k8s.io/pause:${PAUSE_VERSION}\"|g" /etc/containerd/config.toml

# Start containerd service
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd

# Verify containerd is running
if ! sudo systemctl is-active --quiet containerd; then
  echo "ERROR: containerd failed to start"
  sudo journalctl -xeu containerd | tail -20
  exit 1
fi

echo "Containerd is running successfully"
sudo /usr/local/bin/ctr version

echo ""
echo "Kubernetes Installation"
# Extract major.minor version for repository path
K8S_REPO_VERSION=$(echo "$K8S_VERSION" | cut -d. -f1,2)
echo "Using Kubernetes repository version: $K8S_REPO_VERSION"

# Remove existing keyring to avoid interactive prompt
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v"$K8S_REPO_VERSION"/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_REPO_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update

# Install specific Kubernetes version (need to determine package version format)
K8S_PKG_VERSION="${K8S_VERSION}-1.1"
echo "Installing Kubernetes components version: $K8S_PKG_VERSION"
sudo apt install -y kubeadm="$K8S_PKG_VERSION" kubelet="$K8S_PKG_VERSION" kubectl="$K8S_PKG_VERSION"
sudo apt-mark hold kubelet kubeadm kubectl

# Control plane DNS entries in /etc/hosts
echo "Update /etc/hosts with control plane entries"
# Detect control plane IP address using ip addr command
# Get the primary network interface IP (excluding loopback)
CONTROL_PLANE_IP=$(ip addr show | grep -E "inet [0-9]+" | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$CONTROL_PLANE_IP" ]; then
  echo "ERROR: Failed to detect IP address. No network interface found."
  echo "Please ensure network interfaces are configured properly."
  exit 1
fi

echo "Detected control plane IP: $CONTROL_PLANE_IP"

# Detect hostname for control plane node
CONTROL_PLANE_HOSTNAME=$(hostname)
echo "Control plane hostname: $CONTROL_PLANE_HOSTNAME"

# Configure /etc/hosts for Kubernetes control plane
echo "Configuring /etc/hosts for Kubernetes control plane..."
sudo sed -i '/k8scp/d' /etc/hosts
sudo sed -i "/[[:space:]]${CONTROL_PLANE_HOSTNAME}$/d" /etc/hosts

{
  echo "$CONTROL_PLANE_IP k8scp"
  echo "$CONTROL_PLANE_IP $CONTROL_PLANE_HOSTNAME"
  cat /etc/hosts
} | sudo tee /etc/hosts.tmp >/dev/null
sudo mv /etc/hosts.tmp /etc/hosts

# Determine kubeadm API version dynamically
if command -v kubeadm >/dev/null 2>&1; then
  KUBEADM_API_VERSION=$(kubeadm config print init-defaults 2>/dev/null | grep "apiVersion:" | head -1 | awk '{print $2}')
fi

if [ -z "$KUBEADM_API_VERSION" ]; then
  VERSION_NUM=$(echo "$K8S_VERSION" | sed 's/v//' | cut -d. -f1,2 | tr -d '.')
  if [ "$VERSION_NUM" -ge 131 ]; then
    KUBEADM_API_VERSION="kubeadm.k8s.io/v1beta4"
  elif [ "$VERSION_NUM" -ge 115 ]; then
    KUBEADM_API_VERSION="kubeadm.k8s.io/v1beta3"
  else
    KUBEADM_API_VERSION="kubeadm.k8s.io/v1beta2"
  fi
fi

echo "Using kubeadm API version: $KUBEADM_API_VERSION for Kubernetes $K8S_VERSION"

# Configure kubeadm-config.yaml with detected Kubernetes version
if [ -f "kubeadm-config.yaml" ]; then
  echo "Updating kubeadm-config.yaml with Kubernetes version $K8S_VERSION"
  sudo sed -i "s/kubernetesVersion:.*/kubernetesVersion: $K8S_VERSION/" kubeadm-config.yaml
  sudo sed -i "s|apiVersion:.*|apiVersion: $KUBEADM_API_VERSION|" kubeadm-config.yaml
else
  echo "Creating kubeadm-config.yaml with Kubernetes version $K8S_VERSION"
  cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: $KUBEADM_API_VERSION
kind: ClusterConfiguration
kubernetesVersion: $K8S_VERSION
controlPlaneEndpoint: "k8scp:6443"
networking:
  podSubnet: 192.168.0.0/16
EOF
fi

echo ""
echo "Initializing Kubernetes cluster..."
if ! sudo kubeadm init --config=kubeadm-config.yaml --upload-certs --node-name="$CONTROL_PLANE_HOSTNAME" | tee kubeadm-init.out; then
  echo "ERROR: kubeadm init failed"
  exit 1
fi

# Configure kubectl for the current user
echo "Configuring kubectl for user $(whoami)..."
mkdir -p "$HOME"/.kube
sudo cp /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# Verify kubectl configuration
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl configuration failed"
  exit 1
fi

echo "Kubernetes cluster initialized successfully"

echo ""
echo "Installing Cilium CNI..."
# Get latest Cilium CLI version
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
if [ -z "$CILIUM_CLI_VERSION" ]; then
  echo "Failed to fetch Cilium CLI version"
  exit 1
fi

echo "Installing Cilium CLI version: $CILIUM_CLI_VERSION"
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/"$CILIUM_CLI_VERSION"/cilium-linux-"$ARCH".tar.gz{,.sha256sum}

# Verify checksum
if ! sha256sum --check cilium-linux-"$ARCH".tar.gz.sha256sum; then
  echo "ERROR: Cilium CLI checksum verification failed"
  rm -f cilium-linux-"$ARCH".tar.gz*
  exit 1
fi

# Install Cilium CLI
sudo tar xzf cilium-linux-"$ARCH".tar.gz -C /usr/local/bin
rm cilium-linux-"$ARCH".tar.gz{,.sha256sum}

# Get latest Cilium version
CILIUM_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium/main/stable.txt)
if [ -z "$CILIUM_VERSION" ]; then
  echo "Failed to fetch Cilium version"
  exit 1
fi

echo "Installing Cilium version: $CILIUM_VERSION"

# Install Cilium
if ! cilium install --version "${CILIUM_VERSION}"; then
  echo "ERROR: Cilium installation failed"
  exit 1
fi

# Check node taints and remove control-plane taint for single-node setup
kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' | grep -q "node-role.kubernetes.io/control-plane" && {
  echo "Removing control-plane taint for single-node setup..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

# Wait for Cilium to be ready
echo "Waiting for Cilium to be ready..."
cilium status --wait

# Test Cilium connectivity
echo "Testing Cilium connectivity..."
if ! cilium connectivity test; then
  echo "WARNING: Cilium connectivity test failed, but installation may still be functional"
  echo "You can run 'cilium connectivity test' later to verify connectivity"
else
  echo "Cilium connectivity test passed successfully"
fi

echo "Cilium installation completed successfully"

echo ""
echo "Setting up kubectl shell completion..."

# Detect user's current shell
CURRENT_SHELL=$(basename "$SHELL")
case "$CURRENT_SHELL" in
bash)
  SHELL_RC_FILE="$HOME/.bashrc"
  COMPLETION_COMMAND="source <(kubectl completion bash)"
  ALIAS_COMPLETION="complete -o default -F __start_kubectl k"
  COMPLETION_PACKAGE="bash-completion"
  ;;
zsh)
  SHELL_RC_FILE="$HOME/.zshrc"
  COMPLETION_COMMAND="source <(kubectl completion zsh)"
  ALIAS_COMPLETION="compdef __start_kubectl k"
  COMPLETION_PACKAGE="zsh-completions"
  ;;
fish)
  SHELL_RC_FILE="$HOME/.config/fish/config.fish"
  COMPLETION_COMMAND="kubectl completion fish | source"
  ALIAS_COMPLETION="" # Fish handles aliases differently
  COMPLETION_PACKAGE=""
  ;;
*)
  echo "WARNING: Unsupported shell ($CURRENT_SHELL), defaulting to bash completion"
  SHELL_RC_FILE="$HOME/.bashrc"
  COMPLETION_COMMAND="source <(kubectl completion bash)"
  ALIAS_COMPLETION="complete -o default -F __start_kubectl k"
  COMPLETION_PACKAGE="bash-completion"
  ;;
esac

echo "Detected shell: $CURRENT_SHELL"

# Install completion package if specified
if [ -n "$COMPLETION_PACKAGE" ]; then
  if ! sudo apt install "$COMPLETION_PACKAGE" -y; then
    echo "WARNING: Failed to install $COMPLETION_PACKAGE package"
  fi
fi

# Create shell config file if it doesn't exist
mkdir -p "$(dirname "$SHELL_RC_FILE")"
touch "$SHELL_RC_FILE"

# Add kubectl alias if not already present
if ! grep -q "alias k='kubectl'" "$SHELL_RC_FILE" 2>/dev/null; then
  echo "alias k='kubectl'" >>"$SHELL_RC_FILE"
  echo "Added kubectl alias 'k' to $(basename "$SHELL_RC_FILE")"
fi

# Add kubectl completion if not already present
if ! grep -q "kubectl completion" "$SHELL_RC_FILE" 2>/dev/null; then
  echo "$COMPLETION_COMMAND" >>"$SHELL_RC_FILE"
  echo "Added kubectl completion to $(basename "$SHELL_RC_FILE")"
fi

# Add completion for 'k' alias if applicable and not already present
if [ -n "$ALIAS_COMPLETION" ] && ! grep -q "__start_kubectl k" "$SHELL_RC_FILE" 2>/dev/null; then
  echo "$ALIAS_COMPLETION" >>"$SHELL_RC_FILE"
  echo "Added completion for 'k' alias to $(basename "$SHELL_RC_FILE")"
fi

echo "Shell completion setup completed for $CURRENT_SHELL"

echo ""
echo "============================================="
echo "Kubernetes cluster installation completed!"
echo "============================================="
echo "Cluster details:"
echo "  - Kubernetes version: $K8S_VERSION"
echo "  - Control plane IP: $CONTROL_PLANE_IP"
echo "  - Control plane hostname: $CONTROL_PLANE_HOSTNAME"
echo "  - CNI: Cilium $CILIUM_VERSION"
echo "  - kubeadm API version: $KUBEADM_API_VERSION"
echo ""
echo ""
echo "Next steps:"
echo "  1. Run 'source $(basename "$SHELL_RC_FILE")' or start a new terminal session to activate completions"
echo "  2. Test cluster: kubectl get nodes"
echo "  3. View cluster info: kubectl cluster-info"
echo "============================================="
echo ""
