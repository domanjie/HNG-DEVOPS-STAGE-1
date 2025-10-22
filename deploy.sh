#!/bin/bash
# github-validate.sh - Interactive GitHub validation

set -e 
SCRIPT_DIR="$(pwd)"
LOG_FILE="$SCRIPT_DIR/deploy_$(date '+%Y%m%d').log"

touch "$LOG_FILE"

# Redirect all stdout/stderr to log file and  to console
exec > >(tee -a "$LOG_FILE") 2>&1

# 1. Collect Paramters from User Input


# Ask for GitHub URL
echo "Enter GitHub repository URL:"
read -p "URL: " GITHUB_URL

# Validate URL is not empty
if [ -z "$GITHUB_URL" ]; then
    echo "ERROR: URL cannot be empty"
    exit 1
fi

if [[ ! "$GITHUB_URL" =~ github\.com/([^/]+)/([^/]+) ]]; then
    echo "ERROR: Invalid GitHub URL format"
    echo "Expected format: https://github.com/owner/repo"
    exit 1
fi


# Ask for Personal Access Token (hide input for security)
echo ""
echo "Enter GitHub Personal Access Token:"
echo "Tip: Input will be hidden for security"
read -s -p "Token: " PAT
echo ""  # New line after hidden input

# Validate token is not empty
if [ -z "$PAT" ]; then
    echo "ERROR: Personal Access Token cannot be empty"
    exit 1
fi

# Ask for branch (with default)
echo ""
echo "Enter branch name (press Enter for 'main'):"
read -p "Branch [main]: " BRANCH

# Use default if empty
if [ -z "$BRANCH" ]; then
    BRANCH="main"
fi


# Ask for Remote ssh username 
echo ""
echo "Enter remote ssh username:"
read -p "Remote username: " REMOTE_USERNAME

# Validate remote username is not empty
if [ -z "$REMOTE_USERNAME" ]; then
	echo "ERROR: Remote username cannot be empty"
	exit 1 
fi 


# Ask for Remote ssh IP 
echo ""
echo "Enter ip of remote server:"
read -p "Remote ip: " REMOTE_IP

# Validate remote username is not empty
if [ -z "$REMOTE_IP" ]; then
	echo "ERROR: Remote server ip cannot be empty"
	exit 1 
fi 

echo ""
echo "Enter ssh key path:"
read -p "ssh key path: "  SSH_KEY_PATH 

if [ -z "$SSH_KEY_PATH" ]; then 
	echo "ERROR: ssh key path cannot be empty"
	exit 1
fi 
	
echo ""
echo "Enter port for docker application container:"
read -p "App port: " APP_PORT  

if [ -z "$APP_PORT" ]; then 
	echo "ERROR: docker application port cannot be empty"
	exit 1
fi 
	
PAT_GITHUB_URL="$(echo "$GITHUB_URL" | sed "s/https:\/\//https:\/\/$PAT@/")"
REPO="./repo"

# 2&3. Clone the Repository if necessary  and navigate to the cloned directory
# and validate that a dockerfile or docker-compose file is found.   
if [ -d "$REPO/.git" ]; then
    
	# Repository Exists (Update)

    	echo "Status: Repository already exists."
    	echo "Action: Navigating to $REPO and performing git pull..."
	
	cd "$REPO"
	
	git remote set-url origin "$PAT_GITHUB_URL"
	
	git checkout "$BRANCH"
	
        # Pull the latest changes for the specified branch
	if  ( git pull origin "$BRANCH" ); then
        	echo "SUCCESS: Repository updated."
    	else
        	echo "ERROR: Failed to pull changes. Check the log messages above."
        	exit 1
    	fi

else
    	# Repository Does NOT Exist (Initial Deployment) 
   	echo "Status: Repository not found in $REPO."
    	echo "Action: Cloning repository..."

    	PARENT_DIR=$(dirname "$REPO")
    	if [ ! -d "$PARENT_DIR" ]; then
        	echo "Creating parent directory $PARENT_DIR..."
        	mkdir -p "$PARENT_DIR"
    	fi
	
    	if  git clone "$PAT_GITHUB_URL" "$REPO"; then
        echo "SUCCESS: Initial deployment complete. Cloned into $REPO"
    		else
        echo "ERROR: Initial clone failed. Check permissions or PAT/URL."
        	exit 1
    	fi
	
	cd "$REPO"
	git checkout "$BRANCH"
fi

DOCKER_FILE=./Dockerfile
DOCKER_COMPOSE_FILE=./docker-compose.yml

if [[ -f "$DOCKER_FILE" || -f "$DOCKER_COMPOSE_FILE"   ]]; then 
	echo "Success: Docker File Found"		
else 
	echo "Error: Docker file missing"
	exit 1 
fi

cd ..

# 4.Test ssh into remote server 


ssh "$REMOTE_USERNAME@$REMOTE_IP" -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 bash <<EOF | tee -a $LOG_FILE
set -e

echo " Detecting OS and version..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=\$ID
    VERSION_ID=\${VERSION_ID%%.*}
else
    echo "Cannot determine OS."
    exit 1
fi

echo "Detected OS: \$OS \$VERSION_ID"

case "\$OS" in
    ubuntu|debian)
        echo "→ Using apt (Debian-based)"
        sudo apt update -y
        sudo apt install -y nginx docker.io curl docker-compose
        ;;

    centos|rhel|rocky|almalinux)
        if [ "\$VERSION_ID" -ge 8 ] 2>/dev/null; then
            echo "→ Using dnf (RHEL 8+)"
            sudo dnf install -y nginx docker curl docker-compose
        else
            echo "→ Using yum (RHEL/CentOS 7)"
            sudo yum install -y epel-release
            sudo yum install -y nginx docker curl docker-compose
        fi
        ;;

    fedora)
        echo "→ Using dnf (Fedora)"
        sudo dnf install -y nginx docker curl docker-compose
        ;;

    arch|archlinux)
        echo "→ Using pacman (Arch)"
        sudo pacman -Syu --noconfirm nginx docker curl docker-compose
        ;;

    *)
        echo "Unsupported OS: \$OS"
        exit 1
        ;;
esac

echo "Installation complete!"

# Optional: enable and start Docker & Nginx services
sudo systemctl enable docker nginx
sudo systemctl start docker nginx

REMOTE_USER=\$(whoami)
echo "→ Adding user '\$REMOTE_USER' to docker group..."
sudo usermod -aG docker \$REMOTE_USER
echo "Docker and Nginx are now running!"
nginx -v 2>&1
docker --version
curl --version | head -n1
docker-compose --version

sudo mkdir -p "$REPO"
echo " Created $REPO on remote host"
EOF
if [ $? -ne 0 ]; then 
	echo "SSH setup failed, Check key, network or remote firewall "
       	exit 1	
fi



REMOTE="$REMOTE_USERNAME@$REMOTE_IP"
HOST_PORT=80

scp -i "$SSH_KEY_PATH" -r "$REPO"/* "$REMOTE:$REPO" | tee -a $LOG_FILE

ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" bash <<EOF | tee -a $LOG_FILE
set -e
cd "$REPO"

echo "Checking for Docker configuration"

# Stop old containers if they exist
if sudo docker ps -a --format '{{.Names}}' | grep -q hngapp_container; then
    echo "Stopping old containers..."
    sudo docker stop hngapp_container || true
    sudo docker rm hngapp_container || true
fi

if sudo docker-compose ps -q &>/dev/null; then
    echo "Stopping old docker-compose services..."
    sudo docker-compose down || true
fi

if [ -f docker-compose.yml ]; then
    echo "Found docker-compose.yml"
    echo "Building and running containers with docker-compose..."
    sudo docker-compose up -d --build

elif [ -f Dockerfile ]; then
    echo "Found Dockerfile"
    IMAGE_NAME="hngapp"
    CONTAINER_NAME="hngapp_container"

    echo "Building image"
    sudo docker build -t "\$IMAGE_NAME" .

    echo "Running container"
    sudo docker run -d --name "\$CONTAINER_NAME" -p $APP_PORT:$APP_PORT "\$IMAGE_NAME"
fi

echo "Containers running:"
sudo docker ps


NGINX_CONF="/etc/nginx/sites-available/hngapp.conf"
if [ ! -f "\$NGINX_CONF" ]; then
    echo "Creating new Nginx config..."
else
    echo "Updating existing Nginx config..."
fi

sudo bash -c "cat > \$NGINX_CONF" <<'NGINXCONF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

#    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/ssl/hngapp/hngapp.crt;
    ssl_certificate_key /etc/ssl/hngapp/hngapp.key;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF

sudo mkdir -p /etc/ssl/hngapp
if [ ! -f /etc/ssl/hngapp/hngapp.crt ]; then
    echo "🔒 Generating self-signed SSL cert..."
    sudo openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /etc/ssl/hngapp/hngapp.key \
        -out /etc/ssl/hngapp/hngapp.crt \
        -days 365 \
        -subj "/CN=$REMOTE_IP"
else
    echo "✅ SSL cert already exists."
fi

sudo ln -sf "\$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

echo ""
echo "✅ Reverse proxy and SSL setup complete."

# ----------------------------
# Remote tests
# ----------------------------
echo ""
echo "🧪 Running remote connectivity tests..."
curl -s -o /dev/null -w "HTTP code (local): %{http_code}\n" http://localhost
curl -s -k -o /dev/null -w "HTTPS code (local): %{http_code}\n" https://localhost
EOF

