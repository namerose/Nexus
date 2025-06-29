#!/bin/bash
set -e

# === Konfigurasi dasar ===
NODE_DATA_DIR="/root/.nexus"
LOG_DIR="/root/nexus_logs"
WORKSPACE_DIR="/root"
SCRIPT_DIR="/root/nexus-scripts"
NODE_LIST_FILE="/root/nexus_nodes.txt"  # File untuk menyimpan daftar node
CONTAINER_PREFIX="nexus-node"

# === Warna terminal ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

# === Header Tampilan ===
function show_header() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "                     NEXUS - Podman"
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
    
    # Cek apakah Podman sudah terinstall
    if command -v podman &> /dev/null; then
        PODMAN_VERSION=$(podman --version | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
        echo -e "${GREEN}[✓] Podman terdeteksi versi: $PODMAN_VERSION${RESET}"
        PODMAN_INSTALLED=true
    else
        echo -e "${YELLOW}[!] Podman belum terinstall${RESET}"
        PODMAN_INSTALLED=false
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

# === Install Podman ===
function install_podman() {
    echo -e "${CYAN}[*] Menginstall Podman...${RESET}"
    
    # Update package index
    apt update
    
    # Install dependencies
    apt install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates
    
    # Coba install Podman dari repository Ubuntu default terlebih dahulu
    echo -e "${CYAN}[*] Mencoba install Podman dari repository Ubuntu...${RESET}"
    apt install -y podman 2>/dev/null
    
    # Cek apakah berhasil
    if command -v podman &> /dev/null; then
        PODMAN_VERSION=$(podman --version | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")
        echo -e "${GREEN}[✓] Podman berhasil diinstall dari repository Ubuntu versi: $PODMAN_VERSION${RESET}"
        PODMAN_INSTALLED=true
    else
        echo -e "${YELLOW}[!] Podman tidak tersedia di repository Ubuntu, mencoba repository alternatif...${RESET}"
        
        # Hapus repository lama jika ada
        rm -f /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
        
        # Coba metode alternatif dengan GPG key yang lebih aman
        . /etc/os-release
        
        # Download dan install GPG key dengan cara yang lebih aman
        curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key" | gpg --dearmor -o /usr/share/keyrings/libcontainers-archive-keyring.gpg
        
        # Add repository dengan signed-by
        echo "deb [signed-by=/usr/share/keyrings/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" | tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
        
        # Update dan install
        apt update
        apt install -y podman
        
        # Verify installation
        if command -v podman &> /dev/null; then
            PODMAN_VERSION=$(podman --version | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")
            echo -e "${GREEN}[✓] Podman berhasil diinstall dari repository alternatif versi: $PODMAN_VERSION${RESET}"
            PODMAN_INSTALLED=true
        else
            echo -e "${RED}[!] Gagal menginstall Podman dari semua repository${RESET}"
            echo -e "${YELLOW}[!] Mencoba install dengan snap sebagai alternatif terakhir...${RESET}"
            
            # Install snap jika belum ada
            apt install -y snapd
            
            # Install Podman via snap
            snap install podman
            
            # Cek lagi
            if command -v podman &> /dev/null; then
                PODMAN_VERSION=$(podman --version | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "snap")
                echo -e "${GREEN}[✓] Podman berhasil diinstall via snap versi: $PODMAN_VERSION${RESET}"
                PODMAN_INSTALLED=true
            else
                echo -e "${RED}[!] Gagal menginstall Podman dengan semua metode${RESET}"
                PODMAN_INSTALLED=false
                return 1
            fi
        fi
    fi
    
    echo ""
}

# === Periksa dan Install Dependencies ===
function install_dependencies() {
    echo -e "${CYAN}[*] Memeriksa dan menginstal dependencies...${RESET}"
    
    # Update package index
    apt update
    
    # Install dependencies
    apt install -y curl build-essential pkg-config libssl-dev git-all
    
    # Install Podman jika belum ada
    if [ "$PODMAN_INSTALLED" = false ]; then
        install_podman
    fi
    
    echo -e "${GREEN}[✓] Dependencies berhasil diinstal${RESET}"
    echo ""
}

# === Buat Direktori ===
function create_directories() {
    echo -e "${CYAN}[*] Membuat direktori yang diperlukan...${RESET}"
    
    mkdir -p "$LOG_DIR"
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$NODE_DATA_DIR"
    
    echo -e "${GREEN}[✓] Direktori berhasil dibuat${RESET}"
    echo ""
}

# === Buat Dockerfile untuk Nexus ===
function create_nexus_dockerfile() {
    echo -e "${CYAN}[*] Membuat Dockerfile untuk Nexus...${RESET}"
    
    cat > "$SCRIPT_DIR/Dockerfile.nexus" <<EOF
FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \\
    curl \\
    build-essential \\
    pkg-config \\
    libssl-dev \\
    ca-certificates \\
    && rm -rf /var/lib/apt/lists/*

# Create nexus user
RUN useradd -m -s /bin/bash nexus

# Switch to nexus user
USER nexus
WORKDIR /home/nexus

# Install Nexus CLI
RUN curl -sSL https://cli.nexus.xyz/ | sh

# Add Nexus binary to PATH
ENV PATH="/home/nexus/.nexus/bin:\$PATH"

# Create data directory
RUN mkdir -p /home/nexus/.nexus

# Set entrypoint
ENTRYPOINT ["/home/nexus/.nexus/bin/nexus-network"]
CMD ["start"]
EOF
    
    echo -e "${GREEN}[✓] Dockerfile berhasil dibuat${RESET}"
    echo ""
}

# === Build Nexus Container Image ===
function build_nexus_image() {
    echo -e "${CYAN}[*] Building Nexus container image...${RESET}"
    
    cd "$SCRIPT_DIR"
    
    # Build image dengan Podman
    podman build -f Dockerfile.nexus -t nexus-network:latest .
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[✓] Nexus container image berhasil dibuild${RESET}"
    else
        echo -e "${RED}[!] Gagal build Nexus container image${RESET}"
        return 1
    fi
    
    echo ""
}

# === Buat Script Runner untuk Podman ===
function create_runner_script() {
    echo -e "${CYAN}[*] Membuat script runner untuk Podman...${RESET}"
    
    cat > "$SCRIPT_DIR/run-nexus-podman.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

CONTAINER_NAME="${CONTAINER_PREFIX}-\$NODE_ID"
LOG_FILE="$LOG_DIR/nexus-\$NODE_ID.log"

# Hentikan dan hapus container yang mungkin masih berjalan
podman stop \$CONTAINER_NAME >/dev/null 2>&1 || true
podman rm \$CONTAINER_NAME >/dev/null 2>&1 || true

# Jalankan container dengan Podman
podman run -d \\
    --name \$CONTAINER_NAME \\
    --restart unless-stopped \\
    -v "$NODE_DATA_DIR:/home/nexus/.nexus" \\
    -v "$LOG_DIR:/home/nexus/logs" \\
    nexus-network:latest \\
    start --node-id \$NODE_ID

# Cek apakah container berhasil dijalankan
if podman ps | grep -q "\$CONTAINER_NAME"; then
    echo "Node \$NODE_ID berjalan dalam container \$CONTAINER_NAME"
    
    # Redirect logs ke file
    podman logs -f \$CONTAINER_NAME >> \$LOG_FILE 2>&1 &
    
    echo "Log tersedia di: \$LOG_FILE"
    echo "Untuk melihat logs: podman logs -f \$CONTAINER_NAME"
    echo "Untuk masuk ke container: podman exec -it \$CONTAINER_NAME /bin/bash"
else
    echo "Gagal menjalankan container untuk node \$NODE_ID"
    podman logs \$CONTAINER_NAME
    exit 1
fi
EOF
    
    chmod +x "$SCRIPT_DIR/run-nexus-podman.sh"
    
    # Buat script untuk melihat log
    cat > "$SCRIPT_DIR/view-log-podman.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

CONTAINER_NAME="${CONTAINER_PREFIX}-\$NODE_ID"

if podman ps | grep -q "\$CONTAINER_NAME"; then
    echo "Menampilkan logs untuk container \$CONTAINER_NAME:"
    podman logs -f \$CONTAINER_NAME
else
    echo "Container \$CONTAINER_NAME tidak berjalan"
    LOG_FILE="$LOG_DIR/nexus-\$NODE_ID.log"
    if [ -f "\$LOG_FILE" ]; then
        echo "Menampilkan log file lokal:"
        tail -f "\$LOG_FILE"
    else
        echo "Log file tidak ditemukan"
    fi
fi
EOF
    
    chmod +x "$SCRIPT_DIR/view-log-podman.sh"
    
    # Buat script untuk menghentikan node
    cat > "$SCRIPT_DIR/stop-nexus-podman.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

CONTAINER_NAME="${CONTAINER_PREFIX}-\$NODE_ID"

# Hentikan container
podman stop \$CONTAINER_NAME >/dev/null 2>&1 || true

# Hapus container
podman rm \$CONTAINER_NAME >/dev/null 2>&1 || true

echo "Nexus node \$NODE_ID (container \$CONTAINER_NAME) telah dihentikan"
EOF
    
    chmod +x "$SCRIPT_DIR/stop-nexus-podman.sh"
    
    # Buat script untuk memeriksa status
    cat > "$SCRIPT_DIR/status-nexus-podman.sh" <<EOF
#!/bin/bash
NODE_ID=\$1
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak diberikan"
    exit 1
fi

CONTAINER_NAME="${CONTAINER_PREFIX}-\$NODE_ID"

if podman ps | grep -q "\$CONTAINER_NAME"; then
    echo "Nexus node \$NODE_ID sedang berjalan dalam container \$CONTAINER_NAME"
    
    # Tampilkan informasi container
    echo "Status container:"
    podman ps --filter "name=\$CONTAINER_NAME" --format "table {{.Names}}\\t{{.Status}}\\t{{.Ports}}"
    
    # Tampilkan resource usage
    echo ""
    echo "Resource usage:"
    podman stats --no-stream \$CONTAINER_NAME
else
    echo "Nexus node \$NODE_ID tidak berjalan"
    
    # Cek apakah container ada tapi stopped
    if podman ps -a | grep -q "\$CONTAINER_NAME"; then
        echo "Container \$CONTAINER_NAME ditemukan tapi tidak berjalan"
        podman ps -a --filter "name=\$CONTAINER_NAME" --format "table {{.Names}}\\t{{.Status}}"
    fi
fi
EOF
    
    chmod +x "$SCRIPT_DIR/status-nexus-podman.sh"
    
    # Buat script untuk cleanup containers
    cat > "$SCRIPT_DIR/cleanup-nexus-podman.sh" <<EOF
#!/bin/bash

echo "Membersihkan semua container Nexus..."

# Hentikan semua container nexus
podman stop \$(podman ps -q --filter "name=${CONTAINER_PREFIX}-") 2>/dev/null || true

# Hapus semua container nexus
podman rm \$(podman ps -aq --filter "name=${CONTAINER_PREFIX}-") 2>/dev/null || true

# Hapus unused images (opsional)
read -p "Hapus unused images juga? (y/n): " cleanup_images
if [[ "\$cleanup_images" =~ ^[Yy]$ ]]; then
    podman image prune -f
fi

echo "Cleanup selesai"
EOF
    
    chmod +x "$SCRIPT_DIR/cleanup-nexus-podman.sh"
    
    echo -e "${GREEN}[✓] Script runner untuk Podman berhasil dibuat${RESET}"
    echo ""
}

# === Jalankan Nexus Node dengan Podman ===
function run_nexus_node() {
    local node_id=$1
    
    echo -e "${CYAN}[*] Menjalankan Nexus node dengan ID: ${node_id} menggunakan Podman...${RESET}"
    
    # Pastikan image sudah ada
    if ! podman images | grep -q "nexus-network"; then
        echo -e "${YELLOW}[!] Image nexus-network belum ada, building image...${RESET}"
        build_nexus_image
        if [ $? -ne 0 ]; then
            echo -e "${RED}[!] Gagal build image${RESET}"
            return 1
        fi
    fi
    
    # Buat direktori yang diperlukan
    mkdir -p "$NODE_DATA_DIR"
    mkdir -p "$LOG_DIR"
    
    # Tambahkan node ke daftar node
    if ! grep -q "^$node_id$" "$NODE_LIST_FILE" 2>/dev/null; then
        echo "$node_id" >> "$NODE_LIST_FILE"
        echo -e "${GREEN}[✓] Node $node_id ditambahkan ke daftar node${RESET}"
    fi
    
    # Jalankan script runner
    "$SCRIPT_DIR/run-nexus-podman.sh" "$node_id"
    
    # Cek apakah berhasil
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[✓] Nexus node berhasil dijalankan dalam container${RESET}"
        echo -e "${GREEN}[✓] Container name: ${CONTAINER_PREFIX}-${node_id}${RESET}"
        echo -e "${GREEN}[✓] Log tersedia di: $LOG_DIR/nexus-${node_id}.log${RESET}"
        echo -e "${GREEN}[✓] Untuk melihat logs: podman logs -f ${CONTAINER_PREFIX}-${node_id}${RESET}"
    else
        echo -e "${RED}[!] Gagal menjalankan node${RESET}"
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
    
    echo -e "${CYAN}Daftar node:${RESET}"
    echo "--------------------------------------------------------------"
    printf "%-5s %-20s %-15s %-12s\n" "No" "Node ID" "Container" "Status"
    echo "--------------------------------------------------------------"
    
    local i=1
    while read -r node_id; do
        local container_name="${CONTAINER_PREFIX}-$node_id"
        local status="Tidak Aktif"
        if podman ps | grep -q "$container_name"; then
            status="Aktif"
        fi
        printf "%-5s %-20s %-15s %-12s\n" "$i" "$node_id" "$container_name" "$status"
        i=$((i+1))
    done < "$NODE_LIST_FILE"
    
    echo "--------------------------------------------------------------"
    
    read -rp "Pilih nomor node untuk melihat detail status (0 untuk kembali): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$((i-1))" ]; then
        local selected_node=$(sed -n "${choice}p" "$NODE_LIST_FILE")
        echo -e "${CYAN}Detail status untuk node $selected_node:${RESET}"
        "$SCRIPT_DIR/status-nexus-podman.sh" "$selected_node"
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
        "$SCRIPT_DIR/view-log-podman.sh" "$selected_node"
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
            "$SCRIPT_DIR/stop-nexus-podman.sh" "$node_id"
        done < "$NODE_LIST_FILE"
        echo -e "${GREEN}[✓] Semua node berhasil dihentikan${RESET}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$((i-1))" ]; then
        local selected_node=$(sed -n "${choice}p" "$NODE_LIST_FILE")
        echo -e "${CYAN}[*] Menghentikan node $selected_node...${RESET}"
        "$SCRIPT_DIR/stop-nexus-podman.sh" "$selected_node"
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
            # Hentikan dan hapus container
            "$SCRIPT_DIR/stop-nexus-podman.sh" "$node_id"
            # Hapus log
            rm -f "$LOG_DIR/nexus-$node_id.log"
        done < "$NODE_LIST_FILE"
        # Hapus daftar node
        rm -f "$NODE_LIST_FILE"
        echo -e "${GREEN}[✓] Semua node berhasil dihapus${RESET}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$((i-1))" ]; then
        local selected_node=$(sed -n "${choice}p" "$NODE_LIST_FILE")
        echo -e "${CYAN}[*] Menghapus node $selected_node...${RESET}"
        # Hentikan dan hapus container
        "$SCRIPT_DIR/stop-nexus-podman.sh" "$selected_node"
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

# === Cleanup Containers ===
function cleanup_containers() {
    echo -e "${CYAN}[*] Membersihkan containers...${RESET}"
    
    "$SCRIPT_DIR/cleanup-nexus-podman.sh"
    
    echo ""
    read -p "Tekan enter untuk kembali ke menu..."
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
    
    if [ "$PODMAN_INSTALLED" = true ]; then
        echo -e "${GREEN}Podman:${RESET} Terinstall versi $PODMAN_VERSION"
        
        # Tampilkan informasi Podman
        echo -e "${GREEN}Podman Images:${RESET}"
        podman images | grep nexus || echo "  Tidak ada image nexus"
        
        echo -e "${GREEN}Running Containers:${RESET}"
        podman ps --filter "name=${CONTAINER_PREFIX}-" || echo "  Tidak ada container yang berjalan"
    else
        echo -e "${RED}Podman:${RESET} Belum terinstall"
    fi
    
    # Cek status node
    echo -e "${GREEN}Status Node:${RESET}"
    if [ -f "$NODE_LIST_FILE" ] && [ -s "$NODE_LIST_FILE" ]; then
        echo "Node terdaftar:"
        local i=1
        while read -r node_id; do
            local container_name="${CONTAINER_PREFIX}-$node_id"
            local status="Tidak Aktif"
            if podman ps | grep -q "$container_name"; then
                status="Aktif"
            fi
            echo "$i. Node ID: $node_id - Container: $container_name - Status: $status"
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
                local container_name="${CONTAINER_PREFIX}-$node_id"
                if podman ps | grep -q "$container_name"; then
                    active_nodes=$((active_nodes+1))
                fi
            done < "$NODE_LIST_FILE"
        fi
        
        echo -e "${CYAN}Node Aktif: ${GREEN}$active_nodes${RESET}/${YELLOW}$total_nodes${RESET} | Container Engine: ${MAGENTA}Podman${RESET}"
        echo ""
        
        echo -e "${GREEN} 1.${RESET} ➕ Instal & Jalankan Node Baru"
        echo -e "${GREEN} 2.${RESET} 📊 Lihat Status Node"
        echo -e "${GREEN} 3.${RESET} 🧾 Lihat Log Node"
        echo -e "${GREEN} 4.${RESET} ⏹️  Hentikan Node"
        echo -e "${GREEN} 5.${RESET} 💥 Hapus Node"
        echo -e "${GREEN} 6.${RESET} 🧹 Cleanup Containers"
        echo -e "${GREEN} 7.${RESET} ℹ️  Informasi Sistem"
        echo -e "${GREEN} 8.${RESET} 🚪 Keluar"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        read -rp "Pilih menu (1-8): " pilihan
        
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
                
                # Install dependencies
                install_dependencies
                
                # Buat direktori
                create_directories
                
                # Buat Dockerfile
                create_nexus_dockerfile
                
                # Build image
                build_nexus_image
                
                # Buat script runner
                create_runner_script
                
                # Jalankan Nexus node
                read -rp "Masukkan NODE_ID: " NODE_ID
                [ -z "$NODE_ID" ] && echo "NODE_ID tidak boleh kosong." && read -p "Tekan enter..." && continue
                run_nexus_node "$NODE_ID"
                
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
                cleanup_containers
                ;;
            7)
                show_system_info
                ;;
            8) 
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
show_header
detect_environment

# Buat direktori script jika belum ada
mkdir -p "$SCRIPT_DIR"
mkdir -p "$LOG_DIR"

# Jalankan menu utama
main_menu
