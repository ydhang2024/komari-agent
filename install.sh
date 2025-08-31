#!/bin/bash

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${NC} $1"
}

log_success() {
    echo -e "${GREEN}${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${NC} $1"
}

log_config() {
    echo -e "${CYAN}[CONFIG]${NC} $1"
}

# Default values
service_name="komari-agent"
target_dir="/opt/komari"
github_proxy="https://hub.hang.edu.kg"
install_version="" # New parameter for specifying version
need_vnstat=false # Flag to indicate if vnstat is needed

# Detect OS
os_type=$(uname -s)
case $os_type in
    Darwin)
        os_name="darwin"
        target_dir="/usr/local/komari"  # Use /usr/local on macOS
        # Check if we can write to /usr/local, fallback to user directory
        if [ ! -w "/usr/local" ] && [ "$EUID" -ne 0 ]; then
            target_dir="$HOME/.komari"
            log_info "No write permission to /usr/local, using user directory: $target_dir"
        fi
        ;;
    Linux)
        os_name="linux"
        ;;
    *)
        log_error "Unsupported operating system: $os_type"
        exit 1
        ;;
esac

# Parse install-specific arguments
komari_args=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir)
            target_dir="$2"
            shift 2
            ;;
        --install-service-name)
            service_name="$2"
            shift 2
            ;;
        --install-ghproxy)
            github_proxy="$2"
            shift 2
            ;;
        --install-version)
            install_version="$2"
            shift 2
            ;;
        --month-rotate)
            need_vnstat=true
            komari_args="$komari_args $1"
            shift
            ;;
        --install*)
            log_warning "Unknown install parameter: $1"
            shift
            ;;
        *)
            # Non-install arguments go to komari_args
            komari_args="$komari_args $1"
            shift
            ;;
    esac
done

# Remove leading space from komari_args if present
komari_args="${komari_args# }"

komari_agent_path="${target_dir}/agent"

# macOS doesn't always require sudo for everything
if [ "$os_name" = "darwin" ] && command -v brew >/dev/null 2>&1; then
    # On macOS with Homebrew, we can run without root for dependencies
    require_root_for_deps=false
else
    require_root_for_deps=true
fi

if [ "$EUID" -ne 0 ] && [ "$require_root_for_deps" = true ]; then
    log_error "Please run as root"
    exit 1
fi

echo -e "${WHITE}===========================================${NC}"
echo -e "${WHITE}    Komari Agent Installation Script     ${NC}"
echo -e "${WHITE}===========================================${NC}"
echo ""
log_config "Installation configuration:"
log_config "  Service name: ${GREEN}$service_name${NC}"
log_config "  Install directory: ${GREEN}$target_dir${NC}"
log_config "  GitHub proxy: ${GREEN}${github_proxy:-"(direct)"}${NC}"
log_config "  Binary arguments: ${GREEN}$komari_args${NC}"
if [ -n "$install_version" ]; then
    log_config "  Specified agent version: ${GREEN}$install_version${NC}"
else
    log_config "  Agent version: ${GREEN}Latest${NC}"
fi
if [ "$need_vnstat" = true ]; then
    log_config "  vnstat installation: ${GREEN}Required (--month-rotate detected)${NC}"
else
    log_config "  vnstat installation: ${GREEN}Not required${NC}"
fi
echo ""

# Function to uninstall the previous installation
uninstall_previous() {
    log_step "Checking for previous installation..."
    
    # Stop and disable service if it exists
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "${service_name}.service"; then
        log_info "Stopping and disabling existing systemd service..."
        systemctl stop ${service_name}.service
        systemctl disable ${service_name}.service
        rm -f "/etc/systemd/system/${service_name}.service"
        systemctl daemon-reload
    elif command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
        log_info "Stopping and disabling existing OpenRC service..."
        rc-service ${service_name} stop
        rc-update del ${service_name} default
        rm -f "/etc/init.d/${service_name}"
    elif command -v uci >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
        log_info "Stopping and disabling existing procd service..."
        /etc/init.d/${service_name} stop
        /etc/init.d/${service_name} disable
        rm -f "/etc/init.d/${service_name}"
    elif [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
        # macOS launchd service - check both system and user locations
        system_plist="/Library/LaunchDaemons/com.komari.${service_name}.plist"
        user_plist="$HOME/Library/LaunchAgents/com.komari.${service_name}.plist"
        
        if [ -f "$system_plist" ]; then
            log_info "Stopping and removing existing system launchd service..."
            launchctl bootout system "$system_plist" 2>/dev/null || true
            rm -f "$system_plist"
        fi
        
        if [ -f "$user_plist" ]; then
            log_info "Stopping and removing existing user launchd service..."
            launchctl bootout gui/$(id -u) "$user_plist" 2>/dev/null || true
            rm -f "$user_plist"
        fi
    fi
    
    # Remove old binary if it exists
    if [ -f "$komari_agent_path" ]; then
        log_info "Removing old binary..."
        rm -f "$komari_agent_path"
    fi
}

# Uninstall previous installation
uninstall_previous

install_dependencies() {
    log_step "Checking and installing dependencies..."

    local deps="curl"
    local missing_deps=""
    for cmd in $deps; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing_deps="$missing_deps $cmd"
        fi
    done

    if [ -n "$missing_deps" ]; then
        # Check package manager and install dependencies
        if command -v apt >/dev/null 2>&1; then
            log_info "Using apt to install dependencies..."
            apt update
            apt install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            log_info "Using yum to install dependencies..."
            yum install -y $missing_deps
        elif command -v apk >/dev/null 2>&1; then
            log_info "Using apk to install dependencies..."
            apk add $missing_deps
        elif command -v brew >/dev/null 2>&1; then
            log_info "Using Homebrew to install dependencies..."
            brew install $missing_deps
        else
            log_error "No supported package manager found (apt/yum/apk/brew)"
            exit 1
        fi
        
        # Verify installation
        for cmd in $missing_deps; do
            if ! command -v $cmd >/dev/null 2>&1; then
                log_error "Failed to install $cmd"
                exit 1
            fi
        done
        log_success "Dependencies installed successfully"
    else
        log_success "Dependencies already satisfied"
    fi
}

# Function to install vnstat if needed
install_vnstat() {
    if [ "$need_vnstat" = true ]; then
        log_step "Checking and installing vnstat for --month-rotate functionality..."
        
        if command -v vnstat >/dev/null 2>&1; then
            log_success "vnstat is already installed"
            return
        fi
        
        log_info "vnstat not found, installing..."
        
        # Install vnstat based on package manager
        if command -v apt >/dev/null 2>&1; then
            log_info "Using apt to install vnstat..."
            apt update
            apt install -y vnstat
        elif command -v yum >/dev/null 2>&1; then
            log_info "Using yum to install vnstat..."
            yum install -y vnstat
        elif command -v dnf >/dev/null 2>&1; then
            log_info "Using dnf to install vnstat..."
            dnf install -y vnstat
        elif command -v apk >/dev/null 2>&1; then
            log_info "Using apk to install vnstat..."
            apk add vnstat
        elif command -v brew >/dev/null 2>&1; then
            log_info "Using Homebrew to install vnstat..."
            brew install vnstat
        elif command -v pacman >/dev/null 2>&1; then
            log_info "Using pacman to install vnstat..."
            pacman -S --noconfirm vnstat
        else
            log_error "No supported package manager found for vnstat installation"
            log_error "Please install vnstat manually to use --month-rotate functionality"
            exit 1
        fi
        
        # Verify installation
        if command -v vnstat >/dev/null 2>&1; then
            log_success "vnstat installed successfully"
            
            # Start vnstat daemon if systemd is available
            if command -v systemctl >/dev/null 2>&1; then
                log_info "Starting vnstat daemon..."
                systemctl enable vnstat
                systemctl start vnstat
            elif [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
                log_info "vnstat daemon management varies on macOS, please check vnstat documentation"
            fi
        else
            log_error "Failed to install vnstat"
            exit 1
        fi
    fi
}

# Install dependencies
install_dependencies

# Install vnstat if needed for month-rotate
install_vnstat

arch=$(uname -m)
case $arch in
    x86_64)
        arch="amd64"
        ;;
    aarch64)
        arch="arm64"
        ;;
    arm64)
        arch="arm64"
        ;;
    *)
        log_error "Unsupported architecture: $arch"
        exit 1
        ;;
esac
log_info "Detected architecture: ${GREEN}$arch${NC}"

version_to_install="latest"
if [ -n "$install_version" ]; then
    log_info "Attempting to install specified version: ${GREEN}$install_version${NC}"
    version_to_install="$install_version"
else
    log_info "No version specified, installing the latest version."
fi

# Construct download URL
file_name="komari-agent-${os_name}-${arch}"
if [ "$version_to_install" = "latest" ]; then
    download_path="latest/download"
else
    download_path="download/${version_to_install}"
fi

if [ -n "$github_proxy" ]; then
    # Use proxy for GitHub releases
    download_url="${github_proxy}/https://github.com/komari-monitor/komari-agent/releases/${download_path}/${file_name}"
else
    # Direct access to GitHub releases
    download_url="https://hub.hang.edu.kg/https://github.com/komari-monitor/komari-agent/releases/${download_path}/${file_name}"
fi

log_step "Creating installation directory: ${GREEN}$target_dir${NC}"
mkdir -p "$target_dir"

# Download binary
if [ -n "$github_proxy" ]; then
    log_step "Downloading $file_name via proxy..."
    log_info "URL: ${CYAN}$download_url${NC}"
else
    log_step "Downloading $file_name directly..."
    log_info "URL: ${CYAN}$download_url${NC}"
fi
if ! curl -L -o "$komari_agent_path" "$download_url"; then
    log_error "Download failed"
    exit 1
fi

# Set executable permissions
chmod +x "$komari_agent_path"
log_success "Komari-agent installed to ${GREEN}$komari_agent_path${NC}"

# Detect init system and configure service
log_step "Configuring system service..."

# Check if running on NixOS
if [ -f /etc/NIXOS ]; then
    log_warning "NixOS detected. System services must be configured declaratively."
    log_info "Please add the following to your NixOS configuration:"
    echo ""
    echo -e "${CYAN}systemd.services.${service_name} = {${NC}"
    echo -e "${CYAN}  description = \"Komari Agent Service\";${NC}"
    echo -e "${CYAN}  after = [ \"network.target\" ];${NC}"
    echo -e "${CYAN}  wantedBy = [ \"multi-user.target\" ];${NC}"
    echo -e "${CYAN}  serviceConfig = {${NC}"
    echo -e "${CYAN}    Type = \"simple\";${NC}"
    echo -e "${CYAN}    ExecStart = \"${komari_agent_path} ${komari_args}\";${NC}"
    echo -e "${CYAN}    WorkingDirectory = \"${target_dir}\";${NC}"
    echo -e "${CYAN}    Restart = \"always\";${NC}"
    echo -e "${CYAN}    User = \"root\";${NC}"
    echo -e "${CYAN}  };${NC}"
    echo -e "${CYAN}};${NC}"
    echo ""
    log_info "Then run: sudo nixos-rebuild switch"
    log_warning "Service not started automatically on NixOS. Please rebuild your configuration."
elif command -v systemctl >/dev/null 2>&1; then
    # Systemd service configuration
    log_info "Using systemd for service management"
    service_file="/etc/systemd/system/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Komari Agent Service
After=network.target

[Service]
Type=simple
ExecStart=${komari_agent_path} ${komari_args}
WorkingDirectory=${target_dir}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable ${service_name}.service
    systemctl start ${service_name}.service
    log_success "Systemd service configured and started"
elif command -v rc-service >/dev/null 2>&1; then
    # OpenRC service configuration
    log_info "Using OpenRC for service management"
    service_file="/etc/init.d/${service_name}"
    cat > "$service_file" << EOF
#!/sbin/openrc-run

name="Komari Agent Service"
description="Komari monitoring agent"
command="${komari_agent_path}"
command_args="${komari_args}"
command_user="root"
directory="${target_dir}"
pidfile="/run/${service_name}.pid"
retry="SIGTERM/30"
supervisor=supervise-daemon

depend() {
    need net
    after network
}
EOF

    # Set permissions and enable service
    chmod +x "$service_file"
    rc-update add ${service_name} default
    rc-service ${service_name} start
    log_success "OpenRC service configured and started"
elif command -v uci >/dev/null 2>&1; then
    # procd service configuration (OpenWrt)
    log_info "Using procd for service management"
    service_file="/etc/init.d/${service_name}"
    cat > "$service_file" << EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

PROG="${komari_agent_path}"
ARGS="${komari_args}"

start_service() {
    procd_open_instance
    procd_set_param command \$PROG \$ARGS
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param user root
    procd_close_instance
}

stop_service() {
    killall \$(basename \$PROG)
}

reload_service() {
    stop
    start
}
EOF

    # Set permissions and enable service
    chmod +x "$service_file"
    /etc/init.d/${service_name} enable
    /etc/init.d/${service_name} start
    log_success "procd service configured and started"
elif [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
    # macOS launchd service configuration
    log_info "Using launchd for service management"
    
    # Determine if this should be a system or user service based on installation directory
    if [[ "$target_dir" =~ ^/Users/.* ]] || [ "$EUID" -ne 0 ]; then
        # User-level service (LaunchAgent)
        plist_dir="$HOME/Library/LaunchAgents"
        plist_file="$plist_dir/com.komari.${service_name}.plist"
        log_info "Installing as user-level service (LaunchAgent)"
        mkdir -p "$plist_dir"
        service_user="$(whoami)"
        log_dir="$HOME/Library/Logs"
    else
        # System-level service (LaunchDaemon)
        plist_dir="/Library/LaunchDaemons"
        plist_file="$plist_dir/com.komari.${service_name}.plist"
        log_info "Installing as system-level service (LaunchDaemon)"
        service_user="root"
        log_dir="/var/log"
    fi
    
    # Create the launchd plist file
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.komari.${service_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${komari_agent_path}</string>
EOF
    
    # Add program arguments if provided
    if [ -n "$komari_args" ]; then
        for arg in $komari_args; do
            echo "        <string>$arg</string>" >> "$plist_file"
        done
    fi
    
    cat >> "$plist_file" << EOF
    </array>
    <key>WorkingDirectory</key>
    <string>${target_dir}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>UserName</key>
    <string>${service_user}</string>
    <key>StandardOutPath</key>
    <string>${log_dir}/${service_name}.log</string>
    <key>StandardErrorPath</key>
    <string>${log_dir}/${service_name}.log</string>
</dict>
</plist>
EOF
    
    # Load and start the service
    if [[ "$target_dir" =~ ^/Users/.* ]] || [ "$EUID" -ne 0 ]; then
        # User-level service
        if launchctl bootstrap gui/$(id -u) "$plist_file"; then
            log_success "User-level launchd service configured and started"
        else
            log_error "Failed to load user-level launchd service"
            exit 1
        fi
    else
        # System-level service
        if launchctl bootstrap system "$plist_file"; then
            log_success "System-level launchd service configured and started"
        else
            log_error "Failed to load system-level launchd service"
            exit 1
        fi
    fi
else
    log_error "Unsupported init system (systemd, openrc, procd, or launchd not found)"
    exit 1
fi

echo ""
echo -e "${WHITE}===========================================${NC}"
if [ -f /etc/NIXOS ]; then
    log_success "Komari-agent binary installed!"
    log_warning "NixOS requires declarative service configuration."
    log_info "Please add the service configuration to your NixOS config and rebuild."
else
    log_success "Komari-agent installation completed!"
fi
log_config "Service: ${GREEN}$service_name${NC}"
log_config "Arguments: ${GREEN}$komari_args${NC}"
echo -e "${WHITE}===========================================${NC}"
