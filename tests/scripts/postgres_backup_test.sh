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
while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ]; then
        echo dump >"$2"
    fi
    shift
done
EOF
    cat >"$WORK_DIR/bin/zip" <<'EOF'
#!/bin/bash
cp "$3" "$2"
EOF
    cat >"$WORK_DIR/bin/aws" <<'EOF'
#!/bin/bash
echo "$*" >>"$WORK_DIR/aws-calls"
case "$1 $2" in
    "s3api list-buckets")
        if [ -f "$WORK_DIR/list-buckets-error" ]; then
            cat "$WORK_DIR/list-buckets-error" >&2
            exit 254
        fi
        cat "$WORK_DIR/buckets"
        ;;
    "sts get-caller-identity") echo "$FAKE_ACCOUNT_ID" ;;
    "s3api list-objects-v2") if [ -f "$WORK_DIR/objects" ]; then cat "$WORK_DIR/objects"; fi ;;
esac
EOF
    chmod +x "$WORK_DIR/bin/apk" "$WORK_DIR/bin/pg_dump" "$WORK_DIR/bin/zip" "$WORK_DIR/bin/aws"
}

buckets() {
    local IFS=$'\t'
    printf '%s\n' "$*" >"$WORK_DIR/buckets"
}

deny_bucket_listing() {
    echo "An error occurred (AccessDenied) when calling the ListBuckets operation: Access Denied" >"$WORK_DIR/list-buckets-error"
}

eight_backups() {
    printf 'backup-8.zip\tbackup-7.zip\tbackup-6.zip\tbackup-5.zip\tbackup-4.zip\tbackup-3.zip\tbackup-2.zip\tbackup-1.zip\n' >"$WORK_DIR/objects"
}

run_backup() {
    setup_stubs
    backup_script | sed "s#/tmp/#$WORK_DIR/#g" >"$WORK_DIR/backup.sh"
    PATH="$WORK_DIR/bin:$PATH" \
        S3_ENDPOINT="$1" \
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
    assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
    assert_contains "$(calls_to "s3 cp ")" "--endpoint-url https://$AWS_ENDPOINT --expected-bucket-owner $ACCOUNT_ID"
    assert_contains "$(calls_to "s3api list-objects-v2 ")" "--expected-bucket-owner $ACCOUNT_ID"
    assert_eq "$(calls_to "s3 rm ")" "s3 rm s3://5stack-db-backups/backup-1.zip --endpoint-url https://$AWS_ENDPOINT --expected-bucket-owner $ACCOUNT_ID"
}

test_a_listed_bucket_on_b2_is_uploaded_to_without_an_aws_owner() {
    buckets 5stack-db-backups
    eight_backups
    run_backup "$B2_ENDPOINT"
    assert_succeeded
    assert_contains "$(calls_to "s3api list-buckets ")" "--endpoint-url https://$B2_ENDPOINT --query Buckets[].Name --output text"
    assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
    assert_eq "$(calls_to "s3 rm ")" "s3 rm s3://5stack-db-backups/backup-1.zip --endpoint-url https://$B2_ENDPOINT"
    assert_not_contains "$(aws_calls)" "--expected-bucket-owner"
    assert_not_contains "$(aws_calls)" "sts "
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
    deny_bucket_listing
    run_backup "$B2_ENDPOINT"
    assert_succeeded
    assert_contains "$(cat "$WORK_DIR/output")" "because these S3 keys can't list buckets"
    assert_contains "$(calls_to "s3 cp ")" "s3://5stack-db-backups/backup-"
}

test_aws_keys_that_cannot_list_buckets_still_upload_only_as_this_account() {
    deny_bucket_listing
    run_backup "$AWS_ENDPOINT"
    assert_succeeded
    assert_contains "$(calls_to "s3 cp ")" "--expected-bucket-owner $ACCOUNT_ID"
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
        assert_eq "$(calls_to "s3 rm ")" "s3 rm s3://5stack-db-backups/backup-1.zip --endpoint-url http://$host:9000"
        assert_not_contains "$(aws_calls)" "list-buckets"
        assert_not_contains "$(aws_calls)" "--expected-bucket-owner"
    done
}

run_tests
