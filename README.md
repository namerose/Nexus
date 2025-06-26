apt update && apt upgrade -y
apt install wget htop

wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-quick.sh
chmod +x nexus-quick.sh
./nexus-quick.sh

apt update && apt upgrade -y
apt install wget htop

wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus.sh
chmod +x nexus.sh
./nexus.sh
