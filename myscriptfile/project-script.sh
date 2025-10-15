#!/bin/bash

# deploy-swarm.sh or project-script.sh
# Script to initialize Docker Swarm, set up environment variables, create stack files,
# and deploy Traefik and Voting App stacks on an Ubuntu manager node.

# Exit on any error
set -e

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Step 1: Verify Docker is installed and running
log "Verifying Docker installation..."
if ! command_exists docker; then
    log "Error: Docker is not installed. Please install Docker and try again."
    exit 1
fi
if ! systemctl is-active --quiet docker; then
    log "Error: Docker service is not running. Starting Docker..."
    systemctl start docker || { log "Error: Failed to start Docker service"; exit 1; }
fi
log "Docker is installed and running (version: $(docker --version))."

# Step 2: Verify and initialize Docker Swarm
log "Checking Docker Swarm status..."
SWARM_STATE=$(docker info --format '{{.Swarm.LocalNodeState}}' || echo "error")
if [ "$SWARM_STATE" = "error" ]; then
    log "Error: Failed to check Swarm status. Ensure Docker is running correctly."
    exit 1
fi
if [ "$SWARM_STATE" != "active" ]; then
    log "Initializing Docker Swarm..."
    # Dynamically detect the primary network interface and private IP
    INTERFACE=$(ip link | grep -E '^[0-9]+: (ens|eth)' | awk '{print $2}' | cut -d: -f1 | head -n 1)
    if [ -z "$INTERFACE" ]; then
        log "Warning: Could not detect network interface. Using default IP 10.0.1.199."
        PRIVATE_IP="10.0.1.199"
    else
        PRIVATE_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
        if [ -z "$PRIVATE_IP" ]; then
            log "Warning: Could not get private IP from $INTERFACE. Using default IP 10.0.1.199."
            PRIVATE_IP="10.0.1.199"
        fi
    fi
    docker swarm init --advertise-addr "$PRIVATE_IP" > swarm_init_output.txt
    log "Docker Swarm initialized successfully."
    log "To join worker nodes, SSH into each worker and run the following command:"
    cat swarm_init_output.txt | grep "docker swarm join" || { log "Error: Swarm join command not found"; exit 1; }
    echo "Please run the above command on each worker node manually."
else
    log "Docker Swarm is already initialized."
fi

# Verify Node ID
log "Verifying Swarm Node ID..."
NODE_ID=$(docker info --format '{{.Swarm.NodeID}}' || echo "")
if [ -z "$NODE_ID" ]; then
    log "Error: Failed to retrieve NODE_ID. Ensure this node is part of an active Swarm."
    log "Try reinitializing Swarm with 'docker swarm leave --force' and 'docker swarm init'."
    exit 1
fi
log "Node ID: $NODE_ID"

# Step 3: Create traefik.yml
log "Creating traefik.yml..."
cat > traefik.yml << 'EOF'
version: '3.3'

services:
  traefik:
    image: traefik:v2.9
    ports:
      - 80:80
      - 443:443
    deploy:
      placement:
        constraints:
          - node.labels.traefik-public.traefik-public-certificates == true
      labels:
        - traefik.enable=true
        - traefik.docker.network=traefik-public
        - traefik.constraint-label=traefik-public
        - traefik.http.middlewares.admin-auth.basicauth.users=${USERNAME?Variable not set}:${HASHED_PASSWORD?Variable not set}
        - traefik.http.middlewares.https-redirect.redirectscheme.scheme=https
        - traefik.http.middlewares.https-redirect.redirectscheme.permanent=true
        - traefik.http.routers.traefik-public-http.rule=Host(`${DOMAIN?Variable not set}`)
        - traefik.http.routers.traefik-public-http.entrypoints=http
        - traefik.http.routers.traefik-public-http.middlewares=https-redirect
        - traefik.http.routers.traefik-public-https.rule=Host(`${DOMAIN?Variable not set}`)
        - traefik.http.routers.traefik-public-https.entrypoints=https
        - traefik.http.routers.traefik-public-https.tls=true
        - traefik.http.routers.traefik-public-https.service=api@internal
        - traefik.http.routers.traefik-public-https.tls.certresolver=le
        - traefik.http.routers.traefik-public-https.middlewares=admin-auth
        - traefik.http.services.traefik-public.loadbalancer.server.port=8080
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik-public-certificates:/certificates
    command:
      - --providers.docker
      - --providers.docker.constraints=Label(`traefik.constraint-label`, `traefik-public`)
      - --providers.docker.exposedbydefault=false
      - --providers.docker.swarmmode
      - --entrypoints.http.address=:80
      - --entrypoints.https.address=:443
      - --certificatesresolvers.le.acme.email=${EMAIL?Variable not set}
      - --certificatesresolvers.le.acme.storage=/certificates/acme.json
      - --certificatesresolvers.le.acme.tlschallenge=true
      - --accesslog
      - --log
      - --api
    networks:
      - traefik-public

volumes:
  traefik-public-certificates:

networks:
  traefik-public:
    external: true
EOF
log "traefik.yml created successfully."

# Step 4: Create votingapp_with_traefik.yml
log "Creating votingapp_with_traefik.yml..."
cat > votingapp_with_traefik.yml << 'EOF'
version: "3"		
services:
  redis:
    image: redis:alpine
    networks:
      - traefik-public
    deploy:
      replicas: 1
      update_config:
        parallelism: 2
        delay: 10s
      restart_policy:
        condition: on-failure
  db:
    image: postgres:9.4
    environment:
      POSTGRES_USER: "postgres"
      POSTGRES_PASSWORD: "postgres"
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - traefik-public
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 512M
        reservations:
          cpus: "0.25"
          memory: 128M
      placement:
        constraints: [node.role == manager]
  vote:
    image: kiran2361993/testing:latestappvote
    ports:
      - 5000:80
    networks:
      - traefik-public
    depends_on:
      - redis
    deploy:
      replicas: 2
      labels:
        - traefik.enable=true
        - traefik.docker.network=traefik-public
        - traefik.constraint-label=traefik-public
        - traefik.http.middlewares.vote-https-redirect.redirectscheme.scheme=https
        - traefik.http.middlewares.vote-https-redirect.redirectscheme.permanent=true
        - traefik.http.routers.vote-public-http.rule=Host(`vote.atkrp.store`) || Host(`www.atkrp.store`)
        - traefik.http.routers.vote-public-http.entrypoints=http
        - traefik.http.routers.vote-public-http.middlewares=https-redirect
        - traefik.http.routers.vote-public-https.rule=Host(`vote.atkrp.store`) || Host(`www.atkrp.store`)
        - traefik.http.routers.vote-public-https.entrypoints=https
        - traefik.http.routers.vote-public-https.tls=true
        - traefik.http.routers.vote-public-https.tls.certresolver=le
        - traefik.http.services.vote-public.loadbalancer.server.port=80
      update_config:
        parallelism: 2
      restart_policy:
        condition: on-failure
  result:
    image: kiran2361993/testing:latestappresults
    ports:
      - 5001:80
    networks:
      - traefik-public
    depends_on:
      - db
    deploy:
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.docker.network=traefik-public
        - traefik.constraint-label=traefik-public
        - traefik.http.middlewares.result-https-redirect.redirectscheme.scheme=https
        - traefik.http.middlewares.result-https-redirect.redirectscheme.permanent=true
        - traefik.http.routers.result-public-http.rule=Host(`result.atkrp.store`)
        - traefik.http.routers.result-public-http.entrypoints=http
        - traefik.http.routers.result-public-http.middlewares=https-redirect
        - traefik.http.routers.result-public-https.rule=Host(`result.atkrp.store`)
        - traefik.http.routers.result-public-https.entrypoints=https
        - traefik.http.routers.result-public-https.tls=true
        - traefik.http.routers.result-public-https.tls.certresolver=le
        - traefik.http.services.result-public.loadbalancer.server.port=80
      update_config:
        parallelism: 2
        delay: 10s
      restart_policy:
        condition: on-failure
  worker:
    image: kiran2361993/testing:latestappworker
    networks:
      - traefik-public
    depends_on:
      - db
      - redis
    deploy:
      mode: replicated
      replicas: 1
      labels: [APP=VOTING]
      restart_policy:
        condition: on-failure
        delay: 10s
        max_attempts: 3
        window: 120s

networks:
  traefik-public:
    external: true

volumes:
  db-data:
EOF
log "votingapp_with_traefik.yml created successfully."

# Step 5: Set up environment variables
log "Setting up environment variables..."
# Prompt for sensitive variables
read -p "Enter your email for Let's Encrypt: " EMAIL
read -p "Enter Traefik dashboard password: " PASSWORD
export EMAIL
export DOMAIN=traefik.atkrp.store
export TRAEFIK_REPLICAS=1
export USERNAME=atkrpadmin
export PASSWORD
if ! command_exists openssl; then
    log "Installing openssl for password hashing..."
    apt-get update -y && apt-get install -y openssl || { log "Error: Failed to install openssl"; exit 1; }
fi
export HASHED_PASSWORD=$(openssl passwd -apr1 "$PASSWORD") || { log "Error: Failed to generate hashed password"; exit 1; }
docker node update --label-add traefik-public.traefik-public-certificates=true "$NODE_ID" || { log "Error: Failed to add node label"; exit 1; }
log "Environment variables set successfully."

# Step 6: Create traefik-public network
log "Creating traefik-public network..."
if ! docker network ls | grep -q "traefik-public"; then
    docker network create --driver=overlay traefik-public || { log "Error: Failed to create traefik-public network"; exit 1; }
    log "traefik-public network created successfully."
else
    log "traefik-public network already exists."
fi

# Step 7: Deploy Traefik stack
log "Deploying Traefik stack..."
docker stack deploy -c traefik.yml traefik || { log "Error: Failed to deploy Traefik stack"; exit 1; }
log "Traefik stack deployed successfully."

# Wait for Traefik to be ready
log "Waiting for Traefik services to start..."
sleep 30
if docker stack ps traefik | grep -q "Running"; then
    log "Traefik services are running."
else
    log "Warning: Traefik services may not be running correctly. Check logs with 'docker service logs traefik_traefik'."
fi

# Step 8: Deploy Voting App stack
log "Deploying Voting App stack..."
docker stack deploy -c votingapp_with_traefik.yml voting || { log "Error: Failed to deploy Voting App stack"; exit 1; }
log "Voting App stack deployed successfully."

# Step 9: Verify deployments
log "Verifying deployments..."
log "Traefik services:"
docker stack ps traefik
log "Voting App services:"
docker stack ps voting
log "Swarm nodes:"
docker node ls

# Final instructions
log "Setup complete! Next steps:"
log "- Ensure worker nodes have joined the Swarm using the join command shown above."
log "- Verify Traefik dashboard at https://traefik.atkrp.store (credentials: atkrpadmin/<your-password>)."
log "- Test Voting App at https://vote.atkrp.store, https://www.atkrp.store, and https://result.atkrp.store."
log "- Check logs if issues arise: 'docker service logs traefik_traefik' or 'docker service logs voting_vote'."
