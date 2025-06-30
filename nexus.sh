#!/bin/bash
set -e

# === Konfigurasi dasar ===
BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"

# === Warna terminal ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# === Ambil Versi CLI Terbaru ===
function get_latest_cli_version() {
    local latest_version=""
    if command -v curl >/dev/null 2>&1; then
        latest_version=$(curl -s https://api.github.com/repos/nexus-xyz/nexus-cli/releases/latest 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4 2>/dev/null)
    fi
    
    if [ -z "$latest_version" ]; then
        echo "Unknown"
    else
        echo "$latest_version"
    fi
}

# === Header Tampilan ===
function show_header() {
    clear
    local cli_version=$(get_latest_cli_version)
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "                    NEXUS - Node"
    echo -e "                CLI Versi Terbaru: ${YELLOW}${cli_version}${CYAN}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# === Periksa Docker ===
function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker tidak ditemukan. Menginstal Docker...${RESET}"
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        systemctl enable docker
        systemctl start docker
    fi
}

# === Periksa Cron ===
function check_cron() {
    if ! command -v cron >/dev/null 2>&1; then
        echo -e "${YELLOW}Cron belum tersedia. Menginstal cron...${RESET}"
        apt update
        apt install -y cron
        systemctl enable cron
        systemctl start cron
    fi
}

# === Hapus Image Lama ===
function clean_old_images() {
    echo -e "${YELLOW}Menghapus image dan cache Docker lama...${RESET}"
    
    # Hapus semua container nexus yang ada
    docker ps -aq --filter "name=${BASE_CONTAINER_NAME}" | xargs -r docker rm -f 2>/dev/null || true
    
    # Hapus image nexus-node
    docker rmi -f "$IMAGE_NAME" 2>/dev/null || true
    docker rmi -f $(docker images --filter "reference=nexus-node" -q) 2>/dev/null || true
    
    # Hapus image ubuntu:24.04 untuk memaksa download fresh
    docker rmi -f ubuntu:24.04 2>/dev/null || true
    
    # Bersihkan build cache
    docker builder prune -f 2>/dev/null || true
    
    echo -e "${GREEN}Cache dan image lama berhasil dihapus.${RESET}"
}

# === Build Docker Image ===
function build_image() {
    # Hapus image lama terlebih dahulu
    clean_old_images
    
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    bash \\
    && rm -rf /var/lib/apt/lists/*

# Memaksa download CLI terbaru dengan timestamp
RUN curl -sSL https://cli.nexus.xyz/?t=\$(date +%s) | NONINTERACTIVE=1 sh \\
    && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
PROVER_ID_FILE="/root/.nexus/node-id"
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID belum disetel"
    exit 1
fi
echo "\$NODE_ID" > "\$PROVER_ID_FILE"
screen -S nexus -X quit >/dev/null 2>&1 || true
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"
sleep 3
if screen -list | grep -q "nexus"; then
    echo "Node berjalan di latar belakang"
else
    echo "Gagal menjalankan node"
    cat /root/nexus.log
    exit 1
fi
tail -f /root/nexus.log
EOF

    echo -e "${YELLOW}Membangun image baru dengan CLI versi terbaru...${RESET}"
    docker build --no-cache -t "$IMAGE_NAME" .
    cd -
    rm -rf "$WORKDIR"
    
    echo -e "${GREEN}Image berhasil dibangun dengan CLI versi terbaru.${RESET}"
}

# === Jalankan Container ===
function run_container() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"

    docker rm -f "$container_name" 2>/dev/null || true
    mkdir -p "$LOG_DIR"
    touch "$log_file"
    chmod 644 "$log_file"

    docker run -d --name "$container_name" -v "$log_file":/root/nexus.log -e NODE_ID="$node_id" "$IMAGE_NAME"

    check_cron
    echo "0 0 * * * rm -f $log_file" > "/etc/cron.d/nexus-log-cleanup-${node_id}"
}

# === Hapus Node ===
function uninstall_node() {
    local node_id=$1
    local cname="${BASE_CONTAINER_NAME}-${node_id}"
    docker rm -f "$cname" 2>/dev/null || true
    rm -f "${LOG_DIR}/nexus-${node_id}.log" "/etc/cron.d/nexus-log-cleanup-${node_id}"
    echo -e "${YELLOW}Node $node_id telah dihapus.${RESET}"
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

# === Reset Lengkap ===
function full_reset() {
    echo -e "${RED}⚠️  PERINGATAN: Ini akan menghapus SEMUA data Nexus dan cache Docker!${RESET}"
    echo "- Semua container Nexus akan dihapus"
    echo "- Semua image Docker Nexus akan dihapus"
    echo "- Cache Docker akan dibersihkan"
    echo "- Log files akan dihapus"
    echo "- Cron jobs akan dihapus"
    echo ""
    echo "Setelah reset, node akan menggunakan CLI versi terbaru saat dijalankan ulang."
    echo ""
    read -rp "Ketik 'RESET' untuk konfirmasi: " confirm
    
    if [[ "$confirm" == "RESET" ]]; then
        echo -e "${YELLOW}Memulai reset lengkap...${RESET}"
        
        # Hapus semua node
        local all_nodes=($(get_all_nodes))
        for node in "${all_nodes[@]}"; do
            uninstall_node "$node"
        done
        
        # Bersihkan image dan cache
        clean_old_images
        
        # Hapus direktori log
        rm -rf "$LOG_DIR"
        
        # Hapus semua cron job nexus
        rm -f /etc/cron.d/nexus-log-cleanup-*
        
        echo -e "${GREEN}✅ Reset lengkap berhasil!${RESET}"
        echo "Sekarang Anda dapat menjalankan node baru dengan CLI versi terbaru."
    else
        echo "Reset dibatalkan."
    fi
    read -p "Tekan enter..."
}

# === MENU UTAMA ===
while true; do
    show_header
    echo -e "${GREEN} 1.${RESET} ➕ Instal & Jalankan Node"
    echo -e "${GREEN} 2.${RESET} 📊 Lihat Status Semua Node"
    echo -e "${GREEN} 3.${RESET} ❌ Hapus Node Tertentu"
    echo -e "${GREEN} 4.${RESET} 🧾 Lihat Log Node"
    echo -e "${GREEN} 5.${RESET} 💥 Hapus Semua Node"
    echo -e "${GREEN} 6.${RESET} 🔄 Reset Lengkap (Force Update CLI)"
    echo -e "${GREEN} 7.${RESET} 🚪 Keluar"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    read -rp "Pilih menu (1-7): " pilihan
    case $pilihan in
        1)
            check_docker
            read -rp "Masukkan NODE_ID: " NODE_ID
            [ -z "$NODE_ID" ] && echo "NODE_ID tidak boleh kosong." && read -p "Tekan enter..." && continue
            build_image
            run_container "$NODE_ID"
            read -p "Tekan enter..."
            ;;
        2) list_nodes ;;
        3) batch_uninstall_nodes ;;
        4) view_logs ;;
        5) uninstall_all_nodes ;;
        6) full_reset ;;
        7) echo "Keluar..."; exit 0 ;;
        *) echo "Pilihan tidak valid."; read -p "Tekan enter..." ;;
    esac
done
