#!/bin/bash
# Custom bootstrap script for Ubuntu Linux

set -e
exec > >(sudo tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# any important variables
HOME=/home/ubuntu
echo "Setting HOME to $HOME"

echo "Start bootstrap script for Linux ${linux_os}"

# OS tuning
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
sudo sysctl -w net.core.netdev_max_backlog=250000

# Install packages
# Wait for apt to be ready
echo "Waiting for apt lock..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 2
done

echo "Installing initial packages"
sudo apt-get update -y
sudo apt-get install -y net-tools unzip masscan jq build-essential libpcap-dev nmap python3-pip python3.12-venv chromium-browser
sudo -u ubuntu mkdir /home/ubuntu/baseliner
sudo -u ubuntu wget https://raw.githubusercontent.com/spartantri/baseliner/refs/heads/main/baseliner/ip_baseliner.sh -O /home/ubuntu/baseliner/ip_baseliner.sh
sudo -u ubuntu wget https://raw.githubusercontent.com/spartantri/baseliner/refs/heads/main/baseliner/requirements.txt -O /home/ubuntu/baseliner/requirements.txt
sudo -u ubuntu wget https://raw.githubusercontent.com/spartantri/baseliner/refs/heads/main/baseliner/web_frontend.py -O /home/ubuntu/baseliner/web_frontend.py
sudo -u ubuntu wget https://raw.githubusercontent.com/spartantri/baseliner/refs/heads/main/baseliner/web_backend.py -O /home/ubuntu/baseliner/web_backend.py
chmod +x /home/ubuntu/baseliner/*.py /home/ubuntu/baseliner/*.sh
sudo -u ubuntu python3 -m venv /home/ubuntu/baseliner/.venv
echo "source /home/ubuntu/baseliner/.venv/bin/activate" >> /home/ubuntu/.bashrc

# Golang 1.24 install
echo "Installing Golang 1.22"
sudo -u ubuntu mkdir -p /home/ubuntu/go
sudo wget https://go.dev/dl/go1.24.3.linux-amd64.tar.gz
sudo tar -C /usr/local/ -xvf go1.24.3.linux-amd64.tar.gz
echo "export GOROOT=/usr/local/go" >> /home/ubuntu/.profile
echo "export GOPATH=$HOME/go" >> /home/ubuntu/.profile
echo "export PATH=$PATH:/usr/local/go/bin:/home/ubuntu/go/bin:/home/ubuntu/.pdtm/go/bin" >> /home/ubuntu/.profile
echo "export GOCACHE=/home/ubuntu/go/cache" >> /home/ubuntu/.profile
echo "export HOME=/home/ubuntu" >> /home/ubuntu/.profile
echo "export HOME=/home/ubuntu" >> /home/ubuntu/.bashrc
source /home/ubuntu/.profile
source /home/ubuntu/.bashrc

# Install massdns
cd /home/ubuntu
git clone https://github.com/blechschmidt/massdns.git
cd massdns
make
make install

# Install pdtm
echo "Installing pdtm"
sudo -u ubuntu -H bash -c '
export GOROOT=/usr/local/go
export GOPATH=/home/ubuntu/go
export PATH=$PATH:/usr/local/go/bin:/home/ubuntu/go/bin
go install -v github.com/projectdiscovery/pdtm/cmd/pdtm@latest
/home/ubuntu/go/bin/pdtm -install-all
'

# Install gowitness
sudo -u ubuntu -H bash -c '
export GOROOT=/usr/local/go
export GOPATH=/home/ubuntu/go
export PATH=$PATH:/usr/local/go/bin:/home/ubuntu/go/bin:/home/ubuntu/.pdtm/go/bin
go install -v github.com/sensepost/gowitness@latest
'

# Set permissions
chown -R ubuntu /home/ubuntu

# Install systemd services
cat <<EOF >/etc/systemd/system/baseliner-frontend.service
${baseliner_frontend_service}
EOF

cat <<EOF >/etc/systemd/system/baseliner-backend.service
${baseliner_backend_service}
EOF

chmod 644 /etc/systemd/system/baseliner-frontend.service
chmod 644 /etc/systemd/system/baseliner-backend.service

systemctl daemon-reexec
systemctl daemon-reload

systemctl enable baseliner-frontend
systemctl enable baseliner-backend

systemctl start baseliner-frontend
systemctl start baseliner-backend

# Enable tunneling
CONFIG_FILE="/etc/ssh/sshd_config"
SEARCH_STRING="Match User mrivas,cmcgranahan,dthompson"
BLOCK_TO_ADD="
Match User ubuntu
  AllowTcpForwarding yes
  DisableForwarding no
  PermitOpen 127.0.0.1:7170
  PermitOpen 127.0.0.1:7171
  PermitOpen 127.0.0.1:8501
"

echo "Checking $CONFIG_FILE for the required Match User block..."
# Use grep to check if the specific Match line already exists
if grep -qF "$SEARCH_STRING" "$CONFIG_FILE"; then
    echo "Status: The configuration is already present. No changes made."
else
    echo "Status: Configuration not found. Appending to $CONFIG_FILE..."
    # Use sudo tee -a to safely append the multi-line string
    echo "$BLOCK_TO_ADD" | tee -a "$CONFIG_FILE" > /dev/null
    echo "Success: Configuration added."
    # Verify the syntax of the SSH configuration to ensure no lockouts
    echo "Testing SSH configuration syntax..."
    if sshd -t; then
        echo "Syntax OK! Restarting the SSH service..." 
        # Restart the service as requested
        systemctl restart sshd
        echo "Service restarted successfully."
    else
        echo "WARNING: SSH configuration syntax check failed! Aborting restart. Please review $CONFIG_FILE immediately."
    fi
fi

echo "Bootstrap completed"
touch /home/ubuntu/bootstrap.done
chown ubuntu:ubuntu /home/ubuntu/bootstrap.done
