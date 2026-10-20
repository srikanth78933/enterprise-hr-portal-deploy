# Runtime image for Enterprise HR Portal.
# Jenkins builds the JAR first, then runs:  docker build -f Dockerfile app/target
FROM eclipse-temurin:21-jre-alpine

WORKDIR /app

# Run as a non-root user (numeric UID so Kubernetes runAsNonRoot can verify it)
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app app

COPY enterprise-hr-portal.jar /app/app.jar

USER 10001:10001

# Let the JVM size its heap from the container memory limit
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0"

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
