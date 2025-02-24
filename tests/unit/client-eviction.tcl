tags {"external:skip"} {

# Get info about a redis client connection:
# name - name of client we want to query
# f - field name from "CLIENT LIST" we want to get
proc client_field {name f} {
    set clients [split [string trim [r client list]] "\r\n"]
    set c [lsearch -inline $clients *name=$name*]
    if {![regexp $f=(\[a-zA-Z0-9-\]+) $c - res]} {
        error "no client named $name found with field $f"
    }
    return $res
}

proc client_exists {name} {
    if {[catch { client_field $name tot-mem } e]} {
        return false
    }
    return true
}

proc gen_client {} {
    set rr [redis_client]
    set name "tst_[randstring 4 4 simplealpha]"
    $rr client setname $name
    assert {[client_exists $name]}
    return [list $rr $name]
}

# Sum a value across all redis client connections:
# f - the field name from "CLIENT LIST" we want to sum
proc clients_sum {f} {
    set sum 0
    set clients [split [string trim [r client list]] "\r\n"]
    foreach c $clients {
        if {![regexp $f=(\[a-zA-Z0-9-\]+) $c - res]} {
            error "field $f not found in $c"
        }
        incr sum $res
    }
    return $sum
}

proc mb {v} {
    return [expr $v * 1024 * 1024]
}

start_server {} {
    set maxmemory_clients 3000000
    r config set maxmemory-clients $maxmemory_clients
    
    test "client evicted due to large argv" {
        r flushdb
        lassign [gen_client] rr cname
        # Attempt a large multi-bulk command under eviction limit
        $rr mset k v k2 [string repeat v 1000000]
        assert_equal [$rr get k] v
        # Attempt another command, now causing client eviction
        catch { $rr mset k v k2 [string repeat v $maxmemory_clients] } e
        assert {![client_exists $cname]}
        $rr close
    }

    test "client evicted due to large query buf" {
        r flushdb
        lassign [gen_client] rr cname
        # Attempt to fill the query buff without completing the argument above the limit, causing client eviction
        catch { 
            $rr write [join [list "*1\r\n\$$maxmemory_clients\r\n" [string repeat v $maxmemory_clients]] ""]
            $rr flush
            $rr read
        } e
        assert {![client_exists $cname]}
        $rr close
    }

    test "client evicted due to percentage of maxmemory" {
        set maxmemory [mb 6]
        r config set maxmemory $maxmemory
        # Set client eviction threshold to 7% of maxmemory        
        set maxmemory_clients_p 7
        r config set maxmemory-clients $maxmemory_clients_p%
        r flushdb
        
        set maxmemory_clients_actual [expr $maxmemory * $maxmemory_clients_p / 100]

        lassign [gen_client] rr cname
        # Attempt to fill the query buff with only half the percentage threshold verify we're not disconnected
        set n [expr $maxmemory_clients_actual / 2]
        $rr write [join [list "*1\r\n\$$n\r\n" [string repeat v $n]] ""]
        $rr flush
        set tot_mem [client_field $cname tot-mem]
        assert {$tot_mem >= $n && $tot_mem < $maxmemory_clients_actual}
        
        # Attempt to fill the query buff with the percentage threshold of maxmemory and verify we're evicted
        $rr close
        lassign [gen_client] rr cname
        catch { 
            $rr write [join [list "*1\r\n\$$maxmemory_clients_actual\r\n" [string repeat v $maxmemory_clients_actual]] ""]
            $rr flush
        } e
        assert {![client_exists $cname]}
        $rr close
        
        # Restore settings
        r config set maxmemory 0
        r config set maxmemory-clients $maxmemory_clients
    }

    test "client evicted due to large multi buf" {
        r flushdb
        lassign [gen_client] rr cname
        
        # Attempt a multi-exec where sum of commands is less than maxmemory_clients
        $rr multi
        $rr set k [string repeat v [expr $maxmemory_clients / 4]]
        $rr set k [string repeat v [expr $maxmemory_clients / 4]]
        assert_equal [$rr exec] {OK OK}

        # Attempt a multi-exec where sum of commands is more than maxmemory_clients, causing client eviction
        $rr multi
        catch { 
            for {set j 0} {$j < 5} {incr j} {
                $rr set k [string repeat v [expr $maxmemory_clients / 4]]
            }
        } e
        assert {![client_exists $cname]}
        $rr close
    }

    test "client evicted due to watched key list" {
        r flushdb
        set rr [redis_client]
        
        # Since watched key list is a small overheatd this test uses a minimal maxmemory-clients config
        set temp_maxmemory_clients 200000
        r config set maxmemory-clients $temp_maxmemory_clients
        
        # Append watched keys until list maxes out maxmemroy clients and causes client eviction
        catch { 
            for {set j 0} {$j < $temp_maxmemory_clients} {incr j} {
                $rr watch $j
            }
        } e
        assert_match {I/O error reading reply} $e
        $rr close
        
        # Restore config for next tests
        r config set maxmemory-clients $maxmemory_clients
    }

    test "client evicted due to pubsub subscriptions" {
        r flushdb
        
        # Since pubsub subscriptions cause a small overheatd this test uses a minimal maxmemory-clients config
        set temp_maxmemory_clients 200000
        r config set maxmemory-clients $temp_maxmemory_clients

        # Test eviction due to pubsub patterns
        set rr [redis_client]
        # Add patterns until list maxes out maxmemroy clients and causes client eviction
        catch { 
            for {set j 0} {$j < $temp_maxmemory_clients} {incr j} {
                $rr psubscribe $j
            }
        } e
        assert_match {I/O error reading reply} $e
        $rr close

        # Test eviction due to pubsub channels
        set rr [redis_client]
        # Add patterns until list maxes out maxmemroy clients and causes client eviction
        catch { 
            for {set j 0} {$j < $temp_maxmemory_clients} {incr j} {
                $rr subscribe $j
            }
        } e
        assert_match {I/O error reading reply} $e
        $rr close
       
        # Restore config for next tests
        r config set maxmemory-clients $maxmemory_clients
    }
    
    test "client evicted due to tracking redirection" {
        r flushdb
        # Use slow hz to avoid clientsCron from updating memory usage frequently since 
        # we're testing the update logic when writing tracking redirection output
        set backup_hz [lindex [r config get hz] 1]
        r config set hz 1

        set rr [redis_client]
        set redirected_c [redis_client] 
        $redirected_c client setname redirected_client
        set redir_id [$redirected_c client id]
        $redirected_c SUBSCRIBE __redis__:invalidate
        $rr client tracking on redirect $redir_id bcast
        # Use a big key name to fill the redirected tracking client's buffer quickly
        set key_length [expr 1024*10]
        set long_key [string repeat k $key_length]
        # Use a script so we won't need to pass the long key name when dirtying it in the loop
        set script_sha [$rr script load "redis.call('incr', '$long_key')"]
        # Read and write to same (long) key until redirected_client's buffers cause it to be evicted
        set t [clock milliseconds]
        catch {
            while true {
                set mem [client_field redirected_client tot-mem]
                assert {$mem < $maxmemory_clients}
                $rr evalsha $script_sha 0
            }
        } e
        assert_match {no client named redirected_client found*} $e
        
        # Make sure eviction happened in less than 1sec, this means, statistically eviction
        # wasn't caused by clientCron accounting
        set t [expr [clock milliseconds] - $t]
        assert {$t < 1000}

        r config set hz $backup_hz
        $rr close
        $redirected_c close
    }

    test "client evicted due to client tracking prefixes" {
        r flushdb
        set rr [redis_client]
        
        # Since tracking prefixes list is a small overheatd this test uses a minimal maxmemory-clients config
        set temp_maxmemory_clients 200000
        r config set maxmemory-clients $temp_maxmemory_clients
        
        # Append tracking prefixes until list maxes out maxmemroy clients and causes client eviction
        catch { 
            for {set j 0} {$j < $temp_maxmemory_clients} {incr j} {
                $rr client tracking on prefix [format %012s $j] bcast
            }
        } e
        assert_match {I/O error reading reply} $e
        $rr close

        # Restore config for next tests
        r config set maxmemory-clients $maxmemory_clients
    }

    test "client evicted due to output buf" {
        r flushdb
        r setrange k 200000 v
        set rr [redis_deferring_client]
        $rr client setname test_client
        $rr flush
        assert {[$rr read] == "OK"}
        # Attempt a large response under eviction limit
        $rr get k
        $rr flush
        assert {[string length [$rr read]] == 200001}
        set mem [client_field test_client tot-mem]
        assert {$mem < $maxmemory_clients}

        # Fill output buff in loop without reading it and make sure 
        # we're eventually disconnected, but before reaching maxmemory_clients
        while true {
            if { [catch {
                set mem [client_field test_client tot-mem]
                assert {$mem < $maxmemory_clients}
                $rr get k
                $rr flush
               } e]} {
                assert {![client_exists test_client]}
                break
            }
        }
        $rr close
    }

    foreach {no_evict} {on off} {
        test "client no-evict $no_evict" {
            r flushdb
            r client setname control
            r client no-evict on ;# Avoid evicting the main connection
            lassign [gen_client] rr cname
            $rr client no-evict $no_evict
        
            # Overflow maxmemory-clients
            set qbsize [expr {$maxmemory_clients + 1}]
            if {[catch {
                $rr write [join [list "*1\r\n\$$qbsize\r\n" [string repeat v $qbsize]] ""]
                $rr flush
                wait_for_condition 200 10 {
                    [client_field $cname qbuf] == $qbsize
                } else {
                    fail "Failed to fill qbuf for test"
                }
            } e] && $no_evict == off} {
                assert {![client_exists $cname]}
            } elseif {$no_evict == on} {
                assert {[client_field $cname tot-mem] > $maxmemory_clients}
            }            
            $rr close
        }
    }
}

start_server {} {
    set server_pid [s process_id]
    set maxmemory_clients [mb 10]
    set obuf_limit [mb 3]
    r config set maxmemory-clients $maxmemory_clients
    r config set client-output-buffer-limit "normal $obuf_limit 0 0"

    test "avoid client eviction when client is freed by output buffer limit" {
        r flushdb
        set obuf_size [expr {$obuf_limit + [mb 1]}]
        r setrange k $obuf_size v
        set rr1 [redis_client]
        $rr1 client setname "qbuf-client"
        set rr2 [redis_deferring_client]
        $rr2 client setname "obuf-client1"
        assert_equal [$rr2 read] OK
        set rr3 [redis_deferring_client]
        $rr3 client setname "obuf-client2"
        assert_equal [$rr3 read] OK

        # Occupy client's query buff with less than output buffer limit left to exceed maxmemory-clients
        set qbsize [expr {$maxmemory_clients - $obuf_size}]
        $rr1 write [join [list "*1\r\n\$$qbsize\r\n" [string repeat v $qbsize]] ""]
        $rr1 flush
        # Wait for qbuff to be as expected
        wait_for_condition 200 10 {
            [client_field qbuf-client qbuf] == $qbsize
        } else {
            fail "Failed to fill qbuf for test"
        }
        
        # Make the other two obuf-clients pass obuf limit and also pass maxmemory-clients
        # We use two obuf-clients to make sure that even if client eviction is attempted
        # between two command processing (with no sleep) we don't perform any client eviction
        # because the obuf limit is enforced with precedence.
        exec kill -SIGSTOP $server_pid
        $rr2 get k
        $rr2 flush
        $rr3 get k
        $rr3 flush
        exec kill -SIGCONT $server_pid
        
        # Validate obuf-clients were disconnected (because of obuf limit)
        catch {client_field obuf-client1 name} e
        assert_match {no client named obuf-client1 found*} $e
        catch {client_field obuf-client2 name} e
        assert_match {no client named obuf-client2 found*} $e
        
        # Validate qbuf-client is still connected and wasn't evicted
        assert_equal [client_field qbuf-client name] {qbuf-client}

        $rr1 close
        $rr2 close
        $rr3 close
    }
}

start_server {} {
    test "decrease maxmemory-clients causes client eviction" {
        set maxmemory_clients [mb 4]
        set client_count 10
        set qbsize [expr ($maxmemory_clients - [mb 1]) / $client_count]
        r config set maxmemory-clients $maxmemory_clients


        # Make multiple clients consume together roughly 1mb less than maxmemory_clients
        set rrs {}
        for {set j 0} {$j < $client_count} {incr j} {
            set rr [redis_client]
            lappend rrs $rr
            $rr client setname client$j
            $rr write [join [list "*2\r\n\$$qbsize\r\n" [string repeat v $qbsize]] ""]
            $rr flush
            wait_for_condition 200 10 {
                [client_field client$j qbuf] >= $qbsize
            } else {
                fail "Failed to fill qbuf for test"
            }
        }
        
        # Make sure all clients are still connected
        set connected_clients [llength [lsearch -all [split [string trim [r client list]] "\r\n"] *name=client*]]
        assert {$connected_clients == $client_count}
        
        # Decrease maxmemory_clients and expect client eviction
        r config set maxmemory-clients [expr $maxmemory_clients / 2]
        set connected_clients [llength [lsearch -all [split [string trim [r client list]] "\r\n"] *name=client*]]
        assert {$connected_clients > 0 && $connected_clients < $client_count}
        
        foreach rr $rrs {$rr close}
    }
}

start_server {} {
    test "evict clients only until below limit" {
        set client_count 10
        set client_mem [mb 1]
        r config set maxmemory-clients 0
        r client setname control
        r client no-evict on
        
        # Make multiple clients consume together roughly 1mb less than maxmemory_clients
        set total_client_mem 0
        set rrs {}
        for {set j 0} {$j < $client_count} {incr j} {
            set rr [redis_client]
            lappend rrs $rr
            $rr client setname client$j
            $rr write [join [list "*2\r\n\$$client_mem\r\n" [string repeat v $client_mem]] ""]
            $rr flush
            wait_for_condition 200 10 {
                [client_field client$j tot-mem] >= $client_mem
            } else {
                fail "Failed to fill qbuf for test"
            }
            incr total_client_mem [client_field client$j tot-mem]
        }

        set client_actual_mem [expr $total_client_mem / $client_count]
        
        # Make sure client_acutal_mem is more or equal to what we intended
        assert {$client_actual_mem >= $client_mem}

        # Make sure all clients are still connected
        set connected_clients [llength [lsearch -all [split [string trim [r client list]] "\r\n"] *name=client*]]
        assert {$connected_clients == $client_count}

        # Set maxmemory-clients to accommodate half our clients (taking into account the control client)
        set maxmemory_clients [expr ($client_actual_mem * $client_count) / 2 + [client_field control tot-mem]]
        r config set maxmemory-clients $maxmemory_clients
        
        # Make sure total used memory is below maxmemory_clients
        set total_client_mem [clients_sum tot-mem]
        assert {$total_client_mem <= $maxmemory_clients}

        # Make sure we have only half of our clients now
        set connected_clients [llength [lsearch -all [split [string trim [r client list]] "\r\n"] *name=client*]]
        assert {$connected_clients == [expr $client_count / 2]}

        foreach rr $rrs {$rr close}
    }
}

start_server {} {
    test "evict clients in right order (large to small)" {
        # Note that each size step needs to be at least x2 larger than previous step 
        # because of how the client-eviction size bucktting works
        set sizes [list 100000 [mb 1] [mb 3]]
        set clients_per_size 3
        r client setname control
        r client no-evict on
        r config set maxmemory-clients 0
        
        # Run over all sizes and create some clients using up that size
        set total_client_mem 0
        set rrs {}
        for {set i 0} {$i < [llength $sizes]} {incr i} {
            set size [lindex $sizes $i]

            for {set j 0} {$j < $clients_per_size} {incr j} {
                set rr [redis_client]
                lappend rrs $rr
                $rr client setname client-$i
                $rr write [join [list "*2\r\n\$$size\r\n" [string repeat v $size]] ""]
                $rr flush
            }
            set client_mem [client_field client-$i tot-mem]
    
            # Update our size list based on actual used up size (this is usually 
            # slightly more than expected because of allocator bins
            assert {$client_mem >= $size}
            set sizes [lreplace $sizes $i $i $client_mem]
            
            # Account total client memory usage
            incr total_mem [expr $clients_per_size * $client_mem]
        }
        incr total_mem [client_field control tot-mem]
        
        # Make sure all clients are connected
        set clients [split [string trim [r client list]] "\r\n"]
        for {set i 0} {$i < [llength $sizes]} {incr i} {
            assert_equal [llength [lsearch -all $clients "*name=client-$i *"]] $clients_per_size        
        }
        
        # For each size reduce maxmemory-clients so relevant clients should be evicted
        # do this from largest to smallest
        foreach size [lreverse $sizes] {
            set total_mem [expr $total_mem - $clients_per_size * $size]
            r config set maxmemory-clients $total_mem
            set clients [split [string trim [r client list]] "\r\n"]
            # Verify only relevant clients were evicted
            for {set i 0} {$i < [llength $sizes]} {incr i} {
                set verify_size [lindex $sizes $i]
                set count [llength [lsearch -all $clients "*name=client-$i *"]]
                if {$verify_size < $size} {
                    assert_equal $count $clients_per_size
                } else {
                    assert_equal $count 0
                }
            }
        }
        foreach rr $rrs {$rr close}
    }
}

}

