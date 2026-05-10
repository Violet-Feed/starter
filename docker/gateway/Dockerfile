FROM maven:3.8.8-eclipse-temurin-8 AS build

RUN mkdir -p /usr/share/maven/conf && \
    cat > /usr/share/maven/conf/settings.xml <<'EOF'
<settings>
  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>*</mirrorOf>
      <name>Aliyun Maven</name>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
EOF

WORKDIR /build
COPY pom.xml .

RUN --mount=type=cache,target=/root/.m2 \
    mvn dependency:go-offline -B -Dmaven.repo.local=/root/.m2/repository

COPY src ./src

RUN --mount=type=cache,target=/root/.m2 \
    mvn package -DskipTests -B -Dmaven.repo.local=/root/.m2/repository && \
    JAR=$(ls target/*.jar | grep -v original | head -1) && \
    cp "$JAR" app.jar

FROM amazoncorretto:8-al2023-jre

WORKDIR /app
RUN mkdir -p /app/config
COPY --from=build /build/app.jar app.jar

EXPOSE 3000 3001 3002
ENV JAVA_OPTS=""
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]