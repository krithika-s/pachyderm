#!/bin/bash

set -euxo pipefail

parse_flags() {
  # Common config
  export AWS_REGION=us-east-1
  export AWS_AVAILABILITY_ZONE=us-east-1a
  export STATE_BUCKET=k8scom-state-store-pachyderm-${RANDOM}
  local USE_EXISTING_STATE_BUCKET='false'

  # Parse flags
  set -- $( getopt -l "state:,region:,zone:" "--" "${0}" "${@}" )
  while true; do
      case "${1}" in
          --state)
            export STATE_BUCKET="${2}"
            USE_EXISTING_STATE_BUCKET='true'
            ;;
          --region)
            export AWS_REGION="${2}"
            ;;
          --zone)
            export AWS_AVAILABILITY_ZONE="${2}"
            ;;
          --)
            break
            ;;
      esac
      shift 2
  done

  if [ "${USE_EXISTING_STATE_BUCKET}" == 'false' ]; then
    create_s3_bucket "${STATE_BUCKET}"
  fi
}

create_s3_bucket() {
  if [[ "$#" -lt 1 ]]; then
    echo "Error: create_s3_bucket needs a bucket name"
    return 1
  fi
  BUCKET="${1}"

  # For some weird reason, s3 emits an error if you pass a location constraint when location is "us-east-1"
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket ${BUCKET} --region ${AWS_REGION}
  else
    aws s3api create-bucket --bucket ${BUCKET} --region ${AWS_REGION} --create-bucket-configuration LocationConstraint=${AWS_REGION}
  fi
}

deploy_k8s_on_aws() {
    # Check prereqs
    which aws
    which jq
    which uuid
    aws configure list
    aws iam list-users

    export NODE_SIZE=r4.xlarge
    export MASTER_SIZE=r4.xlarge
    export NUM_NODES=3
    export NAME=$(uuid | cut -f 1 -d-)-pachydermcluster.kubernetes.com
    echo "kops state store: s3://${STATE_BUCKET}"
    kops create cluster \
        --state=s3://${STATE_BUCKET} \
        --node-count ${NUM_NODES} \
        --zones ${AWS_AVAILABILITY_ZONE} \
        --master-zones ${AWS_AVAILABILITY_ZONE} \
        --dns private \
        --dns-zone kubernetes.com \
        --node-size ${NODE_SIZE} \
        --master-size ${NODE_SIZE} \
        ${NAME}
    kops update cluster ${NAME} --yes --state=s3://${STATE_BUCKET}

    # Record state store bucket in temp file.
    # This will allow us to cleanup the cluster afterwards
    set +euxo pipefail
    mkdir tmp
    echo "KOPS_STATE_STORE=${STATE_BUCKET}" >> tmp/${NAME}.sh
    echo ${NAME} > tmp/current-benchmark-cluster.txt
    set -euxo pipefail

    wait_for_k8s_master_ip
    update_sec_group
    wait_for_nodes_to_come_online
}

update_sec_group() {
    export SECURITY_GROUP_ID="$(
        aws ec2 describe-instances --filters "Name=instance-type,Values=${NODE_SIZE}" --region ${AWS_REGION} \
          | jq --raw-output '.Reservations[].Instances[] | select([.Tags[].Value | contains("masters.'${NAME}'")] | any) | .SecurityGroups[0].GroupId')"
    # For k8s access
    aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 8080 --cidr "0.0.0.0/0" --region ${AWS_REGION}
    # For pachyderm direct access:
    aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 30650 --cidr "0.0.0.0/0" --region ${AWS_REGION}
}

# Prints a spinning wheel. Every time you call it, the wheel advances 1/4 turn
WHEEL="-\|/"
spin() {
    echo -en "\e[D${WHEEL:0:1}"
    WHEEL=${WHEEL:1}${WHEEL:0:1}
}

wait_for_k8s_master_ip() {
    # Get the IP of the k8s master node and hack /etc/hosts so we can connect
    # Need to retry this in a loop until we see the instance appear
    set +euxo pipefail
    echo "Retrieving ec2 instance list to get k8s master domain name (may take a minute)"
    get_k8s_master_domain
    while [ $? -ne 0 ]; do
        spin
        sleep 1
        get_k8s_master_domain
    done
    echo "Master k8s node is up and lives at ${K8S_MASTER_DOMAIN}"
    set -euxo pipefail
    masterk8sip="$(dig +short ${K8S_MASTER_DOMAIN})"
    # This is the only operation that requires sudo privileges
    sudo echo " " >> /etc/hosts # Some files dont contain newlines ... I'm looking at you travisCI
    sudo echo "${masterk8sip} api.${NAME}" >> /etc/hosts
    echo "state of /etc/hosts:"
    cat /etc/hosts
}

wait_for_nodes_to_come_online() {
    # Wait until all nodes show as ready, and we have as many as we expect
    set +euxo pipefail
    echo "Waiting for nodes to come online (may take a few minutes)"
    check_all_nodes_ready >/dev/null 2>&1
    while [ $? -ne 0 ]; do
        spin
        sleep 1
        check_all_nodes_ready >/dev/null 2>&1
    done
    set -euxo pipefail
    rm nodes.txt
}

check_all_nodes_ready() {
    echo "Checking k8s nodes are ready"
    kubectl get nodes > nodes.txt
    if [ $? -ne 0 ]; then
        return 1
    fi

    master=`cat nodes.txt | grep master | wc -l`
    if [ ${master} != "1" ]; then
        echo "no master nodes found"
        return 1
    fi

    total_nodes=$((${NUM_NODES}+1))
    ready_nodes=`cat nodes.txt | grep -v NotReady | grep Ready | wc -l`
    echo "total ${total_nodes}, ready ${ready_nodes}"
    if [ ${ready_nodes} == ${total_nodes} ]; then
        echo "all nodes ready"
        return 0
    fi
    return 1
}

get_k8s_master_domain() {
    export K8S_MASTER_DOMAIN="$(
        aws ec2 describe-instances --filters "Name=instance-type,Values=${NODE_SIZE}" --region ${AWS_REGION} \
          | jq --raw-output '.Reservations[].Instances[] | select([.Tags[]?.Value | contains("masters.'${NAME}'")] | any) | .PublicDnsName')"
    if [ -n "${K8S_MASTER_DOMAIN}" ]; then
        return 0
    fi
    return 1
}


##################################
###### Deploy Pach cluster #######
##################################

deploy_pachyderm_on_aws() {
    # shared with k8s deploy script:
    export STORAGE_SIZE=100
    export BUCKET_NAME=${RANDOM}-pachyderm-store

    create_s3_bucket "${BUCKET_NAME}"

    # Since my user should have the right access:
    AWS_KEY=`cat ~/.aws/credentials | grep aws_secret_access_key | cut -d " " -f 3`
    AWS_ID=`cat ~/.aws/credentials | grep aws_access_key_id  | cut -d " " -f 3`

    # Omit token since im using my personal creds
    pachctl deploy amazon ${BUCKET_NAME} "${AWS_ID}" "${AWS_KEY}" " " ${AWS_REGION} ${STORAGE_SIZE} --dynamic-etcd-nodes=3
}

if [ "${EUID}" -ne 0 ]; then
  echo "Cowardly refusing to deploy cluster. Please run as root"
  echo "Please run this command like 'sudo -E make launch-bench'"
  exit 1
fi
parse_flags

set +euxo pipefail
which pachctl
if [ $? -ne 0 ]; then
    echo "pachctl not found on path"
    exit 1
fi
set -euxo pipefail

deploy_k8s_on_aws
deploy_pachyderm_on_aws
