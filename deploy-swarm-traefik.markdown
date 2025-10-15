# Deploying Docker Swarm with Traefik and Voting App on AWS

This guide provides step-by-step instructions to set up a Docker Swarm cluster on AWS using Terraform, deploy Traefik as a reverse proxy, and run a sample voting application. The setup includes 1 manager node, 2 worker nodes, an NLB for traffic routing, and HTTPS with Let's Encrypt.

## Prerequisites

- **AWS Account**: With programmatic access (Access Key ID, Secret Access Key). Configure AWS CLI with `aws configure`.
- **EC2 Key Pair**: Named `myawskey` in your AWS region (default: `us-east-1`). Private key at `C:/Users/akhil/.ssh/myawskey.pem` (update if different).
- **Software**:
  - Terraform (&gt;= 1.4.0).
  - Docker (for local testing).
  - SSH client (e.g., OpenSSH).
- **Domain**: Managed via Route 53 or similar (e.g., `atkrp.store`). Prepare subdomains: `traefik.atkrp.store`, `vote.atkrp.store`, `result.atkrp.store`, `www.atkrp.store`.
- **AMI**: Verify Ubuntu AMI ID (`ami-0360c520857e3138f`) for your region.

## Step 1: Set Up Terraform Infrastructure

1. Create a project directory and add Terraform files (`main.tf`, `outputs.tf`, `variables.tf`).

2. Update `variables.tf` if needed (e.g., region, key path, AMI).

3. Initialize Terraform:

   ```
   terraform init
   ```

4. Plan the deployment:

   ```
   terraform plan
   ```

5. Apply the configuration:

   ```
   terraform apply
   ```

   - Confirm with `yes`.
   - Note outputs: `nlb_dns_name`, `master_ips`, `worker_ips`.

## Step 2: Configure DNS Records

1. In Route 53 (or your DNS provider), create A (ALIAS) records pointing to the NLB DNS name:
   - `traefik.atkrp.store` → NLB DNS.
   - `vote.atkrp.store` → NLB DNS.
   - `result.atkrp.store` → NLB DNS.
   - `www.atkrp.store` → NLB DNS.

## Step 3: Set Up Docker Swarm

1. SSH into the manager node:

   ```
   ssh -i /path/to/myawskey.pem ubuntu@<manager-public-ip>
   ```

2. Initialize Swarm:

   ```
   sudo docker swarm init --advertise-addr <manager-private-ip>
   ```

   - Copy the `Docker Swarm join` command.

3. SSH into each worker and join the Swarm:

   ```
   sudo docker swarm join --token <token> <manager-private-ip>:2377
   ```

4. Verify:

   ```
   sudo docker node ls
   ```

## Step 4: Deploy Traefik

1. On the manager, create `traefik.yml` and paste the provided content.

2. Set environment variables:

   ```
   sudo docker network create --driver=overlay traefik-public
   export NODE_ID=$(docker info -f '{{.Swarm.NodeID}}')
   sudo docker node update --label-add traefik-public.traefik-public-certificates=true $NODE_ID
   export EMAIL=example@gmail.com
   export DOMAIN=traefik.atkrp.store
   export TRAEFIK_REPLICAS=1
   export USERNAME=atkrpadmin
   export PASSWORD=Passwordonly123
   export HASHED_PASSWORD=$(openssl passwd -apr1 $PASSWORD)
   ```

3. Deploy:

   ```
   sudo docker stack deploy -c traefik.yml traefik
   ```

4. Verify: Access `https://traefik.atkrp.store` (credentials: `atkrpadmin:Passwordonly123`).

## Step 5: Deploy Voting Application

1. On the manager, create `votingapp_with_traefik.yml` and paste the provided content.

2. Deploy:

   ```
   sudo docker stack deploy -c votingapp_with_traefik.yml voting
   ```

3. Verify services:

   ```
   sudo docker stack ps voting
   ```

4. Test URLs:

   - Voting: `https://vote.atkrp.store` or `https://www.atkrp.store`.
   - Results: `https://result.atkrp.store`.

## Troubleshooting

- **Traefik Logs**: `sudo docker service logs traefik_traefik`.
- **App Logs**: `sudo docker service logs voting_vote`.
- **DNS**: Use `dig vote.atkrp.store` to check resolution.
- **Swarm Network**: `sudo docker network ls`.

## Cleanup

1. Remove stacks:

   ```
   sudo docker stack rm voting
   sudo docker stack rm traefik
   ```

2. Destroy infrastructure:

   ```
   terraform destroy
   ```