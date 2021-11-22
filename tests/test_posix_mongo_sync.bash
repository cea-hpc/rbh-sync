#!/usr/bin/env bash

set -e

stat ./rbh-sync && rbh_sync=./rbh-sync || rbh_sync=rbh-sync

function error
{
    echo "$*"
    exit 1
}

function cleanup
{
    rm -rf $1
    mongo --quiet $2 --eval "db.dropDatabase()"
}

function test_sync
{
    local dir=$(mktemp --dir -t rbh_sync_test_posix_mongo_sync.XXXXX)
    local random_string="${dir##*.}"

    trap "cleanup $dir $random_string" EXIT

    truncate -s 1k "$dir/fileA"

    $rbh_sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/\"" || \
        error "failed to find root"
    echo "$output" | grep "\"path\" : \"/fileA\"" || \
        error "failed to find 'fileA'"

    echo "hello world !" >> "$dir/fileA"
    local length=$(wc -m "$dir/fileA" | cut -d' ' -f1)

    $rbh_sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/fileA\"" | \
                     grep "\"size\" : NumberLong($length)" || \
                     error "'fileA' did not have the proper size"

    truncate -s 1k "$dir/fileB"

    $rbh_sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/\"" || \
        error "failed to find root"
    echo "$output" | grep "\"path\" : \"/fileA\"" || \
        error "failed to find 'fileA'"
    echo "$output" | grep "\"path\" : \"/fileB\"" || \
        error "failed to find 'fileB'"

    setfattr -n user.a -v b "$dir/fileA"
    setfattr -n user.c -v d "$dir/fileB"

    $rbh_sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/fileA\"" | \
                     grep "\"xattrs\" : { \"user\" : { \"a\"" || \
                     error "'fileA' did not have the proper xattrs"
    echo "$output" | grep "\"path\" : \"/fileB\"" | \
                     grep "\"xattrs\" : { \"user\" : { \"c\"" || \
                     error "'fileB' did not have the proper xattrs"

    mkdir "$dir/dir"
    truncate -s 1k "$dir/dir/file1"

    $rbh_sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/\"" ||
        error "failed to find root"
    echo "$output" | grep "\"path\" : \"/fileA\"" || \
        error "failed to find 'fileA'"
    echo "$output" | grep "\"path\" : \"/fileB\"" || \
        error "failed to find 'fileB'"
    echo "$output" | grep "\"path\" : \"/dir\"" || \
        error "failed to find 'dir'"
    echo "$output" | grep "\"path\" : \"/dir/file1\"" || \
        error "failed to find 'dir/file1'"

    cleanup $dir $random_string

    $rbh_sync "rbh:posix:.." "rbh:mongo:$random_string"
    local output_file=$(mktemp -t rbh_sync_test_posix_mongo_sync_file.XXXXX)
    mongo --quiet $random_string --eval \
        "DBQuery.shellBatchSize = 1000; db.entries.find()" > $output_file

    # This is a workaround the fact that find outputs the given path before
    # each line, which is different than how paths are recorded in mongo
    cd ..
    for i in $(find *); do
        grep "\"path\" : \"/$i\"" $output_file || error "failed to find '$i'"
    done

    cd -
    rm $output_file
    cleanup $dir $random_string
}

function test_sync_one
{
    local dir=$(mktemp --dir -t rbh_sync_test_posix_mongo_sync.XXXXX)
    local random_string="${dir##*.}"

    trap "cleanup $dir $random_string" EXIT

    truncate -s 1k "$dir/fileA"
    local length=$(wc -m "$dir/fileA" | cut -d' ' -f1)

    $rbh_sync -o "rbh:posix:$dir/fileA" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"size\" : NumberLong($length)" || \
                     error "No file with size '$length' was found"

    truncate -s 1k "$dir/fileB"
    setfattr -n user.a -v b "$dir/fileB"
    local length=$(wc -m "$dir/fileB" | cut -d' ' -f1)

    $rbh_sync -o "rbh:posix:$dir/fileB" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"size\" : NumberLong($length)" || \
                     error "No file with size '$length' was found"
    echo "$output" | grep "\"size\" : NumberLong($length)" | \
                     grep "\"xattrs\" : { \"user\" : { \"a\"" ||
                     error "The file with size '$length' did not have the" \
                           "proper xattrs"

    local output_lines=$(echo "$output" | wc -l)
    if [ $output_lines -ne 2 ]; then
        error "More files than asked for were synced"
    fi

    cleanup $dir $random_string
}

test_sync
test_sync_one

trap - EXIT
