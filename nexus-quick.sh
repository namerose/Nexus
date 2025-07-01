#!/bin/bash
set -e

# === Konfigurasi dasar ===
BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/workspace/nexus_logs"
WORKSPACE_DIR="/workspace"
REFRESH_INTERVAL_MINUTES=10  # Interval restart otomatis
AUTO_REFRESH_ENABLED=false   # Status auto-refresh

# === Warna terminal ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

# === Ambil Versi CLI ===
function get_cli_version() {
    local version="Unknown"
    if command -v curl >/dev/null 2>&1; then
        version=$(curl -s "https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest" 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4)
        if [ -z "$version" ]; then
            version="Unknown"
        fi
    fi
    echo "$version"
}

# === Header Tampilan ===
function show_header() {
    clear
    local cli_version=$(get_cli_version)
    local auto_refresh_status="${RED}OFF${RESET}"
    
    # Cek apakah auto-refresh aktif berdasarkan variabel status
    if [ "$AUTO_REFRESH_ENABLED" = true ]; then
        auto_refresh_status="${GREEN}ON${RESET} (Setiap ${REFRESH_INTERVAL_MINUTES} menit)"
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "                           NEXUS - Node (Quickpod Previlege Edition)"
    echo -e "                           Latest CLI Version: ${cli_version}"
    echo -e "                           Auto-refresh: ${auto_refresh_status}"
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
    echo -e "${RED}[!] Solusi instalasi langsung telah dihapus.${RESET}"
    echo -e "${YELLOW}[!] Silakan gunakan solusi Nested Container (opsi 1).${RESET}"
    echo ""
    
    # Set solution type back to nested
    SOLUTION_TYPE="nested"
    echo "$SOLUTION_TYPE" > "${WORKSPACE_DIR}/.nexus_solution_type"
    
    read -p "Tekan enter untuk kembali ke menu utama..."
    return
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
    
    # Jalankan container
    docker run -d --name "$container_name" \
        -v "$log_file":/root/nexus.log \
        -e NODE_ID="$node_id" \
        "$IMAGE_NAME"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[!] Gagal menjalankan container.${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}[✓] Container berhasil dijalankan${RESET}"
    echo -e "${GREEN}[✓] Log tersedia di: ${log_file}${RESET}"
    echo ""
}

# === Jalankan Nexus Langsung ===
function run_direct() {
    local node_id=$1
    
    echo -e "${RED}[!] Solusi instalasi langsung telah dihapus.${RESET}"
    echo -e "${YELLOW}[!] Silakan gunakan solusi Nested Container (opsi 1).${RESET}"
    echo ""
    
    # Set solution type back to nested
    SOLUTION_TYPE="nested"
    echo "$SOLUTION_TYPE" > "${WORKSPACE_DIR}/.nexus_solution_type"
    
    read -p "Tekan enter untuk kembali ke menu utama..."
    return
}

# === Hapus Node ===
function uninstall_node() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    
    echo -e "${CYAN}[*] Menghapus node ID: ${node_id}...${RESET}"
    
    # Hapus container
    docker rm -f "$container_name" 2>/dev/null || true
    
    # Hapus file log
    rm -f "${LOG_DIR}/nexus-${node_id}.log"
    
    echo -e "${GREEN}[✓] Node berhasil dihapus${RESET}"
    echo ""
}

# === Ambil Semua Node ===
function get_all_nodes() {
    docker ps -a --format "{{.Names}}" | grep "^${BASE_CONTAINER_NAME}-" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# === Tampilkan Semua Node ===
function list_nodes() {
    show_header
    echo -e "${CYAN}📊 Daftar Node Terdaftar:${RESET}"
    echo "--------------------------------------------------------------"
    
    printf "%-5s %-20s %-12s %-15s %-15s\n" "No" "Node ID" "Status" "CPU" "Memori"
    echo "--------------------------------------------------------------"
    
    local all_nodes=($(get_all_nodes))
    local failed_nodes=()
    
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container="${BASE_CONTAINER_NAME}-${node_id}"
        local cpu="N/A"
        local mem="N/A"
        local status="Tidak Aktif"
        
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
        
        printf "%-5s %-20s %-12s %-15s %-15s\n" "$((i+1))" "$node_id" "$status" "$cpu" "$mem"
    done
    
    echo "--------------------------------------------------------------"
    
    if [ ${#failed_nodes[@]} -gt 0 ]; then
        echo -e "${RED}⚠ Node gagal dijalankan (exited):${RESET}"
        
        for id in "${failed_nodes[@]}"; do
            echo "- $id"
        done
    fi
    
    read -p "Tekan enter untuk kembali ke menu..."
}

# === Lihat Log Node ===
function view_logs() {
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
    
    read -p "Tekan enter..."
}

# === Hapus Beberapa Node ===
function batch_uninstall_nodes() {
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
    
    read -p "Tekan enter..."
}

# === Hapus Semua Node ===
function uninstall_all_nodes() {
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
    
    read -p "Tekan enter..."
}

# === Inisialisasi Solusi ===
function initialize_solution() {
    # Selalu gunakan nested container
    SOLUTION_TYPE="nested"
    echo "$SOLUTION_TYPE" > "${WORKSPACE_DIR}/.nexus_solution_type"
}

# === Fungsi restart semua node ===
function restart_all_nodes() {
    local all_nodes=($(get_all_nodes))
    echo -e "${CYAN}♻  Memulai restart otomatis semua node...${RESET}"
    
    for node_id in "${all_nodes[@]}"; do
        local container="${BASE_CONTAINER_NAME}-${node_id}"
        echo -e "${YELLOW}🔄 Restarting node ${node_id}...${RESET}"
        docker restart "$container" >/dev/null 2>&1
    done
    
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

# === Cleanup System Penuh ===
function full_system_cleanup() {
    echo -e "${YELLOW}⚠️  PERINGATAN: Ini akan membersihkan SELURUH SISTEM secara menyeluruh!${RESET}"
    echo -e "${RED}Semua container, image, volume, dan network Docker akan dihapus!${RESET}"
    echo -e "${RED}Semua proses zombie dan proses yang tidak perlu akan dihentikan!${RESET}"
    echo -e "${RED}RAM dan cache sistem akan dibersihkan!${RESET}"
    echo -e "${RED}Semua log dan file temporary akan dihapus!${RESET}"
    echo ""
    echo "Apakah Anda yakin ingin melanjutkan? (ketik 'YES' untuk konfirmasi)"
    read -rp "Konfirmasi: " confirm
    
    if [[ "$confirm" == "YES" ]]; then
        echo -e "${CYAN}🧹 Memulai pembersihan sistem penuh dan menyeluruh...${RESET}"
        
        # 1. Tampilkan status sistem sebelum cleanup
        echo -e "${YELLOW}1. Status sistem sebelum pembersihan:${RESET}"
        echo "RAM Usage: $(free -h | awk '/^Mem:/ {print $3"/"$2}')"
        echo "Disk Usage: $(df -h / | awk 'NR==2 {print $3"/"$2" ("$5")"}')"
        echo "Running Processes: $(ps aux | wc -l)"
        echo "Zombie Processes: $(ps aux | awk '$8 ~ /^Z/ { count++ } END { print count+0 }')"
        
        # 2. Kill semua proses yang tidak perlu dan zombie processes
        echo -e "${YELLOW}2. Menghentikan proses zombie dan proses tidak perlu...${RESET}"
        # Kill zombie processes
        ps aux | awk '$8 ~ /^Z/ { print $2 }' | xargs -r kill -9 2>/dev/null || true
        # Kill high CPU/memory processes (except essential ones)
        ps aux --sort=-%cpu | awk 'NR>1 && $3>50 && $11!~/systemd|kernel|init|ssh|bash|docker/ {print $2}' | head -10 | xargs -r kill -15 2>/dev/null || true
        ps aux --sort=-%mem | awk 'NR>1 && $4>20 && $11!~/systemd|kernel|init|ssh|bash|docker/ {print $2}' | head -10 | xargs -r kill -15 2>/dev/null || true
        
        # 3. Stop dan hapus semua container Nexus
        echo -e "${YELLOW}3. Menghentikan semua container Nexus...${RESET}"
        if [ "$SOLUTION_TYPE" == "nested" ]; then
            docker ps -a --format "{{.Names}}" | grep "^${BASE_CONTAINER_NAME}-" | xargs -r docker rm -f
        else
            if [ "$SYSTEMD_AVAILABLE" = true ]; then
                systemctl stop nexus 2>/dev/null || true
            else
                screen -S nexus -X quit >/dev/null 2>&1 || true
                pkill -f "nexus-network" 2>/dev/null || true
            fi
        fi
        
        # 4. Stop semua container Docker yang berjalan
        echo -e "${YELLOW}4. Menghentikan semua container Docker...${RESET}"
        if command -v docker &>/dev/null; then
            docker stop $(docker ps -q) 2>/dev/null || true
        fi
        
        # 5. Hapus semua container Docker
        echo -e "${YELLOW}5. Menghapus semua container Docker...${RESET}"
        if command -v docker &>/dev/null; then
            docker container prune -f
            docker rm -f $(docker ps -aq) 2>/dev/null || true
        fi
        
        # 6. Hapus semua image Docker
        echo -e "${YELLOW}6. Menghapus semua image Docker...${RESET}"
        if command -v docker &>/dev/null; then
            docker image prune -a -f
            docker rmi -f $(docker images -q) 2>/dev/null || true
        fi
        
        # 7. Hapus semua volume Docker
        echo -e "${YELLOW}7. Menghapus semua volume Docker...${RESET}"
        if command -v docker &>/dev/null; then
            docker volume prune -f
            docker volume rm $(docker volume ls -q) 2>/dev/null || true
        fi
        
        # 8. Hapus semua network Docker
        echo -e "${YELLOW}8. Menghapus semua network Docker...${RESET}"
        if command -v docker &>/dev/null; then
            docker network prune -f
        fi
        
        # 9. Hapus build cache Docker
        echo -e "${YELLOW}9. Menghapus build cache Docker...${RESET}"
        if command -v docker &>/dev/null; then
            docker builder prune -a -f
        fi
        
        # 10. Hapus system Docker secara menyeluruh
        echo -e "${YELLOW}10. Pembersihan sistem Docker menyeluruh...${RESET}"
        if command -v docker &>/dev/null; then
            docker system prune -a -f --volumes
        fi
        
        # 11. Bersihkan RAM dan cache sistem
        echo -e "${YELLOW}11. Membersihkan RAM dan cache sistem...${RESET}"
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        sysctl -w vm.drop_caches=3 2>/dev/null || true
        
        # 12. Hapus semua log Nexus
        echo -e "${YELLOW}12. Menghapus semua log Nexus...${RESET}"
        rm -rf "$LOG_DIR"
        rm -rf /root/nexus-logs
        
        # 13. Hapus semua cron job Nexus
        echo -e "${YELLOW}13. Menghapus semua cron job Nexus...${RESET}"
        rm -f /etc/cron.d/nexus-log-cleanup-*
        
        # 14. Bersihkan semua log sistem
        echo -e "${YELLOW}14. Membersihkan semua log sistem...${RESET}"
        journalctl --vacuum-time=1h 2>/dev/null || true
        > /var/log/syslog 2>/dev/null || true
        > /var/log/kern.log 2>/dev/null || true
        > /var/log/auth.log 2>/dev/null || true
        find /var/log -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
        find /var/log -name "*.log.*" -delete 2>/dev/null || true
        
        # 15. Bersihkan temporary files dan cache
        echo -e "${YELLOW}15. Membersihkan file temporary dan cache...${RESET}"
        rm -rf /tmp/* 2>/dev/null || true
        rm -rf /var/tmp/* 2>/dev/null || true
        rm -rf ~/.cache/* 2>/dev/null || true
        rm -rf /root/.cache/* 2>/dev/null || true
        rm -rf /var/cache/* 2>/dev/null || true
        
        # 16. Bersihkan package cache
        echo -e "${YELLOW}16. Membersihkan package cache...${RESET}"
        apt clean 2>/dev/null || true
        apt autoclean 2>/dev/null || true
        apt autoremove -y --purge 2>/dev/null || true
        
        # 17. Bersihkan swap jika ada
        echo -e "${YELLOW}17. Membersihkan swap...${RESET}"
        swapoff -a 2>/dev/null || true
        swapon -a 2>/dev/null || true
        
        # 18. Defragmentasi dan optimasi filesystem
        echo -e "${YELLOW}18. Optimasi filesystem...${RESET}"
        sync
        fstrim -av 2>/dev/null || true
        
        # 19. Reset network connections
        echo -e "${YELLOW}19. Reset koneksi network...${RESET}"
        systemctl restart networking 2>/dev/null || true
        systemctl restart systemd-networkd 2>/dev/null || true
        
        # 20. Restart services penting
        echo -e "${YELLOW}20. Restart services sistem...${RESET}"
        if command -v docker &>/dev/null; then
            systemctl restart docker 2>/dev/null || true
        fi
        systemctl restart cron 2>/dev/null || true
        
        # 21. Force garbage collection
        echo -e "${YELLOW}21. Force garbage collection...${RESET}"
        sync
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
        
        # 22. Tampilkan status sistem setelah cleanup
        echo -e "${GREEN}✅ Pembersihan sistem penuh selesai!${RESET}"
        echo -e "${CYAN}📊 Status sistem setelah pembersihan:${RESET}"
        echo "RAM Usage: $(free -h | awk '/^Mem:/ {print $3"/"$2}')"
        echo "Disk Usage: $(df -h / | awk 'NR==2 {print $3"/"$2" ("$5")"}')"
        echo "Running Processes: $(ps aux | wc -l)"
        echo "Zombie Processes: $(ps aux | awk '$8 ~ /^Z/ { count++ } END { print count+0 }')"
        
    else
        echo -e "${YELLOW}Pembersihan dibatalkan.${RESET}"
    fi
    read -p "Tekan enter untuk kembali ke menu..."
}

# === MENU UTAMA ===
function main_menu() {
    while true; do
        show_header
        echo ""
        echo -e "${GREEN} 1.${RESET} ➕ Instal & Jalankan Node"
        echo -e "${GREEN} 2.${RESET} 📊 Lihat Status Semua Node"
        echo -e "${GREEN} 3.${RESET} ❌ Hapus Node Tertentu"
        echo -e "${GREEN} 4.${RESET} 🧾 Lihat Log Node"
        echo -e "${GREEN} 5.${RESET} 💥 Hapus Semua Node"
        echo -e "${GREEN} 6.${RESET} 🔄 Auto-Refresh Node"
        echo -e "${GREEN} 7.${RESET} 🧹 Cleanup System Penuh"
        echo -e "${GREEN} 8.${RESET} 🚪 Keluar"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        
        read -rp "Pilih menu (1-8): " pilihan
        
        case $pilihan in
            1)
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
                setup_auto_refresh 
                ;;
            7)
                full_system_cleanup
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
initialize_solution

# Jalankan menu utama
main_menu
