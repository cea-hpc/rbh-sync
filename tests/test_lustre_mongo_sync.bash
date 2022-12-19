#!/usr/bin/env bash

# This file is part of the RobinHood Library
# Copyright (C) 2022 Commissariat a l'energie atomique et aux energies
#                    alternatives
#
# SPDX-License-Identifer: LGPL-3.0-or-later

test_dir=$(dirname $(readlink -e $0))
. $test_dir/test_utils.bash

################################################################################
#                                    TESTS                                     #
################################################################################

test_simple_sync()
{
    mkdir "dir"
    touch "dir/fileA"
    touch "dir/fileB"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    find_attribute '"ns.xattrs.path":"/"'
    find_attribute '"ns.xattrs.path":"/dir"'
    find_attribute '"ns.xattrs.path":"/dir/fileA"'
    find_attribute '"ns.xattrs.path":"/dir/fileB"'
}

get_hsm_state_value()
{
    # retrieve the hsm status which is in-between parentheses
    local state=$(lfs hsm_state "$1" | cut -d '(' -f2 | cut -d ')' -f1)
    # the hsm status is written in hexa, so remove the first two characters (0x)
    state=$(echo "${state:2}")
    # bc only understands uppercase hexadecimals, but hsm state only returns
    # lowercase, so we use some bashim to uppercase the whole string, and then
    # convert the hexa to decimal
    echo "ibase=16; ${state^^}" | bc
}

test_hsm_state_none()
{
    touch "none"
    touch "archived"
    lfs hsm_set --archived archived

    rbh-sync "rbh:lustre:." "rbh:mongo:$testdb"

    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "none") \
                   '"ns.xattrs.path" : "/none"'
}

test_hsm_state_archived_states()
{
    local states=("dirty" "lost" "released")

    for state in "${states[@]}"; do
        touch "${state}"
        sudo lfs hsm_archive "$state"

        while ! lfs hsm_state "$state" | grep "archived"; do
            sleep 0.5;
        done

        if [ "$state" == "released" ]; then
            sudo lfs hsm_release "$state"
        else
            sudo lfs hsm_set "--$state" "$state"
        fi
    done

    rbh-sync "rbh:lustre:." "rbh:mongo:$testdb"

    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "dirty")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "lost")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "released")
}

test_hsm_state_independant_states()
{
    local states=("archived" "exists" "norelease" "noarchive")

    for state in "${states[@]}"; do
        touch "${state}"
        sudo lfs hsm_set "--$state" "$state"
    done

    rbh-sync "rbh:lustre:." "rbh:mongo:$testdb"

    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "archived")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "exists")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "norelease")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "noarchive")
}

test_hsm_state_multiple_states()
{
    local states=("archived" "exists" "noarchive" "norelease")
    local length=${#states[@]}
    length=$((length - 1))

    for i in $(seq 0 $length); do
        local state=${states[$i]}
        touch "$state"

        for j in $(seq $i $length); do
            local flag=${states[$j]}

            sudo lfs hsm_set "--$flag" "$state"
        done
    done

    rbh-sync "rbh:lustre:." "rbh:mongo:$testdb"

    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "archived")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "exists")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "noarchive")
    find_attribute '"ns.xattrs.hsm_state":'$(get_hsm_state_value "norelease")
}

test_hsm_archive_id()
{
    touch "archive-id-0"
    touch "archive-id-1"

    lfs hsm_archive "archive-id-1"
    while ! lfs hsm_state "archive-id-1" | grep "archived"; do
        sleep 0.5;
    done

    rbh-sync "rbh:lustre:." "rbh:mongo:$testdb"

    local id_1=$(lfs hsm_state "archive-id-1" | cut -d ':' -f3)
    find_attribute '"ns.xattrs.hsm_archive_id":0'
    find_attribute '"ns.xattrs.hsm_archive_id":'$id_1
}

# TODO: test with other flags
test_flags()
{
    lfs setstripe -E 1k -c 2 -E -1 -c -1 "test_flags"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local flags=$(lfs getstripe -v "test_flags" | grep "lcm_flags" | \
                  cut -d ':' -f2 | xargs)

    find_attribute '"ns.xattrs.flags":'$flags '"ns.xattrs.path":"/test_flags"'
}

test_gen()
{
    lfs setstripe -E 1k -c 2 -E -1 -c -1 "test_gen_1"
    truncate -s 2k test_gen_1
    lfs setstripe -E 1M -c 2 -S 256k -E -1 -c -1 "test_gen_2"
    truncate -s 4M test_gen_2

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local gen_1=$(lfs getstripe -v "test_gen_1" | grep "lcm_layout_gen" | \
                  cut -d ':' -f2 | xargs)
    local gen_2=$(lfs getstripe -v "test_gen_2" | grep "lcm_layout_gen" | \
                  cut -d ':' -f2 | xargs)
    find_attribute '"ns.xattrs.gen":'$gen_1
    find_attribute '"ns.xattrs.gen":'$gen_2
}

# TODO: no idea how to modify the mirror count
test_mirror_count()
{
    lfs setstripe -E 1M -c 2 -E -1 -c -1 "test_mc"
    truncate -s 2M "test_mc"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local mc=$(lfs getstripe -v "test_mc" | grep "lcm_mirror_count" | \
               cut -d ':' -f2 | xargs)
    find_attribute '"ns.xattrs.mirror_count":'$mc '"ns.xattrs.path":"/test_mc"'
}

test_stripe_count()
{
    lfs setstripe -E 1M -c 2 -E 2M -c 1 -E -1 -c -1 "test_sc"
    truncate -s 2M "test_sc"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local sc_array=$(lfs getstripe -v "test_sc" | grep "lmm_stripe_count" | \
                     cut -d ':' -f2 | xargs)
    sc_array=$(build_long_array ${sc_array[@]})

    find_attribute '"ns.xattrs.stripe_count":'$sc_array
}

test_stripe_size()
{
    lfs setstripe -E 1M -S 256k -E 2M -S 1M -E -1 -S 1G "test_ss"
    truncate -s 2M "test_ss"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local ss_array=$(lfs getstripe -v "test_ss" | grep "lmm_stripe_size" | \
                     cut -d ':' -f2 | xargs)
    ss_array=$(build_long_array ${ss_array[@]})

    find_attribute '"ns.xattrs.stripe_size":'$ss_array
}

# TODO: test with overstripping and dom
test_pattern()
{
    lfs setstripe -E 1M -c 2 -E -1 -c -1 "test_pattern"
    truncate -s 2M "test_pattern"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local patterns=$(lfs getstripe -v "test_pattern" | grep "lmm_pattern" | \
                     cut -d ':' -f2 | xargs)
    patterns="${patterns//raid0/0}"
    pattern_array=$(build_long_array $patterns)

    find_attribute '"ns.xattrs.pattern":'$pattern_array
}

# TODO: test with other flags
test_comp_flags()
{
    lfs setstripe -E 1M -S 256k -E 2M -S 1M -E -1 -S 1G "test_comp_flags"
    truncate -s 1M "test_comp_flags"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local flags=$(lfs getstripe -v "test_comp_flags" | grep "lcme_flags" | \
                  cut -d ':' -f2 | xargs)
    flags="${flags//init/16}"
    flags_array=$(build_long_array $flags)

    find_attribute '"ns.xattrs.comp_flags":'$flags_array
}

test_pool()
{
    lfs setstripe -E 1M -p "test_pool1" -E 2G -p ""  -E -1 -p "test_pool2" \
        "test_pool"
    truncate -s 2M "test_pool"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local pools=()

    # If a component doesn't have an attributed pool, Lustre will not show it,
    # so we instead retrieve the pool of each component (which may not exist)
    # and add it to our array.
    # In this function, our final array will be ("test_pool1" "" "test_pool2")
    local n_comp=$(lfs getstripe --component-count "test_pool")
    for i in $(seq 1 $n_comp); do
        pools+=("\"$(lfs getstripe -I$i -p 'test_pool')\"")
    done

    pools_array=$(build_string_array ${pools[@]})

    find_attribute '"ns.xattrs.pool":'$pools_array
}

test_mirror_id()
{
    lfs setstripe -E 1M -c 2 -E 2M -c 1 -E -1 -c -1 "test_mirror_id"
    truncate -s 1M "test_mirror_id"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local mids=$(lfs getstripe -v "test_mirror_id" | grep "lcme_mirror_id" | \
                 cut -d ':' -f2 | xargs)
    mids_array=$(build_long_array $mids)

    find_attribute '"ns.xattrs.mirror_id":'$mids_array
}

test_begin()
{
    lfs setstripe -E 1M -c 1 -S 256k -E 512M -c 2 -S 512k -E -1 -c -1 -S 1024k \
        "test_begin"
    truncate -s 1M "test_begin"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local begins=$(lfs getstripe -v "test_begin" | \
                   grep "lcme_extent.e_start" | cut -d ':' -f2 | xargs)
    begins="${begins//EOF/-1}"
    begins_array=$(build_long_array $begins)

    find_attribute '"ns.xattrs.begin":'$begins_array
}

test_end()
{
    lfs setstripe -E 1M -c 1 -S 256k -E 512M -c 2 -S 512k -E -1 -c -1 -S 1024k \
        "test_end"
    truncate -s 2M "test_end"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local ends=$(lfs getstripe -v "test_end" | grep "lcme_extent.e_end" | \
                 cut -d ':' -f2 | xargs)
    ends="${ends//EOF/-1}"
    ends_array=$(build_long_array $ends)

    find_attribute '"ns.xattrs.end":'$ends_array
}

test_ost()
{
    lfs setstripe -E 1M -c 1 -S 256k -E 512M -c 2 -S 512k -E -1 -c -1 -S 1024k \
        "test_ost1"
    lfs setstripe -E 1M -c 2 -E -1 -c -1 "test_ost2"
    truncate -s 1k "test_ost1"
    truncate -s 2M "test_ost2"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local ost1s=$(lfs getstripe -v "test_ost1" | grep "l_ost_idx" | \
                 cut -d ':' -f3 | cut -d ',' -f1 | xargs)
    local ost2s=$(lfs getstripe -v "test_ost2" | grep "l_ost_idx" | \
                 cut -d ':' -f3 | cut -d ',' -f1 | xargs)

    # An object with PFL layout may not have all components containing data.
    # This is registered as -1 in the database. To know if and how many -1 must
    # be added to the query string, we retrieve the number of components and the
    # number of objects of each components given back by Lustre. If they differ,
    # we add that many "-1" to the string
    local n_comp=$(lfs getstripe --component-count "test_ost1")
    local real_comp=$(lfs getstripe -v "test_ost1" | grep "lmm_objects" | wc -l)

    for i in $(seq $real_comp $((n_comp - 1))); do
        ost1s+=" -1"
    done

    n_comp=$(lfs getstripe --component-count "test_ost2")
    real_comp=$(lfs getstripe -v "test_ost2" | grep "lmm_objects" | wc -l)

    for i in $(seq $real_comp $((n_comp - 1))); do
        ost2s+=" -1"
    done

    ost1s_array=$(build_long_array $ost1s)
    ost2s_array=$(build_long_array $ost2s)

    find_attribute '"ns.xattrs.ost":'$ost1s_array
    find_attribute '"ns.xattrs.ost":'$ost2s_array
}

test_mdt_index_file()
{
    touch "test_mdt_index"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local mdt_index=$(lfs getstripe -m "test_mdt_index")

    find_attribute '"ns.xattrs.mdt_index":'$mdt_index
}

# TODO: test with multiple MDTs
test_mdt_index_dir()
{
    mkdir "test_mdt_index"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local mdt_indexes="[$(lfs getdirstripe -m 'test_mdt_index')]"

    find_attribute '"ns.xattrs.mdt_idx":'$mdt_indexes \
                   '"ns.xattrs.path":"/test_mdt_index"'
}

test_mdt_hash()
{
    mkdir "test_mdt_hash1"
    lfs setdirstripe -D "test_mdt_hash1"
    mkdir "test_mdt_hash2"
    lfs setdirstripe -D -H fnv_1a_64 "test_mdt_hash2"
    mkdir "test_mdt_hash3"
    lfs setdirstripe -D -H all_char "test_mdt_hash3"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local mdt_hash1=$(lfs getdirstripe -D -H "test_mdt_hash1")
    mdt_hash1="${mdt_hash1//none/0}"
    local mdt_hash2=$(lfs getdirstripe -D -H "test_mdt_hash2")
    mdt_hash2="${mdt_hash2//fnv_1a_64/1}"
    local mdt_hash3=$(lfs getdirstripe -D -H "test_mdt_hash3")
    mdt_hash3="${mdt_hash3//all_char/2}"

    find_attribute '"ns.xattrs.mdt_hash":'$mdt_hash1 \
                   '"ns.xattrs.path":"/test_mdt_hash1"'
    find_attribute '"ns.xattrs.mdt_hash":'$mdt_hash2
    find_attribute '"ns.xattrs.mdt_hash":'$mdt_hash3
}

# TODO: test with multiple MDTs
test_mdt_count()
{
    lfs setdirstripe -c 1 "test_mdt_count"

    rbh_sync "rbh:lustre:." "rbh:mongo:$testdb"

    local mdt_count=$(lfs getdirstripe -D -c "test_mdt_count")

    find_attribute '"ns.xattrs.mdt_count":'$mdt_count \
                   '"ns.xattrs.path":"/test_mdt_count"'
}

################################################################################
#                                     MAIN                                     #
################################################################################

declare -a tests=(test_simple_sync)

if lctl get_param mdt.*.hsm_control | grep "enabled"; then
    tests+=(test_hsm_state_none test_hsm_state_archived_states
            test_hsm_state_independant_states test_hsm_state_multiple_states
            test_hsm_archive_id)
fi

tests+=(test_flags test_gen test_mirror_count test_stripe_count
        test_stripe_size test_pattern test_comp_flags test_pool test_mirror_id
        test_begin test_end test_ost test_mdt_index_file test_mdt_index_dir
        test_mdt_hash test_mdt_count)

LUSTRE_DIR=/mnt/lustre/
cd "$LUSTRE_DIR"

tmpdir=$(mktemp --directory --tmpdir=$LUSTRE_DIR)
trap -- "rm -rf '$tmpdir'" EXIT
cd "$tmpdir"

run_tests ${tests[@]}
