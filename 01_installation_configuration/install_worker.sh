#!/bin/bash
#
# Kubernetes Worker Node Installation Script
#
# Usage:
#   1. With command line argument:
#      ./install_worker.sh <CONTROL_PLANE_IP>
#      Example: ./install_worker.sh <CONTROL_PLANE_IP>
#
#   2. With environment variable:
#      CONTROL_PLANE_IP=<CONTROL_PLANE_IP> ./install_worker.sh
#
#   3. Interactive mode (will prompt for IP):
#      ./install_worker.sh
#
# Requirements:
#   - Ubuntu/Debian-based system
#   - Sudo privileges
#   - Minimum 2 CPU cores and 2GB RAM
#   - Network connectivity to control plane
#

set -e

echo "============================================="
echo "Starting Kubernetes Worker Installation"
echo "============================================="

echo ""
echo "Checking for control plane IP..."

# Check for control plane IP from environment variable or command line argument
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-$1}"

if [ -z "$CONTROL_PLANE_IP" ]; then
  echo ""
  echo "Control plane IP not provided."
  echo "Please provide the IP address of your Kubernetes control plane node."
  echo ""
  read -r -p "Enter control plane IP address: " CONTROL_PLANE_IP
  
  if [ -z "$CONTROL_PLANE_IP" ]; then
    echo "ERROR: Control plane IP is required"
    exit 1
  fi
fi

# Validate IP address format
if ! echo "$CONTROL_PLANE_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
  echo "ERROR: Invalid IP address format: $CONTROL_PLANE_IP"
  exit 1
fi

echo "Using control plane IP: $CONTROL_PLANE_IP"

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

# worker plane DNS entries in /etc/hosts
echo "Update /etc/hosts with worker plane entries"
# Detect worker plane IP address using ip addr command
# Get the primary network interface IP (excluding loopback)
WORKER_PLANE_IP=$(ip addr show | grep -E "inet [0-9]+" | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$WORKER_PLANE_IP" ]; then
  echo "ERROR: Failed to detect IP address. No network interface found."
  echo "Please ensure network interfaces are configured properly."
  exit 1
fi

echo "Detected worker plane IP: $WORKER_PLANE_IP"

# Detect hostname for worker plane node
WORKER_PLANE_HOSTNAME=$(hostname)
echo "worker plane hostname: $WORKER_PLANE_HOSTNAME"

# Configure /etc/hosts for Kubernetes worker plane
echo "Configuring /etc/hosts for Kubernetes worker plane..."
sudo sed -i '/k8scp/d' /etc/hosts
sudo sed -i "/[[:space:]]${WORKER_PLANE_HOSTNAME}$/d" /etc/hosts

{
  echo "$CONTROL_PLANE_IP k8scp"
  echo "$WORKER_PLANE_IP $WORKER_PLANE_HOSTNAME"
  cat /etc/hosts
} | sudo tee /etc/hosts.tmp >/dev/null
sudo mv /etc/hosts.tmp /etc/hosts
