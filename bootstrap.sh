#!/bin/bash 

if [[ -z "$PROJECT_ID" ]]; then
    echo "Must provide PROJECT_ID in environment" 1>&2
    exit 1
fi

# Function to register a GKE cluster to the Anthos dashboard 
register_cluster () {
    CLUSTER_NAME=$1 
    ZONE=$2 
    echo "🏔 Registering cluster to Anthos: $CLUSTER_NAME, zone: $ZONE" 

    URI="https://container.googleapis.com/v1/projects/${PROJECT_ID}/zones/${ZONE}/clusters/${CLUSTER_NAME}"
    gcloud container hub memberships register ${CLUSTER_NAME} \
    --project=${PROJECT_ID} \
    --gke-uri=${URI} \
    --service-account-key-file=register-key.json
}

# Set Project ID 
gcloud config set project $PROJECT_ID 

export CLUSTER_NAME="asm-reliability"
export ZONE="us-central1-b"
export REG_SERVICE_ACCOUNT="register-sa"

# Enable the GKE API 
echo "☁️ Enabling APIs..."
gcloud services enable container.googleapis.com
gcloud services enable anthos.googleapis.com 

# Create cluster 
echo "☸️ Creating GKE cluster ($CLUSTER_NAME in zone: $ZONE)..."
gcloud beta container clusters create $CLUSTER_NAME \
--project=${PROJECT_ID} --zone=${ZONE} \
--machine-type=e2-standard-4 --num-nodes=4 \
--enable-stackdriver-kubernetes --subnetwork=default \
--workload-pool=$PROJECT_ID.svc.id.goog

# Connect to the cluster 
echo "⏫ Connecting your local terminal to your GKE cluster..."
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE --project ${PROJECT_ID} 

# Register cluster to the Anthos dashboard
echo "🔑 Setting up Anthos registration service account..."
gcloud iam service-accounts create ${REG_SERVICE_ACCOUNT} --project=${PROJECT_ID}

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${REG_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/gkehub.connect"\

gcloud iam service-accounts keys create register-key.json \
    --iam-account=${REG_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com \
    --project=${PROJECT_ID}

# Register cluster to the Anthos dashboard 
register_cluster $CLUSTER_NAME $ZONE 

# Install ASM (user managed control plane 1.9) on the cluster 
echo "🕸️ Installing Anthos Service Mesh on your GKE cluster..."
gcloud config set compute/zone $ZONE
curl https://storage.googleapis.com/csm-artifacts/asm/install_asm_1.9 > install_asm
curl https://storage.googleapis.com/csm-artifacts/asm/install_asm_1.9.sha256 > install_asm.sha256
sha256sum -c install_asm.sha256
chmod +x install_asm

./install_asm \
--project_id $PROJECT_ID \
--cluster_name $CLUSTER_NAME \
--cluster_location $ZONE \
--mode install \
--enable_all

# Label the default namespace for istio injection 
# get "revision" from directory created by install_asm script 
for dir in asm-${CLUSTER_1_NAME}/istio-*/ ; do
    export REVISION=`basename $dir`
    echo "Revision is: $REVISION" 
done
kubectl label namespace default istio-injection- istio.io/rev=$REVISION --overwrite

# Set up Workload Identity for the default namespace, incl. BoA specific permissions 
echo "🔒 Setting up Workload Identity so that your GKE Pods can authenticate to GCP..."
GSA_NAME="boa-gsa"
gcloud iam service-accounts create $GSA_NAME

# WI setup 
# https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#authenticating_to
gcloud iam service-accounts add-iam-policy-binding \
--role roles/iam.workloadIdentityUser \
--member "serviceAccount:$PROJECT_ID.svc.id.goog[default/default]" \
$GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com

# BoA setup - give the Google Service Account Cloud Monitoring + Trace permissions. 
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
--member "serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
--role roles/cloudtrace.agent

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
--member "serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
--role roles/monitoring.metricWriter

# Connect BoA's default Kubernetes Service Account (KSA) to the  GSA 
kubectl annotate serviceaccount \
--namespace default default \
iam.gke.io/gcp-service-account=$GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com

# Deploy Bank of Anthos app, including Istio resources for ingress 
echo "🏦 Deploying Bank of Anthos to GKE..."
kubectl apply -f bank-of-anthos

echo "Waiting for all pods to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/frontend
kubectl wait --for=condition=available --timeout=300s deployment/contacts
kubectl wait --for=condition=available --timeout=300s deployment/userservice
kubectl wait --for=condition=available --timeout=300s deployment/ledgerwriter
kubectl wait --for=condition=available --timeout=300s deployment/transactionhistory
kubectl wait --for=condition=available --timeout=300s deployment/balancereader
kubectl wait --for=condition=available --timeout=300s deployment/loadgenerator
kubectl wait --for=condition=ready --timeout=300s pod/accounts-db-0
kubectl wait --for=condition=ready --timeout=300s pod/ledger-db-0

# Done! Print the external IP. 
echo "✅ Bootstrapping complete. Bank of Anthos frontend is available at:"
kubectl get service istio-ingressgateway -n istio-system | awk '{print $4}'
