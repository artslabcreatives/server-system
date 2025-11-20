#!/bin/bash

# DigitalOcean API Configuration
DO_TOKEN="dop_v1_353ac5378198b18e98925df8d61fe61b63fc3c210ec566dbe38248909ef56343"
SERVER_PUBLIC_IP_ADDRESS="213.199.54.105"
DOMAIN="beta.artslabcreatives.com"


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

# Prompt for main domain
echo "1] Domain"
echo "2] Subdomain"
read -p "Domain or subdomain to beta.artslabcreatives.com: " CHOICE

if [ "$CHOICE" != "1" ] && [ "$CHOICE" != "2" ]; then
	echo "Invalid choice. Exiting."
	exit 1
fi

if [ "$CHOICE" == "1" ]; then
	read -p "Enter the main domain (e.g., beta.artslabcreatives.com): " DOMAIN
	if [ "$DOMAIN" != "beta.artslabcreatives.com" ]; then
		echo "Only beta.artslabcreatives.com is allowed. Exiting."
		exit 1
	fi
elif [ "$CHOICE" == "2" ]; then
  DOMAIN="beta.artslabcreatives.com"
  read -p "Enter the subdomain (e.g., myapp): " SUBDOMAIN
  if [ -z "$SUBDOMAIN" ]; then
      echo "Subdomain cannot be empty. Exiting."
      exit 1
  fi
    # Create subdomain A record in DigitalOcean
    if create_subdomain "$SUBDOMAIN" "$SERVER_PUBLIC_IP_ADDRESS"; then
      echo "DNS A record for $SUBDOMAIN.$DOMAIN created successfully."
    else
      echo "Failed to create DNS record for $SUBDOMAIN.$DOMAIN. Please check your DigitalOcean token and permissions."
      read -p "Do you want to continue with the rest of the setup anyway? (y/n): " continue_setup
      if [[ "$continue_setup" != "y" ]]; then
        exit 1
      fi
    fi
fi

# Build full domain
if [ -n "$SUBDOMAIN" ]; then
    FULL_DOMAIN="$SUBDOMAIN.$DOMAIN"
else
    FULL_DOMAIN="$DOMAIN"
fi

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

echo "Domain to configure: $FULL_DOMAIN"

# Ask for type: directory or reverse proxy
read -p "Should this point to a local directory or reverse proxy? (dir/proxy): " TYPE

if [ "$TYPE" == "dir" ]; then

    read -p "Enter the directory path (e.g., /var/www/html): " DIR_PATH
    CONFIG="server {
        listen 80;
        server_name $FULL_DOMAIN;
        root $DIR_PATH;
        index index.html index.htm;

        location / {
            try_files \$uri \$uri/ =404;
        }
    }"
elif [ "$TYPE" == "proxy" ]; then
    read -p "Enter the IP address and port to proxy to (e.g., 127.0.0.1:3000): " PROXY_PASS
    CONFIG="server {
        listen 80;
        server_name $FULL_DOMAIN;

        location / {
            proxy_pass http://$PROXY_PASS;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }"
else
    echo "Invalid type. Exiting."
    exit 1
fi

CONF_PATH="/etc/nginx/sites-available/$FULL_DOMAIN"
echo "$CONFIG" | sudo tee "$CONF_PATH" > /dev/null
sudo ln -sf "$CONF_PATH" "/etc/nginx/sites-enabled/$FULL_DOMAIN"
echo "Nginx config created at $CONF_PATH and enabled."
echo "Test Nginx config with: sudo nginx -t"
echo "Reload Nginx with: sudo systemctl reload nginx"
