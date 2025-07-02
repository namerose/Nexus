```bash
apt update && apt upgrade -y
apt install wget htop
```
or
```bash
sudo apt update && apt upgrade -y
sudo apt install wget htop
```

Normal VPS using Docker *required Ubuntu 24.04 ( Containerized ) 
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus.sh
chmod +x nexus.sh
./nexus.sh
```

Not Normal VPS like Quickpod Previlege *required Ubuntu 24.04 ( Containerized ) 
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-quick.sh
chmod +x nexus-quick.sh
./nexus-quick.sh
```

Podman *required Ubuntu 24.04 ( Containerized ) 
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-pod.sh
chmod +x nexus-pod.sh
./nexus-pod.sh
```

Retarted *required Ubuntu 24.04 ( Not Containerized ) 
```bash
wget https://raw.githubusercontent.com/namerose/Nexus/refs/heads/main/nexus-ts.sh
chmod +x nexus-ts.sh
./nexus-ts.sh
```
