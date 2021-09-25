/* This file is part of rbh-sync
 * Copyright (C) 2019 Commissariat a l'energie atomique et aux energies
 *                    alternatives
 *
 * SPDX-License-Identifer: LGPL-3.0-or-later
 */

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <dlfcn.h>
#include <errno.h>
#include <error.h>
#include <getopt.h>
#include <robinhood/fsentry.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>

#include <sys/stat.h>

#include <robinhood.h>
#include <robinhood/statx.h>
#ifndef HAVE_STATX
# include <robinhood/statx-compat.h>
#endif
#include <robinhood/utils.h>

#ifndef RBH_ITER_CHUNK_SIZE
# define RBH_ITER_CHUNK_SIZE (1 << 12)
#endif

static struct rbh_backend *from, *to;

static void __attribute__((destructor))
destroy_from(void)
{
    if (from)
        rbh_backend_destroy(from);
}

static void __attribute__((destructor))
destroy_to(void)
{
    if (to)
        rbh_backend_destroy(to);
}

static struct rbh_mut_iterator *chunks;

static void __attribute__((destructor))
destroy_chunks(void)
{
    if (chunks)
        rbh_mut_iter_destroy(chunks);
}

static bool one = false;

/*----------------------------------------------------------------------------*
 |                                   sync()                                   |
 *----------------------------------------------------------------------------*/

    /*--------------------------------------------------------------------*
     |                           mut_iter_one()                           |
     *--------------------------------------------------------------------*/

struct one_iterator {
    struct rbh_mut_iterator iterator;
    void *element;
};

static void *
one_mut_iter_next(void *iterator)
{
    struct one_iterator *one = iterator;

    if (one->element) {
        void *element = one->element;

        one->element = NULL;
        return element;
    }

    errno = ENODATA;
    return NULL;
}

static void
one_mut_iter_destroy(void *iterator)
{
    struct one_iterator *one = iterator;

    free(one->element);
    free(one);
}

static const struct rbh_mut_iterator_operations ONE_ITER_OPS = {
    .next = one_mut_iter_next,
    .destroy = one_mut_iter_destroy,
};

static const struct rbh_mut_iterator ONE_ITERATOR = {
    .ops = &ONE_ITER_OPS,
};

static struct rbh_mut_iterator *
mut_iter_one(void *element)
{
    struct one_iterator *one;

    one = malloc(sizeof(*one));
    if (one == NULL)
        error(EXIT_FAILURE, errno, "malloc");

    one->element = element;
    one->iterator = ONE_ITERATOR;
    return &one->iterator;
}

    /*--------------------------------------------------------------------*
     |                           iter_convert()                           |
     *--------------------------------------------------------------------*/

/* A convert_iterator converts fsentries into fsevents.
 *
 * For each fsentry, it yields up to two fsevents (depending on the information
 * available in the fsentry): one RBH_FET_UPSERT, to create the inode in the
 * backend; and one RBH_FET_LINK to "link" the inode in the namespace.
 */
struct convert_iterator {
    struct rbh_mut_iterator iterator;
    struct rbh_iterator *fsentries;

    const struct rbh_fsentry *fsentry;
    bool upsert;
    bool link;
};

/* Advance a convert_iterator to its next fsentry */
static int
_convert_iter_next(struct convert_iterator *convert)
{
    const struct rbh_fsentry *fsentry;
    bool upsert, link;

    do {
        fsentry = rbh_iter_next(convert->fsentries);
        if (fsentry == NULL)
            return -1;

        if (!(fsentry->mask & RBH_FP_ID)) {
            /* this should never happen */
            /* FIXME: log something about it */
            upsert = link = false;
            continue;
        }

        /* What kind of fsevent should this fsentry be converted to? */
        upsert = (fsentry->mask & RBH_FP_STATX)
              || (fsentry->mask & RBH_FP_SYMLINK);
        link = (fsentry->mask & RBH_FP_PARENT_ID)
            && (fsentry->mask & RBH_FP_NAME);
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
    const struct rbh_fsentry *fsentry;
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
        struct {
            bool xattrs:1;
            bool statx:1;
            bool symlink:1;
        } has = {
            .xattrs = fsentry->mask & RBH_FP_INODE_XATTRS,
            .statx = fsentry->mask & RBH_FP_STATX,
            .symlink = fsentry->mask & RBH_FP_SYMLINK,
        };

        fsevent = rbh_fsevent_upsert_new(
                &fsentry->id,
                has.xattrs ? &fsentry->xattrs.inode : NULL,
                has.statx ? fsentry->statx : NULL,
                has.symlink ? fsentry->symlink : NULL
                );
        if (fsevent == NULL)
            return NULL;
        convert->upsert = false;
        return fsevent;
    }

    if (convert->link) {
        bool has_xattrs = fsentry->mask & RBH_FP_NAMESPACE_XATTRS;

        fsevent = rbh_fsevent_link_new(&fsentry->id,
                                       has_xattrs ? &fsentry->xattrs.ns : NULL,
                                       &fsentry->parent_id, fsentry->name);
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

    rbh_iter_destroy(convert->fsentries);
    free(convert);
}

static const struct rbh_mut_iterator_operations CONVERT_ITER_OPS = {
    .next = convert_iter_next,
    .destroy = convert_iter_destroy,
};

static const struct rbh_mut_iterator CONVERT_ITER = {
    .ops = &CONVERT_ITER_OPS,
};

static struct rbh_iterator *
iter_convert(struct rbh_iterator *fsentries)
{
    struct convert_iterator *convert;
    struct rbh_iterator *constified;

    convert = malloc(sizeof(*convert));
    if (convert == NULL)
        return NULL;

    convert->iterator = CONVERT_ITER;
    convert->fsentries = fsentries;
    convert->fsentry = NULL;
    convert->upsert = convert->link = false;

    constified = rbh_iter_constify(&convert->iterator);
    if (constified == NULL) {
        int save_errno = errno;

        rbh_mut_iter_destroy(&convert->iterator);
        errno = save_errno;
    }

    return constified;
}

struct projection_iterator {
    struct rbh_iterator iterator;

    struct rbh_iterator *fsentries;
    struct rbh_filter_projection projection;

    struct statx statx;
    struct rbh_fsentry fsentry;
};

static void
statx_project(struct statx *dest, const struct statx *source, uint32_t mask)
{
    dest->stx_mask = source->stx_mask & mask;

    if (dest->stx_mask & RBH_STATX_BLKSIZE)
        dest->stx_blksize = source->stx_blksize;

    if (dest->stx_mask & RBH_STATX_ATTRIBUTES) {
        dest->stx_attributes_mask = source->stx_attributes_mask;
        dest->stx_attributes = source->stx_attributes;
    }

    if (dest->stx_mask & RBH_STATX_NLINK)
        dest->stx_nlink = source->stx_nlink;

    if (dest->stx_mask & RBH_STATX_UID)
        dest->stx_uid = source->stx_uid;

    if (dest->stx_mask & RBH_STATX_GID)
        dest->stx_gid = source->stx_gid;

    if (dest->stx_mask & RBH_STATX_TYPE)
        dest->stx_mode = source->stx_mode & S_IFMT;

    if (dest->stx_mask & RBH_STATX_MODE)
        dest->stx_mode = source->stx_mode & ~S_IFMT;

    if (dest->stx_mask & RBH_STATX_INO)
        dest->stx_ino = source->stx_ino;

    if (dest->stx_mask & RBH_STATX_SIZE)
        dest->stx_size = source->stx_size;

    if (dest->stx_mask & RBH_STATX_BLOCKS)
        dest->stx_blocks = source->stx_blocks;

    if (dest->stx_mask & RBH_STATX_ATIME_SEC)
        dest->stx_atime.tv_sec = source->stx_atime.tv_sec;

    if (dest->stx_mask & RBH_STATX_ATIME_NSEC)
        dest->stx_atime.tv_nsec = source->stx_atime.tv_nsec;

    if (dest->stx_mask & RBH_STATX_BTIME_SEC)
        dest->stx_btime.tv_sec = source->stx_btime.tv_sec;

    if (dest->stx_mask & RBH_STATX_BTIME_NSEC)
        dest->stx_btime.tv_nsec = source->stx_btime.tv_nsec;

    if (dest->stx_mask & RBH_STATX_CTIME_SEC)
        dest->stx_ctime.tv_sec = source->stx_ctime.tv_sec;

    if (dest->stx_mask & RBH_STATX_CTIME_NSEC)
        dest->stx_ctime.tv_nsec = source->stx_ctime.tv_nsec;

    if (dest->stx_mask & RBH_STATX_MTIME_SEC)
        dest->stx_mtime.tv_sec = source->stx_mtime.tv_sec;

    if (dest->stx_mask & RBH_STATX_MTIME_NSEC)
        dest->stx_mtime.tv_nsec = source->stx_mtime.tv_nsec;

    if (dest->stx_mask & RBH_STATX_RDEV_MAJOR)
        dest->stx_rdev_major = source->stx_rdev_major;

    if (dest->stx_mask & RBH_STATX_RDEV_MINOR)
        dest->stx_rdev_minor = source->stx_rdev_minor;

    if (dest->stx_mask & RBH_STATX_DEV_MAJOR)
        dest->stx_dev_major = source->stx_dev_major;

    if (dest->stx_mask & RBH_STATX_DEV_MINOR)
        dest->stx_dev_minor = source->stx_dev_minor;

    if (dest->stx_mask & RBH_STATX_MNT_ID)
        dest->stx_mnt_id = source->stx_mnt_id;
}

#define SYMLINK_MAX_SIZE (1 << 16) /* 64KB */

static void
fsentry_project(struct rbh_fsentry *dest, const struct rbh_fsentry *source,
                const struct rbh_filter_projection *projection,
                struct statx *statxbuf)
{
    dest->mask = source->mask & projection->fsentry_mask;

    if (dest->mask & RBH_FP_ID)
        dest->id = source->id;

    if (dest->mask & RBH_FP_PARENT_ID)
        dest->parent_id = source->parent_id;

    if (dest->mask & RBH_FP_NAME)
        dest->name = source->name;

    if (dest->mask & RBH_FP_STATX) {
        if (source->statx->stx_mask == projection->statx_mask) {
            dest->statx = source->statx;
        } else {
            statx_project(statxbuf, source->statx, projection->statx_mask);
            dest->statx = statxbuf;
        }
    }

    if (dest->mask & RBH_FP_INODE_XATTRS) {
        /* TODO: support xattr projection */
        assert(projection->xattrs.inode.count == 0);

        dest->xattrs.inode = source->xattrs.inode;
    }

    if (dest->mask & RBH_FP_NAMESPACE_XATTRS) {
        /* TODO: support xattr projection */
        assert(projection->xattrs.ns.count == 0);

        dest->xattrs.ns = source->xattrs.ns;
    }

    if (dest->mask & RBH_FP_SYMLINK)
        strncpy(dest->symlink, source->symlink, SYMLINK_MAX_SIZE);
}

static const void *
projection_iter_next(void *iterator)
{
    struct projection_iterator *iter = iterator;
    const struct rbh_fsentry *fsentry;

    fsentry = rbh_iter_next(iter->fsentries);
    if (fsentry == NULL)
        return NULL;

    fsentry_project(&iter->fsentry, fsentry, &iter->projection, &iter->statx);

    return &iter->fsentry;
}

static void
projection_iter_destroy(void *iterator)
{
    struct projection_iterator *iter = iterator;

    rbh_iter_destroy(iter->fsentries);
    free(iter);
}

static struct rbh_iterator_operations PROJECTION_ITER_OPS = {
    .next = projection_iter_next,
    .destroy = projection_iter_destroy,
};

static struct rbh_iterator PROJECTION_ITERATOR = {
    .ops = &PROJECTION_ITER_OPS,
};

static struct rbh_iterator *
projection_iter_new(struct rbh_iterator *fsentries,
                    const struct rbh_filter_projection *projection)
{
    struct projection_iterator *iterator;

    iterator = malloc(sizeof(*iterator) + SYMLINK_MAX_SIZE);
    if (iterator == NULL)
        return NULL;

    iterator->iterator = PROJECTION_ITERATOR;
    iterator->fsentries = fsentries;
    iterator->projection = *projection;

    return &iterator->iterator;
}

static void
sync(const struct rbh_filter_projection *projection)
{
    const struct rbh_filter_options options = {
        .projection = *projection,
    };
    struct rbh_mut_iterator *_fsentries;
    struct rbh_iterator *fsentries;
    struct rbh_iterator *projected;
    struct rbh_iterator *fsevents;

    if (one) {
        struct rbh_fsentry *root;

        root = rbh_backend_root(from, projection);
        if (root == NULL)
            error(EXIT_FAILURE, errno, "rbh_backend_root");

        _fsentries = mut_iter_one(root);
        if (_fsentries == NULL)
            error(EXIT_FAILURE, errno, "rbh_mut_array_iterator");
    } else {
        /* "Dump" `from' */
        _fsentries = rbh_backend_filter(from, NULL, &options);
        if (_fsentries == NULL)
            error(EXIT_FAILURE, errno, "rbh_backend_filter_fsentries");
    }

    fsentries = rbh_iter_constify(_fsentries);
    if (fsentries == NULL) {
        int save_errno = errno;

        rbh_mut_iter_destroy(_fsentries);
        error(EXIT_FAILURE, save_errno, "rbh_iter_constify");
    }

    /* Filter out extra information the source backend may have provided */
    projected = projection_iter_new(fsentries, projection);
    if (projected == NULL) {
        int save_errno = errno;

        rbh_mut_iter_destroy(_fsentries);
        error(EXIT_FAILURE, save_errno, "projection_iter_new");
    }

    /* Convert all this information into fsevents */
    fsevents = iter_convert(projected);
    if (fsevents == NULL) {
        int save_errno = errno;

        rbh_iter_destroy(projected);
        error(EXIT_FAILURE, save_errno, "iter_convert");
    }

    /* XXX: the mongo backend tries to process all the fsevents at once in a
     *      single bulk operation, but a bulk operation is limited in size.
     *
     * Splitting `fsevents' into fixed-size sub-iterators solves this.
     */
    chunks = rbh_iter_chunkify(fsevents, RBH_ITER_CHUNK_SIZE);
    if (chunks == NULL) {
        int save_errno = errno;

        rbh_iter_destroy(fsevents);
        error(EXIT_FAILURE, save_errno, "rbh_mut_iter_chunkify");
    }

    /* Update `to' */
    do {
        struct rbh_iterator *chunk = rbh_mut_iter_next(chunks);
        int save_errno;
        ssize_t count;

        if (chunk == NULL) {
            if (errno == ENODATA || errno == RBH_BACKEND_ERROR)
                break;
            error(EXIT_FAILURE, errno, "while chunkifying SOURCE's entries");
        }

        count = rbh_backend_update(to, chunk);
        save_errno = errno;
        rbh_iter_destroy(chunk);
        if (count < 0) {
            errno = save_errno;
            assert(errno != ENODATA);
            break;
        }
    } while (true);

    switch (errno) {
    case ENODATA:
        return;
    case RBH_BACKEND_ERROR:
        error(EXIT_FAILURE, 0, "unhandled error: %s", rbh_backend_error);
        __builtin_unreachable();
    default:
        error(EXIT_FAILURE, errno, "while iterating over SOURCE's entries");
    }
}

/*----------------------------------------------------------------------------*
 |                                    cli                                     |
 *----------------------------------------------------------------------------*/

    /*--------------------------------------------------------------------*
     |                              usage()                               |
     *--------------------------------------------------------------------*/

static int
usage(void)
{
    const char *message =
        "usage: %s [-ho] [-ei FIELD] SOURCE DEST\n"
        "\n"
        "Upsert SOURCE's entries into DEST\n"
        "\n"
        "Positional arguments:\n"
        "    SOURCE  a robinhood URI\n"
        "    DEST    a robinhood URI\n"
        "\n"
        "Optional arguments:\n"
        "    -h,--help           show this message and exit\n"
        "    -e,--exclude FIELD  exclude FIELD from the synchronization\n"
        "                        (can be specified multiple times)\n"
        "    -i,--include FIELD  include FIELD in the synchronization\n"
        "                        (can be specified multiple times)\n"
        "    -o,--one            only consider the root of SOURCE\n"
        "    -s,--strict         fail if any explicitly required field is missing\n"
        "\n"
        "A robinhood URI is built as follows:\n"
        "    "RBH_SCHEME":BACKEND:FSNAME[#{PATH|ID}]\n"
        "\n"
        "  Where:\n"
        "    BACKEND  is the name of a backend\n"
        "    FSNAME   is the name of a filesystem for BACKEND\n"
        "    PATH/ID  is the path/id of an fsentry managed by BACKEND:FSNAME\n"
        "             (ID must be enclosed in square brackets '[ID]' to distinguish it\n"
        "             from a path)\n"
        "\n"
        "FIELD can be any of the following:\n"
        "    [x] id          [x] parent-id   [x] name        [x] statx\n"
        "    [x] symlink     [x] ns-xattrs   [x] xattrs\n"
        "\n"
        "  Where 'statx' also supports the following subfields:\n"
        "    [x] blksize     [x] attributes  [x] nlink       [x] uid\n"
        "    [x] gid         [x] type        [x] mode        [x] ino\n"
        "    [x] size        [x] btime.nsec  [x] btime.sec   [x] ctime.nsec\n"
        "    [x] ctime.sec   [x] mtime.nsec  [x] mtime.sec   [x] rdev.major\n"
        "    [x] rdev.minor  [x] dev.major   [x] dev.minor   [ ] mount-id\n"
        "\n"
        "  [x] indicates the field is included by default\n"
        "  [ ] indicates the field is excluded by default\n";

    return printf(message, program_invocation_short_name);
}

static uint32_t
str2statx_field(const char *string_)
{
    const char *string = string_;

    switch (*string++) {
    case 'a': /* atime.nsec, atime.sec, attributes */
        if (*string++ != 't')
            break;

        switch (*string++) {
        case 'i': /* atime.nsec, atime.sec */
            if (strncmp(string, "me.", 3))
                break;
            string += 3;

            switch (*string++) {
            case 'n':
                if (strcmp(string, "sec"))
                    break;
                return RBH_STATX_ATIME_NSEC;
            case 's':
                if (strcmp(string, "ec"))
                    break;
                return RBH_STATX_ATIME_SEC;
            }
            break;
        case 't': /* attributes */
            if (strcmp(string, "ributes"))
                break;
            return RBH_STATX_ATTRIBUTES;
        }
        break;
    case 'b': /* blksize, blocks, btime.nsec, btime.sec */
        switch (*string++) {
        case 'l': /* blksize, blocks */
            switch (*string++) {
            case 'k': /* blksize */
                if (strcmp(string, "size"))
                    break;
                return RBH_STATX_BLKSIZE;
            case 'o': /* blocks */
                if (strcmp(string, "cks"))
                    break;
                return RBH_STATX_BLOCKS;
            }
            break;
        case 't': /* btime.nsec, btime.sec */
            if (strncmp(string, "ime.", 4))
                break;
            string += 4;

            switch (*string++) {
            case 'n':
                if (strcmp(string, "sec"))
                    break;
                return RBH_STATX_BTIME_NSEC;
            case 's':
                if (strcmp(string, "ec"))
                    break;
                return RBH_STATX_BTIME_SEC;
            }
            break;
        }
        break;
    case 'c': /* ctime.nsec, ctime.sec */
        if (strncmp(string, "time.", 5))
            break;
        string += 5;

        switch (*string++) {
        case 'n':
            if (strcmp(string, "sec"))
                break;
            return RBH_STATX_CTIME_NSEC;
        case 's':
            if (strcmp(string, "ec"))
                break;
            return RBH_STATX_CTIME_SEC;
        }
        break;
    case 'd': /* dev.major, dev.minor */
        if (strncmp(string, "ev.m", 4))
            break;
        string += 4;

        switch (*string++) {
        case 'a':
            if (strcmp(string, "jor"))
                break;
            return RBH_STATX_DEV_MAJOR;
        case 'i':
            if (strcmp(string, "nor"))
                break;
            return RBH_STATX_DEV_MINOR;
        }
        break;
    case 'g': /* gid */
        if (strcmp(string, "id"))
            break;
        return RBH_STATX_GID;
    case 'i': /* ino */
        if (strcmp(string, "no"))
            break;
        return RBH_STATX_INO;
    case 'm': /* mode, mtime.nsec, mtime.sec */
        switch (*string++) {
        case 'o': /* mode */
            if (strcmp(string, "de"))
                break;
            return RBH_STATX_MODE;
        case 't': /* mtime.nsec, mtime.sec */
            if (strncmp(string, "ime.", 4))
                break;
            string += 4;

            switch (*string++) {
            case 'n':
                if (strcmp(string, "sec"))
                    break;
                return RBH_STATX_MTIME_NSEC;
            case 's':
                if (strcmp(string, "ec"))
                    break;
                return RBH_STATX_MTIME_SEC;
            }
            break;
        }
        break;
    case 'n': /* nlink */
        if (strcmp(string, "link"))
            break;
        return RBH_STATX_NLINK;
    case 'r': /* rdev.major, rdev.minor */
        if (strncmp(string, "dev.m", 5))
            break;
        string += 5;

        switch (*string++) {
        case 'a':
            if (strcmp(string, "jor"))
                break;
            return RBH_STATX_DEV_MAJOR;
        case 'i':
            if (strcmp(string, "nor"))
                break;
            return RBH_STATX_DEV_MINOR;
        }
        break;
    case 's': /* size */
        if (strcmp(string, "ize"))
            break;
        return RBH_STATX_SIZE;
    case 't': /* type */
        if (strcmp(string, "ype"))
            break;
        return RBH_STATX_TYPE;
    case 'u': /* uid */
        if (strcmp(string, "id"))
            break;
        return RBH_STATX_UID;
    }

    error(EX_USAGE, 0, "unknown statx field: %s", string_);
    __builtin_unreachable();
}

static const struct rbh_filter_field *
str2field(const char *string_)
{
    static struct rbh_filter_field field;
    const char *string = string_;

    switch (*string++) {
    case 'i': /* id */
        if (strcmp(string, "d"))
            break;
        field.fsentry = RBH_FP_ID;
        return &field;
    case 'n': /* name, ns-xattrs */
        switch (*string++) {
        case 'a': /* name */
            if (strcmp(string, "me"))
                break;
            field.fsentry = RBH_FP_NAME;
            return &field;
        case 's': /* ns-xattrs */
            if (strncmp(string, "-xattrs", 7))
                break;
            field.fsentry = RBH_FP_NAMESPACE_XATTRS;
            string += 6;

            switch (*string++) {
            case '\0':
                field.xattr = NULL;
                return &field;
            case '.':
                field.xattr = string;
                return &field;
            }
            break;
        }
        break;
    case 'p': /* parent-id */
        if (strcmp(string, "arent-id"))
            break;
        field.fsentry = RBH_FP_PARENT_ID;
        return &field;
    case 's': /* statx, symlink */
        switch (*string++) {
        case 't':
            if (strncmp(string, "atx", 3))
                break;
            string += 3;

            field.fsentry = RBH_FP_STATX;
            switch (*string++) {
            case '\0':
                field.statx = RBH_STATX_ALL;
                return &field;
            case '.':
                field.statx = str2statx_field(string);
                return &field;
            }
            break;
        case 'y':
            if (strcmp(string, "mlink"))
                break;
            field.fsentry = RBH_FP_SYMLINK;
            return &field;
        }
        break;
    case 'x': /* xattrs */
        if (strncmp(string, "attrs", 5))
            break;
        string += 5;

        field.fsentry = RBH_FP_INODE_XATTRS;
        switch (*string++) {
        case '\0':
            field.xattr = NULL;
            return &field;
        case '.':
            field.xattr = string;
            return &field;
        }
        break;
    }

    error(EX_USAGE, 0, "unknown field: %s", string_);
    __builtin_unreachable();
}

static void
projection_add(struct rbh_filter_projection *projection,
               const struct rbh_filter_field *field)
{
    projection->fsentry_mask |= field->fsentry;

    switch (field->fsentry) {
    case RBH_FP_ID:
    case RBH_FP_PARENT_ID:
    case RBH_FP_NAME:
        break;
    case RBH_FP_STATX:
        projection->statx_mask |= field->statx;
        break;
    case RBH_FP_SYMLINK:
    case RBH_FP_NAMESPACE_XATTRS:
        // TODO: handle subfields
        break;
    case RBH_FP_INODE_XATTRS:
        // TODO: handle subfields
        break;
    }
}

static void
projection_remove(struct rbh_filter_projection *projection,
                  const struct rbh_filter_field *field)
{
    projection->fsentry_mask &= ~field->fsentry;

    switch (field->fsentry) {
    case RBH_FP_ID:
    case RBH_FP_PARENT_ID:
    case RBH_FP_NAME:
        break;
    case RBH_FP_STATX:
        projection->statx_mask &= ~field->statx;
        if (projection->statx_mask & RBH_STATX_ALL)
            projection->fsentry_mask |= RBH_FP_STATX;
        break;
    case RBH_FP_SYMLINK:
    case RBH_FP_NAMESPACE_XATTRS:
        // TODO: handle subfields
        break;
    case RBH_FP_INODE_XATTRS:
        // TODO: handle subfields
        break;
    }
}

int
main(int argc, char *argv[])
{
    const struct option LONG_OPTIONS[] = {
        {
            .name = "exclude",
            .has_arg = required_argument,
            .val = 'e',
        },
        {
            .name = "help",
            .val = 'h',
        },
        {
            .name = "include",
            .has_arg = required_argument,
            .val = 'i',
        },
        {
            .name = "one",
            .val = 'o',
        },
        {}
    };
    struct rbh_filter_projection projection = {
        .fsentry_mask = RBH_FP_ALL,
        .statx_mask = RBH_STATX_ALL & ~RBH_STATX_MNT_ID,
    };
    char c;

    /* Parse the command line */
    while ((c = getopt_long(argc, argv, "e:hi:o", LONG_OPTIONS, NULL)) != -1) {
        switch (c) {
        case 'e':
            projection_remove(&projection, str2field(optarg));
            break;
        case 'h':
            usage();
            return 0;
        case 'i':
            projection_add(&projection, str2field(optarg));
            break;
        case 'o':
            one = true;
            break;
        case '?':
        default:
            /* getopt_long() prints meaningful error messages itself */
            exit(EX_USAGE);
        }
    }

    argc -= optind;
    argv += optind;

    if (argc < 2)
        error(EX_USAGE, 0, "not enough arguments");
    if (argc > 2)
        error(EX_USAGE, 0, "unexpected argument: %s", argv[2]);

    /* Parse SOURCE */
    from = rbh_backend_from_uri(argv[0]);
    /* Parse DEST */
    to = rbh_backend_from_uri(argv[1]);

    sync(&projection);

    return EXIT_SUCCESS;
}
