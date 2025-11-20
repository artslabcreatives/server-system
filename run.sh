#!/bin/bash
#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
# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# DigitalOcean API Configuration
DO_TOKEN="dop_v1_f11f5b0adf46057f9acc925d2fcf6fc905469b7abf5a4018fdf079d1e74b4f05"
SERVER_PUBLIC_IP_ADDRESS="213.199.54.105"
DOMAIN="beta.artslabcreatives.com"

# Update package lists
apt update

# Install required software if not already installed
declare -A packages=(
  [nginx]="nginx"
  [mysql]="mysql-server"
  [php]="php"
  [wp_cli]="wp"
  [certbot]="certbot python3-certbot-nginx"
  [composer]="composer"
  [curl]="curl"
)

for package in "${!packages[@]}"; do
  if ! command -v "$package" &> /dev/null; then
    echo "Installing ${packages[$package]}..."
    apt install -y ${packages[$package]}
  else
    echo "${packages[$package]} already installed."
  fi
done

# Function to create a subdomain on DigitalOcean
create_subdomain() {
  local subdomain=$1
  local target_ip=$2
  
  echo "Creating DNS record for $subdomain.$DOMAIN pointing to $target_ip"
  
  local response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DO_TOKEN" \
    -d "{\"type\":\"A\",\"name\":\"$subdomain\",\"data\":\"$target_ip\",\"ttl\":3600}" \
    "https://api.digitalocean.com/v2/domains/$DOMAIN/records")
  
  if echo "$response" | grep -q "id"; then
    echo "DNS record created successfully for $subdomain.$DOMAIN"
    return 0
  else
    echo "Failed to create DNS record. Response: $response"
    return 1
  fi
}

# Prompt user for PHP version, site name, and framework selection
read -p "Enter PHP version to use (e.g., 7.4, 8.0): " php_version
read -p "Enter the site name (e.g., example.com): " site_name
read -p "Do you want to set up WordPress or Laravel? (wordpress/laravel): " framework

# Set default WordPress credentials
wp_user="miyuru@artslabcreatives.com"
wp_password="miyuru@artslabcreatives.com@123"
db_password="23\$23@\$\!\@4" # Replace with your root MySQL password if different

# Create DNS Record for the subdomain
if create_subdomain "$site_name" "$SERVER_PUBLIC_IP_ADDRESS"; then
  echo "DNS record has been created. It may take some time to propagate."
else
  echo "Failed to create DNS record. Please check your DigitalOcean token and permissions."
  read -p "Do you want to continue with the rest of the setup anyway? (y/n): " continue_setup
  if [[ "$continue_setup" != "y" ]]; then
    exit 1
  fi
fi

# Create MySQL database and user
db_name="${site_name//./_}_db"
sudo mysql <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS $db_name;
GRANT ALL PRIVILEGES ON $db_name.* TO 'nimda'@'%';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

installpath=$site_name
if [ "$framework" = "wordpress" ]; then
    installpath=$site_name
else
    installpath="$site_name/public"
fi

# Create Nginx server block
nginx_config="/etc/nginx/sites-available/$site_name"
cat <<EOL > $nginx_config
server {
    listen 80;
    server_name $site_name.$DOMAIN;
    root /var/www/$installpath;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php$php_version-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }

    listen [::]:80;
}
EOL

# Enable site and reload nginx
ln -s $nginx_config /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo "DNS record for $site_name.$DOMAIN has been created. Waiting for it to propagate..."
sleep 2  # Wait for 2 seconds before running certbot

# Obtain SSL certificate
certbot --nginx -d $site_name.$DOMAIN

# Set up WordPress
if [ "$framework" = "wordpress" ]; then
  # Set up the web root and install WordPress
  mkdir -p /var/www/$site_name && cd /var/www/$site_name
  wp core download --allow-root
  wp config create --dbname=$db_name --dbuser=nimda --dbpass=$db_password --dbhost=localhost --allow-root
  wp core install --url="https://$site_name.$DOMAIN" --title="$site_name" --admin_user="$wp_user" --admin_password="$wp_password" --admin_email="$wp_user" --allow-root

  chown -R www-data:www-data /var/www/$site_name
  chmod -R 777 /var/www/$site_name
  echo "WordPress installation completed at https://$site_name.$DOMAIN"

# Set up Laravel
elif [ "$framework" = "laravel" ]; then
  if ! command -v composer &> /dev/null; then
    echo "Installing Composer..."
    apt install -y composer
  fi

  # Set up the web root and install Laravel
  mkdir -p /var/www/$site_name && cd /var/www
  composer create-project --prefer-dist "laravel/laravel:^10.0" $site_name
  cd /var/www/$site_name
  
  # Update database configuration
  sed -i "s/DB_DATABASE=laravel/DB_DATABASE=$db_name/" /var/www/$site_name/.env
  sed -i "s/DB_USERNAME=root/DB_USERNAME=nimda/" /var/www/$site_name/.env
  sed -i "s/DB_PASSWORD=/DB_PASSWORD=$db_password/" /var/www/$site_name/.env
  
  # Install Filament and Laravel Backup
  echo "Installing Filament and Laravel Backup packages..."
  composer require filament/filament
  composer require spatie/laravel-backup
  composer require laravel/slack-notification-channel
  # Publish backup config
  php artisan vendor:publish --provider="Spatie\Backup\BackupServiceProvider" --tag=backup-config
  
  # Install Filament with panels
  php artisan filament:install --panels

  # Initialize Git repository
  echo "Initializing Git repository..."
  git init

  # Add safe directory for Git
  echo "Adding safe directory for Git..."
  git config --global --add safe.directory /var/www/$site_name

gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  /orgs/artslabcreatives/repos \
   -f "name=$site_name" -f "description=system for $site_name" -f "homepage=https://artslabcreatives.com" -F "private=true" -F "has_issues=true" -F "has_projects=true" -F "has_wiki=true"

  git add .
  git commit -m "init"
  git remote add origin git@github.com:artslabcreatives/$site_name.git
  git push origin master 

  # Create Admin User Seeder
  echo "Creating admin user seeder..."
  php artisan make:seeder AdminUserSeeder
  
  # Create the AdminUserSeeder content
  cat > /var/www/$site_name/database/seeders/AdminUserSeeder.php << 'EOF'
<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\Hash;
use App\Models\User;
use Filament\Models\Contracts\FilamentUser;
use Illuminate\Support\Str;

class AdminUserSeeder extends Seeder
{
    /**
     * Run the database seeds.
     */
    public function run(): void
    {
        User::create([
            'name' => 'Admin',
            'email' => 'miyuru@artslabcreatives.com',
            'email_verified_at' => now(),
            'password' => Hash::make('miyuru@artslabcreatives.com@123'),
            'remember_token' => Str::random(10),
        ]);
    }
}
EOF
  
  # Update User model to implement FilamentUser interface
  sed -i '/class User/i use Filament\\Models\\Contracts\\FilamentUser; \n use Filament\\Panel;' /var/www/$site_name/app/Models/User.php
  sed -i 's/class User extends Authenticatable/class User extends Authenticatable implements FilamentUser/' /var/www/$site_name/app/Models/User.php
  
  # Add canAccessFilament method to User model
  sed -i '/^{/a\\n    public function canAccessPanel(Panel $panel): bool\n    {\n        return $this->email === \"miyuru@artslabcreatives.com\";\n    }' /var/www/$site_name/app/Models/User.php
  
  # Update DatabaseSeeder to call AdminUserSeeder
  sed -i '/run()/,/}/c\    public function run(): void\n    {\n        $this->call([\n            AdminUserSeeder::class,\n        ]);\n    }' /var/www/$site_name/database/seeders/DatabaseSeeder.php
  
  # Run migrations and seeders
  php artisan migrate --seed
  
  git add .
  git commit -m "added filament"
  git push origin master 

  # Set permissions
  chown -R www-data:www-data /var/www/$site_name
  chmod -R 777 /var/www/$site_name
  echo "Laravel with Filament and admin user has been installed at https://$site_name.$DOMAIN"
else
  echo "Invalid choice. Please run the script again."
  exit 1
fi

echo "Installation complete. Access your site at https://$site_name.$DOMAIN"

# Set up UptimeRobot monitor for Laravel or WordPress
if [ "$framework" = "wordpress" ] || [ "$framework" = "laravel" ]; then
  echo "Setting up UptimeRobot monitor for https://$site_name.$DOMAIN..."
  UPTIME_API_TOKEN="u3084610-7d3688a8ce739e3d85de50ed"
  UPTIME_API_URL="https://api.uptimerobot.com/v3/monitors"
  # Prepare JSON payload
  read -r -d '' UPTIME_PAYLOAD <<EOF
{
  "friendlyName": "$site_name.$DOMAIN",
  "url": "https://$site_name.$DOMAIN",
  "type": "HTTP",
  "port": 0,
  "keywordType": "ALERT_EXISTS",
  "keywordCaseType": 0,
  "keywordValue": "AAAAAA",
  "interval": 600,
  "timeout": 300,
  "gracePeriod": 300,
  "httpUsername": "admin",
  "httpPassword": "password",
  "httpMethodType": "HEAD",
  "authType": "NONE",
  "postValueData": {},
  "postValueType": "KEY_VALUE",
  "customHttpHeaders": {},
  "successHttpResponseCodes": [
    "2xx",
    "3xx"
  ],
  "checkSSLErrors": false,
  "tagNames": [
    "tag1",
    "tag2"
  ],
  "maintenanceWindowsIds": [
    123,
    234
  ],
  "domainExpirationReminder": false,
  "sslExpirationReminder": false,
  "followRedirections": false,
  "responseTimeThreshold": 0,
  "regionalData": "na",
}
EOF
  # Send request
  uptime_response=$(curl -s -X POST "$UPTIME_API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $UPTIME_API_TOKEN" \
    -d "$UPTIME_PAYLOAD")
  if echo "$uptime_response" | grep -q '"id"'; then
    echo "UptimeRobot monitor created successfully."
  else
    echo "Failed to create UptimeRobot monitor. Response: $uptime_response"
  fi
fi
