# This file is part of the RobinHood Library
# Copyright (C) 2021 Commissariat a l'energie atomique et aux energies
#                    alternatives
#
# SPDX-License-Identifer: LGPL-3.0-or-later

compil = meson.get_compiler('c')

integration_tests = ['test_posix_mongo_sync']

foreach t: integration_tests
    src_backend = t.split('_')[1]
    dst_backend = t.split('_')[2]
    src_dep = compil.find_library('librbh-' + src_backend, required : false)
    dst_dep = compil.find_library('librbh-' + dst_backend, required : false)
    if src_dep.found() and dst_dep.found()
        e = find_program(t + '.bash')
        test(t, e)
    else
        message ('librbh-' + src_backend + ' or librbh-' + dst_backend +
                 ' not found, skipped "' + t + '.bash"')
    endif
endforeach
