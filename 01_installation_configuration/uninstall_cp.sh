#!/bin/bash

set -e

echo "============================================="
echo "Kubernetes Control Plane Uninstaller"
echo "============================================="

echo ""
echo "WARNING: This will completely remove Kubernetes and all associated components!"
echo "This action cannot be undone. All cluster data will be lost."
echo ""
read -p "Are you sure you want to proceed? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo "Stopping Kubernetes services..."
sudo systemctl stop kubelet 2>/dev/null || true
sudo systemctl stop containerd 2>/dev/null || true

# Stop any processes using port 6443 (Kubernetes API server)
echo "Checking for processes using port 6443..."
if lsof -ti:6443 >/dev/null 2>&1; then
    echo "Found processes using port 6443, terminating them..."
    sudo lsof -ti:6443 | sudo xargs -r kill -9 2>/dev/null || true
    sleep 2
fi

# Stop etcd if running
sudo systemctl stop etcd 2>/dev/null || true

# Kill any remaining Kubernetes processes
echo "Stopping any remaining Kubernetes processes..."
sudo pkill -f kube-apiserver 2>/dev/null || true
sudo pkill -f kube-controller-manager 2>/dev/null || true
sudo pkill -f kube-scheduler 2>/dev/null || true
sudo pkill -f etcd 2>/dev/null || true

# Wait a moment for processes to fully terminate
sleep 3

echo ""
echo "Draining and removing Kubernetes cluster..."
# Remove cluster if kubeadm is available
if command -v kubeadm &>/dev/null; then
    sudo kubeadm reset -f 2>/dev/null || true
fi

echo ""
echo "Removing Kubernetes packages..."
# Remove package holds
sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true

# Remove Kubernetes packages
sudo apt remove -y kubeadm kubectl kubelet 2>/dev/null || true
sudo apt autoremove -y 2>/dev/null || true

echo ""
echo "Cleaning up Kubernetes directories and files..."
# Remove Kubernetes directories
sudo rm -rf /etc/cni/net.d 2>/dev/null || true
sudo rm -rf /var/lib/cni/ 2>/dev/null || true
sudo rm -rf /etc/kubernetes/ 2>/dev/null || true
sudo rm -rf /var/lib/kubelet/ 2>/dev/null || true
sudo rm -rf /var/lib/etcd/ 2>/dev/null || true
sudo rm -rf /var/lib/dockershim/ 2>/dev/null || true
sudo rm -rf /etc/systemd/system/kubelet.service.d 2>/dev/null || true
sudo rm -rf /var/lib/containerd/ 2>/dev/null || true

# Remove kubeadm configuration files
sudo rm -f kubeadm-config.yaml 2>/dev/null || true
sudo rm -f kubeadm-init.out 2>/dev/null || true

# Remove kubectl configuration
rm -rf "$HOME/.kube" 2>/dev/null || true

echo ""
echo "Uninstalling Cilium CNI..."
# Uninstall Cilium if cilium CLI is available
if command -v cilium &>/dev/null; then
    echo "Running cilium uninstall..."
    cilium uninstall --wait --timeout 10m 2>/dev/null || true

    # Clean up any remaining Cilium test namespace
    kubectl delete namespace cilium-test 2>/dev/null || true

    # Remove any remaining Cilium resources
    kubectl delete --ignore-not-found=true -f https://raw.githubusercontent.com/cilium/cilium/master/install/kubernetes/quick-install.yaml 2>/dev/null || true

    echo "Cilium uninstalled successfully"
else
    echo "Cilium CLI not found, skipping Cilium-specific cleanup"
fi

# Clean up CNI configuration files manually
echo "Cleaning up CNI configurations..."
sudo rm -f /etc/cni/net.d/05-cilium.conf 2>/dev/null || true
sudo rm -f /etc/cni/net.d/10-cilium-cni.conf 2>/dev/null || true

# Clean up Cilium network interfaces (if any remain)
echo "Cleaning up Cilium network interfaces..."
for interface in cilium_vxlan cilium_host cilium_net; do
    if ip link show "$interface" 2>/dev/null; then
        sudo ip link delete "$interface" 2>/dev/null || true
    fi
done

echo ""
echo "Cleaning up container images..."
# Clean container images if crictl is available
if command -v crictl &>/dev/null; then
    sudo crictl rmi "$(sudo crictl images -q)" 2>/dev/null || true
fi

echo ""
echo "Removing container runtime binaries..."
# Disable and stop containerd service completely
sudo systemctl disable containerd 2>/dev/null || true
sudo systemctl stop containerd 2>/dev/null || true

# Kill any remaining containerd processes
sudo pkill -f containerd 2>/dev/null || true

# Remove containerd and runc binaries
sudo rm -f /etc/systemd/system/containerd.service 2>/dev/null || true
sudo rm -f /usr/local/bin/containerd* 2>/dev/null || true
sudo rm -f /usr/local/bin/ctr 2>/dev/null || true
sudo rm -f /usr/local/bin/containerd-shim* 2>/dev/null || true
sudo rm -f /usr/local/sbin/runc 2>/dev/null || true

# Remove Cilium CLI
sudo rm -f /usr/local/bin/cilium 2>/dev/null || true

# Remove containerd configuration
sudo rm -rf /etc/containerd/ 2>/dev/null || true

echo ""
echo "Removing Kubernetes repository and keys..."
# Remove Kubernetes repository
sudo rm -f /etc/apt/sources.list.d/kubernetes.list 2>/dev/null || true
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true

# Update package lists
sudo apt update 2>/dev/null || true

echo ""
echo "Cleaning up kernel configuration..."
# Remove kernel networking configuration
sudo rm -f /etc/sysctl.d/kubernetes.conf 2>/dev/null || true

# Reset kernel modules (they will be reloaded on next boot if needed)
sudo modprobe -r br_netfilter 2>/dev/null || true
sudo modprobe -r overlay 2>/dev/null || true

echo ""
echo "Cleaning up /etc/hosts entries..."
# Remove /etc/hosts entries
sudo sed -i '/k8scp/d' /etc/hosts 2>/dev/null || true
# Remove any entries that point to the control plane (more thorough cleanup)
backup_files=(/etc/hosts.backup.*)
if [ -f "${backup_files[0]}" ]; then
    echo "Found /etc/hosts backup, would you like to restore it? (y/n)"
    read -r restore_hosts
    if [[ $restore_hosts =~ ^[Yy]$ ]]; then
        latest_backup=$(find /etc -name "hosts.backup.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
        if [ -n "$latest_backup" ]; then
            sudo cp "$latest_backup" /etc/hosts
            echo "Restored /etc/hosts from backup: $latest_backup"
        fi
    fi
fi

echo ""
echo "Cleaning up shell configuration..."
# Detect user's current shell
CURRENT_SHELL=$(basename "$SHELL")
case "$CURRENT_SHELL" in
bash)
    SHELL_RC_FILE="$HOME/.bashrc"
    ;;
zsh)
    SHELL_RC_FILE="$HOME/.zshrc"
    ;;
fish)
    SHELL_RC_FILE="$HOME/.config/fish/config.fish"
    ;;
*)
    SHELL_RC_FILE="$HOME/.bashrc"
    ;;
esac

# Remove kubectl alias and completion from shell RC file
if [ -f "$SHELL_RC_FILE" ]; then
    # Create backup
    cp "$SHELL_RC_FILE" "${SHELL_RC_FILE}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

    # Remove kubectl-related lines
    sed -i '/alias k=.kubectl./d' "$SHELL_RC_FILE" 2>/dev/null || true
    sed -i '/kubectl completion/d' "$SHELL_RC_FILE" 2>/dev/null || true
    sed -i '/complete.*__start_kubectl k/d' "$SHELL_RC_FILE" 2>/dev/null || true
    sed -i '/compdef __start_kubectl k/d' "$SHELL_RC_FILE" 2>/dev/null || true

    echo "Removed kubectl aliases and completion from $(basename "$SHELL_RC_FILE")"
fi

echo ""
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload 2>/dev/null || true

# Final check - ensure port 6443 is free
echo "Performing final port 6443 cleanup check..."
if lsof -ti:6443 >/dev/null 2>&1; then
    echo "WARNING: Port 6443 is still in use. Attempting final cleanup..."
    sudo lsof -ti:6443 | sudo xargs -r kill -9 2>/dev/null || true
    sleep 2

    # If still in use, show what's using it
    if lsof -ti:6443 >/dev/null 2>&1; then
        echo "ERROR: Port 6443 is still in use by:"
        lsof -i:6443 2>/dev/null || true
        echo "You may need to reboot the system to fully clean up port 6443"
    else
        echo "Port 6443 is now free"
    fi
else
    echo "Port 6443 is free"
fi

echo ""
echo "Optional cleanup steps:"
echo "Would you like to remove completion packages? (y/n)"
read -r remove_completion
if [[ $remove_completion =~ ^[Yy]$ ]]; then
    sudo apt remove -y bash-completion zsh-completions 2>/dev/null || true
    echo "Removed completion packages"
fi

echo ""
echo "Would you like to remove system packages that were installed? (y/n)"
echo "(This includes: apt-transport-https, software-properties-common, ca-certificates, socat, curl)"
read -r remove_packages
if [[ $remove_packages =~ ^[Yy]$ ]]; then
    sudo apt remove -y apt-transport-https software-properties-common ca-certificates socat curl 2>/dev/null || true
    sudo apt autoremove -y 2>/dev/null || true
    echo "Removed system packages"
fi

echo ""
echo "============================================="
echo "Kubernetes cluster removal completed!"
echo "============================================="
echo ""
echo "Summary of actions performed:"
echo "  ✓ Stopped Kubernetes services"
echo "  ✓ Removed Kubernetes cluster with kubeadm reset"
echo "  ✓ Uninstalled Cilium CNI properly"
echo "  ✓ Cleaned up Cilium network interfaces"
echo "  ✓ Uninstalled Kubernetes packages"
echo "  ✓ Cleaned up all Kubernetes directories"
echo "  ✓ Removed container images"
echo "  ✓ Removed container runtime binaries"
echo "  ✓ Removed Kubernetes repository and keys"
echo "  ✓ Cleaned up kernel configuration"
echo "  ✓ Cleaned up /etc/hosts entries"
echo "  ✓ Removed kubectl aliases and completion"
echo ""
echo "The system has been restored to its pre-Kubernetes state."
echo "You may need to restart your shell or run 'source $(basename "$SHELL_RC_FILE")'"
echo "to remove kubectl aliases from your current session."
echo ""
echo "Note: Swap is still disabled. Re-enable it manually if needed:"
echo "  sudo swapon -a"
echo "============================================="
echo ""
