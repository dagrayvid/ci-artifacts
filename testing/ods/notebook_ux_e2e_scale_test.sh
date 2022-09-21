#! /bin/bash

set -o errexit
set -o pipefail
set -o nounset
set -o errtrace
set -x

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source "$THIS_DIR/../prow/_logging.sh"
source "$THIS_DIR/process_ctrl.sh"
source "$THIS_DIR/common.sh"

if [[ "${INSIDE_CI_IMAGE:-}" == "y" ]]; then
    KUBECONFIG_DRIVER="${KUBECONFIG_DRIVER:-${SHARED_DIR}/driver_kubeconfig}" # cluster driving the test
    KUBECONFIG_SUTEST="${KUBECONFIG_SUTEST:-${SHARED_DIR}/sutest_kubeconfig}" # system under test
else
    KUBECONFIG_DRIVER="${KUBECONFIG_DRIVER:-$KUBECONFIG}" # cluster driving the test
    KUBECONFIG_SUTEST="${KUBECONFIG_SUTEST:-$KUBECONFIG}" # system under test
fi

DRIVER_CLUSTER=driver
SUTEST_CLUSTER=sutest

switch_sutest_cluster() {
    switch_cluster "$SUTEST_CLUSTER"
}

switch_driver_cluster() {
    switch_cluster "$DRIVER_CLUSTER"
}

switch_cluster() {
    cluster_role="$1"
    echo "Switching to the '$cluster_role' cluster"
    if [[ "$cluster_role" == "$DRIVER_CLUSTER" ]]; then
        export KUBECONFIG=$KUBECONFIG_DRIVER
    elif [[ "$cluster_role" == "$SUTEST_CLUSTER" ]]; then
        export KUBECONFIG=$KUBECONFIG_SUTEST
    else
        echo "Requested to switch to an unknown cluster '$cluster_role', exiting."
        exit 1
    fi
    export ARTIFACT_TOOLBOX_NAME_PREFIX="${cluster_role}_"
}

# ---

connect_sutest_cluster() {
    osd_cluster_name=$1

    touch "$KUBECONFIG_SUTEST"

    switch_sutest_cluster

    if [[ "$osd_cluster_name" ]]; then
        echo "OSD cluster name is $osd_cluster_name"

        ocm_login

        if ! ocm_cluster_is_ready "$osd_cluster_name"
        then
            echo "OCM cluster '$osd_cluster_name' isn't ready ..."
            exit 1
        fi

        ocm_oc_login "$osd_cluster_name"
    fi

    oc get clusterversion
}

prepare_driver_cluster() {
    switch_cluster "driver"

    prepare_driver_scale_cluster

    oc create namespace "$ODS_CI_TEST_NAMESPACE" -oyaml --dry-run=client | oc apply -f-
    oc annotate namespace/"$ODS_CI_TEST_NAMESPACE" --overwrite \
       "openshift.io/node-selector=node.kubernetes.io/instance-type=$DRIVER_COMPUTE_MACHINE_TYPE"

    build_and_preload_odsci_image() {
        ./run_toolbox.py utils build_push_image \
                         "$ODS_CI_IMAGESTREAM" "$ODS_CI_TAG" \
                         --namespace="$ODS_CI_TEST_NAMESPACE" \
                         --git-repo="$ODS_CI_REPO" \
                         --git-ref="$ODS_CI_REF" \
                         --context-dir="/" \
                         --dockerfile-path="build/Dockerfile"

        ods_ci_image="image-registry.openshift-image-registry.svc:5000/$ODS_CI_TEST_NAMESPACE/$ODS_CI_IMAGESTREAM:$ODS_CI_TAG"
        ./run_toolbox.py cluster preload_image "preload-ods-ci" "$ods_ci_image" \
                         --namespace="$ODS_CI_TEST_NAMESPACE"
    }

    build_and_preload_artifacts_exporter_image() {
        ./run_toolbox.py utils build_push_image \
                         "$ODS_CI_IMAGESTREAM" "$ODS_CI_ARTIFACTS_EXPORTER_TAG" \
                         --namespace="$ODS_CI_TEST_NAMESPACE" \
                         --context-dir="/" \
                         --dockerfile-path="$ODS_CI_ARTIFACTS_EXPORTER_DOCKERFILE"

        artifacts_exporter_image="image-registry.openshift-image-registry.svc:5000/$ODS_CI_TEST_NAMESPACE/$ODS_CI_IMAGESTREAM:$ODS_CI_ARTIFACTS_EXPORTER_TAG"

        ./run_toolbox.py cluster preload_image "artifacts-exporter" "$artifacts_exporter_image" \
                         --namespace="$ODS_CI_TEST_NAMESPACE"
    }

    process_ctrl::run_in_bg build_and_preload_odsci_image
    process_ctrl::run_in_bg build_and_preload_artifacts_exporter_image

    process_ctrl::run_in_bg ./run_toolbox.py cluster deploy_minio_s3_server "$S3_LDAP_PROPS"

    process_ctrl::run_in_bg ./run_toolbox.py cluster deploy_nginx_server "$NGINX_NOTEBOOK_NAMESPACE" "$ODS_NOTEBOOK_DIR"

    process_ctrl::run_in_bg ./run_toolbox.py cluster deploy_redis_server "$STATESIGNAL_REDIS_NAMESPACE"
}

prepare_sutest_deploy_rhods() {
    switch_sutest_cluster

    osd_cluster_name=$(get_osd_cluster_name "sutest")

    if [[ "$osd_cluster_name" ]]; then
        prepare_osd_sutest_deploy_rhods "$osd_cluster_name"
    else
        prepare_ocp_sutest_deploy_rhods
    fi
}

prepare_sutest_deploy_ldap() {
    switch_sutest_cluster

    osd_cluster_name=$(get_osd_cluster_name "sutest")

    process_ctrl::run_in_bg ./run_toolbox.py cluster deploy_ldap \
              "$LDAP_IDP_NAME" "$ODS_CI_USER_PREFIX" "$LDAP_NB_USERS" "$S3_LDAP_PROPS" \
              --use_ocm="$osd_cluster_name" \
              --wait
}

prepare_driver_scale_cluster() {
    cluster_role=driver

    switch_cluster "$cluster_role"

    osd_cluster_name=$(get_osd_cluster_name "$cluster_role")

    cluster_type=$([[ "$osd_cluster_name" ]] && echo osd || echo ocp)
    compute_nodes_type=$(get_compute_node_type "$cluster_role" "$cluster_type")
    compute_nodes_count=$(get_compute_node_count "$cluster_role" "$cluster_type" "$compute_nodes_type")

    if [[ "$osd_cluster_name" ]]; then
        ocm create machinepool \
            --cluster "$osd_cluster_name" \
            --instance-type "$compute_nodes_type" \
            "$DRIVER_MACHINE_POOL_NAME" \
            --replicas "$compute_nodes_count"
    else
        ./run_toolbox.py cluster set-scale "$compute_nodes_type" "$compute_nodes_count" \
                         --name "$DRIVER_MACHINESET_NAME"
    fi
}

prepare_sutest_scale_cluster() {
    cluster_role=sutest

    switch_cluster "$cluster_role"

    osd_cluster_name=$(get_osd_cluster_name "$cluster_role")
    cluster_type=$([[ "$osd_cluster_name" ]] && echo osd || echo ocp)
    compute_nodes_type=$(get_compute_node_type "$cluster_role" "$cluster_type")
    compute_nodes_count=$(get_compute_node_count "$cluster_role" "$cluster_type" "$compute_nodes_type")

    if [[ "$osd_cluster_name" ]]; then
        if [[ "$ENABLE_AUTOSCALER" ]]; then
            specific_options=" \
                --enable-autoscaling \
                --min-replicas=2 \
                --max-replicas=150 \
                "
        else
            specific_options=" \
                --replicas "$compute_nodes_count" \
                "
        fi
        ocm create machinepool "$SUTEST_MACHINESET_NAME" \
            --cluster "$osd_cluster_name" \
            --instance-type "$compute_nodes_type" \
            $specific_options
    else
        ./run_toolbox.py cluster set-scale "$compute_nodes_type" "$compute_nodes_count" \
                         --name "$SUTEST_MACHINESET_NAME"


        if [[ "$ENABLE_AUTOSCALER" ]]; then
            oc apply -f testing/ods/autoscaling/clusterautoscaler.yaml
            cat testing/ods/autoscaling/machineautoscaler.yaml \
                | sed "s/MACHINESET_NAME/$MACHINESET_NAME/" \
                | oc apply -f-
        fi
    fi
}

prepare_sutest_cluster() {
    switch_sutest_cluster
    prepare_sutest_deploy_rhods
    prepare_sutest_deploy_ldap
    prepare_sutest_scale_cluster
}

prepare_osd_sutest_deploy_rhods() {
    osd_cluster_name=$1

    if [[ "$OSD_USE_ODS_CATALOG" == 1 ]]; then
        echo "Deploying RHODS $ODS_CATALOG_IMAGE_TAG (from $ODS_CATALOG_IMAGE)"

        process_ctrl::run_in_bg ./run_toolbox.py rhods deploy_ods \
                  "$ODS_CATALOG_IMAGE" "$ODS_CATALOG_IMAGE_TAG"
    else

        if [[ "$OCM_ENV" == "staging" ]]; then
            echo "Workaround for https://issues.redhat.com/browse/RHODS-4182"
            MISSING_SECRET_NAMESPACE=redhat-ods-monitoring

            oc create ns "$MISSING_SECRET_NAMESPACE" \
               --dry-run=client \
               -oyaml \
                | oc apply -f-

            oc create secret generic redhat-rhods-smtp \
               -n "$MISSING_SECRET_NAMESPACE" \
               --from-literal=host= \
               --from-literal=username= \
               --from-literal=password= \
               --from-literal=port= \
               --from-literal=tls=
        fi

        process_ctrl::run_in_bg ./run_toolbox.py rhods deploy_addon "$osd_cluster_name" "$ODS_ADDON_EMAIL_ADDRESS"
    fi
}

prepare_ocp_sutest_deploy_rhods() {
    switch_sutest_cluster

    echo "Deploying RHODS $ODS_CATALOG_IMAGE_TAG (from $ODS_CATALOG_IMAGE)"

    process_ctrl::run_in_bg \
        process_ctrl::retry 5 3m \
            ./run_toolbox.py rhods deploy_ods \
                "$ODS_CATALOG_IMAGE" "$ODS_CATALOG_IMAGE_TAG"

    if ! oc get group/dezdicated-admins >/dev/null 2>/dev/null; then
        echo "Create the dedicated-admins group"
        oc adm groups new dedicated-admins
        oc adm policy add-cluster-role-to-group cluster-admin dedicated-admins
    fi
}

sutest_customize_rhods_before_wait() {
    if [[ "$CUSTOMIZE_RHODS_REMOVE_GPU_IMAGES" == 1 ]]; then
        # Fill the imagestreams with dummy (ubi) images
        for image in minimal-gpu nvidia-cuda-11.4.2 pytorch tensorflow; do
            oc tag registry.access.redhat.com/ubi8/ubi "$image:ubi" -n redhat-ods-applications
        done
        # Delete the RHODS builds
        oc delete builds --all  -n redhat-ods-applications
    fi
}

sutest_customize_rhods_after_wait() {

    if [[ "$CUSTOMIZE_RHODS_PVC_SIZE" ]]; then
        oc patch odhdashboardconfig odh-dashboard-config --type=merge -p '{"spec":{"notebookController":{"pvcSize":"'$CUSTOMIZE_RHODS_PVC_SIZE'"}}}' -n redhat-ods-applications
    fi

    if [[ "$CUSTOMIZE_RHODS_USE_CUSTOM_NOTEBOOK_SIZE" == 1 ]]; then
        # must be consistent with testing/ods/sizing/notebook_sizes
        ODS_NOTEBOOK_CPU_SIZE=1
        ODS_NOTEBOOK_MEMORY_SIZE=4Gi

        oc get odhdashboardconfig/odh-dashboard-config -n redhat-ods-applications -ojson \
            | jq '.spec.notebookSizes = [{"name": "'$ODS_NOTEBOOK_SIZE'", "resources": { "limits":{"cpu":"'$ODS_NOTEBOOK_CPU_SIZE'", "memory":"'$ODS_NOTEBOOK_MEMORY_SIZE'"}, "requests":{"cpu":"'$ODS_NOTEBOOK_CPU_SIZE'", "memory":"'$ODS_NOTEBOOK_MEMORY_SIZE'"}}}]' \
            | oc apply -f-
    fi

    if [[ "$CUSTOMIZE_RHODS_DASHBOARD_FORCED_IMAGE" ]]; then
        oc scale deploy/rhods-operator --replicas=0 -n redhat-ods-operator
        oc scale deploy/rhods-dashboard --replicas=0 -n redhat-ods-applications
        oc set image deploy/rhods-dashboard -n redhat-ods-applications "rhods-dashboard=$CUSTOMIZE_RHODS_DASHBOARD_FORCED_IMAGE"
        oc set probe deploy/rhods-dashboard -n redhat-ods-applications --remove --readiness --liveness
        oc scale deploy/rhods-dashboard --replicas=$CUSTOMIZE_RHODS_DASHBOARD_REPLICAS -n redhat-ods-applications
    fi
}

sutest_wait_rhods_launch() {
    switch_sutest_cluster

    if [[ "$CUSTOMIZE_RHODS" == 1 ]]; then
        sutest_customize_rhods_before_wait
    fi

    ./run_toolbox.py rhods wait_ods

    if [[ "$CUSTOMIZE_RHODS" == 1 ]]; then
        sutest_customize_rhods_after_wait

        ./run_toolbox.py rhods wait_ods
    fi


    if [[ -z "$ENABLE_AUTOSCALER" ]]; then
        rhods_notebook_image_tag=$(oc get istag -n redhat-ods-applications -oname \
                                       | cut -d/ -f2 | grep "$RHODS_NOTEBOOK_IMAGE_NAME" | cut -d: -f2)

        NOTEBOOK_IMAGE="image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/$RHODS_NOTEBOOK_IMAGE_NAME:$rhods_notebook_image_tag"
        # preload the image only if auto-scaling is disabled
        ./run_toolbox.py cluster preload_image "notebook" "$NOTEBOOK_IMAGE" \
                         --namespace=redhat-ods-applications
    fi

    osd_cluster_name=$(get_osd_cluster_name "sutest")
    if [[ "$osd_cluster_name" ]]; then
        machine_type=$OSD_SUTEST_COMPUTE_MACHINE_TYPE
    else
        machine_type=$OCP_SUTEST_COMPUTE_MACHINE_TYPE
    fi

    oc annotate namespace/rhods-notebooks --overwrite \
       "openshift.io/node-selector=node.kubernetes.io/instance-type=$machine_type"
}

capture_environment() {
    switch_sutest_cluster
    ./run_toolbox.py rhods capture_state > /dev/null || true
    ./run_toolbox.py cluster capture_environment > /dev/null || true

    switch_driver_cluster
    ./run_toolbox.py cluster capture_environment > /dev/null || true
}

prepare_ci() {
    cp "$THIS_DIR/common.sh" "$ARTIFACT_DIR" # save the settings of this run

    sutest_osd_cluster_name=$(get_osd_cluster_name "sutest")
    connect_sutest_cluster "$sutest_osd_cluster_name"
}

prepare() {
    process_ctrl::run_in_bg prepare_sutest_cluster
    process_ctrl::run_in_bg prepare_driver_cluster

    process_ctrl::wait_bg_processes

    sutest_wait_rhods_launch
}

run_test() {
    switch_driver_cluster

    REDIS_SERVER="redis.${STATESIGNAL_REDIS_NAMESPACE}.svc"

    NGINX_SERVER="nginx-$NGINX_NOTEBOOK_NAMESPACE"
    nginx_hostname=$(oc whoami --show-server | sed "s/api/$NGINX_SERVER.apps/g" | awk -F ":" '{print $2}' | sed s,//,,g)

    ./run_toolbox.py rhods notebook_ux_e2e_scale_test \
                     "$LDAP_IDP_NAME" \
                     "$ODS_CI_USER_PREFIX" "$ODS_CI_NB_USERS" \
                     "$S3_LDAP_PROPS" \
                     "http://$nginx_hostname/$ODS_NOTEBOOK_NAME" \
                     --sut_cluster_kubeconfig="$KUBECONFIG_SUTEST" \
                     --artifacts-collected="$ODS_CI_ARTIFACTS_COLLECTED" \
                     --ods_sleep_factor="$ODS_SLEEP_FACTOR" \
                     --ods_ci_exclude_tags="$ODS_EXCLUDE_TAGS" \
                     --ods_ci_artifacts_exporter_istag="$ODS_CI_IMAGESTREAM:$ODS_CI_ARTIFACTS_EXPORTER_TAG" \
                     --ods_ci_notebook_image_name="$RHODS_NOTEBOOK_IMAGE_NAME" \
                     --state_signal_redis_server="${REDIS_SERVER}"
}

driver_cleanup() {
    oc delete machineset "$DRIVER_MACHINESET_NAME" -n openshift-machine-api
}

sutest_cleanup() {
    switch_sutest_cluster
    sutest_cleanup_ldap

    osd_cluster_name=$(get_osd_cluster_name "$cluster_role")
    if [[ "$osd_cluster_name" ]]; then
        ocm delete machinepool "$SUTEST_MACHINESET_NAME"
    else
        oc delete machineset "$SUTEST_MACHINESET_NAME" -n openshift-machine-api
    fi
}

sutest_cleanup_ldap() {
    switch_sutest_cluster

    if ! ./run_toolbox.py rhods cleanup_notebooks "$ODS_CI_USER_PREFIX" > /dev/null; then
        echo "WARNING: rhods notebook cleanup failed :("
    fi

    if oc get cm/keep-cluster -n default 2>/dev/null; then
        echo "INFO: cm/keep-cluster found, not undeploying LDAP."
        return
    fi

    osd_cluster_name=$(get_osd_cluster_name "sutest")
    ./run_toolbox.py cluster undeploy_ldap \
                     "$LDAP_IDP_NAME" \
                     --use_ocm="$osd_cluster_name" > /dev/null
}

run_prepare_local_cluster() {
    prepare_driver_cluster
    prepare_sutest_cluster "$(get_osd_cluster_name "sutest")"

    process_ctrl::wait_bg_processes

    sutest_wait_rhods_launch
}

generate_plots() {
    mkdir "$ARTIFACT_DIR/plotting"
    if ARTIFACT_DIR="$ARTIFACT_DIR/plotting" ./testing/ods/generate_matrix-benchmarking.sh > "$ARTIFACT_DIR/plotting/build-log.txt" 2>&1; then
        echo "INFO: MatrixBenchmarkings plots successfully generated."
    else
        errcode=$?
        echo "ERROR: MatrixBenchmarkings plots generated failed. See logs in \$ARTIFACT_DIR/plotting/build-log.txt"
        return $errcode
    fi
}

# ---

finalizers+=("process_ctrl::kill_bg_processes")

switch_driver_cluster
oc get clusterversion/version
oc whoami --show-console

switch_sutest_cluster
oc get clusterversion/version
oc whoami --show-console

action=${1:-run_ci_e2e_test}

case ${action} in
    "run_ci_e2e_test")
        if [ -z "${SHARED_DIR:-}" ]; then
            echo "FATAL: multi-stage test \$SHARED_DIR not set ..."
            exit 1
        fi
        finalizers+=("capture_environment")
        finalizers+=("sutest_cleanup")
        finalizers+=("driver_cleanup")

        prepare_ci
        prepare

        failed=0
        BASE_ARTIFACT_DIR=$ARTIFACT_DIR
        for idx in $(seq $NOTEBOOK_TEST_RUNS); do
            export ARTIFACT_DIR="$BASE_ARTIFACT_DIR/test_run_$idx"
            mkdir -p "$ARTIFACT_DIR"
            pr_file="$BASE_ARTIFACT_DIR"/pull_request.json
            pr_comment_file="$BASE_ARTIFACT_DIR"/pull_request.json
            for f in "$pr_file" "$pr_comment_file"; do
                [[ -f "$f" ]] && cp "$f" "$ARTIFACT_DIR"
            done

            run_test && failed=0 || failed=1
            # quick access to these files
            cp "$ARTIFACT_DIR"/*__driver_rhods__notebook_ux_e2e_scale_test/{failed_tests,success_count} "$ARTIFACT_DIR" || true
            generate_plots
            if [[ "$failed" == 1 ]]; then
                break
            fi
        done
        export ARTIFACT_DIR="$BASE_ARTIFACT_DIR"
        exit $failed
        ;;
    "prepare")
        prepare
        exit 0
        ;;
    "deploy_rhods")
        prepare_sutest_deploy_rhods
        process_ctrl::wait_bg_processes
        exit 0
        ;;
    "wait_rhods")
        sutest_wait_rhods_launch
        process_ctrl::wait_bg_processes
        exit 0
        ;;
    "deploy_ldap")
        prepare_sutest_deploy_ldap
        process_ctrl::wait_bg_processes
        exit 0
        ;;
    "undeploy_ldap")
        sutest_cleanup_ldap
        exit 0
        ;;
    "prepare_driver_cluster")
        prepare_driver_cluster
        process_ctrl::wait_bg_processes
        exit 0
        ;;
    "run_test_and_plot")
        run_test
        generate_plots
        exit 0
        ;;
    "run_test")
        run_test
        exit 0
        ;;
    "generate_plots")
        generate_plots
        exit  0
        ;;
    "source")
        # file is being sourced by another script
        ;;
    *)
        echo "FATAL: Unknown action: ${action}" "$@"
        exit 1
        ;;
esac
