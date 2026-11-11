# Imagem de produção de uma aplicação Go. Ajuste à vontade.
FROM golang:{{GO_VERSAO}}-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
# Pacote main da aplicação (o scaffold.sh acha o main.go)
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app {{GO_MAIN}}

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=build /out/app /app/app
# {{CRIAR_PASTAS_DOCKERFILE}}
ENV PORT={{PORTA_APP}}
EXPOSE {{PORTA_APP}}
CMD ["/app/app"]
