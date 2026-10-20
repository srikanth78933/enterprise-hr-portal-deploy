# Enterprise HR Portal – Deployment

Jenkins CI/CD pipeline, Dockerfile and Helm chart that build and deploy
[Enterprise HR Portal](https://github.com/srikanth78933/Enterprise-HR-Management-System) to AWS EKS.

```
Git ─► Maven (build + tests) ─► SonarQube (+ quality gate) ─► Nexus (JAR)
    ─► Docker image ─► Trivy scan ─► Docker Hub ─► Helm package ─► EKS
```

## Repository contents

```
enterprise-hr-portal-deploy/
├── Jenkinsfile                 Declarative pipeline (all stages above)
├── Dockerfile                  Runtime image (Java 21 JRE, non-root user)
├── maven-settings.xml          Nexus credentials read from environment variables
├── .trivyignore                Reviewed/accepted CVEs with reasons
└── helm/enterprise-hr-portal/  Helm chart
    ├── Chart.yaml
    ├── values.yaml
    └── templates/              deployment.yaml, service.yaml, _helpers.tpl, NOTES.txt
```

Each build uses one version everywhere: **`1.0.<BUILD_NUMBER>`** → JAR version in Nexus,
Docker image tag, Helm chart version and app version.

## Values to change before the first run

Edit the `environment` block at the top of the `Jenkinsfile`:

| Variable       | Set it to |
|----------------|-----------|
| `NEXUS_URL`    | `http://<nexus-ec2-ip>:8081` |
| `DOCKER_IMAGE` | `<your-dockerhub-user>/enterprise-hr-portal` |
| `EKS_CLUSTER`  | Your EKS cluster name |
| `AWS_REGION`   | Region of the EKS cluster |

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

### 7. EKS access for the Jenkins IAM user

```bash
aws eks create-access-entry --cluster-name <cluster> --region <region> \
  --principal-arn arn:aws:iam::<account-id>:user/<jenkins-iam-user>

aws eks associate-access-policy --cluster-name <cluster> --region <region> \
  --principal-arn arn:aws:iam::<account-id>:user/<jenkins-iam-user> \
  --policy-arn arn:aws:eks::aws:policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

### 8. Database (AWS RDS PostgreSQL) and Kubernetes Secret

1. Create an RDS PostgreSQL instance with initial database name **`employee_db`**.
2. Allow inbound **TCP 5432** on the RDS security group from the EKS node security group.
3. Create the namespace and the database Secret once (Flyway creates the tables on first start):

```bash
kubectl create namespace hr-portal

kubectl create secret generic enterprise-hr-portal-db -n hr-portal \
  --from-literal=DB_HOST=<rds-endpoint>.rds.amazonaws.com \
  --from-literal=DB_PORT=5432 \
  --from-literal=DB_NAME=employee_db \
  --from-literal=DB_USERNAME=<db-user> \
  --from-literal=DB_PASSWORD='<db-password>'
```

The password lives only in this Secret, never in Git or Jenkins.

## Create the Jenkins job

1. **New Item** → name `enterprise-hr-portal` → **Pipeline**.
2. **Pipeline → Definition**: *Pipeline script from SCM*.
3. **SCM**: Git, URL `https://github.com/srikanth78933/enterprise-hr-portal-deploy.git`, branch `*/main`.
4. **Script Path**: `Jenkinsfile` → **Save** → **Build Now**.

Jenkins checks out this repository, then the pipeline checks out the application code into `./app`.

## Open the application

```bash
kubectl get pods,svc -n hr-portal
kubectl get svc enterprise-hr-portal -n hr-portal -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open `http://<load-balancer-hostname>` in the browser (allow 2–3 minutes for the load balancer DNS).

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
| Helm Package             | `helm lint` + `helm package`, archives the chart `.tgz` |
| Deploy to EKS            | `helm upgrade --install` and waits until the pods are ready |

## Useful commands

```bash
helm list -n hr-portal                                  # deployed releases
helm history enterprise-hr-portal -n hr-portal          # release history
helm rollback enterprise-hr-portal <revision> -n hr-portal
kubectl logs -n hr-portal deploy/enterprise-hr-portal   # application logs
```

## Accepted vulnerabilities (`.trivyignore`)

Two Spring Framework 6.2 CVEs are fixed only in Spring Framework 7 (Spring Boot 4) and do not
apply to this application (it uses no `XsltView` and no Server-Sent Events). They are listed in
`.trivyignore` with the reason. Review the file whenever Spring Boot is upgraded.
