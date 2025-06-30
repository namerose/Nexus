```bash
apt update && apt upgrade -y
apt install wget htop
```
or
```bash
sudo apt update && apt upgrade -y
sudo apt install wget htop
```

For Normal VPS using Docker ( your VPS server is not in docker container ) *required Ubuntu 24.04
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus.sh
chmod +x nexus.sh
./nexus.sh
```

For Not Normal VPS like Quickpod Previlege *required Ubuntu 24.04
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-quick.sh
chmod +x nexus-quick.sh
./nexus-quick.sh
```

For Podman *required Ubuntu 24.04
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-pod.sh
chmod +x nexus-pod.sh
./nexus-pod.sh
```

For IDK what to call but im using it using screen or tmux
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-ts.sh
chmod +x nexus-ts.sh
./nexus-ts.sh
```
