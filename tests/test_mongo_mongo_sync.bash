#!/usr/bin/env bash

# This file is part of rbh-sync.
# Copyright (C) 2021 Commissariat a l'energie atomique et aux energies
#                    alternatives
#
# SPDX-License-Identifer: LGPL-3.0-or-later

set -e

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

__mongosh=$(which mongosh || which mongo)
mongosh()
{
    "$__mongosh" --quiet "$@"
}

setup()
{
    # Create a test directory and `cd` into it
    testdir=$SUITE-$test
    mkdir "$testdir"
    cd "$testdir"

    # Create test databases' names
    testdb1=$SUITE-1$test
    testdb2=$SUITE-2$test
}

teardown()
{
    mongosh "$testdb1" --eval "db.dropDatabase()" >/dev/null
    mongosh "$testdb2" --eval "db.dropDatabase()" >/dev/null
    rm -rf "$testdir"
}

error()
{
    echo "$*"
    exit 1
}

compare_outputs()
{
    # The second collection is either contained in the first or equal to it
    local output=$(mongosh $testdb1 --eval "
        db2 = db.getSiblingDB(\""$testdb2"\");
        function compareCollection(col1, col2){
            var same = true;
            var compared = col2.find().forEach(function(doc2){
                var doc1 = col1.findOne({_id: doc2._id});
                same = same && JSON.stringify(doc2)==JSON.stringify(doc1);
            });

            return same;
        }
        compareCollection(db.entries, db2.entries);
    ")

    if [[ "$output" != "true" ]]; then
        error "sync resulted in different db state"
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

    local output1=$(mongosh $testdb1 --eval "db.entries.find()")
    local output2=$(mongosh $testdb2 --eval "db.entries.find()")

    n_output1=$(echo "$output1" | wc -l)
    n_output2=$(echo "$output2" | wc -l)

    compare_outputs "$output1" "$output2"

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

    local output1=$(mongosh $testdb1 --eval "db.entries.find()")
    local output2=$(mongosh $testdb2 --eval "db.entries.find()")

    n_output1=$(echo "$output1" | wc -l)
    n_output2=$(echo "$output2" | wc -l)

    compare_outputs "$output1" "$output2"

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

    ("$test") && echo "$test: ✔" || error "$test: ✖"
    )
done
