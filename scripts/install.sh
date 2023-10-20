#!/bin/sh
# This script installs Ollama on Linux.
# It detects the current operating system architecture and installs the appropriate version of Ollama.

set -eu

status() { echo ">>> $*" >&2; }
error() { echo "ERROR $*"; exit 1; }
warning() { echo "WARNING: $*"; }

TEMP_DIR=$(mktemp -d)
cleanup() { rm -rf $TEMP_DIR; }
trap cleanup EXIT

available() { command -v $1 >/dev/null; }
require() {
    local MISSING=''
    for TOOL in $*; do
        if ! available $TOOL; then
            MISSING="$MISSING $TOOL"
        fi
    done

    echo $MISSING
}

[ "$(uname -s)" = "Linux" ] || error 'This script is intended to run on Linux only.'

case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac

SUDO=
if [ "$(id -u)" -ne 0 ]; then
    # Running as root, no need for sudo
    if ! available sudo; then
        error "This script requires superuser permissions. Please re-run as root."
    fi

    SUDO="sudo"
fi

NEEDS=$(require curl awk grep sed tee xargs)
if [ -n "$NEEDS" ]; then
    status "ERROR: The following tools are required but missing:"
    for NEED in $NEEDS; do
        echo "  - $NEED"
    done
    exit 1
fi

status "Downloading ollama..."
curl --fail --show-error --location --progress-bar -o $TEMP_DIR/ollama "https://ollama.ai/download/ollama-linux-$ARCH"

for BINDIR in /usr/local/bin /usr/bin /bin; do
    echo $PATH | grep -q $BINDIR && break || continue
done

status "Installing ollama to $BINDIR..."
$SUDO install -o0 -g0 -m755 -d $BINDIR
$SUDO install -o0 -g0 -m755 $TEMP_DIR/ollama $BINDIR/ollama

install_success() { status 'Install complete. Run "ollama" from the command line.'; }
trap install_success EXIT

# Everything from this point onwards is optional.

configure_systemd() {
    status "Creating ollama systemd service..."
    # create the directories the service will need
    mkdir -p $HOME/.config/systemd/user/
    mkdir -p $HOME/.ollama/logs/
    # add the service for the current user
    cat <<EOF | $SUDO tee $HOME/.config/systemd/user/ollama.service >/dev/null
[Unit]
Description=Ollama

[Service]
ExecStart=$BINDIR/ollama serve
Restart=always
RestartSec=3
Environment="HOME=$HOME"
StandardOutput=file:$HOME/.ollama/logs/server.log 
StandardError=file:$HOME/.ollama/logs/server.log 
Environment="PATH=$PATH"

[Install]
WantedBy=default.target
EOF

    SYSTEMCTL_RUNNING="$(systemctl --user is-system-running || true)"
    case $SYSTEMCTL_RUNNING in
        running|degraded)
            status "Enabling and starting ollama service..."
            systemctl --user daemon-reload
            systemctl --user enable ollama

            start_service() { systemctl --user restart ollama; }
            trap start_service EXIT
            ;;
    esac
}

merge_folders() {
    local src="$1"
    local dest="$2"
    local rel_path=""
    local target=""

    # The 'find' command recursively locates all items in the source directory.
    # It uses '-print0' to separate each item with a null byte, which ensures accurate processing 
    # even for filenames with special characters, spaces, or newlines.
    #
    # The 'awk' command then takes this output and transforms each null byte into a newline character.
    # This allows us to easily process each item in the subsequent 'while' loop.
    #
    # 'IFS=' ensures that leading/trailing whitespace in filenames won't be trimmed in the 'read' command.
    find "$src" -mindepth 1 -print0 | awk 'BEGIN { RS="\0"; OFS="\n" } { print }' | while IFS= read -r item; do
        # Compute the relative path and target for each item
        rel_path=$(realpath --relative-to="$src" "$item")
        target="$dest/$rel_path"

        # If it's a directory and doesn't exist in the target location, create it
        if [ -d "$item" ] && [ ! -d "$target" ]; then
            mkdir -p "$target"
        # If it's a file and doesn't exist in the target location, move it
        elif [ -f "$item" ] && [ ! -e "$target" ]; then
            sudo mv "$item" "$target"
        fi
    done
}

migrate_systemd() {
    # Check if the ollama service exists and is running
    if systemctl is-active --quiet ollama; then
        # Extract the User value from the service configuration
        SERVICE_USER=$(systemctl show -p User --value ollama)

        # If the service is running as the "ollama" user, stop it, copy content to the user's home, and remove it
        if [ "$SERVICE_USER" = "ollama" ]; then
            status "Detected a previous install of Ollama. Ollama will now run as your current user. Migrating models..."
            
            # Stop the service
            $SUDO systemctl stop ollama

            # Disable the service to prevent it from starting on boot
            $SUDO systemctl disable ollama

            # Remove the systemd service file
            $SUDO rm /etc/systemd/system/ollama.service

            $SUDO mkdir -p "$HOME/.ollama/models"
            merge_folders /usr/share/ollama/.ollama/models "$HOME/.ollama/models"
            # Adjusting permissions and ownership after copying
            $SUDO chown -R $(whoami):$(id -gn) "$HOME/.ollama"
            if [ -f "$HOME/.ollama/id_ed25519" ]; then
                chmod 600 "$HOME/.ollama/id_ed25519"
            fi

            # Reload systemd configuration to recognize service removal
            $SUDO systemctl daemon-reload
        fi
    fi
}

# Setup an Ollama background service for the user if systemd is available along with the tools required to get information about the current user.
if available systemctl whoami id find awk read; then
    # Ollama used to be installed as a systemd service running as the "ollama" user, remove that if it exists.
    migrate_systemd
    # Install the Ollama systemd service
    configure_systemd
fi

if ! available lspci && ! available lshw; then
    warning "Unable to detect NVIDIA GPU. Install lspci or lshw to automatically detect and install NVIDIA CUDA drivers."
    exit 0
fi

check_gpu() {
    case $1 in
        lspci) available lspci && lspci -d '10de:' | grep -q 'NVIDIA' || return 1 ;;
        lshw) available lshw && $SUDO lshw -c display -numeric | grep -q 'vendor: .* \[10DE\]' || return 1 ;;
        nvidia-smi) available nvidia-smi || return 1 ;;
    esac
}

if check_gpu nvidia-smi; then
    status "NVIDIA GPU installed."
    exit 0
fi

if ! check_gpu lspci && ! check_gpu lshw; then
    warning "No NVIDIA GPU detected. Ollama will run in CPU-only mode."
    exit 0
fi

# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-7-centos-7
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-8-rocky-8
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-9-rocky-9
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#fedora
install_cuda_driver_yum() {
    status 'Installing NVIDIA repository...'
    case $PACKAGE_MANAGER in
        yum)
            $SUDO $PACKAGE_MANAGER -y install yum-utils
            $SUDO $PACKAGE_MANAGER-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m)/cuda-$1$2.repo
            ;;
        dnf)
            $SUDO $PACKAGE_MANAGER config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m)/cuda-$1$2.repo
            ;;
    esac

    case $1 in
        rhel)
            status 'Installing EPEL repository...'
            # EPEL is required for third-party dependencies such as dkms and libvdpau
            $SUDO $PACKAGE_MANAGER -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-$2.noarch.rpm || true
            ;;
    esac

    status 'Installing CUDA driver...'

    if [ "$1" = 'centos' ] || [ "$1$2" = 'rhel7' ]; then
        $SUDO $PACKAGE_MANAGER -y install nvidia-driver-latest-dkms
    fi

    $SUDO $PACKAGE_MANAGER -y install cuda-drivers
}

# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#ubuntu
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#debian
install_cuda_driver_apt() {
    status 'Installing NVIDIA repository...'
    curl -fsSL -o $TEMP_DIR/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m)/cuda-keyring_1.1-1_all.deb

    case $1 in
        debian)
            status 'Enabling contrib sources...'
            $SUDO sed 's/main/contrib/' < /etc/apt/sources.list | sudo tee /etc/apt/sources.list.d/contrib.list > /dev/null
            ;;
    esac

    status 'Installing CUDA driver...'
    $SUDO dpkg -i $TEMP_DIR/cuda-keyring.deb
    $SUDO apt-get update

    [ -n "$SUDO" ] && SUDO_E="$SUDO -E" || SUDO_E=
    DEBIAN_FRONTEND=noninteractive $SUDO_E apt-get -y install cuda-drivers -q
}

if [ ! -f "/etc/os-release" ]; then
    error "Unknown distribution. Skipping CUDA installation."
fi

. /etc/os-release

OS_NAME=$ID
OS_VERSION=$VERSION_ID

PACKAGE_MANAGER=
for PACKAGE_MANAGER in dnf yum apt-get; do
    if available $PACKAGE_MANAGER; then
        break
    fi
done

if [ -z "$PACKAGE_MANAGER" ]; then
    error "Unknown package manager. Skipping CUDA installation."
fi

if ! check_gpu nvidia-smi || [ -z "$(nvidia-smi | grep -o "CUDA Version: [0-9]*\.[0-9]*")" ]; then
    case $OS_NAME in
        centos|rhel) install_cuda_driver_yum 'rhel' $OS_VERSION ;;
        rocky) install_cuda_driver_yum 'rhel' $(echo $OS_VERSION | cut -c1) ;;
        fedora) install_cuda_driver_yum $OS_NAME $OS_VERSION ;;
        amzn) install_cuda_driver_yum 'fedora' '35' ;;
        debian) install_cuda_driver_apt $OS_NAME $OS_VERSION ;;
        ubuntu) install_cuda_driver_apt $OS_NAME $(echo $OS_VERSION | sed 's/\.//') ;;
        *) exit ;;
    esac
fi

if ! lsmod | grep -q nvidia; then
    KERNEL_RELEASE="$(uname -r)"
    case $OS_NAME in
        centos|rhel|rocky|amzn) $SUDO $PACKAGE_MANAGER -y install kernel-devel-$KERNEL_RELEASE kernel-headers-$KERNEL_RELEASE ;;
        fedora) $SUDO $PACKAGE_MANAGER -y install kernel-devel-$KERNEL_RELEASE ;;
        debian|ubuntu) $SUDO apt-get -y install linux-headers-$KERNEL_RELEASE ;;
        *) exit ;;
    esac

    NVIDIA_CUDA_VERSION=$($SUDO dkms status | awk -F: '/added/ { print $1 }')
    if [ -n "$NVIDIA_CUDA_VERSION" ]; then
        $SUDO dkms install $NVIDIA_CUDA_VERSION
    fi

    if lsmod | grep -q nouveau; then
        status 'Reboot to complete NVIDIA CUDA driver install.'
        exit 0
    fi

    $SUDO modprobe nvidia
fi


status "NVIDIA CUDA drivers installed."
