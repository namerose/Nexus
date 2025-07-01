#!/bin/bash
set -e

# === Konfigurasi dasar ===
BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"
REFRESH_INTERVAL_MINUTES=10  # Interval restart otomatis
AUTO_REFRESH_ENABLED=false   # Status auto-refresh

# === Warna terminal ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
    local auto_refresh_status="OFF"
    
    # Cek apakah auto-refresh aktif berdasarkan variabel status
    if [ "$AUTO_REFRESH_ENABLED" = true ]; then
        auto_refresh_status="${GREEN}ON${CYAN} (Setiap ${REFRESH_INTERVAL_MINUTES} menit)"
    else
        # Double-check dengan crontab juga
        if crontab -l 2>/dev/null | grep -q "restart_nexus_nodes"; then
            auto_refresh_status="${GREEN}ON${CYAN} (Setiap ${REFRESH_INTERVAL_MINUTES} menit)"
            # Update variabel status jika ternyata aktif
            AUTO_REFRESH_ENABLED=true
            # Simpan status ke file
            sed -i "s/^AUTO_REFRESH_ENABLED=.*/AUTO_REFRESH_ENABLED=true   # Status auto-refresh/" "$0"
        else
            auto_refresh_status="${RED}OFF${CYAN}"
        fi
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "           NEXUS - Node"
    echo -e "   Latest CLI Version: ${cli_version}"
    echo -e "   Auto-refresh: ${auto_refresh_status}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
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

# === Build Docker Image ===
function build_image() {
    echo -e "${YELLOW}Menggunakan installer resmi untuk mendapatkan CLI versi terbaru...${RESET}"
    local latest_version=$(get_cli_version)
    if [ "$latest_version" != "Unknown" ]; then
        echo -e "${GREEN}Versi terbaru tersedia: $latest_version${RESET}"
    fi

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

# Install latest Nexus CLI using official installer
RUN echo "Installing latest Nexus CLI from official installer..." && \\
    curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh && \\
    ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
PROVER_ID_FILE="/root/.nexus/node-id"

# Tampilkan versi CLI yang terinstall
echo "=== Nexus CLI Information ==="
if command -v nexus-network >/dev/null 2>&1; then
    nexus-network --version 2>/dev/null || echo "CLI Version: Installed (version check not available)"
else
    echo "CLI Version: Not found"
fi
echo "============================="

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

    docker build -t "$IMAGE_NAME" .
    cd -
    rm -rf "$WORKDIR"
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

# === Aktifkan Auto-Refresh ===
function enable_auto_refresh() {
    check_cron
    mkdir -p "$LOG_DIR"
    
    # Tambah job baru
    crontab -l | grep -v "restart_nexus_nodes" | crontab -  # Hapus job lama jika ada
    (crontab -l 2>/dev/null; echo "*/${REFRESH_INTERVAL_MINUTES} * * * * $PWD/$0 --restart-nodes >> $LOG_DIR/refresh.log 2>&1") | crontab -
    
    # Update status auto-refresh
    AUTO_REFRESH_ENABLED=true
    sed -i "s/^AUTO_REFRESH_ENABLED=.*/AUTO_REFRESH_ENABLED=true   # Status auto-refresh/" "$0"
    
    echo -e "${GREEN}✅ Auto-refresh diaktifkan setiap ${REFRESH_INTERVAL_MINUTES} menit${RESET}"
    echo -e "${CYAN}⏱  Next restart: $(date -d "+${REFRESH_INTERVAL_MINUTES} minutes" "+%H:%M:%S")${RESET}"
    
    # Restart semua node sekarang
    echo -e "${CYAN}♻️ Melakukan restart awal untuk semua node...${RESET}"
    restart_all_nodes
}

# === Nonaktifkan Auto-Refresh ===
function disable_auto_refresh() {
    # Hapus job auto-refresh
    crontab -l | grep -v "restart_nexus_nodes" | crontab -
    
    # Update status auto-refresh
    AUTO_REFRESH_ENABLED=false
    sed -i "s/^AUTO_REFRESH_ENABLED=.*/AUTO_REFRESH_ENABLED=false   # Status auto-refresh/" "$0"
    
    echo -e "${YELLOW}🔄 Auto-refresh dinonaktifkan${RESET}"
    echo -e "${CYAN}ℹ️ Node tidak akan di-restart secara otomatis${RESET}"
}

# === Menu Auto-Refresh ===
function setup_auto_refresh() {
    show_header
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "       🔄 PENGATURAN AUTO-REFRESH NODE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    # Cek status auto-refresh saat ini
    local is_active=false
    if crontab -l 2>/dev/null | grep -q "restart_nexus_nodes"; then
        is_active=true
        echo -e "${GREEN}Status: Auto-refresh AKTIF${RESET}"
        echo -e "${CYAN}Interval: Setiap ${REFRESH_INTERVAL_MINUTES} menit${RESET}"
        echo -e "${CYAN}Next restart: $(date -d "+${REFRESH_INTERVAL_MINUTES} minutes" "+%H:%M:%S")${RESET}"
    else
        echo -e "${RED}Status: Auto-refresh TIDAK AKTIF${RESET}"
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    if [ "$is_active" = true ]; then
        echo -e "${GREEN}1.${RESET} Ubah interval refresh (saat ini: ${REFRESH_INTERVAL_MINUTES} menit)"
        echo -e "${GREEN}2.${RESET} Matikan auto-refresh"
        echo -e "${GREEN}3.${RESET} Restart semua node sekarang"
        echo -e "${GREEN}4.${RESET} Kembali ke menu utama"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        read -rp "Pilih opsi (1-4): " choice
        
        case $choice in
            1)
                read -rp "Masukkan interval refresh baru (dalam menit): " new_interval
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -gt 0 ]; then
                    REFRESH_INTERVAL_MINUTES=$new_interval
                    # Update konfigurasi
                    sed -i "s/^REFRESH_INTERVAL_MINUTES=.*/REFRESH_INTERVAL_MINUTES=$new_interval  # Interval restart otomatis/" "$0"
                    # Aktifkan ulang dengan interval baru
                    enable_auto_refresh
                else
                    echo -e "${RED}Interval tidak valid. Harus berupa angka positif.${RESET}"
                    read -p "Tekan enter untuk kembali..."
                fi
                ;;
            2)
                disable_auto_refresh
                ;;
            3)
                restart_all_nodes
                read -p "Tekan enter untuk kembali..."
                ;;
            4)
                return
                ;;
            *)
                echo -e "${RED}Pilihan tidak valid.${RESET}"
                read -p "Tekan enter untuk kembali..."
                ;;
        esac
    else
        echo -e "${GREEN}1.${RESET} Aktifkan auto-refresh (interval: ${REFRESH_INTERVAL_MINUTES} menit)"
        echo -e "${GREEN}2.${RESET} Ubah interval refresh (saat ini: ${REFRESH_INTERVAL_MINUTES} menit)"
        echo -e "${GREEN}3.${RESET} Kembali ke menu utama"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        read -rp "Pilih opsi (1-3): " choice
        
        case $choice in
            1)
                enable_auto_refresh
                ;;
            2)
                read -rp "Masukkan interval refresh baru (dalam menit): " new_interval
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -gt 0 ]; then
                    REFRESH_INTERVAL_MINUTES=$new_interval
                    # Update konfigurasi
                    sed -i "s/^REFRESH_INTERVAL_MINUTES=.*/REFRESH_INTERVAL_MINUTES=$new_interval  # Interval restart otomatis/" "$0"
                    echo -e "${GREEN}✅ Interval refresh diubah menjadi ${new_interval} menit${RESET}"
                else
                    echo -e "${RED}Interval tidak valid. Harus berupa angka positif.${RESET}"
                fi
                read -p "Tekan enter untuk kembali..."
                ;;
            3)
                return
                ;;
            *)
                echo -e "${RED}Pilihan tidak valid.${RESET}"
                read -p "Tekan enter untuk kembali..."
                ;;
        esac
    fi
    
    # Rekursif kembali ke menu auto-refresh
    setup_auto_refresh
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
        docker ps -a --format "{{.Names}}" | grep "^${BASE_CONTAINER_NAME}-" | xargs -r docker rm -f
        
        # 4. Stop semua container Docker yang berjalan
        echo -e "${YELLOW}4. Menghentikan semua container Docker...${RESET}"
        docker stop $(docker ps -q) 2>/dev/null || true
        
        # 5. Hapus semua container Docker
        echo -e "${YELLOW}5. Menghapus semua container Docker...${RESET}"
        docker container prune -f
        docker rm -f $(docker ps -aq) 2>/dev/null || true
        
        # 6. Hapus semua image Docker
        echo -e "${YELLOW}6. Menghapus semua image Docker...${RESET}"
        docker image prune -a -f
        docker rmi -f $(docker images -q) 2>/dev/null || true
        
        # 7. Hapus semua volume Docker
        echo -e "${YELLOW}7. Menghapus semua volume Docker...${RESET}"
        docker volume prune -f
        docker volume rm $(docker volume ls -q) 2>/dev/null || true
        
        # 8. Hapus semua network Docker
        echo -e "${YELLOW}8. Menghapus semua network Docker...${RESET}"
        docker network prune -f
        
        # 9. Hapus build cache Docker
        echo -e "${YELLOW}9. Menghapus build cache Docker...${RESET}"
        docker builder prune -a -f
        
        # 10. Hapus system Docker secara menyeluruh
        echo -e "${YELLOW}10. Pembersihan sistem Docker menyeluruh...${RESET}"
        docker system prune -a -f --volumes
        
        # 11. Bersihkan RAM dan cache sistem
        echo -e "${YELLOW}11. Membersihkan RAM dan cache sistem...${RESET}"
        sync
        echo 3 > /proc/sys/vm/drop_caches
        sysctl -w vm.drop_caches=3
        
        # 12. Hapus semua log Nexus
        echo -e "${YELLOW}12. Menghapus semua log Nexus...${RESET}"
        rm -rf "$LOG_DIR"
        
        # 13. Hapus semua cron job Nexus
        echo -e "${YELLOW}13. Menghapus semua cron job Nexus...${RESET}"
        rm -f /etc/cron.d/nexus-log-cleanup-*
        
        # 14. Bersihkan semua log sistem
        echo -e "${YELLOW}14. Membersihkan semua log sistem...${RESET}"
        journalctl --vacuum-time=1h
        > /var/log/syslog
        > /var/log/kern.log
        > /var/log/auth.log
        find /var/log -name "*.log" -exec truncate -s 0 {} \;
        find /var/log -name "*.log.*" -delete
        
        # 15. Bersihkan temporary files dan cache
        echo -e "${YELLOW}15. Membersihkan file temporary dan cache...${RESET}"
        rm -rf /tmp/*
        rm -rf /var/tmp/*
        rm -rf ~/.cache/*
        rm -rf /root/.cache/*
        rm -rf /var/cache/*
        
        # 16. Bersihkan package cache
        echo -e "${YELLOW}16. Membersihkan package cache...${RESET}"
        apt clean
        apt autoclean
        apt autoremove -y --purge
        
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
        systemctl restart docker
        systemctl restart cron
        
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

# === Handle command line arguments ===
case "$1" in
    "--restart-nodes")
        restart_all_nodes
        exit 0
        ;;
esac

# === MENU UTAMA ===
while true; do
    show_header
    echo -e "${GREEN} 1.${RESET} ➕ Instal & Jalankan Node"
    echo -e "${GREEN} 2.${RESET} 📊 Lihat Status Semua Node"
    echo -e "${GREEN} 3.${RESET} ❌ Hapus Node Tertentu"
    echo -e "${GREEN} 4.${RESET} 🧾 Lihat Log Node"
    echo -e "${GREEN} 5.${RESET} 💥 Hapus Semua Node"
    echo -e "${GREEN} 6.${RESET} 🔄 Aktifkan Auto-Refresh Node"
    echo -e "${GREEN} 7.${RESET} 🧹 Cleanup System Penuh"
    echo -e "${GREEN} 8.${RESET} 🚪 Keluar"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    read -rp "Pilih menu (1-8): " pilihan
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
        6) 
            setup_auto_refresh
            read -p "Tekan enter untuk kembali ke menu..."
            ;;
        7) full_system_cleanup ;;
        8) echo "Keluar..."; exit 0 ;;
        *) echo "Pilihan tidak valid."; read -p "Tekan enter..." ;;
    esac
done
