#!/usr/bin/env bash

set -xe

rbh_sync=./rbh-sync

function error
{
    echo "$*"
    exit 1
}

function test_sync
{
    local dir=$(mktemp --dir)
    local random_string="${dir##*.}"

    truncate -s 1k $dir/fileA

    rbh-sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/\""
    echo "$output" | grep "\"path\" : \"/fileA\""

    echo "hello world !" >> $dir/fileA
    local length=$(wc -m $dir/fileA | cut -d' ' -f1)

    rbh-sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/fileA\"" | \
                     grep "\"size\" : NumberLong($length)"

    truncate -s 1k $dir/fileB

    rbh-sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/\""
    echo "$output" | grep "\"path\" : \"/fileA\""
    echo "$output" | grep "\"path\" : \"/fileB\""

    setfattr -n user.a -v b $dir/fileA
    setfattr -n user.c -v d $dir/fileB

    rbh-sync "rbh:posix:$dir" "rbh:mongo:$random_string"
    local output=$(mongo --quiet $random_string --eval "db.entries.find()")
    echo "$output" | grep "\"path\" : \"/fileA\"" | \
                     grep "\"xattrs\" : { \"user\" : { \"a\""
    echo "$output" | grep "\"path\" : \"/fileB\"" | \
                     grep "\"xattrs\" : { \"user\" : { \"c\""

    rm -rf $dir
}

test_sync
