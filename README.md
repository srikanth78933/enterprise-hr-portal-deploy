# Enterprise HR Portal – Deployment

Jenkins CI/CD pipeline, Dockerfile and Helm chart that build and deploy
[Enterprise HR Portal](https://github.com/srikanth78933/Enterprise-HR-Management-System) to AWS EKS,
for the **dev** and **prod** environments.

```
Git ─► Maven (build + tests) ─► SonarQube (+ quality gate) ─► Nexus (JAR)
    ─► Docker image ─► Trivy scan ─► Docker Hub ─► Helm package ─► [prod approval] ─► EKS
```

## Repository contents

```
enterprise-hr-portal-deploy/
├── Jenkinsfile                   Declarative pipeline, parameter ENVIRONMENT = dev | prod
├── Dockerfile                    Runtime image (Java 21 JRE, non-root user)
├── maven-settings.xml            Nexus credentials read from environment variables
├── .trivyignore                  Reviewed/accepted CVEs with reasons
├── environments/
│   ├── dev/values.yaml           Dev overrides: HPA, resources, PDB, secret name, IAM role
│   └── prod/values.yaml          Prod overrides
├── config/
│   ├── env-dev.yaml              Dev environment variables (ConfigMap)
│   └── env-prod.yaml             Prod environment variables (ConfigMap)
└── helm/enterprise-hr-portal/    Helm chart (same chart for every environment)
    ├── Chart.yaml
    ├── values.yaml               GLOBAL defaults for all environments
    └── templates/
        ├── configmap.yaml            All "env" keys → environment variables
        ├── secretproviderclass.yaml  "secrets.keys" from AWS Secrets Manager
        ├── serviceaccount.yaml       IAM role (IRSA) allowed to read the secret
        ├── deployment.yaml           Pods, probes, ConfigMap + secret wiring
        ├── service.yaml              LoadBalancer (or ClusterIP with Ingress)
        ├── hpa.yaml                  Autoscaling on CPU/memory
        ├── pdb.yaml                  Keeps pods available during node drains
        ├── ingress.yaml              Optional ALB Ingress (disabled by default)
        ├── _helpers.tpl              Shared labels
        └── NOTES.txt                 Shown after install
```

## How environments work

Helm combines three layers. **Later files win**, and maps are merged key by key, so an
environment file only contains what is different:

```
1. helm/enterprise-hr-portal/values.yaml   global defaults (packaged inside the chart)
2. environments/<env>/values.yaml          environment overrides
3. config/env-<env>.yaml                   environment variables for that environment
```

Jenkins deploys with:

```bash
helm upgrade --install enterprise-hr-portal <chart.tgz> \
  -f environments/<env>/values.yaml -f config/env-<env>.yaml ...
```

The packaged chart is identical for dev and prod; only the environment files differ.

### Environment variables (`env`)

Every key under `env:` becomes an environment variable in the pods (through the ConfigMap).
Common defaults (`DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `JAVA_TOOL_OPTIONS`) are in the global
`values.yaml`; `config/env-<env>.yaml` adds or overrides keys. `DB_HOST` is required there.
To add a new variable, add one line, for example `FEATURE_X_ENABLED: "true"`.

### Secrets (`secrets`)

Only the **name** of the Secrets Manager secret and the **key names** are in Git, never the values:

```yaml
secrets:
  awsSecretName: "enterprise-hr-portal/dev/db"   # set per environment
  keys:                                          # <ENV_VARIABLE>: <json key in the secret>
    DB_USERNAME: username
    DB_PASSWORD: password
```

`keys` is defined globally; an environment can add a key (for example `API_TOKEN: api_token`)
and it is merged with the global ones. Every key must exist in that environment's secret.

```
config/env-<env>.yaml ─► ConfigMap ──────────────────────────┐ DB_HOST, DB_PORT, DB_NAME, ...
                                                             │
AWS Secrets Manager ─► SecretProviderClass (CSI driver) ─────┤
  enterprise-hr-portal/<env>/db  │ ServiceAccount IAM role   │ DB_USERNAME, DB_PASSWORD
                                 └─► synced K8s Secret ──────┴─► Deployment (env variables)
```

### Differences between dev and prod

| Setting                | dev                              | prod                              |
|------------------------|----------------------------------|-----------------------------------|
| EKS cluster            | `mycompany-dev-eks`              | `mycompany-prod-eks`              |
| Namespace              | `hr-portal-dev`                  | `hr-portal-prod`                  |
| Pods (HPA min–max)     | 1–2                              | 2–6                               |
| PodDisruptionBudget    | off                              | minAvailable 1                    |
| CPU / memory requests  | 200m / 512Mi                     | 500m / 768Mi                      |
| Secrets Manager secret | `enterprise-hr-portal/dev/db`    | `enterprise-hr-portal/prod/db`    |
| Log level (app)        | DEBUG                            | INFO                              |
| Deploy approval        | automatic                        | manual approval in Jenkins        |

Each build uses one version everywhere: **`1.0.<BUILD_NUMBER>`** → JAR version in Nexus,
Docker image tag, Helm chart version and app version.

## Values to change before the first run

| File                              | Value                    | Set it to |
|-----------------------------------|--------------------------|-----------|
| `Jenkinsfile`                     | `NEXUS_URL`              | `http://<nexus-ec2-ip>:8081` |
| `Jenkinsfile`                     | `DOCKER_IMAGE`           | `<your-dockerhub-user>/enterprise-hr-portal` |
| `Jenkinsfile`                     | `EKS_CLUSTER`            | Cluster name pattern (default `mycompany-<env>-eks`) |
| `Jenkinsfile`                     | `AWS_REGION`             | Region of the clusters and Secrets Manager |
| `config/env-dev.yaml`             | `env.DB_HOST`            | Dev RDS endpoint |
| `config/env-prod.yaml`            | `env.DB_HOST`            | Prod RDS endpoint |
| `environments/dev/values.yaml`    | `serviceAccount.roleArn` | Dev IAM role ARN (setup step 8d) |
| `environments/prod/values.yaml`   | `serviceAccount.roleArn` | Prod IAM role ARN (setup step 8d) |

If dev and prod share one cluster, set `EKS_CLUSTER` to that fixed name; the namespaces
(`hr-portal-dev`, `hr-portal-prod`) keep them separate.

## One-time setup

### 1. Tools on the Jenkins server (Ubuntu)

```bash
# Docker (and allow Jenkins to use it)
sudo apt update
sudo apt install -y docker.io unzip curl wget gnupg
sudo usermod -aG docker jenkins

# Trivy
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt update && sudo apt install -y trivy

# Helm 3
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install

# kubectl
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl

sudo systemctl restart jenkins
```

Check: `docker --version && trivy --version && helm version && aws --version && kubectl version --client`

### 2. Jenkins plugins

Install from **Manage Jenkins → Plugins**: *Pipeline*, *Git*, *SonarQube Scanner*,
*Docker Pipeline*, *Credentials Binding*, *JUnit* (most come with the suggested plugins).

### 3. Jenkins tools

**Manage Jenkins → Tools**:

| Tool  | Name (must match the Jenkinsfile) |
|-------|-----------------------------------|
| JDK   | `java21` (JDK 21) |
| Maven | `maven3.9.16` |

### 4. Jenkins credentials

**Manage Jenkins → Credentials → (global) → Add credentials**:

| ID                      | Kind                | Value |
|-------------------------|---------------------|-------|
| `nexus-credentials`     | Username/password   | Nexus user that can deploy to `maven-releases` |
| `dockerhub-credentials` | Username/password   | Docker Hub username + access token |
| `AWS_ACCESS_KEY_ID`     | Secret text         | Access key of the IAM user used for EKS |
| `AWS_SECRET_ACCESS_KEY` | Secret text         | Secret key of the same IAM user |
| `sonarqube-token`       | Secret text         | SonarQube user token (My Account → Security) |

### 5. SonarQube

1. **Manage Jenkins → System → SonarQube servers → Add**:
   name **`sonarqube`**, URL `http://<sonar-ec2-ip>:9000`, token `sonarqube-token`.
2. In SonarQube: **Administration → Configuration → Webhooks → Create**:
   URL `http://<jenkins-ec2-ip>:8080/sonarqube-webhook/`.
   The *Quality Gate* stage waits for this webhook; without it the stage times out after 5 minutes.

### 6. Nexus

The pipeline uploads to the default **`maven-releases`** repository
(`<NEXUS_URL>/repository/maven-releases/`). Release repositories reject the same version twice,
which is why each build gets its own `1.0.<BUILD_NUMBER>` version.

### 7. EKS access for the Jenkins IAM user (each cluster)

```bash
aws eks create-access-entry --cluster-name <cluster> --region <region> \
  --principal-arn arn:aws:iam::<account-id>:user/<jenkins-iam-user>

aws eks associate-access-policy --cluster-name <cluster> --region <region> \
  --principal-arn arn:aws:iam::<account-id>:user/<jenkins-iam-user> \
  --policy-arn arn:aws:eks::aws:policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

### 8. Database and AWS Secrets Manager (repeat for dev and prod)

Run these from a machine with `aws`, `eksctl`, `kubectl` and `helm` configured for the cluster.
Set `ENV` to `dev` first, then repeat everything with `ENV=prod`.

```bash
export ENV=dev                       # then: prod
export CLUSTER=mycompany-${ENV}-eks
export REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

**a) RDS PostgreSQL**

1. Create an RDS PostgreSQL instance with initial database name **`employee_db`**
   (Flyway creates the tables on the first application start).
2. Allow inbound **TCP 5432** on the RDS security group from the EKS node security group.
3. Put the RDS endpoint in `config/env-${ENV}.yaml` → `env.DB_HOST`.

**b) Store the DB credentials in Secrets Manager**

```bash
aws secretsmanager create-secret --region $REGION \
  --name enterprise-hr-portal/${ENV}/db \
  --secret-string '{"username":"<db-user>","password":"<db-password>"}'
```

The password exists only in Secrets Manager: never in Git, Jenkins or Helm values.

**c) Install the Secrets Store CSI driver and the AWS provider (once per cluster)**

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm repo update

# syncSecret.enabled=true lets the driver copy the values into a Kubernetes Secret
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system --set syncSecret.enabled=true

helm install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  -n kube-system
```

**d) IAM role for the application's ServiceAccount (IRSA)**

```bash
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve

cat > secrets-policy-${ENV}.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
    "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:enterprise-hr-portal/${ENV}/db-*"
  }]
}
EOF

aws iam create-policy --policy-name enterprise-hr-portal-${ENV}-secrets-policy \
  --policy-document file://secrets-policy-${ENV}.json

# --role-only: creates just the IAM role; the ServiceAccount itself comes from the Helm chart
eksctl create iamserviceaccount --cluster $CLUSTER --region $REGION \
  --namespace hr-portal-${ENV} --name enterprise-hr-portal \
  --role-name enterprise-hr-portal-${ENV}-secrets-role \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/enterprise-hr-portal-${ENV}-secrets-policy \
  --role-only --approve
```

Put `arn:aws:iam::<account-id>:role/enterprise-hr-portal-<env>-secrets-role` in
`environments/<env>/values.yaml` → `serviceAccount.roleArn`. Each role trusts exactly one
namespace + ServiceAccount pair, so the dev pods cannot read the prod secret and vice versa.

**e) metrics-server (needed by the HPA, once per cluster)**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl top nodes   # works after ~1 minute
```

**Rotating the password:** update the secret in Secrets Manager, then restart the pods with
`kubectl rollout restart deploy/enterprise-hr-portal -n hr-portal-<env>`.

### 9. Optional: ALB Ingress instead of a LoadBalancer Service

If the AWS Load Balancer Controller is installed, set in `environments/<env>/values.yaml`:

```yaml
service:
  type: ClusterIP
ingress:
  enabled: true
  host: "hr-dev.example.com"   # optional
```

## Create the Jenkins job

1. **New Item** → name `enterprise-hr-portal` → **Pipeline**.
2. **Pipeline → Definition**: *Pipeline script from SCM*.
3. **SCM**: Git, URL `https://github.com/srikanth78933/enterprise-hr-portal-deploy.git`, branch `*/main`.
4. **Script Path**: `Jenkinsfile` → **Save**.
5. Click **Build Now** once (Jenkins learns the `ENVIRONMENT` parameter and deploys to dev).
   After that, use **Build with Parameters** and choose `dev` or `prod`.

For `prod`, the pipeline pauses at **Approve Production**; click **Deploy** in the build page
(within 30 minutes) to continue.

## Open the application

```bash
kubectl get pods,svc,hpa,pdb -n hr-portal-dev
kubectl get svc enterprise-hr-portal -n hr-portal-dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open `http://<load-balancer-hostname>` in the browser (allow 2–3 minutes for the load balancer DNS).
Use `hr-portal-prod` for production.

## Pipeline stages

| Stage                    | What it does |
|--------------------------|--------------|
| Checkout Code            | Clones the application repository into `./app` |
| Maven Build & Test       | Sets version `1.0.<BUILD_NUMBER>`, runs `mvn clean package`, publishes JUnit results |
| SonarQube Analysis       | Sends code analysis to SonarQube (project key `enterprise-hr-portal`) |
| Quality Gate             | Fails the build if the SonarQube quality gate fails |
| Upload JAR to Nexus      | `mvn deploy` to `maven-releases` |
| Build Docker Image       | Builds `DOCKER_IMAGE:1.0.<BUILD_NUMBER>` from `app/target` |
| Trivy Image Scan         | Archives a HIGH/CRITICAL report; fails on fixable CRITICAL vulnerabilities |
| Push Image to Docker Hub | Pushes the image |
| Helm Package             | `helm lint` with the environment files + `helm package`, archives the chart `.tgz` |
| Approve Production       | Only for `prod`: waits for a manual approval |
| Deploy to EKS            | `helm upgrade --install` with the environment files, waits until the pods are ready |

## Useful commands

```bash
helm list -n hr-portal-dev                                       # deployed releases
helm history enterprise-hr-portal -n hr-portal-dev               # release history
helm rollback enterprise-hr-portal <revision> -n hr-portal-dev   # roll back
helm get values enterprise-hr-portal -n hr-portal-dev            # values used by the release
kubectl logs -n hr-portal-dev deploy/enterprise-hr-portal        # application logs

# Preview what an environment renders to, without deploying
helm template enterprise-hr-portal helm/enterprise-hr-portal \
  -f environments/prod/values.yaml -f config/env-prod.yaml
```

## Accepted vulnerabilities (`.trivyignore`)

Two Spring Framework 6.2 CVEs are fixed only in Spring Framework 7 (Spring Boot 4) and do not
apply to this application (it uses no `XsltView` and no Server-Sent Events). They are listed in
`.trivyignore` with the reason. Review the file whenever Spring Boot is upgraded.
