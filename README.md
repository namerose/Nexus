apt update && apt upgrade -y
apt install wget htop

wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-quick.sh
chmod +x nexus-quick.sh
./nexus-quick.sh

wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus.sh
chmod +x nexus.sh
./nexus.sh

wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-pod.sh
chmod +x nexus-pod.sh
./nexus-pod.sh
