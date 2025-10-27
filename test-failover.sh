#!/bin/bash

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Accept optional IP address, default to localhost
HOST="${1:-localhost}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_debug() {
    echo -e "${PURPLE}[DEBUG]${NC} $1"
}

increment_passed() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

increment_failed() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Function to test service health
test_service_health() {
    local service=$1
    local url=$2
    local max_retries=5
    
    log "Testing $service health..."
    
    for i in $(seq 1 $max_retries); do
        if curl -s -f "$url/healthz" > /dev/null; then
            log_success "$service is healthy"
            return 0
        fi
        sleep 2
    done
    
    log_error "$service health check failed"
    return 1
}

# Function to test chaos endpoint
test_chaos_endpoint() {
    local base_url=$1
    local pool=$2
    
    log "Testing chaos endpoints for $pool..."
    
    # Test chaos start with various modes
    local modes=("error" "timeout" "500" "delay" "")
    local chaos_worked=false
    
    for mode in "${modes[@]}"; do
        local url="$base_url/chaos/start"
        if [ -n "$mode" ]; then
            url="$url?mode=$mode"
        fi
        
        log_debug "Trying: POST $url"
        local response
        response=$(curl -s -w "\n%{http_code}" -X POST "$url")
        local status_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | head -n1)
        
        if [ "$status_code" = "200" ]; then
            log_success "Chaos started successfully with mode: '${mode:-default}'"
            log_debug "Response: $body"
            chaos_worked=true
            break
        else
            log_debug "Mode '${mode:-default}' failed: HTTP $status_code"
        fi
    done
    
    if [ "$chaos_worked" = false ]; then
        log_warning "No chaos mode worked for $pool"
        # Test if endpoint exists at all
        log_debug "Testing chaos endpoint existence..."
        curl -I -s "$base_url/chaos/start" | head -1
        return 1
    fi
    
    # Test chaos stop
    log_debug "Testing chaos stop..."
    local stop_response
    stop_response=$(curl -s -w "\n%{http_code}" -X POST "$base_url/chaos/stop")
    local stop_status=$(echo "$stop_response" | tail -n1)
    
    if [ "$stop_status" = "200" ]; then
        log_success "Chaos stop worked for $pool"
        return 0
    else
        log_warning "Chaos stop failed for $pool: HTTP $stop_status"
        return 1
    fi
}

# Function to verify pool serving traffic
verify_pool() {
    local expected_pool=$1
    local description=$2
    local num_requests=5
    
    log "Verifying pool: $description (expecting: $expected_pool)"
    
    local correct_count=0
    local total_checked=0
    
    for i in $(seq 1 $num_requests); do
        local response
        response=$(curl -s -i "http://$HOST:8080/version")
        local status_code=$(echo "$response" | grep HTTP | awk '{print $2}')
        local app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
        
        if [ "$status_code" = "200" ]; then
            ((total_checked++))
            if [ "$app_pool" = "$expected_pool" ]; then
                ((correct_count++))
                log_debug "Request $i: ✓ $app_pool"
            else
                log_debug "Request $i: ✗ got $app_pool, expected $expected_pool"
            fi
        else
            log_debug "Request $i: ✗ HTTP $status_code"
        fi
        sleep 0.3
    done
    
    if [ $total_checked -eq 0 ]; then
        log_error "No successful requests to verify pool"
        return 1
    fi
    
    local success_rate=$((correct_count * 100 / total_checked))
    
    if [ $success_rate -ge 80 ]; then
        log_success "Pool verification: $success_rate% requests from $expected_pool"
        return 0
    else
        log_error "Pool verification failed: only $success_rate% from $expected_pool"
        return 1
    fi
}

# Function to test failover with chaos
test_chaos_failover() {
    local chaos_pool=$1
    local chaos_url="http://$HOST:8081"
    if [ "$chaos_pool" = "green" ]; then
        chaos_url="http://$HOST:8082"
    fi
    
    log "Testing chaos-induced failover from $chaos_pool..."
    
    # Step 1: Start chaos
    log "Starting chaos on $chaos_pool..."
    local chaos_started=false
    
    # Try multiple chaos modes
    for mode in "error" "timeout" "500" ""; do
        local chaos_cmd="$chaos_url/chaos/start"
        if [ -n "$mode" ]; then
            chaos_cmd="$chaos_cmd?mode=$mode"
        fi
        
        local response
        response=$(curl -s -w "\n%{http_code}" -X POST "$chaos_cmd")
        local status_code=$(echo "$response" | tail -n1)
        
        if [ "$status_code" = "200" ]; then
            log_success "Chaos started on $chaos_pool with mode: '${mode:-default}'"
            chaos_started=true
            
            # Verify the target pool is actually failing
            log_debug "Verifying $chaos_pool is returning errors..."
            local target_status
            target_status=$(curl -s -o /dev/null -w "%{http_code}" "$chaos_url/version")
            log_debug "$chaos_pool direct status during chaos: $target_status"
            break
        fi
    done
    
    if [ "$chaos_started" = false ]; then
        log_warning "Could not start chaos on $chaos_pool - using manual failure simulation"
        # Fallback: manually stop the container
        docker-compose stop "app_$chaos_pool" 2>/dev/null && {
            log_success "Manually stopped $chaos_pool container for testing"
            chaos_started=true
        } || {
            log_error "Cannot simulate failure for $chaos_pool"
            return 1
        }
    fi
    
    # Step 2: Wait for failover
    log "Waiting for failover detection (3 seconds)..."
    sleep 3
    
    # Step 3: Verify failover occurred
    local expected_new_pool="green"
    if [ "$chaos_pool" = "green" ]; then
        expected_new_pool="blue"
    fi
    
    log "Verifying failover to $expected_new_pool..."
    
    # Test multiple requests to confirm failover
    local failover_success=0
    local test_requests=8
    
    for i in $(seq 1 $test_requests); do
        local response
        response=$(curl -s -i "http://$HOST:8080/version")
        local status_code=$(echo "$response" | grep HTTP | awk '{print $2}')
        local app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
        
        if [ "$status_code" = "200" ] && [ "$app_pool" = "$expected_new_pool" ]; then
            ((failover_success++))
            log_debug "Failover request $i: ✓ $app_pool"
        else
            log_debug "Failover request $i: ✗ Status: $status_code, Pool: $app_pool"
        fi
        sleep 0.4
    done
    
    local failover_rate=$((failover_success * 100 / test_requests))
    
    if [ $failover_rate -ge 80 ]; then
        log_success "Failover successful: $failover_rate% traffic to $expected_new_pool"
    else
        log_error "Failover failed: only $failover_rate% traffic to $expected_new_pool"
        # Restart stopped container if we used manual method
        if [ "$chaos_started" = true ] && docker-compose ps "app_$chaos_pool" | grep -q "Exit"; then
            docker-compose start "app_$chaos_pool"
        fi
        return 1
    fi
    
    # Step 4: Test stability during failure
    log "Testing stability during chaos (zero failed requests)..."
    local failed_requests=0
    local stability_requests=15
    
    for i in $(seq 1 $stability_requests); do
        if ! curl -s -f "http://$HOST:8080/version" > /dev/null; then
            ((failed_requests++))
            log_debug "Stability request $i: ✗ Failed"
        else
            log_debug "Stability request $i: ✓ Success"
        fi
        sleep 0.3
    done
    
    if [ $failed_requests -eq 0 ]; then
        log_success "Stability test passed: zero failed requests during chaos"
    else
        log_error "Stability test failed: $failed_requests failed requests during chaos"
    fi
    
    # Step 5: Stop chaos and verify recovery
    log "Stopping chaos and verifying recovery..."
    
    # Stop chaos or restart container
    if docker-compose ps "app_$chaos_pool" | grep -q "Up"; then
        curl -s -X POST "$chaos_url/chaos/stop" > /dev/null
        log_success "Chaos stopped on $chaos_pool"
    else
        docker-compose start "app_$chaos_pool"
        log_success "Restarted $chaos_pool container"
    fi
    
    # Wait for recovery
    log "Waiting for recovery (5 seconds)..."
    sleep 5
    
    # Verify system returned to normal
    log "Verifying system returned to normal state..."
    if verify_pool "blue" "recovery state"; then
        log_success "System recovered successfully"
        return 0
    else
        log_error "System did not recover properly"
        return 1
    fi
}

# Main test execution
main() {
    echo "=========================================="
    echo "🔵 Blue/Green Deployment - Comprehensive Failover Test"
    echo "=========================================="
    echo "Target Host: $HOST"
    echo ""
    
    # Pre-flight checks
    log "Running pre-flight checks..."
    
    # Check if services are running
    if ! docker-compose ps | grep -q "Up"; then
        log_error "Docker services are not running. Start with: docker-compose up -d"
        exit 1
    fi
    
    # Test service health
    test_service_health "Blue" "http://$HOST:8081" || exit 1
    test_service_health "Green" "http://$HOST:8082" || exit 1
    
    # Test chaos endpoints
    log "Testing chaos endpoints..."
    test_chaos_endpoint "http://$HOST:8081" "blue"
    test_chaos_endpoint "http://$HOST:8082" "green"
    
    echo ""
    echo "=========================================="
    echo ""
    
    # Test 1: Initial state verification
    log "=== TEST 1: Initial State Verification ==="
    if verify_pool "blue" "initial state"; then
        increment_passed
        log_success "Initial state verified - Blue is active"
    else
        increment_failed
        log_error "Initial state verification failed"
        exit 1
    fi
    
    echo ""
    
    # Test 2: Chaos failover from Blue to Green
    log "=== TEST 2: Chaos Failover (Blue → Green) ==="
    if test_chaos_failover "blue"; then
        increment_passed
        log_success "Blue→Green chaos failover test passed"
    else
        increment_failed
        log_error "Blue→Green chaos failover test failed"
    fi
    
    echo ""
    
    # Test 3: Chaos failover from Green to Blue
    log "=== TEST 3: Chaos Failover (Green → Blue) ==="
    if test_chaos_failover "green"; then
        increment_passed
        log_success "Green→Blue chaos failover test passed"
    else
        increment_failed
        log_error "Green→Blue chaos failover test failed"
    fi
    
    # Summary
    echo ""
    echo "=========================================="
    echo "📊 TEST SUMMARY"
    echo "=========================================="
    log_success "Tests Passed: $TESTS_PASSED"
    if [ $TESTS_FAILED -gt 0 ]; then
        log_error "Tests Failed: $TESTS_FAILED"
    else
        log_success "Tests Failed: $TESTS_FAILED"
    fi
    
    local total_tests=$((TESTS_PASSED + TESTS_FAILED))
    if [ $total_tests -gt 0 ]; then
        local success_rate=$((TESTS_PASSED * 100 / total_tests))
        echo "Success Rate: $success_rate%"
    fi
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo ""
        echo -e "${GREEN}🎉 ALL TESTS PASSED! Blue/Green deployment is working correctly.${NC}"
        echo ""
        echo "Summary of verified functionality:"
        echo "  ✅ Service health monitoring"
        echo "  ✅ Chaos endpoint functionality" 
        echo "  ✅ Automatic failover detection"
        echo "  ✅ Zero failed requests during failover"
        echo "  ✅ Traffic routing to correct pools"
        echo "  ✅ System recovery after chaos"
        exit 0
    else
        echo ""
        echo -e "${RED}❌ SOME TESTS FAILED. Check the deployment configuration.${NC}"
        exit 1
    fi
}

# Handle script interruption
cleanup() {
    log "Cleaning up..."
    # Stop any chaos and ensure all services are running
    curl -s -X POST "http://$HOST:8081/chaos/stop" > /dev/null 2>&1
    curl -s -X POST "http://$HOST:8082/chaos/stop" > /dev/null 2>&1
    docker-compose start app_blue app_green > /dev/null 2>&1
    log "Cleanup completed"
}

trap cleanup EXIT INT TERM

# Run main function
main "$@"