#!/usr/bin/env bash

set -e

# The POSIX and Mongo backends are necessary for this test.
# We have to resort to the posix backend because directly inserting into
# Mongo makes it so the backend doesn't understand any of the tokens,
# ending in an EINVAL error.
stat /usr/lib64/librbh-posix.so >> /dev/null
stat /usr/lib64/librbh-mongo.so >> /dev/null

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
    mongo --quiet $3 --eval "db.dropDatabase()"
}

function test_sync
{
    local seen=false
    local sync_mongo_db=$1
    local mongo_db1=$2
    local mongo_db2=$3

    $rbh_sync "rbh:mongo:$sync_mongo_db" "rbh:mongo:$mongo_db2"
    local output1=$(mongo --quiet $mongo_db1 --eval "db.entries.find()")
    local output2=$(mongo --quiet $mongo_db2 --eval "db.entries.find()")

    n_output1=$(echo "$output1" | wc -l)
    n_output2=$(echo "$output2" | wc -l)

    # The second output is either contained in the first or eual to it
    # according to a simple if condition but grep disagrees, which is strange.
    # The workaround is to use simple boolean and double while loop, not
    # optimal but good enough for the small amount of entries.
    while IFS= read -r line; do
        while IFS= read -r line2; do
            if [ "$line2" = "$line" ]; then
                seen=true
                break;
        fi
        done <<< "$output1"

        if [ $seen = true ]; then
            break
        fi
    done <<< "$output2"

    if [ $seen = false ]; then
        error "sync resulted in different db state : db1 = '$output1'," \
              "db2 = '$output2'"
    fi
}

function test_sync_simple
{
    local dir=$(mktemp --dir -t rbh_sync_test_mongo_mongo_sync.XXXXX)
    local random_string1="${dir##*.}1"
    local random_string2="${dir##*.}2"

    trap "cleanup $dir $random_string" EXIT

    touch $dir/fileA
    touch $dir/fileB
    mkdir $dir/dir
    touch $dir/dir/file1
    $rbh_sync rbh:posix:$dir rbh:mongo:$random_string1

    test_sync "$random_string1" "$random_string1" "$random_string2"

    if [ $n_output1 -ne $n_output2 ]; then
        error "sync resulted in different db state"
    fi

    cleanup $dir $random_string1 $random_string2
}

function test_sync_with_branch
{
    local dir=$(mktemp --dir -t rbh_sync_test_mongo_mongo_sync.XXXXX)
    local random_string1="${dir##*.}1"
    local random_string2="${dir##*.}2"

    trap "cleanup $dir $random_string" EXIT

    mkdir $dir/dir
    touch $dir/dir/file
    $rbh_sync rbh:posix:$dir rbh:mongo:$random_string1

    test_sync "$random_string1#dir" "$random_string1" "$random_string2"

    if [ $n_output2 -ne 2 ]; then
        error "sync resulted in different db state"
    fi

    cleanup $dir $random_string1 $random_string2
}

test_sync_simple
test_sync_with_branch

trap - EXIT
