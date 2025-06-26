#!/bin/bash
set -e

# === Konfigurasi dasar ===
BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/workspace/nexus_logs"
WORKSPACE_DIR="/workspace"
CPU_ASSIGNMENT_FILE="/workspace/nexus_cpu_assignments.txt"
CORES_PER_NODE=3
MEMORY_PER_NODE="6G"

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
    echo -e "                           NEXUS - Node (Quickpod Previlege Edition)"
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
    
    # Deteksi apakah Docker tersedia
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}[✓] Docker terdeteksi${RESET}"
        DOCKER_AVAILABLE=true
        DOCKER_VERSION=$(docker --version | cut -d ' ' -f3 | sed 's/,//')
        echo -e "${GREEN}[✓] Versi Docker: $DOCKER_VERSION${RESET}"
    else
        echo -e "${YELLOW}[!] Docker tidak terdeteksi${RESET}"
        DOCKER_AVAILABLE=false
    fi
    
    # Deteksi apakah kita berada di dalam container
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo -e "${GREEN}[✓] Terdeteksi berjalan di dalam container Docker${RESET}"
        IN_CONTAINER=true
    else
        echo -e "${YELLOW}[!] Tidak terdeteksi berjalan di dalam container Docker${RESET}"
        IN_CONTAINER=false
    fi
    
    # Deteksi apakah kita memiliki akses privileged
    if docker info 2>/dev/null | grep -q "Security Options.*privileged"; then
        echo -e "${GREEN}[✓] Container memiliki akses privileged${RESET}"
        IS_PRIVILEGED=true
    else
        echo -e "${YELLOW}[!] Container tidak terdeteksi memiliki akses privileged${RESET}"
        IS_PRIVILEGED=false
    fi
    
    # Deteksi apakah systemd tersedia sebagai init system
    if ps -p 1 -o comm= | grep -q "systemd"; then
        echo -e "${GREEN}[✓] Systemd terdeteksi sebagai init system${RESET}"
        SYSTEMD_AVAILABLE=true
    else
        echo -e "${YELLOW}[!] Systemd tidak terdeteksi sebagai init system${RESET}"
        SYSTEMD_AVAILABLE=false
    fi
    
    echo -e "${CYAN}[*] Deteksi lingkungan selesai${RESET}"
    echo ""
}

# === Periksa dan Install Docker ===
function install_docker() {
    echo -e "${CYAN}[*] Memeriksa dan menginstal Docker...${RESET}"
    
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}[✓] Docker sudah terinstal${RESET}"
    else
        echo -e "${YELLOW}[!] Docker tidak ditemukan. Menginstal Docker...${RESET}"
        
        # Update package index
        apt update
        
        # Install prerequisites
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        
        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        
        # Set up the stable repository
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        
        # Update package index again
        apt update
        
        # Install Docker CE
        apt install -y docker-ce docker-ce-cli containerd.io
        
        # Start Docker service based on available init system
        if [ "$SYSTEMD_AVAILABLE" = true ]; then
            echo -e "${GREEN}[✓] Menggunakan systemd untuk mengelola layanan Docker${RESET}"
            systemctl enable docker || true
            systemctl start docker || true
        else
            echo -e "${YELLOW}[!] Systemd tidak tersedia, mencoba metode alternatif${RESET}"
            # Alternatif untuk lingkungan tanpa systemd
            if [ -f /etc/init.d/docker ]; then
                /etc/init.d/docker start || true
            else
                # Jika tidak ada init script, coba jalankan dockerd secara langsung
                nohup dockerd > /var/log/dockerd.log 2>&1 &
                echo -e "${YELLOW}[!] Menjalankan dockerd secara langsung di background${RESET}"
                sleep 5 # Beri waktu untuk dockerd startup
            fi
        fi
        
        # Verifikasi Docker berjalan
        if docker info >/dev/null 2>&1; then
            echo -e "${GREEN}[✓] Docker berhasil diinstal dan berjalan${RESET}"
        else
            echo -e "${RED}[!] Docker terinstal tetapi tidak berjalan. Coba jalankan manual: 'dockerd &'${RESET}"
        fi
    fi
    
    # Install Docker Compose if not already installed
    if ! command -v docker-compose >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] Docker Compose tidak ditemukan. Menginstal Docker Compose...${RESET}"
        
        # Install Docker Compose
        curl -L "https://github.com/docker/compose/releases/download/v2.20.3/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        
        echo -e "${GREEN}[✓] Docker Compose berhasil diinstal${RESET}"
    else
        echo -e "${GREEN}[✓] Docker Compose sudah terinstal${RESET}"
    fi
    
    echo -e "${CYAN}[*] Pemeriksaan dan instalasi Docker selesai${RESET}"
    echo ""
}

# === Solusi 1: Nested Container dengan Ubuntu 24.04 ===
function setup_nested_container() {
    echo -e "${CYAN}[*] Menyiapkan nested container dengan Ubuntu 24.04...${RESET}"
    
    # Buat direktori untuk menyimpan Dockerfile dan file konfigurasi
    TEMP_DIR="${WORKSPACE_DIR}/nexus-setup-temp"
    mkdir -p "$TEMP_DIR"
    
    # Buat Dockerfile untuk container Ubuntu 24.04
    cat > "${TEMP_DIR}/Dockerfile" <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

# Install dependencies
RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    bash \\
    ca-certificates \\
    && rm -rf /var/lib/apt/lists/*

# Install Nexus CLI
RUN curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh \\
    && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF
    
    # Buat entrypoint script
    cat > "${TEMP_DIR}/entrypoint.sh" <<EOF
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"

if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID belum disetel"
    exit 1
fi

echo "\$NODE_ID" > "\$PROVER_ID_FILE"

# Cek dan matikan screen yang mungkin masih berjalan
screen -S nexus -X quit >/dev/null 2>&1 || true

# Jalankan nexus-network di dalam screen
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"

# Tunggu sebentar untuk memastikan screen sudah berjalan
sleep 3

# Cek apakah screen berhasil dijalankan
if screen -list | grep -q "nexus"; then
    echo "Node berjalan di latar belakang"
else
    echo "Gagal menjalankan node"
    cat /root/nexus.log
    exit 1
fi

# Tampilkan log secara real-time
tail -f /root/nexus.log
EOF
    
    # Build Docker image
    echo -e "${CYAN}[*] Building Docker image untuk Ubuntu 24.04...${RESET}"
    docker build -t "$IMAGE_NAME" "${TEMP_DIR}"
    
    echo -e "${GREEN}[✓] Docker image berhasil dibuild${RESET}"
    echo ""
}

# === Solusi 2: Instalasi Langsung di Ubuntu 24.04 ===
function setup_direct_installation() {
    echo -e "${CYAN}[*] Menyiapkan instalasi langsung di Ubuntu 24.04...${RESET}"
    
    # Update package index
    apt update
    
    # Install dependencies
    apt install -y curl screen build-essential pkg-config libssl-dev git-all
    
    # Install Nexus CLI
    curl -sSL https://cli.nexus.xyz/ | sh
    
    # Buat direktori untuk script dan log
    mkdir -p /root/nexus-scripts
    mkdir -p /root/nexus-logs
    
    # Buat script untuk menjalankan Nexus
    cat > /root/nexus-scripts/run-nexus.sh <<EOF
#!/bin/bash
NODE_ID=\$(cat /root/.nexus/node-id)
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID tidak ditemukan di /root/.nexus/node-id"
    exit 1
fi

# Matikan screen yang mungkin masih berjalan
screen -S nexus -X quit >/dev/null 2>&1 || true

# Jalankan nexus-network di dalam screen
screen -dmS nexus bash -c "/root/.nexus/bin/nexus-network start --node-id \$NODE_ID &>> /root/nexus-logs/nexus.log"

# Cek apakah screen berhasil dijalankan
if screen -list | grep -q "nexus"; then
    echo "Node berjalan di latar belakang"
else
    echo "Gagal menjalankan node"
    cat /root/nexus-logs/nexus.log
    exit 1
fi

echo "Nexus node berjalan dengan NODE_ID: \$NODE_ID"
echo "Log tersedia di: /root/nexus-logs/nexus.log"
EOF
    
    chmod +x /root/nexus-scripts/run-nexus.sh
    
    # Jika systemd tersedia, buat service
    if [ "$SYSTEMD_AVAILABLE" = true ]; then
        # Create systemd service for Nexus
        cat > /etc/systemd/system/nexus.service <<EOF
[Unit]
Description=Nexus Network Node
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/root/nexus-scripts/run-nexus.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        echo -e "${GREEN}[✓] Service systemd dibuat${RESET}"
    else
        echo -e "${YELLOW}[!] Systemd tidak tersedia, akan menggunakan script langsung${RESET}"
        # Buat crontab entry untuk menjalankan pada boot (jika cron tersedia)
        if command -v crontab >/dev/null 2>&1; then
            (crontab -l 2>/dev/null || echo "") | grep -v "run-nexus.sh" | { cat; echo "@reboot /root/nexus-scripts/run-nexus.sh"; } | crontab -
            echo -e "${GREEN}[✓] Crontab entry dibuat untuk menjalankan pada boot${RESET}"
        fi
    fi
    
    echo -e "${GREEN}[✓] Instalasi langsung selesai${RESET}"
    echo ""
}

# === Manajemen CPU Cores ===
function get_total_cpu_cores() {
    nproc
}

function get_assigned_cores() {
    if [ ! -f "$CPU_ASSIGNMENT_FILE" ]; then
        touch "$CPU_ASSIGNMENT_FILE"
    fi
    cat "$CPU_ASSIGNMENT_FILE"
}

function is_core_assigned() {
    local core=$1
    grep -q "^.*:.*,${core},.*$\|^.*:.*,${core}$\|^.*:${core},.*$\|^.*:${core}$" "$CPU_ASSIGNMENT_FILE"
}

function get_available_cores() {
    local total_cores=$(get_total_cpu_cores)
    local available_cores=""
    
    for ((i=0; i<total_cores; i++)); do
        if ! is_core_assigned $i; then
            available_cores="${available_cores}${i},"
        fi
    done
    
    # Hapus koma terakhir
    available_cores=${available_cores%,}
    echo "$available_cores"
}

function assign_cores_to_node() {
    local node_id=$1
    local cores=$2
    
    # Hapus assignment lama jika ada
    sed -i "/^${node_id}:/d" "$CPU_ASSIGNMENT_FILE"
    
    # Tambahkan assignment baru
    echo "${node_id}:${cores}" >> "$CPU_ASSIGNMENT_FILE"
}

function get_node_cores() {
    local node_id=$1
    grep "^${node_id}:" "$CPU_ASSIGNMENT_FILE" | cut -d':' -f2
}

function release_node_cores() {
    local node_id=$1
    sed -i "/^${node_id}:/d" "$CPU_ASSIGNMENT_FILE"
}

function select_cores_for_node() {
    local node_id=$1
    local total_cores=$(get_total_cpu_cores)
    local available_cores=$(get_available_cores)
    
    echo -e "${CYAN}=== Pilihan CPU Cores ===${RESET}"
    echo "Total CPU cores tersedia: $total_cores"
    echo "Cores yang belum digunakan: $available_cores"
    echo ""
    echo "1. Pilih cores secara manual"
    echo "2. Gunakan cores yang tersedia secara otomatis"
    read -rp "Pilihan (1/2): " core_choice
    
    if [[ "$core_choice" == "1" ]]; then
        echo "Masukkan nomor cores yang ingin digunakan (contoh: 0,1,2 atau 3-5)"
        read -rp "Cores: " manual_cores
        
        # Konversi range (e.g., 3-5) menjadi daftar (e.g., 3,4,5)
        if [[ "$manual_cores" =~ ^[0-9]+-[0-9]+$ ]]; then
            local start_core=$(echo "$manual_cores" | cut -d'-' -f1)
            local end_core=$(echo "$manual_cores" | cut -d'-' -f2)
            manual_cores=""
            for ((i=start_core; i<=end_core; i++)); do
                manual_cores="${manual_cores}${i},"
            done
            manual_cores=${manual_cores%,}
        fi
        
        # Validasi cores
        local cores_array=(${manual_cores//,/ })
        if [ ${#cores_array[@]} -ne $CORES_PER_NODE ]; then
            echo -e "${RED}Error: Harus memilih tepat $CORES_PER_NODE cores.${RESET}"
            return 1
        fi
        
        # Periksa apakah cores sudah digunakan
        local invalid_cores=0
        for core in ${cores_array[@]}; do
            if is_core_assigned $core; then
                echo -e "${RED}Error: Core $core sudah digunakan oleh node lain.${RESET}"
                invalid_cores=1
            fi
            
            if [ "$core" -ge "$total_cores" ]; then
                echo -e "${RED}Error: Core $core tidak valid. Total cores: $total_cores.${RESET}"
                invalid_cores=1
            fi
        done
        
        if [ $invalid_cores -eq 1 ]; then
            return 1
        fi
        
        assign_cores_to_node "$node_id" "$manual_cores"
        echo -e "${GREEN}[✓] Berhasil menetapkan cores $manual_cores ke node $node_id.${RESET}"
        return 0
    else
        # Pilih cores otomatis
        local cores_array=(${available_cores//,/ })
        if [ ${#cores_array[@]} -lt $CORES_PER_NODE ]; then
            echo -e "${RED}Error: Tidak cukup cores tersedia. Dibutuhkan $CORES_PER_NODE cores.${RESET}"
            return 1
        fi
        
        local auto_cores=""
        for ((i=0; i<CORES_PER_NODE; i++)); do
            auto_cores="${auto_cores}${cores_array[$i]},"
        done
        auto_cores=${auto_cores%,}
        
        assign_cores_to_node "$node_id" "$auto_cores"
        echo -e "${GREEN}[✓] Berhasil menetapkan cores $auto_cores ke node $node_id secara otomatis.${RESET}"
        return 0
    fi
}

# === Jalankan Container ===
function run_container() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"
    
    echo -e "${CYAN}[*] Menjalankan container untuk node ID: ${node_id}...${RESET}"
    
    # Hapus container lama jika ada
    docker rm -f "$container_name" 2>/dev/null || true
    
    # Buat direktori log jika belum ada
    mkdir -p "$LOG_DIR"
    touch "$log_file"
    chmod 644 "$log_file"
    
    # Pilih CPU cores untuk node
    echo -e "${CYAN}[*] Menetapkan CPU cores untuk node...${RESET}"
    if ! select_cores_for_node "$node_id"; then
        echo -e "${RED}[!] Gagal menetapkan CPU cores. Node tidak dijalankan.${RESET}"
        return 1
    fi
    
    local node_cores=$(get_node_cores "$node_id")
    
    # Jalankan container dengan alokasi CPU cores dan memory spesifik
    echo -e "${CYAN}[*] Menjalankan container dengan CPU cores: $node_cores dan memory: $MEMORY_PER_NODE${RESET}"
    docker run -d --name "$container_name" \
        --cpuset-cpus="$node_cores" \
        --memory="$MEMORY_PER_NODE" \
        -v "$log_file":/root/nexus.log \
        -e NODE_ID="$node_id" \
        "$IMAGE_NAME"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[!] Gagal menjalankan container. Melepaskan CPU cores.${RESET}"
        release_node_cores "$node_id"
        return 1
    fi
    
    echo -e "${GREEN}[✓] Container berhasil dijalankan${RESET}"
    echo -e "${GREEN}[✓] Log tersedia di: ${log_file}${RESET}"
    echo -e "${GREEN}[✓] CPU cores yang digunakan: $node_cores${RESET}"
    echo ""
}

# === Jalankan Nexus Langsung ===
function run_direct() {
    local node_id=$1
    
    echo -e "${CYAN}[*] Menjalankan Nexus langsung untuk node ID: ${node_id}...${RESET}"
    
    # Set node ID
    echo "$node_id" > /root/.nexus/node-id
    
    if [ "$SYSTEMD_AVAILABLE" = true ]; then
        # Set environment variable for systemd service
        echo "NODE_ID=$node_id" > /etc/default/nexus
        
        # Reload systemd
        systemctl daemon-reload
        
        # Enable and start service
        systemctl enable nexus
        systemctl restart nexus
        
        echo -e "${GREEN}[✓] Nexus berhasil dijalankan sebagai service systemd${RESET}"
        echo -e "${GREEN}[✓] Log tersedia melalui: journalctl -u nexus -f${RESET}"
    else
        # Jalankan script langsung
        /root/nexus-scripts/run-nexus.sh
        
        echo -e "${GREEN}[✓] Nexus berhasil dijalankan menggunakan screen${RESET}"
        echo -e "${GREEN}[✓] Log tersedia di: /root/nexus-logs/nexus.log${RESET}"
        echo -e "${GREEN}[✓] Untuk melihat screen: screen -r nexus${RESET}"
    fi
    
    echo ""
}

# === Hapus Node ===
function uninstall_node() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    
    echo -e "${CYAN}[*] Menghapus node ID: ${node_id}...${RESET}"
    
    if [ "$SOLUTION_TYPE" == "nested" ]; then
        # Hapus container
        docker rm -f "$container_name" 2>/dev/null || true
        
        # Hapus file log
        rm -f "${LOG_DIR}/nexus-${node_id}.log"
        
        # Lepaskan CPU cores
        echo -e "${CYAN}[*] Melepaskan CPU cores untuk node: $node_id${RESET}"
        release_node_cores "$node_id"
    else
        # Matikan screen yang mungkin masih berjalan
        screen -S nexus -X quit >/dev/null 2>&1 || true
        
        if [ "$SYSTEMD_AVAILABLE" = true ]; then
            # Stop and disable service
            systemctl stop nexus 2>/dev/null || true
            systemctl disable nexus 2>/dev/null || true
            
            # Remove service file
            rm -f /etc/systemd/system/nexus.service
            rm -f /etc/default/nexus
            
            # Reload systemd
            systemctl daemon-reload 2>/dev/null || true
        else
            # Hapus crontab entry jika ada
            if command -v crontab >/dev/null 2>&1; then
                (crontab -l 2>/dev/null || echo "") | grep -v "run-nexus.sh" | crontab -
            fi
            
            # Matikan proses nexus-network jika masih berjalan
            pkill -f "nexus-network" 2>/dev/null || true
        fi
        
        # Hapus script dan log
        rm -f /root/nexus-scripts/run-nexus.sh
        rm -f /root/nexus-logs/nexus.log
    fi
    
    echo -e "${GREEN}[✓] Node berhasil dihapus${RESET}"
    echo ""
}

# === Ambil Semua Node ===
function get_all_nodes() {
    if [ "$SOLUTION_TYPE" == "nested" ]; then
        docker ps -a --format "{{.Names}}" | grep "^${BASE_CONTAINER_NAME}-" | sed "s/${BASE_CONTAINER_NAME}-//"
    else
        if [ -f /root/.nexus/node-id ]; then
            cat /root/.nexus/node-id
        fi
    fi
}

# === Tampilkan Semua Node ===
function list_nodes() {
    show_header
    echo -e "${CYAN}📊 Daftar Node Terdaftar:${RESET}"
    echo "--------------------------------------------------------------"
    
    if [ "$SOLUTION_TYPE" == "nested" ]; then
        printf "%-5s %-20s %-12s %-15s %-15s %-15s %-15s\n" "No" "Node ID" "Status" "CPU" "Memori" "Batas Memori" "CPU Cores"
        echo "-----------------------------------------------------------------------------------------"
        
        local all_nodes=($(get_all_nodes))
        local failed_nodes=()
        
        for i in "${!all_nodes[@]}"; do
            local node_id=${all_nodes[$i]}
            local container="${BASE_CONTAINER_NAME}-${node_id}"
            local cpu="N/A"
            local mem="N/A"
            local status="Tidak Aktif"
            local cpu_cores=$(get_node_cores "$node_id")
            if [ -z "$cpu_cores" ]; then
                cpu_cores="N/A"
            fi
            
            if docker inspect "$container" &>/dev/null; then
                status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
                
                if [[ "$status" == "running" ]]; then
                    stats=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" "$container" 2>/dev/null)
                    cpu=$(echo "$stats" | cut -d'|' -f1)
                    mem=$(echo "$stats" | cut -d'|' -f2 | cut -d'/' -f1 | xargs)
                elif [[ "$status" == "exited" ]]; then
                    failed_nodes+=("$node_id")
                fi
            fi
            
            printf "%-5s %-20s %-12s %-15s %-15s %-15s %-15s\n" "$((i+1))" "$node_id" "$status" "$cpu" "$mem" "$MEMORY_PER_NODE" "$cpu_cores"
        done
        
        echo "-----------------------------------------------------------------------------------------"
        
        if [ ${#failed_nodes[@]} -gt 0 ]; then
            echo -e "${RED}⚠ Node gagal dijalankan (exited):${RESET}"
            
            for id in "${failed_nodes[@]}"; do
                echo "- $id"
            done
        fi
    else
        printf "%-5s %-20s %-12s\n" "No" "Node ID" "Status"
        echo "--------------------------------------------------------------"
        
        if [ -f /root/.nexus/node-id ]; then
            local node_id=$(cat /root/.nexus/node-id)
            local status="Tidak Aktif"
            
            if systemctl is-active --quiet nexus; then
                status="Aktif"
            fi
            
            printf "%-5s %-20s %-12s\n" "1" "$node_id" "$status"
        else
            echo "Tidak ada node yang terdaftar"
        fi
        
        echo "--------------------------------------------------------------"
    fi
    
    read -p "Tekan enter untuk kembali ke menu..."
}

# === Lihat Log Node ===
function view_logs() {
    if [ "$SOLUTION_TYPE" == "nested" ]; then
        local all_nodes=($(get_all_nodes))
        
        if [ ${#all_nodes[@]} -eq 0 ]; then
            echo "Tidak ada node"
            read -p "Tekan enter..."
            return
        fi
        
        echo "Pilih node untuk lihat log:"
        
        for i in "${!all_nodes[@]}"; do
            echo "$((i+1)). ${all_nodes[$i]}"
        done
        
        read -rp "Nomor: " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice > 0 && choice <= ${#all_nodes[@]} )); then
            local selected=${all_nodes[$((choice-1))]}
            echo -e "${YELLOW}Menampilkan log node: $selected${RESET}"
            docker logs -f "${BASE_CONTAINER_NAME}-${selected}"
        fi
    else
        if [ "$SYSTEMD_AVAILABLE" = true ]; then
            echo -e "${YELLOW}Menampilkan log Nexus dari systemd...${RESET}"
            journalctl -u nexus -f
        else
            echo -e "${YELLOW}Menampilkan log Nexus dari file...${RESET}"
            if [ -f /root/nexus-logs/nexus.log ]; then
                tail -f /root/nexus-logs/nexus.log
            else
                echo -e "${RED}[!] File log tidak ditemukan${RESET}"
            fi
        fi
    fi
    
    read -p "Tekan enter..."
}

# === Hapus Beberapa Node ===
function batch_uninstall_nodes() {
    if [ "$SOLUTION_TYPE" == "nested" ]; then
        local all_nodes=($(get_all_nodes))
        
        echo "Masukkan nomor node yang ingin dihapus (pisahkan spasi):"
        
        for i in "${!all_nodes[@]}"; do
            echo "$((i+1)). ${all_nodes[$i]}"
        done
        
        read -rp "Nomor: " input
        
        for num in $input; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num > 0 && num <= ${#all_nodes[@]} )); then
                uninstall_node "${all_nodes[$((num-1))]}"
            else
                echo "Lewati: $num"
            fi
        done
    else
        echo "Fitur ini hanya tersedia untuk solusi nested container"
    fi
    
    read -p "Tekan enter..."
}

# === Hapus Semua Node ===
function uninstall_all_nodes() {
    if [ "$SOLUTION_TYPE" == "nested" ]; then
        local all_nodes=($(get_all_nodes))
        
        echo "Yakin ingin hapus SEMUA node? (y/n)"
        read -rp "Konfirmasi: " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            for node in "${all_nodes[@]}"; do
                uninstall_node "$node"
            done
            
            echo "Semua node dihapus."
        else
            echo "Dibatalkan."
        fi
    else
        echo "Yakin ingin hapus node? (y/n)"
        read -rp "Konfirmasi: " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            uninstall_node "$(cat /root/.nexus/node-id)"
            echo "Node dihapus."
        else
            echo "Dibatalkan."
        fi
    fi
    
    read -p "Tekan enter..."
}

# === Pilih Solusi ===
function choose_solution() {
    show_header
    echo -e "${CYAN}Pilih solusi untuk menjalankan Nexus Network:${RESET}"
    echo ""
    echo -e "${GREEN}1.${RESET} Nested Container (Ubuntu 24.04 di dalam container saat ini)"
    echo -e "   ${YELLOW}✓ Cocok untuk Ubuntu 22.04 dengan Docker${RESET}"
    echo -e "   ${YELLOW}✓ Tidak perlu mengubah template VPS${RESET}"
    echo -e "   ${YELLOW}✓ Memanfaatkan Docker-in-Docker${RESET}"
    echo ""
    echo -e "${GREEN}2.${RESET} Instalasi Langsung (untuk Ubuntu 24.04)"
    echo -e "   ${YELLOW}✓ Lebih sederhana, tanpa nested container${RESET}"
    echo -e "   ${YELLOW}✓ Performa potensial lebih baik${RESET}"
    echo -e "   ${YELLOW}✓ Memerlukan Ubuntu 24.04${RESET}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    read -rp "Pilih solusi (1-2): " solution_choice
    
    case $solution_choice in
        1)
            SOLUTION_TYPE="nested"
            echo -e "${GREEN}[✓] Anda memilih Solusi Nested Container${RESET}"
            ;;
        2)
            SOLUTION_TYPE="direct"
            echo -e "${GREEN}[✓] Anda memilih Solusi Instalasi Langsung${RESET}"
            ;;
        *)
            echo -e "${RED}[!] Pilihan tidak valid. Menggunakan Solusi Nested Container secara default${RESET}"
            SOLUTION_TYPE="nested"
            ;;
    esac
    
    # Simpan pilihan solusi
    echo "$SOLUTION_TYPE" > "${WORKSPACE_DIR}/.nexus_solution_type"
    
    echo ""
    read -p "Tekan enter untuk melanjutkan..."
}

# === Load Solusi yang Tersimpan ===
function load_saved_solution() {
    if [ -f "${WORKSPACE_DIR}/.nexus_solution_type" ]; then
        SOLUTION_TYPE=$(cat "${WORKSPACE_DIR}/.nexus_solution_type")
        echo -e "${GREEN}[✓] Memuat solusi tersimpan: $SOLUTION_TYPE${RESET}"
    else
        # Default ke nested jika belum ada pilihan tersimpan
        SOLUTION_TYPE="nested"
    fi
}

# === MENU UTAMA ===
function main_menu() {
    while true; do
        show_header
        echo -e "${CYAN}Solusi Aktif: ${YELLOW}$SOLUTION_TYPE${RESET}"
        echo ""
        echo -e "${GREEN} 1.${RESET} ➕ Instal & Jalankan Node"
        echo -e "${GREEN} 2.${RESET} 📊 Lihat Status Semua Node"
        echo -e "${GREEN} 3.${RESET} ❌ Hapus Node Tertentu"
        echo -e "${GREEN} 4.${RESET} 🧾 Lihat Log Node"
        echo -e "${GREEN} 5.${RESET} 💥 Hapus Semua Node"
        echo -e "${GREEN} 6.${RESET} 🔄 Ganti Solusi"
        echo -e "${GREEN} 7.${RESET} ℹ️  Informasi Sistem"
        echo -e "${GREEN} 8.${RESET} 🚪 Keluar"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        read -rp "Pilih menu (1-8): " pilihan
        
        case $pilihan in
            1)
                if [ "$SOLUTION_TYPE" == "nested" ]; then
                    # Periksa Docker
                    if ! command -v docker &> /dev/null; then
                        echo -e "${RED}[!] Docker tidak terinstal. Menginstal Docker...${RESET}"
                        install_docker
                    fi
                    
                    # Setup nested container
                    setup_nested_container
                    
                    # Jalankan container
                    read -rp "Masukkan NODE_ID: " NODE_ID
                    [ -z "$NODE_ID" ] && echo "NODE_ID tidak boleh kosong." && read -p "Tekan enter..." && continue
                    run_container "$NODE_ID"
                else
                    # Setup direct installation
                    setup_direct_installation
                    
                    # Jalankan Nexus langsung
                    read -rp "Masukkan NODE_ID: " NODE_ID
                    [ -z "$NODE_ID" ] && echo "NODE_ID tidak boleh kosong." && read -p "Tekan enter..." && continue
                    run_direct "$NODE_ID"
                fi
                
                read -p "Tekan enter..."
                ;;
            2) 
                list_nodes 
                ;;
            3) 
                batch_uninstall_nodes 
                ;;
            4) 
                view_logs 
                ;;
            5) 
                uninstall_all_nodes 
                ;;
            6) 
                choose_solution 
                ;;
            7)
                show_header
                echo -e "${CYAN}ℹ️  Informasi Sistem:${RESET}"
                echo "--------------------------------------------------------------"
                echo -e "${GREEN}Versi Ubuntu:${RESET} $UBUNTU_VERSION"
                echo -e "${GREEN}Versi GLIBC:${RESET} $GLIBC_VERSION"
                
                if [ "$DOCKER_AVAILABLE" == "true" ]; then
                    echo -e "${GREEN}Docker:${RESET} Terinstal (Versi $DOCKER_VERSION)"
                else
                    echo -e "${RED}Docker:${RESET} Tidak terinstal"
                fi
                
                if [ "$IN_CONTAINER" == "true" ]; then
                    echo -e "${GREEN}Container:${RESET} Berjalan di dalam container"
                else
                    echo -e "${GREEN}Container:${RESET} Berjalan di host"
                fi
                
                if [ "$IS_PRIVILEGED" == "true" ]; then
                    echo -e "${GREEN}Privileged:${RESET} Ya"
                else
                    echo -e "${RED}Privileged:${RESET} Tidak"
                fi
                
                echo -e "${GREEN}Solusi Aktif:${RESET} $SOLUTION_TYPE"
                echo "--------------------------------------------------------------"
                
                read -p "Tekan enter untuk kembali ke menu..."
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
load_saved_solution

# Jika belum ada solusi yang dipilih, minta pengguna memilih
if [ -z "$SOLUTION_TYPE" ]; then
    choose_solution
fi

# Jalankan menu utama
main_menu
