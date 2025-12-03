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

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -o alternative-ui .

# Runtime stage
FROM alpine:3.19

WORKDIR /app

# Add ca-certificates for HTTPS
RUN apk add --no-cache ca-certificates

# Copy binary from builder
COPY --from=builder /app/alternative-ui /app/alternative-ui

# Expose the default port
EXPOSE 19998

# Run the application
ENTRYPOINT ["/app/alternative-ui"]
CMD ["-addr", ":19998"]
