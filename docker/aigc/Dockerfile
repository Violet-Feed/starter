FROM maven:3.8-openjdk-8-slim AS build
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -DskipTests -B && \
    JAR=$(ls target/*.jar | grep -v original | head -1) && \
    cp "$JAR" app.jar

FROM openjdk:8-jre-slim
WORKDIR /app
RUN mkdir -p /app/config
COPY --from=build /build/app.jar app.jar

EXPOSE 3005

ENTRYPOINT ["java", "-jar", "app.jar"]