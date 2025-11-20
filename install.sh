lsb_release -a
cd ..
sudo apt-get install
sudo apt-get update
sudo apt-get upgrade
sudo apt-get install nginx
sudo snap install certbot --classic
sudo apt install software-properties-common -y
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
sudo apt-get install zip
sudo apt install -y php8.1 php8.1-fpm php8.1-cli php8.1-common php8.1-mysql php8.1-zip php8.1-gd php8.1-mbstring php8.1-curl php8.1-xml php8.1-bcmath php8.1-intl php8.1-soap php8.1-readline php8.1-imap php8.1-ldap php8.1-opcache
sudo apt install -y php8.2 php8.2-fpm php8.2-cli php8.2-common php8.2-mysql php8.2-zip php8.2-gd php8.2-mbstring php8.2-curl php8.2-xml php8.2-bcmath php8.2-intl php8.2-soap php8.2-readline php8.2-imap php8.2-ldap php8.2-opcache
sudo apt install -y php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-mysql php8.3-zip php8.3-gd php8.3-mbstring php8.3-curl php8.3-xml php8.3-bcmath php8.3-intl php8.3-soap php8.3-readline php8.3-imap php8.3-ldap php8.3-opcache
sudo apt install -y php8.4 php8.4-fpm php8.4-cli php8.4-common php8.4-mysql php8.4-zip php8.4-gd php8.4-mbstring php8.4-curl php8.4-xml php8.4-bcmath php8.4-intl php8.4-soap php8.4-readline php8.4-imap php8.4-ldap php8.4-opcache
sudo update-alternatives --config php
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php -r "if (hash_file('sha384', 'composer-setup.php') === 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'.PHP_EOL; } else { echo 'Installer corrupt'.PHP_EOL; unlink('composer-setup.php'); exit(1); }"
php composer-setup.php
php -r "unlink('composer-setup.php');"
sudo mv composer.phar /usr/local/bin/composer
composer
php -v
systemctl status php8.1-fpm
systemctl status php8.2-fpm
systemctl status php8.3-fpm
systemctl status php8.4-fpm
php -v
history
