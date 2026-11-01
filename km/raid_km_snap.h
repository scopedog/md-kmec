/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * raidkm native snapshots (P2: crash safe).  Design:
 * notes/md-kmec/native-snapshot-design-2026-10-31.md (model) and
 * notes/md-kmec/native-snapshot-p2-design-2026-10-31.md (on disk, journal).
 *
 * An array created with --snapshots (RAIDKM_LAYOUT_SNAP, needs the row map)
 * exports origin rows L = 0..O-1 and keeps physical rows P = 0..R-1; rows
 * past the origin are the reserve that redirected rows go to.  A linear
 * chain of read-only snapshots, oldest first.
 *
 * What persists is one reverse map, rmap[P] = {L, owner}: every physical row
 * belongs to the origin, to one snapshot, or to nobody.  The origin map, the
 * exception lists and the used bitmap are rebuilt from it at assemble.  An
 * all-zero entry is the default (P < O: origin row P; P >= O: free), so a
 * zeroed map is an array with no snapshots.  Changes go to a journal first
 * (an origin write that needed a copy is acked once its record is durable),
 * checkpoints write the changed rmap pages.
 */
#ifndef _RAID_KM_SNAP_H
#define _RAID_KM_SNAP_H

#include <linux/types.h>
#include <linux/bio.h>
#include <linux/xarray.h>
#include <linux/workqueue.h>
#include <linux/hashtable.h>
#include <linux/mempool.h>
#include <linux/wait.h>

struct r5conf;
struct mddev;
struct md_rdev;

#define RK_SNAP_NAME	64
#define RK_SNAP_ATTRS	1024	/* "key=value key=value", what a snapshot tool keeps */
#define RK_SNAP_SLOTS	64	/* snapshots an array can hold */

/* ---- on disk (every member, after the row map; mdadm mirrors these) ---- */

#define RK_SN_PAGE	4096
#define RK_SN_TRAILER	16		/* id, gen, crc: as the row map's */
#define RK_SN_BODY	(RK_SN_PAGE - RK_SN_TRAILER)
#define RK_SN_VERSION	1

/* a different magic per kind of page, folded into the crc: a page is never
 * taken for another kind */
#define RK_SN_MAGIC_HDR		0x524b5348U	/* "RKSH" */
#define RK_SN_MAGIC_TBL		0x524b5354U	/* "RKST" */
#define RK_SN_MAGIC_PMAP	0x524b5350U	/* "RKSP" */
#define RK_SN_MAGIC_RMAP	0x524b5352U	/* "RKSR" */
#define RK_SN_MAGIC_JRNL	0x524b534aU	/* "RKSJ" */

#define RK_SN_TBL_PER_PAGE	3
#define RK_SN_TBL_PAGES		DIV_ROUND_UP(RK_SNAP_SLOTS, RK_SN_TBL_PER_PAGE)	/* 22 */
#define RK_SN_RMAP_PER_PAGE	(RK_SN_BODY / 8)	/* 510 */
#define RK_SN_PMAP_PER_PAGE	RK_SN_BODY		/* one byte per rmap page */
#define RK_SN_JPAGES		1024			/* journal ring, 4 MiB */

/* region layout, in 4 KiB pages from its start */
#define RK_SN_OFF_HDR		0			/* 2 copies */
#define RK_SN_OFF_TBL		2			/* 2 x RK_SN_TBL_PAGES */
#define RK_SN_OFF_PMAP		(RK_SN_OFF_TBL + 2 * RK_SN_TBL_PAGES)	/* 46 */

/* header body; mdadm writes one with R = 0 at create ("init": the kernel
 * sizes the origin from reserve_pct at the first assemble) */
struct rk_sn_hdr {
	__le32	magic;		/* RK_SN_MAGIC_HDR */
	__le32	version;
	__le32	reserve_pct;	/* 1..90, from mdadm --snapshots=<pct> */
	__le32	jpages;
	__le64	R;		/* physical rows; 0 = init header */
	__le64	O;		/* origin rows */
	__le64	rs;		/* row sectors */
	__le64	ckpt;		/* checkpoint number (also the trailer gen) */
	__le64	jtail;		/* first journal seq the checkpoint does not cover */
	__le32	next_id;
	__le32	slots;		/* RK_SNAP_SLOTS */
	__le64	rmap_pages;	/* per rmap slot */
} __packed;

struct rk_sn_tent {		/* one snapshot slot in the table */
	__le32	id;
	__le32	used;
	__le64	ctime;
	char	name[RK_SNAP_NAME];
	char	attrs[RK_SNAP_ATTRS];
} __packed;			/* 1104 bytes, 3 per page */

struct rk_sn_rent {		/* rmap[P] */
	__le32	L;
	__le16	owner;
	__le16	rsvd;
} __packed;

#define RK_SN_OWN_DEFAULT	0
#define RK_SN_OWN_ORIGIN	1
#define RK_SN_OWN_SNAP0		2	/* + slot */
#define RK_SN_OWN_FREE		0xffff

/* pmap byte per rmap page */
#define RK_SN_PM_TOUCHED	0x01	/* ever written: load reads it */
#define RK_SN_PM_SLOT		0x02	/* which rmap slot holds it */

/* journal record body: __le64 seq, __le16 len, then len bytes of ops */
#define RK_SN_JHDR		10
#define RK_SN_JMAX		(RK_SN_BODY - RK_SN_JHDR)

enum {
	RK_OP_REDIRECT = 1,	/* u32 L, oldP, newP */
	RK_OP_CREATE,		/* u8 slot, u32 id, s64 ctime, name[64] */
	RK_OP_DESTROY,		/* u8 slot */
	RK_OP_RENAME,		/* u8 slot, name[64] */
	RK_OP_SET,		/* u8 slot, u16 n, attrs[n] */
};

/* ---- in core -------------------------------------------------------------- */

struct raidkm_snap;
struct raidkm_snap_one;

/* something for the journal: a COW's redirect, or a create/destroy/... */
struct rk_snap_op {
	struct list_head	node;		/* sn->pending */
	u8			type;
	u8			slot;
	u32			L, oldP, newP;	/* REDIRECT */
	struct raidkm_snap_one	*g;		/* CREATE: the new one */
	char			*text;		/* RENAME: name; SET: attrs */
	blk_status_t		status;		/* REDIRECT: the data write's */
	struct completion	*done;		/* sync ops */
	int			err;
};

/* a COW in flight; a fixed set of them, see cow[] */
struct rk_snap_cow {
	struct work_struct	work;		/* partial rows: read-merge-write */
	struct hlist_node	node;		/* sn->busy */
	struct raidkm_snap	*sn;
	struct bio		*bio;		/* the origin write */
	bio_end_io_t		*end_io;	/* its own, while hooked */
	void			*private;
	u64			L;
	struct bio_list		waiters;	/* writes to L that came meanwhile */
	struct rk_snap_op	op;
};

#define RK_SNAP_COWS	64

struct raidkm_snap_one {
	struct list_head	list;		/* sn->snaps, oldest first */
	struct raidkm_snap	*sn;
	int			id;
	u8			slot;
	char			name[RK_SNAP_NAME];
	char			attrs[RK_SNAP_ATTRS];
	time64_t		ctime;
	struct xarray		exc;		/* L -> P + 1 (0 = none) */
	u64			nexc;
	struct gendisk		*disk;
	bool			dying;		/* destroy: no new open */
};

struct raidkm_snap {
	struct r5conf		*conf;
	u64			R, O;		/* physical rows, origin rows */
	u64			rs;		/* row sectors (array) */
	u32			*origin;	/* L -> P */
	unsigned long		*shared;	/* L shared with the newest */
	unsigned long		*used;		/* P referenced */
	u64			cursor;		/* allocator */
	u64			redirected;	/* L with origin[L] != L */
	unsigned int		piece;		/* pages per physical bio */
	spinlock_t		lock;		/* origin, shared, used, busy, snaps,
						 * pending, hold, overflow */
	struct mutex		mutex;		/* create / destroy / rename / set */
	struct list_head	snaps;
	int			nsnaps, next_id;
	DECLARE_BITMAP(slots, RK_SNAP_SLOTS);	/* table slots in use */
	DECLARE_HASHTABLE(busy, 8);		/* rk_snap_cow by L, in flight */
	/* COWs without allocation: map_bio() runs with md's active_io held,
	 * and create/destroy suspend the array (wait for it), so it never
	 * waits for memory or a COW */
	struct rk_snap_cow	cow[RK_SNAP_COWS];
	DECLARE_BITMAP(cow_busy, RK_SNAP_COWS);
	struct bio_list		overflow;	/* writes that found no free COW,
						 * or came while hold was set */
	bool			hold;		/* create/destroy: start no COW */
	atomic_t		cows;		/* COWs started, not yet finished */
	wait_queue_head_t	drain_wq;
	mempool_t		*buf_pool;	/* struct rk_rowbuf: one row */
	struct bio_set		bs;		/* physical bios */
	struct workqueue_struct	*wq;		/* partial COWs, disk adds */
	struct work_struct	disks_work;	/* add the snapshot disks */

	/* ---- persistence (raid_km-snapmeta.c) ---- */
	sector_t		region;		/* member sector rel. data_offset */
	u32			id;		/* crc32c of the array uuid */
	u32			reserve_pct;
	u64			N;		/* rmap pages per slot */
	u64			pmp;		/* pmap pages per copy */
	struct xarray		rmap;		/* P -> owner << 32 | L, non-default */
	u8			*pmap;		/* N bytes */
	unsigned long		*rdirty;	/* rmap pages changed since ckpt */
	u64			ckpt;		/* last complete checkpoint */
	u64			jtail, jhead;	/* journal: covered / next seq */
	bool			broken;		/* metadata reached no member */
	bool			jscrub;		/* after a load: clear the ring past
						 * the head before the next record */
	struct list_head	pending;	/* rk_snap_op for the next commit */
	struct workqueue_struct	*cwq;		/* commits, ordered */
	struct work_struct	commit_work;
	struct page		**jbuf;		/* record pages for one commit */
	unsigned int		jbuf_n;
	struct page		**cbuf;		/* checkpoint pages */
	struct md_rdev		**io_rdevs;	/* rk_sn_write_all(): one per member */
	struct bio		**io_bios;	/* slot (commit worker only) */
	atomic64_t		commits, records, ckpts, replayed;

	atomic64_t		cow_whole, cow_partial, cow_fail, cow_nospc, freed;
};

enum { RK_SNAP_GO, RK_SNAP_DONE };

/* raid_km-snap.c */
int raidkm_snap_init(struct r5conf *conf);
void raidkm_snap_start(struct r5conf *conf);
int raidkm_snap_map_bio(struct r5conf *conf, struct bio **bip);
void raidkm_snap_stop(struct r5conf *conf);
void raidkm_snap_free(struct r5conf *conf);
void raidkm_snap_seed(struct r5conf *conf);
bool raidkm_snap_room(struct r5conf *conf, struct md_rdev *rdev);
ssize_t raidkm_snap_show(struct mddev *mddev, char *page);
ssize_t raidkm_snap_store(struct mddev *mddev, const char *page, size_t len);

/* raid_km-snapmeta.c, for raid_km-snap.c */
u64 rk_sn_region_pages(u64 R);
int rk_sn_load(struct raidkm_snap *sn);
void rk_sn_commit_fn(struct work_struct *work);
int rk_sn_submit_sync(struct raidkm_snap *sn, struct rk_snap_op *op);
int rk_sn_checkpoint_sync(struct raidkm_snap *sn, bool full);
int rk_sn_alloc(struct raidkm_snap *sn);
void rk_sn_free(struct raidkm_snap *sn);
void rk_sn_rmap_get(struct raidkm_snap *sn, u64 P, u16 *owner, u32 *L);
void rk_sn_rmap_set(struct raidkm_snap *sn, u64 P, u32 L, u16 owner);

/* raid_km-snap.c, for raid_km-snapmeta.c */
void rk_snap_apply(struct raidkm_snap *sn, struct rk_snap_op *op, bool replay);
void rk_snap_cow_finish(struct raidkm_snap *sn, struct rk_snap_cow *c,
			blk_status_t st, bool undo);
struct raidkm_snap_one *rk_snap_slot(struct raidkm_snap *sn, u8 slot);

#endif
