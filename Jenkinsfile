// CI/CD pipeline for Enterprise HR Portal
// Flow: Git -> Maven -> SonarQube -> Nexus -> Docker image -> Trivy -> Docker Hub -> Helm package -> EKS
pipeline {
    agent any

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'prod'], description: 'Environment to deploy to')
    }

    tools {
        maven 'maven3.10.0'
        jdk 'java21'
    }

    environment {
        // Application source code
        APP_REPO      = 'https://github.com/srikanth78933/Enterprise-HR-Management-System.git'
        APP_BRANCH    = 'main'
        APP_NAME      = 'enterprise-hr-portal'
        APP_VERSION   = "1.0.${env.BUILD_NUMBER}"

        // Nexus server (repository maven-releases)
        NEXUS_URL     = 'http://13.203.97.33:8081'

        // Docker Hub image
        DOCKER_IMAGE  = 'devopstraining064/hr-portal'

        // EKS: one cluster and namespace per environment
        EKS_CLUSTER   = "mycompany-${params.ENVIRONMENT}-eks"
        AWS_REGION    = 'ap-south-1'
        K8S_NAMESPACE = "hr-portal-${params.ENVIRONMENT}"

        // Helm values: global chart defaults + environment overrides + environment variables
        HELM_VALUES   = "-f environments/${params.ENVIRONMENT}/values.yaml -f config/env-${params.ENVIRONMENT}.yaml"
        AWS_ACCESS_KEY_ID     = credentials('AWS_ACCESS_KEY_ID')
        AWS_SECRET_ACCESS_KEY = credentials('AWS_SECRET_ACCESS_KEY')
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
    }

    stages {
        stage('Checkout Code') {
            steps {
                // This deploy repo is already checked out by Jenkins; the application code goes into ./app
                dir('app') {
                    git branch: "${APP_BRANCH}", url: "${APP_REPO}"
                }
            }
        }

        stage('Maven Build & Test') {
            steps {
                dir('app') {
                    sh 'mvn versions:set -DnewVersion=$APP_VERSION -DgenerateBackupPoms=false'
                    sh 'mvn clean package'
                }
            }
            post {
                always {
                    junit 'app/target/surefire-reports/*.xml'
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                dir('app') {
                    withSonarQubeEnv('sonarqube') {
                        sh '''
                            mvn org.sonarsource.scanner.maven:sonar-maven-plugin:5.8.0.7211:sonar \
                                -Dsonar.projectKey=$APP_NAME \
                                -Dsonar.projectName="Enterprise HR Portal" \
                                -Dsonar.projectVersion=$APP_VERSION
                        '''
                    }
                }
            }
        }

        stage('Quality Gate') {
            steps {
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Upload JAR to Nexus') {
            steps {
                dir('app') {
                    withCredentials([usernamePassword(credentialsId: 'nexus-credentials', usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASS')]) {
                        sh '''
                            mvn deploy -DskipTests -s ../maven-settings.xml \
                                -DaltDeploymentRepository=nexus-releases::$NEXUS_URL/repository/maven-releases/
                        '''
                    }
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                // Build context is app/target, which contains enterprise-hr-portal.jar
                sh 'docker build -t $DOCKER_IMAGE:$APP_VERSION -f Dockerfile app/target'
            }
        }

        stage('Trivy Image Scan') {
            steps {
                sh '''
                    # Trivy downloads its vulnerability databases (~1 GB) through a temp folder.
                    # /tmp can be a small RAM disk (Ubuntu 25.04+), so use the workspace disk instead.
                    export TMPDIR="$WORKSPACE/.trivy-tmp"
                    mkdir -p "$TMPDIR"

                    # Full report of HIGH and CRITICAL vulnerabilities (does not fail the build)
                    trivy image --no-progress --severity HIGH,CRITICAL --exit-code 0 \
                        --output trivy-report.txt $DOCKER_IMAGE:$APP_VERSION
                    cat trivy-report.txt

                    # Fail the build if there are CRITICAL vulnerabilities that have a fix available
                    trivy image --no-progress --severity CRITICAL --ignore-unfixed --exit-code 1 \
                        $DOCKER_IMAGE:$APP_VERSION
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Push Image to Docker Hub') {
            steps {
                withDockerRegistry(credentialsId: 'dockerhub-credentials', url: 'https://index.docker.io/v1/') {
                    sh 'docker push $DOCKER_IMAGE:$APP_VERSION'
                }
            }
        }

        stage('Helm Package') {
            steps {
                sh '''
                    rm -rf helm-packages
                    helm lint helm/$APP_NAME $HELM_VALUES
                    helm package helm/$APP_NAME --version $APP_VERSION --app-version $APP_VERSION -d helm-packages
                '''
                archiveArtifacts artifacts: 'helm-packages/*.tgz'
            }
        }

        stage('Approve Production') {
            when {
                expression { params.ENVIRONMENT == 'prod' }
            }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Deploy ${APP_NAME} ${APP_VERSION} to PRODUCTION?", ok: 'Deploy'
                }
            }
        }

        stage('Deploy to EKS') {
            steps {
                sh '''
                    aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER

                    helm upgrade --install $APP_NAME helm-packages/$APP_NAME-$APP_VERSION.tgz \
                        --namespace $K8S_NAMESPACE --create-namespace \
                        $HELM_VALUES \
                        --set image.repository=$DOCKER_IMAGE \
                        --set image.tag=$APP_VERSION \
                        --set secrets.region=$AWS_REGION \
                        --wait --timeout 10m

                    kubectl get pods,svc,hpa,pdb -n $K8S_NAMESPACE
                '''
            }
        }
    }

    post {
        always {
            // Remove the local image so the Jenkins disk does not fill up
            sh 'docker rmi $DOCKER_IMAGE:$APP_VERSION || true'
        }
        success {
            echo "Deployed ${APP_NAME} version ${APP_VERSION} to ${params.ENVIRONMENT} (cluster ${EKS_CLUSTER}, namespace ${K8S_NAMESPACE})"
        }
        failure {
            echo 'Pipeline failed. Check the stage logs above.'
        }
    }
}
