#!/bin/bash
# Custom bootstrap script for Ubuntu Linux

set -e
exec > >(sudo tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# any important variables
HOME=/home/ubuntu
echo "Setting HOME to $HOME"

echo "Start bootstrap script for Linux ${linux_os}"
echo "Installing initial packages"
sudo apt-get update -y
sudo apt-get install -y net-tools unzip masscan jq build-essential libpcap-dev nmap

# Golang 1.24 install
echo "Installing Golang 1.22"
sudo wget https://go.dev/dl/go1.24.3.linux-amd64.tar.gz
sudo tar -C /usr/local/ -xvf go1.24.3.linux-amd64.tar.gz
echo "export GOROOT=/usr/local/go" >> /home/ubuntu/.profile
echo "export GOPATH=$HOME/go" >> /home/ubuntu/.profile
echo "export PATH=$PATH:/usr/local/go/bin" >> /home/ubuntu/.profile
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
go install -v github.com/projectdiscovery/pdtm/cmd/pdtm@latest
source ~/.bashrc
~/go/bin/pdtm -install-all
source ~/.bashrc
echo "source ~/.bashrc" >> ~/.bash_profile
source ~/.bash_profile
echo "source ~/.bashrc" >> ~/.profile
source ~/.profile
chown -R ubuntu:ubuntu /home/ubuntu/.config

# Install gowitness
go install -v github.com/sensepost/gowitness@latest

# OS config
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
sudo sysctl -w net.core.netdev_max_backlog=250000
