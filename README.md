# Blue/Green Deployment with Nginx Server

This project implements a Blue/Green deployment strategy for Node.js applications using Nginx as a load balancer with automatic failover.

## Architecture

- **Nginx**: Reverse proxy and load balancer (port 8080)
- **Blue App**: Primary application instance (port 8081)
- **Green App**: Backup application instance (port 8082)

## Features

- Automatic failover from Blue to Green on failure
- Zero downtime during failover
- Health-based routing
- Header forwarding for pool identification

## Setup and Run

1. Clone this repository
2. Edit my .env file
3. Run the application:
```bash
docker-compose up --build
```

## Testing

### Normal Operation
```bash
curl http://localhost:8080/version
```

Expected: 200 OK with `X-App-Pool: blue` header

### Test Failover
1. Trigger chaos on Blue:
```bash
curl -X POST http://localhost:8081/chaos/start?mode=error
```

2. Make requests through Nginx:
```bash
curl http://localhost:8080/version
```

Expected: 200 OK with `X-App-Pool: green` header

3. Stop chaos:
```bash
curl -X POST http://localhost:8081/chaos/stop
```

## Configuration

All configuration is done via the `.env` file:

- `BLUE_IMAGE`: Docker image for Blue instance
- `GREEN_IMAGE`: Docker image for Green instance
- `ACTIVE_POOL`: Active pool (blue or green)
- `RELEASE_ID_BLUE`: Release identifier for Blue
- `RELEASE_ID_GREEN`: Release identifier for Green
- `PORT`: Application port (default 8080)

## This is how it will work

1. All traffic initially goes to Blue (primary)
2. Nginx monitors Blue with health checks
3. On Blue failure (timeout or 5xx), Nginx automatically retries to Green
4. Client receives successful response without knowing about the failure
5. After 30 seconds, Nginx tries Blue again and like that like that

## Failover Configuration

- **Timeout**: 2 seconds
- **Max Fails**: 1 attempt
- **Fail Timeout**: 30 seconds
- **Retry Policy**: error, timeout, http_500, http_502, http_503, http_504