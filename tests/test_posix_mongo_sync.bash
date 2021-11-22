#!/usr/bin/env bash

# This file is part of the RobinHood Library
# Copyright (C) 2021 Commissariat a l'energie atomique et aux energies
#                    alternatives
#
# SPDX-License-Identifer: LGPL-3.0-or-later

set -e

# The POSIX and Mongo backends are necessary for this test
stat /usr/lib64/librbh-posix.so >> /dev/null
stat /usr/lib64/librbh-mongo.so >> /dev/null

################################################################################
#                                  UTILITIES                                   #
################################################################################

SUITE=${BASH_SOURCE##*/}
SUITE=${SUITE%.*}

__rbh_sync=$(PATH="$PWD:$PATH" which rbh-sync)
rbh_sync()
{
    "$__rbh_sync" "$@"
}

__mongo=$(which mongosh || which mongo)
mongo()
{
    "$__mongo" "$@"
}

setup()
{
    # Create a test directory and `cd` into it
    testdir=$SUITE-$test
    mkdir "$testdir"
    cd "$testdir"

    # "Create" a test database
    testdb=$SUITE-$test
}

teardown()
{
    mongo --quiet "$testdb" --eval "db.dropDatabase()" >/dev/null
    rm -rf "$testdir"
}

find_attribute()
{
    local output="$1"
    local attr="$2"

    while [[ ! -z "$attr" ]]; do
        local output=$(echo "$output" | grep "$attr")
        if [[ -z "$output" ]]; then
            echo "failed to find attribute '$attr'"
            return 1
        fi
        shift
        attr="$2"
    done
}

################################################################################
#                                    TESTS                                     #
################################################################################

test_sync_2_files()
{
    truncate -s 1k "fileA"
    rbh_sync "rbh:posix:." "rbh:mongo:$testdb"

    local output=$(mongo --quiet $testdb --eval "db.entries.find()")
    find_attribute "$output" '"path" : "/"'
    find_attribute "$output" '"path" : "/fileA"'
}

test_sync_size()
{
    truncate -s 1k "fileA"
    echo "hello world !" >> "fileA"
    local length=$(wc -m "fileA" | cut -d' ' -f1)

    rbh_sync "rbh:posix:." "rbh:mongo:$testdb"
    local output=$(mongo --quiet $testdb --eval "db.entries.find()")
    find_attribute "$output" '"path" : "/fileA"' \
                             "\"size\" : NumberLong($length)"
}

test_sync_3_files()
{
    truncate -s 1k "fileA"
    truncate -s 1k "fileB"

    rbh_sync "rbh:posix:." "rbh:mongo:$testdb"
    local output=$(mongo --quiet $testdb --eval "db.entries.find()")
    find_attribute "$output" '"path" : "/"'
    find_attribute "$output" '"path" : "/fileA"'
    find_attribute "$output" '"path" : "/fileB"'
}

test_sync_xattrs()
{
    truncate -s 1k "fileA"
    setfattr -n user.a -v b "fileA"
    truncate -s 1k "fileB"
    setfattr -n user.c -v d "fileB"

    rbh_sync "rbh:posix:." "rbh:mongo:$testdb"
    local output=$(mongo --quiet $testdb --eval "db.entries.find()")
    find_attribute "$output" '"path" : "/fileA"' '"xattrs" : { "user" : { "a"'
    find_attribute "$output" '"path" : "/fileB"' '"xattrs" : { "user" : { "c"'
}

test_sync_subdir()
{
    mkdir "dir"
    truncate -s 1k "dir/file"
    truncate -s 1k "fileA"
    truncate -s 1k "fileB"

    rbh_sync "rbh:posix:." "rbh:mongo:$testdb"
    local output=$(mongo --quiet $testdb --eval "db.entries.find()")
    find_attribute "$output" '"path" : "/"'
    find_attribute "$output" '"path" : "/fileA"'
    find_attribute "$output" '"path" : "/fileB"'
    find_attribute "$output" '"path" : "/dir"'
    find_attribute "$output" '"path" : "/dir/file"'
}

test_sync_large_tree()
{
    local oldpath=$PWD

    rbh_sync "rbh:posix:.." "rbh:mongo:$testdb"
    local output=$(mongo --quiet $testdb --eval \
                       "DBQuery.shellBatchSize = 1000; db.entries.find()")

    # This is a workaround the fact that find outputs the given path before
    # each line, which is different than how paths are recorded in mongo
    cd ..
    for i in $(find *); do
        local grep_out=$(echo "$output" | grep "\"path\" : \"/$i\"")
        if [[ -z "$grep_out" ]]; then
            echo "failed to find '$i'"
            return 1
        fi
    done
    cd $oldpath
}

test_sync_one_one_file()
{
    truncate -s 1k "fileA"
    local length=$(wc -m "fileA" | cut -d' ' -f1)

    rbh_sync -o "rbh:posix:fileA" "rbh:mongo:$testdb"
    local output=$(mongo --quiet $testdb --eval "db.entries.find()")
    find_attribute "$output" "\"size\" : NumberLong($length)"
}

test_sync_one_two_files()
{
    truncate -s 1k "fileA"
    truncate -s 1k "fileB"
    setfattr -n user.a -v b "fileB"
    local length=$(wc -m "fileB" | cut -d' ' -f1)

    rbh_sync -o "rbh:posix:fileA" "rbh:mongo:$testdb"
    rbh_sync -o "rbh:posix:fileB" "rbh:mongo:$testdb"
    local output=$(mongo --quiet $testdb --eval "db.entries.find()")
    find_attribute "$output" "\"size\" : NumberLong($length)" \
                             '"xattrs" : { "user" : { "a"'

    local output_lines=$(echo "$output" | wc -l)
    if [[ $output_lines -ne 2 ]]; then
        echo "More or not enough files than asked for were synced"
        return 1
    fi
}

################################################################################
#                                     MAIN                                     #
################################################################################

declare -a tests=(test_sync_2_files test_sync_size test_sync_3_files
                  test_sync_xattrs test_sync_subdir test_sync_large_tree
                  test_sync_one_one_file test_sync_one_two_files)

tmpdir=$(mktemp --directory)
trap -- "rm -rf '$tmpdir'" EXIT
cd "$tmpdir"

for test in "${tests[@]}"; do
    (
    trap -- "teardown" EXIT
    setup

    ("$test") && echo "$test: ✔" || echo "$test: ✖"
    )
done
