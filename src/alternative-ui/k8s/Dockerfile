# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Install git for go mod download
RUN apk add --no-cache git

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the collector
RUN CGO_ENABLED=0 GOOS=linux go build -o k8s-collector .

# Runtime stage
FROM alpine:3.19

WORKDIR /app

# Add ca-certificates for HTTPS
RUN apk add --no-cache ca-certificates

# Copy binary from builder
COPY --from=builder /app/k8s-collector /app/k8s-collector

# Run as non-root user
RUN adduser -D -u 1000 collector
USER collector

ENTRYPOINT ["/app/k8s-collector"]
