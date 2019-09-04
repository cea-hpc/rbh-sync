/* This file is part of rbh-sync
 * Copyright (C) 2019 Commissariat a l'energie atomique et aux energies
 *                    alternatives
 *
 * SPDX-License-Identifer: LGPL-3.0-or-later
 *
 * author: Quentin Bouget <quentin.bouget@cea.fr>
 */

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <dlfcn.h>
#include <errno.h>
#include <error.h>
#include <stdio.h>
#include <stdlib.h>
#include <sysexits.h>

#include <sys/stat.h>

#include <robinhood.h>
#ifndef HAVE_STATX
# include <robinhood/statx.h>
#endif
#include <robinhood/utils.h>

#ifndef RBH_ITER_CHUNK_SIZE
# define RBH_ITER_CHUNK_SIZE (1 << 12)
#endif

static struct rbh_backend *from, *to;

static void
destroy_from(void)
{
    rbh_backend_destroy(from);
}

static void
destroy_to(void)
{
    rbh_backend_destroy(to);
}

static struct rbh_mut_iterator *chunks;

static void
destroy_chunks(void)
{
    rbh_mut_iter_destroy(chunks);
}

static void
_atexit(void (*function)(void))
{
    if (atexit(function))
        error(EXIT_FAILURE, 0, "cannot set atexit function");
}

struct convert_iterator {
    struct rbh_mut_iterator iterator;
    struct rbh_mut_iterator *fsentries;
    struct rbh_fsentry *fsentry;

    bool upsert;
    bool link;
};

static void *
iter_mut_next(struct rbh_mut_iterator *iterator)
{
    int save_errno = errno;
    void *next;

    do {
        errno = 0;
        next = rbh_mut_iter_next(iterator);
    } while (next == NULL && errno == EAGAIN);

    errno = errno ? : save_errno;
    return next;
}

static int
_convert_iter_next(struct convert_iterator *convert)
{
    struct rbh_fsentry *fsentry = convert->fsentry;
    bool upsert, link;

    convert->fsentry = NULL;
    do {
        free(fsentry);

        fsentry = iter_mut_next(convert->fsentries);
        if (fsentry == NULL)
            return -1;

        if (!(fsentry->mask & RBH_FP_ID))
            /* this should never happen */
            /* FIXME: log something about it */
            continue;

        /* What kind of fsevent should this fsentry be converted to? */
        upsert = (fsentry->mask & RBH_FP_PARENT_ID)
              && (fsentry->mask & RBH_FP_NAME);
        link = (fsentry->mask & RBH_FP_PARENT_ID)
            || (fsentry->mask & RBH_FP_SYMLINK);
    } while (!upsert && !link);

    convert->fsentry = fsentry;
    convert->upsert = upsert;
    convert->link = link;
    return 0;
}

static void *
convert_iter_next(void *iterator)
{
    struct convert_iterator *convert = iterator;
    struct rbh_fsentry *fsentry;
    struct rbh_fsevent *fsevent;

    /* Should the current fsentry generate any more fsevent? */
    if (!convert->upsert && !convert->link) {
        /* No => fetch the next one */
        if (_convert_iter_next(convert))
            return NULL;
        assert(convert->upsert || convert->link);
    }
    fsentry = convert->fsentry;

    if (convert->upsert) {
        fsevent = rbh_fsevent_upsert_new(
                &fsentry->id,
                fsentry->mask & RBH_FP_STATX ? fsentry->statx : NULL,
                fsentry->mask & RBH_FP_SYMLINK ? fsentry->symlink : NULL
                );
        if (fsevent == NULL)
            return NULL;
        convert->upsert = false;
        return fsevent;
    }

    if (convert->link) {
        fsevent = rbh_fsevent_link_new(&fsentry->id, &fsentry->parent_id,
                                       fsentry->name);
        if (fsevent == NULL)
            return NULL;
        convert->link = false;
        return fsevent;
    }

    __builtin_unreachable();
}

static void
convert_iter_destroy(void *iterator) {
    struct convert_iterator *convert = iterator;

    rbh_mut_iter_destroy(convert->fsentries);
    free(convert->fsentry);
    free(convert);
}

static const struct rbh_mut_iterator_operations CONVERT_ITER_OPS = {
    .next = convert_iter_next,
    .destroy = convert_iter_destroy,
};

static const struct rbh_mut_iterator CONVERT_ITER = {
    .ops = &CONVERT_ITER_OPS,
};

static struct rbh_mut_iterator *
convert_iter_new(struct rbh_mut_iterator *fsentries)
{
    struct convert_iterator *convert;

    convert = malloc(sizeof(*convert));
    if (convert == NULL)
        return NULL;

    convert->iterator = CONVERT_ITER;
    convert->fsentries = fsentries;
    convert->fsentry = NULL;
    convert->upsert = convert->link = false;

    return &convert->iterator;
}

static int
insert_fsentries(struct rbh_backend *backend,
                 struct rbh_mut_iterator *fsevents)
{
    struct rbh_mut_iterator *fsevents_tee[2];
    struct rbh_fsevent *fsevent;
    int save_errno;
    ssize_t rc;

    if (rbh_mut_iter_tee(fsevents, fsevents_tee))
        return -1;

    rc = rbh_backend_update(to, (struct rbh_iterator *)fsevents_tee[0]);
    save_errno = errno;
    rbh_mut_iter_destroy(fsevents_tee[0]);
    if (rc < 0) {
        rbh_mut_iter_destroy(fsevents_tee[1]);
        errno = save_errno;
        return -1;
    }

    do {
        do {
            errno = 0;
            fsevent = rbh_mut_iter_next(fsevents_tee[1]);
        } while (fsevent == NULL && errno == EAGAIN);

        if (fsevent == NULL)
            break;

        free(fsevent);
    } while (true);

    assert(errno);
    save_errno = errno;
    rbh_mut_iter_destroy(fsevents_tee[1]);
    errno = save_errno;
    return errno == ENODATA ? 0 : -1;
}

static int
usage(FILE *output)
{
    return fprintf(output, "usage: %s SOURCE DEST\n"
"Positional arguments:\n"
"    SOURCE  a robinhood URI\n"
"    DEST    a robinhood URI\n"
"\n"
"A robinhood URI is built as follows:\n"
"    "RBH_SCHEME":BACKEND:FSNAME[#{PATH|ID}]\n"
"where:\n"
"    BACKEND  is the name of a backend\n"
"    FSNAME   is the name of a filesystem for BACKEND\n"
"    PATH/ID  is the path/id of an fsentry managed by BACKEND:FSNAME (ID must\n"
"             be enclosed in square brackets '[ID]' to distinguish it from a\n"
"             path)\n", program_invocation_short_name);
}

int
main(int argc, char *argv[])
{
    struct rbh_mut_iterator *fsentries;
    struct rbh_mut_iterator *fsevents;
    struct rbh_mut_iterator *chunk;

    if (argc < 2) {
        usage(stderr);
        error(EX_USAGE, 0, "missing SOURCE argument");
    }

    from = rbh_backend_from_uri(argv[1]);
    _atexit(destroy_from);

    if (argc < 3) {
        usage(stderr);
        error(EX_USAGE, 0, "missing DEST argument");
    }

    to = rbh_backend_from_uri(argv[2]);
    _atexit(destroy_to);

    fsentries = rbh_backend_filter_fsentries(from, NULL, RBH_FP_ALL, STATX_ALL);
    if (fsentries == NULL)
        error(EXIT_FAILURE, errno, "rbh_backend_filter_fsentries");

    fsevents = convert_iter_new(fsentries);
    if (fsevents == NULL) {
        int save_errno = errno;
        rbh_mut_iter_destroy(fsentries);
        error(EXIT_FAILURE, save_errno, "convert_iter_new");
    }

    chunks = rbh_mut_iter_chunkify(fsevents, RBH_ITER_CHUNK_SIZE);
    if (chunks == NULL) {
        int save_errno = errno;
        rbh_mut_iter_destroy(fsevents);
        error(EXIT_FAILURE, save_errno, "rbh_mut_iter_chunkify");
    }
    _atexit(destroy_chunks);

    do {
        do {
            errno = 0;
            chunk = rbh_mut_iter_next(chunks);
        } while (chunk == NULL && errno == EAGAIN);

        if (chunk == NULL && errno == ENODATA)
            break;
        if (chunk == NULL)
            error(EXIT_FAILURE, errno, "while chunkifying SOURCE's entries");

        if (insert_fsentries(to, chunk)) {
            assert(errno != ENODATA);
            break;
        }
    } while (true);

    switch (errno) {
    case ENODATA:
        return EXIT_SUCCESS;
    case RBH_BACKEND_ERROR:
        error(EXIT_FAILURE, 0, "unhandled error: %s\n", rbh_backend_error);
    default:
        error(EXIT_FAILURE, errno, "while iterating over SOURCE's entries");
    }
}
