apt update -y
apt-get upgrade -y 
dpkg-reconfigure tzdata
apt install build-essential checkinstall
apt install ubuntu-restricted-extras
apt install software-properties-common
apt upgrade -o APT::Get::Show-Upgraded=true
apt-show-versions | grep upgradeable
apt install apt-show-versions
apt update -y
apt-get upgrade -y 
apt -f install 
apt autoremove 
apt -y autoclean 
apt -y clean 
apt update


# Docker Install

apt-get update -y
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  
sudo apt-get update

sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

apt-get update -y

systemctl start docker
systemctl enable docker
usermod -aG docker ${USER}
systemctl restart docker
systemctl status docker
docker --version

# Docker Compose Install
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
apt update -y
apt upgrade -y
docker-compose --version

