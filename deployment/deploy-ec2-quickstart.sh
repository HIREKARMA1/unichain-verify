#!/bin/bash

################################################################################
# Unichain-Verify EC2 Quick Start Deployment Script
# This script automates the deployment of Unichain-Verify on AWS EC2
#
# Repository: https://github.com/HIREKARMA1/unichain-verify.git
# Branch: releasehk-0.15.x
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="deployment-$(date +%Y%m%d-%H%M%S).log"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1" | tee -a "$LOG_FILE"
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    log_error "Please do not run this script as root"
    exit 1
fi

log_info "Deployment started at $(date)"
log_info "Log file: $LOG_FILE"

################################################################################
# Configuration
################################################################################

log_info "=== Unichain-Verify Deployment Configuration ==="
echo ""

# Get EC2 public IP
EC2_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
if [ -n "$EC2_PUBLIC_IP" ]; then
    log_info "Detected EC2 Public IP: $EC2_PUBLIC_IP"
else
    log_warn "Could not detect EC2 public IP"
fi

read -p "Enter your domain name (or press Enter to use IP $EC2_PUBLIC_IP): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    if [ -n "$EC2_PUBLIC_IP" ]; then
        DOMAIN_NAME=$EC2_PUBLIC_IP
        log_info "Using EC2 public IP: $DOMAIN_NAME"
    else
        log_error "Could not determine domain/IP. Please enter manually."
        exit 1
    fi
fi

read -p "Do you have a valid SSL certificate? (y/n) [default: n]: " HAS_SSL
HAS_SSL=${HAS_SSL:-n}
if [[ "$HAS_SSL" =~ ^[Yy]$ ]]; then
    ENABLE_SSL="Y"
    log_info "SSL enabled"
else
    ENABLE_SSL="n"
    log_warn "SSL disabled. This is only recommended for development."
fi

read -p "Database password [default: postgres]: " DB_PASSWORD
DB_PASSWORD=${DB_PASSWORD:-postgres}
log_info "Database password configured"

echo ""
log_info "Configuration Summary:"
log_info "  Domain/IP: $DOMAIN_NAME"
log_info "  SSL Enabled: $ENABLE_SSL"
log_info "  DB Password: ********"
log_info "  Repository: https://github.com/HIREKARMA1/unichain-verify.git"
log_info "  Branch: releasehk-0.15.x"
echo ""

read -p "Continue with deployment? (y/n) [default: y]: " CONTINUE
CONTINUE=${CONTINUE:-y}
if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    log_info "Deployment cancelled by user"
    exit 0
fi

################################################################################
# Step 1: System Update
################################################################################

log_info "Step 1: Updating system packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git vim unzip jq net-tools

log_info "System packages updated successfully"

################################################################################
# Step 2: Install Docker
################################################################################

log_info "Step 2: Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
    
    # Start docker service
    sudo systemctl enable docker
    sudo systemctl start docker
    
    log_info "✓ Docker installed successfully"
    log_info "Version: $(docker --version)"
else
    log_info "✓ Docker already installed: $(docker --version)"
fi

################################################################################
# Step 3: Install k3s (Lightweight Kubernetes)
################################################################################

log_info "Step 3: Installing k3s (Lightweight Kubernetes)..."
if ! command -v k3s &> /dev/null; then
    curl -sfL https://get.k3s.io | sh -
    
    # Setup kubeconfig
    sudo mkdir -p $HOME/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
    sudo chown $USER:$USER $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
    
    # Add to bashrc if not already there
    if ! grep -q "KUBECONFIG" ~/.bashrc; then
        echo "export KUBECONFIG=$HOME/.kube/config" >> ~/.bashrc
    fi
    
    # Wait for k3s to be ready
    log_info "Waiting for k3s to be ready (this may take 30-60 seconds)..."
    sleep 30
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        sudo ln -s /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true
    fi
    
    kubectl wait --for=condition=Ready nodes --all --timeout=300s || {
        log_warn "k3s not ready yet, waiting additional time..."
        sleep 30
        kubectl wait --for=condition=Ready nodes --all --timeout=300s
    }
    
    log_info "✓ k3s installed successfully"
    kubectl get nodes
else
    log_info "✓ k3s already installed"
    export KUBECONFIG=$HOME/.kube/config
    kubectl get nodes
fi

################################################################################
# Step 4: Install Helm
################################################################################

log_info "Step 4: Installing Helm..."
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_info "✓ Helm installed successfully"
    log_info "Version: $(helm version --short)"
else
    log_info "✓ Helm already installed: $(helm version --short)"
fi

################################################################################
# Step 5: Install Java 21 & Maven
################################################################################

log_info "Step 5: Installing Java 21 and Maven..."

# Install Java 21 using apt (simpler than SDKMAN for automated deployment)
if ! command -v java &> /dev/null; then
    log_info "Installing OpenJDK 21..."
    sudo apt install -y openjdk-21-jdk
    log_info "✓ Java installed successfully"
else
    log_info "✓ Java already installed"
fi
log_info "Java version: $(java -version 2>&1 | head -n 1)"

if ! command -v mvn &> /dev/null; then
    sudo apt install -y maven
    log_info "✓ Maven installed successfully"
    log_info "Maven version: $(mvn -version | head -n 1)"
else
    log_info "✓ Maven already installed: $(mvn -version | head -n 1)"
fi

################################################################################
# Step 6: Install PostgreSQL on Kubernetes
################################################################################

log_info "Step 6: Installing PostgreSQL on Kubernetes..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

# Check if postgres namespace exists
if ! kubectl get namespace postgres &> /dev/null; then
    kubectl create namespace postgres
    log_info "Created namespace: postgres"
fi

# Check if PostgreSQL is already installed
if ! helm list -n postgres 2>/dev/null | grep -q postgres; then
    log_info "Installing PostgreSQL (this may take a few minutes)..."
    helm install postgres bitnami/postgresql \
        --namespace postgres \
        --set auth.postgresPassword=$DB_PASSWORD \
        --set auth.username=postgres \
        --set auth.password=$DB_PASSWORD \
        --set auth.database=inji_verify \
        --set primary.persistence.size=20Gi \
        --set primary.resources.requests.memory=256Mi \
        --set primary.resources.requests.cpu=250m \
        --wait --timeout=10m
    
    log_info "✓ PostgreSQL installed successfully"
else
    log_info "✓ PostgreSQL already installed"
fi

# Wait for PostgreSQL to be ready
log_info "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql -n postgres --timeout=300s || {
    log_warn "PostgreSQL pods not ready yet, checking status..."
    kubectl get pods -n postgres
    log_info "Waiting additional time..."
    sleep 30
}

log_info "✓ PostgreSQL is ready"
kubectl get pods -n postgres

################################################################################
# Step 7: Create Config Server Namespace and ConfigMap
################################################################################

log_info "Step 7: Setting up config server..."
if ! kubectl get namespace config-server &> /dev/null; then
    kubectl create namespace config-server
    log_info "Created namespace: config-server"
fi

# Create or update ConfigMap
kubectl create configmap inji-stack-config \
    --namespace config-server \
    --from-literal=injiverify-host=$DOMAIN_NAME \
    --from-literal=postgres-host=postgres-postgresql.postgres \
    --from-literal=redis-host=redis-master.redis \
    --dry-run=client -o yaml | kubectl apply -f -

log_info "✓ ConfigMap created successfully"
kubectl get configmap inji-stack-config -n config-server -o yaml | grep -A 5 "data:"

################################################################################
# Step 8: Navigate to Unichain-Verify Repository
################################################################################

log_info "Step 8: Locating unichain-verify repository..."

# Save current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_debug "Script directory: $SCRIPT_DIR"

# Determine project root (script is in deployment/unichain-verify, project is at ../../unichain-verify)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
log_debug "Project root: $PROJECT_ROOT"

UNICHAIN_VERIFY_DIR="$PROJECT_ROOT/unichain-verify"
log_debug "Looking for unichain-verify at: $UNICHAIN_VERIFY_DIR"

if [ ! -d "$UNICHAIN_VERIFY_DIR" ]; then
    log_error "unichain-verify directory not found at: $UNICHAIN_VERIFY_DIR"
    log_error "Please ensure the unichain-verify repository exists at the project root"
    log_error "Expected structure:"
    log_error "  project-root/"
    log_error "  ├── deployment/unichain-verify/ (this script)"
    log_error "  └── unichain-verify/ (the main repository)"
    exit 1
fi

log_info "✓ Found unichain-verify at: $UNICHAIN_VERIFY_DIR"
cd "$UNICHAIN_VERIFY_DIR"
log_info "Working directory: $(pwd)"

################################################################################
# Step 9: Initialize Database
################################################################################

log_info "Step 9: Initializing database..."

if [ ! -d "db_scripts" ]; then
    log_error "db_scripts directory not found in $(pwd)"
    exit 1
fi

cd db_scripts

# Backup existing files if they exist
if [ -f "init_values.yaml" ]; then
    cp init_values.yaml init_values.yaml.backup
fi

# Update init_values.yaml
log_info "Creating database configuration..."
cat > init_values.yaml <<EOF
dbUserPasswords:
  dbuserPassword: "$DB_PASSWORD"

databases:
  inji_verify:
    enabled: true
    host: "postgres-postgresql.postgres"
    port: 5432
    su:
      user: postgres
      secret:
        name: postgres-postgresql
        key: postgres-password
    dml: 1
    repoUrl: https://github.com/HIREKARMA1/unichain-verify.git
    branch: releasehk-0.15.x
EOF

# Update postgres-config.yaml
cat > postgres-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-config
  namespace: injiverify
data:
  host: "postgres-postgresql.postgres"
  port: "5432"
EOF

# Make scripts executable
chmod +x init_db.sh copy_cm_func.sh 2>/dev/null || true

# Initialize database (automatically answer Y)
log_info "Running database initialization..."
echo "Y" | ./init_db.sh || {
    log_error "Database initialization failed"
    log_error "Check the logs above for details"
    exit 1
}

log_info "✓ Database initialized successfully"

cd ..

################################################################################
# Step 10: Deploy Unichain-Verify
################################################################################

log_info "Step 10: Deploying Unichain-Verify services..."

if [ ! -d "deploy" ]; then
    log_error "deploy directory not found in $(pwd)"
    exit 1
fi

cd deploy

# Make scripts executable
log_info "Making deployment scripts executable..."
chmod +x *.sh 2>/dev/null || true
find . -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Deploy services
log_info "Running deployment scripts (this may take several minutes)..."
log_info "Deployment will automatically configure SSL and domain settings..."

# Automatically answer prompts
{
    echo "$ENABLE_SSL"
    if [ "$ENABLE_SSL" = "n" ]; then
        echo "$DOMAIN_NAME"
    fi
} | ./install-all.sh || {
    log_error "Deployment failed"
    log_error "Check the logs above for details"
    exit 1
}

log_info "✓ Unichain-Verify services deployed successfully"

################################################################################
# Step 11: Wait for Pods to be Ready
################################################################################

log_info "Step 11: Waiting for pods to be ready (this may take 5-10 minutes)..."

# Wait for namespace to be created
sleep 10

# Check if pods exist
log_info "Checking pod status..."
kubectl get pods -n injiverify 2>/dev/null || log_warn "Namespace injiverify not ready yet, waiting..."

# Wait for verify-service
log_info "Waiting for verify-service pods..."
kubectl wait --for=condition=Ready pod -l app=inji-verify-service -n injiverify --timeout=600s 2>/dev/null || {
    log_warn "Timeout waiting for verify-service, checking status..."
    kubectl get pods -n injiverify
    log_info "Waiting additional time..."
    sleep 60
}

# Wait for verify-ui
log_info "Waiting for verify-ui pods..."
kubectl wait --for=condition=Ready pod -l app=inji-verify-ui -n injiverify --timeout=600s 2>/dev/null || {
    log_warn "Timeout waiting for verify-ui, checking status..."
    kubectl get pods -n injiverify
    log_info "Waiting additional time..."
    sleep 60
}

log_info "✓ Pods are ready"

################################################################################
# Step 12: Display Access Information
################################################################################

echo ""
log_info "═══════════════════════════════════════"
log_info "    Deployment Complete! 🎉"
log_info "═══════════════════════════════════════"
echo ""

# Get service information
VERIFY_SERVICE_PORT=$(kubectl get svc -n injiverify inji-verify-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
VERIFY_UI_PORT=$(kubectl get svc -n injiverify inji-verify-ui -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")

# Get EC2 public IP again for display
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "$DOMAIN_NAME")

log_info "📍 Access Information:"
echo ""
if [ "$ENABLE_SSL" = "Y" ]; then
    echo "  🌐 UI:  https://$DOMAIN_NAME"
    echo "  🔌 API: https://$DOMAIN_NAME/v1/verify"
else
    echo "  🌐 UI:  http://$PUBLIC_IP:$VERIFY_UI_PORT"
    echo "  🔌 API: http://$PUBLIC_IP:$VERIFY_SERVICE_PORT/v1/verify"
fi
echo ""

log_info "🔍 Health Check Commands:"
echo "  kubectl get pods -n injiverify"
echo "  curl http://localhost:8080/v1/verify/health  # (via port-forward)"
echo ""

log_info "📋 View Logs:"
echo "  kubectl logs -n injiverify -l app=inji-verify-service -f"
echo "  kubectl logs -n injiverify -l app=inji-verify-ui -f"
echo ""

log_info "🔧 Port Forward (for direct testing):"
echo "  kubectl port-forward -n injiverify svc/inji-verify-ui 3000:8000 &"
echo "  kubectl port-forward -n injiverify svc/inji-verify-service 8080:8080 &"
echo ""

log_info "⚙️  Management Commands:"
echo "  Restart: cd $UNICHAIN_VERIFY_DIR/deploy && ./restart-all.sh"
echo "  Delete:  cd $UNICHAIN_VERIFY_DIR/deploy && ./delete-all.sh"
echo "  Status:  kubectl get all -n injiverify"
echo ""

if [ "$VERIFY_SERVICE_PORT" != "N/A" ] && [ "$VERIFY_UI_PORT" != "N/A" ]; then
    log_warn "⚠️  SECURITY GROUP PORTS:"
    echo "  Make sure these ports are open in your EC2 Security Group:"
    echo "    - $VERIFY_SERVICE_PORT (verify-service)"
    echo "    - $VERIFY_UI_PORT (verify-ui)"
    echo "    - Or use port-forward for testing"
fi
echo ""

log_info "📖 Documentation:"
echo "  Full guide: $SCRIPT_DIR/DEPLOYMENT-README.md"
echo "  Quick start: $SCRIPT_DIR/QUICK-START.md"
echo "  Troubleshooting: $SCRIPT_DIR/TROUBLESHOOTING-CHEATSHEET.md"
echo ""

log_info "📝 Deployment log saved to: $LOG_FILE"
echo ""

################################################################################
# Step 13: Verification
################################################################################

log_info "Step 13: Running verification tests..."
sleep 15

echo ""
log_info "🧪 Testing Deployment..."
echo ""

# Check if pods are running
log_info "📊 Pod Status:"
kubectl get pods -n injiverify
echo ""

# Test backend health
log_info "🏥 Testing backend service health..."
if kubectl exec -n injiverify deploy/inji-verify-service -- curl -s http://localhost:8080/v1/verify/health &> /dev/null; then
    log_info "✅ Backend service is healthy!"
else
    log_warn "⚠️  Backend service health check failed"
    log_warn "This might be normal if pods are still starting"
    log_warn "Check logs: kubectl logs -n injiverify -l app=inji-verify-service"
fi
echo ""

# Display service information
log_info "🔌 Services:"
kubectl get svc -n injiverify
echo ""

# Display ingress information if exists
log_info "🌐 Ingress/Gateway:"
kubectl get ingress -n injiverify 2>/dev/null || kubectl get gateway -n injiverify 2>/dev/null || echo "  No ingress configured (using NodePort)"
echo ""

log_info "═══════════════════════════════════════"
log_info "  ✅ Setup Completed Successfully!"
log_info "═══════════════════════════════════════"
echo ""
log_info "⏰ Deployment completed at: $(date)"
log_info "⏱️  Total time: $SECONDS seconds"
echo ""

log_info "🚀 Next Steps:"
echo "  1. Wait 2-3 minutes for all pods to be fully ready"
echo "  2. Check pod status: kubectl get pods -n injiverify"
echo "  3. Access the UI in your browser using the URL above"
echo "  4. Test QR code verification functionality"
echo ""

log_info "📚 Need help? Check the troubleshooting guide:"
echo "  cat $SCRIPT_DIR/TROUBLESHOOTING-CHEATSHEET.md"
echo ""

