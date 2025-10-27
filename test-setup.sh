#!/bin/bash
# test-setup.sh - Setup and verify basic functionality
set -e

echo "🔵 Setting up Blue/Green deployment..."
echo "======================================"
echo "Nginx Config: 2s fail_timeout, 1s timeouts"
echo ""

# Make scripts executable
chmod +x entrypoint.sh test-failover.sh

# Stop any running services and start fresh
docker-compose down > /dev/null 2>&1 || true
docker-compose up -d

echo "Waiting for services to start..."
sleep 10  # Reduced from 15s due to faster timeouts

echo ""
echo "✅ Setup completed!"
echo ""
echo "🌐 Quick verification:"
echo "Nginx (8080): $(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/version || echo "DOWN")"
echo "Blue (8081):  $(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/version || echo "DOWN")"
echo "Green (8082): $(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/version || echo "DOWN")"

echo ""
echo "🚀 Run './test-failover.sh' to execute comprehensive failover tests"
echo "   Expected: 2-second failover with zero failed requests"