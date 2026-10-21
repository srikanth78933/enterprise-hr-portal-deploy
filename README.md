# Enterprise HR Portal – Deployment

Jenkins CI/CD pipeline, Dockerfile and Helm chart that build and deploy
[Enterprise HR Portal](https://github.com/srikanth78933/Enterprise-HR-Management-System) to AWS EKS,
for the **dev** and **prod** environments. The AWS infrastructure (VPC, EKS, RDS, IRSA roles,
cluster add-ons) comes from [enterprise-hr-portal-infra](https://github.com/srikanth78933/enterprise-hr-portal-infra).

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
        ├── service.yaml              ClusterIP Service behind the ALB
        ├── hpa.yaml                  Autoscaling on CPU/memory
        ├── pdb.yaml                  Keeps pods available during node drains
        ├── ingress.yaml              Internet-facing ALB (optional HTTPS and WAF)
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
| Pods (HPA min–max)     | 3–4                              | 3–6                               |
| PodDisruptionBudget    | minAvailable 1                   | minAvailable 1                    |
| CPU / memory requests  | 200m / 512Mi                     | 500m / 768Mi                      |
| Secrets Manager secret | `enterprise-hr-portal/dev/db`    | `enterprise-hr-portal/prod/db`    |
| Log level (app)        | DEBUG                            | INFO                              |
| Deploy approval        | automatic                        | manual approval in Jenkins        |

Each build uses one version everywhere: **`1.0.<BUILD_NUMBER>`** → JAR version in Nexus,
Docker image tag, Helm chart version and app version.

## Current settings

These values are already set in this repository. Terraform prints the AWS ones with
`terraform output deploy_repo_values` (infra repo); update them if you recreate the
infrastructure in another account or region.

| File                              | Value                    | Current setting |
|-----------------------------------|--------------------------|-----------------|
| `Jenkinsfile`                     | `NEXUS_URL`              | `http://13.203.97.33:8081` (repository `maven-releases`) |
| `Jenkinsfile`                     | `DOCKER_IMAGE`           | `devopstraining064/hr-portal` |
| `Jenkinsfile`                     | `AWS_REGION`             | `ap-south-1` |
| `Jenkinsfile`                     | Tools                    | Maven `maven3.10.0`, JDK `java21` |
| `config/env-dev.yaml`             | `env.DB_HOST`            | `enterprise-hr-portal-dev.c58yuau4wywi.ap-south-1.rds.amazonaws.com` |
| `config/env-prod.yaml`            | `env.DB_HOST`            | `enterprise-hr-portal-prod.c58yuau4wywi.ap-south-1.rds.amazonaws.com` |
| `environments/<env>/values.yaml`  | `serviceAccount.roleArn` | `arn:aws:iam::476079000065:role/enterprise-hr-portal-<env>-secrets-role` |
| `environments/prod/values.yaml`   | `ingress.wafAclArn`      | empty; set it to Terraform output `waf_web_acl_arn` (changes each time prod is recreated) |
| `environments/<env>/values.yaml`  | `ingress.certificateArn` | empty (HTTP only); set an ACM certificate ARN for HTTPS |

`EKS_CLUSTER` (`mycompany-<env>-eks`) and the secret name (`enterprise-hr-portal/<env>/db`)
match the infra repo. RDS endpoints and role ARNs stay the same when an environment is
destroyed and recreated in the same account and region.

## One-time setup

### 1. Tools on the Jenkins server (Ubuntu)

The Jenkins server needs at least **30 GB of disk** (Docker images, the Trivy database, Maven
and Terraform caches). The same server also runs the infra pipeline (Terraform) and the
monitoring pipeline (`jq`).

```bash
# Base packages, Java 21, Docker (and allow Jenkins to use it)
sudo apt update
sudo apt install -y docker.io unzip curl wget gnupg jq openjdk-21-jdk
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

# kubectl (same minor version as the EKS cluster, 1.35)
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable-1.35.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl

# Terraform (infra pipeline)
curl -fsSLo /tmp/terraform.zip https://releases.hashicorp.com/terraform/1.13.4/terraform_1.13.4_linux_amd64.zip
sudo unzip -o /tmp/terraform.zip -d /usr/local/bin && rm /tmp/terraform.zip

sudo systemctl restart jenkins
```

Check as the `jenkins` user:
`sudo -u jenkins bash -c 'cd /tmp; docker ps >/dev/null && trivy --version && helm version && aws --version && kubectl version --client && terraform version && jq --version'`

If `apt` reports *Could not get lock /var/lib/dpkg/lock-frontend*, the automatic security updates of a
new instance are still running: wait until they finish (`sudo fuser /var/lib/dpkg/lock-frontend`), run
`sudo dpkg --configure -a`, then repeat the command. If Jenkins does not start after several quick restarts
(*start-limit-hit*), run `sudo systemctl reset-failed jenkins && sudo systemctl start jenkins`.

### 2. Jenkins plugins

Install from **Manage Jenkins → Plugins**: *Pipeline*, *Git*, *SonarQube Scanner*,
*Docker Pipeline*, *Credentials Binding*, *JUnit* (most come with the suggested plugins).

### 3. Jenkins tools

**Manage Jenkins → Tools**:

| Tool  | Name (must match the Jenkinsfile) |
|-------|-----------------------------------|
| JDK   | `java21` (JAVA_HOME `/usr/lib/jvm/java-21-openjdk-amd64`) |
| Maven | `maven3.10.0` (Install automatically, Maven 3.10.0) |

If you name the tools differently, change the `tools { }` block in the `Jenkinsfile`; a mismatch fails
the build at once with *Tool type "maven" does not have an install of …*.

### 4. Jenkins credentials

**Manage Jenkins → Credentials → (global) → Add credentials**:

| ID                      | Kind                | Value |
|-------------------------|---------------------|-------|
| `nexus-credentials`     | Username/password   | Nexus user that can deploy to `maven-releases` |
| `dockerhub-credentials` | Username/password   | Docker Hub username + access token |
| `AWS_ACCESS_KEY_ID`     | Secret text         | Access key of the IAM user used for EKS |
| `AWS_SECRET_ACCESS_KEY` | Secret text         | Secret key of the same IAM user |
| `sonar-token`           | Secret text         | SonarQube user token (My Account → Security) |

### 5. SonarQube

1. **Manage Jenkins → System → SonarQube servers → Add**:
   name **`sonarqube`**, URL `http://15.252.238.226:9000`, token `sonar-token`.
2. In SonarQube (as admin): **Administration → Configuration → Webhooks → Create**:
   URL `http://65.0.177.168:8080/sonarqube-webhook/`.
   The *Quality Gate* stage waits for this webhook; without it the stage times out after 5 minutes.
3. The default *Sonar way* quality gate requires **80% test coverage on new code**. The app produces
   a JaCoCo coverage report during `mvn package`, so new code needs unit tests to pass the gate.

### 6. Nexus

The pipeline uploads to the default **`maven-releases`** repository
(`<NEXUS_URL>/repository/maven-releases/`). Release repositories reject the same version twice,
which is why each build gets its own `1.0.<BUILD_NUMBER>` version.

### 7. Infrastructure (Terraform)

Everything on the AWS side is created by
[enterprise-hr-portal-infra](https://github.com/srikanth78933/enterprise-hr-portal-infra),
once per environment:

| Created by Terraform                                   | Used here for |
|--------------------------------------------------------|---------------|
| VPC with frontend / compute / data subnets             | ALB, pods, RDS |
| EKS cluster `mycompany-<env>-eks` + node group         | Jenkins deploy target |
| EKS access entry for the Jenkins IAM user (`cluster_admin_arns`) | `helm upgrade` from Jenkins |
| RDS PostgreSQL + secret `enterprise-hr-portal/<env>/db` | `DB_HOST`, `DB_USERNAME`, `DB_PASSWORD` |
| IRSA role `enterprise-hr-portal-<env>-secrets-role`    | `serviceAccount.roleArn` |
| AWS Load Balancer Controller                           | Creates the ALB from `ingress.yaml` |
| Secrets Store CSI driver + AWS provider                | `secretproviderclass.yaml` |
| metrics-server, Cluster Autoscaler                     | `hpa.yaml`, extra nodes when pods don't fit |
| WAF web ACL (prod)                                     | `ingress.wafAclArn` |

```bash
cd enterprise-hr-portal-infra/environments/dev   # or prod
terraform init && terraform apply
terraform output deploy_repo_values              # copy these into this repo (table above)
```

The IRSA role trusts exactly namespace `hr-portal-<env>` and ServiceAccount `enterprise-hr-portal`
(the Helm release name). Keep those names as they are.

**Before destroying an environment**, run `helm uninstall enterprise-hr-portal -n hr-portal-<env>`
so the AWS Load Balancer Controller deletes the ALB; otherwise the VPC cannot be removed.

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
kubectl get pods,svc,ingress,hpa,pdb -n hr-portal-dev
kubectl get ingress enterprise-hr-portal -n hr-portal-dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open `http://<alb-hostname>` in the browser (the ALB takes 2–3 minutes to become reachable after
the first deploy). With `ingress.certificateArn` set, use `https://` and point your domain's
Route 53 alias record at the ALB. Use `hr-portal-prod` for production.

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

## Troubleshooting

Problems met while setting up this pipeline, and their fixes:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `couldn't find remote ref refs/heads/master` | Job branch set to `*/master` | Branch specifier `*/main` |
| `Tool type "maven" does not have an install of …` | Tool name in Jenkins differs from the Jenkinsfile | Use the same name in **Tools** and in `tools { }` |
| Quality Gate `ERROR` with *Coverage on new code 0%* | New code without tests (or no coverage report) | Add unit tests; the app's JaCoCo plugin reports coverage |
| Quality Gate stage waits 5 minutes, then fails | SonarQube webhook to Jenkins missing | Create the webhook (setup step 5) and allow port 8080 from SonarQube |
| Trivy: `failed to download Java DB … no space left on device` | `/tmp` is a small RAM disk on Ubuntu 25.04+ | The Jenkinsfile sets `TMPDIR` to the workspace (already done) |
| Builds fail with `no space left on device` | Jenkins disk too small | Grow the EBS volume to 30 GB+, then `growpart` + `resize2fs`; clean with `docker system prune -af` |
| `Upload JAR to Nexus` 401 | `nexus-credentials` missing or wrong | Add the credential (setup step 4) |
| First build has no **Build with Parameters** | Jenkins reads the parameters on the first run | Run **Build Now** once (it deploys to dev) |
| App pods `CreateContainerConfigError` about the secret | The CSI driver could not read Secrets Manager | Check `serviceAccount.roleArn` and that the infra repo created the IRSA role |
| Kibana / app URL stops loading | ALB recreated (new DNS name) or your IP changed | `kubectl get ingress -n hr-portal-<env>`; update `kibana_allowed_cidrs` in the infra repo |
