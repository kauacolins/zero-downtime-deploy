# Imagem de produção de uma aplicação Java com Maven (Spring Boot). Ajuste à vontade.
FROM maven:3.9-eclipse-temurin-{{JAVA_VERSAO}} AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -q -B dependency:go-offline
COPY src ./src
# Testes ficam no CI; aqui só empacota
RUN mvn -q -B package -DskipTests \
  && cp "$(ls target/*.jar | grep -v -- '-plain' | head -1)" /src/app.jar

FROM eclipse-temurin:{{JAVA_VERSAO}}-jre-alpine
WORKDIR /app
COPY --from=build /src/app.jar app.jar
# {{CRIAR_PASTAS_DOCKERFILE}}
ENV SERVER_PORT={{PORTA_APP}}
EXPOSE {{PORTA_APP}}
CMD ["java", "-jar", "app.jar"]
