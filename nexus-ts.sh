#!/bin/bash
set -e

# === Konfigurasi dasar ===
NODE_DATA_DIR="/root/.nexus"
LOG_DIR="/root/nexus_logs"
WORKSPACE_DIR="/root"
SCRIPT_DIR="/root/nexus-scripts"
NODE_LIST_FILE="/root/nexus_nodes.txt"  # File untuk menyimpan daftar node
SESSION_MANAGER_FILE="/root/nexus_session_manager.txt"  # File untuk menyimpan pilihan session manager
REFRESH_INTERVAL_MINUTES=10  # Interval restart otomatis
AUTO_REFRESH_ENABLED=false   # Status auto-refresh

# === Global Variables ===
CURRENT_NEXUS_VERSION=""
LATEST_CLI_VERSION=""
NEXUS_VERSION=""

# === Warna terminal ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

# === Deteksi Versi CLI Terbaru ===
function get_latest_cli_version() {
    if [[ -z "$LATEST_CLI_VERSION" ]]; then
        if command -v curl >/dev/null 2>&1; then
            LATEST_CLI_VERSION=$(curl -s "https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)".*/\1/' 2>/dev/null || echo "Unknown")
        else
            LATEST_CLI_VERSION="Unknown"
        fi
    fi
    echo "$LATEST_CLI_VERSION"
}

# === Deteksi Versi yang Sedang Digunakan ===
function get_current_system_version() {
    if [[ -z "$CURRENT_NEXUS_VERSION" ]]; then
        # Check if we have any stored version info
        if [[ -n "$NEXUS_VERSION" && "$NEXUS_VERSION" != "latest" ]]; then
            CURRENT_NEXUS_VERSION="$NEXUS_VERSION"
        else
            # Check if there are any running nodes
            if [ -f "$NODE_LIST_FILE" ] && [ -s "$NODE_LIST_FILE" ]; then
                local first_node=$(head -n 1 "$NODE_LIST_FILE")
                if [ -n "$first_node" ]; then
                    # Check if we have version info stored
                    local version_file="$SCRIPT_DIR/nexus-version.txt"
                    if [ -f "$version_file" ]; then
                        CURRENT_NEXUS_VERSION=$(cat "$version_file")
                    else
                        CURRENT_NEXUS_VERSION="Latest (Official)"
                    fi
                else
                    CURRENT_NEXUS_VERSION="Not Installed"
                fi
            else
                CURRENT_NEXUS_VERSION="Not Installed"
            fi
        fi
    fi
    echo "$CURRENT_NEXUS_VERSION"
}

# === Header Tampilan ===
function show_header() {
    clear
    local latest_version=$(get_latest_cli_version)
    local current_version=$(get_current_system_version)
    local auto_refresh_status="${RED}OFF${RESET}"
    
    # Cek apakah auto-refresh aktif berdasarkan variabel status
    if [ "$AUTO_REFRESH_ENABLED" = true ]; then
        auto_refresh_status="${GREEN}ON${RESET} (Setiap ${REFRESH_INTERVAL_MINUTES} menit)"
    else
        # Double-check dengan crontab juga
        if crontab -l 2>/dev/null | grep -q "restart_nexus_nodes"; then
            auto_refresh_status="${GREEN}ON${RESET} (Setiap ${REFRESH_INTERVAL_MINUTES} menit)"
            # Update variabel status jika ternyata aktif
            AUTO_REFRESH_ENABLED=true
            # Simpan status ke file
            sed -i "s/^AUTO_REFRESH_ENABLED=.*/AUTO_REFRESH_ENABLED=true   # Status auto-refresh/" "$0"
        fi
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "                     NEXUS - Direct Node Setup (VPS Edition)"
    echo -e "                     📦 Latest CLI Version: ${latest_version}"
    echo -e "                     🔧 System Version: ${current_version}"
    echo -e "                     🔄 Auto-refresh: ${auto_refresh_status}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# === Deteksi Lingkungan ===
function detect_environment() {
    echo -e "${CYAN}[*] Mendeteksi lingkungan sistem...${RESET}"
    
    # Deteksi versi Ubuntu
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        UBUNTU_VERSION=$VERSION_ID
        echo -e "${GREEN}[✓] Terdeteksi Ubuntu versi: $UBUNTU_VERSION${RESET}"
    else
        echo -e "${RED}[!] Tidak dapat mendeteksi versi Ubuntu${RESET}"
        UBUNTU_VERSION="unknown"
    fi
    
    # Deteksi versi GLIBC
    GLIBC_VERSION=$(ldd --version | head -n1 | grep -o '[0-9]\+\.[0-9]\+$' || echo "unknown")
    echo -e "${GREEN}[✓] Terdeteksi GLIBC versi: $GLIBC_VERSION${RESET}"
    
    # Deteksi apakah kita berada di dalam container
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo -e "${GREEN}[✓] Terdeteksi berjalan di dalam container Docker${RESET}"
        IN_CONTAINER=true
    else
        echo -e "${YELLOW}[!] Tidak terdeteksi berjalan di dalam container Docker${RESET}"
        IN_CONTAINER=false
    fi
    
    # Periksa apakah GLIBC memenuhi persyaratan
    if [[ "$GLIBC_VERSION" == "2.39" || "$UBUNTU_VERSION" == "24.04" ]]; then
        echo -e "${GREEN}[✓] GLIBC 2.39 terdeteksi atau Ubuntu 24.04 (mendukung Nexus Network)${RESET}"
        GLIBC_COMPATIBLE=true
    else
        echo -e "${RED}[!] GLIBC 2.39 tidak terdeteksi (versi saat ini: $GLIBC_VERSION)${RESET}"
        echo -e "${RED}[!] Nexus Network memerlukan GLIBC 2.39 yang tersedia di Ubuntu 24.04${RESET}"
        GLIBC_COMPATIBLE=false
    fi
    
    echo -e "${CYAN}[*] Deteksi lingkungan selesai${RESET}"
    echo ""
}

# === Pilih Versi Nexus ===
function select_version() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "                           PILIH VERSI NEXUS CLI"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN} 1.${RESET} 🚀 Latest Version (Official Installer - Recommended)"
    echo -e "${GREEN} 2.${RESET} 📦 Specific Version dari GitHub"
    echo -e "${GREEN} 3.${RESET} 📋 Lihat Available Versions"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    read -rp "Pilih opsi (1-3): " version_choice
    
    case $version_choice in
        1)
            NEXUS_VERSION="latest"
            echo -e "${GREEN}✅ Menggunakan Latest Version (Official Installer)${RESET}"
            ;;
        2)
            echo -e "${YELLOW}Masukkan versi yang diinginkan (contoh: v0.8.11, v0.8.10, v0.9.0):${RESET}"
            read -rp "Versi: " custom_version
            if [[ -z "$custom_version" ]]; then
                echo -e "${RED}❌ Versi tidak boleh kosong!${RESET}"
                read -p "Tekan enter untuk kembali..."
                return 1
            fi
            # Add 'v' prefix if not present
            if [[ ! "$custom_version" =~ ^v ]]; then
                custom_version="v$custom_version"
            fi
            NEXUS_VERSION="$custom_version"
            echo -e "${GREEN}✅ Menggunakan versi: $NEXUS_VERSION${RESET}"
            ;;
        3)
            show_available_versions
            return 1
            ;;
        *)
            echo -e "${RED}❌ Pilihan tidak valid!${RESET}"
            read -p "Tekan enter untuk kembali..."
            return 1
            ;;
    esac
    return 0
}

# === Tampilkan Available Versions ===
function show_available_versions() {
    echo -e "${YELLOW}🔍 Mengambil daftar versi dari GitHub...${RESET}"
    
    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}Installing curl...${RESET}"
        apt update && apt install -y curl
    fi
    
    echo -e "${CYAN}📋 Available Nexus CLI Versions:${RESET}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Get latest 10 releases from GitHub API
    curl -s "https://api.github.com/repos/nexus-xyz/nexus-cli/releases?per_page=10" | \
    grep '"tag_name":' | \
    sed 's/.*"tag_name": "\(.*\)".*/\1/' | \
    head -10 | \
    nl -w2 -s'. '
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}💡 Tip: Versi yang lebih lama mungkin lebih stabil${RESET}"
    echo -e "${YELLOW}💡 Versi terbaru memiliki fitur dan perbaikan terbaru${RESET}"
    read -p "Tekan enter untuk kembali ke menu versi..."
}

# === Pilih Session Manager ===
function choose_session_manager() {
    echo -e "${CYAN}[*] Pilih session manager untuk menjalankan node:${RESET}"
    echo ""
    echo -e "${GREEN}1.${RESET} Screen (default)"
    echo -e "   ${YELLOW}✓ Ringan dan sederhana${RESET}"
    echo -e "   ${YELLOW}✓ Sudah terinstal di kebanyakan sistem${RESET}"
    echo ""
    echo -e "${GREEN}2.${RESET} Tmux"
    echo -e "   ${YELLOW}✓ Lebih powerful dan fleksibel${RESET}"
    echo -e "   ${YELLOW}✓ Mendukung split window dan session management yang lebih baik${RESET}"
    echo -e "   ${YELLOW}✓ Lebih modern dan user-friendly${RESET}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    read -rp "Pilih session manager (1-2, default: 1): " session_choice
    
    case $session_choice in
        2)
            SESSION_MANAGER="tmux"
            echo -e "${GREEN}[✓] Anda memilih Tmux${RESET}"
            ;;
        *)
            SESSION_MANAGER="screen"
            echo -e "${GREEN}[✓] Anda memilih Screen${RESET}"
            ;;
    esac
    
    # Simpan pilihan session manager
    echo "$SESSION_MANAGER" > "$SESSION_MANAGER_FILE"
    
    echo ""
    read -p "Tekan enter untuk melanjutkan..."
}

# === Load Session Manager yang Tersimpan ===
function load_saved_session_manager() {
    if [ -f "$SESSION_MANAGER_FILE" ]; then
        SESSION_MANAGER=$(cat "$SESSION_MANAGER_FILE")
        echo -e "${GREEN}[✓] Memuat session manager tersimpan: $SESSION_MANAGER${RESET}"
    else
        # Default ke screen jika belum ada pilihan tersimpan
        SESSION_MANAGER="screen"
    fi
}

# === Periksa dan Install Dependencies ===
function install_dependencies() {
    echo -e "${CYAN}[*] Memeriksa dan menginstal dependencies...${RESET}"
    
    # Update package index
    apt update
    
    # Install dependencies dasar
    apt install -y curl screen build-essential pkg-config libssl-dev git-all
    
    # Install tmux jika dipilih
    if [ "$SESSION_MANAGER" = "tmux" ]; then
        if ! command -v tmux >/dev/null 2>&1; then
            echo -e "${CYAN}[*] Menginstal tmux...${RESET}"
            apt install -y tmux
            echo -e "${GREEN}[✓] Tmux berhasil diinstal${RESET}"
        else
            echo -e "${GREEN}[✓] Tmux sudah terinstal${RESET}"
        fi
    fi
    
    echo -e "${GREEN}[✓] Dependencies berhasil diinstal${RESET}"
    echo ""
}

# === Buat Direktori ===
function create_directories() {
    echo -e "${CYAN}[*] Membuat direktori yang diperlukan...${RESET}"
    
    mkdir -p "$LOG_DIR"
    mkdir -p "$SCRIPT_DIR"
    
    echo -e "${GREEN}[✓] Direktori berhasil dibuat${RESET}"
    echo ""
}

# === Hapus CLI Lama ===
function clean_old_cli() {
    echo -e "${YELLOW}[*] Menghapus CLI lama untuk memaksa update...${RESET}"
    
    # Hapus direktori .nexus
    rm -rf "$NODE_DATA_DIR"
    
    # Hapus symlink
    rm -f /usr/local/bin/nexus-network
    
    # Hapus file path yang tersimpan
    rm -f "$SCRIPT_DIR/nexus-binary-path.txt"
    
    echo -e "${GREEN}[✓] CLI lama berhasil dihapus${RESET}"
}

# === Install Nexus CLI ===
function install_nexus_cli() {
    local version=${1:-"latest"}
    
    echo -e "${CYAN}[*] Menginstal Nexus CLI...${RESET}"
    
    if [ "$GLIBC_COMPATIBLE" = true ]; then
        # Hapus CLI lama terlebih dahulu untuk memaksa update
        clean_old_cli
        
        if [[ "$version" == "latest" ]]; then
            echo -e "${YELLOW}📦 Installing Latest Version (Official Installer)...${RESET}"
            install_latest_cli
        else
            echo -e "${YELLOW}📦 Installing Version $version dari GitHub...${RESET}"
            install_github_cli "$version"
        fi
        
    else
        echo -e "${RED}[!] Tidak dapat menginstal Nexus CLI karena GLIBC tidak kompatibel${RESET}"
        echo -e "${YELLOW}[!] Anda perlu menggunakan Ubuntu 24.04 untuk menjalankan Nexus Network${RESET}"
    fi
    
    echo ""
}

# === Install Latest CLI ===
function install_latest_cli() {
    # Install Nexus CLI dengan timestamp untuk memaksa download fresh
    curl -sSL "https://cli.nexus.xyz/?t=$(date +%s)" | sh
    
    # Deteksi lokasi nexus-network binary
    detect_and_setup_binary "latest-official"
}

# === Install GitHub CLI ===
function install_github_cli() {
    local version=$1
    echo -e "${YELLOW}📦 Building Nexus CLI $version dari GitHub...${RESET}"
    
    # Install Rust if not available
    if ! command -v cargo >/dev/null 2>&1; then
        echo -e "${CYAN}[*] Installing Rust...${RESET}"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source ~/.cargo/env
    fi
    
    # Install git if not available
    if ! command -v git >/dev/null 2>&1; then
        echo -e "${CYAN}[*] Installing git...${RESET}"
        apt update && apt install -y git
    fi
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # Clone repository and checkout specific version
    echo -e "${CYAN}[*] Cloning Nexus CLI repository...${RESET}"
    git clone https://github.com/nexus-xyz/nexus-cli.git
    cd nexus-cli/clients/cli
    
    echo -e "${CYAN}[*] Checking out version $version...${RESET}"
    git checkout tags/$version
    
    # Build the binary
    echo -e "${CYAN}[*] Building binary...${RESET}"
    cargo build --release
    
    # Install the binary
    echo -e "${CYAN}[*] Installing binary...${RESET}"
    if [ -f target/release/nexus-cli ]; then
        cp target/release/nexus-cli /usr/local/bin/nexus-network
    elif [ -f target/release/nexus ]; then
        cp target/release/nexus /usr/local/bin/nexus-network
    elif [ -f target/release/nexus-network ]; then
        cp target/release/nexus-network /usr/local/bin/nexus-network
    else
        echo -e "${RED}[!] No suitable binary found${RESET}"
        ls -la target/release/
        cd - && rm -rf "$TEMP_DIR"
        return 1
    fi
    
    chmod +x /usr/local/bin/nexus-network
    
    # Cleanup
    cd - && rm -rf "$TEMP_DIR"
    
    # Setup binary path
    detect_and_setup_binary "$version"
    
    echo -e "${GREEN}[✓] Nexus CLI $version berhasil diinstal${RESET}"
}

# === Detect and Setup Binary ===
function detect_and_setup_binary() {
    local version=${1:-"latest"}
    
    # Deteksi lokasi nexus-network binary
    NEXUS_BINARY=""
    
    # Cek di lokasi default
    if [ -f "$NODE_DATA_DIR/bin/nexus-network" ]; then
        NEXUS_BINARY="$NODE_DATA_DIR/bin/nexus-network"
    # Cek di PATH
    elif command -v nexus-network &> /dev/null; then
        NEXUS_BINARY=$(which nexus-network)
    # Cek di lokasi alternatif
    elif [ -f "/usr/local/bin/nexus-network" ]; then
        NEXUS_BINARY="/usr/local/bin/nexus-network"
    fi
    
    if [ -n "$NEXUS_BINARY" ]; then
        echo -e "${GREEN}[✓] Nexus binary ditemukan di: $NEXUS_BINARY${RESET}"
        
        # Simpan lokasi binary untuk digunakan nanti
        echo "$NEXUS_BINARY" > "$SCRIPT_DIR/nexus-binary-path.txt"
        
        # Simpan versi yang digunakan
        echo "$version" > "$SCRIPT_DIR/nexus-version.txt"
        
        # Buat symlink jika belum ada
        if [ ! -f "/usr/local/bin/nexus-network" ]; then
            ln -sf "$NEXUS_BINARY" /usr/local/bin/nexus-network
            echo -e "${GREEN}[✓] Symlink dibuat di /usr/local/bin/nexus-network${RESET}"
        fi
        
        # Update current version info
        if [[ "$version" == "latest-official" ]]; then
            CURRENT_NEXUS_VERSION="Latest (Official)"
        else
            CURRENT_NEXUS_VERSION="$version"
        fi
        
        echo -e "${GREEN}[✓] Nexus CLI berhasil diinstal${RESET}"
    else
        echo -e "${RED}[!] Nexus binary tidak ditemukan${RESET}"
        echo -e "${YELLOW}[!] Coba jalankan 'source /root/.profile' dan coba lagi${RESET}"
        return 1
    fi
}

# === Buat Script Runner ===
function create_runner_script() {
    echo -e "${CYAN}[*] Membuat script runner...${RESET}"
    
    # Dapatkan path nexus binary
    NEXUS_BINARY=""
    
    # Coba source profile untuk mendapatkan PATH yang diperbarui
    source /root/.profile 2>/dev/null || true
    
    # Cek di PATH terlebih dahulu (prioritas tertinggi)
    if command -v nexus-network &> /dev/null; then
        NEXUS_BINARY=$(which nexus-network)
        echo -e "${GREEN}[✓] Nexus binary ditemukan di PATH: $NEXUS_BINARY${RESET}"
    # Cek di lokasi yang disimpan
    elif [ -f "$SCRIPT_DIR/nexus-binary-path.txt" ]; then
        NEXUS_BINARY=$(cat "$SCRIPT_DIR/nexus-binary-path.txt")
        echo -e "${GREEN}[✓] Nexus binary ditemukan di lokasi tersimpan: $NEXUS_BINARY${RESET}"
    # Cek di lokasi alternatif
    elif [ -f "/usr/local/bin/nexus-network" ]; then
        NEXUS_BINARY="/usr/local/bin/nexus-network"
        echo -e "${GREEN}[✓] Nexus binary ditemukan di /usr/local/bin${RESET}"
    # Cek di lokasi default
    elif [ -f "$NODE_DATA_DIR/bin/nexus-network" ]; then
        NEXUS_BINARY="$NODE_DATA_DIR/bin/nexus-network"
        echo -e "${GREEN}[✓] Nexus binary ditemukan di $NODE_DATA_DIR/bin${RESET}"
    else
        echo -e "${RED}[!] Nexus binary tidak ditemukan${RESET}"
        echo -e "${YELLOW}[!] Mencoba mencari di lokasi lain...${RESET}"
        
        # Cari di seluruh sistem
        POSSIBLE_BINARY=$(find /root -name "nexus-network" -type f 2>/dev/null | head -n 1)
        if [ -n "$POSSIBLE_BINARY" ]; then
            NEXUS_BINARY="$POSSIBLE_BINARY"
            echo -e "${GREEN}[✓] Nexus binary ditemukan di: $NEXUS_BINARY${RESET}"
        else
            echo -e "${RED}[!] Nexus binary tidak ditemukan di sistem${RESET}"
            echo -e "${YELLOW}[!] Pastikan Nexus CLI sudah terinstal dengan benar${RESET}"
            echo -e "${YELLOW}[!] Coba jalankan 'source /root/.profile' dan coba lagi${RESET}"
            return 1
        fi
    fi
    
    # Simpan lokasi binary untuk digunakan nanti
    echo "$NEXUS_BINARY" > "$SCRIPT_DIR/nexus-binary-path.txt"
    echo -e "${GREEN}[✓] Menggunakan Nexus binary: $NEXUS_BINARY${RESET}"
    
    cat > "$SCRIPT_DIR/run-nexus.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

SESSION_NAME="nexus-\$NODE_ID"
LOG_FILE="$LOG_DIR/nexus-\$NODE_ID.log"
SESSION_MANAGER="$SESSION_MANAGER"

if [ "\$SESSION_MANAGER" = "tmux" ]; then
    # Matikan tmux session yang mungkin masih berjalan
    tmux kill-session -t \$SESSION_NAME 2>/dev/null || true
    
    # Jalankan nexus-network di dalam tmux
    tmux new-session -d -s \$SESSION_NAME "$NEXUS_BINARY start --node-id \$NODE_ID 2>&1 | tee \$LOG_FILE"
    
    # Tunggu sebentar untuk memastikan tmux sudah berjalan
    sleep 3
    
    # Cek apakah tmux session berhasil dijalankan
    if tmux has-session -t \$SESSION_NAME 2>/dev/null; then
        echo "Node \$NODE_ID berjalan di latar belakang (tmux)"
        echo "Nexus node berjalan dengan NODE_ID: \$NODE_ID"
        echo "Log tersedia di: \$LOG_FILE"
        echo "Untuk melihat tmux session: tmux attach-session -t \$SESSION_NAME"
    else
        echo "Gagal menjalankan node \$NODE_ID"
        cat \$LOG_FILE
        exit 1
    fi
else
    # Matikan screen yang mungkin masih berjalan
    screen -S \$SESSION_NAME -X quit >/dev/null 2>&1 || true
    
    # Jalankan nexus-network di dalam screen
    screen -dmS \$SESSION_NAME bash -c "$NEXUS_BINARY start --node-id \$NODE_ID &>> \$LOG_FILE"
    
    # Tunggu sebentar untuk memastikan screen sudah berjalan
    sleep 3
    
    # Cek apakah screen berhasil dijalankan
    if screen -list | grep -q "\$SESSION_NAME"; then
        echo "Node \$NODE_ID berjalan di latar belakang (screen)"
        echo "Nexus node berjalan dengan NODE_ID: \$NODE_ID"
        echo "Log tersedia di: \$LOG_FILE"
        echo "Untuk melihat screen: screen -r \$SESSION_NAME"
    else
        echo "Gagal menjalankan node \$NODE_ID"
        cat \$LOG_FILE
        exit 1
    fi
fi
EOF
    
    chmod +x "$SCRIPT_DIR/run-nexus.sh"
    
    # Buat script untuk melihat log
    cat > "$SCRIPT_DIR/view-log.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

LOG_FILE="$LOG_DIR/nexus-\$NODE_ID.log"

if [ -f "\$LOG_FILE" ]; then
    tail -f "\$LOG_FILE"
else
    echo "File log tidak ditemukan di \$LOG_FILE"
fi
EOF
    
    chmod +x "$SCRIPT_DIR/view-log.sh"
    
    # Buat script untuk menghentikan node
    cat > "$SCRIPT_DIR/stop-nexus.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

SESSION_NAME="nexus-\$NODE_ID"
SESSION_MANAGER="$SESSION_MANAGER"

if [ "\$SESSION_MANAGER" = "tmux" ]; then
    # Matikan tmux session yang mungkin masih berjalan
    tmux kill-session -t \$SESSION_NAME 2>/dev/null || true
else
    # Matikan screen yang mungkin masih berjalan
    screen -S \$SESSION_NAME -X quit >/dev/null 2>&1 || true
fi

# Matikan proses nexus-network untuk node ini
pkill -f "nexus-network start --node-id \$NODE_ID" 2>/dev/null || true

echo "Nexus node \$NODE_ID telah dihentikan"
EOF
    
    chmod +x "$SCRIPT_DIR/stop-nexus.sh"
    
    # Buat script untuk memeriksa status
    cat > "$SCRIPT_DIR/status-nexus.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

SCREEN_NAME="nexus-\$NODE_ID"

if screen -list | grep -q "\$SCREEN_NAME"; then
    echo "Nexus node \$NODE_ID sedang berjalan"
    
    # Cek proses nexus-network
    if pgrep -f "nexus-network start --node-id \$NODE_ID" > /dev/null; then
        echo "Proses nexus-network untuk node \$NODE_ID terdeteksi"
    else
        echo "Peringatan: Screen \$SCREEN_NAME berjalan tetapi proses nexus-network tidak terdeteksi"
    fi
else
    echo "Nexus node \$NODE_ID tidak berjalan"
fi
EOF
    
    chmod +x "$SCRIPT_DIR/status-nexus.sh"
    
    echo -e "${GREEN}[✓] Script runner berhasil dibuat${RESET}"
    echo ""
}

# === Jalankan Nexus Node ===
function run_nexus_node() {
    local node_id=$1
    
    echo -e "${CYAN}[*] Menjalankan Nexus node dengan ID: ${node_id}...${RESET}"
    
    # Buat direktori .nexus jika belum ada
    mkdir -p "$NODE_DATA_DIR"
    
    # Buat direktori log jika belum ada
    mkdir -p "$LOG_DIR"
    
    # Tambahkan node ke daftar node
    if ! grep -q "^$node_id$" "$NODE_LIST_FILE" 2>/dev/null; then
        echo "$node_id" >> "$NODE_LIST_FILE"
        echo -e "${GREEN}[✓] Node $node_id ditambahkan ke daftar node${RESET}"
    fi
    
    # Verifikasi bahwa nexus binary ada dan dapat dijalankan
    if [ ! -f "$SCRIPT_DIR/nexus-binary-path.txt" ]; then
        echo -e "${RED}[!] Nexus binary path tidak ditemukan${RESET}"
        echo -e "${YELLOW}[!] Menjalankan ulang create_runner_script untuk mencari binary${RESET}"
        create_runner_script
    fi
    
    # Jalankan script runner
    "$SCRIPT_DIR/run-nexus.sh" "$node_id"
    
    # Cek apakah berhasil
    if [ $? -ne 0 ]; then
        echo -e "${RED}[!] Gagal menjalankan node${RESET}"
        echo -e "${YELLOW}[!] Mencoba menjalankan nexus-network secara langsung...${RESET}"
        
        # Coba jalankan nexus-network secara langsung
        if [ -f "$SCRIPT_DIR/nexus-binary-path.txt" ]; then
            NEXUS_BINARY=$(cat "$SCRIPT_DIR/nexus-binary-path.txt")
            SCREEN_NAME="nexus-$node_id"
            LOG_FILE="$LOG_DIR/nexus-$node_id.log"
            
            # Matikan screen yang mungkin masih berjalan
            screen -S $SCREEN_NAME -X quit >/dev/null 2>&1 || true
            
            # Jalankan nexus-network di dalam screen
            echo -e "${YELLOW}[!] Menjalankan: $NEXUS_BINARY start --node-id $node_id${RESET}"
            screen -dmS $SCREEN_NAME bash -c "$NEXUS_BINARY start --node-id $node_id &>> $LOG_FILE"
            
            # Tunggu sebentar untuk memastikan screen sudah berjalan
            sleep 3
            
            # Cek apakah screen berhasil dijalankan
            if screen -list | grep -q "$SCREEN_NAME"; then
                echo -e "${GREEN}[✓] Node $node_id berjalan di latar belakang${RESET}"
                echo -e "${GREEN}[✓] Log tersedia di: $LOG_FILE${RESET}"
                echo -e "${GREEN}[✓] Untuk melihat screen: screen -r $SCREEN_NAME${RESET}"
            else
                echo -e "${RED}[!] Gagal menjalankan node${RESET}"
                echo -e "${YELLOW}[!] Cek log untuk detail: $LOG_FILE${RESET}"
                cat "$LOG_FILE"
            fi
        else
            echo -e "${RED}[!] Tidak dapat menemukan nexus-network binary${RESET}"
        fi
    else
        echo -e "${GREEN}[✓] Nexus node berhasil dijalankan${RESET}"
        echo -e "${GREEN}[✓] Log tersedia di: $LOG_DIR/nexus-${node_id}.log${RESET}"
        echo -e "${GREEN}[✓] Untuk melihat screen: screen -r nexus-${node_id}${RESET}"
    fi
    
    echo ""
}

# === Lihat Status Node ===
function view_node_status() {
    echo -e "${CYAN}[*] Memeriksa status Nexus node...${RESET}"
    
    if [ ! -f "$NODE_LIST_FILE" ] || [ ! -s "$NODE_LIST_FILE" ]; then
        echo -e "${YELLOW}[!] Tidak ada node yang terdaftar${RESET}"
        read -p "Tekan enter untuk kembali ke menu..."
        return
    fi
    
    echo -e "${CYAN}📊 Daftar Node Terdaftar:${RESET}"
    echo "--------------------------------------------------------------"
    printf "%-5s %-20s %-12s %-15s %-15s\n" "No" "Node ID" "Status" "CPU" "Memori"
    echo "--------------------------------------------------------------"
    
    local i=1
    local failed_nodes=()
    while read -r node_id; do
        local status="Tidak Aktif"
        local cpu="N/A"
        local mem="N/A"
        local session_name="nexus-$node_id"
        
        # Cek status berdasarkan session manager yang digunakan
        local is_running=false
        if [ "$SESSION_MANAGER" = "tmux" ]; then
            if tmux has-session -t "$session_name" 2>/dev/null; then
                is_running=true
                status="Aktif (tmux)"
            fi
        else
            if screen -list | grep -q "$session_name"; then
                is_running=true
                status="Aktif (screen)"
            fi
        fi
        
        # Jika session berjalan, cek proses dan ambil statistik
        if [ "$is_running" = true ]; then
            # Cari PID proses nexus-network untuk node ini
            local nexus_pid=$(pgrep -f "nexus-network start --node-id $node_id" | head -n 1)
            
            if [ -n "$nexus_pid" ]; then
                # Ambil statistik CPU dan memori dari proses
                if command -v ps >/dev/null 2>&1; then
                    local stats=$(ps -p "$nexus_pid" -o %cpu,%mem --no-headers 2>/dev/null)
                    if [ -n "$stats" ]; then
                        cpu=$(echo "$stats" | awk '{print $1"%"}')
                        mem=$(echo "$stats" | awk '{print $2"%"}')
                    fi
                fi
            else
                # Session berjalan tapi proses tidak ditemukan
                status="Error"
                failed_nodes+=("$node_id")
            fi
        fi
        
        printf "%-5s %-20s %-12s %-15s %-15s\n" "$i" "$node_id" "$status" "$cpu" "$mem"
        i=$((i+1))
    done < "$NODE_LIST_FILE"
    
    echo "--------------------------------------------------------------"
    
    if [ ${#failed_nodes[@]} -gt 0 ]; then
        echo -e "${RED}⚠ Node dengan masalah (session aktif tapi proses tidak ditemukan):${RESET}"
        for id in "${failed_nodes[@]}"; do
            echo "- $id"
        done
        echo ""
    fi
    
    read -rp "Pilih nomor node untuk melihat detail status (0 untuk kembali): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$((i-1))" ]; then
        local selected_node=$(sed -n "${choice}p" "$NODE_LIST_FILE")
        echo -e "${CYAN}Detail status untuk node $selected_node:${RESET}"
        
        # Tampilkan informasi detail
        local session_name="nexus-$selected_node"
        local nexus_pid=$(pgrep -f "nexus-network start --node-id $selected_node" | head -n 1)
        
        echo "Node ID: $selected_node"
        echo "Session Manager: $SESSION_MANAGER"
        echo "Session Name: $session_name"
        
        if [ "$SESSION_MANAGER" = "tmux" ]; then
            if tmux has-session -t "$session_name" 2>/dev/null; then
                echo "Tmux Session: Aktif"
                echo "Untuk melihat session: tmux attach-session -t $session_name"
            else
                echo "Tmux Session: Tidak aktif"
            fi
        else
            if screen -list | grep -q "$session_name"; then
                echo "Screen Session: Aktif"
                echo "Untuk melihat session: screen -r $session_name"
            else
                echo "Screen Session: Tidak aktif"
            fi
        fi
        
        if [ -n "$nexus_pid" ]; then
            echo "Process ID: $nexus_pid"
            echo "Process Status: Berjalan"
            
            # Tampilkan statistik detail
            if command -v ps >/dev/null 2>&1; then
                echo ""
                echo "Statistik Proses:"
                ps -p "$nexus_pid" -o pid,ppid,%cpu,%mem,vsz,rss,tty,stat,start,time,cmd --no-headers 2>/dev/null || echo "Tidak dapat mengambil statistik proses"
            fi
        else
            echo "Process ID: Tidak ditemukan"
            echo "Process Status: Tidak berjalan"
        fi
        
        # Tampilkan log terbaru
        local log_file="$LOG_DIR/nexus-$selected_node.log"
        if [ -f "$log_file" ]; then
            echo ""
            echo "Log terbaru (10 baris terakhir):"
            echo "----------------------------------------"
            tail -n 10 "$log_file"
        fi
    fi
    
    echo ""
    read -p "Tekan enter untuk kembali ke menu..."
}

# === Lihat Log Node ===
function view_node_logs() {
    echo -e "${CYAN}[*] Menampilkan log Nexus node...${RESET}"
    
    if [ ! -f "$NODE_LIST_FILE" ] || [ ! -s "$NODE_LIST_FILE" ]; then
        echo -e "${YELLOW}[!] Tidak ada node yang terdaftar${RESET}"
        read -p "Tekan enter untuk kembali ke menu..."
        return
    fi
    
    echo -e "${CYAN}Pilih node untuk melihat log:${RESET}"
    local i=1
    while read -r node_id; do
        echo "$i. Node ID: $node_id"
        i=$((i+1))
    done < "$NODE_LIST_FILE"
    
    read -rp "Pilih nomor node (0 untuk kembali): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$((i-1))" ]; then
        local selected_node=$(sed -n "${choice}p" "$NODE_LIST_FILE")
        echo -e "${CYAN}Menampilkan log untuk node $selected_node:${RESET}"
        "$SCRIPT_DIR/view-log.sh" "$selected_node"
    fi
    
    echo ""
    read -p "Tekan enter untuk kembali ke menu..."
}

# === Hentikan Node ===
function stop_nexus_node() {
    echo -e "${CYAN}[*] Menghentikan Nexus node...${RESET}"
    
    if [ ! -f "$NODE_LIST_FILE" ] || [ ! -s "$NODE_LIST_FILE" ]; then
        echo -e "${YELLOW}[!] Tidak ada node yang terdaftar${RESET}"
        read -p "Tekan enter untuk kembali ke menu..."
        return
    fi
    
    echo -e "${CYAN}Pilih node untuk dihentikan:${RESET}"
    echo "0. Hentikan semua node"
    local i=1
    while read -r node_id; do
        echo "$i. Node ID: $node_id"
        i=$((i+1))
    done < "$NODE_LIST_FILE"
    
    read -rp "Pilih nomor node (0 untuk semua): " choice
    
    if [ "$choice" -eq 0 ]; then
        echo -e "${YELLOW}[!] Menghentikan semua node...${RESET}"
        while read -r node_id; do
            echo -e "${CYAN}[*] Menghentikan node $node_id...${RESET}"
            "$SCRIPT_DIR/stop-nexus.sh" "$node_id"
        done < "$NODE_LIST_FILE"
        echo -e "${GREEN}[✓] Semua node berhasil dihentikan${RESET}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$((i-1))" ]; then
        local selected_node=$(sed -n "${choice}p" "$NODE_LIST_FILE")
        echo -e "${CYAN}[*] Menghentikan node $selected_node...${RESET}"
        "$SCRIPT_DIR/stop-nexus.sh" "$selected_node"
        echo -e "${GREEN}[✓] Node $selected_node berhasil dihentikan${RESET}"
    else
        echo -e "${RED}[!] Pilihan tidak valid${RESET}"
    fi
    
    echo ""
    read -p "Tekan enter untuk kembali ke menu..."
}

# === Hapus Node ===
function uninstall_node() {
    echo -e "${CYAN}[*] Menghapus Nexus node...${RESET}"
    
    if [ ! -f "$NODE_LIST_FILE" ] || [ ! -s "$NODE_LIST_FILE" ]; then
        echo -e "${YELLOW}[!] Tidak ada node yang terdaftar${RESET}"
        read -p "Tekan enter untuk kembali ke menu..."
        return
    fi
    
    echo -e "${CYAN}Pilih node untuk dihapus:${RESET}"
    echo "0. Hapus semua node"
    local i=1
    while read -r node_id; do
        echo "$i. Node ID: $node_id"
        i=$((i+1))
    done < "$NODE_LIST_FILE"
    
    read -rp "Pilih nomor node (0 untuk semua): " choice
    
    if [ "$choice" -eq 0 ]; then
        echo -e "${YELLOW}[!] Menghapus semua node...${RESET}"
        while read -r node_id; do
            echo -e "${CYAN}[*] Menghapus node $node_id...${RESET}"
            # Hentikan node terlebih dahulu
            "$SCRIPT_DIR/stop-nexus.sh" "$node_id"
            # Hapus log
            rm -f "$LOG_DIR/nexus-$node_id.log"
        done < "$NODE_LIST_FILE"
        # Hapus daftar node
        rm -f "$NODE_LIST_FILE"
        echo -e "${GREEN}[✓] Semua node berhasil dihapus${RESET}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$((i-1))" ]; then
        local selected_node=$(sed -n "${choice}p" "$NODE_LIST_FILE")
        echo -e "${CYAN}[*] Menghapus node $selected_node...${RESET}"
        # Hentikan node terlebih dahulu
        "$SCRIPT_DIR/stop-nexus.sh" "$selected_node"
        # Hapus log
        rm -f "$LOG_DIR/nexus-$selected_node.log"
        # Hapus dari daftar node
        grep -v "^$selected_node$" "$NODE_LIST_FILE" > "$NODE_LIST_FILE.tmp"
        mv "$NODE_LIST_FILE.tmp" "$NODE_LIST_FILE"
        echo -e "${GREEN}[✓] Node $selected_node berhasil dihapus${RESET}"
    else
        echo -e "${RED}[!] Pilihan tidak valid${RESET}"
    fi
    
    echo ""
    read -p "Tekan enter untuk kembali ke menu..."
}

# === Reset Lengkap ===
function full_reset() {
    echo -e "${RED}⚠️  PERINGATAN: Ini akan menghapus SEMUA data Nexus dan CLI!${RESET}"
    echo "- Semua node akan dihentikan dan dihapus"
    echo "- CLI Nexus akan dihapus"
    echo "- Log files akan dihapus"
    echo "- Script dan direktori akan dihapus"
    echo ""
    echo "Setelah reset, Anda dapat menginstal CLI versi terbaru saat menjalankan node baru."
    echo ""
    read -rp "Ketik 'RESET' untuk konfirmasi: " confirm
    
    if [[ "$confirm" == "RESET" ]]; then
        echo -e "${YELLOW}[*] Memulai reset lengkap...${RESET}"
        
        # Hentikan semua node
        if [ -f "$NODE_LIST_FILE" ] && [ -s "$NODE_LIST_FILE" ]; then
            while read -r node_id; do
                echo -e "${CYAN}[*] Menghentikan node $node_id...${RESET}"
                "$SCRIPT_DIR/stop-nexus.sh" "$node_id" 2>/dev/null || true
            done < "$NODE_LIST_FILE"
        fi
        
        # Hapus semua proses nexus-network yang masih berjalan
        pkill -f "nexus-network" 2>/dev/null || true
        
        # Hapus semua screen nexus
        screen -ls | grep "nexus-" | cut -d. -f1 | awk '{print $1}' | xargs -I {} screen -S {} -X quit 2>/dev/null || true
        
        # Hapus CLI dan direktori nexus
        clean_old_cli
        
        # Hapus direktori log
        rm -rf "$LOG_DIR"
        
        # Hapus direktori script
        rm -rf "$SCRIPT_DIR"
        
        # Hapus file daftar node
        rm -f "$NODE_LIST_FILE"
        
        echo -e "${GREEN}✅ Reset lengkap berhasil!${RESET}"
        echo "Sekarang Anda dapat menjalankan node baru dengan CLI versi terbaru."
    else
        echo "Reset dibatalkan."
    fi
    read -p "Tekan enter..."
}

# === Fungsi restart semua node ===
function restart_all_nodes() {
    if [ ! -f "$NODE_LIST_FILE" ] || [ ! -s "$NODE_LIST_FILE" ]; then
        echo -e "${YELLOW}⚠️  Tidak ada node yang terdaftar untuk di-restart${RESET}"
        return
    fi
    
    echo -e "${CYAN}♻  Memulai restart otomatis semua node...${RESET}"
    
    while read -r node_id; do
        echo -e "${YELLOW}🔄 Restarting node ${node_id}...${RESET}"
        
        # Stop node
        "$SCRIPT_DIR/stop-nexus.sh" "$node_id" >/dev/null 2>&1
        
        # Wait a moment
        sleep 2
        
        # Start node again
        "$SCRIPT_DIR/run-nexus.sh" "$node_id" >/dev/null 2>&1
        
    done < "$NODE_LIST_FILE"
    
    echo -e "${GREEN}✅ Semua node telah di-restart${RESET}"
    echo -e "${CYAN}⏱  Next restart: $(date -d "+${REFRESH_INTERVAL_MINUTES} minutes" "+%H:%M:%S")${RESET}"
}

# === Setup cron untuk auto-refresh ===
function setup_auto_refresh() {
    check_cron
    mkdir -p "$LOG_DIR"
    
    # Cek apakah auto-refresh sudah aktif
    local is_active=false
    if crontab -l 2>/dev/null | grep -q "restart_nexus_nodes"; then
        is_active=true
    fi
    
    show_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "                           🔄 PENGATURAN AUTO-REFRESH NODE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    if [ "$is_active" = true ]; then
        echo -e "${GREEN}Status: Auto-refresh AKTIF${RESET}"
        echo -e "${CYAN}Interval: Setiap ${REFRESH_INTERVAL_MINUTES} menit${RESET}"
        echo -e "${CYAN}Next restart: $(date -d "+${REFRESH_INTERVAL_MINUTES} minutes" "+%H:%M:%S")${RESET}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        echo -e "${GREEN}1.${RESET} Ubah interval refresh (saat ini: ${REFRESH_INTERVAL_MINUTES} menit)"
        echo -e "${GREEN}2.${RESET} Matikan auto-refresh"
        echo -e "${GREEN}3.${RESET} Restart semua node sekarang"
        echo -e "${GREEN}4.${RESET} Kembali ke menu utama"
        
        read -rp "Pilih opsi (1-4): " choice
        
        case $choice in
            1)
                read -rp "Masukkan interval refresh baru (dalam menit): " new_interval
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -gt 0 ]; then
                    REFRESH_INTERVAL_MINUTES=$new_interval
                    # Update konfigurasi
                    sed -i "s/^REFRESH_INTERVAL_MINUTES=.*/REFRESH_INTERVAL_MINUTES=$new_interval  # Interval restart otomatis/" "$0"
                    # Aktifkan ulang dengan interval baru
                    crontab -l | grep -v "restart_nexus_nodes" | crontab -
                    (crontab -l 2>/dev/null; echo "*/${REFRESH_INTERVAL_MINUTES} * * * * $PWD/$0 --restart-nodes >> $LOG_DIR/refresh.log 2>&1") | crontab -
                    AUTO_REFRESH_ENABLED=true
                    sed -i "s/^AUTO_REFRESH_ENABLED=.*/AUTO_REFRESH_ENABLED=true   # Status auto-refresh/" "$0"
                    echo -e "${GREEN}✅ Interval refresh diubah menjadi ${new_interval} menit${RESET}"
                else
                    echo -e "${RED}Interval tidak valid. Harus berupa angka positif.${RESET}"
                fi
                ;;
            2)
                crontab -l | grep -v "restart_nexus_nodes" | crontab -
                AUTO_REFRESH_ENABLED=false
                sed -i "s/^AUTO_REFRESH_ENABLED=.*/AUTO_REFRESH_ENABLED=false   # Status auto-refresh/" "$0"
                echo -e "${YELLOW}🔄 Auto-refresh dinonaktifkan${RESET}"
                ;;
            3)
                restart_all_nodes
                ;;
            4)
                return
                ;;
            *)
                echo -e "${RED}Pilihan tidak valid.${RESET}"
                ;;
        esac
    else
        echo -e "${RED}Status: Auto-refresh TIDAK AKTIF${RESET}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        echo -e "${GREEN}1.${RESET} Aktifkan auto-refresh (interval: ${REFRESH_INTERVAL_MINUTES} menit)"
        echo -e "${GREEN}2.${RESET} Ubah interval refresh (saat ini: ${REFRESH_INTERVAL_MINUTES} menit)"
        echo -e "${GREEN}3.${RESET} Kembali ke menu utama"
        
        read -rp "Pilih opsi (1-3): " choice
        
        case $choice in
            1)
                crontab -l | grep -v "restart_nexus_nodes" | crontab -
                (crontab -l 2>/dev/null; echo "*/${REFRESH_INTERVAL_MINUTES} * * * * $PWD/$0 --restart-nodes >> $LOG_DIR/refresh.log 2>&1") | crontab -
                AUTO_REFRESH_ENABLED=true
                sed -i "s/^AUTO_REFRESH_ENABLED=.*/AUTO_REFRESH_ENABLED=true   # Status auto-refresh/" "$0"
                echo -e "${GREEN}✅ Auto-refresh diaktifkan setiap ${REFRESH_INTERVAL_MINUTES} menit${RESET}"
                echo -e "${CYAN}⏱  Next restart: $(date -d "+${REFRESH_INTERVAL_MINUTES} minutes" "+%H:%M:%S")${RESET}"
                restart_all_nodes
                ;;
            2)
                read -rp "Masukkan interval refresh baru (dalam menit): " new_interval
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -gt 0 ]; then
                    REFRESH_INTERVAL_MINUTES=$new_interval
                    sed -i "s/^REFRESH_INTERVAL_MINUTES=.*/REFRESH_INTERVAL_MINUTES=$new_interval  # Interval restart otomatis/" "$0"
                    echo -e "${GREEN}✅ Interval refresh diubah menjadi ${new_interval} menit${RESET}"
                else
                    echo -e "${RED}Interval tidak valid. Harus berupa angka positif.${RESET}"
                fi
                ;;
            3)
                return
                ;;
            *)
                echo -e "${RED}Pilihan tidak valid.${RESET}"
                ;;
        esac
    fi
    
    read -p "Tekan enter untuk kembali..."
    setup_auto_refresh
}

# === Periksa Cron ===
function check_cron() {
    if ! command -v cron >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Cron belum tersedia. Menginstal cron...${RESET}"
        apt update >/dev/null 2>&1
        apt install -y cron >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1
        systemctl start cron >/dev/null 2>&1
        echo -e "${GREEN}✅ Cron berhasil diinstal${RESET}"
    fi
}

# === Informasi Sistem ===
function show_system_info() {
    show_header
    echo -e "${CYAN}ℹ️  Informasi Sistem:${RESET}"
    echo "--------------------------------------------------------------"
    echo -e "${GREEN}Versi Ubuntu:${RESET} $UBUNTU_VERSION"
    echo -e "${GREEN}Versi GLIBC:${RESET} $GLIBC_VERSION"
    
    if [ "$GLIBC_COMPATIBLE" = true ]; then
        echo -e "${GREEN}Kompatibilitas GLIBC:${RESET} Kompatibel dengan Nexus Network"
    else
        echo -e "${RED}Kompatibilitas GLIBC:${RESET} Tidak kompatibel dengan Nexus Network"
    fi
    
    if [ "$IN_CONTAINER" = true ]; then
        echo -e "${GREEN}Container:${RESET} Berjalan di dalam container"
    else
        echo -e "${GREEN}Container:${RESET} Berjalan di host"
    fi
    
    echo -e "${GREEN}Session Manager:${RESET} $SESSION_MANAGER"
    
    # Cek status node
    echo -e "${GREEN}Status Node:${RESET}"
    if [ -f "$NODE_LIST_FILE" ] && [ -s "$NODE_LIST_FILE" ]; then
        echo "Node terdaftar:"
        local i=1
        while read -r node_id; do
            local status="Tidak Aktif"
            local session_name="nexus-$node_id"
            
            if [ "$SESSION_MANAGER" = "tmux" ]; then
                if tmux has-session -t "$session_name" 2>/dev/null; then
                    status="Aktif (tmux)"
                fi
            else
                if screen -list | grep -q "$session_name"; then
                    status="Aktif (screen)"
                fi
            fi
            
            echo "$i. Node ID: $node_id - Status: $status"
            i=$((i+1))
        done < "$NODE_LIST_FILE"
    else
        echo "Tidak ada node yang terdaftar"
    fi
    
    echo "--------------------------------------------------------------"
    
    read -p "Tekan enter untuk kembali ke menu..."
}

# === MENU UTAMA ===
function main_menu() {
    while true; do
        show_header
        
        # Tampilkan jumlah node aktif
        local active_nodes=0
        local total_nodes=0
        if [ -f "$NODE_LIST_FILE" ] && [ -s "$NODE_LIST_FILE" ]; then
            total_nodes=$(wc -l < "$NODE_LIST_FILE")
            while read -r node_id; do
                if screen -list | grep -q "nexus-$node_id"; then
                    active_nodes=$((active_nodes+1))
                fi
            done < "$NODE_LIST_FILE"
        fi
        
        echo -e "${CYAN}Node Aktif: ${GREEN}$active_nodes${RESET}/${YELLOW}$total_nodes${RESET}"
        echo ""
        
        echo -e "${GREEN} 1.${RESET} ➕ Instal & Jalankan Node Baru"
        echo -e "${GREEN} 2.${RESET} 📊 Lihat Status Node"
        echo -e "${GREEN} 3.${RESET} 🧾 Lihat Log Node"
        echo -e "${GREEN} 4.${RESET} ⏹️  Hentikan Node"
        echo -e "${GREEN} 5.${RESET} 💥 Hapus Node"
        echo -e "${GREEN} 6.${RESET} 🔄 Ganti Session Manager"
        echo -e "${GREEN} 7.${RESET} 🔄 Auto-Refresh Node"
        echo -e "${GREEN} 8.${RESET} 🔥 Reset Lengkap (Force Update CLI)"
        echo -e "${GREEN} 9.${RESET} ℹ️  Informasi Sistem"
        echo -e "${GREEN}10.${RESET} 🚪 Keluar"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        read -rp "Pilih menu (1-10): " pilihan
        
        case $pilihan in
            1)
                if [ "$GLIBC_COMPATIBLE" = false ]; then
                    echo -e "${RED}[!] PERINGATAN: Sistem Anda tidak kompatibel dengan Nexus Network${RESET}"
                    echo -e "${RED}[!] Nexus Network memerlukan GLIBC 2.39 yang tersedia di Ubuntu 24.04${RESET}"
                    read -rp "Tetap lanjutkan? (y/n): " confirm
                    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                        continue
                    fi
                fi
                
                # Pilih versi terlebih dahulu
                while true; do
                    if select_version; then
                        break
                    fi
                done
                
                # Pilih session manager jika belum dipilih
                if [ -z "$SESSION_MANAGER" ]; then
                    choose_session_manager
                fi
                
                # Install dependencies
                install_dependencies
                
                # Buat direktori
                create_directories
                
                # Install Nexus CLI dengan versi yang dipilih
                install_nexus_cli "$NEXUS_VERSION"
                
                # Buat script runner
                create_runner_script
                
                # Jalankan Nexus node
                read -rp "Masukkan NODE_ID: " NODE_ID
                [ -z "$NODE_ID" ] && echo "NODE_ID tidak boleh kosong." && read -p "Tekan enter..." && continue
                run_nexus_node "$NODE_ID"
                
                # Update current version info after successful installation
                if [[ "$NEXUS_VERSION" == "latest" ]]; then
                    CURRENT_NEXUS_VERSION="Latest (Official)"
                else
                    CURRENT_NEXUS_VERSION="$NEXUS_VERSION"
                fi
                
                read -p "Tekan enter..."
                ;;
            2) 
                view_node_status 
                ;;
            3) 
                view_node_logs 
                ;;
            4) 
                stop_nexus_node 
                ;;
            5) 
                uninstall_node 
                ;;
            6) 
                choose_session_manager 
                ;;
            7) 
                setup_auto_refresh 
                ;;
            8) 
                full_reset 
                ;;
            9)
                show_system_info
                ;;
            10) 
                echo "Keluar..."; 
                exit 0 
                ;;
            *) 
                echo "Pilihan tidak valid."; 
                read -p "Tekan enter..." 
                ;;
        esac
    done
}

# === MAIN EXECUTION ===

# Handle command line arguments for auto-refresh
if [[ "$1" == "--restart-nodes" ]]; then
    # Load session manager yang tersimpan
    load_saved_session_manager
    
    # Restart all nodes
    restart_all_nodes
    exit 0
fi

show_header
detect_environment

# Buat direktori script jika belum ada
mkdir -p "$SCRIPT_DIR"
mkdir -p "$LOG_DIR"

# Load session manager yang tersimpan
load_saved_session_manager

# Coba source profile untuk mendapatkan PATH yang diperbarui
source /root/.profile 2>/dev/null || true

# Jalankan menu utama
main_menu
