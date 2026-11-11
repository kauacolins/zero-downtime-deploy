# Java com Maven

Para aplicações Java com Maven (Spring Boot). O `scaffold.sh` sugere esta stack quando o repositório tem `pom.xml`, e lê a versão do Java do `<java.version>` (padrão 21).

- A porta vem de `SERVER_PORT` (padrão 8080).
- Rota de saúde: `/actuator/health`, do Spring Boot Actuator. Sem ele, crie uma rota que responda `200` e use `--health`.
- Migração: com Flyway ou Liquibase, ela roda sozinha quando a aplicação sobe. Para isso, as migrações precisam servir às duas versões durante a troca.
