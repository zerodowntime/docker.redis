#!/bin/bash
#
# Script to join cluster.
#
# VARIABLES
# MASTER_IPS - list of master IPs
# MASTERS_PORT - port of masters
# SLAVE_IPS - list of slaves IPs
# SLAVES_PORT - port of slaves
# FUNCTIONS

verify_cluster() {
  # Check if cluster is ok
  $redis_cli_path -p $PORT cluster info | grep -q cluster_state:ok
  if [ $? -eq 0 ]; then
    echo "Cluster is ${1:-ok}, finishing job"
    exit 0
  fi
}

get_index(){
  arr=($1)
  value=$2
  for i in "${!arr[@]}"; do
    if [[ "${arr[$i]}" = "${value}" ]]; then
        echo "${i}"
        return 0
    fi
  done
  echo "-1"
  return 1
}

# CODE

DEFAULT_PORT=6379
redis_cli_path="/usr/local/bin/redis-cli"

# Set master ip - if any
my_master_ip=$(sort <(hostname -I | tr " " "\n") <(echo "$MASTER_IPS" | tr " " "\n") | uniq -d) # empty if not master
# Set slave ip - if any
my_slave_ip=$(sort <(hostname -I | tr " " "\n") <(echo "$SLAVE_IPS" | tr " " "\n") | uniq -d) # empty if not slave
# Set lead master
set -- $MASTER_IPS
lead_master_ip="$1"

echo "Starting organizer"

# Assert role is assigned - node is in slave or master pool
if [ "_$my_master_ip" == "_" -a "_$my_slave_ip" == "_" ]; then
    echo "Host has to be in slave or master ip pool, Define 'MASTER_IPS' and/or 'SLAVE_IPS'"
    exit 1
fi
# Master envs handling
if [ -z "$MASTER_IPS" ]; then
    echo "MASTER_IPS has to be defined"
    exit 1
fi
if [ -z "$MASTERS_PORT" ]; then
    echo "Setting default port for master to $DEFAULT_PORT"
    export MASTERS_PORT=$DEFAULT_PORT
fi
# Slave envs handling
if [ "_$my_slave_ip" != "_" ]; then
    echo "Slave node"
    if [ -z "$SLAVES_PORT" ]; then
        echo "Setting default port for slave to $DEFAULT_PORT"
        export SLAVES_PORT=$DEFAULT_PORT
    fi
    if [ -z "$SLAVE_IPS" ]; then
        echo "SLAVE_IPS has to be defined for slave"
        exit 1
    fi
    PORT=$SLAVES_PORT
else
    echo "Master node"
    PORT=$MASTERS_PORT
fi
# This flag sets redis to assign this slave to first orphaned master
# by default - false - redis will join
if [ "_$JOIN_ORPHANED_MASTER" = "_true" -o "_$JOIN_ORPHANED_MASTER" = "_True" ]; then
    JOIN_ORPHANED_MASTER="$(echo "$JOIN_ORPHANED_MASTER" | tr '[:upper:]' '[:lower:]')"
else
    JOIN_ORPHANED_MASTER="false"
fi

# Wait till I am running
while [ 1 ]; do
    nc -z 127.0.0.1 6379
    if [ $? -eq 0 ]; then
        break;
    fi
    sleep 1
done

# Let app start up
sleep 5

cluster_info=$($redis_cli_path -p $PORT cluster info)

# Check if standalone
echo $cluster_info | grep -q cluster_enabled:0
if [ $? -eq 0 ]; then
    echo "It is standalone node, finishing job"
    exit 0
fi

echo "It is cluster node"

# All is ok - gracefully end
verify_cluster "OK"
# Cluster is failed

# Waiting for cluster setup
if [ "_$my_slave_ip" != "_" ]; then
    echo "Wait 15 seconds till masters create cluster"
    sleep 15
else
    echo "Wait 5 seconds till all masters come up"
    sleep 5
fi

# Node have never been in cluster
echo $cluster_info | grep -q cluster_size:0
if [ $? -eq 0 ]; then
    my_ips=$(hostname -I)
    echo
    echo "Try to join cluster"

    # Join cluster by trying one node after each other.
    for i in `seq 30`; do
        for master in $MASTER_IPS; do
            echo "--Try to reach $master"
            if nc -z "$master" $MASTERS_PORT; then
                echo "--Connected"
                _cluster_info=$($redis_cli_path -h "$master" -p $MASTERS_PORT cluster info)
                # Cluster is ok to join
                # echo $_cluster_info | grep cluster_state:ok > /dev/null
                echo $_cluster_info | grep -q cluster_state:ok
                if [ $? -eq 0 ]; then
                    # Master
                    if [ "_$my_master_ip" != "_" -a -z "$SLAVE_IPS" ]; then
                        echo "----Joining existing cluster at $master:$MASTERS_PORT as master"
                        $redis_cli_path --cluster add-node $my_master_ip:$MASTERS_PORT $master:$MASTERS_PORT
                        sleep $[ ( $RANDOM % 10 )  + 1 ]s
                        echo "----Rebalance shards after joining cluster"
                        $redis_cli_path --cluster rebalance $my_master_ip:$MASTERS_PORT --cluster-use-empty-masters
                        if [ $? -eq 0 ]; then
                            echo
                            echo "Successfully joined cluster"
                            touch ready.flag
                            exit 0
                        else
                            echo "----Something went wrong - did not join cluster"
                        fi
                    # Slave
                    else
                        if [ "$JOIN_ORPHANED_MASTER" = "true" ]; then
                            echo "----Joining existing cluster at $master:$MASTERS_PORT as slave of orphaned master"
                            $redis_cli_path --cluster add-node $my_slave_ip:$SLAVES_PORT $master:$MASTERS_PORT --cluster-slave
                        else
                            _slave_index=$(get_index "$MASTER_IPS" "$my_slave_ip")
                            _masters=($MASTER_IPS $MASTER_IPS)
                            _replicate_master_ip=${_masters[_slave_index+1]}
                            _replicate_master_id=$($redis_cli_path -h $master -p $MASTERS_PORT cluster nodes | grep master | grep $_replicate_master_ip | cut -d" " -f1)
                            if [ "_$_replicate_master_id" != "_" ]; then
                                echo "----Joining existing cluster at $master:$MASTERS_PORT as slave of $_replicate_master_id"
                                $redis_cli_path --cluster add-node $my_slave_ip:$SLAVES_PORT $master:$MASTERS_PORT --cluster-slave --cluster-master-id $_replicate_master_id
                                if [ $? -eq 0 ]; then
                                    echo
                                    echo "Successfully joined cluster"
                                    touch ready.flag
                                    sleep 10
                                    # Assert I am not joined to master on my host
                                    $redis_cli_path -p $MASTERS_PORT cluster nodes | grep $_replicate_master_id | grep -q myself
                                    if [ $? -eq 0 ]; then
                                      echo "Slave is connected to Master on the same host!"
                                      exit 6
                                    fi
                                    exit 0
                                else
                                    echo "----Joining cluster failed"
                                fi
                            else
                                echo "----Master, this node is assigned to - $_replicate_master_ip, is not in a cluster"
                            fi
                        fi
                    fi
                else
                    echo "--Nodes cluster state is false, ending connection"
                fi
            fi
        done
        echo "--Failed to join other nodes."

        # Create cluster
        if [ "$my_master_ip" == "$lead_master_ip" -a -z "$SLAVE_IPS" ]; then
            echo "--Create cluster due to claimed master role on $lead_master_ip."
            # yes yes | $redis_cli_path --cluster fix 127.0.0.1:$MASTERS_PORT
            $redis_cli_path  --cluster fix 127.0.0.1:$MASTERS_PORT --cluster-yes
            if [ $? -eq 0 ]; then
              echo "Cluster creation succeded"
              touch ready.flag
              exit 0
            else
              echo "--Cluster creation failed"
            fi
        fi

        echo
        echo "RETRY $i/30"
        sleep 10
    done
    echo "Could not join or create cluster, finishing job"
    echo "This should never happen, possible configuration in wrong"
    exit 2
fi

# Node used to be in a cluster but dropped
# Node with cluster_size > 0 -> used to be in cluster, if cluster_size=1 and NOT ok -> error
echo $cluster_info | grep -q cluster_size:1
# Try to recover node for 5 minutes
if [ $? -eq 0 ]; then
    echo "This nodes used to be in cluster, now it is single node"
    for i in `seq 30`; do
      echo "wait 10seconds, $i/30 retry"
      sleep 10
      # Check if cluster is ok
      verify_cluster "recovered"
    done
    echo "Could not recover cluster, finishing job"
    echo "Try potentially fix cluster and join again"
    exit 3
fi

# Node is right cluster but cluster is failed
# Fix cluster on lead master
if [ "$my_master_ip" == "$lead_master_ip" -a -z "$SLAVE_IPS" ]; then
    echo "Fixing cluster due to claimed master role on $lead_master_ip."
    echo
    # yes yes | $redis_cli_path --cluster fix 127.0.0.1:$MASTERS_PORT
    $redis_cli_path --cluster fix 127.0.0.1:$MASTERS_PORT --cluster-yes
    if [ $? -eq 0 ]; then
      echo "Cluster fix succeded"
      touch ready.flag
      exit 0
    else
      echo "Cluster fix failed"
    fi
else
    echo "Waiting for master to fix cluster"
    exit 4
fi

echo "Failed to join cluster."
echo "This part should never be reached. Probably there is an unhandled case."
exit 5
