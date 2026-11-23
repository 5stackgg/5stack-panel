#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AWS_ENDPOINT="s3.us-east-1.amazonaws.com"
B2_ENDPOINT="s3.us-west-004.backblazeb2.com"
ACCOUNT_ID="111122223333"

backup_script() {
    awk '
        /^ *- \|$/ { in_block = 1; indent = -1; next }
        in_block {
            if ($0 ~ /^ *$/) { print ""; next }
            match($0, /^ */)
            if (indent < 0) { indent = RLENGTH }
            if (RLENGTH < indent) { exit }
            print substr($0, indent + 1)
        }
    ' "$TEST_ROOT/base/backups/postgres-backup-cronjob.yaml"
}

setup_stubs() {
    mkdir -p "$WORK_DIR/bin"
    cat >"$WORK_DIR/bin/apk" <<'EOF'
#!/bin/bash
EOF
    cat >"$WORK_DIR/bin/pg_dump" <<'EOF'
#!/bin/bash
echo "$*" >>"$WORK_DIR/pg-dump-calls"
database=""
file=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d) database="$2" ;;
        -f) file="$2" ;;
    esac
    shift
done
if [ -f "$WORK_DIR/fail-dump-$database" ]; then
    exit 1
fi
echo "dump of $database" >"$file"
EOF
    cat >"$WORK_DIR/bin/psql" <<'EOF'
#!/bin/bash
if [ -f "$WORK_DIR/fail-psql" ]; then
    exit 2
fi
cat "$WORK_DIR/plugin-databases" 2>/dev/null || true
EOF
    cat >"$WORK_DIR/bin/zip" <<'EOF'
#!/bin/bash
cp "$3" "$2"
EOF
    cat >"$WORK_DIR/bin/aws" <<'EOF'
#!/bin/bash
echo "$*" >>"$WORK_DIR/aws-calls"
expected_owner="$(printf '%s' " $* " | sed -n 's/.* --expected-bucket-owner \([^ ]*\) .*/\1/p')"
case "$1 $2" in
    "s3 cp" | "s3 rm")
        if [ -n "$expected_owner" ]; then
            printf '\nUnknown options: --expected-bucket-owner, %s\n\n' "$expected_owner" >&2
            exit 252
        fi
        ;;
    "s3api head-bucket")
        owner="$FAKE_ACCOUNT_ID"
        if [ -f "$WORK_DIR/bucket-owner" ]; then
            owner="$(cat "$WORK_DIR/bucket-owner")"
        fi
        if [ -n "$expected_owner" ] && [ "$expected_owner" != "$owner" ]; then
            echo "An error occurred (403) when calling the HeadBucket operation: Forbidden" >&2
            exit 254
        fi
        ;;
    "s3api list-buckets")
        if [ -f "$WORK_DIR/list-buckets-error" ]; then
            cat "$WORK_DIR/list-buckets-error" >&2
            exit 254
        fi
        cat "$WORK_DIR/buckets"
        ;;
    "sts get-caller-identity") echo "$FAKE_ACCOUNT_ID" ;;
    "s3api list-objects-v2")
        prefix="$(printf '%s' " $* " | sed -n 's/.* --prefix \([^ ]*\) .*/\1/p')"
        listing="$WORK_DIR/objects"
        if [ -n "$prefix" ] && [ "$prefix" != "backup-" ]; then
            listing="$WORK_DIR/objects-$(printf '%s' "$prefix" | tr '/' '_')"
        fi
        if [ -f "$listing" ]; then cat "$listing"; fi
        ;;
esac
EOF
    chmod +x "$WORK_DIR/bin/apk" "$WORK_DIR/bin/pg_dump" "$WORK_DIR/bin/psql" "$WORK_DIR/bin/zip" "$WORK_DIR/bin/aws"
}

buckets() {
    local IFS=$'\t'
    printf '%s\n' "$*" >"$WORK_DIR/buckets"
}

deny_bucket_listing() {
    echo "${1:-An error occurred (AccessDenied) when calling the ListBuckets operation: Access Denied}" >"$WORK_DIR/list-buckets-error"
}

eight_backups() {
    printf 'backup-8.zip\tbackup-7.zip\tbackup-6.zip\tbackup-5.zip\tbackup-4.zip\tbackup-3.zip\tbackup-2.zip\tbackup-1.zip\n' >"$WORK_DIR/objects"
}

run_backup() {
    setup_stubs
    backup_script | sed "s#/tmp/#$WORK_DIR/#g" >"$WORK_DIR/backup.sh"
    PATH="$WORK_DIR/bin:$PATH" \
        S3_ENDPOINT="$1" \
        DEMOS_DOMAIN="${2:-}" \
        S3_ACCESS_KEY=key \
        S3_SECRET=secret \
        POSTGRES_HOST=timescaledb \
        POSTGRES_PORT=5432 \
        POSTGRES_USER=hasura \
        POSTGRES_PASSWORD=password \
        POSTGRES_DB=hasura \
        FAKE_ACCOUNT_ID="$ACCOUNT_ID" \
        bash "$WORK_DIR/backup.sh" >"$WORK_DIR/output" 2>&1
    STATUS=$?
}

aws_calls() {
    cat "$WORK_DIR/aws-calls" 2>/dev/null || true
}

calls_to() {
    grep "^$1" "$WORK_DIR/aws-calls" 2>/dev/null || true
}

assert_succeeded() {
    [ "$STATUS" -eq 0 ] || fail "backup exited $STATUS: $(cat "$WORK_DIR/output")"
}

test_a_listed_bucket_on_aws_is_uploaded_to_only_as_this_account() {
    buckets other-bucket 5stack-db-backups
    eight_backups
    run_backup "$AWS_ENDPOINT"
    assert_succeeded
    assert_eq "$(calls_to "s3api head-bucket ")" "s3api head-bucket --bucket 5stack-db-backups --endpoint-url https://$AWS_ENDPOINT --expected-bucket-owner $ACCOUNT_ID"
    assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
    assert_contains "$(calls_to "s3api list-objects-v2 ")" "--expected-bucket-owner $ACCOUNT_ID"
    assert_eq "$(calls_to "s3api delete-object ")" "s3api delete-object --bucket 5stack-db-backups --key backup-1.zip --endpoint-url https://$AWS_ENDPOINT --expected-bucket-owner $ACCOUNT_ID"
}

test_every_spelling_of_an_aws_endpoint_checks_the_owner() {
    for endpoint in S3.US-EAST-1.AMAZONAWS.COM "$AWS_ENDPOINT/" "https://$AWS_ENDPOINT" s3.cn-north-1.amazonaws.com.cn; do
        rm -f "$WORK_DIR/aws-calls"
        buckets 5stack-db-backups
        run_backup "$endpoint"
        assert_succeeded
        assert_contains "$(calls_to "sts ")" "get-caller-identity"
        assert_contains "$(calls_to "s3api head-bucket ")" "--expected-bucket-owner $ACCOUNT_ID"
    done
}

test_an_aws_bucket_owned_by_another_account_is_never_uploaded_to() {
    deny_bucket_listing
    echo 444455556666 >"$WORK_DIR/bucket-owner"
    run_backup "$AWS_ENDPOINT"
    [ "$STATUS" -ne 0 ] || fail "backup succeeded into a bucket owned by another account"
    assert_contains "$(cat "$WORK_DIR/output")" "the backup bucket 5stack-db-backups isn't owned by AWS account $ACCOUNT_ID that these S3 keys belong to, or the keys lack s3:ListBucket on it, so the database dump was NOT uploaded"
    assert_eq "$(calls_to "s3 cp ")" ""
}

test_a_listed_bucket_on_b2_is_uploaded_to_without_an_aws_owner() {
    buckets 5stack-db-backups
    eight_backups
    run_backup "$B2_ENDPOINT"
    assert_succeeded
    assert_contains "$(calls_to "s3api list-buckets ")" "--endpoint-url https://$B2_ENDPOINT --query Buckets[].Name --output text"
    assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
    assert_eq "$(calls_to "s3api delete-object ")" "s3api delete-object --bucket 5stack-db-backups --key backup-1.zip --endpoint-url https://$B2_ENDPOINT"
    assert_not_contains "$(aws_calls)" "--expected-bucket-owner"
    assert_not_contains "$(aws_calls)" "sts "
    assert_not_contains "$(aws_calls)" "head-bucket"
}

test_a_bucket_outside_the_account_is_never_uploaded_to() {
    for endpoint in "$B2_ENDPOINT" "$AWS_ENDPOINT"; do
        rm -f "$WORK_DIR/aws-calls"
        buckets 5stack-db-backups-old other-bucket
        run_backup "$endpoint"
        [ "$STATUS" -ne 0 ] || fail "backup to $endpoint succeeded with a bucket outside the account"
        assert_contains "$(cat "$WORK_DIR/output")" "the backup bucket 5stack-db-backups isn't in the account these S3 keys belong to, so the database dump was NOT uploaded"
        assert_eq "$(calls_to "s3 cp ")" ""
    done
}

test_an_account_with_no_buckets_is_never_uploaded_to() {
    buckets
    run_backup "$B2_ENDPOINT"
    [ "$STATUS" -ne 0 ] || fail "backup succeeded into an account with no buckets"
    assert_eq "$(calls_to "s3 cp ")" ""
}

test_keys_that_cannot_list_buckets_still_upload_with_a_note() {
    for denial in "An error occurred (AccessDenied) when calling the ListBuckets operation: Access Denied" \
        "An error occurred (401) when calling the ListBuckets operation: Unauthorized"; do
        rm -f "$WORK_DIR/aws-calls"
        deny_bucket_listing "$denial"
        run_backup "$B2_ENDPOINT"
        assert_succeeded
        assert_contains "$(cat "$WORK_DIR/output")" "because these S3 keys can't list buckets"
        assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
    done
}

test_aws_keys_that_cannot_list_buckets_still_upload_only_as_this_account() {
    deny_bucket_listing
    run_backup "$AWS_ENDPOINT"
    assert_succeeded
    assert_contains "$(calls_to "s3api head-bucket ")" "--expected-bucket-owner $ACCOUNT_ID"
    assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
    assert_not_contains "$(cat "$WORK_DIR/output")" "can't list buckets"
}

test_a_listing_that_fails_for_another_reason_stops_before_uploading() {
    echo "Could not connect to the endpoint URL: \"https://$B2_ENDPOINT/\"" >"$WORK_DIR/list-buckets-error"
    run_backup "$B2_ENDPOINT"
    [ "$STATUS" -ne 0 ] || fail "backup succeeded when the bucket listing failed"
    assert_contains "$(cat "$WORK_DIR/output")" "Could not connect to the endpoint URL"
    assert_eq "$(calls_to "s3 cp ")" ""
}

test_the_in_cluster_store_uploads_without_listing_buckets() {
    for endpoint in "" rustfs minio; do
        rm -f "$WORK_DIR/aws-calls"
        eight_backups
        run_backup "$endpoint"
        assert_succeeded
        host="${endpoint:-rustfs}"
        assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
        assert_contains "$(calls_to "s3 cp ")" "--endpoint-url http://$host:9000"
        assert_eq "$(calls_to "s3api delete-object ")" "s3api delete-object --bucket 5stack-db-backups --key backup-1.zip --endpoint-url http://$host:9000"
        assert_not_contains "$(aws_calls)" "list-buckets"
        assert_not_contains "$(aws_calls)" "--expected-bucket-owner"
    done
}

test_s3_on_the_demos_domain_uploads_to_rustfs_inside_the_cluster() {
    for endpoint in demos.example.com "https://Demos.Example.com/" "demos.example.com:443"; do
        rm -f "$WORK_DIR/aws-calls"
        eight_backups
        run_backup "$endpoint" demos.example.com
        assert_succeeded
        assert_contains "$(calls_to "s3 cp ")" "--endpoint-url http://rustfs:9000"
        assert_eq "$(calls_to "s3api delete-object ")" "s3api delete-object --bucket 5stack-db-backups --key backup-1.zip --endpoint-url http://rustfs:9000"
        assert_not_contains "$(aws_calls)" "list-buckets"
        assert_not_contains "$(aws_calls)" "example.com"
    done
}

test_a_remote_bucket_beside_a_demos_domain_stays_remote() {
    buckets 5stack-db-backups
    run_backup "$B2_ENDPOINT" demos.example.com
    assert_succeeded
    assert_contains "$(calls_to "s3 cp ")" "--endpoint-url https://$B2_ENDPOINT"
    assert_contains "$(aws_calls)" "list-buckets"
}

plugin_databases() {
    printf '%s\n' "$@" >"$WORK_DIR/plugin-databases"
}

test_each_plugin_database_is_its_own_dump_in_its_own_folder_after_the_main_one() {
    plugin_databases plugin_arenas plugin_ranks
    run_backup ""
    assert_succeeded
    uploads="$(calls_to "s3 cp ")"
    assert_contains "$(echo "$uploads" | sed -n 1p)" "s3://5stack-db-backups/backup-"
    assert_contains "$(echo "$uploads" | sed -n 2p)" "s3://5stack-db-backups/plugin-databases/plugin_arenas/backup-"
    assert_contains "$(echo "$uploads" | sed -n 3p)" "s3://5stack-db-backups/plugin-databases/plugin_ranks/backup-"
    assert_contains "$(cat "$WORK_DIR/pg-dump-calls")" "-d plugin_arenas -F c -Z 0 -f"
    assert_not_contains "$(grep -e "-d plugin_arenas" "$WORK_DIR/pg-dump-calls")" "--no-owner"
}

test_the_main_backups_prune_only_counts_their_own_top_level_keys() {
    plugin_databases plugin_arenas
    printf 'plugin-databases/plugin_arenas/backup-9.zip\tbackup-8.zip\tbackup-7.zip\tbackup-6.zip\tbackup-5.zip\tbackup-4.zip\tbackup-3.zip\tbackup-2.zip\n' >"$WORK_DIR/objects"
    run_backup ""
    assert_succeeded
    assert_contains "$(calls_to "s3api list-objects-v2 ")" "--prefix backup-"
    assert_eq "$(calls_to "s3api delete-object ")" ""
}

test_each_plugin_database_keeps_its_own_newest_seven() {
    plugin_databases plugin_arenas
    printf 'plugin-databases/plugin_arenas/backup-8.zip\tplugin-databases/plugin_arenas/backup-7.zip\tplugin-databases/plugin_arenas/backup-6.zip\tplugin-databases/plugin_arenas/backup-5.zip\tplugin-databases/plugin_arenas/backup-4.zip\tplugin-databases/plugin_arenas/backup-3.zip\tplugin-databases/plugin_arenas/backup-2.zip\tplugin-databases/plugin_arenas/backup-1.zip\n' >"$WORK_DIR/objects-plugin-databases_plugin_arenas_"
    run_backup ""
    assert_succeeded
    assert_eq "$(calls_to "s3api delete-object ")" "s3api delete-object --bucket 5stack-db-backups --key plugin-databases/plugin_arenas/backup-1.zip --endpoint-url http://rustfs:9000"
}

test_a_plugin_database_that_fails_still_backs_up_the_rest_and_fails_the_job() {
    plugin_databases plugin_arenas plugin_broken plugin_ranks
    touch "$WORK_DIR/fail-dump-plugin_broken"
    run_backup ""
    [ "$STATUS" -ne 0 ] || fail "backup succeeded with a plugin database that could not be dumped"
    uploads="$(calls_to "s3 cp ")"
    assert_contains "$uploads" "s3://5stack-db-backups/backup-"
    assert_contains "$uploads" "plugin-databases/plugin_arenas/"
    assert_contains "$uploads" "plugin-databases/plugin_ranks/"
    assert_not_contains "$uploads" "plugin_broken"
    assert_contains "$(cat "$WORK_DIR/output")" "the main database was backed up, but these plugin databases were NOT: plugin_broken"
}

test_a_failed_plugin_listing_fails_the_job_after_the_main_backup() {
    touch "$WORK_DIR/fail-psql"
    run_backup ""
    [ "$STATUS" -ne 0 ] || fail "backup succeeded without listing the plugin databases"
    assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
    assert_contains "$(cat "$WORK_DIR/output")" "could not list the plugin databases"
}

test_no_plugin_databases_means_only_the_main_backup() {
    run_backup ""
    assert_succeeded
    assert_eq "$(calls_to "s3 cp " | wc -l | tr -d ' ')" "1"
}

run_tests
