#!/usr/bin/env bash

# This file is part of the RobinHood Library
# Copyright (C) 2021 Commissariat a l'energie atomique et aux energies
#                    alternatives
#
# SPDX-License-Identifer: LGPL-3.0-or-later

set -e

# The POSIX and Mongo backends are necessary for this test.
# We have to resort to the posix backend because directly inserting into
# Mongo makes it so the backend doesn't understand any of the tokens,
# ending in an EINVAL error.
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

    # "Create" test databases
    testdb1=$SUITE-1$test
    testdb2=$SUITE-2$test
}

teardown()
{
    mongo --quiet "$testdb1" --eval "db.dropDatabase()" >/dev/null
    mongo --quiet "$testdb2" --eval "db.dropDatabase()" >/dev/null
    rm -rf "$testdir"
}

test_sync()
{
    local output1="$1"
    local output2="$2"
    local seen=false

    # The second output is either contained in the first or equal to it
    # according to a simple if condition but grep disagrees, which is strange.
    # The workaround is to use simple boolean and two while loops, not
    # optimal but good enough for the small amount of entries.
    while read -r line; do
        while read -r line2; do
            if [[ "$line2" = "$line" ]]; then
                seen=true
                break;
        fi
        done <<< "$output1"

        if [ $seen = true ]; then
            break
        fi
    done <<< "$output2"

    if [[ $seen = false ]]; then
        error "sync resulted in different db state : db1 = '$output1'," \
              "db2 = '$output2'"
    fi
}

################################################################################
#                                    TESTS                                     #
################################################################################

test_sync_simple()
{
    touch fileA
    touch fileB
    mkdir dir
    touch dir/file1

    rbh_sync "rbh:posix:." "rbh:mongo:$testdb1"
    rbh_sync "rbh:mongo:$testdb1" "rbh:mongo:$testdb2"

    local output1=$(mongo --quiet $testdb1 --eval "db.entries.find()")
    local output2=$(mongo --quiet $testdb2 --eval "db.entries.find()")

    n_output1=$(echo "$output1" | wc -l)
    n_output2=$(echo "$output2" | wc -l)

    test_sync "$output1" "$output2"

    if [[ $n_output1 -ne $n_output2 ]]; then
        error "sync resulted in different db state"
    fi
}

test_sync_branch()
{
    touch fileA
    mkdir dir
    touch dir/fileB

    rbh_sync "rbh:posix:." "rbh:mongo:$testdb1"
    rbh_sync "rbh:mongo:$testdb1#dir" "rbh:mongo:$testdb2"

    local output1=$(mongo --quiet $testdb1 --eval "db.entries.find()")
    local output2=$(mongo --quiet $testdb2 --eval "db.entries.find()")

    n_output1=$(echo "$output1" | wc -l)
    n_output2=$(echo "$output2" | wc -l)

    test_sync "$output1" "$output2"

    if [[ $n_output2 -ne 2 ]]; then
        error "sync resulted in different db state"
    fi
}

################################################################################
#                                     MAIN                                     #
################################################################################

declare -a tests=(test_sync_simple test_sync_branch)

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
